use crate::bounded_command;
use crate::pool_authority::{
    parse_reason, parse_selector, PoolAuthorityPhase, PoolAuthorityStatus, PoolRotationOperation,
    PoolRotationOperationPhase,
};
use crate::rate_limit_resets::SmartResetReason;
use crate::secure_file;
use anyhow::{bail, Context, Result};
use chrono::{Duration as ChronoDuration, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;
use uuid::Uuid;

const REMOTE_AUTHORITY_CONFIG_VERSION: u32 = 1;
const REMOTE_AUTHORITY_CONFIG_MAX_BYTES: usize = 16 * 1024;
const REMOTE_ROTATION_JOURNAL_MAX_BYTES: usize = 16 * 1024;
const REMOTE_OUTPUT_MAX_BYTES: usize = 64 * 1024;
const HOST_MAX_BYTES: usize = 253;
const USER_MAX_BYTES: usize = 64;
const KEY_PATH_MAX_BYTES: usize = 4 * 1024;
const DETAIL_MAX_BYTES: usize = 4 * 1024;
const STATUS_TIMEOUT: Duration = Duration::from_secs(20);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_STATUS_AGE: ChronoDuration = ChronoDuration::seconds(30);
const MAX_FUTURE_SKEW: ChronoDuration = ChronoDuration::seconds(30);
const MAX_COOLDOWN_SECONDS: i64 = 31 * 24 * 60 * 60;
const REMOTE_ROTATION_JOURNAL_VERSION: u32 = 1;
const STATUS_RECONCILIATION_ATTEMPTS: usize = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteRotationOutcome {
    pub status: PoolAuthorityStatus,
    pub operation_id: Uuid,
    pub reason: String,
    pub used_banked_reset: bool,
    pub banked_resets_remaining: Option<u32>,
    pub reset_reason: Option<SmartResetReason>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RemoteRotationJournalState {
    Pending,
    LocallyConverged,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoteRotationJournal {
    version: u32,
    operation_id: Uuid,
    reason: String,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
    started_at: chrono::DateTime<Utc>,
    updated_at: chrono::DateTime<Utc>,
    state: RemoteRotationJournalState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteRotationIntent {
    reason: String,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteRotationPreparation {
    Ready(RemoteRotationJournal),
    Conflicting {
        pending: RemoteRotationJournal,
        requested: RemoteRotationIntent,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteRotateReport {
    operation_id: Uuid,
    used_banked_reset: bool,
    banked_resets_remaining: Option<u32>,
    reset_reason: Option<SmartResetReason>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteAuthorityConfig {
    version: u32,
    enabled: bool,
    host: String,
    user: String,
    port: u16,
    ssh_key_path: String,
}

type RemoteRunner = dyn Fn(&RemoteAuthorityConfig, &str, Duration) -> Result<Vec<u8>> + Send + Sync;

pub fn default_config_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join(".codexswitch")
        .join("remote-authority.json"))
}

fn default_rotation_journal_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join(".codexswitch")
        .join("remote-rotation.json"))
}

pub fn load_default_config() -> Result<RemoteAuthorityConfig> {
    load_config(&default_config_path()?)
}

pub fn load_config(path: &Path) -> Result<RemoteAuthorityConfig> {
    let snapshot = secure_file::observe(path, REMOTE_AUTHORITY_CONFIG_MAX_BYTES, false)
        .context("failed to securely observe remote-authority transport config")?;
    let bytes = snapshot
        .bytes()
        .context("remote-authority transport config is absent")?;
    let config: RemoteAuthorityConfig =
        serde_json::from_slice(bytes).context("remote-authority transport config is malformed")?;
    validate_config(&config)?;
    Ok(config)
}

pub fn fetch_status() -> Result<PoolAuthorityStatus> {
    let config = load_default_config()?;
    fetch_status_with(&config, &run_ssh)
}

pub fn fetch_committed_status() -> Result<PoolAuthorityStatus> {
    let config = load_default_config()?;
    fetch_reconciled_status_with(&config, &run_ssh)
}

pub fn request_target(
    selector: &str,
    request_id: Uuid,
    expected_epoch: u64,
    reason: &str,
) -> Result<PoolAuthorityStatus> {
    let config = load_default_config()?;
    request_target_with(
        &config,
        selector,
        request_id,
        expected_epoch,
        reason,
        &run_ssh,
    )
}

pub fn rotate(
    reason: &str,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
) -> Result<RemoteRotationOutcome> {
    let config = load_default_config()?;
    match begin_or_resume_rotation(reason, cooldown_seconds, allow_banked_reset)? {
        RemoteRotationPreparation::Ready(pending) => rotate_with(&config, &pending, &run_ssh),
        RemoteRotationPreparation::Conflicting { pending, requested } => {
            reconcile_conflicting_rotation_with(&config, &pending, &requested, &run_ssh)
        }
    }
}

pub fn mark_rotation_locally_converged(operation_id: Uuid) -> Result<()> {
    mark_rotation_locally_converged_at(&default_rotation_journal_path()?, operation_id)
}

pub fn validate_adoptable_status(status: &PoolAuthorityStatus) -> Result<()> {
    validate_status(status, Utc::now())?;
    if !matches!(
        status.phase,
        PoolAuthorityPhase::Stable | PoolAuthorityPhase::Degraded
    ) {
        bail!(
            "remote pool authority epoch {} is {:?}, not committed",
            status.epoch,
            status.phase
        );
    }
    Ok(())
}

fn fetch_status_with(
    config: &RemoteAuthorityConfig,
    runner: &RemoteRunner,
) -> Result<PoolAuthorityStatus> {
    let bytes = runner(config, remote_status_command(), STATUS_TIMEOUT)
        .context("remote pool-authority status transport failed")?;
    parse_status(&bytes)
}

fn begin_or_resume_rotation(
    reason: &str,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
) -> Result<RemoteRotationPreparation> {
    begin_or_resume_rotation_at(
        &default_rotation_journal_path()?,
        reason,
        cooldown_seconds,
        allow_banked_reset,
    )
}

fn begin_or_resume_rotation_at(
    path: &Path,
    reason: &str,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
) -> Result<RemoteRotationPreparation> {
    parse_reason(reason).map_err(anyhow::Error::msg)?;
    if !(0..=MAX_COOLDOWN_SECONDS).contains(&cooldown_seconds) {
        bail!("remote rotation cooldown is outside the supported range");
    }
    let requested = RemoteRotationIntent {
        reason: reason.to_string(),
        cooldown_seconds,
        allow_banked_reset,
    };
    let file = secure_file::lock(path, true)
        .context("failed to lock the remote rotation transport journal")?;
    let snapshot = file
        .load(REMOTE_ROTATION_JOURNAL_MAX_BYTES, true)
        .context("failed to load the remote rotation transport journal")?;
    let existing = snapshot
        .bytes()
        .map(|bytes| {
            serde_json::from_slice::<RemoteRotationJournal>(bytes)
                .context("remote rotation transport journal is malformed")
        })
        .transpose()?;
    if let Some(existing) = existing {
        validate_rotation_journal(&existing)?;
        if existing.state == RemoteRotationJournalState::Pending {
            if rotation_journal_matches_intent(&existing, &requested) {
                return Ok(RemoteRotationPreparation::Ready(existing));
            }
            return Ok(RemoteRotationPreparation::Conflicting {
                pending: existing,
                requested,
            });
        }
    }

    let now = Utc::now();
    let journal = RemoteRotationJournal {
        version: REMOTE_ROTATION_JOURNAL_VERSION,
        operation_id: Uuid::new_v4(),
        reason: reason.to_string(),
        cooldown_seconds,
        allow_banked_reset,
        started_at: now,
        updated_at: now,
        state: RemoteRotationJournalState::Pending,
    };
    let encoded =
        serde_json::to_vec_pretty(&journal).context("failed to encode remote rotation journal")?;
    file.commit(
        snapshot.generation(),
        &encoded,
        REMOTE_ROTATION_JOURNAL_MAX_BYTES,
    )
    .context("failed to commit remote rotation transport journal")?;
    Ok(RemoteRotationPreparation::Ready(journal))
}

fn rotation_journal_matches_intent(
    journal: &RemoteRotationJournal,
    intent: &RemoteRotationIntent,
) -> bool {
    journal.reason == intent.reason
        && journal.cooldown_seconds == intent.cooldown_seconds
        && journal.allow_banked_reset == intent.allow_banked_reset
}

fn mark_rotation_locally_converged_at(path: &Path, operation_id: Uuid) -> Result<()> {
    let file = secure_file::lock(path, true)
        .context("failed to lock the remote rotation transport journal")?;
    let snapshot = file
        .load(REMOTE_ROTATION_JOURNAL_MAX_BYTES, false)
        .context("failed to load the remote rotation transport journal")?;
    let mut journal: RemoteRotationJournal = serde_json::from_slice(
        snapshot
            .bytes()
            .context("remote rotation transport journal disappeared")?,
    )
    .context("remote rotation transport journal is malformed")?;
    validate_rotation_journal(&journal)?;
    if journal.operation_id != operation_id {
        bail!("remote rotation transport journal operation changed before local convergence");
    }
    journal.state = RemoteRotationJournalState::LocallyConverged;
    journal.updated_at = Utc::now();
    let encoded =
        serde_json::to_vec_pretty(&journal).context("failed to encode remote rotation journal")?;
    file.commit(
        snapshot.generation(),
        &encoded,
        REMOTE_ROTATION_JOURNAL_MAX_BYTES,
    )
    .context("failed to mark remote rotation as locally converged")?;
    Ok(())
}

fn validate_rotation_journal(journal: &RemoteRotationJournal) -> Result<()> {
    if journal.version != REMOTE_ROTATION_JOURNAL_VERSION {
        bail!(
            "unsupported remote rotation journal version {}",
            journal.version
        );
    }
    if journal.operation_id.is_nil() {
        bail!("remote rotation journal operation ID must not be nil");
    }
    parse_reason(&journal.reason).map_err(anyhow::Error::msg)?;
    if !(0..=MAX_COOLDOWN_SECONDS).contains(&journal.cooldown_seconds) {
        bail!("remote rotation journal cooldown is outside the supported range");
    }
    if journal.updated_at < journal.started_at {
        bail!("remote rotation journal timestamps are inconsistent");
    }
    Ok(())
}

fn request_target_with(
    config: &RemoteAuthorityConfig,
    selector: &str,
    request_id: Uuid,
    expected_epoch: u64,
    reason: &str,
    runner: &RemoteRunner,
) -> Result<PoolAuthorityStatus> {
    parse_selector(selector).map_err(anyhow::Error::msg)?;
    parse_reason(reason).map_err(anyhow::Error::msg)?;
    if expected_epoch == 0 {
        bail!("remote pool-authority expected epoch must be positive");
    }
    let command = format!(
        "export PATH=\"$HOME/.local/bin:$PATH\"; exec codexswitch-cli request-pool-target {} --request-id {} --expected-epoch {} --reason {} --json",
        shell_quote(selector),
        shell_quote(&request_id.hyphenated().to_string()),
        expected_epoch,
        shell_quote(reason),
    );
    let requested = parse_status(
        &runner(config, &command, REQUEST_TIMEOUT)
            .context("remote pool-target request transport failed")?,
    )?;
    validate_adoptable_status(&requested)?;
    if requested.request_id != request_id
        || requested.desired_provider_account_id != selector
        || requested.epoch < expected_epoch
    {
        bail!("remote pool-target request response did not match the submitted transaction");
    }
    Ok(requested)
}

fn rotate_with(
    config: &RemoteAuthorityConfig,
    pending: &RemoteRotationJournal,
    runner: &RemoteRunner,
) -> Result<RemoteRotationOutcome> {
    let observed = fetch_reconciled_status_with(config, runner)?;
    if let Some(outcome) = completed_rotation_outcome_for_pending(&observed, pending)? {
        return Ok(outcome);
    }

    let mut command = format!(
        "export PATH=\"$HOME/.local/bin:$PATH\"; exec codexswitch-cli rotate-now --operation-id {} --reason {} --cooldown-seconds {} --json",
        shell_quote(&pending.operation_id.hyphenated().to_string()),
        shell_quote(&pending.reason),
        pending.cooldown_seconds,
    );
    if pending.allow_banked_reset {
        command.push_str(" --allow-banked-reset");
    }
    let output = match runner(config, &command, REQUEST_TIMEOUT) {
        Ok(output) => Some(output),
        Err(transport_error) => {
            let reconciled = fetch_reconciled_status_with(config, runner).with_context(|| {
                format!(
                    "remote rotation outcome is unknown after transport failure: {transport_error:#}"
                )
            })?;
            if let Some(outcome) = completed_rotation_outcome_for_pending(&reconciled, pending)? {
                return Ok(outcome);
            }
            return Err(transport_error).context(
                "remote rotation transport failed and read-only reconciliation found no completed operation",
            );
        }
    };
    let report: RemoteRotateReport = serde_json::from_slice(
        output
            .as_deref()
            .context("remote rotation output disappeared")?,
    )
    .context("remote rotation report is malformed")?;
    if report.operation_id != pending.operation_id {
        bail!("remote rotation report operation ID does not match the durable request");
    }
    let status = fetch_reconciled_status_with(config, runner)?;
    let outcome = completed_rotation_outcome_for_pending(&status, pending)?
        .context("remote authority did not durably complete the rotation operation")?;
    if report.used_banked_reset != outcome.used_banked_reset
        || report.banked_resets_remaining != outcome.banked_resets_remaining
        || report.reset_reason != outcome.reset_reason
    {
        bail!("remote rotation report does not match the durable authority outcome");
    }
    Ok(outcome)
}

fn reconcile_conflicting_rotation_with(
    config: &RemoteAuthorityConfig,
    pending: &RemoteRotationJournal,
    requested: &RemoteRotationIntent,
    runner: &RemoteRunner,
) -> Result<RemoteRotationOutcome> {
    let observed = fetch_reconciled_status_with(config, runner).with_context(|| {
        format!(
            "pending remote rotation {} has different semantics and remains unknown because read-only reconciliation failed",
            pending.operation_id
        )
    })?;
    if let Some(outcome) = completed_rotation_outcome_for_pending(&observed, pending)? {
        return Ok(outcome);
    }
    bail!(
        "pending remote rotation {} reason={} cooldown_seconds={} allow_banked_reset={} remains unresolved after read-only reconciliation; refusing mismatched request reason={} cooldown_seconds={} allow_banked_reset={}",
        pending.operation_id,
        pending.reason,
        pending.cooldown_seconds,
        pending.allow_banked_reset,
        requested.reason,
        requested.cooldown_seconds,
        requested.allow_banked_reset
    )
}

fn fetch_reconciled_status_with(
    config: &RemoteAuthorityConfig,
    runner: &RemoteRunner,
) -> Result<PoolAuthorityStatus> {
    let mut status = fetch_status_with(config, runner)?;
    for _ in 1..STATUS_RECONCILIATION_ATTEMPTS {
        if status.phase != PoolAuthorityPhase::Converging {
            break;
        }
        status = fetch_status_with(config, runner)?;
    }
    validate_adoptable_status(&status)?;
    Ok(status)
}

fn completed_rotation_outcome(
    status: &PoolAuthorityStatus,
    operation_id: Uuid,
) -> Result<Option<RemoteRotationOutcome>> {
    let Some(operation) = status
        .rotation_operations
        .iter()
        .find(|operation| operation.operation_id == operation_id)
    else {
        return Ok(None);
    };
    if operation.phase != PoolRotationOperationPhase::Completed {
        return Ok(None);
    }
    operation
        .target_provider_account_id
        .as_deref()
        .context("completed remote rotation has no provider target")?;
    let used_banked_reset = operation
        .used_banked_reset
        .context("completed remote rotation has no banked-reset outcome")?;
    let reset_reason = operation
        .reset_reason
        .as_deref()
        .map(parse_smart_reset_reason)
        .transpose()?;
    if !used_banked_reset && reset_reason.is_some() {
        bail!("remote non-reset rotation contains a reset reason");
    }
    Ok(Some(RemoteRotationOutcome {
        status: status.clone(),
        operation_id,
        reason: operation.reason.clone(),
        used_banked_reset,
        banked_resets_remaining: operation.banked_resets_remaining,
        reset_reason,
    }))
}

fn completed_rotation_outcome_for_pending(
    status: &PoolAuthorityStatus,
    pending: &RemoteRotationJournal,
) -> Result<Option<RemoteRotationOutcome>> {
    if let Some(operation) = status
        .rotation_operations
        .iter()
        .find(|operation| operation.operation_id == pending.operation_id)
    {
        if operation.reason != pending.reason
            || operation.cooldown_seconds != pending.cooldown_seconds
            || operation.allow_banked_reset != pending.allow_banked_reset
        {
            bail!(
                "remote rotation operation {} does not match its durable local semantics",
                pending.operation_id
            );
        }
    }
    completed_rotation_outcome(status, pending.operation_id)
}

fn parse_smart_reset_reason(value: &str) -> Result<SmartResetReason> {
    serde_json::from_value(serde_json::Value::String(value.to_string()))
        .context("remote rotation reset reason is unsupported")
}

fn parse_status(bytes: &[u8]) -> Result<PoolAuthorityStatus> {
    let status: PoolAuthorityStatus =
        serde_json::from_slice(bytes).context("remote pool-authority status is malformed")?;
    validate_status(&status, Utc::now())?;
    Ok(status)
}

fn validate_status(status: &PoolAuthorityStatus, now: chrono::DateTime<Utc>) -> Result<()> {
    if status.epoch == 0 {
        bail!("remote pool-authority epoch must be positive");
    }
    validate_printable(
        &status.desired_provider_account_id,
        256,
        "remote desired provider account ID",
    )?;
    validate_printable(
        &status.previous_provider_account_id,
        256,
        "remote previous provider account ID",
    )?;
    parse_reason(&status.reason).map_err(anyhow::Error::msg)?;
    if let Some(detail) = status.detail.as_deref() {
        validate_printable(detail, DETAIL_MAX_BYTES, "remote authority detail")?;
    }
    let age = now.signed_duration_since(status.observed_at);
    if age > MAX_STATUS_AGE || age < -MAX_FUTURE_SKEW {
        bail!("remote pool-authority observation is stale or future-dated");
    }
    if status.updated_at > status.observed_at + MAX_FUTURE_SKEW {
        bail!("remote pool-authority transition timestamp is inconsistent");
    }
    if status.rotation_operations.len() > 16 {
        bail!("remote rotation operation history is oversized");
    }
    let mut operation_ids = HashSet::new();
    let mut started_count = 0;
    for operation in &status.rotation_operations {
        if !operation_ids.insert(operation.operation_id) {
            bail!("remote rotation operation IDs are not unique");
        }
        validate_remote_rotation_operation(operation)?;
        if operation.phase == PoolRotationOperationPhase::Started {
            started_count += 1;
        }
    }
    if started_count > 1 {
        bail!("remote authority reports multiple incomplete rotation operations");
    }
    Ok(())
}

fn validate_remote_rotation_operation(operation: &PoolRotationOperation) -> Result<()> {
    if operation.operation_id.is_nil() {
        bail!("remote rotation operation ID must not be nil");
    }
    parse_reason(&operation.reason).map_err(anyhow::Error::msg)?;
    if !(0..=MAX_COOLDOWN_SECONDS).contains(&operation.cooldown_seconds)
        || operation.updated_at < operation.started_at
    {
        bail!("remote rotation operation metadata is inconsistent");
    }
    if let Some(target) = operation.target_provider_account_id.as_deref() {
        validate_printable(target, 256, "remote rotation provider target")?;
    }
    if let Some(reason) = operation.reset_reason.as_deref() {
        parse_smart_reset_reason(reason)?;
    }
    match operation.phase {
        PoolRotationOperationPhase::Started => {
            if operation.target_provider_account_id.is_some()
                || operation.used_banked_reset.is_some()
                || operation.banked_resets_remaining.is_some()
                || operation.reset_reason.is_some()
            {
                bail!("started remote rotation contains terminal fields");
            }
        }
        PoolRotationOperationPhase::Completed => {
            if operation.target_provider_account_id.is_none()
                || operation.used_banked_reset.is_none()
            {
                bail!("completed remote rotation is missing outcome fields");
            }
        }
    }
    Ok(())
}

fn validate_config(config: &RemoteAuthorityConfig) -> Result<()> {
    if config.version != REMOTE_AUTHORITY_CONFIG_VERSION {
        bail!(
            "unsupported remote-authority transport config version {}",
            config.version
        );
    }
    if !config.enabled {
        bail!("remote-authority transport is disabled");
    }
    validate_host(&config.host)?;
    validate_user(&config.user)?;
    if config.port == 0 {
        bail!("remote-authority SSH port must be positive");
    }
    validate_printable(
        &config.ssh_key_path,
        KEY_PATH_MAX_BYTES,
        "remote-authority SSH key path",
    )?;
    validate_private_key_path(Path::new(&config.ssh_key_path))
}

fn validate_host(value: &str) -> Result<()> {
    validate_printable(value, HOST_MAX_BYTES, "remote-authority host")?;
    if value.starts_with('-')
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b':' | b'[' | b']')
        })
    {
        bail!("remote-authority host contains unsupported characters");
    }
    Ok(())
}

fn validate_user(value: &str) -> Result<()> {
    validate_printable(value, USER_MAX_BYTES, "remote-authority user")?;
    if value.starts_with('-')
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        bail!("remote-authority user contains unsupported characters");
    }
    Ok(())
}

fn validate_printable(value: &str, max_bytes: usize, label: &str) -> Result<()> {
    if value.is_empty() || value.len() > max_bytes {
        bail!("{label} is empty or exceeds {max_bytes} bytes");
    }
    if value.chars().any(char::is_control) {
        bail!("{label} contains control characters");
    }
    Ok(())
}

fn validate_private_key_path(path: &Path) -> Result<()> {
    if !normal_absolute_path(path) {
        bail!("remote-authority SSH key path must be a normal absolute path");
    }
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect SSH key path {}", path.display()))?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("remote-authority SSH key path has an unsafe type, owner, or mode");
    }
    if fs::canonicalize(path).ok().as_deref() != Some(path) {
        bail!("remote-authority SSH key path is not canonical");
    }
    Ok(())
}

fn normal_absolute_path(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    let mut root_seen = false;
    for component in path.components() {
        match component {
            std::path::Component::RootDir if !root_seen => root_seen = true,
            std::path::Component::Normal(_) if root_seen => {}
            _ => return false,
        }
    }
    root_seen
}

fn run_ssh(
    config: &RemoteAuthorityConfig,
    remote_command: &str,
    timeout: Duration,
) -> Result<Vec<u8>> {
    let mut command = ssh_command(config, remote_command);
    let output = bounded_command::output(&mut command, timeout, REMOTE_OUTPUT_MAX_BYTES)?;
    if !output.status.success() {
        let detail = sanitized_stderr(&output.stderr);
        bail!(
            "remote-authority SSH command failed with status {:?}{}",
            output.status.code(),
            if detail.is_empty() {
                String::new()
            } else {
                format!(": {detail}")
            }
        );
    }
    Ok(output.stdout)
}

fn ssh_command(config: &RemoteAuthorityConfig, remote_command: &str) -> Command {
    let destination = format!("{}@{}", config.user, config.host);
    let port = config.port.to_string();
    let mut command = Command::new("/usr/bin/ssh");
    command
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "KbdInteractiveAuthentication=no",
            "-o",
            "NumberOfPasswordPrompts=0",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectionAttempts=1",
            "-o",
            "ConnectTimeout=8",
            "-o",
            "ServerAliveInterval=5",
            "-o",
            "ServerAliveCountMax=2",
            "-o",
            "LogLevel=ERROR",
            "-p",
        ])
        .arg(&port)
        .arg("-i")
        .arg(&config.ssh_key_path)
        .arg("--")
        .arg(&destination)
        .arg(remote_command);
    command
}

fn sanitized_stderr(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .trim()
        .chars()
        .take(512)
        .collect()
}

fn remote_status_command() -> &'static str {
    "export PATH=\"$HOME/.local/bin:$PATH\"; exec codexswitch-cli pool-authority-status --json"
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration as ChronoDuration;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;

    fn secure_temp_dir() -> Result<TempDir> {
        let temp = TempDir::new()?;
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700))?;
        Ok(temp)
    }

    fn write_config(temp: &TempDir, enabled: bool) -> Result<PathBuf> {
        let key = temp.path().join("id_ed25519");
        fs::write(&key, b"test key fixture")?;
        fs::set_permissions(&key, fs::Permissions::from_mode(0o600))?;
        let path = temp.path().join("remote-authority.json");
        fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "enabled": enabled,
                "host": "100.95.84.123",
                "user": "signul",
                "port": 22,
                "sshKeyPath": key,
            }))?,
        )?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        Ok(path)
    }

    fn status(
        epoch: u64,
        target: &str,
        request_id: Uuid,
        updated_at: chrono::DateTime<Utc>,
    ) -> PoolAuthorityStatus {
        PoolAuthorityStatus {
            epoch,
            phase: PoolAuthorityPhase::Stable,
            desired_provider_account_id: target.to_string(),
            request_id,
            reason: "test".to_string(),
            observed_at: Utc::now(),
            updated_at,
            previous_provider_account_id: "previous-provider".to_string(),
            detail: None,
            rotation_operations: Vec::new(),
        }
    }

    #[test]
    fn secure_config_accepts_configured_endpoint_even_when_monitor_is_unrelated() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;

        assert!(config.enabled);
        assert_eq!(config.host, "100.95.84.123");
        assert_eq!(config.user, "signul");
        assert_eq!(config.port, 22);
        Ok(())
    }

    #[test]
    fn ssh_transport_preserves_configured_host_aliases_with_strict_overrides() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let command = ssh_command(&config, remote_status_command());
        let arguments = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        assert!(!arguments.windows(2).any(|pair| pair == ["-F", "/dev/null"]));
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-o", "StrictHostKeyChecking=yes"]));
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-o", "IdentitiesOnly=yes"]));
        assert!(arguments
            .iter()
            .any(|argument| argument == "signul@100.95.84.123"));
        Ok(())
    }

    #[test]
    fn absent_or_disabled_transport_fails_closed() -> Result<()> {
        let temp = secure_temp_dir()?;
        let absent = temp.path().join("remote-authority.json");
        assert!(load_config(&absent).is_err());
        assert!(load_config(&write_config(&temp, false)?).is_err());
        Ok(())
    }

    #[test]
    fn request_returns_the_exact_committed_remote_transaction() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let request_id = Uuid::new_v4();
        let response = status(2, "provider-target", request_id, Utc::now());
        let encoded = serde_json::to_vec(&response)?;
        let commands = Arc::new(Mutex::new(Vec::new()));
        let observed_commands = Arc::clone(&commands);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            observed_commands.lock().unwrap().push(command.to_string());
            Ok(encoded.clone())
        };

        let observed =
            request_target_with(&config, "provider-target", request_id, 1, "manual", &runner)?;

        assert_eq!(observed.epoch, 2);
        assert_eq!(commands.lock().unwrap().len(), 1);
        assert!(commands.lock().unwrap()[0].contains("request-pool-target"));
        Ok(())
    }

    #[test]
    fn status_freshness_uses_observed_at_not_old_transition_time() -> Result<()> {
        let old_transition = Utc::now() - ChronoDuration::days(4);
        let fresh = status(7, "provider-target", Uuid::new_v4(), old_transition);
        validate_adoptable_status(&fresh)?;

        let mut stale = fresh;
        stale.observed_at = Utc::now() - ChronoDuration::minutes(2);
        assert!(validate_adoptable_status(&stale).is_err());
        Ok(())
    }

    #[test]
    fn committed_degraded_status_is_adoptable_but_converging_is_not() -> Result<()> {
        let mut degraded = status(8, "provider-target", Uuid::new_v4(), Utc::now());
        degraded.phase = PoolAuthorityPhase::Degraded;
        degraded.detail = Some("VPS runtime health is degraded".to_string());
        validate_adoptable_status(&degraded)?;

        degraded.phase = PoolAuthorityPhase::Converging;
        assert!(validate_adoptable_status(&degraded).is_err());
        Ok(())
    }

    #[test]
    fn pending_rotation_journal_reuses_only_exact_semantic_match() -> Result<()> {
        let temp = secure_temp_dir()?;
        let path = temp.path().join("remote-rotation.json");
        let RemoteRotationPreparation::Ready(first) =
            begin_or_resume_rotation_at(&path, "usage_limit", 18_000, true)?
        else {
            panic!("first rotation must create a ready operation");
        };
        let RemoteRotationPreparation::Ready(resumed) =
            begin_or_resume_rotation_at(&path, "usage_limit", 18_000, true)?
        else {
            panic!("exact semantic match must resume the pending operation");
        };
        assert_eq!(resumed, first);

        for (reason, cooldown_seconds, allow_banked_reset) in [
            ("token_expired", 18_000, true),
            ("usage_limit", 90, true),
            ("usage_limit", 18_000, false),
        ] {
            let RemoteRotationPreparation::Conflicting { pending, requested } =
                begin_or_resume_rotation_at(&path, reason, cooldown_seconds, allow_banked_reset)?
            else {
                panic!("each semantic mismatch must reject pending-operation reuse");
            };
            assert_eq!(pending, first);
            assert_eq!(requested.reason, reason);
            assert_eq!(requested.cooldown_seconds, cooldown_seconds);
            assert_eq!(requested.allow_banked_reset, allow_banked_reset);
        }

        mark_rotation_locally_converged_at(&path, first.operation_id)?;
        let RemoteRotationPreparation::Ready(next) =
            begin_or_resume_rotation_at(&path, "usage_limit", 18_000, true)?
        else {
            panic!("locally converged operation must permit a new operation");
        };
        assert_ne!(next.operation_id, first.operation_id);
        assert_eq!(next.state, RemoteRotationJournalState::Pending);
        Ok(())
    }

    #[test]
    fn conflicting_pending_rotation_reconciles_read_only_then_fails_unknown() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let pending = RemoteRotationJournal {
            version: REMOTE_ROTATION_JOURNAL_VERSION,
            operation_id: Uuid::new_v4(),
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            state: RemoteRotationJournalState::Pending,
        };
        let requested = RemoteRotationIntent {
            reason: "token_expired".to_string(),
            cooldown_seconds: 90,
            allow_banked_reset: false,
        };
        let commands = Arc::new(Mutex::new(Vec::new()));
        let observed_commands = Arc::clone(&commands);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            observed_commands.lock().unwrap().push(command.to_string());
            Ok(serde_json::to_vec(&status(
                3,
                "provider-current",
                Uuid::new_v4(),
                Utc::now(),
            ))?)
        };

        let error = reconcile_conflicting_rotation_with(&config, &pending, &requested, &runner)
            .expect_err("unresolved conflicting operation must fail closed");

        assert!(error
            .to_string()
            .contains("remains unresolved after read-only reconciliation"));
        assert_eq!(commands.lock().unwrap().len(), 1);
        assert!(commands.lock().unwrap()[0].contains("pool-authority-status"));
        assert!(!commands.lock().unwrap()[0].contains("rotate-now"));
        Ok(())
    }

    #[test]
    fn conflicting_pending_rotation_returns_completed_prior_outcome_without_mutation() -> Result<()>
    {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let operation_id = Uuid::new_v4();
        let pending = RemoteRotationJournal {
            version: REMOTE_ROTATION_JOURNAL_VERSION,
            operation_id,
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            state: RemoteRotationJournalState::Pending,
        };
        let requested = RemoteRotationIntent {
            reason: "token_expired".to_string(),
            cooldown_seconds: 90,
            allow_banked_reset: false,
        };
        let commands = Arc::new(Mutex::new(Vec::new()));
        let observed_commands = Arc::clone(&commands);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            observed_commands.lock().unwrap().push(command.to_string());
            let mut observed = status(4, "provider-pro", Uuid::new_v4(), Utc::now());
            observed.rotation_operations.push(completed_operation(
                operation_id,
                "provider-pro",
                true,
                Some(1),
                Some("preserve_faster_tier"),
            ));
            Ok(serde_json::to_vec(&observed)?)
        };

        let outcome = reconcile_conflicting_rotation_with(&config, &pending, &requested, &runner)?;

        assert_eq!(outcome.operation_id, operation_id);
        assert!(outcome.used_banked_reset);
        assert_eq!(commands.lock().unwrap().len(), 1);
        assert!(!commands.lock().unwrap()[0].contains("rotate-now"));
        Ok(())
    }

    #[test]
    fn remote_rotation_report_preserves_banked_reset_truth() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let operation_id = Uuid::new_v4();
        let pending = RemoteRotationJournal {
            version: REMOTE_ROTATION_JOURNAL_VERSION,
            operation_id,
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            state: RemoteRotationJournalState::Pending,
        };
        let calls = Arc::new(Mutex::new(0usize));
        let observed_calls = Arc::clone(&calls);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            let mut calls = observed_calls.lock().unwrap();
            *calls += 1;
            if command.contains("rotate-now") {
                return Ok(serde_json::to_vec(&serde_json::json!({
                    "operationId": operation_id,
                    "usedBankedReset": true,
                    "bankedResetsRemaining": 1,
                    "resetReason": "preserve_faster_tier",
                }))?);
            }
            let mut observed = status(4, "provider-pro", Uuid::new_v4(), Utc::now());
            if *calls > 1 {
                observed.rotation_operations.push(completed_operation(
                    operation_id,
                    "provider-pro",
                    true,
                    Some(1),
                    Some("preserve_faster_tier"),
                ));
            }
            Ok(serde_json::to_vec(&observed)?)
        };

        let outcome = rotate_with(&config, &pending, &runner)?;

        assert!(outcome.used_banked_reset);
        assert_eq!(outcome.banked_resets_remaining, Some(1));
        assert_eq!(
            outcome.reset_reason,
            Some(SmartResetReason::PreserveFasterTier)
        );
        Ok(())
    }

    #[test]
    fn timeout_after_commit_reconciles_without_second_remote_rotation() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let operation_id = Uuid::new_v4();
        let pending = RemoteRotationJournal {
            version: REMOTE_ROTATION_JOURNAL_VERSION,
            operation_id,
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            state: RemoteRotationJournalState::Pending,
        };
        let committed = Arc::new(Mutex::new(false));
        let mutation_count = Arc::new(Mutex::new(0usize));
        let observed_committed = Arc::clone(&committed);
        let observed_mutations = Arc::clone(&mutation_count);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            if command.contains("rotate-now") {
                *observed_mutations.lock().unwrap() += 1;
                *observed_committed.lock().unwrap() = true;
                bail!("simulated SSH timeout after durable commit");
            }
            let mut observed = status(5, "provider-pro", Uuid::new_v4(), Utc::now());
            if *observed_committed.lock().unwrap() {
                observed.rotation_operations.push(completed_operation(
                    operation_id,
                    "provider-pro",
                    true,
                    Some(1),
                    Some("runtime_usage_limit_no_replacement"),
                ));
            }
            Ok(serde_json::to_vec(&observed)?)
        };

        let first = rotate_with(&config, &pending, &runner)?;
        let replay = rotate_with(&config, &pending, &runner)?;

        assert!(first.used_banked_reset);
        assert_eq!(replay.operation_id, operation_id);
        assert_eq!(*mutation_count.lock().unwrap(), 1);
        assert_eq!(replay.banked_resets_remaining, Some(1));
        Ok(())
    }

    #[test]
    fn malformed_response_retry_reuses_operation_and_cannot_spend_second_reset() -> Result<()> {
        let temp = secure_temp_dir()?;
        let config = load_config(&write_config(&temp, true)?)?;
        let operation_id = Uuid::new_v4();
        let pending = RemoteRotationJournal {
            version: REMOTE_ROTATION_JOURNAL_VERSION,
            operation_id,
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            state: RemoteRotationJournalState::Pending,
        };
        let committed = Arc::new(Mutex::new(false));
        let mutation_count = Arc::new(Mutex::new(0usize));
        let observed_committed = Arc::clone(&committed);
        let observed_mutations = Arc::clone(&mutation_count);
        let runner = move |_config: &RemoteAuthorityConfig, command: &str, _timeout: Duration| {
            if command.contains("rotate-now") {
                *observed_mutations.lock().unwrap() += 1;
                *observed_committed.lock().unwrap() = true;
                return Ok(b"{malformed".to_vec());
            }
            let mut observed = status(5, "provider-pro", Uuid::new_v4(), Utc::now());
            if *observed_committed.lock().unwrap() {
                observed.rotation_operations.push(completed_operation(
                    operation_id,
                    "provider-pro",
                    true,
                    Some(1),
                    Some("runtime_usage_limit_no_replacement"),
                ));
            }
            Ok(serde_json::to_vec(&observed)?)
        };

        let first = rotate_with(&config, &pending, &runner)
            .expect_err("malformed first response must be rejected");
        assert!(format!("{first:#}").contains("remote rotation report is malformed"));
        let replay = rotate_with(&config, &pending, &runner)?;

        assert_eq!(replay.operation_id, operation_id);
        assert!(replay.used_banked_reset);
        assert_eq!(replay.banked_resets_remaining, Some(1));
        assert_eq!(*mutation_count.lock().unwrap(), 1);
        Ok(())
    }

    fn completed_operation(
        operation_id: Uuid,
        target: &str,
        used_banked_reset: bool,
        banked_resets_remaining: Option<u32>,
        reset_reason: Option<&str>,
    ) -> PoolRotationOperation {
        let now = Utc::now();
        PoolRotationOperation {
            operation_id,
            phase: PoolRotationOperationPhase::Completed,
            reason: "usage_limit".to_string(),
            cooldown_seconds: 18_000,
            allow_banked_reset: true,
            started_at: now,
            updated_at: now,
            target_provider_account_id: Some(target.to_string()),
            used_banked_reset: Some(used_banked_reset),
            banked_resets_remaining,
            reset_reason: reset_reason.map(str::to_string),
        }
    }
}

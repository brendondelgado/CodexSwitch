use crate::bounded_command;
use crate::patched_codex;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

const NPM_LATEST_URL: &str = "https://registry.npmjs.org/@openai%2Fcodex/latest";
const CODEX_REPO_URL: &str = "https://github.com/openai/codex.git";
const AUTOMATIC_CHECK_INTERVAL_MINUTES: i64 = 15;
const AUTOMATIC_FAILURE_BACKOFF_HOURS: i64 = 6;
const CHECKING_STALE_AFTER_MINUTES: i64 = 5;
const INSTALLING_STALE_AFTER_MINUTES: i64 = 15;
const MINIMUM_SOURCE_PREPARE_BYTES: u64 = 20 * 1024 * 1024 * 1024;
const PROBE_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);
const MANAGED_DAEMON_PROC_SCAN_TIMEOUT: Duration = Duration::from_secs(3);
const MANAGED_DAEMON_PROC_SCAN_MAX_ENTRIES: usize = 200_000;
const MANAGED_DAEMON_PID_RECORD_MAX_BYTES: u64 = 4 * 1024;
const MANAGED_DAEMON_CMDLINE_MAX_BYTES: u64 = 64 * 1024;
const UPDATE_STATE_MAX_BYTES: u64 = 1024 * 1024;
const REGISTRY_METADATA_MAX_BYTES: u64 = 64 * 1024;
const SOURCE_COMMAND_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const MANAGED_APP_SERVER_UNIT: &str = "signul-codex-app-server.service";
const UPDATER_RETENTION_MAX_ENUM_ENTRIES: usize = 200_000;
const SOURCE_TREE_MAX_COUNT: usize = 3;
const SOURCE_TREE_MAX_TOTAL_BYTES: u64 = 60 * 1024 * 1024 * 1024;
const SOURCE_TREE_MAX_AGE: Duration = Duration::from_secs(45 * 24 * 60 * 60);
const PREPARED_TREE_MAX_COUNT: usize = 4;
const PREPARED_TREE_MAX_TOTAL_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const PREPARED_TREE_MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const UPDATE_LOG_ROTATE_BYTES: u64 = 5 * 1024 * 1024;
const UPDATE_LOG_MAX_COUNT: usize = 4;
const UPDATE_LOG_MAX_TOTAL_BYTES: u64 = 20 * 1024 * 1024;
const UPDATE_LOG_MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const BACKGROUND_UPDATE_DEADLINE: Duration = Duration::from_secs(75 * 60);
const BACKGROUND_UPDATE_MARKER: &str = "CODEXSWITCH_BOUNDED_BACKGROUND_UPDATE";
const RUNTIME_START_INSTALL_GUARD: &str = "runtime-start-install.lock";
const RUNTIME_INSTALL_JOURNAL: &str = "codex-runtime-install.json";
const MACOS_LAUNCHER_INSTALL_JOURNAL: &str = "macos-runtime-activation.json";
const BUILD_TARGET_CLEANUP_ATTEMPTS: usize = 3;

include!("codex_update/state.rs");
include!("codex_update/transaction.rs");
include!("codex_update/macos_activation.rs");
impl Default for CodexUpdateState {
    fn default() -> Self {
        Self {
            status: UpdateStatus::Idle,
            last_checked_at: None,
            latest_stable_version: None,
            installed_version: None,
            installed_artifact_manifest_sha256: None,
            prepared_version: None,
            prepared_source_path: None,
            prepared_binary_path: None,
            prepared_artifact_manifest_sha256: None,
            failed_prepare_version: None,
            prepare_retry_not_before: None,
            failed_install_version: None,
            install_retry_not_before: None,
            cleanup_pending_target_path: None,
            unresolved_failure: None,
            install_transaction: None,
            error: None,
            updated_at: Utc::now(),
        }
    }
}

pub fn status_report() -> Result<CodexUpdateReport> {
    let data_dir = codexswitch_data_dir()?;
    status_report_at(
        &data_dir.join("codex-update.lock"),
        &data_dir.join("codex-cli-update.json"),
        installed_codex_version,
        reconcile_installed_state,
    )
}

fn deferred_status_report() -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    restore_unresolved_failure(&mut state);
    Ok(report_from_state(state))
}

fn status_report_at<Installed, Reconcile>(
    lock_path: &Path,
    state_path: &Path,
    installed_version: Installed,
    reconcile: Reconcile,
) -> Result<CodexUpdateReport>
where
    Installed: FnOnce() -> Option<String>,
    Reconcile: FnOnce(&mut CodexUpdateState) -> bool,
{
    let Some(_operation_lock) = UpdaterOperationLock::try_acquire_at(lock_path)? else {
        let mut state = load_state_at(state_path)?;
        restore_unresolved_failure(&mut state);
        return Ok(report_from_state(state));
    };
    let mut state = load_state_at(state_path)?;
    let observed_installed_version = installed_version();
    let mut changed = state.installed_version != observed_installed_version;
    observe_installed_version(&mut state, observed_installed_version);
    if state.unresolved_failure.is_some() {
        changed |= restore_unresolved_failure(&mut state);
    } else {
        changed |= reconcile(&mut state);
    }
    if changed {
        save_state_at(state_path, &state)?;
    }
    Ok(report_from_state(state))
}

pub fn check_for_update(force: bool, prepare: bool) -> Result<CodexUpdateReport> {
    let Some(_operation_lock) = UpdaterOperationLock::try_acquire()? else {
        return deferred_status_report();
    };
    check_for_update_with_lock_held(force, prepare)
}

fn check_for_update_with_lock_held(force: bool, prepare: bool) -> Result<CodexUpdateReport> {
    dispatch_update_check(
        prepare,
        || check_metadata_with_lock_held(force, false),
        || check_with_artifact_maintenance_lock_held(force),
    )
}

fn dispatch_update_check<T, Metadata, Maintenance>(
    maintenance_requested: bool,
    metadata_only: Metadata,
    with_maintenance: Maintenance,
) -> Result<T>
where
    Metadata: FnOnce() -> Result<T>,
    Maintenance: FnOnce() -> Result<T>,
{
    if maintenance_requested {
        with_maintenance()
    } else {
        metadata_only()
    }
}

fn check_with_artifact_maintenance_lock_held(force: bool) -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    let data_dir = codexswitch_data_dir()?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
    if cleanup_pending_target_at(&mut state, &data_dir)? {
        save_state(&state)?;
    }
    if cleanup_stale_preparation_artifacts(&mut state, Utc::now())? {
        save_state(&state)?;
    }
    check_metadata_with_lock_held(force, true)
}

fn check_metadata_with_lock_held(
    force: bool,
    prepare_requested: bool,
) -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    if !force && !check_due(&state) {
        return Ok(report_from_state(state));
    }

    let checked_at = Utc::now();
    let status_before_check = state.status.clone();
    if status_before_check == UpdateStatus::Failed && state.unresolved_failure.is_none() {
        let failed_at = state.updated_at;
        let failed_version = state
            .failed_install_version
            .clone()
            .or_else(|| state.failed_prepare_version.clone());
        let failure_kind = failure_kind_from_state(&state);
        record_unresolved_failure(&mut state, failure_kind, failed_at, failed_version, None);
    }
    state.status = UpdateStatus::Checking;
    state.last_checked_at = Some(checked_at);
    state.updated_at = checked_at;
    if state.failed_prepare_version.is_none()
        && state.failed_install_version.is_none()
        && !matches!(
            status_before_check,
            UpdateStatus::Installing | UpdateStatus::Failed
        )
    {
        state.error = None;
    }
    save_state(&state)?;

    match fetch_latest_stable_version() {
        Ok(latest) => {
            let prepared_runtime_is_valid = if prepare_requested {
                state.prepared_version.as_deref() == Some(latest.as_str())
                    && state
                        .prepared_binary_path
                        .as_deref()
                        .map(Path::new)
                        .is_some_and(|path| prepared_runtime_is_valid(path, &latest))
            } else {
                status_before_check == UpdateStatus::ReadyToInstall
                    && state.prepared_version.as_deref() == Some(latest.as_str())
            };
            let can_prepare = prepare_requested && current_source_prepare_capacity()?;
            let installed_version = if prepare_requested {
                installed_codex_version()
            } else {
                state.installed_version.clone()
            };
            if apply_successful_metadata_check(
                &mut state,
                &latest,
                installed_version,
                prepared_runtime_is_valid,
                prepare_requested,
                can_prepare,
                status_before_check,
                checked_at,
            ) {
                save_state(&state)?;
                return prepare_version_with_lock_held(&latest);
            }
        }
        Err(error) => {
            apply_metadata_failure(&mut state, format!("{error:#}"), checked_at);
        }
    }

    if state.status == UpdateStatus::Failed && state.unresolved_failure.is_none() {
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Metadata,
            checked_at,
            None,
            None,
        );
    }

    state.updated_at = Utc::now();
    save_state(&state)?;
    Ok(report_from_state(state))
}

fn apply_metadata_failure(state: &mut CodexUpdateState, error: String, checked_at: DateTime<Utc>) {
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
        return;
    }
    state.status = UpdateStatus::Failed;
    state.error = Some(error);
    record_unresolved_failure(state, UpdateFailureKind::Metadata, checked_at, None, None);
}

fn apply_successful_metadata_check(
    state: &mut CodexUpdateState,
    latest: &str,
    installed_version: Option<String>,
    prepared_runtime_is_valid: bool,
    prepare_requested: bool,
    can_prepare: bool,
    status_before_check: UpdateStatus,
    now: DateTime<Utc>,
) -> bool {
    state.last_checked_at = Some(now);
    state.latest_stable_version = Some(latest.to_string());
    observe_installed_version(state, installed_version);
    if version_is_stable(latest)
        && state
            .unresolved_failure
            .as_ref()
            .is_some_and(|failure| failure.kind == UpdateFailureKind::Metadata)
    {
        clear_unresolved_failure(state);
        state.error = None;
    }
    let preserve_same_version_observation = state.installed_version.as_deref() == Some(latest)
        && same_version_observation_must_preserve_failure(state, latest, &status_before_check);
    if !preserve_same_version_observation {
        if has_prepare_failure_for_version(state, latest)
            && state.prepare_retry_not_before.is_none()
        {
            state.prepare_retry_not_before =
                Some(state.updated_at + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS));
        }
        if has_install_failure_for_version(state, latest)
            && state.install_retry_not_before.is_none()
        {
            state.install_retry_not_before =
                Some(state.updated_at + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS));
        }
        clear_obsolete_prepare_failure(state, latest);
        clear_obsolete_install_failure(state, latest);
    }

    if !version_is_stable(latest) {
        state.status = UpdateStatus::Failed;
        state.error = Some(format!(
            "registry latest resolved to non-stable version {latest}; refusing"
        ));
    } else if state.installed_version.as_deref() == Some(latest) {
        if preserve_same_version_observation {
            if !restore_unresolved_failure(state) {
                state.status = status_before_check;
            }
        } else {
            mark_version_installed(state, latest, now);
        }
    } else if state.prepared_version.as_deref() == Some(latest) && prepared_runtime_is_valid {
        if has_install_failure_for_version(state, latest)
            && status_before_check == UpdateStatus::Failed
        {
            state.status = UpdateStatus::Failed;
        } else {
            state.status = UpdateStatus::ReadyToInstall;
            if !has_install_failure_for_version(state, latest) {
                state.error = None;
            }
        }
    } else if prepare_retry_active_for_version(state, latest, now) {
        state.status = UpdateStatus::Failed;
        if state.error.is_none() {
            state.error = Some(format!(
                "preparation of Codex {latest} is deferred until the retry deadline"
            ));
        }
    } else {
        state.status = UpdateStatus::Idle;
        state.error = None;
    }
    state.updated_at = now;
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
    }

    prepare_requested
        && can_prepare
        && state.status == UpdateStatus::Idle
        && !prepare_retry_active_for_version(state, latest, now)
}

pub fn prepare_version(version: &str) -> Result<CodexUpdateReport> {
    let Some(_operation_lock) = UpdaterOperationLock::try_acquire()? else {
        return deferred_status_report();
    };
    prepare_version_with_lock_held(version)
}

fn prepare_version_with_lock_held(version: &str) -> Result<CodexUpdateReport> {
    if HostPlatform::current() == HostPlatform::MacOs {
        bail!(
            "local Codex source builds are disabled on macOS; use the attested remote macOS runtime artifact workflow"
        );
    }
    if !version_is_stable(version) {
        bail!("refusing to prepare non-stable Codex version {version}");
    }

    let mut state = load_state()?;
    let now = Utc::now();
    let data_dir = codexswitch_data_dir()?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
    if cleanup_pending_target_at(&mut state, &data_dir)? {
        save_state(&state)?;
    }
    if cleanup_stale_preparation_artifacts(&mut state, now)? {
        save_state(&state)?;
    }
    if reconcile_requested_version_as_installed(&mut state, version, installed_codex_version(), now)
    {
        save_state(&state)?;
        return Ok(report_from_state(state));
    }
    match reconcile_or_cleanup_existing_prepared_runtime(&mut state, version, now, &data_dir)? {
        ExistingPreparedRuntimeDisposition::Reused => {
            save_state(&state)?;
            return Ok(report_from_state(state));
        }
        ExistingPreparedRuntimeDisposition::ClearedInvalid => save_state(&state)?,
        ExistingPreparedRuntimeDisposition::Absent => {}
    }
    if prepare_retry_active_for_version(&state, version, now)
        || busy_update_state_is_fresh(&state, now)
    {
        save_state(&state)?;
        return Ok(report_from_state(state));
    }
    if !current_source_prepare_capacity()? {
        save_state(&state)?;
        return Ok(report_from_state(state));
    }

    let source_dir = data_dir.join(format!("codex-source-stable-{version}"));
    let prepared_dir = new_prepared_generation_dir(&data_dir, version);
    let prepared_binary = prepared_dir.join("codex");
    state.status = UpdateStatus::Preparing;
    state.latest_stable_version = Some(version.to_string());
    state.prepared_version = Some(version.to_string());
    state.prepared_source_path = Some(source_dir.display().to_string());
    state.prepared_binary_path = Some(prepared_binary.display().to_string());
    state.error = None;
    state.updated_at = Utc::now();
    save_state(&state)?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;

    let workspace = source_dir.join("codex-rs");
    let result = run_with_build_target_cleanup(&workspace, || -> Result<()> {
        checkout_stable_source(version, &source_dir)?;
        patch_codex_source(&source_dir)?;
        let built_binary = patched_codex::build_codex(&workspace)?;
        stage_and_validate_prepared_runtime(&built_binary, &prepared_dir, version)?;
        Ok(())
    });

    match result {
        Ok(BuildTargetCleanupOutcome {
            value: (),
            cleanup_warning,
        }) => {
            state.status = UpdateStatus::ReadyToInstall;
            observe_installed_version(&mut state, installed_codex_version());
            resolve_prepare_failure_for_version(&mut state, version);
            match cleanup_warning {
                Some(error) => {
                    state.cleanup_pending_target_path =
                        Some(workspace.join("target").display().to_string());
                    state.error = Some(format!(
                        "Codex {version} is ready to install, but its build target could not be cleaned: {error:#}"
                    ));
                }
                None => {
                    state.cleanup_pending_target_path = None;
                    state.error = None;
                }
            }
        }
        Err(error) => {
            state.status = UpdateStatus::Failed;
            state.error = Some(format!("{error:#}"));
            if fs::symlink_metadata(workspace.join("target")).is_ok() {
                state.cleanup_pending_target_path =
                    Some(workspace.join("target").display().to_string());
            }
            if matches!(
                fs::symlink_metadata(&prepared_dir),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound
            ) {
                clear_prepared_state(&mut state);
            }
            state.failed_prepare_version = Some(version.to_string());
            state.prepare_retry_not_before =
                Some(Utc::now() + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS));
            record_unresolved_failure(
                &mut state,
                UpdateFailureKind::Preparation,
                Utc::now(),
                Some(version.to_string()),
                None,
            );
        }
    }
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(&mut state);
    }
    state.updated_at = Utc::now();
    save_state(&state)?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;

    if state.status == UpdateStatus::Failed {
        bail!(
            "{}",
            state
                .error
                .clone()
                .unwrap_or_else(|| "failed to prepare Codex update".to_string())
        );
    }
    Ok(report_from_state(state))
}

include!("codex_update/preparation.rs");
include!("codex_update/retention.rs");

pub fn install_prepared() -> Result<CodexUpdateReport> {
    let Some(_operation_lock) = UpdaterOperationLock::try_acquire()? else {
        return deferred_status_report();
    };
    install_prepared_with_lock_held()
}

fn install_prepared_with_lock_held() -> Result<CodexUpdateReport> {
    let platform = HostPlatform::current();
    match platform {
        HostPlatform::MacOs => return install_prepared_macos_with_lock_held(),
        HostPlatform::Linux => {}
        HostPlatform::Other => {
            bail!("prepared Codex installation is supported only on macOS and Linux")
        }
    }
    let mut state = load_state()?;
    if state.status == UpdateStatus::Installed {
        return Ok(report_from_state(state));
    }
    let now = Utc::now();
    let data_dir = codexswitch_data_dir()?;
    enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
    let pending_cleanup_error = cleanup_pending_target_at(&mut state, &data_dir).err();
    let prepared_binary = state
        .prepared_binary_path
        .as_deref()
        .map(PathBuf::from)
        .context("update state is missing prepared binary path")?;
    let expected_version = state
        .prepared_version
        .clone()
        .context("update state is missing prepared version")?;
    if !matches!(
        state.status,
        UpdateStatus::ReadyToInstall | UpdateStatus::Installing | UpdateStatus::Failed
    ) {
        bail!("no patched Codex update is ready to install");
    }
    if let Err(error) = validate_prepared_runtime(&prepared_binary, &expected_version) {
        let cleanup_error = cleanup_prepared_generation(&state).err();
        let cleanup_succeeded = cleanup_error.is_none();
        state.status = UpdateStatus::Failed;
        state.error = Some(match cleanup_error {
            Some(cleanup_error) => format!(
                "prepared Codex {expected_version} failed validation: {error:#}; cleanup also failed: {cleanup_error:#}"
            ),
            None => format!("prepared Codex {expected_version} failed validation: {error:#}"),
        });
        if cleanup_succeeded {
            clear_prepared_state(&mut state);
        }
        state.failed_prepare_version = Some(expected_version.clone());
        state.prepare_retry_not_before =
            Some(now + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS));
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now,
            Some(expected_version.clone()),
            None,
        );
        state.updated_at = now;
        save_state(&state)?;
        bail!("{}", state.error.clone().unwrap_or_default());
    }

    let installed_binary = patched_codex::default_installed_binary()?;
    let current_runtime = installed_runtime_binary(&installed_binary).with_context(|| {
        format!(
            "installed local Codex entry {} does not resolve to one provenance-pinned complete runtime",
            installed_binary.display()
        )
    })?;
    let state_path = state_path()?;
    let install_journal_path = data_dir.join(RUNTIME_INSTALL_JOURNAL);
    if platform == HostPlatform::Linux {
        let install_journal_exists = match fs::symlink_metadata(&install_journal_path) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "failed to inspect runtime install journal {}",
                        install_journal_path.display()
                    )
                });
            }
        };
        if install_journal_exists {
            let recovery_activity = observe_managed_runtime_activity(platform, &current_runtime);
            if let Some(reason) = managed_runtime_block_reason(&recovery_activity) {
                record_interrupted_install_block(
                    &mut state,
                    format!(
                        "interrupted Codex installation requires recovery, but runtime inactivity is not proven: {reason}"
                    ),
                );
                save_state_at(&state_path, &state)?;
                return Ok(report_from_state(state));
            }
            let daemon_reservation =
                managed_daemon_codex_home().map(|home| managed_daemon_reservation_path(&home));
            let guards = match daemon_reservation.as_ref() {
                Ok(path) => RuntimeCommitGuards::try_acquire_at(
                    &runtime_start_install_guard_path(&data_dir),
                    path,
                ),
                Err(error) => GuardAcquire::Blocked(format!(
                    "managed daemon reservation path could not be resolved ({error:#})"
                )),
            };
            let _guards = match guards {
                GuardAcquire::Acquired(guards) => guards,
                GuardAcquire::Blocked(reason) => {
                    record_interrupted_install_block(
                        &mut state,
                        format!("interrupted Codex installation remains journaled: {reason}"),
                    );
                    save_state_at(&state_path, &state)?;
                    return Ok(report_from_state(state));
                }
            };
            let final_activity =
                observe_managed_runtime_activity_with_reservation(platform, &current_runtime, true);
            if let Some(reason) = managed_runtime_block_reason(&final_activity) {
                record_interrupted_install_block(
                    &mut state,
                    format!(
                        "interrupted Codex installation remains journaled because runtime activity changed before recovery: {reason}"
                    ),
                );
                save_state_at(&state_path, &state)?;
                return Ok(report_from_state(state));
            }
            recover_runtime_install_transaction_at(
                &install_journal_path,
                &state_path,
                &mut state,
                &installed_binary,
                &installed_binary.with_file_name("codex-code-mode-host"),
                verify_installed_runtime_pair,
            )?;
            return Ok(report_from_state(state));
        }
        if let Some(transaction) = state.install_transaction.clone() {
            if transaction.phase == InstallTransactionStatePhase::Committed
                && state.installed_version.as_deref() == Some(transaction.version.as_str())
                && verify_installed_runtime_pair(
                    &installed_binary,
                    &installed_binary.with_file_name("codex-code-mode-host"),
                    &transaction.version,
                )
                .is_ok()
            {
                state.install_transaction = None;
                if state.unresolved_failure.is_some() {
                    restore_unresolved_failure(&mut state);
                }
                save_state_at(&state_path, &state)?;
            } else {
                bail!(
                    "updater state contains interrupted install transaction {} without its recovery journal",
                    transaction.id
                );
            }
        }
    }
    let runtime_activity = observe_managed_runtime_activity(platform, &current_runtime);
    let install_outcome = {
        let start_install_guard = runtime_start_install_guard_path(&data_dir);
        let daemon_reservation =
            managed_daemon_codex_home().map(|home| managed_daemon_reservation_path(&home));
        install_staged_if_still_inactive(
            &runtime_activity,
            || StagedLinuxRuntimeInstall::prepare(&prepared_binary, &installed_binary),
            || match daemon_reservation.as_ref() {
                Ok(path) => RuntimeCommitGuards::try_acquire_at(&start_install_guard, path),
                Err(error) => GuardAcquire::Blocked(format!(
                    "managed daemon reservation path could not be resolved ({error:#})"
                )),
            },
            |_| observe_managed_runtime_activity_with_reservation(platform, &current_runtime, true),
            |staged, _| {
                staged.commit_journaled_with(
                    &install_journal_path,
                    &state_path,
                    &mut state,
                    &expected_version,
                    verify_installed_runtime_pair,
                    |_| Ok(()),
                )
            },
        )
    };

    match install_outcome {
        Ok(OfflineInstallOutcome::Installed) => {
            if let Some(error) = pending_cleanup_error {
                if state.unresolved_failure.is_none() {
                    state.error = Some(format!(
                        "Codex {expected_version} installed, but prior build target cleanup remains pending: {error:#}"
                    ));
                }
            }
            save_state_at(&state_path, &state)?;
            enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
            Ok(report_from_state(state))
        }
        Ok(OfflineInstallOutcome::Staged(reason)) => {
            if state.unresolved_failure.is_some() {
                restore_unresolved_failure(&mut state);
            } else {
                state.status = UpdateStatus::ReadyToInstall;
                state.error = Some(format!(
                    "Codex {expected_version} remains staged: {reason}; stop the active managed runtime or repair the failed probe during an approved idle window, then rerun `codexswitch-cli install-prepared-codex`"
                ));
            }
            state.updated_at = Utc::now();
            save_state(&state)?;
            Ok(report_from_state(state))
        }
        Err(error) => {
            state.failed_install_version = Some(expected_version.clone());
            state.install_retry_not_before =
                Some(Utc::now() + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS));
            if state.unresolved_failure.is_none() {
                state.status = UpdateStatus::Failed;
                state.error = Some(format!(
                    "failed to install Codex {expected_version}: {error:#}"
                ));
                state.updated_at = Utc::now();
                let failed_at = state.updated_at;
                let transaction_id = state
                    .install_transaction
                    .as_ref()
                    .map(|transaction| transaction.id.clone());
                record_unresolved_failure(
                    &mut state,
                    UpdateFailureKind::Installation,
                    failed_at,
                    Some(expected_version.clone()),
                    transaction_id,
                );
            } else {
                restore_unresolved_failure(&mut state);
            }
            save_state(&state)?;
            enforce_updater_retention_at(&state, &data_dir, SystemTime::now())?;
            Err(error).with_context(|| format!("failed to install Codex {expected_version}"))
        }
    }
}

pub fn auto_install_update() -> Result<CodexUpdateReport> {
    let state_path = state_path()?;
    let available_bytes = available_disk_bytes(&codexswitch_data_dir()?).unwrap_or(0);
    automatic_update_entrypoint_at_with(
        &state_path,
        Utc::now(),
        AutomaticUpdateContext::current(available_bytes),
        installed_codex_version,
        || check_for_update(false, false),
        |version| {
            if std::env::var_os("CARGO_BUILD_JOBS")
                .is_some_and(|jobs| jobs != std::ffi::OsStr::new("1"))
            {
                bail!("automatic Codex preparation requires CARGO_BUILD_JOBS=1");
            }
            prepare_version(version)
        },
    )
}

fn automatic_update_entrypoint_at_with<Installed, Metadata, Prepare>(
    state_path: &Path,
    now: DateTime<Utc>,
    context: AutomaticUpdateContext,
    installed: Installed,
    metadata: Metadata,
    prepare: Prepare,
) -> Result<CodexUpdateReport>
where
    Installed: FnOnce() -> Option<String>,
    Metadata: FnOnce() -> Result<CodexUpdateReport>,
    Prepare: FnOnce(&str) -> Result<CodexUpdateReport>,
{
    let mut state = load_state_at(state_path)?;
    if context.policy.permits_preparation(context.platform) && state.installed_version.is_none() {
        observe_installed_version(&mut state, installed());
    }
    match automatic_update_decision(&state, now, context) {
        AutomaticUpdateDecision::None => Ok(report_from_state(state)),
        AutomaticUpdateDecision::CheckStableChannel => metadata(),
        AutomaticUpdateDecision::PrepareStableVersion(version) => prepare(&version),
    }
}

pub fn arm_background_update_deadline() {
    if std::env::var_os(BACKGROUND_UPDATE_MARKER).as_deref() != Some(std::ffi::OsStr::new("1")) {
        return;
    }
    std::thread::spawn(|| {
        std::thread::sleep(BACKGROUND_UPDATE_DEADLINE);
        std::process::exit(124);
    });
}

pub fn maybe_spawn_daily_auto_install() -> Result<()> {
    let state = load_state()?;
    let now = Utc::now();
    let data_dir = codexswitch_data_dir()?;
    let available_bytes = available_disk_bytes(&data_dir).unwrap_or(0);
    let decision = automatic_update_decision(
        &state,
        now,
        AutomaticUpdateContext::current(available_bytes),
    );
    if decision == AutomaticUpdateDecision::None {
        return Ok(());
    }

    let exe = background_update_executable().context("failed to resolve current executable")?;
    let log_path = data_dir.join("codex-update.log");
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let maintain_artifacts = automatic_decision_permits_artifact_maintenance(&decision);
    if maintain_artifacts {
        rotate_and_retain_update_logs_at(&data_dir, SystemTime::now())?;
    }
    let args = background_update_args(&decision);

    let spawn = Command::new(exe)
        .args(&args)
        .env(BACKGROUND_UPDATE_MARKER, "1")
        .env("CARGO_BUILD_JOBS", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    match spawn {
        Ok(child) => {
            append_update_log_event(
                &log_path,
                &format!(
                    "{} spawned bounded-output updater pid={} operation={decision:?}\n",
                    Utc::now().to_rfc3339(),
                    child.id()
                ),
            )?;
            if maintain_artifacts {
                rotate_and_retain_update_logs_at(&data_dir, SystemTime::now())?;
            }
            Ok(())
        }
        Err(error) => {
            let mut failed_state = load_state()?;
            if !matches!(
                failed_state.status,
                UpdateStatus::Preparing | UpdateStatus::Installing
            ) {
                failed_state.status = UpdateStatus::Failed;
                failed_state.error =
                    Some(format!("failed to spawn background Codex update: {error}"));
                failed_state.updated_at = Utc::now();
                let failed_at = failed_state.updated_at;
                record_unresolved_failure(
                    &mut failed_state,
                    UpdateFailureKind::Metadata,
                    failed_at,
                    None,
                    None,
                );
                save_state(&failed_state)?;
            }
            Err(error).context("failed to spawn background Codex update")
        }
    }
}

fn append_update_log_event(path: &Path, event: &str) -> Result<()> {
    if event.len() > 1024 {
        bail!("Codex update log event exceeds the 1024 byte limit");
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    file.write_all(event.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

fn clear_prepared_state(state: &mut CodexUpdateState) {
    state.prepared_version = None;
    state.prepared_source_path = None;
    state.prepared_binary_path = None;
    state.prepared_artifact_manifest_sha256 = None;
}

fn clear_prepare_failure(state: &mut CodexUpdateState) {
    state.failed_prepare_version = None;
    state.prepare_retry_not_before = None;
}

fn clear_install_failure(state: &mut CodexUpdateState) {
    state.failed_install_version = None;
    state.install_retry_not_before = None;
}

fn unresolved_failure_from_state(
    state: &CodexUpdateState,
    kind: UpdateFailureKind,
    failed_at: DateTime<Utc>,
    version: Option<String>,
    transaction_id: Option<String>,
) -> UnresolvedUpdateFailure {
    UnresolvedUpdateFailure {
        kind,
        error: state
            .error
            .clone()
            .unwrap_or_else(|| "Codex updater failed without an error message".to_string()),
        failed_at,
        version,
        transaction_id,
        failed_prepare_version: state.failed_prepare_version.clone(),
        prepare_retry_not_before: state.prepare_retry_not_before,
        failed_install_version: state.failed_install_version.clone(),
        install_retry_not_before: state.install_retry_not_before,
    }
}

fn record_unresolved_failure(
    state: &mut CodexUpdateState,
    kind: UpdateFailureKind,
    failed_at: DateTime<Utc>,
    version: Option<String>,
    transaction_id: Option<String>,
) {
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
        return;
    }
    let failure = unresolved_failure_from_state(state, kind, failed_at, version, transaction_id);
    state.unresolved_failure = Some(failure);
}

fn record_interrupted_install_block(state: &mut CodexUpdateState, error: String) {
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
        return;
    }
    let transaction = state.install_transaction.clone();
    let version = transaction
        .as_ref()
        .map(|transaction| transaction.version.clone())
        .or_else(|| state.prepared_version.clone());
    let transaction_id = transaction.map(|transaction| transaction.id);
    let failed_at = Utc::now();
    state.status = UpdateStatus::Failed;
    state.error = Some(error);
    state.failed_install_version = version.clone();
    state.install_retry_not_before = Some(failed_at);
    state.updated_at = failed_at;
    record_unresolved_failure(
        state,
        UpdateFailureKind::Installation,
        failed_at,
        version,
        transaction_id,
    );
}

fn failure_kind_from_state(state: &CodexUpdateState) -> UpdateFailureKind {
    if state.failed_install_version.is_some() {
        UpdateFailureKind::Installation
    } else if state.failed_prepare_version.is_some() {
        UpdateFailureKind::Preparation
    } else {
        UpdateFailureKind::Activation
    }
}

fn preserve_legacy_failure_if_needed(state: &mut CodexUpdateState) {
    if state.status == UpdateStatus::Failed && state.unresolved_failure.is_none() {
        let failure = unresolved_failure_from_state(
            state,
            failure_kind_from_state(state),
            state.updated_at,
            state
                .failed_install_version
                .clone()
                .or_else(|| state.failed_prepare_version.clone()),
            None,
        );
        state.unresolved_failure = Some(failure);
    }
}

fn restore_unresolved_failure(state: &mut CodexUpdateState) -> bool {
    let Some(failure) = state.unresolved_failure.clone() else {
        return false;
    };
    let changed = state.status != UpdateStatus::Failed
        || state.error.as_deref() != Some(failure.error.as_str())
        || state.failed_prepare_version != failure.failed_prepare_version
        || state.prepare_retry_not_before != failure.prepare_retry_not_before
        || state.failed_install_version != failure.failed_install_version
        || state.install_retry_not_before != failure.install_retry_not_before;
    state.status = UpdateStatus::Failed;
    state.error = Some(failure.error);
    state.failed_prepare_version = failure.failed_prepare_version;
    state.prepare_retry_not_before = failure.prepare_retry_not_before;
    state.failed_install_version = failure.failed_install_version;
    state.install_retry_not_before = failure.install_retry_not_before;
    changed
}

fn clear_unresolved_failure(state: &mut CodexUpdateState) {
    state.unresolved_failure = None;
}

fn resolve_prepare_failure_for_version(state: &mut CodexUpdateState, version: &str) {
    let resolves_snapshot = state.unresolved_failure.as_ref().is_some_and(|failure| {
        failure.kind == UpdateFailureKind::Preparation
            && failure.version.as_deref() == Some(version)
            && failure.failed_prepare_version.as_deref() == Some(version)
            && failure.failed_install_version.is_none()
    });
    clear_prepare_failure(state);
    if resolves_snapshot {
        clear_unresolved_failure(state);
    }
}

fn clear_obsolete_prepare_failure(state: &mut CodexUpdateState, latest: &str) {
    if state
        .failed_prepare_version
        .as_deref()
        .is_some_and(|failed| version_is_strictly_newer(latest, failed))
    {
        clear_prepare_failure(state);
    }
}

fn clear_obsolete_install_failure(state: &mut CodexUpdateState, latest: &str) {
    if state
        .failed_install_version
        .as_deref()
        .is_some_and(|failed| version_is_strictly_newer(latest, failed))
    {
        clear_install_failure(state);
    }
}

fn observe_installed_version(state: &mut CodexUpdateState, installed_version: Option<String>) {
    if state.installed_version != installed_version {
        state.installed_artifact_manifest_sha256 = None;
    }
    state.installed_version = installed_version;
}

fn mark_version_installed(state: &mut CodexUpdateState, version: &str, now: DateTime<Utc>) {
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
        state.installed_version = Some(version.to_string());
        state.updated_at = now;
        return;
    }
    state.status = UpdateStatus::Installed;
    state.installed_version = Some(version.to_string());
    clear_prepared_state(state);
    if state
        .failed_prepare_version
        .as_deref()
        .is_some_and(|failed| version_is_at_least(version, failed))
    {
        clear_prepare_failure(state);
    }
    if state
        .failed_install_version
        .as_deref()
        .is_some_and(|failed| version_is_at_least(version, failed))
    {
        clear_install_failure(state);
    }
    clear_unresolved_failure(state);
    state.error = None;
    state.updated_at = now;
}

fn mark_version_installed_for_transaction(
    state: &mut CodexUpdateState,
    version: &str,
    transaction_id: &str,
    now: DateTime<Utc>,
) {
    state.installed_version = Some(version.to_string());
    state.installed_artifact_manifest_sha256 = None;
    clear_prepared_state(state);
    let resolves_install_failure = state.unresolved_failure.as_ref().is_some_and(|failure| {
        failure.kind == UpdateFailureKind::Installation
            && failure.version.as_deref() == Some(version)
            && failure.transaction_id.as_deref() == Some(transaction_id)
    });
    if resolves_install_failure {
        clear_install_failure(state);
        clear_unresolved_failure(state);
    }
    if let Some(transaction) = state.install_transaction.as_mut() {
        if transaction.id == transaction_id && transaction.version == version {
            transaction.phase = InstallTransactionStatePhase::Committed;
        }
    }
    if state.unresolved_failure.is_some() {
        restore_unresolved_failure(state);
    } else {
        state.status = UpdateStatus::Installed;
        state.error = None;
    }
    state.updated_at = now;
}

fn same_version_observation_must_preserve_failure(
    state: &CodexUpdateState,
    version: &str,
    observed_status: &UpdateStatus,
) -> bool {
    state.unresolved_failure.is_some()
        || *observed_status == UpdateStatus::Failed
        || has_install_failure_for_version(state, version)
        || (*observed_status == UpdateStatus::Installing
            && state.prepared_version.as_deref() == Some(version))
}

fn reconcile_requested_version_as_installed(
    state: &mut CodexUpdateState,
    requested_version: &str,
    installed_version: Option<String>,
    now: DateTime<Utc>,
) -> bool {
    observe_installed_version(state, installed_version);
    if state.installed_version.as_deref() != Some(requested_version) {
        return false;
    }

    state.latest_stable_version = Some(requested_version.to_string());
    if same_version_observation_must_preserve_failure(state, requested_version, &state.status) {
        restore_unresolved_failure(state);
        state.updated_at = now;
    } else {
        mark_version_installed(state, requested_version, now);
    }
    true
}

fn reconcile_requested_version_as_prepared(
    state: &mut CodexUpdateState,
    requested_version: &str,
    now: DateTime<Utc>,
) -> bool {
    let valid = state.prepared_version.as_deref() == Some(requested_version)
        && state
            .prepared_binary_path
            .as_deref()
            .map(Path::new)
            .is_some_and(|path| prepared_runtime_is_valid(path, requested_version));
    if !valid {
        return false;
    }
    if state.unresolved_failure.is_some()
        || (has_install_failure_for_version(state, requested_version)
            && state.status == UpdateStatus::Failed)
    {
        restore_unresolved_failure(state);
        state.status = UpdateStatus::Failed;
    } else {
        state.status = UpdateStatus::ReadyToInstall;
        if !has_install_failure_for_version(state, requested_version) {
            state.error = None;
        }
    }
    state.updated_at = now;
    true
}

fn reconcile_or_cleanup_existing_prepared_runtime(
    state: &mut CodexUpdateState,
    requested_version: &str,
    now: DateTime<Utc>,
    data_dir: &Path,
) -> Result<ExistingPreparedRuntimeDisposition> {
    if state.prepared_binary_path.is_none() {
        return Ok(ExistingPreparedRuntimeDisposition::Absent);
    }
    if reconcile_requested_version_as_prepared(state, requested_version, now) {
        return Ok(ExistingPreparedRuntimeDisposition::Reused);
    }
    cleanup_prepared_generation_at(state, data_dir)?;
    clear_prepared_state(state);
    Ok(ExistingPreparedRuntimeDisposition::ClearedInvalid)
}

fn has_prepare_failure_for_version(state: &CodexUpdateState, version: &str) -> bool {
    state.failed_prepare_version.as_deref() == Some(version)
}

fn prepare_retry_not_before_for_version(
    state: &CodexUpdateState,
    version: &str,
) -> Option<DateTime<Utc>> {
    if !has_prepare_failure_for_version(state, version) {
        return None;
    }
    state.prepare_retry_not_before.or(Some(
        state.updated_at + ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS),
    ))
}

fn prepare_retry_active_for_version(
    state: &CodexUpdateState,
    version: &str,
    now: DateTime<Utc>,
) -> bool {
    prepare_retry_not_before_for_version(state, version).is_some_and(|deadline| now < deadline)
}

fn has_install_failure_for_version(state: &CodexUpdateState, version: &str) -> bool {
    state.failed_install_version.as_deref() == Some(version)
}

fn busy_update_state_is_fresh(state: &CodexUpdateState, now: DateTime<Utc>) -> bool {
    let stale_after = match state.status {
        UpdateStatus::Checking => ChronoDuration::minutes(CHECKING_STALE_AFTER_MINUTES),
        UpdateStatus::Preparing => ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS),
        UpdateStatus::Installing => ChronoDuration::minutes(INSTALLING_STALE_AFTER_MINUTES),
        _ => return false,
    };
    now.signed_duration_since(state.updated_at) < stale_after
}

fn automatic_update_decision(
    state: &CodexUpdateState,
    now: DateTime<Utc>,
    context: AutomaticUpdateContext,
) -> AutomaticUpdateDecision {
    if let Some(version) = state.prepared_version.as_deref() {
        if has_install_failure_for_version(state, version) {
            if automatic_check_due(state, now) {
                return AutomaticUpdateDecision::CheckStableChannel;
            }
            return AutomaticUpdateDecision::None;
        }
    }

    match state.status {
        UpdateStatus::ReadyToInstall => {
            return AutomaticUpdateDecision::None;
        }
        UpdateStatus::Checking | UpdateStatus::Preparing | UpdateStatus::Installing => {
            if busy_update_state_is_fresh(state, now) {
                return AutomaticUpdateDecision::None;
            }
            return AutomaticUpdateDecision::CheckStableChannel;
        }
        UpdateStatus::Failed => {
            if state
                .latest_stable_version
                .as_deref()
                .is_some_and(|version| has_prepare_failure_for_version(state, version))
            {
                if automatic_check_due(state, now) {
                    return AutomaticUpdateDecision::CheckStableChannel;
                }
                if state
                    .latest_stable_version
                    .as_deref()
                    .is_some_and(|version| prepare_retry_active_for_version(state, version, now))
                {
                    return AutomaticUpdateDecision::None;
                }
            } else {
                if now.signed_duration_since(state.updated_at)
                    < ChronoDuration::hours(AUTOMATIC_FAILURE_BACKOFF_HOURS)
                {
                    return AutomaticUpdateDecision::None;
                }
                return AutomaticUpdateDecision::CheckStableChannel;
            }
        }
        UpdateStatus::Idle | UpdateStatus::Installed => {}
    }

    if automatic_check_due(state, now) {
        return AutomaticUpdateDecision::CheckStableChannel;
    }

    let Some(latest) = state.latest_stable_version.as_deref() else {
        return AutomaticUpdateDecision::None;
    };
    if !version_is_stable(latest) || state.installed_version.as_deref() == Some(latest) {
        return AutomaticUpdateDecision::None;
    }
    if prepare_retry_active_for_version(state, latest, now) {
        return AutomaticUpdateDecision::None;
    }
    if !context.policy.permits_preparation(context.platform)
        || !source_prepare_allowed(context.available_bytes)
    {
        return AutomaticUpdateDecision::None;
    }

    AutomaticUpdateDecision::PrepareStableVersion(latest.to_string())
}

fn automatic_check_due(state: &CodexUpdateState, now: DateTime<Utc>) -> bool {
    state
        .last_checked_at
        .map(|checked| {
            now.signed_duration_since(checked)
                >= ChronoDuration::minutes(AUTOMATIC_CHECK_INTERVAL_MINUTES)
        })
        .unwrap_or(true)
}

fn source_prepare_allowed(available_bytes: u64) -> bool {
    available_bytes >= MINIMUM_SOURCE_PREPARE_BYTES
}

fn current_source_prepare_capacity() -> Result<bool> {
    let data_dir = codexswitch_data_dir()?;
    Ok(source_prepare_allowed(
        available_disk_bytes(&data_dir).unwrap_or(0),
    ))
}

fn background_update_args(decision: &AutomaticUpdateDecision) -> Vec<String> {
    match decision {
        AutomaticUpdateDecision::None => Vec::new(),
        AutomaticUpdateDecision::CheckStableChannel => {
            vec![
                "check-codex-update".to_string(),
                "--force".to_string(),
                "--json".to_string(),
            ]
        }
        AutomaticUpdateDecision::PrepareStableVersion(version) => vec![
            "prepare-codex-update".to_string(),
            "--version".to_string(),
            version.clone(),
            "--json".to_string(),
        ],
    }
}

fn automatic_decision_permits_artifact_maintenance(decision: &AutomaticUpdateDecision) -> bool {
    matches!(decision, AutomaticUpdateDecision::PrepareStableVersion(_))
}

#[cfg(unix)]
fn available_disk_bytes(path: &Path) -> Result<u64> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;

    let probe_path = path
        .ancestors()
        .find(|candidate| candidate.exists())
        .unwrap_or(Path::new("/"));
    let path = CString::new(probe_path.as_os_str().as_bytes())
        .context("disk probe path contained a NUL byte")?;
    let mut stats = MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("failed to inspect free space for {}", probe_path.display()));
    }
    let stats = unsafe { stats.assume_init() };
    let block_size = if stats.f_frsize > 0 {
        stats.f_frsize
    } else {
        stats.f_bsize
    };
    (stats.f_bavail as u64)
        .checked_mul(block_size)
        .context("available disk byte count overflowed")
}

#[cfg(not(unix))]
fn available_disk_bytes(path: &Path) -> Result<u64> {
    let probe_path = path
        .ancestors()
        .find(|candidate| candidate.exists())
        .unwrap_or(Path::new("/"));
    let output = bounded_command::output(
        Command::new("df").args(["-Pk"]).arg(probe_path),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .with_context(|| format!("failed to inspect free space for {}", probe_path.display()))?;
    if !output.status.success() {
        bail!(
            "failed to inspect free space for {}: {}",
            probe_path.display(),
            output.status
        );
    }

    let stdout = String::from_utf8(output.stdout).context("df emitted non-UTF-8 output")?;
    let data_line = stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .last()
        .context("df output did not contain a filesystem row")?;
    let available_kib = data_line
        .split_whitespace()
        .nth(3)
        .context("df output did not contain an available-space column")?
        .parse::<u64>()
        .context("df available-space column was not an integer")?;
    available_kib
        .checked_mul(1024)
        .context("available disk byte count overflowed")
}

fn report_from_state(state: CodexUpdateState) -> CodexUpdateReport {
    let install_command = if state.status == UpdateStatus::ReadyToInstall {
        Some("codexswitch-cli install-prepared-codex".to_string())
    } else {
        None
    };
    let summary = summary_for_state(&state, install_command.as_deref());
    CodexUpdateReport {
        status: state.status,
        summary,
        last_checked_at: state.last_checked_at,
        latest_stable_version: state.latest_stable_version,
        installed_version: state.installed_version,
        installed_artifact_manifest_sha256: state.installed_artifact_manifest_sha256,
        prepared_version: state.prepared_version,
        prepared_source_path: state.prepared_source_path,
        prepared_binary_path: state.prepared_binary_path,
        prepared_artifact_manifest_sha256: state.prepared_artifact_manifest_sha256,
        failed_prepare_version: state.failed_prepare_version,
        prepare_retry_not_before: state.prepare_retry_not_before,
        failed_install_version: state.failed_install_version,
        install_retry_not_before: state.install_retry_not_before,
        cleanup_pending_target_path: state.cleanup_pending_target_path,
        install_command,
        error: state.error,
    }
}

fn reconcile_installed_state(state: &mut CodexUpdateState) -> bool {
    let Ok(installed_binary) = patched_codex::default_installed_binary() else {
        return false;
    };
    reconcile_installed_state_at(state, &installed_binary)
}

fn reconcile_installed_state_at(state: &mut CodexUpdateState, installed_binary: &Path) -> bool {
    let Some(prepared_version) = state.prepared_version.as_deref() else {
        return false;
    };
    if state.installed_version.as_deref() != Some(prepared_version) {
        return false;
    }
    let Ok(runtime_binary) = installed_runtime_binary(installed_binary) else {
        return false;
    };
    let Some(prepared_binary) = state.prepared_binary_path.as_deref().map(Path::new) else {
        return false;
    };
    if !patched_codex::binary_has_hot_swap_markers(&runtime_binary)
        || !patched_codex::runtime_has_valid_code_mode_host(&runtime_binary)
    {
        return false;
    }
    if patched_codex::codex_version(&runtime_binary).as_deref() != Some(prepared_version) {
        return false;
    }
    if !runtime_matches_prepared_runtime(&runtime_binary, prepared_binary) {
        return false;
    }
    if same_version_observation_must_preserve_failure(state, prepared_version, &state.status) {
        restore_unresolved_failure(state);
        return false;
    }

    let installed_version = prepared_version.to_string();
    state.installed_artifact_manifest_sha256 = None;
    mark_version_installed(state, &installed_version, Utc::now());
    true
}

fn background_update_executable() -> Result<PathBuf> {
    let current = std::env::current_exe().context("failed to resolve current executable")?;
    let current_text = current.to_string_lossy();
    if current.exists() && !current_text.contains(" (deleted)") {
        return Ok(current);
    }

    let user_bin = home_dir()?.join(".local/bin/codexswitch-cli");
    if user_bin.exists() {
        return Ok(user_bin);
    }

    Ok(current)
}

fn summary_for_state(state: &CodexUpdateState, install_command: Option<&str>) -> String {
    summary_for_state_on_platform(state, install_command, HostPlatform::current())
}

fn summary_for_state_on_platform(
    state: &CodexUpdateState,
    install_command: Option<&str>,
    platform: HostPlatform,
) -> String {
    match state.status {
        UpdateStatus::ReadyToInstall => format!(
            "updated and patched Codex CLI {} is ready to install{}{}",
            state.prepared_version.as_deref().unwrap_or("unknown"),
            install_command
                .map(|command| format!(" ({command})"))
                .unwrap_or_default(),
            state
                .error
                .as_deref()
                .map(|warning| format!("; warning: {warning}"))
                .unwrap_or_default()
        ),
        UpdateStatus::Preparing => format!(
            "preparing stable Codex CLI {} in the background",
            state
                .prepared_version
                .as_deref()
                .or(state.latest_stable_version.as_deref())
                .unwrap_or("unknown")
        ),
        UpdateStatus::Installing => format!(
            "installing stable patched Codex CLI {} offline",
            state
                .prepared_version
                .as_deref()
                .or(state.latest_stable_version.as_deref())
                .unwrap_or("unknown")
        ),
        UpdateStatus::Checking => "checking for a stable Codex CLI update".to_string(),
        UpdateStatus::Installed if platform == HostPlatform::MacOs => format!(
            "attested stable Codex CLI {} route is installed and verified",
            state.installed_version.as_deref().unwrap_or("unknown")
        ),
        UpdateStatus::Installed => format!(
            "stable patched Codex CLI {} is installed on disk; runtime activation is separate",
            state.installed_version.as_deref().unwrap_or("unknown")
        ),
        UpdateStatus::Failed => {
            if let (Some(version), Some(deadline)) = (
                state.failed_prepare_version.as_deref(),
                state.prepare_retry_not_before,
            ) {
                if Utc::now() < deadline {
                    return format!(
                        "Codex CLI {version} preparation failed; automatic retry deferred until {}: {}",
                        deadline.to_rfc3339(),
                        state.error.as_deref().unwrap_or("unknown error")
                    );
                }
            }
            format!(
                "Codex CLI update failed: {}",
                state.error.as_deref().unwrap_or("unknown error")
            )
        }
        UpdateStatus::Idle if platform == HostPlatform::MacOs => {
            match (&state.latest_stable_version, &state.installed_version) {
                (Some(latest), Some(installed)) if latest != installed => format!(
                    "stable Codex CLI {latest} is available; build the attested remote macOS runtime artifact, then run scripts/install-macos-cli-artifact.sh"
                ),
                (Some(latest), _) => {
                    format!("latest stable Codex CLI is {latest}; no attested artifact is staged")
                }
                (None, None) => "local Codex runtime is missing or fails complete provenance/hot-swap validation; build and activate an attested remote macOS runtime artifact".to_string(),
                _ => "Codex CLI stable update has not checked yet".to_string(),
            }
        }
        UpdateStatus::Idle => match (&state.latest_stable_version, &state.installed_version) {
            (Some(latest), Some(installed)) if latest != installed => {
                format!("stable Codex CLI {latest} is available; run codexswitch-cli check-codex-update --prepare")
            }
            (Some(latest), _) => format!("latest stable Codex CLI is {latest}; no staged update"),
            (None, None) => "local Codex runtime is missing or fails complete provenance/hot-swap validation; run `codexswitch-cli check-codex-update --prepare`, then explicitly install the verified generation while runtimes are inactive".to_string(),
            _ => "Codex CLI stable update has not checked yet".to_string(),
        },
    }
}

include!("codex_update/runtime_discovery.rs");
fn fetch_latest_stable_version() -> Result<String> {
    let response = Client::builder()
        .timeout(Duration::from_secs(20))
        .build()?
        .get(NPM_LATEST_URL)
        .send()
        .context("failed to fetch @openai/codex latest metadata")?
        .error_for_status()
        .context("npm registry returned an error for @openai/codex/latest")?;
    decode_latest_stable_metadata(response)
}

fn decode_latest_stable_metadata(reader: impl Read) -> Result<String> {
    let mut bytes = Vec::new();
    reader
        .take(REGISTRY_METADATA_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .context("failed to read bounded @openai/codex latest metadata")?;
    if bytes.len() as u64 > REGISTRY_METADATA_MAX_BYTES {
        bail!(
            "@openai/codex latest metadata exceeded the {} byte limit",
            REGISTRY_METADATA_MAX_BYTES
        );
    }
    let package = serde_json::from_slice::<NpmLatest>(&bytes)
        .context("failed to parse @openai/codex latest metadata")?;
    if !version_is_stable(&package.version) {
        bail!(
            "@openai/codex latest resolved to non-stable version {}",
            package.version
        );
    }
    Ok(package.version)
}

// Kept in the parent module so source-generation helpers and their deterministic
// tests share the same private types without widening the updater API.
include!("codex_update/source_patching.rs");
fn load_state() -> Result<CodexUpdateState> {
    let path = state_path()?;
    load_state_at(&path)
}

fn load_state_at(path: &Path) -> Result<CodexUpdateState> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(CodexUpdateState::default());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to inspect {}", path.display()));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("Codex update state must be a regular non-symlink file");
    }
    if metadata.len() > UPDATE_STATE_MAX_BYTES {
        bail!(
            "Codex update state exceeds the {} byte limit",
            UPDATE_STATE_MAX_BYTES
        );
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
        || opened.mode() != metadata.mode()
    {
        bail!("Codex update state changed identity while it was opened");
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(UPDATE_STATE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("failed to read {}", path.display()))?;
    if bytes.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!(
            "Codex update state exceeded the {} byte limit while reading",
            UPDATE_STATE_MAX_BYTES
        );
    }
    let mut state = serde_json::from_slice::<CodexUpdateState>(&bytes)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    preserve_legacy_failure_if_needed(&mut state);
    Ok(state)
}

fn save_state(state: &CodexUpdateState) -> Result<()> {
    let path = state_path()?;
    save_state_at(&path, state)
}

fn save_state_at(path: &Path, state: &CodexUpdateState) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let parent = path.parent().context("update state path has no parent")?;
    let temp_path = parent.join(format!(
        ".codex-cli-update.json.tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    ));
    let encoded = serde_json::to_vec_pretty(state)?;
    if encoded.len() as u64 > UPDATE_STATE_MAX_BYTES {
        bail!(
            "Codex update state exceeds the {} byte limit",
            UPDATE_STATE_MAX_BYTES
        );
    }
    let result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp_path)
            .with_context(|| format!("failed to create {}", temp_path.display()))?;
        file.write_all(&encoded)
            .with_context(|| format!("failed to write {}", temp_path.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to sync {}", temp_path.display()))?;
        fs::rename(&temp_path, path).with_context(|| {
            format!(
                "failed to atomically replace {} with {}",
                path.display(),
                temp_path.display()
            )
        })?;
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .with_context(|| format!("failed to sync directory {}", parent.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn state_path() -> Result<PathBuf> {
    Ok(codexswitch_data_dir()?.join("codex-cli-update.json"))
}

fn codexswitch_data_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/share/codexswitch"))
}

fn installed_codex_version() -> Option<String> {
    let installed_binary = patched_codex::default_installed_binary().ok()?;
    installed_codex_version_from_path(&installed_binary)
}

fn installed_codex_version_from_path(installed_binary: &Path) -> Option<String> {
    let runtime_binary = installed_runtime_binary(installed_binary).ok()?;
    if !patched_codex::binary_has_hot_swap_markers(&runtime_binary)
        || !patched_codex::runtime_has_valid_code_mode_host(&runtime_binary)
    {
        return None;
    }
    patched_codex::codex_version(&runtime_binary)
}

fn installed_runtime_binary(installed_binary: &Path) -> Result<PathBuf> {
    patched_codex::resolve_installed_runtime(installed_binary)
}

fn check_due(state: &CodexUpdateState) -> bool {
    state
        .last_checked_at
        .map(|checked| {
            Utc::now() - checked >= ChronoDuration::minutes(AUTOMATIC_CHECK_INTERVAL_MINUTES)
        })
        .unwrap_or(true)
}

pub fn version_is_stable(version: &str) -> bool {
    parse_stable_version(version).is_some()
}

fn version_is_strictly_newer(candidate: &str, previous: &str) -> bool {
    match (
        parse_stable_version(candidate),
        parse_stable_version(previous),
    ) {
        (Some(candidate), Some(previous)) => candidate > previous,
        _ => false,
    }
}

fn version_is_at_least(candidate: &str, previous: &str) -> bool {
    match (
        parse_stable_version(candidate),
        parse_stable_version(previous),
    ) {
        (Some(candidate), Some(previous)) => candidate >= previous,
        _ => false,
    }
}

fn parse_stable_version(version: &str) -> Option<(u64, u64, u64)> {
    let mut components = version.split('.');
    let parsed = (
        components.next()?.parse().ok()?,
        components.next()?.parse().ok()?,
        components.next()?.parse().ok()?,
    );
    if components.next().is_some() {
        return None;
    }
    Some(parsed)
}

pub fn stable_source_tag(version: &str) -> Result<String> {
    if !version_is_stable(version) {
        bail!("refusing non-stable Codex version {version}");
    }
    Ok(format!("rust-v{version}"))
}

fn set_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}

include!("codex_update/tests.rs");

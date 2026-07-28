use crate::account_store::{active_account, validate_accounts, CodexAccount};
use crate::activation::RuntimeActivationLease;
use crate::secure_file::{self, SecureFileGeneration, SecureFileLock};
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const POOL_AUTHORITY_VERSION: u32 = 1;
const POOL_AUTHORITY_MAX_BYTES: usize = 64 * 1024;
const PROVIDER_ACCOUNT_ID_MAX_BYTES: usize = 256;
const REASON_MAX_BYTES: usize = 256;
const DETAIL_MAX_BYTES: usize = 4 * 1024;
const ROTATION_OPERATION_HISTORY_LIMIT: usize = 16;
const MAX_ROTATION_COOLDOWN_SECONDS: i64 = 31 * 24 * 60 * 60;
const BOOTSTRAP_REASON: &str = "bootstrap";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PoolAuthorityPhase {
    Stable,
    Converging,
    Degraded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PoolRotationOperationPhase {
    Started,
    Completed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolRotationOperation {
    pub operation_id: Uuid,
    pub phase: PoolRotationOperationPhase,
    pub reason: String,
    pub cooldown_seconds: i64,
    pub allow_banked_reset: bool,
    pub started_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_provider_account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used_banked_reset: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub banked_resets_remaining: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reset_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolAuthorityRecord {
    version: u32,
    pub epoch: u64,
    pub phase: PoolAuthorityPhase,
    pub desired_provider_account_id: String,
    pub request_id: Uuid,
    pub reason: String,
    pub requested_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub previous_epoch: u64,
    pub previous_provider_account_id: String,
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rotation_operations: Vec<PoolRotationOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolAuthorityStatus {
    pub epoch: u64,
    pub phase: PoolAuthorityPhase,
    pub desired_provider_account_id: String,
    pub request_id: Uuid,
    pub reason: String,
    pub observed_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub previous_provider_account_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rotation_operations: Vec<PoolRotationOperation>,
}

impl From<&PoolAuthorityRecord> for PoolAuthorityStatus {
    fn from(record: &PoolAuthorityRecord) -> Self {
        Self {
            epoch: record.epoch,
            phase: record.phase,
            desired_provider_account_id: record.desired_provider_account_id.clone(),
            request_id: record.request_id,
            reason: record.reason.clone(),
            observed_at: Utc::now(),
            updated_at: record.updated_at,
            previous_provider_account_id: record.previous_provider_account_id.clone(),
            detail: record.detail.clone(),
            rotation_operations: record.rotation_operations.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetRequestDisposition {
    Replay,
    AlreadyStable,
    Started,
    RecoverSameTarget,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationOperationDisposition {
    Started,
    Recover,
    Replay,
}

impl TargetRequestDisposition {
    pub fn needs_convergence(self) -> bool {
        matches!(self, Self::Started | Self::RecoverSameTarget)
    }
}

pub struct PoolAuthorityLock {
    file: SecureFileLock,
    generation: SecureFileGeneration,
    record: Option<PoolAuthorityRecord>,
}

impl PoolAuthorityLock {
    pub fn acquire_under_runtime_lease(
        runtime_lease: &RuntimeActivationLease,
        store_path: &Path,
    ) -> Result<Self> {
        runtime_lease.require_store(store_path)?;
        let file = secure_file::lock(&pool_authority_path(store_path), true)
            .context("failed to acquire pool-authority journal lock")?;
        let snapshot = file
            .load(POOL_AUTHORITY_MAX_BYTES, true)
            .context("failed to load pool-authority journal")?;
        let record = decode_record(snapshot.bytes())?;
        Ok(Self {
            file,
            generation: snapshot.generation().clone(),
            record,
        })
    }

    pub fn record(&self) -> Option<&PoolAuthorityRecord> {
        self.record.as_ref()
    }

    pub fn require_record(&self) -> Result<&PoolAuthorityRecord> {
        self.record
            .as_ref()
            .context("pool authority is not initialized")
    }

    pub fn bootstrap_from_active(
        &mut self,
        accounts: &[CodexAccount],
    ) -> Result<PoolAuthorityRecord> {
        if let Some(record) = self.record.as_ref() {
            return Ok(record.clone());
        }
        validate_accounts(accounts).context("pool-authority bootstrap account store is invalid")?;
        let active = active_account(accounts)
            .context("pool-authority bootstrap requires exactly one active account")?;
        validate_provider_account_id(&active.account_id)?;
        let now = Utc::now();
        let record = PoolAuthorityRecord {
            version: POOL_AUTHORITY_VERSION,
            epoch: 1,
            phase: PoolAuthorityPhase::Stable,
            desired_provider_account_id: active.account_id.clone(),
            request_id: Uuid::nil(),
            reason: BOOTSTRAP_REASON.to_string(),
            requested_at: now,
            updated_at: now,
            previous_epoch: 1,
            previous_provider_account_id: active.account_id.clone(),
            detail: None,
            rotation_operations: Vec::new(),
        };
        self.commit(record.clone())?;
        Ok(record)
    }

    pub fn reject_stale_request_before_io(
        &self,
        request_id: Uuid,
        expected_epoch: u64,
    ) -> Result<()> {
        match self.record.as_ref() {
            Some(current)
                if request_id != current.request_id && expected_epoch != current.epoch =>
            {
                bail!(
                    "stale pool-authority epoch: expected {}, current {}",
                    expected_epoch,
                    current.epoch
                );
            }
            None if expected_epoch != 1 => {
                bail!(
                    "stale pool-authority epoch: expected {}, bootstrap epoch is 1",
                    expected_epoch
                );
            }
            _ => Ok(()),
        }
    }

    pub fn begin_target_request(
        &mut self,
        target_provider_account_id: &str,
        request_id: Uuid,
        expected_epoch: u64,
        reason: &str,
    ) -> Result<(TargetRequestDisposition, PoolAuthorityRecord)> {
        validate_provider_account_id(target_provider_account_id)?;
        validate_reason(reason)?;
        let current = self.require_record()?.clone();

        if request_id == current.request_id {
            if target_provider_account_id != current.desired_provider_account_id
                || reason != current.reason
            {
                bail!("pool-authority request ID was reused with different request content");
            }
            return Ok((TargetRequestDisposition::Replay, current));
        }
        if expected_epoch != current.epoch {
            bail!(
                "stale pool-authority epoch: expected {}, current {}",
                expected_epoch,
                current.epoch
            );
        }

        match current.phase {
            PoolAuthorityPhase::Stable
                if target_provider_account_id == current.desired_provider_account_id =>
            {
                let now = Utc::now();
                let mut stable = current;
                stable.request_id = request_id;
                stable.reason = reason.to_string();
                stable.requested_at = now;
                stable.updated_at = now;
                stable.previous_epoch = stable.epoch;
                stable.previous_provider_account_id = stable.desired_provider_account_id.clone();
                stable.detail = None;
                self.commit(stable.clone())?;
                Ok((TargetRequestDisposition::AlreadyStable, stable))
            }
            PoolAuthorityPhase::Stable => {
                let epoch = current
                    .epoch
                    .checked_add(1)
                    .context("pool-authority epoch overflow")?;
                let now = Utc::now();
                let converging = PoolAuthorityRecord {
                    version: POOL_AUTHORITY_VERSION,
                    epoch,
                    phase: PoolAuthorityPhase::Converging,
                    desired_provider_account_id: target_provider_account_id.to_string(),
                    request_id,
                    reason: reason.to_string(),
                    requested_at: now,
                    updated_at: now,
                    previous_epoch: current.epoch,
                    previous_provider_account_id: current.desired_provider_account_id,
                    detail: None,
                    rotation_operations: current.rotation_operations,
                };
                self.commit(converging.clone())?;
                Ok((TargetRequestDisposition::Started, converging))
            }
            PoolAuthorityPhase::Converging | PoolAuthorityPhase::Degraded
                if target_provider_account_id == current.desired_provider_account_id =>
            {
                Ok((TargetRequestDisposition::RecoverSameTarget, current))
            }
            PoolAuthorityPhase::Converging | PoolAuthorityPhase::Degraded => bail!(
                "pool authority epoch {} is {:?} for {}; cross-target request is blocked",
                current.epoch,
                current.phase,
                current.desired_provider_account_id
            ),
        }
    }

    pub fn mark_converging(&mut self, detail: Option<&str>) -> Result<PoolAuthorityRecord> {
        self.update_phase(PoolAuthorityPhase::Converging, detail)
    }

    pub fn mark_stable(&mut self) -> Result<PoolAuthorityRecord> {
        self.update_phase(PoolAuthorityPhase::Stable, None)
    }

    pub fn mark_degraded(&mut self, detail: &str) -> Result<PoolAuthorityRecord> {
        self.update_phase(PoolAuthorityPhase::Degraded, Some(detail))
    }

    pub fn begin_rotation_operation(
        &mut self,
        operation_id: Uuid,
        reason: &str,
        cooldown_seconds: i64,
        allow_banked_reset: bool,
    ) -> Result<(RotationOperationDisposition, PoolRotationOperation)> {
        validate_reason(reason)?;
        if operation_id.is_nil() {
            bail!("rotation operation ID must not be nil");
        }
        if !(0..=MAX_ROTATION_COOLDOWN_SECONDS).contains(&cooldown_seconds) {
            bail!("rotation operation cooldown is outside the supported range");
        }

        let mut record = self.require_record()?.clone();
        if let Some(existing) = record
            .rotation_operations
            .iter()
            .find(|operation| operation.operation_id == operation_id)
        {
            if existing.reason != reason
                || existing.cooldown_seconds != cooldown_seconds
                || existing.allow_banked_reset != allow_banked_reset
            {
                bail!("rotation operation ID was reused with different request content");
            }
        }
        if reconcile_superseded_non_reset_rotation(&mut record) {
            self.commit(record.clone())?;
        }
        if let Some(existing) = record
            .rotation_operations
            .iter()
            .find(|operation| operation.operation_id == operation_id)
        {
            let disposition = match existing.phase {
                PoolRotationOperationPhase::Started => RotationOperationDisposition::Recover,
                PoolRotationOperationPhase::Completed => RotationOperationDisposition::Replay,
            };
            return Ok((disposition, existing.clone()));
        }
        if let Some(pending) = record
            .rotation_operations
            .iter()
            .find(|operation| operation.phase == PoolRotationOperationPhase::Started)
        {
            bail!(
                "rotation operation {} remains incomplete; a different operation is blocked",
                pending.operation_id
            );
        }

        let now = Utc::now();
        let operation = PoolRotationOperation {
            operation_id,
            phase: PoolRotationOperationPhase::Started,
            reason: reason.to_string(),
            cooldown_seconds,
            allow_banked_reset,
            started_at: now,
            updated_at: now,
            target_provider_account_id: None,
            used_banked_reset: None,
            banked_resets_remaining: None,
            reset_reason: None,
        };
        while record.rotation_operations.len() >= ROTATION_OPERATION_HISTORY_LIMIT {
            let removable = record
                .rotation_operations
                .iter()
                .position(|entry| entry.phase == PoolRotationOperationPhase::Completed)
                .context("rotation operation history is full with no completed entry to prune")?;
            record.rotation_operations.remove(removable);
        }
        record.rotation_operations.push(operation.clone());
        self.commit(record)?;
        Ok((RotationOperationDisposition::Started, operation))
    }

    pub fn complete_rotation_operation(
        &mut self,
        operation_id: Uuid,
        target_provider_account_id: &str,
        used_banked_reset: bool,
        banked_resets_remaining: Option<u32>,
        reset_reason: Option<&str>,
    ) -> Result<PoolRotationOperation> {
        validate_provider_account_id(target_provider_account_id)?;
        if let Some(reason) = reset_reason {
            validate_reason(reason)?;
        }
        let mut record = self.require_record()?.clone();
        let operation = record
            .rotation_operations
            .iter_mut()
            .find(|operation| operation.operation_id == operation_id)
            .context("rotation operation is not journaled")?;
        if operation.phase == PoolRotationOperationPhase::Completed {
            if operation.target_provider_account_id.as_deref() != Some(target_provider_account_id)
                || operation.used_banked_reset != Some(used_banked_reset)
                || operation.banked_resets_remaining != banked_resets_remaining
                || operation.reset_reason.as_deref() != reset_reason
            {
                bail!("completed rotation operation does not match replayed outcome");
            }
            return Ok(operation.clone());
        }
        operation.phase = PoolRotationOperationPhase::Completed;
        operation.updated_at = Utc::now();
        operation.target_provider_account_id = Some(target_provider_account_id.to_string());
        operation.used_banked_reset = Some(used_banked_reset);
        operation.banked_resets_remaining = banked_resets_remaining;
        operation.reset_reason = reset_reason.map(str::to_string);
        let completed = operation.clone();
        self.commit(record)?;
        Ok(completed)
    }

    fn update_phase(
        &mut self,
        phase: PoolAuthorityPhase,
        detail: Option<&str>,
    ) -> Result<PoolAuthorityRecord> {
        let detail = detail.map(sanitize_detail);
        let mut record = self.require_record()?.clone();
        record.phase = phase;
        record.detail = detail;
        record.updated_at = Utc::now();
        if phase == PoolAuthorityPhase::Stable {
            reconcile_superseded_non_reset_rotation(&mut record);
        }
        self.commit(record.clone())?;
        Ok(record)
    }

    fn commit(&mut self, record: PoolAuthorityRecord) -> Result<()> {
        validate_record(&record)?;
        let data = serde_json::to_vec_pretty(&record)
            .context("failed to encode pool-authority journal")?;
        let committed = self
            .file
            .commit(&self.generation, &data, POOL_AUTHORITY_MAX_BYTES)
            .context("failed to commit pool-authority journal")?;
        let readback = decode_record(committed.bytes())?
            .context("pool-authority journal disappeared after commit")?;
        if readback != record {
            bail!("pool-authority journal readback did not match committed record");
        }
        self.generation = committed.generation().clone();
        self.record = Some(readback);
        Ok(())
    }
}

pub fn observe_status(store_path: &Path) -> Result<Option<PoolAuthorityStatus>> {
    let snapshot = secure_file::observe(
        &pool_authority_path(store_path),
        POOL_AUTHORITY_MAX_BYTES,
        true,
    )
    .context("failed to observe pool-authority journal")?;
    Ok(decode_record(snapshot.bytes())?.as_ref().map(Into::into))
}

pub fn pool_authority_path(store_path: &Path) -> PathBuf {
    store_path.with_file_name("pool-authority.json")
}

pub fn parse_reason(value: &str) -> std::result::Result<String, String> {
    validate_reason(value)
        .map(|()| value.to_string())
        .map_err(|error| error.to_string())
}

pub fn parse_selector(value: &str) -> std::result::Result<String, String> {
    validate_bounded_text(value, PROVIDER_ACCOUNT_ID_MAX_BYTES, "account selector")
        .map(|()| value.to_string())
        .map_err(|error| error.to_string())
}

fn decode_record(bytes: Option<&[u8]>) -> Result<Option<PoolAuthorityRecord>> {
    let Some(bytes) = bytes else {
        return Ok(None);
    };
    let record: PoolAuthorityRecord =
        serde_json::from_slice(bytes).context("failed to decode pool-authority journal")?;
    validate_record(&record)?;
    Ok(Some(record))
}

fn validate_record(record: &PoolAuthorityRecord) -> Result<()> {
    if record.version != POOL_AUTHORITY_VERSION {
        bail!(
            "unsupported pool-authority journal version {}",
            record.version
        );
    }
    if record.epoch == 0 {
        bail!("pool-authority epoch must be positive");
    }
    if record.previous_epoch == 0 || record.previous_epoch > record.epoch {
        bail!("pool-authority previous epoch is invalid");
    }
    validate_provider_account_id(&record.desired_provider_account_id)?;
    validate_provider_account_id(&record.previous_provider_account_id)?;
    validate_reason(&record.reason)?;
    if let Some(detail) = record.detail.as_deref() {
        validate_detail(detail)?;
    }
    if record.rotation_operations.len() > ROTATION_OPERATION_HISTORY_LIMIT {
        bail!("pool-authority rotation operation history is oversized");
    }
    let mut started_count = 0;
    let mut operation_ids = std::collections::HashSet::new();
    for operation in &record.rotation_operations {
        if !operation_ids.insert(operation.operation_id) {
            bail!("pool-authority rotation operation IDs are not unique");
        }
        validate_rotation_operation(operation)?;
        if operation.phase == PoolRotationOperationPhase::Started {
            started_count += 1;
        }
    }
    if started_count > 1 {
        bail!("pool-authority has multiple incomplete rotation operations");
    }
    if record.updated_at < record.requested_at {
        bail!("pool-authority timestamps are inconsistent");
    }
    Ok(())
}

fn reconcile_superseded_non_reset_rotation(record: &mut PoolAuthorityRecord) -> bool {
    if record.phase != PoolAuthorityPhase::Stable {
        return false;
    }
    let Some(operation) = record
        .rotation_operations
        .iter_mut()
        .find(|operation| operation.phase == PoolRotationOperationPhase::Started)
    else {
        return false;
    };
    if operation.allow_banked_reset
        || record.request_id == operation.operation_id
        || record.requested_at <= operation.started_at
        || record.previous_provider_account_id == record.desired_provider_account_id
    {
        return false;
    }

    operation.phase = PoolRotationOperationPhase::Completed;
    operation.updated_at = Utc::now();
    operation.target_provider_account_id = Some(record.desired_provider_account_id.clone());
    operation.used_banked_reset = Some(false);
    operation.banked_resets_remaining = None;
    operation.reset_reason = None;
    true
}

fn validate_rotation_operation(operation: &PoolRotationOperation) -> Result<()> {
    if operation.operation_id.is_nil() {
        bail!("rotation operation ID must not be nil");
    }
    validate_reason(&operation.reason)?;
    if !(0..=MAX_ROTATION_COOLDOWN_SECONDS).contains(&operation.cooldown_seconds) {
        bail!("rotation operation cooldown is outside the supported range");
    }
    if operation.updated_at < operation.started_at {
        bail!("rotation operation timestamps are inconsistent");
    }
    if let Some(provider_id) = operation.target_provider_account_id.as_deref() {
        validate_provider_account_id(provider_id)?;
    }
    if let Some(reason) = operation.reset_reason.as_deref() {
        validate_reason(reason)?;
    }
    match operation.phase {
        PoolRotationOperationPhase::Started => {
            if operation.target_provider_account_id.is_some()
                || operation.used_banked_reset.is_some()
                || operation.banked_resets_remaining.is_some()
                || operation.reset_reason.is_some()
            {
                bail!("started rotation operation contains terminal outcome fields");
            }
        }
        PoolRotationOperationPhase::Completed => {
            if operation.target_provider_account_id.is_none()
                || operation.used_banked_reset.is_none()
            {
                bail!("completed rotation operation is missing outcome fields");
            }
            if operation.used_banked_reset == Some(false) && operation.reset_reason.is_some() {
                bail!("non-reset rotation operation contains a reset reason");
            }
        }
    }
    Ok(())
}

fn validate_provider_account_id(value: &str) -> Result<()> {
    validate_bounded_text(value, PROVIDER_ACCOUNT_ID_MAX_BYTES, "provider account ID")
}

fn validate_reason(value: &str) -> Result<()> {
    validate_bounded_text(value, REASON_MAX_BYTES, "pool-authority reason")
}

fn validate_detail(value: &str) -> Result<()> {
    validate_bounded_text(value, DETAIL_MAX_BYTES, "pool-authority detail")
}

fn sanitize_detail(value: &str) -> String {
    let normalized: String = value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    let normalized = normalized.trim();
    let normalized = if normalized.is_empty() {
        "No diagnostic detail was provided"
    } else {
        normalized
    };
    if normalized.len() <= DETAIL_MAX_BYTES {
        return normalized.to_string();
    }
    let mut end = DETAIL_MAX_BYTES;
    while !normalized.is_char_boundary(end) {
        end -= 1;
    }
    normalized[..end].to_string()
}

fn validate_bounded_text(value: &str, max_bytes: usize, label: &str) -> Result<()> {
    if value.trim().is_empty() {
        bail!("{label} must not be empty");
    }
    if value.len() > max_bytes {
        bail!("{label} exceeds {max_bytes} bytes");
    }
    if value.chars().any(char::is_control) {
        bail!("{label} contains control characters");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{save_accounts, CodexAccount};
    use crate::activation::acquire_runtime_activation_lease;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn secure_temp_dir() -> Result<TempDir> {
        let temp = TempDir::new()?;
        std::fs::set_permissions(temp.path(), std::fs::Permissions::from_mode(0o700))?;
        Ok(temp)
    }

    fn account(email: &str, active: bool) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: email.to_string(),
            access_token: format!("access-{email}"),
            refresh_token: format!("refresh-{email}"),
            id_token: format!("identity-{email}"),
            account_id: format!("provider-{email}"),
            is_active: active,
            plan_type: Some("pro".to_string()),
            quota_snapshot: None,
            last_refreshed: None,
            five_hour_primed_at: None,
            rate_limit_reset_bank: None,
            runtime_unusable_reason: None,
            runtime_unusable_until: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: None,
        }
    }

    #[test]
    fn bootstrap_and_replay_do_not_advance_epoch_twice() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        let target = account("target@example.com", false);
        save_accounts(&store_path, &[active.clone(), target.clone()])?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        let bootstrapped = authority.bootstrap_from_active(&[active.clone(), target.clone()])?;
        assert_eq!(bootstrapped.epoch, 1);
        assert_eq!(bootstrapped.phase, PoolAuthorityPhase::Stable);

        let request_id = Uuid::new_v4();
        let (disposition, started) =
            authority.begin_target_request(&target.account_id, request_id, 1, "manual")?;
        assert_eq!(disposition, TargetRequestDisposition::Started);
        assert_eq!(started.epoch, 2);

        let (disposition, replayed) =
            authority.begin_target_request(&target.account_id, request_id, 1, "manual")?;
        assert_eq!(disposition, TargetRequestDisposition::Replay);
        assert_eq!(replayed.epoch, 2);
        Ok(())
    }

    #[test]
    fn stale_epoch_rejects_without_mutating_journal() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        let target = account("target@example.com", false);
        save_accounts(&store_path, &[active.clone(), target.clone()])?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        authority.bootstrap_from_active(&[active, target.clone()])?;
        let before = authority.require_record()?.clone();

        let error = authority
            .begin_target_request(&target.account_id, Uuid::new_v4(), 0, "manual")
            .unwrap_err();
        assert!(error.to_string().contains("stale pool-authority epoch"));
        assert_eq!(authority.require_record()?, &before);
        Ok(())
    }

    #[test]
    fn status_serializes_server_observation_separately_from_transition_time() -> Result<()> {
        let transition_time = Utc::now() - chrono::Duration::days(3);
        let record = PoolAuthorityRecord {
            version: POOL_AUTHORITY_VERSION,
            epoch: 7,
            phase: PoolAuthorityPhase::Stable,
            desired_provider_account_id: "provider-active".to_string(),
            request_id: Uuid::new_v4(),
            reason: "manual".to_string(),
            requested_at: transition_time,
            updated_at: transition_time,
            previous_epoch: 6,
            previous_provider_account_id: "provider-previous".to_string(),
            detail: None,
            rotation_operations: Vec::new(),
        };

        let status = PoolAuthorityStatus::from(&record);
        let encoded = serde_json::to_value(&status)?;
        let object = encoded
            .as_object()
            .context("pool-authority status did not serialize as an object")?;
        for required in [
            "epoch",
            "phase",
            "desiredProviderAccountId",
            "requestId",
            "reason",
            "observedAt",
            "updatedAt",
            "previousProviderAccountId",
        ] {
            assert!(
                object.contains_key(required),
                "missing status field {required}"
            );
        }
        assert!(!object.contains_key("detail"));
        assert!(!object.contains_key("requestedAt"));
        assert!(!object.contains_key("previousEpoch"));
        let encoded_updated_at = encoded["updatedAt"]
            .as_str()
            .context("updatedAt was not serialized as an RFC3339 string")?
            .parse::<DateTime<Utc>>()?;
        assert_eq!(encoded_updated_at, transition_time);
        assert!(encoded["observedAt"].is_string());
        assert!(status.observed_at > status.updated_at);
        Ok(())
    }

    #[test]
    fn observing_status_refreshes_observed_at_without_mutating_journal() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        let record = authority.bootstrap_from_active(std::slice::from_ref(&active))?;
        drop(authority);
        drop(runtime_lease);
        let journal_path = pool_authority_path(&store_path);
        let journal_before = std::fs::read(&journal_path)?;

        let first = observe_status(&store_path)?.context("first status observation was absent")?;
        std::thread::sleep(std::time::Duration::from_millis(2));
        let second =
            observe_status(&store_path)?.context("second status observation was absent")?;

        assert_eq!(first.updated_at, record.updated_at);
        assert_eq!(second.updated_at, record.updated_at);
        assert!(second.observed_at > first.observed_at);
        assert_eq!(std::fs::read(&journal_path)?, journal_before);
        Ok(())
    }

    #[test]
    fn stale_preflight_rejects_before_bootstrap() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;

        let error = authority
            .reject_stale_request_before_io(Uuid::new_v4(), 9)
            .unwrap_err();
        assert!(error.to_string().contains("bootstrap epoch is 1"));
        assert!(!pool_authority_path(&store_path).exists());
        Ok(())
    }

    #[test]
    fn newer_stable_request_completes_superseded_non_reset_rotation() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        let target = account("target@example.com", false);
        save_accounts(&store_path, &[active.clone(), target.clone()])?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        authority.bootstrap_from_active(&[active, target.clone()])?;

        let operation_id = Uuid::new_v4();
        authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, false)?;
        std::thread::sleep(std::time::Duration::from_millis(2));
        let manual_request_id = Uuid::new_v4();
        authority.begin_target_request(
            &target.account_id,
            manual_request_id,
            1,
            "swift_manual_selection",
        )?;
        authority.mark_stable()?;

        let before_invalid_replay = authority.require_record()?.clone();
        assert_eq!(
            before_invalid_replay.rotation_operations[0].phase,
            PoolRotationOperationPhase::Completed,
            "stable cross-target convergence must resolve the older operation atomically"
        );
        let error = authority
            .begin_rotation_operation(operation_id, "token_invalidated", 18_000, false)
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("reused with different request content"));
        assert_eq!(
            authority.require_record()?,
            &before_invalid_replay,
            "invalid operation reuse must not perform supersession recovery"
        );

        let (disposition, operation) =
            authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, false)?;
        assert_eq!(disposition, RotationOperationDisposition::Replay);
        assert_eq!(operation.phase, PoolRotationOperationPhase::Completed);
        assert_eq!(
            operation.target_provider_account_id.as_deref(),
            Some(target.account_id.as_str())
        );
        assert_eq!(operation.used_banked_reset, Some(false));
        assert_eq!(
            authority.require_record()?.request_id,
            manual_request_id,
            "operation reconciliation must not replace newer authority"
        );

        let next_operation_id = Uuid::new_v4();
        let (disposition, next) = authority.begin_rotation_operation(
            next_operation_id,
            "token_invalidated",
            300,
            false,
        )?;
        assert_eq!(disposition, RotationOperationDisposition::Started);
        assert_eq!(next.operation_id, next_operation_id);
        Ok(())
    }

    #[test]
    fn newer_stable_request_does_not_guess_reset_capable_operation_outcome() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        let target = account("target@example.com", false);
        save_accounts(&store_path, &[active.clone(), target.clone()])?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        authority.bootstrap_from_active(&[active, target.clone()])?;

        let operation_id = Uuid::new_v4();
        authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, true)?;
        std::thread::sleep(std::time::Duration::from_millis(2));
        authority.begin_target_request(
            &target.account_id,
            Uuid::new_v4(),
            1,
            "swift_manual_selection",
        )?;
        authority.mark_stable()?;

        let error = authority
            .begin_rotation_operation(Uuid::new_v4(), "token_invalidated", 300, false)
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("remains incomplete; a different operation is blocked"));
        let (disposition, operation) =
            authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, true)?;
        assert_eq!(disposition, RotationOperationDisposition::Recover);
        assert_eq!(operation.phase, PoolRotationOperationPhase::Started);
        Ok(())
    }

    #[test]
    fn newer_same_target_request_does_not_complete_non_reset_rotation() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        let runtime_lease = acquire_runtime_activation_lease(&store_path)?;
        let mut authority =
            PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, &store_path)?;
        authority.bootstrap_from_active(std::slice::from_ref(&active))?;

        let operation_id = Uuid::new_v4();
        authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, false)?;
        std::thread::sleep(std::time::Duration::from_millis(2));
        let (disposition, _) = authority.begin_target_request(
            &active.account_id,
            Uuid::new_v4(),
            1,
            "swift_manual_selection",
        )?;
        assert_eq!(disposition, TargetRequestDisposition::AlreadyStable);

        let (disposition, operation) =
            authority.begin_rotation_operation(operation_id, "usage_limit", 18_000, false)?;
        assert_eq!(disposition, RotationOperationDisposition::Recover);
        assert_eq!(operation.phase, PoolRotationOperationPhase::Started);
        Ok(())
    }
}

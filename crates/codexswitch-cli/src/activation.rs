use crate::account_store::{
    activate_account, active_account, commit_accounts, AccountStoreGeneration, AccountStoreLock,
    AccountStoreSnapshot, CodexAccount,
};
use crate::auth::{
    account_token_fingerprint, auth_file_fingerprint, auth_file_generation,
    auth_file_matches_account, auth_file_matches_snapshot, capture_auth_file, commit_auth_file,
    restore_auth_file_if_owned, AuthFileCommit, AuthFileSnapshot,
};
use crate::reload::{ActivationReloadBinding, ReloadSummary};
use crate::secure_file::{self, SecureFileGeneration};
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivationState {
    Prepared,
    Confirmed,
    FileOnly,
    CommittedDegraded,
    RolledBack,
    ManualReview,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivationKind {
    Rotation,
    Import,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivationRecord {
    #[serde(default)]
    pub version: u32,
    pub state: ActivationState,
    #[serde(default)]
    pub kind: ActivationKind,
    pub previous_account_id: String,
    pub target_account_id: String,
    pub store_generation: String,
    pub auth_fingerprint: Option<String>,
    #[serde(default)]
    pub base_store_generation: Option<String>,
    #[serde(default)]
    pub owned_store_generation: Option<String>,
    #[serde(default)]
    pub base_auth_generation: Option<SecureFileGeneration>,
    #[serde(default)]
    pub owned_auth_generation: Option<SecureFileGeneration>,
    #[serde(default)]
    pub rollback: Option<ActivationRollbackImage>,
    pub detail: Option<String>,
    pub updated_at: DateTime<Utc>,
}

const ACTIVATION_RECORD_VERSION: u32 = 3;
const ACTIVATION_RECORD_MAX_BYTES: usize = 1024 * 1024;
pub(crate) const LEGACY_DEGRADED_TOKEN_MISMATCH: &str =
    "degraded activation no longer matches the intended store/auth token set; manual review is required";

fn complete_account_token_fingerprint(account: &CodexAccount) -> Option<String> {
    account
        .has_complete_token_material()
        .then(|| account_token_fingerprint(account))
        .flatten()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivationRollbackImage {
    store_bytes: Option<Vec<u8>>,
    auth: AuthFileSnapshot,
}

#[derive(Debug, Clone)]
pub struct ActivationOutcome {
    pub state: ActivationState,
    pub reload: ReloadSummary,
    pub detail: Option<String>,
}

impl ActivationOutcome {
    pub fn is_confirmed(&self) -> bool {
        self.state == ActivationState::Confirmed
            && self.reload.verified_hot_swap()
            && self.reload.has_bound_activation_proof()
    }

    pub fn is_file_only(&self) -> bool {
        self.state == ActivationState::FileOnly
    }
}

pub struct ActivationContext<'a> {
    pub store_lock: &'a AccountStoreLock,
    pub generation: &'a mut AccountStoreGeneration,
    pub accounts: &'a mut [CodexAccount],
    pub auth_path: &'a Path,
    pub target_id: Uuid,
    pub reload_enabled: bool,
}

pub struct ActivationBarrierContext<'a> {
    pub store_lock: &'a AccountStoreLock,
    pub generation: &'a mut AccountStoreGeneration,
    pub accounts: &'a mut [CodexAccount],
    pub auth_path: &'a Path,
    pub reload_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActivationJournalIdentity {
    generation: SecureFileGeneration,
    file_identity: Option<(u64, u64)>,
    modified_unix: Option<(i64, u32)>,
}

#[derive(Debug, Clone)]
pub(crate) struct ProviderIoActivationGuard {
    store_generation: AccountStoreGeneration,
    journal: ActivationJournalIdentity,
}

#[derive(Debug, Clone)]
pub(crate) struct ProviderIoActivationSnapshot {
    pub accounts: Vec<CodexAccount>,
    pub generation: AccountStoreGeneration,
    pub guard: ProviderIoActivationGuard,
}

#[derive(Debug)]
struct ObservedActivationRecord {
    record: Option<ActivationRecord>,
    identity: ActivationJournalIdentity,
}

#[derive(Debug, Clone)]
enum ObservedReload {
    Success(ReloadSummary),
    Failure {
        summary: ReloadSummary,
        error: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingActivationIdentity {
    target_account_id: String,
    state: ActivationState,
    kind: ActivationKind,
    journal_auth_fingerprint: Option<String>,
    binding: ActivationReloadBinding,
}

impl ObservedReload {
    fn capture_with_topology<R, T>(
        auth_path: &Path,
        expected: &ActivationReloadBinding,
        reload: &R,
        revalidate_topology: T,
    ) -> Self
    where
        R: Fn(&Path) -> Result<ReloadSummary>,
        T: Fn(&ReloadSummary, &Path) -> Result<()>,
    {
        let mut summary = match reload(auth_path) {
            Ok(summary) => summary,
            Err(error) => {
                return Self::Failure {
                    summary: ReloadSummary::default(),
                    error: format!("{error:#}"),
                };
            }
        };
        if let Err(error) = summary
            .bind_activation(expected)
            .and_then(|()| revalidate_topology(&summary, auth_path))
        {
            return Self::Failure {
                summary,
                error: format!("{error:#}"),
            };
        }
        Self::Success(summary)
    }
}

pub fn reconcile_activation_barrier<R>(
    context: ActivationBarrierContext<'_>,
    mut reload: R,
) -> Result<Option<ActivationOutcome>>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    reconcile_activation_barrier_with(context, &mut reload)
        .map(|resolution| resolution.map(|(_, outcome)| outcome))
}

fn activation_reload_binding(
    generation: &AccountStoreGeneration,
    auth_path: &Path,
    expected_fingerprint: &str,
) -> Result<ActivationReloadBinding> {
    let auth_generation = auth_file_generation(auth_path)
        .context("activation auth secure-file generation is unavailable")?;
    let auth_fingerprint = auth_file_fingerprint(auth_path)
        .context("activation auth file has incomplete token material")?;
    let stable_auth_generation = auth_file_generation(auth_path)
        .context("activation auth secure-file generation disappeared during observation")?;
    if stable_auth_generation != auth_generation {
        bail!("activation auth file changed during generation/fingerprint observation");
    }
    if auth_fingerprint != expected_fingerprint {
        bail!("activation auth fingerprint changed before runtime reload");
    }
    Ok(ActivationReloadBinding {
        store_generation: generation.as_str().to_string(),
        auth_generation,
        complete_token_fingerprint: auth_fingerprint,
    })
}

fn pending_activation_identity(
    store_lock: &AccountStoreLock,
    auth_path: &Path,
    allowed_states: &[ActivationState],
) -> Result<PendingActivationIdentity> {
    let record = read_activation_record(store_lock)?
        .context("activation record disappeared while preparing runtime convergence")?;
    if !allowed_states.contains(&record.state) {
        bail!("activation record is not in the expected convergence state");
    }
    if record.version != ACTIVATION_RECORD_VERSION || record.kind == ActivationKind::Unknown {
        bail!("activation record lacks a current version and explicit activation kind");
    }
    let snapshot = store_lock.load()?;
    if record.store_generation != snapshot.generation.as_str() {
        bail!("activation journal/store generation diverged before runtime reload");
    }
    let active = active_account(&snapshot.accounts)
        .context("activation convergence requires exactly one active account")?;
    if active.account_id != record.target_account_id {
        bail!("activation journal target is not the active store account");
    }
    let active_fingerprint = complete_account_token_fingerprint(active)
        .context("active store account has incomplete token material")?;
    if record.state != ActivationState::ManualReview
        && record.auth_fingerprint.as_deref() != Some(active_fingerprint.as_str())
    {
        bail!("activation journal fingerprint does not match the active store account");
    }
    let binding = activation_reload_binding(&snapshot.generation, auth_path, &active_fingerprint)?;
    Ok(PendingActivationIdentity {
        target_account_id: record.target_account_id,
        state: record.state,
        kind: record.kind,
        journal_auth_fingerprint: record.auth_fingerprint,
        binding,
    })
}

fn ensure_pending_activation_unchanged(
    store_lock: &AccountStoreLock,
    auth_path: &Path,
    expected: &PendingActivationIdentity,
) -> Result<()> {
    let current = pending_activation_identity(store_lock, auth_path, &[expected.state])?;
    if &current != expected {
        bail!(
            "activation generation or store/auth identity changed while runtime reload was in flight; preserving the newer state"
        );
    }
    Ok(())
}

fn finalize_pending_activation(
    store_lock: &AccountStoreLock,
    auth_path: &Path,
    expected: &PendingActivationIdentity,
    observed: ObservedReload,
    confirmed_detail: Option<String>,
) -> Result<(ActivationOutcome, AccountStoreSnapshot)> {
    ensure_pending_activation_unchanged(store_lock, auth_path, expected)?;
    let snapshot = store_lock.load()?;
    let mut record = read_activation_record(store_lock)?
        .context("activation record disappeared before final confirmation CAS")?;

    let (state, summary, detail) = match observed {
        ObservedReload::Success(summary) => {
            if !summary.proves_activation(&expected.binding) {
                bail!("runtime evidence lost its exact activation binding before publication");
            }
            (ActivationState::Confirmed, summary, confirmed_detail)
        }
        ObservedReload::Failure { summary, error } => (
            ActivationState::CommittedDegraded,
            summary,
            Some(format!(
                "runtime convergence failed before final activation confirmation: {error}"
            )),
        ),
    };

    record.state = state;
    record.store_generation = expected.binding.store_generation.clone();
    record.auth_fingerprint = Some(expected.binding.complete_token_fingerprint.clone());
    record.detail = detail.clone();
    if state == ActivationState::Confirmed {
        record.base_store_generation = None;
        record.owned_store_generation = None;
        record.base_auth_generation = None;
        record.owned_auth_generation = None;
        record.rollback = None;
    }
    record.updated_at = Utc::now();
    write_activation_record(store_lock, &record)?;
    Ok((
        ActivationOutcome {
            state,
            reload: summary,
            detail,
        },
        snapshot,
    ))
}

fn converge_pending_activation_unlocked_with<R, T>(
    store_path: &Path,
    auth_path: &Path,
    expected: PendingActivationIdentity,
    reload: &R,
    revalidate_topology: T,
    confirmed_detail: Option<String>,
) -> Result<(ActivationOutcome, AccountStoreSnapshot)>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
    T: Fn(&ReloadSummary, &Path) -> Result<()>,
{
    let observed = ObservedReload::capture_with_topology(
        auth_path,
        &expected.binding,
        reload,
        revalidate_topology,
    );
    let store_lock = crate::account_store::lock_account_store(store_path)?;
    finalize_pending_activation(
        &store_lock,
        auth_path,
        &expected,
        observed,
        confirmed_detail,
    )
}

pub(crate) fn reconcile_activation_barrier_unlocked<R>(
    store_path: &Path,
    auth_path: &Path,
    reload_enabled: bool,
    reload: &R,
) -> Result<Option<ActivationOutcome>>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    reconcile_activation_barrier_unlocked_with_topology(
        store_path,
        auth_path,
        reload_enabled,
        reload,
        |summary, path| summary.revalidate_current_topology(path),
    )
}

fn reconcile_activation_barrier_unlocked_with_topology<R, T>(
    store_path: &Path,
    auth_path: &Path,
    reload_enabled: bool,
    reload: &R,
    revalidate_topology: T,
) -> Result<Option<ActivationOutcome>>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
    T: Fn(&ReloadSummary, &Path) -> Result<()>,
{
    let prepared = {
        let store_lock = crate::account_store::lock_account_store(store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let outcome = reconcile_activation_barrier(
            ActivationBarrierContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path,
                reload_enabled: false,
            },
            |_| bail!("runtime reload was requested during locked activation preparation"),
        )?;
        match outcome {
            Some(outcome) => Some((
                outcome,
                pending_activation_identity(
                    &store_lock,
                    auth_path,
                    &[
                        ActivationState::FileOnly,
                        ActivationState::CommittedDegraded,
                    ],
                )?,
            )),
            None => None,
        }
    };
    let Some((prepared, expected_identity)) = prepared else {
        return Ok(None);
    };
    if prepared.is_confirmed() || !reload_enabled {
        return Ok(Some(prepared));
    }

    converge_pending_activation_unlocked_with(
        store_path,
        auth_path,
        expected_identity,
        reload,
        revalidate_topology,
        None,
    )
    .map(|(outcome, _)| Some(outcome))
}

pub(crate) fn activate_with_unlocked_reload<R>(
    store_path: &Path,
    auth_path: &Path,
    generation: &mut AccountStoreGeneration,
    accounts: &mut [CodexAccount],
    target_id: Uuid,
    reload_enabled: bool,
    reload: &R,
) -> Result<ActivationOutcome>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    activate_with_unlocked_reload_with_topology(
        store_path,
        auth_path,
        generation,
        accounts,
        target_id,
        reload_enabled,
        reload,
        |summary, path| summary.revalidate_current_topology(path),
    )
}

fn activate_with_unlocked_reload_with_topology<R, T>(
    store_path: &Path,
    auth_path: &Path,
    generation: &mut AccountStoreGeneration,
    accounts: &mut [CodexAccount],
    target_id: Uuid,
    reload_enabled: bool,
    reload: &R,
    revalidate_topology: T,
) -> Result<ActivationOutcome>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
    T: Fn(&ReloadSummary, &Path) -> Result<()>,
{
    let (prepared, expected_identity) = {
        let store_lock = crate::account_store::lock_account_store(store_path)?;
        let current = store_lock.load()?;
        if current.generation != *generation {
            bail!("account store changed before activation commit; retry from a fresh snapshot");
        }
        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation,
                accounts,
                auth_path,
                target_id,
                reload_enabled: false,
            },
            |_| bail!("runtime reload was requested during locked activation preparation"),
        )?;
        let identity = matches!(
            outcome.state,
            ActivationState::FileOnly | ActivationState::CommittedDegraded
        )
        .then(|| {
            pending_activation_identity(
                &store_lock,
                auth_path,
                &[
                    ActivationState::FileOnly,
                    ActivationState::CommittedDegraded,
                ],
            )
        })
        .transpose()?;
        (outcome, identity)
    };
    if !reload_enabled
        || !matches!(
            prepared.state,
            ActivationState::FileOnly | ActivationState::CommittedDegraded
        )
    {
        return Ok(prepared);
    }
    let expected_identity = expected_identity
        .context("activation record disappeared while preparing unlocked runtime convergence")?;
    let (outcome, snapshot) = converge_pending_activation_unlocked_with(
        store_path,
        auth_path,
        expected_identity,
        reload,
        revalidate_topology,
        None,
    )?;
    if snapshot.accounts.len() != accounts.len() {
        bail!(
            "account set changed while runtime reload was in flight; retry from a fresh snapshot"
        );
    }
    *generation = snapshot.generation;
    accounts.clone_from_slice(&snapshot.accounts);
    Ok(outcome)
}

pub(crate) fn resolve_manual_review_activation_unlocked<R>(
    store_path: &Path,
    auth_path: &Path,
    reload: &R,
) -> Result<ActivationOutcome>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    resolve_manual_review_activation_unlocked_with_topology(
        store_path,
        auth_path,
        reload,
        |summary, path| summary.revalidate_current_topology(path),
    )
}

fn resolve_manual_review_activation_unlocked_with_topology<R, T>(
    store_path: &Path,
    auth_path: &Path,
    reload: &R,
    revalidate_topology: T,
) -> Result<ActivationOutcome>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
    T: Fn(&ReloadSummary, &Path) -> Result<()>,
{
    let expected = {
        let store_lock = crate::account_store::lock_account_store(store_path)?;
        let record = read_activation_record(&store_lock)?
            .context("manual-review resolution requires an activation record")?;
        if record.state != ActivationState::ManualReview {
            bail!("activation record is {:?}, not manual_review", record.state);
        }
        if record.version != ACTIVATION_RECORD_VERSION {
            bail!(
                "manual-review resolution requires activation record version {}",
                ACTIVATION_RECORD_VERSION
            );
        }
        if record.kind == ActivationKind::Unknown {
            bail!("manual-review resolution requires an explicit activation kind");
        }
        pending_activation_identity(&store_lock, auth_path, &[ActivationState::ManualReview])?
    };

    let observed = ObservedReload::capture_with_topology(
        auth_path,
        &expected.binding,
        reload,
        revalidate_topology,
    );
    let acknowledgement_count = match &observed {
        ObservedReload::Success(summary) => summary.signaled.len(),
        ObservedReload::Failure { error, .. } => {
            bail!("manual-review runtime convergence failed: {error}")
        }
    };
    let detail = format!(
        "operator resolved manual review after {acknowledgement_count} verified runtime ACK(s)"
    );
    let store_lock = crate::account_store::lock_account_store(store_path)?;
    finalize_pending_activation(&store_lock, auth_path, &expected, observed, Some(detail))
        .map(|(outcome, _)| outcome)
}

pub fn resolve_manual_review_activation<R>(
    context: ActivationBarrierContext<'_>,
    mut reload: R,
) -> Result<ActivationOutcome>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let ActivationBarrierContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        reload_enabled,
    } = context;
    if !reload_enabled {
        bail!("manual-review resolution requires live runtime convergence");
    }

    let record = read_activation_record(store_lock)?
        .context("manual-review resolution requires an activation record")?;
    if record.state != ActivationState::ManualReview {
        bail!("activation record is {:?}, not manual_review", record.state);
    }
    if record.version != ACTIVATION_RECORD_VERSION {
        bail!(
            "manual-review resolution requires activation record version {}",
            ACTIVATION_RECORD_VERSION
        );
    }
    if record.kind == ActivationKind::Unknown {
        bail!("manual-review resolution requires an explicit activation kind");
    }

    let mut active_accounts = accounts.iter().filter(|account| account.is_active);
    let active = active_accounts
        .next()
        .context("manual-review resolution requires exactly one active account")?;
    if active_accounts.next().is_some() {
        bail!("manual-review resolution requires exactly one active account");
    }
    let active_fingerprint = complete_account_token_fingerprint(active)
        .context("manual-review resolution requires a complete active token set")?;

    verify_committed_activation(store_lock, generation, auth_path, active.id, active)
        .context("manual-review resolution refused divergent store/auth state")?;
    let expected = activation_reload_binding(generation, auth_path, &active_fingerprint)?;
    let summary = capture_activation_reload(&mut reload, auth_path, &expected)
        .context("manual-review runtime reload failed")?;
    verify_runtime_confirmation(
        &summary, &expected, store_lock, generation, auth_path, active.id, active,
    )
    .context("manual-review runtime convergence was not proven")?;

    let detail = format!(
        "operator resolved manual review after {} verified runtime ACK(s)",
        summary.signaled.len()
    );
    let mut confirmed = activation_record_ids(
        ActivationState::Confirmed,
        &record.previous_account_id,
        &active.account_id,
        generation,
        Some(active_fingerprint),
        Some(detail.clone()),
    );
    confirmed.kind = record.kind;
    write_activation_record(store_lock, &confirmed)?;

    Ok(ActivationOutcome {
        state: ActivationState::Confirmed,
        reload: summary,
        detail: Some(detail),
    })
}

pub fn activate_with<R>(context: ActivationContext<'_>, reload: R) -> Result<ActivationOutcome>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    activate_with_dependencies(context, commit_auth_file, reload)
}

fn activate_with_dependencies<A, R>(
    context: ActivationContext<'_>,
    mut commit_auth: A,
    mut reload: R,
) -> Result<ActivationOutcome>
where
    A: FnMut(&Path, &CodexAccount) -> Result<AuthFileCommit>,
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let ActivationContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        target_id,
        reload_enabled,
    } = context;
    if let Some((durable_target_id, outcome)) = reconcile_activation_barrier_with(
        ActivationBarrierContext {
            store_lock,
            generation,
            accounts,
            auth_path,
            reload_enabled,
        },
        &mut reload,
    )? {
        if !outcome.is_confirmed() || durable_target_id == target_id {
            return Ok(outcome);
        }
    }

    let previous_active = active_account(accounts)
        .context("activation requires one current active account")?
        .clone();
    let target = accounts
        .iter()
        .find(|account| account.id == target_id)
        .context("activation target disappeared")?
        .clone();
    let target_fingerprint = complete_account_token_fingerprint(&target)
        .context("activation target has incomplete token material")?;
    let previous_auth = capture_auth_file(auth_path)?;
    let base_snapshot = store_lock.load()?;
    if &base_snapshot.generation != generation {
        let detail = format!(
            "activation base generation changed before preparation; concurrent state was preserved (expected {}, found {})",
            generation.as_str(), base_snapshot.generation.as_str()
        );
        write_activation_record(
            store_lock,
            &activation_record(
                ActivationState::ManualReview,
                &previous_active,
                &target,
                &base_snapshot.generation,
                Some(target_fingerprint),
                Some(detail.clone()),
            ),
        )?;
        *generation = base_snapshot.generation;
        return Ok(ActivationOutcome {
            state: ActivationState::ManualReview,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }
    let rollback = ActivationRollbackImage {
        store_bytes: base_snapshot.raw_bytes().map(<[u8]>::to_vec),
        auth: previous_auth.clone(),
    };
    activate_account(accounts, target_id)?;
    let owned_store_generation = store_lock.prospective_generation(accounts)?;
    let mut prepared_record = ActivationRecord {
        version: ACTIVATION_RECORD_VERSION,
        state: ActivationState::Prepared,
        kind: ActivationKind::Rotation,
        previous_account_id: previous_active.account_id.clone(),
        target_account_id: target.account_id.clone(),
        store_generation: generation.as_str().to_string(),
        auth_fingerprint: Some(target_fingerprint.clone()),
        base_store_generation: Some(generation.as_str().to_string()),
        owned_store_generation: Some(owned_store_generation.as_str().to_string()),
        base_auth_generation: previous_auth.generation().cloned(),
        owned_auth_generation: None,
        rollback: Some(rollback.clone()),
        detail: None,
        updated_at: Utc::now(),
    };
    write_activation_record(store_lock, &prepared_record)?;

    if let Err(error) = commit_accounts(store_lock, generation, accounts) {
        let (state, detail) = rollback_after_commit_failure(
            ActivationRollbackContext {
                store_lock,
                generation,
                accounts,
                auth_path,
                rollback: &rollback,
                owned_store_generation: None,
                owned_auth_generation: None,
                previous_active: &previous_active,
                target: &target,
            },
            error.context("account store commit failed before auth commit"),
        )?;
        return Ok(ActivationOutcome {
            state,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    let auth_commit = match commit_auth(auth_path, &target) {
        Ok(commit) if commit.token_fingerprint == target_fingerprint => commit,
        Ok(_) => {
            let error = anyhow::anyhow!("auth commit returned an unexpected token fingerprint");
            let (state, detail) = rollback_after_commit_failure(
                ActivationRollbackContext {
                    store_lock,
                    generation,
                    accounts,
                    auth_path,
                    rollback: &rollback,
                    owned_store_generation: Some(&owned_store_generation),
                    owned_auth_generation: None,
                    previous_active: &previous_active,
                    target: &target,
                },
                error,
            )?;
            return Ok(ActivationOutcome {
                state,
                reload: ReloadSummary::default(),
                detail: Some(detail),
            });
        }
        Err(error) => {
            let (state, detail) = rollback_after_commit_failure(
                ActivationRollbackContext {
                    store_lock,
                    generation,
                    accounts,
                    auth_path,
                    rollback: &rollback,
                    owned_store_generation: Some(&owned_store_generation),
                    owned_auth_generation: None,
                    previous_active: &previous_active,
                    target: &target,
                },
                error,
            )?;
            return Ok(ActivationOutcome {
                state,
                reload: ReloadSummary::default(),
                detail: Some(detail),
            });
        }
    };
    prepared_record.owned_auth_generation = Some(auth_commit.generation.clone());
    prepared_record.updated_at = Utc::now();
    if let Err(error) = write_activation_record(store_lock, &prepared_record) {
        let (state, detail) = rollback_after_commit_failure(
            ActivationRollbackContext {
                store_lock,
                generation,
                accounts,
                auth_path,
                rollback: &rollback,
                owned_store_generation: Some(&owned_store_generation),
                owned_auth_generation: Some(&auth_commit.generation),
                previous_active: &previous_active,
                target: &target,
            },
            error.context("failed to persist owned auth generation"),
        )?;
        return Ok(ActivationOutcome {
            state,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    if let Err(error) =
        verify_committed_activation(store_lock, generation, auth_path, target_id, &target)
    {
        let (state, detail) = rollback_after_commit_failure(
            ActivationRollbackContext {
                store_lock,
                generation,
                accounts,
                auth_path,
                rollback: &rollback,
                owned_store_generation: Some(&owned_store_generation),
                owned_auth_generation: Some(&auth_commit.generation),
                previous_active: &previous_active,
                target: &target,
            },
            error.context("activation readback verification failed"),
        )?;
        return Ok(ActivationOutcome {
            state,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    if !reload_enabled {
        let detail =
            "auth and account store are file-converged; operator explicitly selected offline file-only activation"
                .to_string();
        write_activation_record(
            store_lock,
            &activation_record(
                ActivationState::FileOnly,
                &previous_active,
                &target,
                generation,
                Some(target_fingerprint),
                Some(detail.clone()),
            ),
        )?;
        return Ok(ActivationOutcome {
            state: ActivationState::FileOnly,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    let expected = activation_reload_binding(generation, auth_path, &target_fingerprint)?;
    let (state, summary, detail) =
        match capture_activation_reload(&mut reload, auth_path, &expected) {
            Ok(summary) => match verify_runtime_confirmation(
                &summary, &expected, store_lock, generation, auth_path, target_id, &target,
            ) {
                Ok(()) => (ActivationState::Confirmed, summary, None),
                Err(error) => (
                    ActivationState::CommittedDegraded,
                    summary,
                    Some(format!(
                        "runtime acknowledgement did not survive because final store/auth proof changed: {error:#}"
                    )),
                ),
            },
            Err(error) => (
                ActivationState::CommittedDegraded,
                ReloadSummary::default(),
                Some(format!(
                    "auth and account store committed; runtime reload failed: {error:#}"
                )),
            ),
        };
    write_activation_record(
        store_lock,
        &activation_record(
            state,
            &previous_active,
            &target,
            generation,
            Some(target_fingerprint),
            detail.clone(),
        ),
    )?;
    Ok(ActivationOutcome {
        state,
        reload: summary,
        detail,
    })
}

pub fn replace_accounts_with<R>(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    current_accounts: &mut Vec<CodexAccount>,
    replacement_accounts: Vec<CodexAccount>,
    auth_path: &Path,
    reload_enabled: bool,
    mut reload: R,
) -> Result<ActivationOutcome>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    replace_accounts_with_dependencies(
        store_lock,
        generation,
        current_accounts,
        replacement_accounts,
        auth_path,
        reload_enabled,
        commit_auth_file,
        &mut reload,
    )
}

fn replace_accounts_with_dependencies<A, R>(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    current_accounts: &mut Vec<CodexAccount>,
    replacement_accounts: Vec<CodexAccount>,
    auth_path: &Path,
    reload_enabled: bool,
    mut commit_auth: A,
    mut reload: R,
) -> Result<ActivationOutcome>
where
    A: FnMut(&Path, &CodexAccount) -> Result<AuthFileCommit>,
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    if let Some(recovered) = recover_prepared_activation(store_lock, auth_path)? {
        *generation = recovered.generation;
        *current_accounts = recovered.accounts;
    }
    if let Some((_, outcome)) = reconcile_durable_activation_record_with(
        ActivationBarrierContext {
            store_lock,
            generation,
            accounts: current_accounts,
            auth_path,
            reload_enabled,
        },
        &mut reload,
    )? {
        if !outcome.is_confirmed() {
            bail!(
                "import activation is blocked by unresolved prior convergence ({:?}): {}",
                outcome.state,
                outcome.detail.as_deref().unwrap_or("no detail")
            );
        }
        let refreshed = store_lock.load()?;
        *generation = refreshed.generation;
        *current_accounts = refreshed.accounts;
    }

    if let Some(incomplete) = replacement_accounts
        .iter()
        .find(|account| !account.has_complete_token_material())
    {
        bail!(
            "import account {} has incomplete token material after trimming",
            incomplete.email
        );
    }
    let target = active_account(&replacement_accounts)
        .context("import replacement must contain exactly one active account")?
        .clone();
    let target_fingerprint = complete_account_token_fingerprint(&target)
        .context("import target has incomplete token material")?;
    let base_snapshot = store_lock.load()?;
    if &base_snapshot.generation != generation {
        let detail = format!(
            "import base generation changed before preparation; concurrent state was preserved (expected {}, found {})",
            generation.as_str(), base_snapshot.generation.as_str()
        );
        write_activation_record(
            store_lock,
            &activation_record_ids(
                ActivationState::ManualReview,
                active_account(&base_snapshot.accounts)
                    .map(|account| account.account_id.as_str())
                    .unwrap_or(""),
                &target.account_id,
                &base_snapshot.generation,
                Some(target_fingerprint),
                Some(detail.clone()),
            ),
        )?;
        *generation = base_snapshot.generation;
        *current_accounts = base_snapshot.accounts;
        return Ok(ActivationOutcome {
            state: ActivationState::ManualReview,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    let previous_account_id = active_account(&base_snapshot.accounts)
        .map(|account| account.account_id.clone())
        .unwrap_or_default();
    let previous_auth = capture_auth_file(auth_path)?;
    let rollback = ActivationRollbackImage {
        store_bytes: base_snapshot.raw_bytes().map(<[u8]>::to_vec),
        auth: previous_auth.clone(),
    };
    let owned_generation = store_lock.prospective_generation(&replacement_accounts)?;
    let mut prepared = activation_record_ids(
        ActivationState::Prepared,
        &previous_account_id,
        &target.account_id,
        generation,
        Some(target_fingerprint.clone()),
        None,
    );
    prepared.kind = ActivationKind::Import;
    prepared.base_store_generation = Some(generation.as_str().to_string());
    prepared.owned_store_generation = Some(owned_generation.as_str().to_string());
    prepared.base_auth_generation = previous_auth.generation().cloned();
    prepared.rollback = Some(rollback.clone());
    write_activation_record(store_lock, &prepared)?;

    if let Err(error) = commit_accounts(store_lock, generation, &replacement_accounts) {
        let detail = format!("import store commit failed before mutation: {error:#}");
        let mut record = activation_record_ids(
            ActivationState::RolledBack,
            &previous_account_id,
            &target.account_id,
            generation,
            None,
            Some(detail.clone()),
        );
        record.rollback = Some(rollback);
        write_activation_record(store_lock, &record)?;
        return Ok(ActivationOutcome {
            state: ActivationState::RolledBack,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    let auth_commit = match commit_auth(auth_path, &target) {
        Ok(commit) if commit.token_fingerprint == target_fingerprint => commit,
        Ok(_) => {
            return rollback_replacement_activation(
                ReplacementRollbackContext {
                    store_lock,
                    generation,
                    current_accounts,
                    auth_path,
                    rollback: &rollback,
                    owned_generation: &owned_generation,
                    owned_auth_generation: None,
                    previous_account_id: &previous_account_id,
                    target: &target,
                },
                anyhow::anyhow!("import auth commit returned an unexpected fingerprint"),
                false,
                &mut reload,
            );
        }
        Err(error) => {
            return rollback_replacement_activation(
                ReplacementRollbackContext {
                    store_lock,
                    generation,
                    current_accounts,
                    auth_path,
                    rollback: &rollback,
                    owned_generation: &owned_generation,
                    owned_auth_generation: None,
                    previous_account_id: &previous_account_id,
                    target: &target,
                },
                error.context("import auth commit failed"),
                false,
                &mut reload,
            );
        }
    };
    prepared.owned_auth_generation = Some(auth_commit.generation.clone());
    prepared.updated_at = Utc::now();
    if let Err(error) = write_activation_record(store_lock, &prepared) {
        return rollback_replacement_activation(
            ReplacementRollbackContext {
                store_lock,
                generation,
                current_accounts,
                auth_path,
                rollback: &rollback,
                owned_generation: &owned_generation,
                owned_auth_generation: Some(&auth_commit.generation),
                previous_account_id: &previous_account_id,
                target: &target,
            },
            error.context("failed to persist import auth ownership generation"),
            false,
            &mut reload,
        );
    }

    if let Err(error) =
        verify_committed_activation(store_lock, generation, auth_path, target.id, &target)
    {
        return rollback_replacement_activation(
            ReplacementRollbackContext {
                store_lock,
                generation,
                current_accounts,
                auth_path,
                rollback: &rollback,
                owned_generation: &owned_generation,
                owned_auth_generation: Some(&auth_commit.generation),
                previous_account_id: &previous_account_id,
                target: &target,
            },
            error.context("import activation readback failed"),
            false,
            &mut reload,
        );
    }

    if !reload_enabled {
        *current_accounts = replacement_accounts;
        prepared.state = ActivationState::FileOnly;
        prepared.store_generation = generation.as_str().to_string();
        prepared.auth_fingerprint = Some(target_fingerprint);
        prepared.detail = Some(
            "import files committed and verified; runtime convergence remains pending".to_string(),
        );
        prepared.updated_at = Utc::now();
        write_activation_record(store_lock, &prepared)?;
        return Ok(ActivationOutcome {
            state: ActivationState::FileOnly,
            reload: ReloadSummary::default(),
            detail: prepared.detail,
        });
    }

    let expected = activation_reload_binding(generation, auth_path, &target_fingerprint)?;
    let mut summary = match reload(auth_path) {
        Ok(summary) => summary,
        Err(error) => {
            return rollback_replacement_activation(
                ReplacementRollbackContext {
                    store_lock,
                    generation,
                    current_accounts,
                    auth_path,
                    rollback: &rollback,
                    owned_generation: &owned_generation,
                    owned_auth_generation: Some(&auth_commit.generation),
                    previous_account_id: &previous_account_id,
                    target: &target,
                },
                error.context("import runtime reload failed"),
                false,
                &mut reload,
            );
        }
    };
    let runtime_may_have_changed = !summary.sighup_sent.is_empty();
    if let Err(error) = bind_activation_reload(&mut summary, &expected) {
        return rollback_replacement_activation(
            ReplacementRollbackContext {
                store_lock,
                generation,
                current_accounts,
                auth_path,
                rollback: &rollback,
                owned_generation: &owned_generation,
                owned_auth_generation: Some(&auth_commit.generation),
                previous_account_id: &previous_account_id,
                target: &target,
            },
            error.context("import runtime convergence failed"),
            runtime_may_have_changed,
            &mut reload,
        );
    }

    match verify_runtime_confirmation(
        &summary, &expected, store_lock, generation, auth_path, target.id, &target,
    ) {
        Ok(()) => {
            *current_accounts = replacement_accounts;
            write_activation_record(
                store_lock,
                &activation_record_ids(
                    ActivationState::Confirmed,
                    &previous_account_id,
                    &target.account_id,
                    generation,
                    Some(target_fingerprint),
                    None,
                ),
            )?;
            Ok(ActivationOutcome {
                state: ActivationState::Confirmed,
                reload: summary,
                detail: None,
            })
        }
        Err(error) => rollback_replacement_activation(
            ReplacementRollbackContext {
                store_lock,
                generation,
                current_accounts,
                auth_path,
                rollback: &rollback,
                owned_generation: &owned_generation,
                owned_auth_generation: Some(&auth_commit.generation),
                previous_account_id: &previous_account_id,
                target: &target,
            },
            error.context("import runtime acknowledged reload but final store/auth proof changed"),
            true,
            &mut reload,
        ),
    }
}

struct ReplacementRollbackContext<'a> {
    store_lock: &'a AccountStoreLock,
    generation: &'a mut AccountStoreGeneration,
    current_accounts: &'a mut Vec<CodexAccount>,
    auth_path: &'a Path,
    rollback: &'a ActivationRollbackImage,
    owned_generation: &'a AccountStoreGeneration,
    owned_auth_generation: Option<&'a SecureFileGeneration>,
    previous_account_id: &'a str,
    target: &'a CodexAccount,
}

fn rollback_replacement_activation<R>(
    context: ReplacementRollbackContext<'_>,
    failure: anyhow::Error,
    runtime_may_have_changed: bool,
    reload: &mut R,
) -> Result<ActivationOutcome>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let ReplacementRollbackContext {
        store_lock,
        generation,
        current_accounts,
        auth_path,
        rollback,
        owned_generation,
        owned_auth_generation,
        previous_account_id,
        target,
    } = context;
    let current = store_lock.load()?;
    let store_owned = &current.generation == owned_generation;
    let current_auth_generation = auth_file_generation(auth_path);
    let auth_owned = owned_auth_generation
        .zip(current_auth_generation.as_ref())
        .is_some_and(|(owned, current)| owned == current);
    let auth_previous = auth_file_matches_snapshot(auth_path, &rollback.auth);
    let target_fingerprint = complete_account_token_fingerprint(target)
        .context("import target fingerprint disappeared during rollback")?;
    if !store_owned || (!auth_owned && !auth_previous) {
        let detail = format!(
            "import rollback requires manual review: {failure:#}; concurrent state was preserved (store_owned={store_owned}, auth_owned={auth_owned}, auth_previous={auth_previous})"
        );
        let mut record = activation_record_ids(
            ActivationState::ManualReview,
            previous_account_id,
            &target.account_id,
            &current.generation,
            Some(target_fingerprint.to_string()),
            Some(detail.clone()),
        );
        record.rollback = Some(rollback.clone());
        record.owned_store_generation = Some(owned_generation.as_str().to_string());
        record.owned_auth_generation = owned_auth_generation.cloned();
        write_activation_record(store_lock, &record)?;
        return Ok(ActivationOutcome {
            state: ActivationState::ManualReview,
            reload: ReloadSummary::default(),
            detail: Some(detail),
        });
    }

    let restored =
        store_lock.restore_if_owned(owned_generation, rollback.store_bytes.as_deref())?;
    if auth_owned {
        restore_auth_file_if_owned(
            auth_path,
            owned_auth_generation.context("owned auth generation disappeared during rollback")?,
            &rollback.auth,
        )?;
    }
    *generation = restored.generation;
    *current_accounts = restored.accounts;

    if runtime_may_have_changed {
        let rollback_reload = (|| -> Result<ReloadSummary> {
            let restored_active = active_account(current_accounts)
                .cloned()
                .context("import rollback restored no active account")?;
            let restored_fingerprint = complete_account_token_fingerprint(&restored_active)
                .context("import rollback restored incomplete active token material")?;
            let expected = activation_reload_binding(generation, auth_path, &restored_fingerprint)?;
            let summary = capture_activation_reload(reload, auth_path, &expected)
                .context("import rollback runtime reload failed")?;
            verify_runtime_confirmation(
                &summary,
                &expected,
                store_lock,
                generation,
                auth_path,
                restored_active.id,
                &restored_active,
            )
            .context("import rollback runtime convergence was not proven")?;
            Ok(summary)
        })();
        if rollback_reload.is_err() {
            let detail = format!(
                "import store/auth rolled back after {failure:#}, but prior runtime convergence could not be proven: {}",
                rollback_reload
                    .as_ref()
                    .err()
                    .map(|error| format!("{error:#}"))
                    .unwrap_or_else(|| "reload returned no verified targets".to_string())
            );
            let mut record = activation_record_ids(
                ActivationState::ManualReview,
                previous_account_id,
                &target.account_id,
                generation,
                None,
                Some(detail.clone()),
            );
            record.rollback = Some(rollback.clone());
            write_activation_record(store_lock, &record)?;
            return Ok(ActivationOutcome {
                state: ActivationState::ManualReview,
                reload: rollback_reload.unwrap_or_default(),
                detail: Some(detail),
            });
        }
    }

    let detail = format!("import transaction rolled back: {failure:#}");
    write_activation_record(
        store_lock,
        &activation_record_ids(
            ActivationState::RolledBack,
            previous_account_id,
            &target.account_id,
            generation,
            None,
            Some(detail.clone()),
        ),
    )?;
    Ok(ActivationOutcome {
        state: ActivationState::RolledBack,
        reload: ReloadSummary::default(),
        detail: Some(detail),
    })
}

struct DurableConvergenceContext<'a> {
    store_lock: &'a AccountStoreLock,
    generation: &'a mut AccountStoreGeneration,
    accounts: &'a [CodexAccount],
    auth_path: &'a Path,
    target: &'a CodexAccount,
    target_fingerprint: &'a str,
    reload_enabled: bool,
}

fn reconcile_activation_barrier_with<R>(
    context: ActivationBarrierContext<'_>,
    reload: &mut R,
) -> Result<Option<(Uuid, ActivationOutcome)>>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let ActivationBarrierContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        reload_enabled,
    } = context;
    if let Some(recovered) = recover_prepared_activation(store_lock, auth_path)? {
        if recovered.accounts.len() != accounts.len() {
            bail!(
                "recovered activation changed the account set; retry from a fresh store snapshot"
            );
        }
        *generation = recovered.generation;
        accounts.clone_from_slice(&recovered.accounts);
    }

    reconcile_durable_activation_record_with(
        ActivationBarrierContext {
            store_lock,
            generation,
            accounts,
            auth_path,
            reload_enabled,
        },
        reload,
    )
}

fn reconcile_durable_activation_record_with<R>(
    context: ActivationBarrierContext<'_>,
    reload: &mut R,
) -> Result<Option<(Uuid, ActivationOutcome)>>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let ActivationBarrierContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        reload_enabled,
    } = context;
    let Some(record) = read_activation_record(store_lock)? else {
        return Ok(None);
    };
    let mut record = reconcile_legacy_token_refresh_manual_review(
        store_lock, generation, accounts, auth_path, record,
    )?;
    if record.state == ActivationState::Confirmed {
        record =
            reconcile_confirmed_generation_transition(store_lock, generation, auth_path, record)?;
        let durable = store_lock.load()?;
        if &durable.generation != generation {
            bail!("Confirmed activation reconciliation received a stale store generation");
        }
        let active = active_account(&durable.accounts)
            .context("Confirmed activation reconciliation requires one active account")?;
        let auth_fingerprint = auth_file_fingerprint(auth_path);
        if !activation_record_confirms_current(
            &record,
            active,
            generation,
            auth_fingerprint.as_deref(),
        ) {
            bail!(
                "durable Confirmed activation is stale or does not match current store/auth state"
            );
        }
        return Ok(None);
    }
    if record.state == ActivationState::ManualReview {
        bail!(
            "automatic activation is blocked by a durable manual-review record; explicit resolution is required"
        );
    }
    if !matches!(
        record.state,
        ActivationState::CommittedDegraded | ActivationState::FileOnly
    ) {
        return Ok(None);
    }

    let Some(durable_target) = accounts
        .iter()
        .find(|account| account.account_id == record.target_account_id)
        .cloned()
    else {
        let detail = "durable activation target disappeared; manual review is required".to_string();
        record.state = ActivationState::ManualReview;
        record.detail = Some(detail.clone());
        record.store_generation = generation.as_str().to_string();
        record.updated_at = Utc::now();
        write_activation_record(store_lock, &record)?;
        bail!(detail);
    };
    let durable_fingerprint = complete_account_token_fingerprint(&durable_target)
        .context("durable activation target has incomplete token material")?;
    let durable_target_id = durable_target.id;
    let outcome = resume_committed_degraded(
        DurableConvergenceContext {
            store_lock,
            generation,
            accounts,
            auth_path,
            target: &durable_target,
            target_fingerprint: &durable_fingerprint,
            reload_enabled,
        },
        record,
        reload,
    )?;
    Ok(Some((durable_target_id, outcome)))
}

fn reconcile_confirmed_generation_transition(
    store_lock: &AccountStoreLock,
    generation: &AccountStoreGeneration,
    auth_path: &Path,
    mut record: ActivationRecord,
) -> Result<ActivationRecord> {
    let current = store_lock.load()?;
    if &current.generation != generation {
        bail!("Confirmed activation reconciliation received a stale store generation");
    }
    let (base_generation, owned_generation) = match (
        record.base_store_generation.as_deref(),
        record.owned_store_generation.as_deref(),
    ) {
        (None, None) => return Ok(record),
        (Some(base), Some(owned)) => (base.to_string(), owned.to_string()),
        _ => bail!("Confirmed activation has an incomplete generation transition"),
    };
    if record.version != ACTIVATION_RECORD_VERSION
        || record.kind == ActivationKind::Unknown
        || record.store_generation.as_str() != base_generation.as_str()
        || base_generation.as_str() == owned_generation.as_str()
        || record.base_auth_generation.is_some()
        || record.owned_auth_generation.is_some()
        || record.rollback.is_some()
    {
        bail!("Confirmed activation generation transition is not structurally valid");
    }
    let active = active_account(&current.accounts)
        .context("Confirmed generation transition requires one active account")?;
    let active_fingerprint = complete_account_token_fingerprint(active)
        .context("Confirmed generation transition requires complete active token material")?;
    if record.target_account_id != active.account_id
        || record.auth_fingerprint.as_deref() != Some(active_fingerprint.as_str())
        || auth_file_fingerprint(auth_path).as_deref() != Some(active_fingerprint.as_str())
    {
        bail!("Confirmed generation transition does not match current store/auth identity");
    }

    match generation.as_str() {
        current if current == base_generation.as_str() => {}
        current if current == owned_generation.as_str() => {
            record.store_generation = owned_generation;
        }
        _ => bail!("Confirmed generation transition does not own the current store generation"),
    }
    record.base_store_generation = None;
    record.owned_store_generation = None;
    write_activation_record(store_lock, &record)
        .context("failed to finalize durable Confirmed generation transition")?;
    Ok(record)
}

fn reconcile_legacy_token_refresh_manual_review(
    store_lock: &AccountStoreLock,
    generation: &AccountStoreGeneration,
    accounts: &[CodexAccount],
    auth_path: &Path,
    mut record: ActivationRecord,
) -> Result<ActivationRecord> {
    if record.state != ActivationState::ManualReview
        || record.version != ACTIVATION_RECORD_VERSION
        || record.kind != ActivationKind::Rotation
        || record.detail.as_deref() != Some(LEGACY_DEGRADED_TOKEN_MISMATCH)
    {
        return Ok(record);
    }

    let Some(active) = active_account(accounts) else {
        return Ok(record);
    };
    if !auth_file_matches_account(auth_path, active) {
        return Ok(record);
    }
    let Some(current_fingerprint) = complete_account_token_fingerprint(active) else {
        return Ok(record);
    };

    record.state = ActivationState::CommittedDegraded;
    if active.account_id != record.target_account_id {
        record.previous_account_id = record.target_account_id;
        record.target_account_id = active.account_id.clone();
    }
    record.store_generation = generation.as_str().to_string();
    record.auth_fingerprint = Some(current_fingerprint);
    record.detail = Some(
        "legacy degraded-token mismatch reconciled from exact store/auth convergence; runtime acknowledgement remains required"
            .to_string(),
    );
    record.updated_at = Utc::now();
    write_activation_record(store_lock, &record)?;
    Ok(record)
}

fn resume_committed_degraded<R>(
    context: DurableConvergenceContext<'_>,
    mut record: ActivationRecord,
    reload: &mut R,
) -> Result<ActivationOutcome>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let DurableConvergenceContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        target,
        target_fingerprint,
        reload_enabled,
    } = context;
    let active_matches_target =
        active_account(accounts).map(|account| account.id) == Some(target.id);
    let record_matches_target = record.target_account_id == target.account_id;
    if !active_matches_target
        || !record_matches_target
        || !auth_file_matches_account(auth_path, target)
    {
        let detail = LEGACY_DEGRADED_TOKEN_MISMATCH.to_string();
        record.state = ActivationState::ManualReview;
        record.detail = Some(detail.clone());
        record.store_generation = generation.as_str().to_string();
        record.updated_at = Utc::now();
        write_activation_record(store_lock, &record)?;
        bail!(detail);
    }

    commit_accounts(store_lock, generation, accounts)
        .context("failed to persist account observations while activation remains degraded")?;

    record.store_generation = generation.as_str().to_string();
    record.auth_fingerprint = Some(target_fingerprint.to_string());
    record.updated_at = Utc::now();
    write_activation_record(store_lock, &record)?;

    if !reload_enabled {
        return Ok(ActivationOutcome {
            state: record.state,
            reload: ReloadSummary::default(),
            detail: record.detail,
        });
    }

    let expected = activation_reload_binding(generation, auth_path, target_fingerprint)?;
    let (state, summary, detail) = match capture_activation_reload(reload, auth_path, &expected) {
        Ok(summary) => match verify_runtime_confirmation(
            &summary,
            &expected,
            store_lock,
            generation,
            auth_path,
            target.id,
            target,
        ) {
            Ok(()) => (ActivationState::Confirmed, summary, None),
            Err(error) => (
                ActivationState::CommittedDegraded,
                summary,
                Some(format!(
                    "runtime acknowledgement did not survive final degraded-activation proof: {error:#}"
                )),
            ),
        },
        Err(error) => (
            ActivationState::CommittedDegraded,
            ReloadSummary::default(),
            Some(format!(
                "degraded activation runtime convergence failed: {error:#}"
            )),
        ),
    };
    record.state = state;
    record.store_generation = generation.as_str().to_string();
    record.auth_fingerprint = Some(target_fingerprint.to_string());
    record.detail = detail.clone();
    if state == ActivationState::Confirmed {
        record.base_store_generation = None;
        record.owned_store_generation = None;
        record.base_auth_generation = None;
        record.owned_auth_generation = None;
        record.rollback = None;
    }
    record.updated_at = Utc::now();
    write_activation_record(store_lock, &record)?;
    Ok(ActivationOutcome {
        state,
        reload: summary,
        detail,
    })
}

fn capture_activation_reload<R>(
    reload: &mut R,
    auth_path: &Path,
    expected: &ActivationReloadBinding,
) -> Result<ReloadSummary>
where
    R: FnMut(&Path) -> Result<ReloadSummary>,
{
    let mut summary = reload(auth_path)?;
    bind_activation_reload(&mut summary, expected)?;
    Ok(summary)
}

fn bind_activation_reload(
    summary: &mut ReloadSummary,
    expected: &ActivationReloadBinding,
) -> Result<()> {
    let acknowledgement_count = summary.signaled.len();
    let sighup_count = summary.sighup_sent.len();
    let skipped_count = summary.skipped.len();
    summary.bind_activation(expected).with_context(|| {
        format!(
            "runtime convergence failed with {acknowledgement_count} verified ACK(s), {sighup_count} SIGHUP target(s), and {skipped_count} skipped target(s)"
        )
    })
}

fn verify_runtime_confirmation(
    summary: &ReloadSummary,
    expected: &ActivationReloadBinding,
    store_lock: &AccountStoreLock,
    generation: &AccountStoreGeneration,
    auth_path: &Path,
    target_id: Uuid,
    target: &CodexAccount,
) -> Result<()> {
    if !summary.proves_activation(expected) {
        bail!("runtime reload evidence is not bound to this exact activation generation");
    }
    verify_committed_activation(store_lock, generation, auth_path, target_id, target)?;
    summary.revalidate_current_topology(auth_path)?;
    verify_committed_activation(store_lock, generation, auth_path, target_id, target)
        .context("store/auth changed during final runtime topology validation")
}

struct ActivationRollbackContext<'a> {
    store_lock: &'a AccountStoreLock,
    generation: &'a mut AccountStoreGeneration,
    accounts: &'a mut [CodexAccount],
    auth_path: &'a Path,
    rollback: &'a ActivationRollbackImage,
    owned_store_generation: Option<&'a AccountStoreGeneration>,
    owned_auth_generation: Option<&'a SecureFileGeneration>,
    previous_active: &'a CodexAccount,
    target: &'a CodexAccount,
}

fn rollback_after_commit_failure(
    context: ActivationRollbackContext<'_>,
    commit_error: anyhow::Error,
) -> Result<(ActivationState, String)> {
    let ActivationRollbackContext {
        store_lock,
        generation,
        accounts,
        auth_path,
        rollback,
        owned_store_generation,
        owned_auth_generation,
        previous_active,
        target,
    } = context;
    let current = store_lock.load()?;
    let store_is_previous = current.raw_bytes() == rollback.store_bytes.as_deref();
    let store_is_owned = owned_store_generation.is_some_and(|owned| &current.generation == owned);
    let auth_is_previous = auth_file_matches_snapshot(auth_path, &rollback.auth);
    let current_auth_generation = auth_file_generation(auth_path);
    let auth_is_owned = owned_auth_generation
        .zip(current_auth_generation.as_ref())
        .is_some_and(|(owned, current)| owned == current);

    let rollback_ownership_proven = match owned_store_generation {
        Some(_) => (store_is_owned || store_is_previous) && (auth_is_owned || auth_is_previous),
        None => store_is_previous && auth_is_previous,
    };
    if !rollback_ownership_proven {
        let detail = format!(
            "manual review required after activation commit failure: {commit_error:#}; rollback ownership was not proven (store_owned={store_is_owned}, store_previous={store_is_previous}, auth_owned={auth_is_owned}, auth_previous={auth_is_previous})"
        );
        let mut record = activation_record(
            ActivationState::ManualReview,
            previous_active,
            target,
            &current.generation,
            None,
            Some(detail.clone()),
        );
        record.rollback = Some(rollback.clone());
        record.owned_store_generation =
            owned_store_generation.map(|generation| generation.as_str().to_string());
        record.owned_auth_generation = owned_auth_generation.cloned();
        write_activation_record(store_lock, &record)?;
        return Ok((ActivationState::ManualReview, detail));
    }

    let restored = match (store_is_owned, owned_store_generation) {
        (true, Some(owned_generation)) => {
            store_lock.restore_if_owned(owned_generation, rollback.store_bytes.as_deref())?
        }
        (true, None) => {
            bail!("owned store generation disappeared during activation rollback")
        }
        (false, _) => current,
    };
    if auth_is_owned {
        restore_auth_file_if_owned(
            auth_path,
            owned_auth_generation.context("owned auth generation disappeared during rollback")?,
            &rollback.auth,
        )?;
    }
    *generation = restored.generation;
    if restored.accounts.len() != accounts.len() {
        bail!("activation rollback account count changed unexpectedly");
    }
    accounts.clone_from_slice(&restored.accounts);
    let detail = format!("activation rolled back after commit failure: {commit_error:#}");
    write_activation_record(
        store_lock,
        &activation_record(
            ActivationState::RolledBack,
            previous_active,
            target,
            generation,
            None,
            Some(detail.clone()),
        ),
    )?;
    Ok((ActivationState::RolledBack, detail))
}

fn verify_committed_activation(
    store_lock: &AccountStoreLock,
    generation: &AccountStoreGeneration,
    auth_path: &Path,
    target_id: Uuid,
    target: &CodexAccount,
) -> Result<()> {
    let readback = store_lock.load()?;
    if &readback.generation != generation
        || active_account(&readback.accounts).map(|account| account.id) != Some(target_id)
    {
        bail!("activation store readback did not prove the selected generation");
    }
    if !auth_file_matches_account(auth_path, target) {
        bail!("activation auth readback did not prove the complete selected token set");
    }
    Ok(())
}

fn recover_prepared_activation(
    store_lock: &AccountStoreLock,
    auth_path: &Path,
) -> Result<Option<AccountStoreSnapshot>> {
    let Some(record) = read_activation_record(store_lock)? else {
        return Ok(None);
    };
    if record.state != ActivationState::Prepared {
        return Ok(None);
    }

    if let (Some(base_generation), Some(owned_generation), Some(rollback)) = (
        record.base_store_generation.as_deref(),
        record.owned_store_generation.as_deref(),
        record.rollback.as_ref(),
    ) {
        let current = store_lock.load()?;
        let auth_is_previous = auth_file_matches_snapshot(auth_path, &rollback.auth);
        let current_auth_generation = auth_file_generation(auth_path);
        let auth_is_owned = record
            .owned_auth_generation
            .as_ref()
            .zip(current_auth_generation.as_ref())
            .is_some_and(|(owned, current)| owned == current);

        if current.generation.as_str() == owned_generation
            && auth_is_owned
            && record.kind == ActivationKind::Rotation
        {
            let mut recovered = record;
            recovered.state = ActivationState::CommittedDegraded;
            recovered.detail = Some(
                "recovered a committed activation after interruption; runtime acknowledgement is unknown"
                    .to_string(),
            );
            recovered.store_generation = current.generation.as_str().to_string();
            recovered.updated_at = Utc::now();
            write_activation_record(store_lock, &recovered)?;
            return Ok(Some(current));
        }

        if current.generation.as_str() == owned_generation && (auth_is_previous || auth_is_owned) {
            let restored = store_lock
                .restore_if_owned(&current.generation, rollback.store_bytes.as_deref())?;
            if auth_is_owned {
                restore_auth_file_if_owned(
                    auth_path,
                    record
                        .owned_auth_generation
                        .as_ref()
                        .context("prepared activation lost its owned auth generation")?,
                    &rollback.auth,
                )?;
            }
            let mut recovered = record;
            recovered.state = ActivationState::RolledBack;
            recovered.detail = Some(
                "recovered interrupted activation by restoring its exact pre-activation store and auth"
                    .to_string(),
            );
            recovered.store_generation = restored.generation.as_str().to_string();
            recovered.updated_at = Utc::now();
            write_activation_record(store_lock, &recovered)?;
            return Ok(Some(restored));
        }

        if current.generation.as_str() == base_generation && auth_is_previous {
            let mut recovered = record;
            recovered.state = ActivationState::RolledBack;
            recovered.detail = Some(
                "prepared activation had not committed; pre-activation state remains intact"
                    .to_string(),
            );
            recovered.store_generation = current.generation.as_str().to_string();
            recovered.updated_at = Utc::now();
            write_activation_record(store_lock, &recovered)?;
            return Ok(Some(current));
        }

        let detail = format!(
            "prepared activation ownership is ambiguous; concurrent state was preserved (base={}, owned={}, current={}, auth_owned={}, auth_previous={})",
            base_generation,
            owned_generation,
            current.generation.as_str(),
            auth_is_owned,
            auth_is_previous
        );
        let mut manual_review = record;
        manual_review.state = ActivationState::ManualReview;
        manual_review.detail = Some(detail.clone());
        manual_review.store_generation = current.generation.as_str().to_string();
        manual_review.updated_at = Utc::now();
        write_activation_record(store_lock, &manual_review)?;
        bail!(detail);
    }

    // Legacy records without rollback ownership evidence can only reconverge
    // from the account store; they never overwrite an unproven auth generation.
    let current = store_lock.load()?;
    let active =
        active_account(&current.accounts).context("prepared activation found invalid store")?;
    let active_is_target = active.account_id == record.target_account_id;
    let active_is_previous = active.account_id == record.previous_account_id;
    if active_is_target && auth_file_matches_account(auth_path, active) {
        let mut recovered = record;
        recovered.state = ActivationState::CommittedDegraded;
        recovered.detail = Some(
            "recovered a committed activation after interruption; runtime acknowledgement is unknown"
                .to_string(),
        );
        recovered.store_generation = current.generation.as_str().to_string();
        recovered.updated_at = Utc::now();
        write_activation_record(store_lock, &recovered)?;
        return Ok(Some(current));
    }
    if active_is_previous && auth_file_matches_account(auth_path, active) {
        let mut recovered = record;
        recovered.state = ActivationState::RolledBack;
        recovered.detail =
            Some("legacy prepared activation was already in its prior state".to_string());
        recovered.store_generation = current.generation.as_str().to_string();
        recovered.updated_at = Utc::now();
        write_activation_record(store_lock, &recovered)?;
        return Ok(Some(current));
    }

    let detail = "legacy prepared activation lacks exact store/auth ownership generations; concurrent state was preserved and manual review is required".to_string();
    let mut manual_review = record;
    manual_review.state = ActivationState::ManualReview;
    manual_review.detail = Some(detail.clone());
    manual_review.store_generation = current.generation.as_str().to_string();
    manual_review.updated_at = Utc::now();
    write_activation_record(store_lock, &manual_review)?;
    bail!(detail)
}

fn activation_record(
    state: ActivationState,
    previous: &CodexAccount,
    target: &CodexAccount,
    generation: &AccountStoreGeneration,
    auth_fingerprint: Option<String>,
    detail: Option<String>,
) -> ActivationRecord {
    activation_record_ids(
        state,
        &previous.account_id,
        &target.account_id,
        generation,
        auth_fingerprint,
        detail,
    )
}

fn activation_record_ids(
    state: ActivationState,
    previous_account_id: &str,
    target_account_id: &str,
    generation: &AccountStoreGeneration,
    auth_fingerprint: Option<String>,
    detail: Option<String>,
) -> ActivationRecord {
    ActivationRecord {
        version: ACTIVATION_RECORD_VERSION,
        state,
        kind: ActivationKind::Rotation,
        previous_account_id: previous_account_id.to_string(),
        target_account_id: target_account_id.to_string(),
        store_generation: generation.as_str().to_string(),
        auth_fingerprint,
        base_store_generation: None,
        owned_store_generation: None,
        base_auth_generation: None,
        owned_auth_generation: None,
        rollback: None,
        detail,
        updated_at: Utc::now(),
    }
}

pub fn activation_record_path(store_path: &Path) -> PathBuf {
    store_path.with_extension("activation.json")
}

fn provider_io_lease_path(store_path: &Path) -> PathBuf {
    store_path.with_extension("provider-io")
}

pub(crate) fn acquire_provider_io_lease(store_path: &Path) -> Result<secure_file::SecureFileLock> {
    secure_file::try_lock(&provider_io_lease_path(store_path), true)?.context(
        "another activation or irreversible provider operation owns the provider-I/O lease",
    )
}

pub fn read_activation_record(store_lock: &AccountStoreLock) -> Result<Option<ActivationRecord>> {
    read_activation_record_for_store(store_lock.store_path())
}

pub fn read_activation_record_for_store(store_path: &Path) -> Result<Option<ActivationRecord>> {
    Ok(observe_activation_record_for_store(store_path)?.record)
}

fn observe_activation_record_for_store(store_path: &Path) -> Result<ObservedActivationRecord> {
    let path = activation_record_path(store_path);
    let snapshot = secure_file::observe(&path, ACTIVATION_RECORD_MAX_BYTES, true)?;
    let record = match snapshot.bytes() {
        Some(data) => serde_json::from_slice(data)
            .with_context(|| format!("failed to decode {}", path.display()))
            .map(Some),
        None => Ok(None),
    }?;
    Ok(ObservedActivationRecord {
        record,
        identity: ActivationJournalIdentity {
            generation: snapshot.generation().clone(),
            file_identity: snapshot.file_identity(),
            modified_unix: snapshot.modified_unix(),
        },
    })
}

pub(crate) fn activation_record_confirms_current(
    record: &ActivationRecord,
    active: &CodexAccount,
    generation: &AccountStoreGeneration,
    auth_fingerprint: Option<&str>,
) -> bool {
    let Some(active_fingerprint) = complete_account_token_fingerprint(active) else {
        return false;
    };
    record.version == ACTIVATION_RECORD_VERSION
        && record.state == ActivationState::Confirmed
        && record.kind != ActivationKind::Unknown
        && record.target_account_id == active.account_id
        && record.store_generation == generation.as_str()
        && record.auth_fingerprint.as_deref() == Some(active_fingerprint.as_str())
        && record.base_store_generation.is_none()
        && record.owned_store_generation.is_none()
        && record.base_auth_generation.is_none()
        && record.owned_auth_generation.is_none()
        && record.rollback.is_none()
        && auth_fingerprint == Some(active_fingerprint.as_str())
}

pub(crate) fn require_current_activation_confirmation(
    store_path: &Path,
    auth_path: &Path,
) -> Result<()> {
    let snapshot = crate::account_store::load_account_store_snapshot(store_path)?;
    let active = active_account(&snapshot.accounts)
        .context("activation confirmation requires one active account")?;
    let record = read_activation_record_for_store(store_path)?
        .context("activation confirmation record is missing")?;
    let auth_fingerprint = crate::auth::auth_file_fingerprint(auth_path);
    if !activation_record_confirms_current(
        &record,
        active,
        &snapshot.generation,
        auth_fingerprint.as_deref(),
    ) {
        bail!("activation confirmation is stale or does not match current store/auth state");
    }
    Ok(())
}

pub(crate) fn preflight_provider_io_activation(
    store_path: &Path,
    auth_path: &Path,
) -> Result<ProviderIoActivationSnapshot> {
    let store_lock = crate::account_store::lock_account_store(store_path)?;
    let snapshot = store_lock.load()?;
    let record = read_activation_record(&store_lock)?
        .context("provider I/O requires a durable Confirmed activation record")?;
    if record.state != ActivationState::Confirmed {
        bail!(
            "provider I/O is blocked by unresolved activation state {:?}",
            record.state
        );
    }
    reconcile_confirmed_generation_transition(
        &store_lock,
        &snapshot.generation,
        auth_path,
        record,
    )?;
    let current = store_lock.load()?;
    if current.generation != snapshot.generation {
        bail!("account store changed during provider-I/O activation preflight");
    }
    let observed = observe_activation_record_for_store(store_path)?;
    let guard = ProviderIoActivationGuard {
        store_generation: current.generation.clone(),
        journal: observed.identity,
    };
    validate_provider_io_activation_locked(&store_lock, auth_path, &guard)
        .context("provider I/O activation preflight found stale or malformed confirmation")?;
    Ok(ProviderIoActivationSnapshot {
        accounts: current.accounts,
        generation: current.generation,
        guard,
    })
}

pub(crate) fn validate_provider_io_activation(
    store_path: &Path,
    auth_path: &Path,
    guard: &ProviderIoActivationGuard,
) -> Result<()> {
    let store_lock = crate::account_store::lock_account_store(store_path)?;
    validate_provider_io_activation_locked(&store_lock, auth_path, guard)
}

pub(crate) fn validate_provider_io_activation_locked(
    store_lock: &AccountStoreLock,
    auth_path: &Path,
    guard: &ProviderIoActivationGuard,
) -> Result<()> {
    let current = store_lock.load()?;
    if current.generation != guard.store_generation {
        bail!(
            "provider-I/O activation guard found a changed store generation (expected {}, found {})",
            guard.store_generation.as_str(),
            current.generation.as_str()
        );
    }
    let observed = observe_activation_record_for_store(store_lock.store_path())?;
    if observed.identity != guard.journal {
        bail!("provider-I/O activation guard found a changed activation journal");
    }
    let record = observed
        .record
        .context("provider-I/O activation guard requires a durable Confirmed record")?;
    let active = active_account(&current.accounts)
        .context("provider-I/O activation guard requires one active account")?;
    let auth_fingerprint = auth_file_fingerprint(auth_path);
    if !activation_record_confirms_current(
        &record,
        active,
        &current.generation,
        auth_fingerprint.as_deref(),
    ) {
        bail!("provider-I/O activation guard found stale or malformed confirmation");
    }
    Ok(())
}

pub(crate) fn commit_accounts_preserving_confirmed_generation_continuity(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
    auth_path: &Path,
) -> Result<()> {
    commit_accounts_with_confirmed_generation_continuity(
        store_lock, generation, accounts, auth_path,
    )
}

pub(crate) fn commit_accounts_with_provider_io_activation(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
    auth_path: &Path,
    guard: &ProviderIoActivationGuard,
) -> Result<()> {
    validate_provider_io_activation_locked(store_lock, auth_path, guard)
        .context("account-store commit refused a changed provider-I/O activation guard")?;
    if generation.as_str() != guard.store_generation.as_str() {
        bail!(
            "account-store commit received a generation outside its provider-I/O activation guard"
        );
    }
    let record = read_activation_record(store_lock)?
        .context("account-store commit requires a current Confirmed activation record")?;
    commit_accounts_from_confirmed_record_with(
        store_lock,
        generation,
        accounts,
        auth_path,
        record,
        write_activation_record,
        commit_accounts,
    )
}

pub(crate) fn commit_accounts_with_confirmed_generation_continuity(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
    auth_path: &Path,
) -> Result<()> {
    let record = read_activation_record(store_lock)?
        .context("account-store commit requires a current Confirmed activation record")?;
    commit_accounts_from_confirmed_record_with(
        store_lock,
        generation,
        accounts,
        auth_path,
        record,
        write_activation_record,
        commit_accounts,
    )
}

fn commit_accounts_from_confirmed_record_with<W, C>(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
    auth_path: &Path,
    mut record: ActivationRecord,
    mut write_record: W,
    commit: C,
) -> Result<()>
where
    W: FnMut(&AccountStoreLock, &ActivationRecord) -> Result<()>,
    C: FnOnce(&AccountStoreLock, &mut AccountStoreGeneration, &[CodexAccount]) -> Result<()>,
{
    let previous_generation = generation.clone();
    let current = store_lock.load()?;
    if current.generation != previous_generation {
        bail!(
            "account-store commit requires the exact current generation (expected {}, found {})",
            previous_generation.as_str(),
            current.generation.as_str()
        );
    }
    let current_active = active_account(&current.accounts)
        .context("account-store commit requires exactly one current active account")?;
    let proposed_active = active_account(accounts)
        .context("account-store commit requires exactly one proposed active account")?;
    let current_fingerprint = complete_account_token_fingerprint(current_active)
        .context("current active account has incomplete token material")?;
    let proposed_fingerprint = complete_account_token_fingerprint(proposed_active)
        .context("proposed active account has incomplete token material")?;
    let auth_fingerprint = auth_file_fingerprint(auth_path);
    if !activation_record_confirms_current(
        &record,
        current_active,
        &previous_generation,
        auth_fingerprint.as_deref(),
    ) {
        bail!("account-store commit refused to break Confirmed activation-generation continuity");
    }
    if proposed_active.account_id != current_active.account_id
        || proposed_fingerprint != current_fingerprint
    {
        bail!(
            "account-store commit cannot carry runtime confirmation across an active token change"
        );
    }

    let prospective_generation = store_lock.prospective_generation(accounts)?;
    if prospective_generation == previous_generation {
        return Ok(());
    }
    let mut pending_record = record.clone();
    pending_record.base_store_generation = Some(previous_generation.as_str().to_string());
    pending_record.owned_store_generation = Some(prospective_generation.as_str().to_string());
    write_record(store_lock, &pending_record)
        .context("failed to durably publish the Confirmed generation transition")?;
    commit(store_lock, generation, accounts).context(
        "account-store commit failed after durable Confirmed generation-transition publication; further activation is blocked until reconciliation",
    )?;
    if *generation != prospective_generation {
        bail!("account-store commit returned a generation other than the journaled generation");
    }

    record.store_generation = prospective_generation.as_str().to_string();
    record.base_store_generation = None;
    record.owned_store_generation = None;
    record.base_auth_generation = None;
    record.owned_auth_generation = None;
    record.rollback = None;
    write_record(store_lock, &record).context(
        "failed to finalize Confirmed generation continuity; the durable transition remains fail-closed",
    )?;

    let committed = store_lock.load()?;
    let committed_active = active_account(&committed.accounts)
        .context("committed account store lost its active account")?;
    let durable_record = read_activation_record(store_lock)?
        .context("Confirmed activation record disappeared after account-store commit")?;
    let durable_auth_fingerprint = auth_file_fingerprint(auth_path);
    if committed.generation != prospective_generation
        || !activation_record_confirms_current(
            &durable_record,
            committed_active,
            &committed.generation,
            durable_auth_fingerprint.as_deref(),
        )
    {
        bail!("account-store commit did not preserve exact Confirmed generation continuity");
    }
    Ok(())
}

fn write_activation_record(store_lock: &AccountStoreLock, record: &ActivationRecord) -> Result<()> {
    let _provider_io_lease = acquire_provider_io_lease(store_lock.store_path())
        .context("activation journal mutation blocked by provider I/O")?;
    let path = activation_record_path(store_lock.store_path());
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    let temporary = parent.join(format!(
        ".activation.tmp-{}-{}",
        std::process::id(),
        Uuid::new_v4()
    ));
    let data = serde_json::to_vec_pretty(record).context("failed to encode activation record")?;
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)
            .with_context(|| format!("failed to create {}", temporary.display()))?;
        file.write_all(&data)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to sync {}", temporary.display()))?;
        fs::rename(&temporary, &path)
            .with_context(|| format!("failed to promote {}", path.display()))?;
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .with_context(|| format!("failed to sync {}", parent.display()))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{active_account, lock_account_store, save_accounts, CodexAccount};
    use crate::auth::{auth_file_fingerprint, auth_file_matches_account, commit_auth_file};
    use std::cell::Cell;
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn account(email: &str, active: bool) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: email.to_string(),
            access_token: format!("access-{email}"),
            refresh_token: format!("refresh-{email}"),
            id_token: format!("id-{email}"),
            account_id: format!("account-{email}"),
            quota_snapshot: None,
            plan_type: Some("pro".to_string()),
            last_refreshed: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: Some(true),
            five_hour_primed_at: None,
            is_active: active,
            runtime_unusable_until: None,
            runtime_unusable_reason: None,
            rate_limit_reset_bank: None,
        }
    }

    fn assert_store_lock_available(store_path: &Path) -> Result<()> {
        let lock_path = store_path.with_extension("json.lock");
        let file = OpenOptions::new().read(true).write(true).open(&lock_path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            bail!(
                "account-store lock was held during runtime observation: {}",
                std::io::Error::last_os_error()
            );
        }
        let unlock_result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        if unlock_result != 0 {
            bail!(
                "failed to release runtime-observation probe lock: {}",
                std::io::Error::last_os_error()
            );
        }
        Ok(())
    }

    #[test]
    fn unlocked_activation_runs_reload_and_final_topology_proof_without_store_lock() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        let candidate = account("candidate@example.com", false);
        save_accounts(&store_path, &[active.clone(), candidate.clone()])?;
        commit_auth_file(&auth_path, &active)?;
        let snapshot = crate::account_store::load_account_store_snapshot(&store_path)?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let reload_store_path = store_path.clone();
        let topology_store_path = store_path.clone();

        let outcome = activate_with_unlocked_reload_with_topology(
            &store_path,
            &auth_path,
            &mut generation,
            &mut accounts,
            candidate.id,
            true,
            &move |_| {
                assert_store_lock_available(&reload_store_path)?;
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
            move |summary, _| {
                assert_store_lock_available(&topology_store_path)?;
                if !summary.has_bound_activation_proof() {
                    bail!("topology proof received unbound runtime evidence");
                }
                Ok(())
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(
            read_activation_record_for_store(&store_path)?.map(|record| record.state),
            Some(ActivationState::Confirmed)
        );
        Ok(())
    }

    #[test]
    fn activation_observation_rejects_symlink_without_creating_a_lock() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let journal_path = activation_record_path(&store_path);
        let outside = dir.path().join("outside.json");
        fs::write(&outside, b"{}")?;
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o600))?;
        symlink(&outside, &journal_path)?;

        assert!(read_activation_record_for_store(&store_path).is_err());
        assert!(journal_path.is_symlink());
        assert!(!journal_path.with_extension("json.lock").exists());
        Ok(())
    }

    #[test]
    fn provider_io_lease_blocks_activation_journal_mutation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let record = activation_record_ids(
            ActivationState::Prepared,
            &active.account_id,
            &active.account_id,
            &snapshot.generation,
            account_token_fingerprint(&active),
            None,
        );
        let _provider_io_lease = acquire_provider_io_lease(&store_path)?;

        let error = write_activation_record(&store_lock, &record).unwrap_err();
        assert!(format!("{error:#}").contains("provider I/O"));
        assert!(!activation_record_path(&store_path).exists());
        Ok(())
    }

    #[test]
    fn current_confirmation_requires_exact_state_account_generation_and_auth() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;

        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let fingerprint = account_token_fingerprint(&active).unwrap();
        let mut record = activation_record_ids(
            ActivationState::Confirmed,
            &active.account_id,
            &active.account_id,
            &snapshot.generation,
            Some(fingerprint.clone()),
            None,
        );
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_ok());

        record.kind = ActivationKind::Unknown;
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        record.kind = ActivationKind::Rotation;
        record.state = ActivationState::RolledBack;
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        record.state = ActivationState::Confirmed;
        record.target_account_id = "other-account".to_string();
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        record.target_account_id = active.account_id.clone();
        record.store_generation = "stale-generation".to_string();
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        record.store_generation = snapshot.generation.as_str().to_string();
        record.auth_fingerprint = Some("stale-fingerprint".to_string());
        write_activation_record(&store_lock, &record)?;
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_err());
        Ok(())
    }

    #[test]
    fn quota_only_commit_advances_confirmation_generation_without_reminting_evidence() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let record = activation_record_ids(
            ActivationState::Confirmed,
            &active.account_id,
            &active.account_id,
            &generation,
            account_token_fingerprint(&active),
            None,
        );
        let evidence_time = record.updated_at.to_owned();
        write_activation_record(&store_lock, &record)?;

        accounts[0].plan_type = Some("pro-observed".to_string());
        commit_accounts_with_confirmed_generation_continuity(
            &store_lock,
            &mut generation,
            &accounts,
            &auth_path,
        )?;
        let advanced = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(advanced.store_generation, generation.as_str());
        assert_eq!(advanced.updated_at, evidence_time);
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_ok());

        accounts[0].access_token = "changed-without-runtime-proof".to_string();
        let prior_to_token_change = generation.clone();
        let error = commit_accounts_with_confirmed_generation_continuity(
            &store_lock,
            &mut generation,
            &accounts,
            &auth_path,
        );
        assert!(format!("{:#}", error.unwrap_err()).contains("active token change"));
        assert_eq!(generation, prior_to_token_change);
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_ok());
        assert_ne!(
            store_lock.load()?.accounts[0].access_token,
            accounts[0].access_token
        );
        Ok(())
    }

    #[test]
    fn observation_commit_never_falls_back_beneath_missing_or_unresolved_activation() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_before = fs::read(&store_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        accounts[0].plan_type = Some("observed-pro".to_string());

        let missing_error = commit_accounts_preserving_confirmed_generation_continuity(
            &store_lock,
            &mut generation,
            &accounts,
            &auth_path,
        )
        .unwrap_err();
        assert!(format!("{missing_error:#}").contains("current Confirmed activation record"));
        assert_eq!(fs::read(&store_path)?, store_before);

        let prepared = activation_record_ids(
            ActivationState::Prepared,
            &active.account_id,
            &active.account_id,
            &generation,
            account_token_fingerprint(&active),
            None,
        );
        write_activation_record(&store_lock, &prepared)?;
        let unresolved_error = commit_accounts_preserving_confirmed_generation_continuity(
            &store_lock,
            &mut generation,
            &accounts,
            &auth_path,
        )
        .unwrap_err();
        assert!(
            format!("{unresolved_error:#}").contains("Confirmed activation-generation continuity")
        );
        assert_eq!(fs::read(&store_path)?, store_before);
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            prepared.state
        );
        Ok(())
    }

    #[test]
    fn confirmed_generation_finalization_failure_leaves_durable_transition_barrier() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let original_generation = snapshot.generation;
        let mut generation = original_generation.clone();
        let mut accounts = snapshot.accounts;
        let record = activation_record_ids(
            ActivationState::Confirmed,
            &active.account_id,
            &active.account_id,
            &generation,
            complete_account_token_fingerprint(&active),
            None,
        );
        let evidence_time = record.updated_at.to_owned();
        write_activation_record(&store_lock, &record)?;

        accounts[0].plan_type = Some("new-observation".to_string());
        let prospective_generation = store_lock.prospective_generation(&accounts)?;
        let writes = Cell::new(0usize);
        let error = commit_accounts_from_confirmed_record_with(
            &store_lock,
            &mut generation,
            &accounts,
            &auth_path,
            record,
            |store_lock, record| {
                writes.set(writes.get() + 1);
                if writes.get() == 2 {
                    bail!("simulated final activation-journal failure");
                }
                write_activation_record(store_lock, record)
            },
            commit_accounts,
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("simulated final activation-journal failure"));
        assert_eq!(writes.get(), 2);
        assert_eq!(generation, prospective_generation);
        assert_eq!(store_lock.load()?.generation, prospective_generation);
        let staged = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(staged.store_generation, original_generation.as_str());
        assert_eq!(
            staged.base_store_generation.as_deref(),
            Some(original_generation.as_str())
        );
        assert_eq!(
            staged.owned_store_generation.as_deref(),
            Some(prospective_generation.as_str())
        );
        assert_eq!(staged.updated_at, evidence_time);
        drop(store_lock);

        let reconciled =
            reconcile_activation_barrier_unlocked(&store_path, &auth_path, true, &|_| {
                bail!("generation-only reconciliation must not reload the runtime")
            })?;
        assert!(reconciled.is_none());
        let store_lock = lock_account_store(&store_path)?;
        let finalized = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(finalized.store_generation, prospective_generation.as_str());
        assert_eq!(finalized.base_store_generation, None);
        assert_eq!(finalized.owned_store_generation, None);
        assert_eq!(finalized.updated_at, evidence_time);
        assert!(require_current_activation_confirmation(&store_path, &auth_path).is_ok());
        Ok(())
    }

    #[test]
    fn activation_rejects_whitespace_only_target_tokens_before_mutation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        let mut target = account("target@example.com", false);
        target.refresh_token = " \t ".to_string();
        save_accounts(&store_path, &[active.clone(), target.clone()])?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let original_generation = snapshot.generation.clone();
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;

        let error = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: target.id,
                reload_enabled: true,
            },
            |_| bail!("invalid target must fail before runtime reload"),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("incomplete token material"));
        assert_eq!(store_lock.load()?.generation, original_generation);
        assert!(read_activation_record(&store_lock)?.is_none());
        Ok(())
    }

    #[test]
    fn import_rejects_whitespace_only_inactive_tokens_before_mutation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let current = account("current@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&current))?;
        commit_auth_file(&auth_path, &current)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let original_generation = snapshot.generation.clone();
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;
        let imported_active = account("imported@example.com", true);
        let mut imported_inactive = account("incomplete@example.com", false);
        imported_inactive.id_token = "   ".to_string();

        let error = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            vec![imported_active, imported_inactive],
            &auth_path,
            false,
            |_| bail!("invalid import must fail before runtime reload"),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("incomplete token material after trimming"));
        assert_eq!(store_lock.load()?.generation, original_generation);
        assert!(read_activation_record(&store_lock)?.is_none());
        Ok(())
    }

    fn manual_review_record(
        generation: &AccountStoreGeneration,
        active: &CodexAccount,
    ) -> ActivationRecord {
        activation_record_ids(
            ActivationState::ManualReview,
            &active.account_id,
            &active.account_id,
            generation,
            account_token_fingerprint(active),
            Some("operator review required".to_string()),
        )
    }

    #[test]
    fn activation_is_confirmed_only_after_store_auth_and_reload_proof() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|value| value.id),
            Some(target_id)
        );
        assert!(auth_file_matches_account(&auth_path, &accounts[1]));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::Confirmed
        );
        Ok(())
    }

    #[test]
    fn confirmed_same_account_token_refresh_commits_and_reloads_new_credentials() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[0].id;

        let initial = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;
        assert!(initial.is_confirmed());

        accounts[0].access_token = "fresh-access".to_string();
        accounts[0].refresh_token = "fresh-refresh".to_string();
        accounts[0].id_token = "fresh-id".to_string();
        let reload_calls = Cell::new(0usize);
        let refreshed = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(refreshed.is_confirmed());
        assert_eq!(reload_calls.get(), 1);
        let durable = store_lock.load()?;
        assert_eq!(durable.accounts[0].access_token, "fresh-access");
        assert_eq!(durable.accounts[0].refresh_token, "fresh-refresh");
        assert!(auth_file_matches_account(&auth_path, &durable.accounts[0]));
        Ok(())
    }

    #[test]
    fn zero_runtime_targets_cannot_confirm_activation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: initial[1].id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )?;

        assert_eq!(outcome.state, ActivationState::CommittedDegraded);
        assert!(!outcome.is_confirmed());
        assert!(outcome
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("0 verified ACK")));
        Ok(())
    }

    #[test]
    fn skipped_reload_commits_degraded_without_confirming_swap() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default().with_skipped(vec![(42, "ack timeout".to_string())])),
        )?;

        assert_eq!(outcome.state, ActivationState::CommittedDegraded);
        assert!(!outcome.is_confirmed());
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::CommittedDegraded
        );
        assert!(auth_file_matches_account(&auth_path, &accounts[1]));

        let second_tick = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )?;
        assert_eq!(second_tick.state, ActivationState::CommittedDegraded);
        assert!(!second_tick.is_confirmed());
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::CommittedDegraded
        );

        let converged = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;
        assert_eq!(converged.state, ActivationState::Confirmed);
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::Confirmed
        );
        Ok(())
    }

    #[test]
    fn refreshed_tokens_resume_durable_target_before_cross_target_activation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
            account("third@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let second_id = accounts[1].id;
        let third_id = accounts[2].id;

        let degraded = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: second_id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )?;
        assert_eq!(degraded.state, ActivationState::CommittedDegraded);

        accounts[1].access_token = "refreshed-access".to_string();
        accounts[1].refresh_token = "refreshed-refresh".to_string();
        accounts[1].id_token = "refreshed-id".to_string();
        commit_accounts(&store_lock, &mut generation, &accounts)?;
        commit_auth_file(&auth_path, &accounts[1])?;

        let reload_calls = std::cell::Cell::new(0usize);
        let observed_fingerprints = std::cell::RefCell::new(Vec::new());
        let refreshed_fingerprint = account_token_fingerprint(&accounts[1]).unwrap();
        let replacement_fingerprint = account_token_fingerprint(&accounts[2]).unwrap();
        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: third_id,
                reload_enabled: true,
            },
            |path| {
                let call = reload_calls.get() + 1;
                reload_calls.set(call);
                observed_fingerprints
                    .borrow_mut()
                    .push(auth_file_fingerprint(path).unwrap());
                if call == 1 {
                    let durable = read_activation_record(&store_lock)?.unwrap();
                    assert_eq!(durable.state, ActivationState::CommittedDegraded);
                    assert_eq!(
                        durable.auth_fingerprint.as_deref(),
                        Some(refreshed_fingerprint.as_str())
                    );
                }
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(reload_calls.get(), 2);
        assert_eq!(
            *observed_fingerprints.borrow(),
            vec![refreshed_fingerprint, replacement_fingerprint]
        );
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(third_id)
        );
        assert!(auth_file_matches_account(&auth_path, &accounts[2]));
        let record = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(record.state, ActivationState::Confirmed);
        assert_eq!(record.target_account_id, accounts[2].account_id);
        Ok(())
    }

    #[test]
    fn legacy_token_refresh_manual_review_reconciles_before_rotation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;
        write_activation_record(
            &store_lock,
            &ActivationRecord {
                version: ACTIVATION_RECORD_VERSION,
                state: ActivationState::ManualReview,
                kind: ActivationKind::Rotation,
                previous_account_id: accounts[1].account_id.clone(),
                target_account_id: accounts[0].account_id.clone(),
                store_generation: generation.as_str().to_string(),
                auth_fingerprint: Some("superseded-token-generation".to_string()),
                base_store_generation: None,
                owned_store_generation: None,
                base_auth_generation: None,
                owned_auth_generation: None,
                rollback: None,
                detail: Some(LEGACY_DEGRADED_TOKEN_MISMATCH.to_string()),
                updated_at: Utc::now(),
            },
        )?;
        let reload_calls = std::cell::Cell::new(0usize);

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(reload_calls.get(), 2);
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(target_id)
        );
        assert!(auth_file_matches_account(&auth_path, &accounts[1]));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::Confirmed
        );
        Ok(())
    }

    #[test]
    fn legacy_mismatch_adopts_exact_externally_converged_active_account() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("current@example.com", true),
            account("stale-target@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        write_activation_record(
            &store_lock,
            &ActivationRecord {
                version: ACTIVATION_RECORD_VERSION,
                state: ActivationState::ManualReview,
                kind: ActivationKind::Rotation,
                previous_account_id: accounts[0].account_id.clone(),
                target_account_id: accounts[1].account_id.clone(),
                store_generation: generation.as_str().to_string(),
                auth_fingerprint: Some("superseded-token-generation".to_string()),
                base_store_generation: None,
                owned_store_generation: None,
                base_auth_generation: None,
                owned_auth_generation: None,
                rollback: None,
                detail: Some(LEGACY_DEGRADED_TOKEN_MISMATCH.to_string()),
                updated_at: Utc::now(),
            },
        )?;
        let reload_calls = std::cell::Cell::new(0usize);

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: initial[0].id,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(reload_calls.get(), 1);
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(initial[0].id)
        );
        let record = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(record.state, ActivationState::Confirmed);
        assert_eq!(record.target_account_id, initial[0].account_id);
        Ok(())
    }

    #[test]
    fn final_store_auth_change_after_ack_stays_degraded() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| {
                commit_auth_file(&auth_path, &initial[0])?;
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert_eq!(outcome.state, ActivationState::CommittedDegraded);
        assert!(!outcome.is_confirmed());
        assert!(outcome
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("final store/auth proof changed")));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::CommittedDegraded
        );
        Ok(())
    }

    #[test]
    fn import_cannot_bypass_unresolved_degraded_activation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let second_id = accounts[1].id;
        let degraded = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: second_id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )?;
        assert_eq!(degraded.state, ActivationState::CommittedDegraded);

        let replacement = vec![account("replacement@example.com", true)];
        let error = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut accounts,
            replacement,
            &auth_path,
            true,
            |_| Ok(ReloadSummary::default()),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("unresolved prior convergence"));
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(second_id)
        );
        assert!(auth_file_matches_account(&auth_path, &accounts[1]));
        Ok(())
    }

    #[test]
    fn legacy_repair_requires_explicit_v3_rotation_discriminators() -> Result<()> {
        let missing_discriminators: ActivationRecord = serde_json::from_value(serde_json::json!({
            "state": "manual_review",
            "previousAccountId": "previous",
            "targetAccountId": "target",
            "storeGeneration": "generation",
            "authFingerprint": "fingerprint",
            "detail": LEGACY_DEGRADED_TOKEN_MISMATCH,
            "updatedAt": Utc::now(),
        }))?;
        assert_eq!(missing_discriminators.version, 0);
        assert_eq!(missing_discriminators.kind, ActivationKind::Unknown);

        for (version, kind) in [
            (0, ActivationKind::Unknown),
            (2, ActivationKind::Rotation),
            (ACTIVATION_RECORD_VERSION, ActivationKind::Import),
        ] {
            let dir = tempfile::tempdir()?;
            let store_path = dir.path().join("accounts.json");
            let auth_path = dir.path().join("auth.json");
            let initial = vec![
                account("first@example.com", true),
                account("second@example.com", false),
            ];
            save_accounts(&store_path, &initial)?;
            commit_auth_file(&auth_path, &initial[0])?;
            let store_lock = lock_account_store(&store_path)?;
            let snapshot = store_lock.load()?;
            let mut generation = snapshot.generation;
            let mut accounts = snapshot.accounts;
            write_activation_record(
                &store_lock,
                &ActivationRecord {
                    version,
                    state: ActivationState::ManualReview,
                    kind,
                    previous_account_id: accounts[1].account_id.clone(),
                    target_account_id: accounts[0].account_id.clone(),
                    store_generation: generation.as_str().to_string(),
                    auth_fingerprint: Some("superseded-token-generation".to_string()),
                    base_store_generation: None,
                    owned_store_generation: None,
                    base_auth_generation: None,
                    owned_auth_generation: None,
                    rollback: None,
                    detail: Some(LEGACY_DEGRADED_TOKEN_MISMATCH.to_string()),
                    updated_at: Utc::now(),
                },
            )?;
            let reload_calls = std::cell::Cell::new(0usize);
            let error = activate_with(
                ActivationContext {
                    store_lock: &store_lock,
                    generation: &mut generation,
                    accounts: &mut accounts,
                    auth_path: &auth_path,
                    target_id: initial[1].id,
                    reload_enabled: true,
                },
                |_| {
                    reload_calls.set(reload_calls.get() + 1);
                    Ok(ReloadSummary::default())
                },
            )
            .unwrap_err();
            assert!(format!("{error:#}").contains("manual-review"));
            assert_eq!(reload_calls.get(), 0);
        }
        Ok(())
    }

    #[test]
    fn manual_review_blocks_automatic_activation_without_calling_reload() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        write_activation_record(
            &store_lock,
            &ActivationRecord {
                version: ACTIVATION_RECORD_VERSION,
                state: ActivationState::ManualReview,
                kind: ActivationKind::Rotation,
                previous_account_id: initial[0].account_id.clone(),
                target_account_id: initial[0].account_id.clone(),
                store_generation: generation.as_str().to_string(),
                auth_fingerprint: account_token_fingerprint(&initial[0]),
                base_store_generation: None,
                owned_store_generation: None,
                base_auth_generation: None,
                owned_auth_generation: None,
                rollback: None,
                detail: Some("operator review required".to_string()),
                updated_at: Utc::now(),
            },
        )?;
        let reload_calls = std::cell::Cell::new(0usize);

        let error = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: initial[1].id,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default())
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("manual-review"));
        assert_eq!(reload_calls.get(), 0);
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::ManualReview
        );
        assert_eq!(
            active_account(&accounts).map(|account| account.id),
            Some(initial[0].id)
        );
        assert!(auth_file_matches_account(&auth_path, &initial[0]));
        Ok(())
    }

    #[test]
    fn explicit_manual_review_resolution_requires_final_runtime_proof() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let mut record = manual_review_record(&generation, &accounts[0]);
        record.kind = ActivationKind::Import;
        record.base_store_generation = Some("prior-store-generation".to_string());
        record.owned_store_generation = Some("owned-store-generation".to_string());
        record.rollback = Some(ActivationRollbackImage {
            store_bytes: None,
            auth: capture_auth_file(&auth_path)?,
        });
        write_activation_record(&store_lock, &record)?;

        let outcome = resolve_manual_review_activation(
            ActivationBarrierContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                reload_enabled: true,
            },
            |_| {
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert!(outcome.is_confirmed());
        let confirmed = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(confirmed.state, ActivationState::Confirmed);
        assert_eq!(confirmed.kind, ActivationKind::Import);
        assert_eq!(confirmed.target_account_id, initial[0].account_id);
        assert_eq!(
            confirmed.auth_fingerprint,
            account_token_fingerprint(&initial[0])
        );
        assert_eq!(confirmed.base_store_generation, None);
        assert_eq!(confirmed.owned_store_generation, None);
        assert!(confirmed.rollback.is_none());
        assert!(auth_file_matches_account(&auth_path, &initial[0]));
        Ok(())
    }

    #[test]
    fn unlocked_manual_resolution_runs_reload_and_topology_proof_without_store_lock() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let generation = store_lock.load()?.generation;
        write_activation_record(&store_lock, &manual_review_record(&generation, &active))?;
        drop(store_lock);
        let reload_store_path = store_path.clone();
        let topology_store_path = store_path.clone();

        let outcome = resolve_manual_review_activation_unlocked_with_topology(
            &store_path,
            &auth_path,
            &move |_| {
                assert_store_lock_available(&reload_store_path)?;
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
            move |summary, _| {
                assert_store_lock_available(&topology_store_path)?;
                if !summary.has_bound_activation_proof() {
                    bail!("manual-resolution topology proof was not activation-bound");
                }
                Ok(())
            },
        )?;

        assert!(outcome.is_confirmed());
        assert_eq!(
            read_activation_record_for_store(&store_path)?.map(|record| record.state),
            Some(ActivationState::Confirmed)
        );
        Ok(())
    }

    #[test]
    fn unlocked_manual_resolution_failure_preserves_reviewed_journal_bytes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let active = account("active@example.com", true);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        commit_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let generation = store_lock.load()?.generation;
        write_activation_record(&store_lock, &manual_review_record(&generation, &active))?;
        drop(store_lock);
        let journal_path = activation_record_path(&store_path);
        let original = fs::read(&journal_path)?;

        let error = resolve_manual_review_activation_unlocked_with_topology(
            &store_path,
            &auth_path,
            &|_| {
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
            |_, _| bail!("simulated final topology change"),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("simulated final topology change"));
        assert_eq!(fs::read(&journal_path)?, original);
        Ok(())
    }

    #[test]
    fn zero_ack_manual_review_resolution_preserves_journal_bytes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![account("first@example.com", true)];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        write_activation_record(
            &store_lock,
            &manual_review_record(&generation, &accounts[0]),
        )?;
        let journal_path = activation_record_path(&store_path);
        let original = fs::read(&journal_path)?;

        let error = resolve_manual_review_activation(
            ActivationBarrierContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("0 verified ACK"));
        assert_eq!(fs::read(&journal_path)?, original);
        Ok(())
    }

    #[test]
    fn divergent_auth_manual_review_resolution_never_signals_or_writes_journal() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        write_activation_record(
            &store_lock,
            &manual_review_record(&generation, &accounts[0]),
        )?;
        commit_auth_file(&auth_path, &accounts[1])?;
        let journal_path = activation_record_path(&store_path);
        let original = fs::read(&journal_path)?;
        let reload_calls = std::cell::Cell::new(0usize);

        let error = resolve_manual_review_activation(
            ActivationBarrierContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default())
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("divergent store/auth"));
        assert_eq!(reload_calls.get(), 0);
        assert_eq!(fs::read(&journal_path)?, original);
        Ok(())
    }

    #[test]
    fn stale_generation_preserves_concurrent_store_and_requires_manual_review() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;

        let mut concurrent = accounts.clone();
        concurrent[1].email = "externally-changed@example.com".to_string();
        fs::write(&store_path, serde_json::to_vec_pretty(&concurrent)?)?;

        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| Ok(ReloadSummary::default()),
        )?;

        assert_eq!(outcome.state, ActivationState::ManualReview);
        let stored = store_lock.load()?.accounts;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.id, initial[0].id);
        assert_eq!(stored[1].email, "externally-changed@example.com");
        assert!(auth_file_matches_account(&auth_path, active));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::ManualReview
        );
        Ok(())
    }

    #[test]
    fn rollback_cas_loss_preserves_concurrent_store_and_requires_manual_review() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = accounts[1].id;

        let outcome = activate_with_dependencies(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id,
                reload_enabled: true,
            },
            |_path, _target| {
                let mut concurrent = store_lock.load()?.accounts;
                concurrent[0].email = "concurrent-owner@example.com".to_string();
                fs::write(&store_path, serde_json::to_vec_pretty(&concurrent)?)?;
                bail!("injected auth commit failure after concurrent store update")
            },
            |_| panic!("reload must not run after auth commit failure"),
        )?;

        assert_eq!(outcome.state, ActivationState::ManualReview);
        let current = store_lock.load()?;
        assert_eq!(current.accounts[0].email, "concurrent-owner@example.com");
        assert!(auth_file_matches_account(&auth_path, &initial[0]));
        let record = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(record.state, ActivationState::ManualReview);
        assert_eq!(record.store_generation, current.generation.as_str());
        Ok(())
    }

    #[test]
    fn auth_generation_loss_preserves_concurrent_auth_and_requires_manual_review() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        let concurrent = account("concurrent@example.com", true);
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;

        let outcome = activate_with_dependencies(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path: &auth_path,
                target_id: initial[1].id,
                reload_enabled: true,
            },
            |path, target| {
                let owned = commit_auth_file(path, target)?;
                commit_auth_file(path, &concurrent)?;
                Ok(owned)
            },
            |_| {
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert_eq!(outcome.state, ActivationState::ManualReview);
        assert!(auth_file_matches_account(&auth_path, &concurrent));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::ManualReview
        );
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(initial[1].id)
        );
        Ok(())
    }

    #[test]
    fn import_auth_write_failure_restores_exact_pre_import_store_and_auth() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let original_store = fs::read(&store_path)?;
        let original_auth = fs::read(&auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;
        let replacement = vec![account("imported@example.com", true)];
        let reload_calls = std::cell::Cell::new(0usize);

        let outcome = replace_accounts_with_dependencies(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            replacement,
            &auth_path,
            true,
            |_path, _account| bail!("injected auth write failure"),
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default())
            },
        )?;

        assert_eq!(outcome.state, ActivationState::RolledBack);
        assert_eq!(reload_calls.get(), 0);
        assert_eq!(fs::read(&store_path)?, original_store);
        assert_eq!(fs::read(&auth_path)?, original_auth);
        assert_eq!(current_accounts.len(), initial.len());
        Ok(())
    }

    #[test]
    fn import_zero_runtime_targets_rolls_back_instead_of_confirming() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![account("first@example.com", true)];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let original_store = fs::read(&store_path)?;
        let original_auth = fs::read(&auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;

        let outcome = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            vec![account("imported@example.com", true)],
            &auth_path,
            true,
            |_| Ok(ReloadSummary::default()),
        )?;

        assert_eq!(outcome.state, ActivationState::RolledBack);
        assert!(!outcome.is_confirmed());
        assert_eq!(fs::read(&store_path)?, original_store);
        assert_eq!(fs::read(&auth_path)?, original_auth);
        Ok(())
    }

    #[test]
    fn import_failure_after_sighup_requires_verified_compensating_reload() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![account("first@example.com", true)];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let original_store = fs::read(&store_path)?;
        let original_auth = fs::read(&auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;
        let reload_calls = std::cell::Cell::new(0usize);

        let outcome = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            vec![account("imported@example.com", true)],
            &auth_path,
            true,
            |_| {
                let call = reload_calls.get();
                reload_calls.set(call + 1);
                if call == 0 {
                    Ok(ReloadSummary::default()
                        .with_sighup_sent(vec![42])
                        .with_skipped(vec![(42, "frontend delivery failed".to_string())]))
                } else {
                    Ok(ReloadSummary::default()
                        .with_sighup_sent(vec![42])
                        .with_signaled(vec![42])
                        .with_topology_verified(true))
                }
            },
        )?;

        assert_eq!(outcome.state, ActivationState::RolledBack);
        assert_eq!(reload_calls.get(), 2);
        assert_eq!(fs::read(&store_path)?, original_store);
        assert_eq!(fs::read(&auth_path)?, original_auth);
        Ok(())
    }

    #[test]
    fn failed_compensating_reload_after_sighup_requires_manual_review() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![account("first@example.com", true)];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;
        let reload_calls = std::cell::Cell::new(0usize);

        let outcome = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            vec![account("imported@example.com", true)],
            &auth_path,
            true,
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_skipped(vec![(42, "frontend delivery failed".to_string())]))
            },
        )?;

        assert_eq!(outcome.state, ActivationState::ManualReview);
        assert_eq!(reload_calls.get(), 2);
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::ManualReview
        );
        Ok(())
    }

    #[test]
    fn offline_import_publishes_file_only_then_converges_same_barrier() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![account("first@example.com", true)];
        let imported = account("imported@example.com", true);
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut current_accounts = snapshot.accounts;
        let reload_calls = std::cell::Cell::new(0usize);

        let prepared = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut current_accounts,
            vec![imported.clone()],
            &auth_path,
            false,
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?;

        assert_eq!(prepared.state, ActivationState::FileOnly);
        assert_eq!(reload_calls.get(), 0);
        assert!(auth_file_matches_account(&auth_path, &imported));
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(imported.id)
        );
        let record = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(record.state, ActivationState::FileOnly);
        assert_eq!(record.kind, ActivationKind::Import);
        assert!(record.rollback.is_some());

        let converged = reconcile_activation_barrier(
            ActivationBarrierContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut current_accounts,
                auth_path: &auth_path,
                reload_enabled: true,
            },
            |_| {
                reload_calls.set(reload_calls.get() + 1);
                Ok(ReloadSummary::default()
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )?
        .context("file-only import barrier disappeared before convergence")?;

        assert_eq!(converged.state, ActivationState::Confirmed);
        assert_eq!(reload_calls.get(), 1);
        let record = read_activation_record(&store_lock)?.unwrap();
        assert_eq!(record.state, ActivationState::Confirmed);
        assert_eq!(record.kind, ActivationKind::Import);
        assert!(record.rollback.is_none());
        Ok(())
    }

    #[test]
    fn interrupted_import_recovers_exact_pre_import_store_and_auth() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        let replacement = vec![account("imported@example.com", true)];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[0])?;
        let original_store = fs::read(&store_path)?;
        let original_auth = fs::read(&auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let base = store_lock.load()?;
        let rollback = ActivationRollbackImage {
            store_bytes: base.raw_bytes().map(<[u8]>::to_vec),
            auth: capture_auth_file(&auth_path)?,
        };
        let owned = store_lock.prospective_generation(&replacement)?;
        let target = active_account(&replacement).unwrap();
        let mut record = activation_record_ids(
            ActivationState::Prepared,
            &initial[0].account_id,
            &target.account_id,
            &base.generation,
            account_token_fingerprint(target),
            None,
        );
        record.kind = ActivationKind::Import;
        record.base_store_generation = Some(base.generation.as_str().to_string());
        record.owned_store_generation = Some(owned.as_str().to_string());
        record.base_auth_generation = rollback.auth.generation().cloned();
        record.rollback = Some(rollback);
        write_activation_record(&store_lock, &record)?;

        let mut committed_generation = base.generation;
        commit_accounts(&store_lock, &mut committed_generation, &replacement)?;
        let auth_commit = commit_auth_file(&auth_path, target)?;
        record.owned_auth_generation = Some(auth_commit.generation);
        write_activation_record(&store_lock, &record)?;
        assert_eq!(committed_generation, owned);

        let recovered = recover_prepared_activation(&store_lock, &auth_path)?
            .context("interrupted import was not recovered")?;

        assert_eq!(recovered.accounts.len(), initial.len());
        assert_eq!(fs::read(&store_path)?, original_store);
        assert_eq!(fs::read(&auth_path)?, original_auth);
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::RolledBack
        );
        Ok(())
    }

    #[test]
    fn legacy_prepared_recovery_never_overwrites_unproven_auth() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let auth_path = dir.path().join("auth.json");
        let initial = vec![
            account("first@example.com", true),
            account("second@example.com", false),
        ];
        save_accounts(&store_path, &initial)?;
        commit_auth_file(&auth_path, &initial[1])?;
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let generation = snapshot.generation;
        write_activation_record(
            &store_lock,
            &ActivationRecord {
                version: ACTIVATION_RECORD_VERSION,
                state: ActivationState::Prepared,
                kind: ActivationKind::Rotation,
                previous_account_id: initial[0].account_id.clone(),
                target_account_id: initial[1].account_id.clone(),
                store_generation: generation.as_str().to_string(),
                auth_fingerprint: account_token_fingerprint(&initial[1]),
                base_store_generation: None,
                owned_store_generation: None,
                base_auth_generation: None,
                owned_auth_generation: None,
                rollback: None,
                detail: None,
                updated_at: Utc::now(),
            },
        )?;

        let error = recover_prepared_activation(&store_lock, &auth_path).unwrap_err();

        assert!(format!("{error:#}").contains("manual review"));
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.id),
            Some(initial[0].id)
        );
        assert!(auth_file_matches_account(&auth_path, &initial[1]));
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::ManualReview
        );
        Ok(())
    }
}

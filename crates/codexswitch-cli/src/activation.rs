use crate::account_store::{
    activate_account, active_account, commit_accounts, AccountStoreGeneration, AccountStoreLock,
    AccountStoreSnapshot, CodexAccount,
};
use crate::auth::{
    account_token_fingerprint, auth_file_generation, auth_file_matches_account,
    auth_file_matches_snapshot, capture_auth_file, commit_auth_file, restore_auth_file_if_owned,
    AuthFileCommit, AuthFileSnapshot,
};
use crate::reload::ReloadSummary;
use crate::secure_file::SecureFileGeneration;
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
pub(crate) const LEGACY_DEGRADED_TOKEN_MISMATCH: &str =
    "degraded activation no longer matches the intended store/auth token set; manual review is required";

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
        self.state == ActivationState::Confirmed && self.reload.verified_hot_swap()
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
    let active_fingerprint = account_token_fingerprint(active)
        .context("manual-review resolution requires a complete active token set")?;

    verify_committed_activation(store_lock, generation, auth_path, active.id, active)
        .context("manual-review resolution refused divergent store/auth state")?;
    let summary = reload(auth_path).context("manual-review runtime reload failed")?;
    if !runtime_convergence_proven(&summary) {
        bail!(
            "manual-review runtime convergence was not proven: {} verified ACK(s), {} target(s) skipped",
            summary.signaled.len(),
            summary.skipped.len()
        );
    }
    verify_committed_activation(store_lock, generation, auth_path, active.id, active)
        .context("manual-review final store/auth proof changed after runtime acknowledgement")?;

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
    let target_fingerprint = account_token_fingerprint(&target)
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

    let (state, summary, detail) = match reload(auth_path) {
        Ok(summary) if runtime_convergence_proven(&summary) => {
            match verify_committed_activation(store_lock, generation, auth_path, target_id, &target)
            {
                Ok(()) => (ActivationState::Confirmed, summary, None),
                Err(error) => (
                    ActivationState::CommittedDegraded,
                    summary,
                    Some(format!(
                        "runtime acknowledged reload but final store/auth proof changed: {error:#}"
                    )),
                ),
            }
        }
        Ok(summary) => {
            let detail = format!(
                "auth and account store committed; runtime convergence is unconfirmed ({} verified ACK(s), {} target(s) skipped)",
                summary.signaled.len(), summary.skipped.len()
            );
            (ActivationState::CommittedDegraded, summary, Some(detail))
        }
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

    let target = active_account(&replacement_accounts)
        .context("import replacement must contain exactly one active account")?
        .clone();
    let target_fingerprint = account_token_fingerprint(&target)
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

    match reload(auth_path) {
        Ok(summary)
            if summary.verified_hot_swap()
                && verify_committed_activation(
                    store_lock, generation, auth_path, target.id, &target,
                )
                .is_ok() =>
        {
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
        Ok(summary) if summary.verified_hot_swap() => rollback_replacement_activation(
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
            anyhow::anyhow!(
                "import runtime acknowledged reload but final store/auth proof changed"
            ),
            true,
            &mut reload,
        ),
        Ok(summary) => {
            let runtime_may_have_changed = !summary.sighup_sent.is_empty();
            rollback_replacement_activation(
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
                anyhow::anyhow!(
                    "import runtime convergence failed with {} verified ACK(s) and {} skipped target(s)",
                    summary.signaled.len(),
                    summary.skipped.len()
                ),
                runtime_may_have_changed,
                &mut reload,
            )
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
            error.context("import runtime reload failed"),
            false,
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
    let target_fingerprint = account_token_fingerprint(target)
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
        let rollback_reload = reload(auth_path);
        if !rollback_reload
            .as_ref()
            .is_ok_and(ReloadSummary::verified_hot_swap)
        {
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
    let durable_fingerprint = account_token_fingerprint(&durable_target)
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
    let Some(current_fingerprint) = account_token_fingerprint(active) else {
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

    let (state, summary, detail) = match reload(auth_path) {
        Ok(summary) if runtime_convergence_proven(&summary) => {
            match verify_committed_activation(store_lock, generation, auth_path, target.id, target)
            {
                Ok(()) => (ActivationState::Confirmed, summary, None),
                Err(error) => (
                    ActivationState::CommittedDegraded,
                    summary,
                    Some(format!(
                        "runtime acknowledged reload but final store/auth proof changed: {error:#}"
                    )),
                ),
            }
        }
        Ok(summary) => {
            let detail = format!(
                "degraded activation remains unconfirmed: {} verified runtime ACK(s), {} target(s) skipped",
                summary.signaled.len(),
                summary.skipped.len()
            );
            (ActivationState::CommittedDegraded, summary, Some(detail))
        }
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

fn runtime_convergence_proven(summary: &ReloadSummary) -> bool {
    summary.verified_hot_swap()
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

pub fn read_activation_record(store_lock: &AccountStoreLock) -> Result<Option<ActivationRecord>> {
    let path = activation_record_path(store_lock.store_path());
    match fs::read(&path) {
        Ok(data) => serde_json::from_slice(&data)
            .with_context(|| format!("failed to decode {}", path.display()))
            .map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn write_activation_record(store_lock: &AccountStoreLock, record: &ActivationRecord) -> Result<()> {
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
            |_| {
                Ok(ReloadSummary {
                    skipped: vec![(42, "ack timeout".to_string())],
                    ..ReloadSummary::default()
                })
            },
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    sighup_sent: vec![42],
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                    Ok(ReloadSummary {
                        sighup_sent: vec![42],
                        skipped: vec![(42, "frontend delivery failed".to_string())],
                        ..ReloadSummary::default()
                    })
                } else {
                    Ok(ReloadSummary {
                        sighup_sent: vec![42],
                        signaled: vec![42],
                        ..ReloadSummary::default()
                    })
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
                Ok(ReloadSummary {
                    sighup_sent: vec![42],
                    skipped: vec![(42, "frontend delivery failed".to_string())],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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

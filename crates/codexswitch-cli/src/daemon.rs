use crate::account_store::{
    active_account, lock_account_store, mark_runtime_unusable, quota_availability_at,
    real_quota_snapshot, select_auto_swap_candidate_from_observations,
    select_plan_upgrade_candidate, select_plan_upgrade_candidate_from_observations,
    usage_limit_runtime_block_until, AccountStoreGeneration, AccountStoreSnapshot, CodexAccount,
    CurrentQuotaObservations, QuotaAvailability,
};
#[cfg(test)]
use crate::account_store::{load_accounts, save_accounts};
#[cfg(test)]
use crate::activation::activate_with;
use crate::activation::{
    acquire_runtime_activation_lease, activate_with_under_runtime_lease,
    activate_with_unlocked_reload_under_runtime_lease,
    commit_accounts_with_provider_io_activation_under_runtime_lease,
    preflight_provider_io_activation, read_activation_record,
    reconcile_activation_barrier_unlocked_under_runtime_lease,
    try_acquire_runtime_activation_lease, validate_provider_io_activation,
    validate_provider_io_activation_locked, ActivationContext, ActivationOutcome, ActivationState,
    ProviderIoActivationGuard, RuntimeActivationLease,
};
use crate::auth::auth_file_matches_account;
#[cfg(test)]
use crate::auth::write_auth_file;
use crate::codex_update;
use crate::pool_authority::{PoolAuthorityLock, PoolAuthorityPhase, TargetRequestDisposition};
use crate::quota::{apply_fetch_result, fetch_quota, FetchResult};
use crate::rate_limit_resets::{
    fetch_rate_limit_reset_bank, orchestrate_pool_reset_with_selection_and_provider_guard,
    select_smart_reset_candidate, ConsumeResult, RateLimitResetBank, ResetOrchestrationContext,
    ResetOrchestrationDependencies, ResetQuotaRefreshStrategy,
};
use crate::reload::{
    maintain_managed_headless_app_server_ack, reload_codex_hot_swap_processes,
    ManagedHeadlessAckMaintenance, ManagedHeadlessAppServerIdentity, ReloadSummary,
};
use crate::token_refresh::refresh_account_tokens;
use anyhow::{bail, Context, Result};
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::Value;
use std::path::Path;
use std::time::{Duration, Instant};
use uuid::Uuid;

const LOW_QUOTA_FAST_POLL_THRESHOLD_PERCENT: f64 = 5.0;
const LOW_QUOTA_FAST_POLL_SECONDS: u64 = 2;
const CRITICAL_QUOTA_FAST_POLL_THRESHOLD_PERCENT: f64 = 2.0;
const CRITICAL_QUOTA_FAST_POLL_SECONDS: u64 = 1;
const INACTIVE_EXHAUSTED_PLAN_UPGRADE_POLL_SECONDS: u64 = 5;
const INACTIVE_PLAN_UPGRADE_POLL_SECONDS: u64 = 15;
const INACTIVE_MISSING_QUOTA_POLL_SECONDS: u64 = 30;
const DEGRADED_ACTIVATION_RETRY_SECONDS: u64 = 60;
const DEGRADED_ACTIVATION_INACTIVE_QUOTA_POLL_LIMIT: usize = 4;
const UNIX_TO_SWIFT_REFERENCE_SECONDS: f64 = 978_307_200.0;
const MANAGED_READINESS_MAINTENANCE_INTERVAL: Duration = Duration::from_secs(60);
const MANAGED_READINESS_MINIMUM_ACK_REMAINING: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DaemonTick {
    swapped: bool,
    next_interval: Duration,
}

impl DaemonTick {
    fn settled(swapped: bool, next_interval: Duration) -> Self {
        Self {
            swapped,
            next_interval,
        }
    }

    fn runtime_convergence_pending(base_interval: Duration) -> Self {
        Self {
            swapped: false,
            next_interval: std::cmp::max(
                base_interval,
                Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS),
            ),
        }
    }
}

#[derive(Debug, Default)]
struct ManagedReadinessCadence {
    next_due_at: Option<Instant>,
}

impl ManagedReadinessCadence {
    fn claim_if_due(&mut self, now: Instant) -> bool {
        if self.next_due_at.is_some_and(|next_due| now < next_due) {
            return false;
        }
        self.next_due_at = Some(now + MANAGED_READINESS_MAINTENANCE_INTERVAL);
        true
    }

    fn time_until_due(&self, now: Instant) -> Duration {
        self.next_due_at
            .map(|next_due| next_due.saturating_duration_since(now))
            .unwrap_or(Duration::ZERO)
    }

    fn defer_from(&mut self, completed_at: Instant) {
        self.next_due_at = Some(completed_at + MANAGED_READINESS_MAINTENANCE_INTERVAL);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManagedReadinessTick {
    NotDue,
    DeferredForActivation,
    NoManagedRuntime,
    Current,
    Renewed { pid: i32 },
}

fn maintain_managed_readiness_with<Lease, CompletedAt, AcquireLease, Observe, Maintain>(
    cadence: &mut ManagedReadinessCadence,
    now: Instant,
    completed_at: CompletedAt,
    acquire_runtime_lease: AcquireLease,
    observe_managed_runtime: Observe,
    maintain_ack: Maintain,
) -> Result<ManagedReadinessTick>
where
    CompletedAt: FnOnce() -> Instant,
    AcquireLease: FnOnce() -> Result<Option<Lease>>,
    Observe: FnOnce() -> Result<Option<ManagedHeadlessAppServerIdentity>>,
    Maintain: FnOnce(&ManagedHeadlessAppServerIdentity) -> Result<ManagedHeadlessAckMaintenance>,
{
    if !cadence.claim_if_due(now) {
        return Ok(ManagedReadinessTick::NotDue);
    }
    let result = match acquire_runtime_lease() {
        Ok(None) => Ok(ManagedReadinessTick::DeferredForActivation),
        Ok(Some(_runtime_lease)) => match observe_managed_runtime() {
            Ok(None) => Ok(ManagedReadinessTick::NoManagedRuntime),
            Ok(Some(identity)) => match maintain_ack(&identity) {
                Ok(ManagedHeadlessAckMaintenance::Current) => Ok(ManagedReadinessTick::Current),
                Ok(ManagedHeadlessAckMaintenance::Renewed { pid }) => {
                    Ok(ManagedReadinessTick::Renewed { pid })
                }
                Err(error) => Err(error),
            },
            Err(error) => Err(error),
        },
        Err(error) => Err(error),
    };
    cadence.defer_from(completed_at());
    result
}

fn maintain_managed_readiness_after_tick_with<Lease, CompletedAt, AcquireLease, Observe, Maintain>(
    tick_result: Result<DaemonTick>,
    cadence: &mut ManagedReadinessCadence,
    now: Instant,
    completed_at: CompletedAt,
    acquire_runtime_lease: AcquireLease,
    observe_managed_runtime: Observe,
    maintain_ack: Maintain,
) -> (Result<DaemonTick>, Result<ManagedReadinessTick>)
where
    CompletedAt: FnOnce() -> Instant,
    AcquireLease: FnOnce() -> Result<Option<Lease>>,
    Observe: FnOnce() -> Result<Option<ManagedHeadlessAppServerIdentity>>,
    Maintain: FnOnce(&ManagedHeadlessAppServerIdentity) -> Result<ManagedHeadlessAckMaintenance>,
{
    let readiness_result = maintain_managed_readiness_with(
        cadence,
        now,
        completed_at,
        acquire_runtime_lease,
        observe_managed_runtime,
        maintain_ack,
    );
    (tick_result, readiness_result)
}

struct DaemonTickContext<'a> {
    store_path: &'a Path,
    auth_path: &'a Path,
    base_interval: Duration,
    consume_banked_resets: bool,
}

struct DaemonTickDependencies<F, T, B, C, R> {
    fetch_quota: F,
    refresh_tokens: T,
    fetch_reset_bank: B,
    consume_reset: C,
    reload: R,
}

impl<F, T, B, C, R> DaemonTickDependencies<F, T, B, C, R>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
    B: Fn(&CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    fn new(
        fetch_quota: F,
        refresh_tokens: T,
        fetch_reset_bank: B,
        consume_reset: C,
        reload: R,
    ) -> Self {
        Self {
            fetch_quota,
            refresh_tokens,
            fetch_reset_bank,
            consume_reset,
            reload,
        }
    }
}

fn load_store_snapshot(store_path: &Path) -> Result<AccountStoreSnapshot> {
    let store_lock = lock_account_store(store_path)?;
    store_lock.load()
}

fn commit_daemon_accounts(
    runtime_lease: &RuntimeActivationLease,
    store_path: &Path,
    auth_path: &Path,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
    activation_guard: &ProviderIoActivationGuard,
) -> Result<()> {
    let store_lock = lock_account_store(store_path)?;
    commit_accounts_with_provider_io_activation_under_runtime_lease(
        runtime_lease,
        &store_lock,
        generation,
        accounts,
        auth_path,
        activation_guard,
    )
}

fn activation_state(store_path: &Path) -> Result<Option<ActivationState>> {
    let store_lock = lock_account_store(store_path)?;
    Ok(read_activation_record(&store_lock)?.map(|record| record.state))
}

fn pending_activation_tick(
    outcome: &ActivationOutcome,
    base_interval: Duration,
) -> Option<DaemonTick> {
    if !matches!(
        outcome.state,
        ActivationState::FileOnly | ActivationState::CommittedDegraded
    ) {
        return None;
    }
    let tick = DaemonTick::runtime_convergence_pending(base_interval);
    eprintln!(
        "activation remains unconfirmed ({:?}): {}; retrying runtime convergence in {}s",
        outcome.state,
        outcome.detail.as_deref().unwrap_or("no detail"),
        tick.next_interval.as_secs()
    );
    Some(tick)
}

#[cfg(test)]
fn run_once_with<F, R>(
    store_path: &Path,
    auth_path: &Path,
    fetch_quota_fn: F,
    reload_fn: R,
) -> Result<bool>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    Ok(run_once_report_with(
        store_path,
        auth_path,
        Duration::from_secs(0),
        fetch_quota_fn,
        refresh_account_tokens,
        reload_fn,
    )?
    .swapped)
}

#[cfg(test)]
fn run_once_with_refresh<F, T, R>(
    store_path: &Path,
    auth_path: &Path,
    fetch_quota_fn: F,
    refresh_token_fn: T,
    reload_fn: R,
) -> Result<bool>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    Ok(run_once_report_with(
        store_path,
        auth_path,
        Duration::from_secs(0),
        fetch_quota_fn,
        refresh_token_fn,
        reload_fn,
    )?
    .swapped)
}

#[cfg(test)]
fn run_once_report_with<F, T, R>(
    store_path: &Path,
    auth_path: &Path,
    base_interval: Duration,
    fetch_quota_fn: F,
    refresh_token_fn: T,
    reload_fn: R,
) -> Result<DaemonTick>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    run_once_report_with_resets(
        DaemonTickContext {
            store_path,
            auth_path,
            base_interval,
            consume_banked_resets: false,
        },
        DaemonTickDependencies::new(
            fetch_quota_fn,
            refresh_token_fn,
            |_account| {
                Ok(RateLimitResetBank {
                    available_count: 0,
                    total_earned_count: 0,
                    credits: Vec::new(),
                    fetched_at: Utc::now(),
                })
            },
            |_account, _bank, _request_id| {
                bail!("reset consume unavailable in legacy test harness")
            },
            reload_fn,
        ),
    )
}

fn run_once_report_with_resets<F, T, B, C, R>(
    context: DaemonTickContext<'_>,
    dependencies: DaemonTickDependencies<F, T, B, C, R>,
) -> Result<DaemonTick>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
    B: Fn(&CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    let DaemonTickContext {
        store_path,
        auth_path,
        base_interval,
        consume_banked_resets,
    } = context;
    let DaemonTickDependencies {
        fetch_quota: fetch_quota_fn,
        refresh_tokens: refresh_token_fn,
        fetch_reset_bank: fetch_reset_bank_fn,
        consume_reset: consume_reset_fn,
        reload: reload_fn,
    } = dependencies;
    let runtime_lease = acquire_runtime_activation_lease(store_path)?;
    let bootstrap_snapshot = load_store_snapshot(store_path)?;
    let mut authority = PoolAuthorityLock::acquire_under_runtime_lease(&runtime_lease, store_path)?;
    authority.bootstrap_from_active(&bootstrap_snapshot.accounts)?;
    let mut prior_activation_confirmed = false;
    if let Some(outcome) = reconcile_activation_barrier_unlocked_under_runtime_lease(
        &runtime_lease,
        store_path,
        auth_path,
        true,
        &reload_fn,
    )? {
        if let Some(tick) = pending_activation_tick(&outcome, base_interval) {
            let detail = outcome
                .detail
                .as_deref()
                .unwrap_or("VPS daemon runtime convergence is pending");
            authority.mark_degraded(detail)?;
            if outcome.state == ActivationState::CommittedDegraded {
                if let Err(error) = refresh_quota_observations_during_activation_barrier(
                    store_path,
                    &fetch_quota_fn,
                ) {
                    eprintln!(
                        "warning: degraded activation quota maintenance was skipped: {error:#}"
                    );
                }
            }
            return Ok(tick);
        }
        if let Err(error) = require_confirmed_activation(outcome) {
            let detail = format!("prior VPS daemon activation was not confirmed: {error:#}");
            authority.mark_degraded(&detail)?;
            return Err(error).context("daemon pool authority remains degraded");
        }
        prior_activation_confirmed = true;
    }
    let authority_snapshot = load_store_snapshot(store_path)?;
    let mut authority_record = authority.require_record()?.clone();
    let authority_active_matches = active_account(&authority_snapshot.accounts)
        .map(|account| account.account_id.as_str())
        == Some(authority_record.desired_provider_account_id.as_str());
    if prior_activation_confirmed
        && authority_active_matches
        && authority_record.phase != PoolAuthorityPhase::Stable
    {
        authority_record = authority.mark_stable()?;
    }
    if authority_record.phase != PoolAuthorityPhase::Stable || !authority_active_matches {
        return recover_pool_authority_target(
            &runtime_lease,
            &mut authority,
            store_path,
            auth_path,
            authority_snapshot,
            base_interval,
            &reload_fn,
        );
    }
    let snapshot = preflight_provider_io_activation(store_path, auth_path)
        .context("daemon provider-I/O activation preflight failed")?;
    let activation_guard = snapshot.guard;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let fetch_quota_fn = |account: &CodexAccount| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("daemon activation changed before quota provider I/O")?;
        fetch_quota_fn(account)
    };
    let refresh_token_fn = |account: &mut CodexAccount| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("daemon activation changed before token-refresh provider I/O")?;
        refresh_token_fn(account)
    };
    let fetch_reset_bank_fn = |account: &CodexAccount| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("daemon activation changed before reset-bank provider I/O")?;
        fetch_reset_bank_fn(account)
    };
    let consume_reset_fn = |account: &CodexAccount, bank: &RateLimitResetBank, request_id: Uuid| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("daemon activation changed before reset provider submission")?;
        consume_reset_fn(account, bank, request_id)
    };
    let active_id = active_account(&accounts)
        .map(|account| account.account_id.clone())
        .context("no active account in store")?;

    let active_index = accounts
        .iter()
        .position(|account| account.account_id == active_id)
        .context("active account disappeared")?;
    let mut force_swap = false;
    let mut direct_runtime_usage_limit = false;
    let mut active_poll_succeeded = false;
    match fetch_quota_with_refresh(
        &mut accounts[active_index],
        &fetch_quota_fn,
        &refresh_token_fn,
    ) {
        Ok(result) => {
            apply_fetch_result(&mut accounts[active_index], result);
            active_poll_succeeded = true;
        }
        Err(error) => {
            eprintln!(
                "warning: failed to poll active account {}: {error:#}",
                accounts[active_index].email
            );
            if let Some((reason, cooldown)) = poll_error_runtime_block(&error) {
                let until = runtime_block_until(&accounts[active_index], reason, cooldown);
                mark_runtime_unusable(&mut accounts[active_index], reason, until);
                force_swap = true;
                direct_runtime_usage_limit = reason == "usage_limit";
            }
        }
    }

    let watch_now = Utc::now();
    let active_is_healthy = active_poll_succeeded
        && !force_swap
        && quota_availability_at(&accounts[active_index], watch_now) == QuotaAvailability::Usable;
    let cached_plan_upgrade_before_watch =
        active_is_healthy && select_plan_upgrade_candidate(&accounts, watch_now).is_some();
    if active_is_healthy && !cached_plan_upgrade_before_watch {
        let rotation_interval = next_poll_interval_for(&accounts[active_index], base_interval);
        refresh_inactive_watch_account(
            &mut accounts,
            watch_now,
            rotation_interval,
            &fetch_quota_fn,
            &refresh_token_fn,
        );
    }

    let now = Utc::now();
    let active_availability = quota_availability_at(&accounts[active_index], now);
    let active_is_blocked = active_availability == QuotaAvailability::Blocked;
    let cached_plan_upgrade_exists = !force_swap
        && active_availability == QuotaAvailability::Usable
        && select_plan_upgrade_candidate(&accounts, now).is_some();
    // A required rotation still needs current observations from every candidate;
    // stale quota and plan ranks cannot safely authorize a short-circuit.
    let candidate_observations = (force_swap
        || active_availability != QuotaAvailability::Usable
        || cached_plan_upgrade_exists)
        .then(|| refresh_rotation_candidates(&mut accounts, &fetch_quota_fn, &refresh_token_fn));

    let plan_upgrade_target = if !force_swap && active_availability == QuotaAvailability::Usable {
        candidate_observations.as_ref().and_then(|observations| {
            select_plan_upgrade_candidate_from_observations(&accounts, observations, Utc::now())
                .cloned()
        })
    } else {
        None
    };
    let rotation_target = if let Some(target) = plan_upgrade_target.as_ref() {
        Some(target.clone())
    } else if force_swap || active_availability != QuotaAvailability::Usable {
        candidate_observations.as_ref().and_then(|observations| {
            select_auto_swap_candidate_from_observations(&accounts, observations, Utc::now())
                .cloned()
        })
    } else {
        None
    };

    let mut reset_selection_accounts = accounts.clone();
    if consume_banked_resets {
        refresh_stale_reset_bank_observations(
            &mut reset_selection_accounts,
            Utc::now(),
            &fetch_reset_bank_fn,
        );
    }

    let previous_reset_bank = accounts[active_index].rate_limit_reset_bank.as_ref();
    let cached_reset_candidate_exists = consume_banked_resets
        && select_smart_reset_candidate(
            &reset_selection_accounts,
            active_index,
            direct_runtime_usage_limit,
            Utc::now(),
            candidate_observations.as_ref(),
        )
        .is_some();
    let should_refresh_reset_bank = previous_reset_bank
        .as_ref()
        .map(|bank| bank.is_stale(Utc::now()))
        .unwrap_or(true)
        || active_is_blocked
        || direct_runtime_usage_limit
        || cached_reset_candidate_exists;
    if should_refresh_reset_bank {
        // The production daemon never consumes a reset. Fetch its active
        // inventory before entering the journal transaction so network I/O
        // cannot monopolize the account-store lock.
        let mut prefetched_active_bank =
            (!consume_banked_resets).then(|| fetch_reset_bank_fn(&accounts[active_index]));
        let reset_result = {
            let store_lock = lock_account_store(store_path)?;
            validate_provider_io_activation_locked(&store_lock, auth_path, &activation_guard)
                .context("daemon activation changed during reset observation")?;
            orchestrate_pool_reset_with_selection_and_provider_guard(
                ResetOrchestrationContext {
                    store_lock: &store_lock,
                    accounts: &mut accounts,
                    active_index,
                    candidate_observations: candidate_observations.as_ref(),
                    allow_reset: consume_banked_resets,
                    direct_runtime_usage_limit,
                    operation_id: None,
                    refresh_strategy: ResetQuotaRefreshStrategy::RefreshExpiredToken,
                    now: Utc::now(),
                },
                ResetOrchestrationDependencies::new(
                    |account: &CodexAccount| match prefetched_active_bank.take() {
                        Some(result) => result,
                        None => fetch_reset_bank_fn(account),
                    },
                    |account: &mut CodexAccount, strategy| {
                        debug_assert_eq!(strategy, ResetQuotaRefreshStrategy::RefreshExpiredToken);
                        let result = fetch_quota_with_refresh(
                            &mut *account,
                            &fetch_quota_fn,
                            &refresh_token_fn,
                        )?;
                        apply_fetch_result(account, result);
                        Ok(())
                    },
                    |account: &CodexAccount, bank: &RateLimitResetBank, request_id| {
                        consume_reset_fn(account, bank, request_id)
                    },
                    |accounts: &mut [CodexAccount], reset_account_index: usize| {
                        let target_id = accounts[reset_account_index].id;
                        let target_provider_account_id =
                            accounts[reset_account_index].account_id.clone();
                        let current = authority.require_record()?.clone();
                        if target_provider_account_id == current.desired_provider_account_id {
                            authority.mark_converging(Some(
                                "VPS banked-reset runtime convergence is pending",
                            ))?;
                        } else {
                            let (disposition, _) = authority.begin_target_request(
                                &target_provider_account_id,
                                Uuid::new_v4(),
                                current.epoch,
                                "daemon_banked_reset",
                            )?;
                            if !matches!(disposition, TargetRequestDisposition::Started) {
                                bail!("daemon reset authority transition was not newly serialized");
                            }
                        }
                        activate_with_under_runtime_lease(
                            &runtime_lease,
                            ActivationContext {
                                store_lock: &store_lock,
                                generation: &mut generation,
                                accounts,
                                auth_path,
                                target_id,
                                reload_enabled: false,
                            },
                            |_| {
                                bail!("runtime reload was requested during locked reset activation")
                            },
                        )
                    },
                ),
                &reset_selection_accounts,
                |store_lock| {
                    validate_provider_io_activation_locked(store_lock, auth_path, &activation_guard)
                },
            )
        };
        match reset_result {
            Ok(outcome) => match outcome.completion {
                Some(activation) => {
                    let reset_account_index = outcome.account_index;
                    let swapped = reset_account_index != active_index;
                    let activation = if activation.is_confirmed() {
                        activation
                    } else {
                        reconcile_activation_barrier_unlocked_under_runtime_lease(
                            &runtime_lease,
                            store_path,
                            auth_path,
                            true,
                            &reload_fn,
                        )?
                        .context("reset activation record disappeared before runtime convergence")?
                    };
                    let refreshed = load_store_snapshot(store_path)?;
                    accounts = refreshed.accounts;
                    if let Some(tick) = pending_activation_tick(&activation, base_interval) {
                        let detail = activation
                            .detail
                            .as_deref()
                            .unwrap_or("VPS banked-reset runtime convergence is pending");
                        authority.mark_degraded(detail)?;
                        return Ok(tick);
                    }
                    if let Err(error) = require_confirmed_activation(activation) {
                        let detail =
                            format!("VPS banked-reset convergence was not confirmed: {error:#}");
                        authority.mark_degraded(&detail)?;
                        return Err(error).context("daemon pool authority remains degraded");
                    }
                    authority.mark_stable()?;
                    println!(
                        "reconciled banked reset for {} ({}); {} reset(s) remain",
                        accounts[reset_account_index].email,
                        outcome
                            .reason
                            .map(|reason| reason.as_str())
                            .unwrap_or("pending_attempt"),
                        accounts[reset_account_index]
                            .rate_limit_reset_bank
                            .as_ref()
                            .map(|bank| bank.available_count)
                            .unwrap_or(0)
                    );
                    let next_interval =
                        next_poll_interval_for(&accounts[reset_account_index], base_interval);
                    return Ok(DaemonTick::settled(swapped, next_interval));
                }
                None if outcome.flow.suppresses_redemption() => eprintln!(
                    "banked reset remains unreconciled for {}; new redemption is suppressed{}",
                    accounts[outcome.account_index].email,
                    outcome
                        .flow
                        .detail
                        .as_deref()
                        .map(|detail| format!(": {detail}"))
                        .unwrap_or_default()
                ),
                None => {}
            },
            Err(error) => {
                let authority_transition_started = authority
                    .record()
                    .is_some_and(|record| record.phase != PoolAuthorityPhase::Stable);
                if authority_transition_started {
                    let detail = format!("VPS banked-reset reconciliation failed: {error:#}");
                    authority.mark_degraded(&detail)?;
                    return Err(error).context("daemon pool authority remains degraded");
                }
                eprintln!(
                    "warning: reset reconciliation failed for {}; continuing with normal rotation: {error:#}",
                    accounts[active_index].email
                );
            }
        }
    }

    let Some(target) = rotation_target else {
        if force_swap || active_is_blocked {
            commit_daemon_accounts(
                &runtime_lease,
                store_path,
                auth_path,
                &mut generation,
                &accounts,
                &activation_guard,
            )?;
            bail!("active account is blocked but no freshly confirmed usable candidate exists");
        }
        if active_poll_succeeded {
            validate_provider_io_activation(store_path, auth_path, &activation_guard)
                .context("daemon activation changed before final observation commit")?;
            let durable_state = activation_state(store_path)?;
            let requires_runtime_convergence =
                !auth_file_matches_account(auth_path, &accounts[active_index])
                    || durable_state.is_some_and(|state| {
                        matches!(
                            state,
                            ActivationState::Prepared
                                | ActivationState::FileOnly
                                | ActivationState::CommittedDegraded
                                | ActivationState::ManualReview
                        )
                    });
            if requires_runtime_convergence {
                let target_id = accounts[active_index].id;
                let activation = activate_with_unlocked_reload_under_runtime_lease(
                    &runtime_lease,
                    store_path,
                    auth_path,
                    &mut generation,
                    &mut accounts,
                    target_id,
                    true,
                    &reload_fn,
                );
                let activation = match activation {
                    Ok(outcome) => outcome,
                    Err(error) => {
                        let detail =
                            format!("VPS daemon same-target convergence failed: {error:#}");
                        authority.mark_degraded(&detail)?;
                        return Err(error).context("daemon pool authority remains degraded");
                    }
                };
                if let Some(tick) = pending_activation_tick(&activation, base_interval) {
                    let detail = activation
                        .detail
                        .as_deref()
                        .unwrap_or("VPS daemon same-target runtime convergence is pending");
                    authority.mark_degraded(detail)?;
                    return Ok(tick);
                }
                if let Err(error) = require_confirmed_activation(activation) {
                    let detail =
                        format!("VPS daemon same-target convergence was not confirmed: {error:#}");
                    authority.mark_degraded(&detail)?;
                    return Err(error).context("daemon pool authority remains degraded");
                }
            } else {
                commit_daemon_accounts(
                    &runtime_lease,
                    store_path,
                    auth_path,
                    &mut generation,
                    &accounts,
                    &activation_guard,
                )?;
            }
        } else {
            commit_daemon_accounts(
                &runtime_lease,
                store_path,
                auth_path,
                &mut generation,
                &accounts,
                &activation_guard,
            )?;
        }
        let next_interval = next_poll_interval_for(&accounts[active_index], base_interval);
        return Ok(DaemonTick::settled(false, next_interval));
    };

    if plan_upgrade_target.is_some() {
        eprintln!(
            "higher plan available; rotating from {} ({}) to {} ({})",
            accounts[active_index].email,
            accounts[active_index].normalized_plan_type(),
            target.email,
            target.normalized_plan_type()
        );
    }
    if target.account_id == active_id {
        commit_daemon_accounts(
            &runtime_lease,
            store_path,
            auth_path,
            &mut generation,
            &accounts,
            &activation_guard,
        )?;
        bail!(
            "selected candidate {} is already active; refusing same-account reload storm",
            target.email
        );
    }
    if quota_availability_at(&target, Utc::now()) != QuotaAvailability::Usable {
        commit_daemon_accounts(
            &runtime_lease,
            store_path,
            auth_path,
            &mut generation,
            &accounts,
            &activation_guard,
        )?;
        bail!("selected candidate was not freshly confirmed usable");
    }

    validate_provider_io_activation(store_path, auth_path, &activation_guard)
        .context("daemon activation changed before rotation")?;
    let authority_reason = if plan_upgrade_target.is_some() {
        "daemon_plan_upgrade"
    } else {
        "daemon_quota_rotation"
    };
    let request_id = Uuid::new_v4();
    let expected_epoch = authority.require_record()?.epoch;
    let (disposition, _) = authority.begin_target_request(
        &target.account_id,
        request_id,
        expected_epoch,
        authority_reason,
    )?;
    if !matches!(disposition, TargetRequestDisposition::Started) {
        bail!("daemon cross-target authority transition was not newly serialized");
    }
    let activation = activate_with_unlocked_reload_under_runtime_lease(
        &runtime_lease,
        store_path,
        auth_path,
        &mut generation,
        &mut accounts,
        target.id,
        true,
        &reload_fn,
    );
    let activation = match activation {
        Ok(outcome) => outcome,
        Err(error) => {
            let detail = format!("VPS daemon target activation failed: {error:#}");
            authority.mark_degraded(&detail)?;
            return Err(error).context("daemon pool authority remains degraded");
        }
    };
    if let Some(tick) = pending_activation_tick(&activation, base_interval) {
        let detail = activation
            .detail
            .as_deref()
            .unwrap_or("VPS daemon runtime convergence is pending");
        authority.mark_degraded(detail)?;
        return Ok(tick);
    }
    let summary = match require_confirmed_activation(activation) {
        Ok(summary) => summary,
        Err(error) => {
            let detail = format!("VPS daemon target convergence was not confirmed: {error:#}");
            authority.mark_degraded(&detail)?;
            return Err(error).context("daemon pool authority remains degraded");
        }
    };
    authority.mark_stable()?;
    println!(
        "swapped to {} and signaled {} Codex hot-swap process(es), restarted {}",
        target.email,
        summary.signaled.len(),
        summary.restarted.len()
    );
    Ok(DaemonTick::settled(true, base_interval))
}

fn recover_pool_authority_target<R>(
    runtime_lease: &RuntimeActivationLease,
    authority: &mut PoolAuthorityLock,
    store_path: &Path,
    auth_path: &Path,
    snapshot: AccountStoreSnapshot,
    base_interval: Duration,
    reload: &R,
) -> Result<DaemonTick>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    let record = authority.require_record()?.clone();
    let Some(target) = snapshot
        .accounts
        .iter()
        .find(|account| account.account_id == record.desired_provider_account_id)
        .cloned()
    else {
        let detail = format!(
            "pool-authority target {} is absent from the VPS account store",
            record.desired_provider_account_id
        );
        authority.mark_degraded(&detail)?;
        bail!("{detail}");
    };
    authority.mark_converging(Some("VPS same-target authority recovery is pending"))?;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let activation = activate_with_unlocked_reload_under_runtime_lease(
        runtime_lease,
        store_path,
        auth_path,
        &mut generation,
        &mut accounts,
        target.id,
        true,
        reload,
    );
    match activation {
        Ok(outcome) if outcome.is_confirmed() => {
            authority.mark_stable()?;
            Ok(DaemonTick::settled(false, base_interval))
        }
        Ok(outcome) => {
            let detail = outcome.detail.unwrap_or_else(|| {
                format!(
                    "VPS authority recovery remained {:?} without complete runtime confirmation",
                    outcome.state
                )
            });
            authority.mark_degraded(&detail)?;
            Ok(DaemonTick::runtime_convergence_pending(base_interval))
        }
        Err(error) => {
            let detail = format!("VPS same-target authority recovery failed: {error:#}");
            authority.mark_degraded(&detail)?;
            Err(error).context("VPS pool authority remains degraded")
        }
    }
}

fn require_confirmed_activation(outcome: ActivationOutcome) -> Result<ReloadSummary> {
    if outcome.is_confirmed() {
        return Ok(outcome.reload);
    }
    bail!(
        "activation did not publish as swapped ({:?}): {}",
        outcome.state,
        outcome.detail.as_deref().unwrap_or("no detail")
    )
}

fn refresh_rotation_candidates<F, T>(
    accounts: &mut [CodexAccount],
    fetch_quota_fn: &F,
    refresh_token_fn: &T,
) -> CurrentQuotaObservations
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
{
    let mut observations = CurrentQuotaObservations::new(Utc::now());
    for account in accounts.iter_mut().filter(|account| !account.is_active) {
        match fetch_quota_with_refresh(account, fetch_quota_fn, refresh_token_fn) {
            Ok(result) => {
                apply_fetch_result(account, result);
                observations.record_success(account);
            }
            Err(error) => {
                if let Some((reason, cooldown)) = poll_error_runtime_block(&error) {
                    let until = runtime_block_until(account, reason, cooldown);
                    mark_runtime_unusable(account, reason, until);
                }
            }
        }
    }
    observations
}

fn fetch_quota_with_refresh<F, T>(
    account: &mut CodexAccount,
    fetch_quota_fn: &F,
    refresh_token_fn: &T,
) -> Result<FetchResult>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
{
    let now = Utc::now();
    if account.runtime_unusable_at(now) && account.runtime_block_is_token_expired() {
        bail!(
            "current token_expired runtime block suppresses quota and refresh retry for {}",
            account.email
        );
    }
    match fetch_quota_fn(account) {
        Ok(result) if account.has_usable_inference_token_at(Utc::now()) => Ok(result),
        Ok(_) => bail!(
            "inference token expired or is inside the safety window for {}",
            account.email
        ),
        Err(error)
            if poll_error_runtime_block(&error).map(|(reason, _)| reason)
                == Some("token_expired") =>
        {
            eprintln!(
                "quota poll for {} hit expired access token; refreshing token and retrying once",
                account.email
            );
            if let Err(refresh_error) = refresh_token_fn(account) {
                eprintln!(
                    "warning: failed to refresh expired access token for {}: {refresh_error:#}",
                    account.email
                );
                return Err(error.context(format!(
                    "failed to refresh expired access token for {}",
                    account.email
                )));
            }
            if !account.has_usable_inference_token_at(Utc::now()) {
                bail!(
                    "refreshed inference token expired or is inside the safety window for {}",
                    account.email
                );
            }
            fetch_quota_fn(account)
        }
        Err(error) => Err(error),
    }
}

fn refresh_quota_observations_during_activation_barrier<F>(
    store_path: &Path,
    fetch_quota_fn: &F,
) -> Result<()>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
{
    refresh_quota_observations_during_activation_barrier_at(store_path, fetch_quota_fn, Utc::now())
}

fn refresh_quota_observations_during_activation_barrier_at<F>(
    store_path: &Path,
    fetch_quota_fn: &F,
    now: chrono::DateTime<Utc>,
) -> Result<()>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
{
    let (snapshot, expected_target) = {
        let store_lock = lock_account_store(store_path)?;
        let record = read_activation_record(&store_lock)?
            .context("degraded activation record disappeared before quota maintenance")?;
        if record.state != ActivationState::CommittedDegraded {
            bail!("activation is no longer committed-degraded; skipping quota maintenance");
        }
        (store_lock.load()?, record.target_account_id)
    };
    let mut accounts = snapshot.accounts;
    let active_index = accounts
        .iter()
        .position(|account| account.is_active)
        .context("no active account in store during degraded quota maintenance")?;
    if accounts[active_index].account_id != expected_target {
        bail!("degraded activation target no longer matches the active account");
    }
    let inactive_indices = degraded_activation_inactive_quota_indices(&accounts, now);

    let mut indices = Vec::with_capacity(1 + inactive_indices.len());
    indices.push(active_index);
    indices.extend(inactive_indices);

    for index in indices {
        match fetch_quota_fn(&accounts[index]) {
            Ok(result) => {
                apply_fetch_result(&mut accounts[index], result);
            }
            Err(error) => eprintln!(
                "warning: observational quota poll failed during degraded activation for {}: {error:#}",
                accounts[index].email
            ),
        }
    }
    Ok(())
}

fn degraded_activation_inactive_quota_indices(
    accounts: &[CodexAccount],
    now: chrono::DateTime<Utc>,
) -> Vec<usize> {
    let mut eligible = accounts
        .iter()
        .enumerate()
        .filter(|(_, account)| should_probe_inactive_account(account, now))
        .collect::<Vec<_>>();
    eligible.sort_unstable_by(|(_, left), (_, right)| {
        right
            .plan_priority()
            .cmp(&left.plan_priority())
            .then_with(|| left.account_id.cmp(&right.account_id))
            .then_with(|| left.id.cmp(&right.id))
    });
    if eligible.is_empty() {
        return Vec::new();
    }
    let count = eligible.len();
    let width = count.min(DEGRADED_ACTIVATION_INACTIVE_QUOTA_POLL_LIMIT);
    let bucket = now
        .timestamp()
        .div_euclid(DEGRADED_ACTIVATION_RETRY_SECONDS as i64)
        .rem_euclid(count as i64) as usize;
    let start = bucket.saturating_mul(DEGRADED_ACTIVATION_INACTIVE_QUOTA_POLL_LIMIT) % count;
    (0..width)
        .map(|offset| eligible[(start + offset) % count].0)
        .collect()
}

fn refresh_inactive_watch_account<F, T>(
    accounts: &mut [CodexAccount],
    now: chrono::DateTime<Utc>,
    rotation_interval: Duration,
    fetch_quota_fn: &F,
    refresh_token_fn: &T,
) where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
{
    let Some(index) = inactive_watch_account_index(accounts, now, rotation_interval) else {
        return;
    };
    let account = &mut accounts[index];
    match fetch_quota_with_refresh(account, fetch_quota_fn, refresh_token_fn) {
        Ok(result) => apply_fetch_result(account, result),
        Err(error) => {
            eprintln!(
                "warning: failed to probe inactive account {}: {error:#}",
                account.email
            );
            if let Some((reason, cooldown)) = poll_error_runtime_block(&error) {
                let until = runtime_block_until(account, reason, cooldown);
                mark_runtime_unusable(account, reason, until);
            }
        }
    }
}

fn inactive_watch_account_index(
    accounts: &[CodexAccount],
    now: chrono::DateTime<Utc>,
    rotation_interval: Duration,
) -> Option<usize> {
    let mut eligible = accounts
        .iter()
        .enumerate()
        .filter(|(_, account)| should_probe_inactive_account(account, now))
        .collect::<Vec<_>>();
    // For a stable eligible set, consecutive buckets visit every account once
    // before repeating while preserving a deterministic identity order.
    eligible.sort_unstable_by(|(_, left), (_, right)| {
        left.account_id
            .cmp(&right.account_id)
            .then_with(|| left.id.cmp(&right.id))
    });
    let eligible_count = i64::try_from(eligible.len()).ok()?;
    if eligible_count == 0 {
        return None;
    }
    let bucket_seconds = i64::try_from(rotation_interval.as_secs().max(1)).unwrap_or(i64::MAX);
    let bucket = now.timestamp().div_euclid(bucket_seconds);
    let slot = bucket.rem_euclid(eligible_count) as usize;
    eligible.get(slot).map(|(index, _)| *index)
}

fn refresh_stale_reset_bank_observations<B>(
    accounts: &mut [CodexAccount],
    now: chrono::DateTime<Utc>,
    fetch_reset_bank: &B,
) where
    B: Fn(&CodexAccount) -> Result<RateLimitResetBank>,
{
    for account in accounts {
        let snapshot_is_blocked = real_quota_snapshot(account)
            .is_some_and(|snapshot| snapshot.availability_at(now) == QuotaAvailability::Blocked);
        let runtime_allows_reset_provider_io =
            !account.runtime_unusable_at(now) || account.runtime_block_is_usage_limit();
        let resettable = account.plan_priority() >= 2
            && account.has_usable_inference_token_at(now)
            && runtime_allows_reset_provider_io
            && (snapshot_is_blocked || account.runtime_block_is_usage_limit());
        let bank_is_stale = account
            .rate_limit_reset_bank
            .as_ref()
            .map(|bank| bank.is_stale(now))
            .unwrap_or(true);
        if !resettable || !bank_is_stale {
            continue;
        }

        match fetch_reset_bank(account) {
            Ok(bank) => account.rate_limit_reset_bank = Some(bank),
            Err(error) => eprintln!(
                "warning: failed to refresh reset bank for blocked account {}: {error:#}",
                account.email
            ),
        }
    }
}

fn should_probe_inactive_account(account: &CodexAccount, now: chrono::DateTime<Utc>) -> bool {
    if account.is_active {
        return false;
    }
    if account.runtime_unusable_at(now) && !account.runtime_block_is_usage_limit() {
        return false;
    }
    let availability = quota_availability_at(account, now);
    if availability == QuotaAvailability::Blocked || account.runtime_block_is_usage_limit() {
        let Some(last_refresh) = last_refresh_unix_seconds(account) else {
            return true;
        };
        return now.timestamp() as f64 - last_refresh
            >= INACTIVE_EXHAUSTED_PLAN_UPGRADE_POLL_SECONDS as f64;
    }
    if availability == QuotaAvailability::Unknown || real_quota_snapshot(account).is_none() {
        let Some(last_refresh) = last_refresh_unix_seconds(account) else {
            return true;
        };
        return now.timestamp() as f64 - last_refresh >= INACTIVE_MISSING_QUOTA_POLL_SECONDS as f64;
    }
    if account.plan_priority() >= 4 {
        return false;
    }

    let interval = inactive_plan_upgrade_probe_interval(account);
    let Some(last_refresh) = last_refresh_unix_seconds(account) else {
        return true;
    };
    now.timestamp() as f64 - last_refresh >= interval.as_secs_f64()
}

fn inactive_plan_upgrade_probe_interval(account: &CodexAccount) -> Duration {
    if quota_availability_at(account, Utc::now()) != QuotaAvailability::Usable {
        Duration::from_secs(INACTIVE_EXHAUSTED_PLAN_UPGRADE_POLL_SECONDS)
    } else {
        Duration::from_secs(INACTIVE_PLAN_UPGRADE_POLL_SECONDS)
    }
}

fn last_refresh_unix_seconds(account: &CodexAccount) -> Option<f64> {
    account
        .last_refreshed
        .as_ref()
        .and_then(swift_reference_value_to_unix_seconds)
        .or_else(|| {
            account
                .quota_snapshot
                .as_ref()
                .map(|snapshot| snapshot.fetched_at.timestamp() as f64)
        })
}

fn swift_reference_value_to_unix_seconds(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|text| text.parse::<f64>().ok()))
        .map(|seconds| seconds + UNIX_TO_SWIFT_REFERENCE_SECONDS)
}

fn next_poll_interval_for(account: &CodexAccount, base_interval: Duration) -> Duration {
    let Some(snapshot) = &account.quota_snapshot else {
        return base_interval;
    };
    let Some(lowest_remaining) = snapshot.minimum_remaining_percent() else {
        return base_interval;
    };
    let fast_poll_seconds = if lowest_remaining <= CRITICAL_QUOTA_FAST_POLL_THRESHOLD_PERCENT {
        CRITICAL_QUOTA_FAST_POLL_SECONDS
    } else if lowest_remaining <= LOW_QUOTA_FAST_POLL_THRESHOLD_PERCENT {
        LOW_QUOTA_FAST_POLL_SECONDS
    } else {
        0
    };
    if fast_poll_seconds == 0 {
        return base_interval;
    }

    let fast_interval = Duration::from_secs(fast_poll_seconds);
    if base_interval == Duration::from_secs(0) {
        return fast_interval;
    }
    std::cmp::min(base_interval, fast_interval)
}

fn poll_error_runtime_block(error: &anyhow::Error) -> Option<(&'static str, ChronoDuration)> {
    let message = format!("{error:#}").to_ascii_lowercase();
    if message.contains("token expired") || message.contains("http 401") {
        return Some(("token_expired", ChronoDuration::days(30)));
    }
    if message.contains("insufficient_quota") || message.contains("usage limit") {
        return Some(("usage_limit", ChronoDuration::hours(6)));
    }
    None
}

fn runtime_block_until(
    account: &CodexAccount,
    reason: &str,
    cooldown: ChronoDuration,
) -> chrono::DateTime<Utc> {
    let fallback_until = Utc::now() + cooldown;
    if reason == "usage_limit" {
        usage_limit_runtime_block_until(account, fallback_until)
    } else {
        fallback_until
    }
}

pub fn run_loop(store_path: &Path, auth_path: &Path, interval: Duration) -> Result<()> {
    let mut was_fast_polling = false;
    let mut managed_readiness_cadence = ManagedReadinessCadence::default();
    loop {
        if let Err(error) = codex_update::maybe_spawn_daily_auto_install() {
            eprintln!("codex update check failed: {error:#}");
        }
        let tick_result = run_once_report_with_resets(
            DaemonTickContext {
                store_path,
                auth_path,
                base_interval: interval,
                consume_banked_resets: false,
            },
            DaemonTickDependencies::new(
                fetch_quota,
                refresh_account_tokens,
                fetch_rate_limit_reset_bank,
                |_account, _bank, _request_id| {
                    bail!("automatic banked reset redemption is disabled in the daemon")
                },
                reload_codex_hot_swap_processes,
            ),
        );
        let (tick_result, readiness_result) = maintain_managed_readiness_after_tick_with(
            tick_result,
            &mut managed_readiness_cadence,
            Instant::now(),
            Instant::now,
            || try_acquire_runtime_activation_lease(store_path),
            codex_update::managed_headless_app_server_identity,
            |identity| {
                maintain_managed_headless_app_server_ack(
                    identity,
                    auth_path,
                    MANAGED_READINESS_MINIMUM_ACK_REMAINING,
                )
            },
        );
        match readiness_result {
            Ok(ManagedReadinessTick::Renewed { pid }) => {
                eprintln!("renewed managed app-server hot-swap readiness for pid {pid}");
            }
            Ok(_) => {}
            Err(error) => {
                eprintln!("managed app-server readiness maintenance failed: {error:#}");
            }
        }
        let sleep_interval = complete_daemon_iteration_with_readiness(
            tick_result,
            interval,
            &mut was_fast_polling,
            &managed_readiness_cadence,
            Instant::now(),
        );
        std::thread::sleep(sleep_interval);
    }
}

fn complete_daemon_iteration_with_readiness(
    tick_result: Result<DaemonTick>,
    base_interval: Duration,
    was_fast_polling: &mut bool,
    managed_readiness_cadence: &ManagedReadinessCadence,
    now: Instant,
) -> Duration {
    complete_daemon_iteration(tick_result, base_interval, was_fast_polling)
        .min(managed_readiness_cadence.time_until_due(now))
}

fn complete_daemon_iteration(
    tick_result: Result<DaemonTick>,
    base_interval: Duration,
    was_fast_polling: &mut bool,
) -> Duration {
    match tick_result {
        Ok(tick) => {
            let is_fast_polling = tick.next_interval < base_interval;
            if is_fast_polling && !*was_fast_polling {
                eprintln!(
                    "active account low on quota; polling every {}s until the displayed-1% swap threshold",
                    tick.next_interval.as_secs()
                );
            } else if !is_fast_polling && *was_fast_polling {
                eprintln!("active account left low-quota fast polling");
            }
            *was_fast_polling = is_fast_polling;
            tick.next_interval
        }
        Err(error) => {
            eprintln!("daemon poll failed: {error:#}");
            *was_fast_polling = false;
            base_interval
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{
        CodexAccount, QuotaSnapshot, QuotaWindow, QuotaWindowKind, QuotaWindowRateLimitSource,
        QuotaWindowSlot, QuotaWindowSourceMetadata,
    };
    use crate::reload::HotSwapKernelExecutableIdentity;
    use anyhow::bail;
    use serde_json::json;
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;
    use uuid::Uuid;

    fn account(email: &str, active: bool, five_used: f64, weekly_used: f64) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: email.to_string(),
            access_token: crate::account_store::test_inference_token(
                Utc::now() + ChronoDuration::hours(1),
            ),
            refresh_token: format!("refresh-{email}"),
            id_token: format!("id-{email}"),
            account_id: email.to_string(),
            quota_snapshot: Some(QuotaSnapshot {
                allowed: Some(true),
                limit_reached: Some(false),
                fetched_at: Utc::now(),
                windows: vec![
                    window(QuotaWindowKind::FiveHour, five_used),
                    window(QuotaWindowKind::Weekly, weekly_used),
                ],
            }),
            plan_type: Some("pro".to_string()),
            last_refreshed: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: Some(true),
            five_hour_primed_at: None,
            runtime_unusable_until: None,
            runtime_unusable_reason: None,
            rate_limit_reset_bank: None,
            is_active: active,
        }
    }

    fn secure_temp_dir() -> Result<TempDir> {
        let temp = TempDir::new()?;
        std::fs::set_permissions(temp.path(), std::fs::Permissions::from_mode(0o700))?;
        Ok(temp)
    }

    fn window(kind: QuotaWindowKind, used_percent: f64) -> QuotaWindow {
        let duration_seconds = match kind {
            QuotaWindowKind::FiveHour => 18_000,
            QuotaWindowKind::Weekly => 604_800,
            QuotaWindowKind::Unknown => 86_400,
        };
        QuotaWindow {
            kind,
            duration_seconds,
            used_percent,
            resets_at: Utc::now() + ChronoDuration::seconds(duration_seconds as i64),
            source: QuotaWindowSourceMetadata::new(
                QuotaWindowRateLimitSource::Main,
                QuotaWindowSlot::Primary,
            ),
            hard_limit_reached: false,
        }
    }

    fn ready_fetch(account: &CodexAccount) -> Result<FetchResult> {
        let mut snapshot = account.quota_snapshot.clone().unwrap();
        snapshot.fetched_at = Utc::now();
        Ok(FetchResult {
            snapshot,
            plan_type: account.plan_type.clone().unwrap(),
        })
    }

    fn retain_weekly_only(account: &mut CodexAccount) {
        account
            .quota_snapshot
            .as_mut()
            .unwrap()
            .windows
            .retain(|window| window.kind == QuotaWindowKind::Weekly);
    }

    fn verified_reload_summary() -> ReloadSummary {
        ReloadSummary::default()
            .with_sighup_sent(vec![42])
            .with_signaled(vec![42])
            .with_topology_verified(true)
    }

    fn managed_readiness_identity(
        pid: i32,
        start_identity: &str,
    ) -> ManagedHeadlessAppServerIdentity {
        ManagedHeadlessAppServerIdentity {
            pid,
            owner_uid: 1001,
            executable: PathBuf::from("/opt/codex"),
            start_identity: start_identity.to_string(),
            kernel_executable_identity: HotSwapKernelExecutableIdentity {
                canonical_path: "/opt/codex".to_string(),
                device: 7,
                inode: u64::try_from(pid).unwrap_or_default(),
            },
        }
    }

    #[test]
    fn managed_readiness_no_work_tick_advances_cadence() -> Result<()> {
        let start = Instant::now();
        let mut cadence = ManagedReadinessCadence::default();
        let observations = std::cell::Cell::new(0);
        let maintenance_calls = std::cell::Cell::new(0);

        let mut tick = |now| {
            maintain_managed_readiness_with(
                &mut cadence,
                now,
                || now,
                || Ok(Some(())),
                || {
                    observations.set(observations.get() + 1);
                    Ok(None)
                },
                |_| {
                    maintenance_calls.set(maintenance_calls.get() + 1);
                    Ok(ManagedHeadlessAckMaintenance::Current)
                },
            )
        };

        assert_eq!(tick(start)?, ManagedReadinessTick::NoManagedRuntime);
        assert_eq!(
            tick(start + Duration::from_secs(59))?,
            ManagedReadinessTick::NotDue
        );
        assert_eq!(
            tick(start + Duration::from_secs(60))?,
            ManagedReadinessTick::NoManagedRuntime
        );
        assert_eq!(observations.get(), 2);
        assert_eq!(maintenance_calls.get(), 0);
        Ok(())
    }

    #[test]
    fn managed_readiness_healthy_ticks_do_not_signal_repeatedly() -> Result<()> {
        let start = Instant::now();
        let identity = managed_readiness_identity(42, "linux:current");
        let mut cadence = ManagedReadinessCadence::default();
        let maintenance_calls = std::cell::Cell::new(0);

        for offset in [0, 5, 10, 59] {
            let result = maintain_managed_readiness_with(
                &mut cadence,
                start + Duration::from_secs(offset),
                || start + Duration::from_secs(offset),
                || Ok(Some(())),
                || Ok(Some(identity.clone())),
                |_| {
                    maintenance_calls.set(maintenance_calls.get() + 1);
                    Ok(ManagedHeadlessAckMaintenance::Current)
                },
            )?;
            assert_eq!(
                result,
                if offset == 0 {
                    ManagedReadinessTick::Current
                } else {
                    ManagedReadinessTick::NotDue
                }
            );
        }

        assert_eq!(maintenance_calls.get(), 1);
        Ok(())
    }

    #[test]
    fn managed_readiness_failure_still_advances_cadence() {
        let start = Instant::now();
        let identity = managed_readiness_identity(42, "linux:unpatched");
        let mut cadence = ManagedReadinessCadence::default();
        let maintenance_calls = std::cell::Cell::new(0);

        let first = maintain_managed_readiness_with(
            &mut cadence,
            start,
            || start + Duration::from_secs(70),
            || Ok(Some(())),
            || Ok(Some(identity)),
            |_| {
                maintenance_calls.set(maintenance_calls.get() + 1);
                bail!("missing patch support")
            },
        );
        assert!(first.unwrap_err().to_string().contains("missing patch"));

        let second = maintain_managed_readiness_with(
            &mut cadence,
            start + Duration::from_secs(71),
            || panic!("not-due cadence requested a completion timestamp"),
            || -> Result<Option<()>> {
                panic!("not-due cadence tried to acquire the activation lease")
            },
            || panic!("cadence retry probed before it was due"),
            |_| panic!("cadence retry maintained before it was due"),
        );
        assert_eq!(second.unwrap(), ManagedReadinessTick::NotDue);
        assert_eq!(maintenance_calls.get(), 1);
    }

    #[test]
    fn managed_readiness_lease_contention_defers_without_reload_and_recovers() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let start = Instant::now();
        let identity = managed_readiness_identity(42, "linux:lease-recovery");
        let owner = acquire_runtime_activation_lease(&store_path)?;
        let mut cadence = ManagedReadinessCadence::default();
        let observations = std::cell::Cell::new(0);
        let reload_or_signal_calls = std::cell::Cell::new(0);

        let deferred = maintain_managed_readiness_with(
            &mut cadence,
            start,
            || start,
            || try_acquire_runtime_activation_lease(&store_path),
            || {
                observations.set(observations.get() + 1);
                Ok(Some(identity.clone()))
            },
            |_| {
                reload_or_signal_calls.set(reload_or_signal_calls.get() + 1);
                Ok(ManagedHeadlessAckMaintenance::Renewed { pid: identity.pid })
            },
        )?;

        assert_eq!(deferred, ManagedReadinessTick::DeferredForActivation);
        assert_eq!(observations.get(), 0);
        assert_eq!(reload_or_signal_calls.get(), 0);
        assert_eq!(
            cadence.time_until_due(start),
            MANAGED_READINESS_MAINTENANCE_INTERVAL
        );
        let not_due = maintain_managed_readiness_with(
            &mut cadence,
            start + Duration::from_secs(1),
            || panic!("not-due contention retry requested a completion timestamp"),
            || -> Result<Option<RuntimeActivationLease>> {
                panic!("not-due contention retry tried to acquire the activation lease")
            },
            || panic!("not-due contention retry observed the managed runtime"),
            |_| panic!("not-due contention retry attempted reload"),
        )?;
        assert_eq!(not_due, ManagedReadinessTick::NotDue);

        drop(owner);
        let recovered = maintain_managed_readiness_with(
            &mut cadence,
            start + MANAGED_READINESS_MAINTENANCE_INTERVAL,
            || start + MANAGED_READINESS_MAINTENANCE_INTERVAL,
            || try_acquire_runtime_activation_lease(&store_path),
            || {
                observations.set(observations.get() + 1);
                Ok(Some(identity.clone()))
            },
            |observed| {
                reload_or_signal_calls.set(reload_or_signal_calls.get() + 1);
                assert_eq!(observed, &identity);
                Ok(ManagedHeadlessAckMaintenance::Renewed { pid: observed.pid })
            },
        )?;

        assert_eq!(
            recovered,
            ManagedReadinessTick::Renewed { pid: identity.pid }
        );
        assert_eq!(observations.get(), 1);
        assert_eq!(reload_or_signal_calls.get(), 1);
        Ok(())
    }

    #[test]
    fn failed_quota_tick_does_not_suppress_due_managed_readiness() -> Result<()> {
        let start = Instant::now();
        let identity = managed_readiness_identity(42, "linux:quota-failed");
        let failed_tick = Err(anyhow::anyhow!("quota API unavailable"));
        let mut cadence = ManagedReadinessCadence::default();
        let maintenance_calls = std::cell::Cell::new(0);

        let (failed_tick, readiness) = maintain_managed_readiness_after_tick_with(
            failed_tick,
            &mut cadence,
            start,
            || start,
            || Ok(Some(())),
            || Ok(Some(identity.clone())),
            |observed| {
                maintenance_calls.set(maintenance_calls.get() + 1);
                assert_eq!(observed, &identity);
                Ok(ManagedHeadlessAckMaintenance::Renewed { pid: observed.pid })
            },
        );
        let readiness = readiness?;
        assert!(failed_tick.is_err());
        let mut was_fast_polling = false;
        let sleep_interval = complete_daemon_iteration_with_readiness(
            failed_tick,
            Duration::from_secs(300),
            &mut was_fast_polling,
            &cadence,
            start,
        );

        assert_eq!(
            readiness,
            ManagedReadinessTick::Renewed { pid: identity.pid }
        );
        assert_eq!(maintenance_calls.get(), 1);
        assert_eq!(sleep_interval, MANAGED_READINESS_MAINTENANCE_INTERVAL);
        Ok(())
    }

    #[test]
    fn managed_readiness_detects_a_systemd_pid_restart_on_the_next_due_tick() -> Result<()> {
        let start = Instant::now();
        let original = managed_readiness_identity(42, "linux:original");
        let restarted = managed_readiness_identity(84, "linux:restarted");
        let mut cadence = ManagedReadinessCadence::default();

        let first = maintain_managed_readiness_with(
            &mut cadence,
            start,
            || start,
            || Ok(Some(())),
            || Ok(Some(original)),
            |_| Ok(ManagedHeadlessAckMaintenance::Current),
        )?;
        let second = maintain_managed_readiness_with(
            &mut cadence,
            start + MANAGED_READINESS_MAINTENANCE_INTERVAL,
            || start + MANAGED_READINESS_MAINTENANCE_INTERVAL,
            || Ok(Some(())),
            || Ok(Some(restarted.clone())),
            |identity| {
                assert_eq!(identity, &restarted);
                Ok(ManagedHeadlessAckMaintenance::Renewed { pid: identity.pid })
            },
        )?;

        assert_eq!(first, ManagedReadinessTick::Current);
        assert_eq!(second, ManagedReadinessTick::Renewed { pid: restarted.pid });
        Ok(())
    }

    fn confirm_daemon_activation(store_path: &Path, auth_path: &Path) -> Result<()> {
        let store_lock = lock_account_store(store_path)?;
        let snapshot = store_lock.load()?;
        let mut generation = snapshot.generation;
        let mut accounts = snapshot.accounts;
        let target_id = active_account(&accounts)
            .context("daemon test fixture requires one active account")?
            .id;
        let outcome = activate_with(
            ActivationContext {
                store_lock: &store_lock,
                generation: &mut generation,
                accounts: &mut accounts,
                auth_path,
                target_id,
                reload_enabled: true,
            },
            |_| Ok(verified_reload_summary()),
        )?;
        if !outcome.is_confirmed() {
            bail!("daemon test fixture did not publish Confirmed activation");
        }
        Ok(())
    }

    fn set_test_activation_state(store_path: &Path, state: ActivationState) -> Result<()> {
        let store_lock = lock_account_store(store_path)?;
        let mut record = read_activation_record(&store_lock)?
            .context("daemon test activation record disappeared")?;
        record.state = state;
        let path = crate::activation::activation_record_path(store_path);
        std::fs::write(&path, serde_json::to_vec_pretty(&record)?)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(())
    }

    fn assert_store_lock_available(store_path: &Path) -> Result<()> {
        let lock_path = store_path.with_extension("json.lock");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(&lock_path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            bail!(
                "account-store lock was held during callback: {}",
                std::io::Error::last_os_error()
            );
        }
        let unlock_result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        if unlock_result != 0 {
            bail!(
                "failed to release callback probe lock: {}",
                std::io::Error::last_os_error()
            );
        }
        Ok(())
    }

    fn assert_runtime_activation_lease_busy(store_path: &Path) -> Result<()> {
        let error = acquire_runtime_activation_lease(store_path)
            .err()
            .context("runtime-activation lease was unexpectedly acquirable")?;
        if !format!("{error:#}").contains("runtime activation is busy") {
            bail!("runtime-activation contention returned an unclear error: {error:#}");
        }
        Ok(())
    }

    fn reset_bank(available_count: u32, fetched_at: chrono::DateTime<Utc>) -> RateLimitResetBank {
        RateLimitResetBank {
            available_count,
            total_earned_count: 1,
            credits: (0..available_count)
                .map(|index| crate::rate_limit_resets::RateLimitResetCredit {
                    id: format!("credit-{index}"),
                    reset_type: Some("full".to_string()),
                    status: "available".to_string(),
                    granted_at: Some(fetched_at - ChronoDuration::days(1)),
                    expires_at: Some(fetched_at + ChronoDuration::days(10)),
                    redeem_started_at: None,
                    redeemed_at: None,
                    title: None,
                    description: None,
                })
                .collect(),
            fetched_at,
        }
    }

    fn set_weekly_reset_after(
        account: &mut CodexAccount,
        now: chrono::DateTime<Utc>,
        reset_after: ChronoDuration,
    ) {
        let snapshot = account.quota_snapshot.as_mut().unwrap();
        snapshot.fetched_at = now;
        snapshot.weekly_mut().unwrap().resets_at = now + reset_after;
    }

    #[test]
    fn daemon_refuses_followup_provider_io_and_commit_after_journal_only_transition() -> Result<()>
    {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        let store_before = std::fs::read(&store_path)?;

        let transition_path = store_path.clone();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                {
                    let quota_calls = Arc::clone(&quota_calls);
                    move |account| {
                        *quota_calls.lock().unwrap() += 1;
                        set_test_activation_state(&transition_path, ActivationState::Prepared)?;
                        ready_fetch(account)
                    }
                },
                |_account| Ok(()),
                {
                    let bank_calls = Arc::clone(&bank_calls);
                    move |_account| {
                        *bank_calls.lock().unwrap() += 1;
                        Ok(reset_bank(1, Utc::now()))
                    }
                },
                {
                    let consume_calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *consume_calls.lock().unwrap() += 1;
                        bail!("journal-only transition must prevent daemon reset POST")
                    }
                },
                |_| Ok(verified_reload_summary()),
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("changed activation journal"));
        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 0);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(std::fs::read(&store_path)?, store_before);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::Prepared
        );
        Ok(())
    }

    #[test]
    fn weekly_only_healthy_active_account_remains_usable() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 30.0);
        let mut standby = account("standby@example.com", false, 10.0, 20.0);
        retain_weekly_only(&mut active);
        retain_weekly_only(&mut standby);
        save_accounts(&store_path, &[active, standby])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!tick.swapped);
        assert_eq!(
            active_account(&load_accounts(&store_path)?).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        Ok(())
    }

    #[test]
    fn weekly_only_exhausted_and_denied_active_accounts_rotate() -> Result<()> {
        for denied in [false, true] {
            let temp = TempDir::new()?;
            let store_path = temp.path().join("accounts.json");
            let auth_path = temp.path().join("auth.json");
            let mut active = account("active@example.com", true, 10.0, 100.0);
            let mut replacement = account("replacement@example.com", false, 10.0, 20.0);
            retain_weekly_only(&mut active);
            retain_weekly_only(&mut replacement);
            if denied {
                let snapshot = active.quota_snapshot.as_mut().unwrap();
                snapshot.weekly_mut().unwrap().used_percent = 30.0;
                snapshot.allowed = Some(false);
                snapshot.limit_reached = Some(true);
            }
            save_accounts(&store_path, &[active, replacement])?;
            confirm_daemon_activation(&store_path, &auth_path)?;

            let tick = run_once_report_with(
                &store_path,
                &auth_path,
                Duration::from_secs(300),
                ready_fetch,
                |_| Ok(()),
                |_| Ok(verified_reload_summary()),
            )?;

            assert!(tick.swapped);
            assert_eq!(
                active_account(&load_accounts(&store_path)?).map(|account| account.email.as_str()),
                Some("replacement@example.com")
            );
        }
        Ok(())
    }

    #[test]
    fn failed_candidate_refresh_cannot_select_a_healthy_cached_snapshot() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        save_accounts(
            &store_path,
            &[
                account("active@example.com", true, 100.0, 100.0),
                account("cached@example.com", false, 10.0, 10.0),
            ],
        )?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let error = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            |account| {
                if account.email == "cached@example.com" {
                    bail!("candidate refresh unavailable");
                }
                ready_fetch(account)
            },
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("no freshly confirmed usable candidate"));
        assert_eq!(
            active_account(&load_accounts(&store_path)?).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        Ok(())
    }

    #[test]
    fn unknown_active_quota_stays_unknown_when_no_candidate_refresh_succeeds() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 10.0);
        active.quota_snapshot.as_mut().unwrap().windows =
            vec![window(QuotaWindowKind::Unknown, 100.0)];
        save_accounts(
            &store_path,
            &[active, account("cached@example.com", false, 10.0, 10.0)],
        )?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            |account| {
                if account.email == "cached@example.com" {
                    bail!("candidate refresh unavailable");
                }
                ready_fetch(account)
            },
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!tick.swapped);
        let stored = load_accounts(&store_path)?;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.email, "active@example.com");
        assert_eq!(
            quota_availability_at(active, Utc::now()),
            QuotaAvailability::Unknown
        );
        Ok(())
    }

    #[test]
    fn active_token_expired_refreshes_and_retries_without_rotating() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("expired@example.com", true, 10.0, 10.0);
        active.access_token = "stale-access".to_string();
        active.refresh_token = "stale-refresh".to_string();
        let accounts = vec![active, account("ready@example.com", false, 10.0, 10.0)];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let refreshed = Arc::new(Mutex::new(false));
        let refreshed_for_closure = Arc::clone(&refreshed);
        let rotated = run_once_with_refresh(
            &store_path,
            &auth_path,
            |account| {
                if account.email == "expired@example.com" && account.access_token == "stale-access"
                {
                    bail!("token expired for {}", account.email);
                }
                ready_fetch(account)
            },
            move |account| {
                account.access_token = crate::account_store::test_inference_token(
                    Utc::now() + ChronoDuration::hours(1),
                );
                account.refresh_token = "fresh-refresh".to_string();
                *refreshed_for_closure.lock().unwrap() = true;
                Ok(())
            },
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!rotated);
        assert!(*refreshed.lock().unwrap());
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("expired@example.com")
        );
        let active = stored
            .iter()
            .find(|account| account.email == "expired@example.com")
            .unwrap();
        assert!(active.has_usable_inference_token_at(Utc::now()));
        assert_eq!(active.refresh_token, "fresh-refresh");
        assert_eq!(active.runtime_unusable_reason.as_deref(), None);
        let auth: serde_json::Value = serde_json::from_slice(&std::fs::read(auth_path)?)?;
        assert_eq!(
            auth.pointer("/tokens/account_id")
                .and_then(|value| value.as_str()),
            Some("expired@example.com")
        );
        assert_eq!(
            auth.pointer("/tokens/access_token")
                .and_then(|value| value.as_str()),
            Some(active.access_token.as_str())
        );
        Ok(())
    }

    #[test]
    fn current_token_expired_block_suppresses_quota_and_refresh_provider_io() {
        let now = Utc::now();
        let mut blocked = account("blocked@example.com", true, 10.0, 10.0);
        mark_runtime_unusable(
            &mut blocked,
            "token_expired",
            now + ChronoDuration::days(30),
        );
        let calls = Arc::new(Mutex::new((0usize, 0usize)));
        let fetch_calls = Arc::clone(&calls);
        let refresh_calls = Arc::clone(&calls);

        let error = fetch_quota_with_refresh(
            &mut blocked,
            &move |_| {
                fetch_calls.lock().unwrap().0 += 1;
                bail!("quota provider must not be called")
            },
            &move |_| {
                refresh_calls.lock().unwrap().1 += 1;
                bail!("refresh provider must not be called")
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("suppresses quota and refresh retry"));
        assert_eq!(*calls.lock().unwrap(), (0, 0));
    }

    #[test]
    fn active_token_expired_rotates_when_refresh_fails() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let accounts = vec![
            account("expired@example.com", true, 10.0, 10.0),
            account("ready@example.com", false, 10.0, 10.0),
        ];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let rotated = run_once_with_refresh(
            &store_path,
            &auth_path,
            |account| {
                if account.email == "expired@example.com" {
                    bail!("token expired for {}", account.email);
                }
                ready_fetch(account)
            },
            |_account| bail!("refresh token already used"),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(rotated);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        assert_eq!(
            stored
                .iter()
                .find(|account| account.email == "expired@example.com")
                .and_then(|account| account.runtime_unusable_reason.as_deref()),
            Some("token_expired")
        );
        let auth: serde_json::Value = serde_json::from_slice(&std::fs::read(auth_path)?)?;
        assert_eq!(
            auth.pointer("/tokens/account_id")
                .and_then(|value| value.as_str()),
            Some("ready@example.com")
        );
        Ok(())
    }

    #[test]
    fn missing_activation_blocks_daemon_before_provider_io() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;

        let quota_calls = Arc::new(Mutex::new(0usize));
        let quota_calls_for_closure = Arc::clone(&quota_calls);
        let error = run_once_with(
            &store_path,
            &auth_path,
            move |account| {
                *quota_calls_for_closure.lock().unwrap() += 1;
                ready_fetch(account)
            },
            |_| Ok(verified_reload_summary()),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("durable Confirmed activation record"));
        assert_eq!(*quota_calls.lock().unwrap(), 0);
        assert!(!auth_path.exists());
        Ok(())
    }

    #[test]
    fn healthy_plus_rotates_to_ready_pro() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active-plus@example.com", true, 10.0, 10.0);
        active.plan_type = Some("plus".to_string());
        let mut ready_plus = account("ready-plus@example.com", false, 0.0, 0.0);
        ready_plus.plan_type = Some("plus".to_string());
        let ready_pro = account("ready-pro@example.com", false, 90.0, 70.0);
        save_accounts(&store_path, &[active, ready_plus, ready_pro])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let reloads = Arc::new(Mutex::new(0usize));
        let reloads_for_closure = Arc::clone(&reloads);
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            move |_| {
                *reloads_for_closure.lock().unwrap() += 1;
                Ok(verified_reload_summary())
            },
        )?;

        assert!(tick.swapped);
        assert_eq!(*reloads.lock().unwrap(), 1);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready-pro@example.com")
        );
        let auth: serde_json::Value = serde_json::from_slice(&std::fs::read(auth_path)?)?;
        assert_eq!(
            auth.pointer("/tokens/account_id")
                .and_then(|value| value.as_str()),
            Some("ready-pro@example.com")
        );
        Ok(())
    }

    #[test]
    fn mismatched_auth_blocks_daemon_before_provider_io() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 10.0);
        active.access_token = "fresh-token".to_string();
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        std::fs::write(
            &auth_path,
            b"{\"tokens\":{\"access_token\":\"stale-token\"}}",
        )?;

        let quota_calls = Arc::new(Mutex::new(0usize));
        let quota_calls_for_closure = Arc::clone(&quota_calls);
        let reloads = Arc::new(Mutex::new(0usize));
        let reloads_for_closure = Arc::clone(&reloads);
        let error = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            move |account| {
                *quota_calls_for_closure.lock().unwrap() += 1;
                ready_fetch(account)
            },
            |_| Ok(()),
            move |_| {
                *reloads_for_closure.lock().unwrap() += 1;
                Ok(ReloadSummary::default()
                    .with_sighup_sent(vec![42])
                    .with_signaled(vec![42])
                    .with_topology_verified(true))
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("stale or does not match current store/auth state"));
        assert_eq!(*quota_calls.lock().unwrap(), 0);
        assert_eq!(*reloads.lock().unwrap(), 0);
        assert!(std::fs::read_to_string(auth_path)?.contains("stale-token"));
        Ok(())
    }

    #[test]
    fn healthy_active_reload_is_not_signaled_when_auth_is_unchanged() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let reloads = Arc::new(Mutex::new(0usize));
        let reloads_for_closure = Arc::clone(&reloads);
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            move |_| {
                *reloads_for_closure.lock().unwrap() += 1;
                Ok(verified_reload_summary())
            },
        )?;

        assert!(!tick.swapped);
        assert_eq!(*reloads.lock().unwrap(), 0);
        Ok(())
    }

    #[test]
    fn daemon_network_callbacks_run_without_the_account_store_lock() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        save_accounts(
            &store_path,
            &[
                account("active@example.com", true, 100.0, 100.0),
                account("replacement@example.com", false, 10.0, 10.0),
            ],
        )?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let quota_store_path = store_path.clone();
        let bank_store_path = store_path.clone();
        let reload_store_path = store_path.clone();
        let callback_kinds = Arc::new(Mutex::new(Vec::new()));
        let quota_callbacks = Arc::clone(&callback_kinds);
        let bank_callbacks = Arc::clone(&callback_kinds);
        let reload_callbacks = Arc::clone(&callback_kinds);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: false,
            },
            DaemonTickDependencies::new(
                move |account| {
                    assert_store_lock_available(&quota_store_path)?;
                    quota_callbacks.lock().unwrap().push("quota");
                    ready_fetch(account)
                },
                |_| Ok(()),
                move |_account| {
                    assert_store_lock_available(&bank_store_path)?;
                    bank_callbacks.lock().unwrap().push("reset_bank");
                    Ok(reset_bank(0, Utc::now()))
                },
                |_account, _bank, _request_id| {
                    bail!("the default daemon must not consume a banked reset")
                },
                move |_| {
                    assert_store_lock_available(&reload_store_path)?;
                    reload_callbacks.lock().unwrap().push("reload");
                    Ok(verified_reload_summary())
                },
            ),
        )?;

        assert!(tick.swapped);
        let callback_kinds = callback_kinds.lock().unwrap();
        assert!(callback_kinds.contains(&"quota"));
        assert!(callback_kinds.contains(&"reset_bank"));
        assert!(callback_kinds.contains(&"reload"));
        Ok(())
    }

    #[test]
    fn degraded_barrier_quota_maintenance_never_commits_observations() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 10.0);
        let mut fallback = account("fallback@example.com", false, 0.0, 0.0);
        let stale_at = Utc::now()
            - crate::account_store::QUOTA_OBSERVATION_MAX_AGE
            - ChronoDuration::milliseconds(1);
        active.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
        fallback.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
        save_accounts(&store_path, &[active, fallback])?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        set_test_activation_state(&store_path, ActivationState::CommittedDegraded)?;
        let first_tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::ZERO,
            ready_fetch,
            |_| Ok(()),
            |_| Ok(ReloadSummary::default().with_skipped(vec![(42, "ack timeout".to_string())])),
        )?;
        assert_eq!(
            first_tick.next_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );
        let mut original = load_accounts(&store_path)?;
        for account in &mut original {
            account.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
            account.last_refreshed = None;
        }
        save_accounts(&store_path, &original)?;
        let store_before = std::fs::read(&store_path)?;
        let auth_before = std::fs::read(&auth_path)?;
        let calls = Arc::new(Mutex::new(Vec::new()));
        let observed_calls = Arc::clone(&calls);

        refresh_quota_observations_during_activation_barrier(&store_path, &move |account| {
            observed_calls.lock().unwrap().push(account.email.clone());
            let mut result = ready_fetch(account)?;
            result.snapshot.weekly_mut().unwrap().used_percent = 25.0;
            Ok(result)
        })?;

        assert_eq!(
            *calls.lock().unwrap(),
            vec![
                "active@example.com".to_string(),
                "fallback@example.com".to_string()
            ]
        );
        assert_eq!(std::fs::read(&auth_path)?, auth_before);
        assert_eq!(std::fs::read(&store_path)?, store_before);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        assert_eq!(stored.len(), original.len());
        Ok(())
    }

    #[test]
    fn degraded_barrier_inactive_quota_maintenance_is_bounded_and_fair() {
        const INACTIVE_COUNT: usize = 9;
        let bucket_seconds = DEGRADED_ACTIVATION_RETRY_SECONDS as i64;
        let first_bucket = Utc::now().timestamp().div_euclid(bucket_seconds);
        let first_time =
            chrono::DateTime::<Utc>::from_timestamp(first_bucket * bucket_seconds, 0).unwrap();
        let stale_at = first_time
            - crate::account_store::QUOTA_OBSERVATION_MAX_AGE
            - ChronoDuration::milliseconds(1);
        let mut accounts = vec![account("active@example.com", true, 10.0, 10.0)];
        for index in 0..INACTIVE_COUNT {
            let mut inactive = account(
                &format!("inactive-{index:02}@example.com"),
                false,
                10.0,
                10.0,
            );
            inactive.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
            inactive.last_refreshed = None;
            accounts.push(inactive);
        }

        let mut visited = Vec::new();
        for offset in 0..3 {
            let selected = degraded_activation_inactive_quota_indices(
                &accounts,
                first_time + ChronoDuration::seconds(bucket_seconds * offset),
            );
            assert_eq!(
                selected.len(),
                DEGRADED_ACTIVATION_INACTIVE_QUOTA_POLL_LIMIT
            );
            visited.extend(
                selected
                    .into_iter()
                    .map(|index| accounts[index].email.clone()),
            );
            // Leaving every snapshot unchanged models a full failed-probe pass.
        }
        visited.sort_unstable();
        visited.dedup();
        assert_eq!(visited.len(), INACTIVE_COUNT);
    }

    #[test]
    fn degraded_quota_generation_race_preserves_newer_store_and_backoff() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        save_accounts(
            &store_path,
            &[
                account("active@example.com", true, 10.0, 10.0),
                account("fallback@example.com", false, 0.0, 0.0),
            ],
        )?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        set_test_activation_state(&store_path, ActivationState::CommittedDegraded)?;

        let first_tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::ZERO,
            ready_fetch,
            |_| Ok(()),
            |_| Ok(ReloadSummary::default().with_skipped(vec![(42, "ack timeout".to_string())])),
        )?;
        assert_eq!(
            first_tick.next_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );

        let raced = Arc::new(Mutex::new(false));
        let raced_for_fetch = Arc::clone(&raced);
        let race_store_path = store_path.clone();
        let refresh_calls = Arc::new(Mutex::new(0usize));
        let reset_bank_calls = Arc::new(Mutex::new(0usize));
        let reset_consume_calls = Arc::new(Mutex::new(0usize));
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(5),
                consume_banked_resets: false,
            },
            DaemonTickDependencies::new(
                move |account| {
                    let mut raced = raced_for_fetch.lock().unwrap();
                    if !*raced {
                        let mut concurrent = load_accounts(&race_store_path)?;
                        concurrent[0].subscription_will_renew = Some(false);
                        save_accounts(&race_store_path, &concurrent)?;
                        *raced = true;
                    }
                    ready_fetch(account)
                },
                {
                    let calls = Arc::clone(&refresh_calls);
                    move |_| {
                        *calls.lock().unwrap() += 1;
                        Ok(())
                    }
                },
                {
                    let calls = Arc::clone(&reset_bank_calls);
                    move |_| {
                        *calls.lock().unwrap() += 1;
                        Ok(reset_bank(0, Utc::now()))
                    }
                },
                {
                    let calls = Arc::clone(&reset_consume_calls);
                    move |_account, _bank, _request_id| {
                        *calls.lock().unwrap() += 1;
                        bail!("reset consumption must remain unreachable")
                    }
                },
                |_| Ok(ReloadSummary::default().with_skipped(vec![(42, "ack timeout".to_string())])),
            ),
        )?;

        assert_eq!(
            tick.next_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );
        assert!(*raced.lock().unwrap());
        assert_eq!(*refresh_calls.lock().unwrap(), 0);
        assert_eq!(*reset_bank_calls.lock().unwrap(), 0);
        assert_eq!(*reset_consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        assert_eq!(stored[0].subscription_will_renew, Some(false));
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            read_activation_record(&store_lock)?.unwrap().state,
            ActivationState::CommittedDegraded
        );
        Ok(())
    }

    #[test]
    fn degraded_activation_stays_degraded_until_a_later_verified_ack() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        save_accounts(
            &store_path,
            &[
                account("active@example.com", true, 100.0, 100.0),
                account("replacement@example.com", false, 10.0, 10.0),
            ],
        )?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let first_tick =
            run_once_report_with(
                &store_path,
                &auth_path,
                Duration::ZERO,
                ready_fetch,
                |_| Ok(()),
                {
                    let store_path = store_path.clone();
                    move |_| {
                        assert_store_lock_available(&store_path)?;
                        Ok(ReloadSummary::default()
                            .with_skipped(vec![(42, "ack timeout".to_string())]))
                    }
                },
            )?;
        assert!(!first_tick.swapped);
        assert_eq!(
            first_tick.next_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            crate::activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            crate::activation::ActivationState::CommittedDegraded
        );
        let generation_after_first = store_lock.load()?.generation;
        drop(store_lock);

        let second_tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::ZERO,
            ready_fetch,
            |_| Ok(()),
            {
                let store_path = store_path.clone();
                move |_| {
                    assert_store_lock_available(&store_path)?;
                    Ok(ReloadSummary::default())
                }
            },
        )?;
        assert!(!second_tick.swapped);
        assert_eq!(
            second_tick.next_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            crate::activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            crate::activation::ActivationState::CommittedDegraded
        );
        assert_eq!(store_lock.load()?.generation, generation_after_first);
        drop(store_lock);

        let converged = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::ZERO,
            ready_fetch,
            |_| Ok(()),
            {
                let store_path = store_path.clone();
                move |_| {
                    assert_store_lock_available(&store_path)?;
                    Ok(ReloadSummary::default()
                        .with_signaled(vec![42])
                        .with_topology_verified(true))
                }
            },
        )?;
        assert!(!converged.swapped);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            crate::activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            crate::activation::ActivationState::Confirmed
        );
        Ok(())
    }

    #[test]
    fn degraded_activation_tick_backs_off_without_auxiliary_reload() {
        let mut was_fast_polling = true;
        let sleep_interval = complete_daemon_iteration(
            Ok(DaemonTick::runtime_convergence_pending(Duration::ZERO)),
            Duration::ZERO,
            &mut was_fast_polling,
        );

        assert_eq!(
            sleep_interval,
            Duration::from_secs(DEGRADED_ACTIVATION_RETRY_SECONDS)
        );
        assert!(!was_fast_polling);
    }

    #[test]
    fn daemon_has_no_legacy_broad_ack_bootstrap_scheduler() {
        let source = include_str!("daemon.rs");
        for forbidden in [
            concat!("HOT_SWAP_ACK_", "RENEWAL_INTERVAL"),
            concat!("run_ack_", "bootstrap"),
            concat!("allow_ack_", "bootstrap"),
            concat!("requiring_ack_", "bootstrap"),
        ] {
            assert!(
                !source.contains(forbidden),
                "daemon reintroduced legacy broad runtime signaling through {forbidden}"
            );
        }
    }

    #[test]
    fn manual_review_barrier_blocks_daemon_network_and_reload_callbacks() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        write_auth_file(&auth_path, &active)?;

        let store_lock = lock_account_store(&store_path)?;
        let generation = store_lock.load()?.generation;
        let record = crate::activation::ActivationRecord {
            version: 3,
            state: crate::activation::ActivationState::ManualReview,
            kind: crate::activation::ActivationKind::Rotation,
            previous_account_id: active.account_id.clone(),
            target_account_id: active.account_id.clone(),
            store_generation: generation.as_str().to_string(),
            auth_fingerprint: crate::auth::account_token_fingerprint(&active),
            base_store_generation: None,
            owned_store_generation: None,
            base_auth_generation: None,
            owned_auth_generation: None,
            rollback: None,
            detail: Some("operator review is required".to_string()),
            updated_at: Utc::now(),
        };
        let activation_path = crate::activation::activation_record_path(&store_path);
        std::fs::write(&activation_path, serde_json::to_vec_pretty(&record)?)?;
        std::fs::set_permissions(&activation_path, std::fs::Permissions::from_mode(0o600))?;
        drop(store_lock);

        let fetch_calls = Arc::new(Mutex::new(0usize));
        let tick_reload_calls = Arc::new(Mutex::new(0usize));
        let tick_result = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            {
                let calls = Arc::clone(&fetch_calls);
                move |account| {
                    *calls.lock().unwrap() += 1;
                    ready_fetch(account)
                }
            },
            |_| Ok(()),
            {
                let calls = Arc::clone(&tick_reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        );
        assert!(tick_result.is_err());
        assert_eq!(*fetch_calls.lock().unwrap(), 0);
        assert_eq!(*tick_reload_calls.lock().unwrap(), 0);

        let mut was_fast_polling = true;
        let sleep_interval =
            complete_daemon_iteration(tick_result, Duration::from_secs(300), &mut was_fast_polling);
        assert_eq!(sleep_interval, Duration::from_secs(300));
        assert!(!was_fast_polling);
        Ok(())
    }

    #[test]
    fn telemetry_only_confirmed_generation_drift_stays_current() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        write_auth_file(&auth_path, &active)?;

        let record = crate::activation::ActivationRecord {
            version: 3,
            state: crate::activation::ActivationState::Confirmed,
            kind: crate::activation::ActivationKind::Rotation,
            previous_account_id: active.account_id.clone(),
            target_account_id: active.account_id.clone(),
            store_generation: "prospective-generation-that-never-committed".to_string(),
            auth_fingerprint: crate::auth::account_token_fingerprint(&active),
            base_store_generation: None,
            owned_store_generation: None,
            base_auth_generation: None,
            owned_auth_generation: None,
            rollback: None,
            detail: None,
            updated_at: Utc::now(),
        };
        let activation_path = crate::activation::activation_record_path(&store_path);
        std::fs::write(&activation_path, serde_json::to_vec_pretty(&record)?)?;
        std::fs::set_permissions(&activation_path, std::fs::Permissions::from_mode(0o600))?;

        let fetch_calls = Arc::new(Mutex::new(0usize));
        let reload_calls = Arc::new(Mutex::new(0usize));
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            {
                let calls = Arc::clone(&fetch_calls);
                move |account| {
                    *calls.lock().unwrap() += 1;
                    ready_fetch(account)
                }
            },
            |_| Ok(()),
            {
                let calls = Arc::clone(&reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        )?;

        assert!(!tick.swapped);
        assert_eq!(*fetch_calls.lock().unwrap(), 1);
        assert_eq!(*reload_calls.lock().unwrap(), 0);
        let store_lock = lock_account_store(&store_path)?;
        let current = store_lock.load()?;
        let confirmed = crate::activation::read_activation_record(&store_lock)?
            .context("telemetry drift lost the durable activation record")?;
        assert_eq!(
            confirmed.state,
            crate::activation::ActivationState::Confirmed
        );
        assert_eq!(confirmed.target_account_id, active.account_id);
        assert_ne!(confirmed.store_generation, current.generation.as_str());
        assert_eq!(
            confirmed.auth_fingerprint,
            crate::auth::account_token_fingerprint(&active)
        );
        Ok(())
    }

    #[test]
    fn stale_cross_target_confirmed_generation_blocks_before_provider_io() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        write_auth_file(&auth_path, &active)?;

        let record = crate::activation::ActivationRecord {
            version: 3,
            state: crate::activation::ActivationState::Confirmed,
            kind: crate::activation::ActivationKind::Rotation,
            previous_account_id: active.account_id.clone(),
            target_account_id: "different-provider-account".to_string(),
            store_generation: "prospective-generation-that-never-committed".to_string(),
            auth_fingerprint: crate::auth::account_token_fingerprint(&active),
            base_store_generation: None,
            owned_store_generation: None,
            base_auth_generation: None,
            owned_auth_generation: None,
            rollback: None,
            detail: None,
            updated_at: Utc::now(),
        };
        let activation_path = crate::activation::activation_record_path(&store_path);
        std::fs::write(&activation_path, serde_json::to_vec_pretty(&record)?)?;
        std::fs::set_permissions(&activation_path, std::fs::Permissions::from_mode(0o600))?;

        let fetch_calls = Arc::new(Mutex::new(0usize));
        let reload_calls = Arc::new(Mutex::new(0usize));
        let error = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            {
                let calls = Arc::clone(&fetch_calls);
                move |account| {
                    *calls.lock().unwrap() += 1;
                    ready_fetch(account)
                }
            },
            |_| Ok(()),
            {
                let calls = Arc::clone(&reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("durable Confirmed activation is stale"));
        assert_eq!(*fetch_calls.lock().unwrap(), 0);
        assert_eq!(*reload_calls.lock().unwrap(), 0);
        Ok(())
    }

    #[test]
    fn active_below_five_percent_fast_polls_without_rotating_before_one_percent() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let accounts = vec![
            account("active@example.com", true, 96.0, 10.0),
            account("ready@example.com", false, 10.0, 10.0),
        ];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!tick.swapped);
        assert_eq!(tick.next_interval, Duration::from_secs(2));
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        Ok(())
    }

    #[test]
    fn inactive_non_pro_exhausted_account_is_probed_for_plan_upgrade() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 10.0);
        active.plan_type = Some("pro".to_string());
        let mut upgraded = account("upgrade@example.com", false, 100.0, 94.0);
        upgraded.plan_type = Some("prolite".to_string());
        upgraded.last_refreshed = None;
        upgraded.quota_snapshot.as_mut().unwrap().fetched_at =
            Utc::now() - ChronoDuration::seconds(10);
        save_accounts(&store_path, &[active, upgraded])?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        let stored_before_tick = load_accounts(&store_path)?;
        let upgraded_before_tick = stored_before_tick
            .iter()
            .find(|account| account.email == "upgrade@example.com")
            .unwrap();
        assert!(
            should_probe_inactive_account(upgraded_before_tick, Utc::now()),
            "stored inactive account: {upgraded_before_tick:?}"
        );

        let fetched = Arc::new(Mutex::new(Vec::new()));
        let fetched_for_closure = Arc::clone(&fetched);
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            move |account| {
                fetched_for_closure
                    .lock()
                    .unwrap()
                    .push(account.email.clone());
                if account.email == "upgrade@example.com" {
                    let mut snapshot = account.quota_snapshot.clone().unwrap();
                    snapshot.five_hour_mut().unwrap().used_percent = 0.0;
                    snapshot.weekly_mut().unwrap().used_percent = 0.0;
                    return Ok(FetchResult {
                        snapshot,
                        plan_type: "pro".to_string(),
                    });
                }
                ready_fetch(account)
            },
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!tick.swapped);
        assert_eq!(
            fetched.lock().unwrap().as_slice(),
            [
                "active@example.com".to_string(),
                "upgrade@example.com".to_string()
            ]
        );
        let stored = load_accounts(&store_path)?;
        let upgraded = stored
            .iter()
            .find(|account| account.email == "upgrade@example.com")
            .unwrap();
        assert_eq!(upgraded.plan_type.as_deref(), Some("pro"));
        assert!(upgraded.last_refreshed.is_some());
        assert_eq!(
            upgraded
                .quota_snapshot
                .as_ref()
                .and_then(|snapshot| snapshot.five_hour())
                .map(QuotaWindow::remaining_percent),
            Some(100.0)
        );
        Ok(())
    }

    #[test]
    fn healthy_tick_bounds_many_stale_inactive_quota_probes() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        let stale_at = chrono::DateTime::<Utc>::from_timestamp(
            Utc::now().timestamp()
                - crate::account_store::QUOTA_OBSERVATION_MAX_AGE.num_seconds()
                - 1,
            0,
        )
        .unwrap();
        let mut accounts = vec![active.clone()];
        for index in 0..12 {
            let mut inactive = account(
                &format!("inactive-{index:02}@example.com"),
                false,
                10.0,
                10.0,
            );
            inactive.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
            inactive.last_refreshed = None;
            accounts.push(inactive);
        }
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let fetched = Arc::new(Mutex::new(Vec::new()));
        let fetched_for_closure = Arc::clone(&fetched);
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(5),
            move |account| {
                fetched_for_closure
                    .lock()
                    .unwrap()
                    .push(account.email.clone());
                if account.is_active {
                    ready_fetch(account)
                } else {
                    bail!("simulated slow quota timeout")
                }
            },
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(!tick.swapped);
        let fetched = fetched.lock().unwrap();
        assert_eq!(
            fetched.first().map(String::as_str),
            Some("active@example.com")
        );
        assert_eq!(fetched.len(), 2);
        assert_eq!(
            fetched
                .iter()
                .filter(|email| email.as_str() != "active@example.com")
                .count(),
            1
        );
        drop(fetched);

        for inactive in load_accounts(&store_path)?
            .into_iter()
            .filter(|account| !account.is_active)
        {
            assert!(inactive.last_refreshed.is_none());
            assert_eq!(inactive.quota_snapshot.unwrap().fetched_at, stale_at);
        }
        Ok(())
    }

    #[test]
    fn inactive_watch_scheduling_is_fair_across_successive_time_buckets() {
        const INACTIVE_COUNT: usize = 7;
        let rotation_interval = Duration::from_secs(5);
        let bucket_seconds = i64::try_from(rotation_interval.as_secs()).unwrap();
        let first_bucket = Utc::now().timestamp().div_euclid(bucket_seconds);
        let first_time =
            chrono::DateTime::<Utc>::from_timestamp(first_bucket * bucket_seconds, 0).unwrap();
        let stale_at = first_time
            - crate::account_store::QUOTA_OBSERVATION_MAX_AGE
            - ChronoDuration::seconds(1);
        let mut accounts = vec![account("active@example.com", true, 10.0, 10.0)];
        for index in 0..INACTIVE_COUNT {
            let mut inactive = account(
                &format!("inactive-{index:02}@example.com"),
                false,
                10.0,
                10.0,
            );
            inactive.quota_snapshot.as_mut().unwrap().fetched_at = stale_at;
            inactive.last_refreshed = None;
            accounts.push(inactive);
        }

        let selected = (0..INACTIVE_COUNT * 2)
            .map(|offset| {
                let now = first_time + ChronoDuration::seconds(bucket_seconds * offset as i64);
                let index =
                    inactive_watch_account_index(&accounts, now, rotation_interval).unwrap();
                accounts[index].email.clone()
            })
            .collect::<Vec<_>>();
        let mut unique_first_cycle = selected[..INACTIVE_COUNT].to_vec();
        unique_first_cycle.sort_unstable();
        unique_first_cycle.dedup();

        assert_eq!(unique_first_cycle.len(), INACTIVE_COUNT);
        assert_eq!(
            &selected[..INACTIVE_COUNT],
            &selected[INACTIVE_COUNT..INACTIVE_COUNT * 2]
        );
    }

    #[test]
    fn inactive_pro_account_with_quota_is_not_probed_for_upgrade() -> Result<()> {
        let now = Utc::now();
        let mut pro = account("pro@example.com", false, 10.0, 10.0);
        pro.plan_type = Some("pro".to_string());
        pro.quota_snapshot.as_mut().unwrap().fetched_at = now;
        pro.last_refreshed = None;
        assert!(!should_probe_inactive_account(&pro, now));
        Ok(())
    }

    #[test]
    fn inactive_exhausted_pro_account_is_probed_for_reset() -> Result<()> {
        let now = Utc::now();
        let mut pro = account("pro@example.com", false, 100.0, 32.0);
        pro.plan_type = Some("pro".to_string());
        pro.quota_snapshot.as_mut().unwrap().fetched_at = now;
        pro.last_refreshed = Some(json!(
            (now.timestamp() - UNIX_TO_SWIFT_REFERENCE_SECONDS as i64) as f64
        ));
        assert!(!should_probe_inactive_account(&pro, now));
        assert!(should_probe_inactive_account(
            &pro,
            now + ChronoDuration::seconds(INACTIVE_EXHAUSTED_PLAN_UPGRADE_POLL_SECONDS as i64)
        ));
        Ok(())
    }

    #[test]
    fn inactive_pro_account_missing_quota_is_probed() -> Result<()> {
        let now = Utc::now();
        let mut pro = account("pro@example.com", false, 100.0, 94.0);
        pro.plan_type = Some("pro".to_string());
        pro.quota_snapshot = None;
        pro.last_refreshed = None;
        assert!(should_probe_inactive_account(&pro, now));
        pro.last_refreshed = Some(json!(
            (now.timestamp() - UNIX_TO_SWIFT_REFERENCE_SECONDS as i64) as f64
        ));
        assert!(!should_probe_inactive_account(&pro, now));
        assert!(should_probe_inactive_account(
            &pro,
            now + ChronoDuration::seconds(INACTIVE_MISSING_QUOTA_POLL_SECONDS as i64)
        ));
        Ok(())
    }

    #[test]
    fn inactive_pro_account_with_stale_quota_is_probed() {
        let now = Utc::now();
        let mut pro = account("stale-pro@example.com", false, 10.0, 10.0);
        pro.plan_type = Some("pro".to_string());
        pro.quota_snapshot.as_mut().unwrap().fetched_at =
            now - crate::account_store::QUOTA_OBSERVATION_MAX_AGE - ChronoDuration::milliseconds(1);
        pro.last_refreshed = None;

        assert_eq!(quota_availability_at(&pro, now), QuotaAvailability::Unknown);
        assert!(should_probe_inactive_account(&pro, now));
    }

    #[test]
    fn inactive_pro_account_with_unknown_only_quota_is_probed() {
        let now = Utc::now();
        let mut pro = account("unknown-pro@example.com", false, 10.0, 10.0);
        pro.plan_type = Some("pro".to_string());
        pro.quota_snapshot.as_mut().unwrap().windows = vec![QuotaWindow {
            kind: QuotaWindowKind::Unknown,
            duration_seconds: 86_400,
            used_percent: 20.0,
            resets_at: now + ChronoDuration::days(1),
            source: QuotaWindowSourceMetadata::new(
                QuotaWindowRateLimitSource::Additional,
                QuotaWindowSlot::Primary,
            ),
            hard_limit_reached: false,
        }];
        pro.quota_snapshot.as_mut().unwrap().fetched_at = now;
        pro.last_refreshed = None;

        assert_eq!(quota_availability_at(&pro, now), QuotaAvailability::Unknown);
        assert!(!should_probe_inactive_account(&pro, now));
        assert!(should_probe_inactive_account(
            &pro,
            now + ChronoDuration::seconds(INACTIVE_MISSING_QUOTA_POLL_SECONDS as i64)
        ));
    }

    #[test]
    fn inactive_runtime_blocked_account_is_not_probed_for_upgrade() -> Result<()> {
        let now = Utc::now();
        let mut account = account("blocked@example.com", false, 100.0, 94.0);
        account.plan_type = Some("free".to_string());
        account.last_refreshed = None;
        mark_runtime_unusable(
            &mut account,
            "token_expired",
            now + ChronoDuration::days(30),
        );

        assert!(!should_probe_inactive_account(&account, now));
        Ok(())
    }

    #[test]
    fn inactive_usage_limit_blocked_account_is_probed_for_reset() -> Result<()> {
        let now = Utc::now();
        let mut account = account("blocked@example.com", false, 100.0, 32.0);
        account.plan_type = Some("pro".to_string());
        account.last_refreshed = Some(json!(
            (now.timestamp() - UNIX_TO_SWIFT_REFERENCE_SECONDS as i64) as f64
        ));
        mark_runtime_unusable(&mut account, "usage_limit", now + ChronoDuration::hours(1));

        assert!(!should_probe_inactive_account(&account, now));
        assert!(should_probe_inactive_account(
            &account,
            now + ChronoDuration::seconds(INACTIVE_EXHAUSTED_PLAN_UPGRADE_POLL_SECONDS as i64)
        ));
        Ok(())
    }

    #[test]
    fn token_expired_block_suppresses_reset_bank_provider_io() {
        let now = Utc::now();
        let mut blocked = account("blocked@example.com", false, 100.0, 100.0);
        blocked.plan_type = Some("pro".to_string());
        mark_runtime_unusable(
            &mut blocked,
            "token_expired",
            now + ChronoDuration::days(30),
        );
        let calls = Arc::new(Mutex::new(0usize));
        let calls_for_closure = Arc::clone(&calls);

        refresh_stale_reset_bank_observations(
            std::slice::from_mut(&mut blocked),
            now,
            &move |_| {
                *calls_for_closure.lock().unwrap() += 1;
                Ok(reset_bank(1, now))
            },
        );

        assert_eq!(*calls.lock().unwrap(), 0);
        assert!(blocked.rate_limit_reset_bank.is_none());
    }

    #[test]
    fn daemon_rotation_passes_custom_auth_path_to_reload() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("custom/auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let candidate = account("candidate@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, candidate])?;
        confirm_daemon_activation(&store_path, &auth_path)?;
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_for_reload = Arc::clone(&observed);

        let swapped = run_once_with(&store_path, &auth_path, ready_fetch, move |observed_path| {
            observed_for_reload
                .lock()
                .unwrap()
                .push(observed_path.to_path_buf());
            Ok(verified_reload_summary())
        })?;

        assert!(swapped);
        assert_eq!(*observed.lock().unwrap(), vec![auth_path]);
        Ok(())
    }

    #[test]
    fn active_at_five_percent_enters_fast_polling() -> Result<()> {
        let active = account("active@example.com", true, 95.0, 10.0);
        assert_eq!(
            next_poll_interval_for(&active, Duration::from_secs(300)),
            Duration::from_secs(2)
        );
        Ok(())
    }

    #[test]
    fn active_at_two_percent_enters_critical_fast_polling() -> Result<()> {
        let active = account("active@example.com", true, 98.0, 10.0);
        assert_eq!(
            next_poll_interval_for(&active, Duration::from_secs(300)),
            Duration::from_secs(1)
        );
        Ok(())
    }

    #[test]
    fn daemon_rotation_publishes_stable_pool_authority_transition() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let accounts = vec![
            account("active@example.com", true, 99.0, 10.0),
            account("ready@example.com", false, 10.0, 10.0),
        ];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(tick.swapped);
        assert_eq!(tick.next_interval, Duration::from_secs(300));
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        let authority = crate::pool_authority::observe_status(&store_path)?
            .context("daemon rotation did not publish pool authority")?;
        assert_eq!(authority.epoch, 2);
        assert_eq!(authority.phase, PoolAuthorityPhase::Stable);
        assert_eq!(authority.desired_provider_account_id, "ready@example.com");
        assert_eq!(authority.reason, "daemon_quota_rotation");
        assert!(authority.observed_at >= authority.updated_at);
        Ok(())
    }

    #[test]
    fn active_displayed_as_one_percent_rotates_immediately() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let accounts = vec![
            account("active@example.com", true, 98.6, 10.0),
            account("ready@example.com", false, 10.0, 10.0),
        ];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| Ok(verified_reload_summary()),
        )?;

        assert!(tick.swapped);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        Ok(())
    }

    #[test]
    fn default_daemon_rotates_without_consuming_banked_reset() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 20.0, 100.0);
        let mut replacement = account("ready@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        let accounts = vec![active, replacement];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: false,
            },
            DaemonTickDependencies::new(
                ready_fetch,
                |_| Ok(()),
                |_account| Ok(reset_bank(1, Utc::now())),
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(tick.swapped);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        Ok(())
    }

    #[test]
    fn default_daemon_does_not_redeem_eligible_inactive_pro() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let now = Utc::now();
        let mut active_plus = account("plus@example.com", true, 20.0, 20.0);
        active_plus.plan_type = Some("plus".to_string());
        set_weekly_reset_after(&mut active_plus, now, ChronoDuration::days(3));
        let mut exhausted_pro = account("pro@example.com", false, 20.0, 100.0);
        set_weekly_reset_after(&mut exhausted_pro, now, ChronoDuration::hours(36));
        exhausted_pro.rate_limit_reset_bank = Some(reset_bank(1, now));
        save_accounts(&store_path, &[active_plus, exhausted_pro])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let bank_fetches = Arc::new(Mutex::new(Vec::new()));
        let bank_fetches_for_closure = Arc::clone(&bank_fetches);
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: false,
            },
            DaemonTickDependencies::new(
                ready_fetch,
                |_| Ok(()),
                move |account| {
                    bank_fetches_for_closure
                        .lock()
                        .unwrap()
                        .push(account.email.clone());
                    Ok(reset_bank(
                        u32::from(account.email == "pro@example.com"),
                        Utc::now(),
                    ))
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(!tick.swapped);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(
            bank_fetches.lock().unwrap().as_slice(),
            &["plus@example.com".to_string()]
        );
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("plus@example.com")
        );
        assert_eq!(
            stored
                .iter()
                .find(|account| account.email == "pro@example.com")
                .and_then(|account| account.rate_limit_reset_bank.as_ref())
                .map(|bank| bank.available_count),
            Some(1)
        );
        Ok(())
    }

    #[test]
    fn pool_reset_orchestration_uses_bank_and_keeps_active() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 20.0, 100.0);
        let mut replacement = account("ready@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        let accounts = vec![active, replacement];
        save_accounts(&store_path, &accounts)?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let active_fetches = Arc::new(Mutex::new(0usize));
        let active_fetches_for_closure = Arc::clone(&active_fetches);
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches_for_closure = Arc::clone(&bank_fetches);
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let quota_store_path = store_path.clone();
        let bank_store_path = store_path.clone();
        let consume_store_path = store_path.clone();
        let reload_store_path = store_path.clone();
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                move |account| {
                    assert_store_lock_available(&quota_store_path)?;
                    assert_runtime_activation_lease_busy(&quota_store_path)?;
                    let mut result = ready_fetch(account)?;
                    if account.email == "active@example.com" {
                        let mut calls = active_fetches_for_closure.lock().unwrap();
                        *calls += 1;
                        if *calls > 1 {
                            let five_hour = result.snapshot.five_hour_mut().unwrap();
                            five_hour.used_percent = 0.0;
                            five_hour.hard_limit_reached = false;
                            let weekly = result.snapshot.weekly_mut().unwrap();
                            weekly.used_percent = 0.0;
                            weekly.hard_limit_reached = false;
                            result.snapshot.allowed = Some(true);
                            result.snapshot.limit_reached = Some(false);
                        }
                    }
                    Ok(result)
                },
                |_| Ok(()),
                move |_account| {
                    assert_store_lock_available(&bank_store_path)?;
                    assert_runtime_activation_lease_busy(&bank_store_path)?;
                    let mut calls = bank_fetches_for_closure.lock().unwrap();
                    *calls += 1;
                    Ok(reset_bank(u32::from(*calls == 1), Utc::now()))
                },
                move |_account, _bank, _request_id| {
                    assert_store_lock_available(&consume_store_path)?;
                    assert_runtime_activation_lease_busy(&consume_store_path)?;
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                move |_| {
                    assert_runtime_activation_lease_busy(&reload_store_path)?;
                    Ok(verified_reload_summary())
                },
            ),
        )?;

        assert!(!tick.swapped);
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        assert_eq!(*bank_fetches.lock().unwrap(), 2);
        assert_eq!(*active_fetches.lock().unwrap(), 2);
        let stored = load_accounts(&store_path)?;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.email, "active@example.com");
        assert_eq!(
            quota_availability_at(active, Utc::now()),
            QuotaAvailability::Usable
        );
        assert_eq!(
            active
                .rate_limit_reset_bank
                .as_ref()
                .map(|bank| bank.available_count),
            Some(0)
        );
        let successor = acquire_runtime_activation_lease(&store_path)?;
        drop(successor);
        Ok(())
    }

    #[test]
    fn reset_ranking_prefetch_preserves_prior_bank_and_blocks_external_decrement() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let now = Utc::now();
        let mut exhausted_pro = account("pro@example.com", true, 20.0, 100.0);
        set_weekly_reset_after(&mut exhausted_pro, now, ChronoDuration::hours(36));
        exhausted_pro.rate_limit_reset_bank = Some(reset_bank(
            2,
            now - crate::rate_limit_resets::RESET_BANK_REFRESH_INTERVAL,
        ));
        let mut ready_plus = account("plus@example.com", false, 20.0, 20.0);
        ready_plus.plan_type = Some("plus".to_string());
        save_accounts(&store_path, &[exhausted_pro, ready_plus])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let bank_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches_for_closure = Arc::clone(&bank_fetches);
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                ready_fetch,
                |_| Ok(()),
                move |account| {
                    assert_eq!(account.email, "pro@example.com");
                    *bank_fetches_for_closure.lock().unwrap() += 1;
                    Ok(reset_bank(1, Utc::now()))
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    bail!("an external inventory decrement must suppress another POST")
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(tick.swapped);
        assert_eq!(*bank_fetches.lock().unwrap(), 1);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(active_account(&stored).unwrap().email, "plus@example.com");
        assert_eq!(
            stored
                .iter()
                .find(|account| account.email == "pro@example.com")
                .and_then(|account| account.rate_limit_reset_bank.as_ref())
                .map(|bank| bank.available_count),
            Some(1)
        );
        Ok(())
    }

    #[test]
    fn pool_reset_orchestration_redeems_inactive_pro_then_activates_it() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let now = Utc::now();
        let mut active_plus = account("plus@example.com", true, 20.0, 20.0);
        active_plus.plan_type = Some("plus".to_string());
        set_weekly_reset_after(&mut active_plus, now, ChronoDuration::days(3));
        let mut exhausted_pro = account("pro@example.com", false, 20.0, 100.0);
        set_weekly_reset_after(&mut exhausted_pro, now, ChronoDuration::hours(36));
        exhausted_pro.rate_limit_reset_bank = None;
        save_accounts(&store_path, &[active_plus, exhausted_pro])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let pro_quota_fetches = Arc::new(Mutex::new(0usize));
        let pro_quota_fetches_for_closure = Arc::clone(&pro_quota_fetches);
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches_for_closure = Arc::clone(&bank_fetches);
        let consumed_accounts = Arc::new(Mutex::new(Vec::new()));
        let consumed_accounts_for_closure = Arc::clone(&consumed_accounts);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                move |account| {
                    let mut result = ready_fetch(account)?;
                    if account.email == "pro@example.com" {
                        let mut calls = pro_quota_fetches_for_closure.lock().unwrap();
                        *calls += 1;
                        let five_hour = result.snapshot.five_hour_mut().unwrap();
                        five_hour.used_percent = 0.0;
                        five_hour.hard_limit_reached = false;
                        let weekly = result.snapshot.weekly_mut().unwrap();
                        weekly.used_percent = 0.0;
                        weekly.hard_limit_reached = false;
                        result.snapshot.allowed = Some(true);
                        result.snapshot.limit_reached = Some(false);
                        result.snapshot.fetched_at = Utc::now();
                    }
                    Ok(result)
                },
                |_| Ok(()),
                move |account| {
                    assert_eq!(account.email, "pro@example.com");
                    let mut calls = bank_fetches_for_closure.lock().unwrap();
                    *calls += 1;
                    Ok(reset_bank(u32::from(*calls == 1), Utc::now()))
                },
                move |account, _bank, _request_id| {
                    consumed_accounts_for_closure
                        .lock()
                        .unwrap()
                        .push(account.email.clone());
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(tick.swapped);
        assert_eq!(*pro_quota_fetches.lock().unwrap(), 1);
        assert_eq!(*bank_fetches.lock().unwrap(), 2);
        assert_eq!(
            consumed_accounts.lock().unwrap().as_slice(),
            &["pro@example.com".to_string()]
        );
        let stored = load_accounts(&store_path)?;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.email, "pro@example.com");
        assert_eq!(
            quota_availability_at(active, Utc::now()),
            QuotaAvailability::Usable
        );
        assert_eq!(
            active
                .rate_limit_reset_bank
                .as_ref()
                .map(|bank| bank.available_count),
            Some(0)
        );
        let authority = crate::pool_authority::observe_status(&store_path)?
            .context("banked-reset rotation did not publish pool authority")?;
        assert_eq!(authority.epoch, 2);
        assert_eq!(authority.phase, PoolAuthorityPhase::Stable);
        assert_eq!(authority.desired_provider_account_id, "pro@example.com");
        assert_eq!(authority.reason, "daemon_banked_reset");
        Ok(())
    }

    #[test]
    fn pool_reset_orchestration_preserves_pro_reset_near_natural_recovery() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let now = Utc::now();
        let mut active_plus = account("plus@example.com", true, 20.0, 20.0);
        active_plus.plan_type = Some("plus".to_string());
        set_weekly_reset_after(&mut active_plus, now, ChronoDuration::days(3));
        let mut exhausted_pro = account("pro@example.com", false, 20.0, 100.0);
        set_weekly_reset_after(&mut exhausted_pro, now, ChronoDuration::hours(12));
        exhausted_pro.rate_limit_reset_bank = Some(reset_bank(1, now));
        save_accounts(&store_path, &[active_plus, exhausted_pro])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                ready_fetch,
                |_| Ok(()),
                |account| {
                    assert_eq!(account.email, "plus@example.com");
                    Ok(reset_bank(0, Utc::now()))
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(!tick.swapped);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("plus@example.com")
        );
        assert_eq!(
            stored
                .iter()
                .find(|account| account.email == "pro@example.com")
                .and_then(|account| account.rate_limit_reset_bank.as_ref())
                .map(|bank| bank.available_count),
            Some(1)
        );
        Ok(())
    }

    #[test]
    fn pool_reset_orchestration_uses_usable_pro_without_spending_reset() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let now = Utc::now();
        let mut active_plus = account("plus@example.com", true, 20.0, 20.0);
        active_plus.plan_type = Some("plus".to_string());
        set_weekly_reset_after(&mut active_plus, now, ChronoDuration::days(3));
        let mut exhausted_pro = account("exhausted-pro@example.com", false, 20.0, 100.0);
        set_weekly_reset_after(&mut exhausted_pro, now, ChronoDuration::days(3));
        exhausted_pro.rate_limit_reset_bank = Some(reset_bank(1, now));
        let mut usable_pro = account("usable-pro@example.com", false, 20.0, 20.0);
        set_weekly_reset_after(&mut usable_pro, now, ChronoDuration::days(3));
        save_accounts(&store_path, &[active_plus, exhausted_pro, usable_pro])?;
        confirm_daemon_activation(&store_path, &auth_path)?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let tick = run_once_report_with_resets(
            DaemonTickContext {
                store_path: &store_path,
                auth_path: &auth_path,
                base_interval: Duration::from_secs(300),
                consume_banked_resets: true,
            },
            DaemonTickDependencies::new(
                ready_fetch,
                |_| Ok(()),
                |account| {
                    assert_eq!(account.email, "plus@example.com");
                    Ok(reset_bank(0, Utc::now()))
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: crate::rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(tick.swapped);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("usable-pro@example.com")
        );
        assert_eq!(
            stored
                .iter()
                .find(|account| account.email == "exhausted-pro@example.com")
                .and_then(|account| account.rate_limit_reset_bank.as_ref())
                .map(|bank| bank.available_count),
            Some(1)
        );
        Ok(())
    }

    #[test]
    fn duplicate_provider_identity_is_rejected_before_reload() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 99.0, 10.0);
        active.account_id = "same-account".to_string();
        let mut duplicate = account("duplicate@example.com", false, 10.0, 10.0);
        duplicate.account_id = "same-account".to_string();
        let error = save_accounts(&store_path, &[active, duplicate]).unwrap_err();

        assert!(format!("{error:#}").contains("duplicate provider account identity"));
        assert!(!store_path.exists());
        assert!(!auth_path.exists());
        Ok(())
    }
}

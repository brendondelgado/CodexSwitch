use crate::account_store::{
    active_account, commit_accounts, lock_account_store, mark_runtime_unusable,
    quota_availability_at, real_quota_snapshot, select_auto_swap_candidate_from_observations,
    select_plan_upgrade_candidate, select_plan_upgrade_candidate_from_observations,
    usage_limit_runtime_block_until, CodexAccount, CurrentQuotaObservations, QuotaAvailability,
};
#[cfg(test)]
use crate::account_store::{load_accounts, save_accounts};
use crate::activation::{
    activate_with, read_activation_record, reconcile_activation_barrier, ActivationBarrierContext,
    ActivationContext, ActivationOutcome, ActivationState,
};
use crate::auth::auth_file_matches_account;
#[cfg(test)]
use crate::auth::write_auth_file;
use crate::codex_update;
use crate::quota::{apply_fetch_result, fetch_quota, FetchResult};
use crate::rate_limit_resets::{
    fetch_rate_limit_reset_bank, orchestrate_pool_reset_with_selection,
    select_smart_reset_candidate, ConsumeResult, RateLimitResetBank, ResetOrchestrationContext,
    ResetOrchestrationDependencies, ResetQuotaRefreshStrategy,
};
use crate::reload::{
    discover_hot_swap_processes_missing_current_ack, reload_codex_cli_hot_swap_processes,
    reload_codex_hot_swap_processes, ReloadSummary,
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
const UNIX_TO_SWIFT_REFERENCE_SECONDS: f64 = 978_307_200.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DaemonTick {
    swapped: bool,
    next_interval: Duration,
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
    let store_lock = lock_account_store(store_path)?;
    let snapshot = store_lock.load()?;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    if let Some(outcome) = reconcile_activation_barrier(
        ActivationBarrierContext {
            store_lock: &store_lock,
            generation: &mut generation,
            accounts: &mut accounts,
            auth_path,
            reload_enabled: true,
        },
        &reload_fn,
    )? {
        require_confirmed_activation(outcome)?;
        let refreshed = store_lock.load()?;
        generation = refreshed.generation;
        accounts = refreshed.accounts;
    }
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

    refresh_inactive_watch_accounts(&mut accounts, &fetch_quota_fn, &refresh_token_fn);

    let now = Utc::now();
    let active_availability = quota_availability_at(&accounts[active_index], now);
    let active_is_blocked = active_availability == QuotaAvailability::Blocked;
    let cached_plan_upgrade_exists = !force_swap
        && active_availability == QuotaAvailability::Usable
        && select_plan_upgrade_candidate(&accounts, now).is_some();
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
        match orchestrate_pool_reset_with_selection(
            ResetOrchestrationContext {
                store_lock: &store_lock,
                accounts: &mut accounts,
                active_index,
                candidate_observations: candidate_observations.as_ref(),
                allow_reset: consume_banked_resets,
                direct_runtime_usage_limit,
                refresh_strategy: ResetQuotaRefreshStrategy::RefreshExpiredToken,
                now: Utc::now(),
            },
            ResetOrchestrationDependencies::new(
                |account: &CodexAccount| fetch_reset_bank_fn(account),
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
                    activate_with(
                        ActivationContext {
                            store_lock: &store_lock,
                            generation: &mut generation,
                            accounts,
                            auth_path,
                            target_id,
                            reload_enabled: true,
                        },
                        &reload_fn,
                    )
                },
            ),
            &reset_selection_accounts,
        ) {
            Ok(outcome) => match outcome.completion {
                Some(activation) => {
                    let reset_account_index = outcome.account_index;
                    let swapped = reset_account_index != active_index;
                    require_confirmed_activation(activation)?;
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
                    return Ok(DaemonTick {
                        swapped,
                        next_interval,
                    });
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
            Err(error) => eprintln!(
                "warning: reset reconciliation failed for {}; continuing with normal rotation: {error:#}",
                accounts[active_index].email
            ),
        }
    }

    let Some(target) = rotation_target else {
        if force_swap || active_is_blocked {
            commit_accounts(&store_lock, &mut generation, &accounts)?;
            bail!("active account is blocked but no freshly confirmed usable candidate exists");
        }
        if active_poll_succeeded {
            let durable_state = read_activation_record(&store_lock)?.map(|record| record.state);
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
                let activation = activate_with(
                    ActivationContext {
                        store_lock: &store_lock,
                        generation: &mut generation,
                        accounts: &mut accounts,
                        auth_path,
                        target_id,
                        reload_enabled: true,
                    },
                    &reload_fn,
                )?;
                require_confirmed_activation(activation)?;
            } else {
                commit_accounts(&store_lock, &mut generation, &accounts)?;
            }
        } else {
            commit_accounts(&store_lock, &mut generation, &accounts)?;
        }
        let next_interval = next_poll_interval_for(&accounts[active_index], base_interval);
        return Ok(DaemonTick {
            swapped: false,
            next_interval,
        });
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
        commit_accounts(&store_lock, &mut generation, &accounts)?;
        bail!(
            "selected candidate {} is already active; refusing same-account reload storm",
            target.email
        );
    }
    if quota_availability_at(&target, Utc::now()) != QuotaAvailability::Usable {
        commit_accounts(&store_lock, &mut generation, &accounts)?;
        bail!("selected candidate was not freshly confirmed usable");
    }

    let activation = activate_with(
        ActivationContext {
            store_lock: &store_lock,
            generation: &mut generation,
            accounts: &mut accounts,
            auth_path,
            target_id: target.id,
            reload_enabled: true,
        },
        &reload_fn,
    )?;
    let summary = require_confirmed_activation(activation)?;
    println!(
        "swapped to {} and signaled {} Codex hot-swap process(es), restarted {}",
        target.email,
        summary.signaled.len(),
        summary.restarted.len()
    );
    Ok(DaemonTick {
        swapped: true,
        next_interval: base_interval,
    })
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
    match fetch_quota_fn(account) {
        Ok(result) => Ok(result),
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
            fetch_quota_fn(account)
        }
        Err(error) => Err(error),
    }
}

fn refresh_inactive_watch_accounts<F, T>(
    accounts: &mut [CodexAccount],
    fetch_quota_fn: &F,
    refresh_token_fn: &T,
) where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    T: Fn(&mut CodexAccount) -> Result<()>,
{
    let now = Utc::now();
    for account in accounts {
        if !should_probe_inactive_account(account, now) {
            continue;
        }

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
                } else if real_quota_snapshot(account).is_none() {
                    account.last_refreshed = Some(crate::quota::now_swift_reference_value());
                }
            }
        }
    }
}

fn refresh_stale_reset_bank_observations<B>(
    accounts: &mut [CodexAccount],
    now: chrono::DateTime<Utc>,
    fetch_reset_bank: &B,
) where
    B: Fn(&CodexAccount) -> Result<RateLimitResetBank>,
{
    for account in accounts {
        let resettable = account.plan_priority() >= 2
            && (quota_availability_at(account, now) == QuotaAvailability::Blocked
                || account.runtime_block_is_usage_limit());
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
    if account.runtime_unusable() && !account.runtime_block_is_usage_limit() {
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
    let mut last_ack_bootstrap: Option<Instant> = None;
    let mut was_fast_polling = false;
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
        let sleep_interval = complete_daemon_iteration(
            tick_result,
            interval,
            &mut was_fast_polling,
            &mut last_ack_bootstrap,
            auth_path,
            |path| Ok(!discover_hot_swap_processes_missing_current_ack(false, path)?.is_empty()),
            reload_codex_cli_hot_swap_processes,
        );
        std::thread::sleep(sleep_interval);
    }
}

fn complete_daemon_iteration<D, R>(
    tick_result: Result<DaemonTick>,
    base_interval: Duration,
    was_fast_polling: &mut bool,
    last_ack_bootstrap: &mut Option<Instant>,
    auth_path: &Path,
    discover_missing: D,
    reload: R,
) -> Duration
where
    D: Fn(&Path) -> Result<bool>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    let tick_succeeded = tick_result.is_ok();
    let sleep_interval = match tick_result {
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
    };

    // Background repairs target interactive CLI sessions only. An app-server
    // without a live ACK is reported as not ready by doctor; repeatedly
    // signaling it can terminate the supervised WebSocket service. A failed
    // tick is also a hard barrier for this auxiliary reload path.
    match run_ack_bootstrap_if_due(
        tick_succeeded,
        last_ack_bootstrap,
        auth_path,
        discover_missing,
        reload,
    ) {
        Ok(Some(summary)) => eprintln!(
            "verified hot-swap reload for {} process(es); restarted {}; {} skipped",
            summary.signaled.len(),
            summary.restarted.len(),
            summary.skipped.len()
        ),
        Ok(None) => {}
        Err(error) => eprintln!("{error:#}"),
    }
    sleep_interval
}

fn ack_bootstrap_is_due(tick_succeeded: bool, last_ack_bootstrap: Option<Instant>) -> bool {
    tick_succeeded
        && last_ack_bootstrap
            .map(|instant| instant.elapsed() >= Duration::from_secs(60))
            .unwrap_or(true)
}

fn run_ack_bootstrap_if_due<D, R>(
    tick_succeeded: bool,
    last_ack_bootstrap: &mut Option<Instant>,
    auth_path: &Path,
    discover_missing: D,
    reload: R,
) -> Result<Option<ReloadSummary>>
where
    D: Fn(&Path) -> Result<bool>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    if !ack_bootstrap_is_due(tick_succeeded, *last_ack_bootstrap) {
        return Ok(None);
    }
    *last_ack_bootstrap = Some(Instant::now());
    if !discover_missing(auth_path).context("hot-swap bootstrap readiness check failed")? {
        return Ok(None);
    }
    reload(auth_path)
        .map(Some)
        .context("hot-swap bootstrap reload failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{
        CodexAccount, QuotaSnapshot, QuotaWindow, QuotaWindowKind, QuotaWindowRateLimitSource,
        QuotaWindowSlot, QuotaWindowSourceMetadata,
    };
    use anyhow::bail;
    use serde_json::json;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;
    use uuid::Uuid;

    fn account(email: &str, active: bool, five_used: f64, weekly_used: f64) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: email.to_string(),
            access_token: format!("access-{email}"),
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
        ReloadSummary {
            signaled: vec![42],
            ..ReloadSummary::default()
        }
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
    fn weekly_only_healthy_active_account_remains_usable() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 30.0);
        let mut standby = account("standby@example.com", false, 10.0, 20.0);
        retain_weekly_only(&mut active);
        retain_weekly_only(&mut standby);
        save_accounts(&store_path, &[active, standby])?;

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
                account.access_token = "fresh-access".to_string();
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
        assert_eq!(active.access_token, "fresh-access");
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
            Some("fresh-access")
        );
        Ok(())
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
    fn healthy_active_rewrites_auth_to_match_store() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;

        let rotated = run_once_with(&store_path, &auth_path, ready_fetch, |_| {
            Ok(verified_reload_summary())
        })?;

        assert!(!rotated);
        let auth: serde_json::Value = serde_json::from_slice(&std::fs::read(auth_path)?)?;
        assert_eq!(
            auth.pointer("/tokens/account_id")
                .and_then(|value| value.as_str()),
            Some(active.account_id.as_str())
        );
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
    fn healthy_active_reload_is_signaled_when_auth_changes_without_rotation() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 10.0, 10.0);
        active.access_token = "fresh-token".to_string();
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        std::fs::write(
            &auth_path,
            b"{\"tokens\":{\"access_token\":\"stale-token\"}}",
        )?;

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
                Ok(ReloadSummary {
                    signaled: vec![42],
                    restarted: Vec::new(),
                    skipped: Vec::new(),
                })
            },
        )?;

        assert!(!tick.swapped);
        assert_eq!(*reloads.lock().unwrap(), 1);
        let auth: serde_json::Value = serde_json::from_slice(&std::fs::read(auth_path)?)?;
        assert_eq!(
            auth.pointer("/tokens/access_token")
                .and_then(|value| value.as_str()),
            Some("fresh-token")
        );
        Ok(())
    }

    #[test]
    fn healthy_active_reload_is_not_signaled_when_auth_is_unchanged() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        write_auth_file(&auth_path, &active)?;

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

        let first_error = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| {
                Ok(ReloadSummary {
                    skipped: vec![(42, "ack timeout".to_string())],
                    ..ReloadSummary::default()
                })
            },
        )
        .unwrap_err();
        assert!(format!("{first_error:#}").contains("did not publish as swapped"));
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            crate::activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            crate::activation::ActivationState::CommittedDegraded
        );
        drop(store_lock);

        let second_error = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| Ok(ReloadSummary::default()),
        )
        .unwrap_err();
        assert!(format!("{second_error:#}").contains("did not publish as swapped"));
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            crate::activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            crate::activation::ActivationState::CommittedDegraded
        );
        drop(store_lock);

        let converged = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            |_| {
                Ok(ReloadSummary {
                    signaled: vec![42],
                    ..ReloadSummary::default()
                })
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
    fn daemon_wrapper_skips_ack_bootstrap_after_manual_review_barrier() -> Result<()> {
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
        std::fs::write(
            crate::activation::activation_record_path(&store_path),
            serde_json::to_vec_pretty(&record)?,
        )?;
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

        let discovery_calls = Arc::new(Mutex::new(0usize));
        let bootstrap_reload_calls = Arc::new(Mutex::new(0usize));
        let mut last_ack_bootstrap = None;
        let mut was_fast_polling = true;
        let sleep_interval = complete_daemon_iteration(
            tick_result,
            Duration::from_secs(300),
            &mut was_fast_polling,
            &mut last_ack_bootstrap,
            &auth_path,
            {
                let calls = Arc::clone(&discovery_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(true)
                }
            },
            {
                let calls = Arc::clone(&bootstrap_reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        );
        assert_eq!(sleep_interval, Duration::from_secs(300));
        assert!(!was_fast_polling);
        assert_eq!(*discovery_calls.lock().unwrap(), 0);
        assert_eq!(*bootstrap_reload_calls.lock().unwrap(), 0);
        assert!(last_ack_bootstrap.is_none());
        Ok(())
    }

    #[test]
    fn ack_bootstrap_no_work_advances_probe_cadence() -> Result<()> {
        let auth_path = Path::new("/tmp/test-auth.json");
        let discovery_calls = Arc::new(Mutex::new(0usize));
        let reload_calls = Arc::new(Mutex::new(0usize));
        let mut last_ack_bootstrap = None;

        let first = run_ack_bootstrap_if_due(
            true,
            &mut last_ack_bootstrap,
            auth_path,
            {
                let calls = Arc::clone(&discovery_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(false)
                }
            },
            {
                let calls = Arc::clone(&reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        )?;
        assert!(first.is_none());
        assert!(last_ack_bootstrap.is_some());

        let second = run_ack_bootstrap_if_due(
            true,
            &mut last_ack_bootstrap,
            auth_path,
            {
                let calls = Arc::clone(&discovery_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(true)
                }
            },
            {
                let calls = Arc::clone(&reload_calls);
                move |_| {
                    *calls.lock().unwrap() += 1;
                    Ok(verified_reload_summary())
                }
            },
        )?;
        assert!(second.is_none());
        assert_eq!(*discovery_calls.lock().unwrap(), 1);
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
            now - crate::account_store::QUOTA_OBSERVATION_MAX_AGE;
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
    fn daemon_rotation_passes_custom_auth_path_to_reload() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("custom/auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let candidate = account("candidate@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, candidate])?;
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
    fn active_at_one_percent_rotates_immediately() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let accounts = vec![
            account("active@example.com", true, 99.0, 10.0),
            account("ready@example.com", false, 10.0, 10.0),
        ];
        save_accounts(&store_path, &accounts)?;

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

        let active_fetches = Arc::new(Mutex::new(0usize));
        let active_fetches_for_closure = Arc::clone(&active_fetches);
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
                move |account| {
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
                    let mut calls = bank_fetches_for_closure.lock().unwrap();
                    *calls += 1;
                    Ok(reset_bank(u32::from(*calls == 1), Utc::now()))
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

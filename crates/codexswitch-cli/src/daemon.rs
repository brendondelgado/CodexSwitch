use crate::account_store::{
    active_account, is_immediately_usable, load_accounts, lock_account_store,
    mark_runtime_unusable, real_quota_snapshot, save_accounts, select_auto_swap_candidate,
    select_plan_upgrade_candidate, set_active, CodexAccount,
};
use crate::auth::write_auth_file;
use crate::codex_update;
use crate::hermes;
use crate::quota::{apply_fetch_result, fetch_quota, FetchResult};
use crate::reload::{
    discover_hot_swap_processes_missing_current_ack, reload_codex_cli_hot_swap_processes,
    reload_codex_hot_swap_processes, ReloadSummary,
};
use crate::token_refresh::refresh_account_tokens;
use anyhow::{bail, Context, Result};
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

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

#[cfg(test)]
fn run_once_with<F, R>(
    store_path: &Path,
    auth_path: &Path,
    fetch_quota_fn: F,
    reload_fn: R,
) -> Result<bool>
where
    F: Fn(&CodexAccount) -> Result<FetchResult>,
    R: Fn() -> Result<ReloadSummary>,
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
    R: Fn() -> Result<ReloadSummary>,
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
    R: Fn() -> Result<ReloadSummary>,
{
    let _store_lock = lock_account_store(store_path)?;
    let mut accounts = load_accounts(store_path)?;
    let active_id = active_account(&accounts)
        .map(|account| account.account_id.clone())
        .context("no active account in store")?;

    let active_index = accounts
        .iter()
        .position(|account| account.account_id == active_id)
        .context("active account disappeared")?;
    let mut force_swap = false;
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
                let until = Utc::now() + cooldown;
                mark_runtime_unusable(&mut accounts[active_index], reason, until);
                force_swap = true;
            }
        }
    }

    refresh_inactive_watch_accounts(&mut accounts, &fetch_quota_fn, &refresh_token_fn);

    let active_needs_quota_swap = accounts[active_index]
        .quota_snapshot
        .as_ref()
        .map(|snapshot| {
            snapshot.five_hour.should_auto_swap_away() || snapshot.weekly.should_auto_swap_away()
        })
        .unwrap_or(false);
    let plan_upgrade_target = if !force_swap && !active_needs_quota_swap {
        select_plan_upgrade_candidate(&accounts).cloned()
    } else {
        None
    };
    let should_swap = force_swap || active_needs_quota_swap || plan_upgrade_target.is_some();

    if !should_swap {
        if active_poll_succeeded {
            let previous_auth = auth_reload_fingerprint_from_file(auth_path);
            write_auth_file(auth_path, &accounts[active_index])?;
            if let Err(error) = hermes::apply_account_if_configured(&accounts[active_index]) {
                eprintln!("warning: Hermes sync failed for active account: {error:#}");
            }
            let current_auth = auth_reload_fingerprint_from_file(auth_path);
            if previous_auth != current_auth {
                let summary = reload_fn()?;
                if !summary.signaled.is_empty()
                    || !summary.restarted.is_empty()
                    || !summary.skipped.is_empty()
                {
                    eprintln!(
                        "active auth changed without account rotation; signaled {} Codex hot-swap process(es), restarted {}, {} skipped",
                        summary.signaled.len(),
                        summary.restarted.len(),
                        summary.skipped.len()
                    );
                }
            }
        }
        let next_interval = next_poll_interval_for(&accounts[active_index], base_interval);
        save_accounts(store_path, &accounts)?;
        return Ok(DaemonTick {
            swapped: false,
            next_interval,
        });
    }

    let target = if let Some(target) = plan_upgrade_target {
        eprintln!(
            "higher plan available; rotating from {} ({}) to {} ({})",
            accounts[active_index].email,
            accounts[active_index].normalized_plan_type(),
            target.email,
            target.normalized_plan_type()
        );
        target
    } else {
        for account in accounts.iter_mut().filter(|account| !account.is_active) {
            match fetch_quota_with_refresh(account, &fetch_quota_fn, &refresh_token_fn) {
                Ok(result) => {
                    apply_fetch_result(account, result);
                }
                Err(error) => {
                    if let Some((reason, cooldown)) = poll_error_runtime_block(&error) {
                        let until = Utc::now() + cooldown;
                        mark_runtime_unusable(account, reason, until);
                    }
                }
            }
        }

        let Some(target) = select_auto_swap_candidate(&accounts).cloned() else {
            save_accounts(store_path, &accounts)?;
            bail!("active account is exhausted but no ready candidate exists");
        };
        target
    };
    if !is_immediately_usable(&target) {
        save_accounts(store_path, &accounts)?;
        bail!("selected candidate was not immediately usable");
    }

    set_active(&mut accounts, &target.account_id);
    write_auth_file(auth_path, &target)?;
    if let Err(error) = hermes::apply_account_if_configured(&target) {
        eprintln!("warning: Hermes sync failed after daemon swap: {error:#}");
    }
    save_accounts(store_path, &accounts)?;
    let summary = reload_fn()?;
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
    for index in 0..accounts.len() {
        if !should_probe_inactive_account(&accounts[index], now) {
            continue;
        }

        match fetch_quota_with_refresh(&mut accounts[index], fetch_quota_fn, refresh_token_fn) {
            Ok(result) => apply_fetch_result(&mut accounts[index], result),
            Err(error) => {
                eprintln!(
                    "warning: failed to probe inactive account {}: {error:#}",
                    accounts[index].email
                );
                if let Some((reason, cooldown)) = poll_error_runtime_block(&error) {
                    let until = Utc::now() + cooldown;
                    mark_runtime_unusable(&mut accounts[index], reason, until);
                } else if real_quota_snapshot(&accounts[index]).is_none() {
                    accounts[index].last_refreshed =
                        Some(crate::quota::now_swift_reference_value());
                }
            }
        }
    }
}

fn should_probe_inactive_account(account: &CodexAccount, now: chrono::DateTime<Utc>) -> bool {
    if account.runtime_unusable() {
        return false;
    }
    if account.is_active {
        return false;
    }
    if real_quota_snapshot(account).is_none() {
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
    let exhausted = account
        .quota_snapshot
        .as_ref()
        .map(|snapshot| snapshot.five_hour.is_exhausted() || snapshot.weekly.is_exhausted())
        .unwrap_or(true);
    if exhausted {
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
                .and_then(|snapshot| snapshot.fetched_at.as_ref())
                .and_then(swift_reference_value_to_unix_seconds)
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
    let lowest_remaining = snapshot
        .five_hour
        .remaining_percent()
        .min(snapshot.weekly.remaining_percent());
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

fn auth_reload_fingerprint_from_file(path: &Path) -> Option<String> {
    let data = fs::read(path).ok()?;
    let value = serde_json::from_slice::<Value>(&data).ok()?;
    let tokens = value.get("tokens");
    let fingerprint = serde_json::json!({
        "auth_mode": value.get("auth_mode"),
        "openai_api_key": value.get("OPENAI_API_KEY"),
        "account_id": tokens.and_then(|tokens| tokens.get("account_id")),
        "access_token": tokens.and_then(|tokens| tokens.get("access_token")),
        "refresh_token": tokens.and_then(|tokens| tokens.get("refresh_token")),
        "id_token": tokens.and_then(|tokens| tokens.get("id_token")),
    });
    serde_json::to_string(&fingerprint).ok()
}

pub fn run_loop(store_path: &Path, auth_path: &Path, interval: Duration) -> Result<()> {
    let mut last_ack_bootstrap: Option<Instant> = None;
    let mut was_fast_polling = false;
    loop {
        let mut sleep_interval = interval;
        if let Err(error) = codex_update::maybe_spawn_daily_auto_install() {
            eprintln!("codex update check failed: {error:#}");
        }
        match run_once_report_with(
            store_path,
            auth_path,
            interval,
            fetch_quota,
            refresh_account_tokens,
            reload_codex_hot_swap_processes,
        ) {
            Ok(tick) => {
                sleep_interval = tick.next_interval;
                let is_fast_polling = sleep_interval < interval;
                if is_fast_polling && !was_fast_polling {
                    eprintln!(
                        "active account low on quota; polling every {}s until the displayed-1% swap threshold",
                        sleep_interval.as_secs()
                    );
                } else if !is_fast_polling && was_fast_polling {
                    eprintln!("active account left low-quota fast polling");
                }
                was_fast_polling = is_fast_polling;
            }
            Err(error) => {
                eprintln!("daemon poll failed: {error:#}");
                was_fast_polling = false;
            }
        }
        if last_ack_bootstrap
            .map(|instant| instant.elapsed() >= Duration::from_secs(60))
            .unwrap_or(true)
        {
            // Background repairs target interactive CLI sessions only. An
            // app-server without a live ACK is reported as not ready by doctor;
            // repeatedly signaling it can terminate the supervised WebSocket
            // service and disconnect remote clients.
            match discover_hot_swap_processes_missing_current_ack(false, auth_path) {
                Ok(missing) if !missing.is_empty() => {
                    last_ack_bootstrap = Some(Instant::now());
                    match reload_codex_cli_hot_swap_processes() {
                        Ok(summary) => eprintln!(
                            "verified hot-swap reload for {} process(es); restarted {}; {} skipped",
                            summary.signaled.len(),
                            summary.restarted.len(),
                            summary.skipped.len()
                        ),
                        Err(error) => eprintln!("hot-swap bootstrap reload failed: {error:#}"),
                    }
                }
                Ok(_) => {}
                Err(error) => eprintln!("hot-swap bootstrap readiness check failed: {error:#}"),
            }
        }
        std::thread::sleep(sleep_interval);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{CodexAccount, QuotaSnapshot, QuotaWindow};
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
                five_hour: QuotaWindow {
                    used_percent: five_used,
                    window_duration_mins: 300,
                    resets_at: json!(0),
                    hard_limit_reached: false,
                },
                weekly: QuotaWindow {
                    used_percent: weekly_used,
                    window_duration_mins: 10_080,
                    resets_at: json!(0),
                    hard_limit_reached: false,
                },
                fetched_at: None,
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
            is_active: active,
        }
    }

    fn ready_fetch(account: &CodexAccount) -> Result<FetchResult> {
        Ok(FetchResult {
            snapshot: account.quota_snapshot.clone().unwrap(),
            plan_type: account.plan_type.clone().unwrap(),
        })
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
            || Ok(ReloadSummary::default()),
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
            || Ok(ReloadSummary::default()),
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
        save_accounts(&store_path, &[active.clone()])?;

        let rotated = run_once_with(&store_path, &auth_path, ready_fetch, || {
            Ok(ReloadSummary::default())
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
            move || {
                *reloads_for_closure.lock().unwrap() += 1;
                Ok(ReloadSummary::default())
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
        save_accounts(&store_path, &[active.clone()])?;
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
            move || {
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
        save_accounts(&store_path, &[active.clone()])?;
        write_auth_file(&auth_path, &active)?;

        let reloads = Arc::new(Mutex::new(0usize));
        let reloads_for_closure = Arc::clone(&reloads);
        let tick = run_once_report_with(
            &store_path,
            &auth_path,
            Duration::from_secs(300),
            ready_fetch,
            |_| Ok(()),
            move || {
                *reloads_for_closure.lock().unwrap() += 1;
                Ok(ReloadSummary::default())
            },
        )?;

        assert!(!tick.swapped);
        assert_eq!(*reloads.lock().unwrap(), 0);
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
            || Ok(ReloadSummary::default()),
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
        save_accounts(&store_path, &[active, upgraded])?;

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
                    snapshot.five_hour.used_percent = 0.0;
                    snapshot.weekly.used_percent = 0.0;
                    return Ok(FetchResult {
                        snapshot,
                        plan_type: "pro".to_string(),
                    });
                }
                ready_fetch(account)
            },
            |_| Ok(()),
            || Ok(ReloadSummary::default()),
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
                .map(|snapshot| snapshot.five_hour.remaining_percent()),
            Some(100.0)
        );
        Ok(())
    }

    #[test]
    fn inactive_pro_account_with_quota_is_not_probed_for_upgrade() -> Result<()> {
        let now = Utc::now();
        let mut pro = account("pro@example.com", false, 100.0, 94.0);
        pro.plan_type = Some("pro".to_string());
        pro.last_refreshed = None;
        assert!(!should_probe_inactive_account(&pro, now));
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
            || Ok(ReloadSummary::default()),
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
            || Ok(ReloadSummary::default()),
        )?;

        assert!(tick.swapped);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        Ok(())
    }
}

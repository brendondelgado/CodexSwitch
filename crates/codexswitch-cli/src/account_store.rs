use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const AUTO_SWAP_DISPLAYED_ONE_PERCENT_THRESHOLD: f64 = 2.0;
const RESET_TIE_FIVE_HOUR_TOLERANCE: f64 = 2.0;
const RESET_TIE_WEEKLY_TOLERANCE: f64 = 5.0;
const UNIX_TO_SWIFT_REFERENCE_SECONDS: i64 = 978_307_200;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAccount {
    pub id: Uuid,
    pub email: String,
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    pub account_id: String,
    pub quota_snapshot: Option<QuotaSnapshot>,
    pub plan_type: Option<String>,
    pub last_refreshed: Option<Value>,
    pub subscription_renews_at: Option<Value>,
    pub subscription_expires_at: Option<Value>,
    pub subscription_will_renew: Option<bool>,
    pub has_active_subscription: Option<bool>,
    pub five_hour_primed_at: Option<Value>,
    #[serde(default)]
    pub runtime_unusable_until: Option<DateTime<Utc>>,
    #[serde(default)]
    pub runtime_unusable_reason: Option<String>,
    pub is_active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub five_hour: QuotaWindow,
    pub weekly: QuotaWindow,
    pub fetched_at: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub used_percent: f64,
    pub window_duration_mins: i64,
    pub resets_at: Value,
    #[serde(default)]
    pub hard_limit_reached: bool,
}

impl QuotaWindow {
    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).max(0.0)
    }

    pub fn is_exhausted(&self) -> bool {
        self.hard_limit_reached || self.remaining_percent() < 1.0
    }

    pub fn should_auto_swap_away(&self) -> bool {
        self.hard_limit_reached
            || self.remaining_percent() < AUTO_SWAP_DISPLAYED_ONE_PERCENT_THRESHOLD
    }

    fn looks_like_backend_usage_placeholder(&self, fetched_at: Option<f64>) -> bool {
        let Some(fetched_at) = fetched_at else {
            return false;
        };
        !self.hard_limit_reached
            && self.used_percent <= 0.0001
            && (reset_timestamp(self) - fetched_at).abs() <= 10.0
    }
}

impl QuotaSnapshot {
    pub fn has_backend_usage_placeholder(&self) -> bool {
        self.five_hour
            .looks_like_backend_usage_placeholder(value_as_swift_reference_seconds(
                self.fetched_at.as_ref(),
            ))
    }
}

fn value_as_swift_reference_seconds(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    if let Some(number) = value.as_f64() {
        return Some(number);
    }
    if let Some(string) = value.as_str() {
        if let Ok(number) = string.parse::<f64>() {
            return Some(number);
        }
        if let Ok(datetime) = DateTime::parse_from_rfc3339(string) {
            let unix = datetime.timestamp_millis() as f64 / 1000.0;
            return Some(unix - UNIX_TO_SWIFT_REFERENCE_SECONDS as f64);
        }
    }
    None
}

impl CodexAccount {
    pub fn normalized_plan_type(&self) -> String {
        let normalized = self
            .plan_type
            .as_deref()
            .unwrap_or("unknown")
            .trim()
            .to_ascii_lowercase()
            .replace(['-', ' '], "_");
        if normalized.is_empty() {
            "unknown".to_string()
        } else {
            normalized
        }
    }

    pub fn plan_priority(&self) -> i32 {
        let normalized = self.normalized_plan_type();
        if plan_matches(&normalized, "pro_lite") || normalized == "prolite" {
            return 3;
        }
        if plan_matches(&normalized, "pro") {
            return 4;
        }
        if ["plus", "team", "business", "enterprise", "edu"]
            .iter()
            .any(|plan| plan_matches(&normalized, plan))
        {
            return 2;
        }
        if ["free", "free_workspace", "guest"]
            .iter()
            .any(|plan| plan_matches(&normalized, plan))
        {
            return 1;
        }
        if self.has_active_subscription == Some(true) {
            2
        } else {
            1
        }
    }

    pub fn runtime_unusable(&self) -> bool {
        self.runtime_unusable_until
            .map(|until| until > Utc::now())
            .unwrap_or(false)
    }
}

fn plan_matches(normalized: &str, plan: &str) -> bool {
    normalized == plan
        || normalized.starts_with(&format!("{plan}_"))
        || normalized.ends_with(&format!("_{plan}"))
        || normalized.contains(&format!("_{plan}_"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinuxBundleMetadata {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    #[serde(rename = "createdAt")]
    pub created_at: DateTime<Utc>,
    #[serde(rename = "expiresAt")]
    pub expires_at: DateTime<Utc>,
    #[serde(rename = "exportedByHost")]
    pub exported_by_host: String,
    #[serde(rename = "accountCount")]
    pub account_count: usize,
    #[serde(rename = "activeAccountId")]
    pub active_account_id: Option<String>,
    pub emails: Vec<String>,
}

pub fn default_store_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".codexswitch/accounts.json"))
}

pub struct AccountStoreLock {
    file: fs::File,
}

pub fn lock_account_store(path: &Path) -> Result<AccountStoreLock> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        ensure_permissions(parent, 0o700)?;
    }

    let lock_path = path.with_extension("json.lock");
    let file = fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("failed to open account store lock {}", lock_path.display()))?;
    fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", lock_path.display()))?;
    flock(file.as_raw_fd(), LOCK_EX)
        .with_context(|| format!("failed to lock {}", lock_path.display()))?;
    Ok(AccountStoreLock { file })
}

impl Drop for AccountStoreLock {
    fn drop(&mut self) {
        let _ = flock(self.file.as_raw_fd(), LOCK_UN);
    }
}

const LOCK_EX: i32 = 2;
const LOCK_UN: i32 = 8;

fn flock(fd: i32, operation: i32) -> Result<()> {
    unsafe extern "C" {
        #[link_name = "flock"]
        fn c_flock(fd: i32, operation: i32) -> i32;
    }
    let status = unsafe { c_flock(fd, operation) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error()).context("flock failed")
    }
}

pub fn load_accounts(path: &Path) -> Result<Vec<CodexAccount>> {
    let data = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let accounts: Vec<CodexAccount> = serde_json::from_slice(&data)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    Ok(remove_placeholder_quota_snapshots(&accounts))
}

pub fn save_accounts(path: &Path, accounts: &[CodexAccount]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        ensure_permissions(parent, 0o700)?;
    }

    let tmp = path.with_extension("json.tmp");
    let accounts = remove_placeholder_quota_snapshots(accounts);
    let data = serde_json::to_vec_pretty(&accounts).context("failed to encode accounts")?;
    fs::write(&tmp, data).with_context(|| format!("failed to write {}", tmp.display()))?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| {
        format!(
            "failed to atomically replace {} with {}",
            path.display(),
            tmp.display()
        )
    })?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", path.display()))?;
    Ok(())
}

pub fn remove_placeholder_quota_snapshots(accounts: &[CodexAccount]) -> Vec<CodexAccount> {
    accounts
        .iter()
        .cloned()
        .map(|mut account| {
            if account
                .quota_snapshot
                .as_ref()
                .map(QuotaSnapshot::has_backend_usage_placeholder)
                .unwrap_or(false)
            {
                account.quota_snapshot = None;
                account.last_refreshed = None;
            }
            account
        })
        .collect()
}

pub fn real_quota_snapshot(account: &CodexAccount) -> Option<&QuotaSnapshot> {
    account
        .quota_snapshot
        .as_ref()
        .filter(|snapshot| !snapshot.has_backend_usage_placeholder())
}

pub fn prefer_highest_usable_plan_active(accounts: &mut [CodexAccount]) {
    let target_id = select_plan_upgrade_candidate(accounts)
        .or_else(|| active_account(accounts))
        .or_else(|| select_auto_swap_candidate(accounts))
        .map(|account| account.account_id.clone());
    let Some(target_id) = target_id else { return };
    set_active(accounts, &target_id);
}

fn ensure_permissions(path: &Path, mode: u32) -> Result<()> {
    let current_mode = fs::metadata(path)
        .with_context(|| format!("failed to stat {}", path.display()))?
        .mode()
        & 0o777;
    if current_mode == mode {
        return Ok(());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("failed to chmod {}", path.display()))
}

pub fn active_account(accounts: &[CodexAccount]) -> Option<&CodexAccount> {
    accounts.iter().find(|account| account.is_active)
}

pub fn set_active(accounts: &mut [CodexAccount], account_id: &str) -> bool {
    let mut matched = false;
    for account in accounts {
        let is_match = account.account_id == account_id
            || account.email.eq_ignore_ascii_case(account_id)
            || account.id.to_string() == account_id;
        if is_match {
            matched = true;
        }
        account.is_active = is_match;
    }
    matched
}

pub fn score(account: &CodexAccount) -> f64 {
    if account.runtime_unusable() {
        return -1.0;
    }

    let Some(snapshot) = real_quota_snapshot(account) else {
        return -1.0;
    };
    if snapshot.weekly.is_exhausted() {
        return -1.0;
    }

    let plan_base = match account.plan_priority() {
        4 => 15_000.0,
        3 => 10_000.0,
        2 => 5_000.0,
        _ => 100.0,
    };

    if snapshot.five_hour.is_exhausted() {
        return -1.0;
    }

    let mut score = plan_base + snapshot.five_hour.remaining_percent();
    score += snapshot.weekly.remaining_percent() * 0.3;
    if snapshot.weekly.remaining_percent() < 20.0 {
        score -= 50.0;
    }
    score
}

pub fn is_immediately_usable(account: &CodexAccount) -> bool {
    if account.runtime_unusable() {
        return false;
    }

    let Some(snapshot) = real_quota_snapshot(account) else {
        return false;
    };
    score(account) > 0.0
        && !snapshot.five_hour.should_auto_swap_away()
        && !snapshot.weekly.should_auto_swap_away()
}

pub fn select_auto_swap_candidate(accounts: &[CodexAccount]) -> Option<&CodexAccount> {
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| is_immediately_usable(account))
        .max_by(|left, right| candidate_cmp(left, right))
}

pub fn select_plan_upgrade_candidate(accounts: &[CodexAccount]) -> Option<&CodexAccount> {
    let active = active_account(accounts)?;
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| account.plan_priority() > active.plan_priority())
        .filter(|account| is_immediately_usable(account))
        .max_by(|left, right| candidate_cmp(left, right))
}

fn candidate_cmp(left: &CodexAccount, right: &CodexAccount) -> std::cmp::Ordering {
    if should_use_five_hour_reset_tiebreaker(left, right) {
        let left_reset = reset_timestamp(&real_quota_snapshot(left).unwrap().five_hour);
        let right_reset = reset_timestamp(&real_quota_snapshot(right).unwrap().five_hour);
        if left_reset != right_reset {
            return right_reset.total_cmp(&left_reset);
        }
    }
    score(left).total_cmp(&score(right))
}

fn should_use_five_hour_reset_tiebreaker(left: &CodexAccount, right: &CodexAccount) -> bool {
    if left.plan_priority() != right.plan_priority() {
        return false;
    }
    let (Some(left_snapshot), Some(right_snapshot)) =
        (real_quota_snapshot(left), real_quota_snapshot(right))
    else {
        return false;
    };

    (left_snapshot.five_hour.remaining_percent() - right_snapshot.five_hour.remaining_percent())
        .abs()
        <= RESET_TIE_FIVE_HOUR_TOLERANCE
        && (left_snapshot.weekly.remaining_percent() - right_snapshot.weekly.remaining_percent())
            .abs()
            <= RESET_TIE_WEEKLY_TOLERANCE
        && reset_timestamp(&left_snapshot.five_hour).is_finite()
        && reset_timestamp(&right_snapshot.five_hour).is_finite()
}

fn reset_timestamp(window: &QuotaWindow) -> f64 {
    window
        .resets_at
        .as_f64()
        .or_else(|| {
            window.resets_at.as_str().and_then(|value| {
                value.parse().ok().or_else(|| {
                    DateTime::parse_from_rfc3339(value).ok().map(|datetime| {
                        let unix = datetime.timestamp_millis() as f64 / 1000.0;
                        unix - UNIX_TO_SWIFT_REFERENCE_SECONDS as f64
                    })
                })
            })
        })
        .unwrap_or(f64::INFINITY)
}

pub fn mark_runtime_unusable(account: &mut CodexAccount, reason: &str, until: DateTime<Utc>) {
    account.runtime_unusable_until = Some(until);
    account.runtime_unusable_reason = Some(reason.to_string());

    let fallback_reset = json!((until.timestamp() - 978_307_200) as f64);
    match &mut account.quota_snapshot {
        Some(snapshot) => {
            snapshot.five_hour.used_percent = 100.0;
            snapshot.five_hour.hard_limit_reached = true;
        }
        None => {
            account.quota_snapshot = Some(QuotaSnapshot {
                five_hour: QuotaWindow {
                    used_percent: 100.0,
                    window_duration_mins: 300,
                    resets_at: fallback_reset.clone(),
                    hard_limit_reached: true,
                },
                weekly: QuotaWindow {
                    used_percent: 0.0,
                    window_duration_mins: 10_080,
                    resets_at: fallback_reset,
                    hard_limit_reached: false,
                },
                fetched_at: Some(json!((Utc::now().timestamp() - 978_307_200) as f64)),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::mpsc;
    use std::time::Duration as StdDuration;

    fn account(email: &str, five_used: f64, weekly_used: f64, active: bool) -> CodexAccount {
        account_with_plan(email, five_used, weekly_used, active, "plus")
    }

    fn account_with_plan(
        email: &str,
        five_used: f64,
        weekly_used: f64,
        active: bool,
        plan_type: &str,
    ) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: email.to_string(),
            access_token: "access".to_string(),
            refresh_token: "refresh".to_string(),
            id_token: "id".to_string(),
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
                    window_duration_mins: 10080,
                    resets_at: json!(0),
                    hard_limit_reached: false,
                },
                fetched_at: None,
            }),
            plan_type: Some(plan_type.to_string()),
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

    #[test]
    fn selects_immediately_usable_candidate() {
        let accounts = vec![
            account("active@example.com", 99.5, 10.0, true),
            account("spent@example.com", 100.0, 10.0, false),
            account("ready@example.com", 20.0, 10.0, false),
        ];

        assert_eq!(
            select_auto_swap_candidate(&accounts).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
    }

    #[test]
    fn runtime_unusable_accounts_are_not_candidates() {
        let mut accounts = vec![
            account("active@example.com", 20.0, 10.0, true),
            account("blocked@example.com", 20.0, 10.0, false),
            account("ready@example.com", 30.0, 10.0, false),
        ];
        mark_runtime_unusable(
            &mut accounts[1],
            "insufficient_quota",
            Utc::now() + chrono::Duration::hours(5),
        );

        assert_eq!(
            select_auto_swap_candidate(&accounts).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        assert_eq!(score(&accounts[1]), -1.0);
    }

    #[test]
    fn auto_swap_threshold_matches_displayed_one_percent() {
        let displayed_as_two_percent = QuotaWindow {
            used_percent: 98.0,
            window_duration_mins: 300,
            resets_at: json!(0),
            hard_limit_reached: false,
        };
        let displayed_as_one_percent = QuotaWindow {
            used_percent: 98.01,
            window_duration_mins: 300,
            resets_at: json!(0),
            hard_limit_reached: false,
        };

        assert!(!displayed_as_two_percent.should_auto_swap_away());
        assert!(displayed_as_one_percent.should_auto_swap_away());
    }

    #[test]
    fn plan_priority_orders_pro_prolite_plus_free() {
        let active = account_with_plan("active@example.com", 20.0, 20.0, true, "pro");
        let free = account_with_plan("free@example.com", 0.0, 0.0, false, "free");
        let plus = account_with_plan("plus@example.com", 0.0, 0.0, false, "plus");
        let pro_lite = account_with_plan("prolite@example.com", 0.0, 0.0, false, "pro_lite");
        let pro = account_with_plan("pro@example.com", 95.0, 98.0, false, "pro");

        assert_eq!(pro.plan_priority(), 4);
        assert_eq!(pro_lite.plan_priority(), 3);
        assert_eq!(plus.plan_priority(), 2);
        assert_eq!(free.plan_priority(), 1);
        assert!(score(&pro) > score(&pro_lite));
        assert!(score(&pro_lite) > score(&plus));
        assert!(score(&plus) > score(&free));
        assert_eq!(
            select_auto_swap_candidate(&[active, free, plus, pro_lite, pro])
                .map(|account| account.email.as_str()),
            Some("pro@example.com")
        );
    }

    #[test]
    fn plan_priority_recognizes_aliases() {
        let plus = account_with_plan("plus@example.com", 0.0, 0.0, false, "chatgpt plus");
        let pro_lite =
            account_with_plan("prolite@example.com", 0.0, 0.0, false, "chatgpt_pro_lite");
        let pro = account_with_plan("pro@example.com", 95.0, 50.0, false, "ChatGPT Pro");
        let pro_monthly =
            account_with_plan("monthly@example.com", 95.0, 50.0, false, "pro-monthly");

        assert_eq!(plus.plan_priority(), 2);
        assert_eq!(pro_lite.plan_priority(), 3);
        assert_eq!(pro.plan_priority(), 4);
        assert_eq!(pro_monthly.plan_priority(), 4);
        assert!(score(&pro) > score(&plus));
    }

    #[test]
    fn healthy_plus_selects_usable_pro_upgrade() {
        let active_plus = account_with_plan("active@example.com", 20.0, 20.0, true, "plus");
        let ready_plus = account_with_plan("ready-plus@example.com", 0.0, 0.0, false, "plus");
        let ready_pro = account_with_plan("ready-pro@example.com", 90.0, 70.0, false, "pro");
        let spent_pro = account_with_plan("spent-pro@example.com", 99.0, 0.0, false, "pro");

        assert_eq!(
            select_plan_upgrade_candidate(&[active_plus, ready_plus, ready_pro, spent_pro])
                .map(|account| account.email.as_str()),
            Some("ready-pro@example.com")
        );
    }

    #[test]
    fn placeholder_quota_snapshots_are_not_usable_candidates() {
        let fetched_at = 802_157_341.0;
        let active = account("active@example.com", 99.0, 10.0, true);
        let mut placeholder = account_with_plan("placeholder@example.com", 0.0, 0.0, false, "pro");
        let snapshot = placeholder.quota_snapshot.as_mut().unwrap();
        snapshot.fetched_at = Some(json!(fetched_at));
        snapshot.five_hour.resets_at = json!(fetched_at);
        snapshot.weekly.resets_at = json!(fetched_at + 604_800.0);
        let ready_plus = account_with_plan("ready-plus@example.com", 40.0, 40.0, false, "plus");

        assert!(placeholder
            .quota_snapshot
            .as_ref()
            .unwrap()
            .has_backend_usage_placeholder());
        assert_eq!(score(&placeholder), -1.0);
        assert!(!is_immediately_usable(&placeholder));
        assert_eq!(
            select_auto_swap_candidate(&[active, placeholder, ready_plus])
                .map(|account| account.email.as_str()),
            Some("ready-plus@example.com")
        );
    }

    #[test]
    fn save_accounts_removes_placeholder_quota_snapshots() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let fetched_at = 802_157_341.0;
        let mut placeholder = account_with_plan("placeholder@example.com", 0.0, 0.0, true, "pro");
        let snapshot = placeholder.quota_snapshot.as_mut().unwrap();
        snapshot.fetched_at = Some(json!(fetched_at));
        snapshot.five_hour.resets_at = json!(fetched_at);
        snapshot.weekly.resets_at = json!(fetched_at + 604_800.0);
        placeholder.last_refreshed = Some(json!(fetched_at));

        save_accounts(&store_path, &[placeholder])?;

        let raw: Vec<CodexAccount> = serde_json::from_slice(&std::fs::read(&store_path)?)?;
        assert!(raw[0].quota_snapshot.is_none());
        assert!(raw[0].last_refreshed.is_none());
        Ok(())
    }

    #[test]
    fn comparable_paid_accounts_prefer_earlier_five_hour_reset() {
        let active = account("active@example.com", 99.0, 10.0, true);
        let mut later_reset_slightly_more_weekly =
            account_with_plan("later@example.com", 0.0, 47.0, false, "plus");
        let mut earlier_reset_slightly_less_weekly =
            account_with_plan("earlier@example.com", 0.0, 48.0, false, "plus");
        later_reset_slightly_more_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour
            .resets_at = json!(14_400.0);
        earlier_reset_slightly_less_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour
            .resets_at = json!(600.0);

        assert_eq!(
            select_auto_swap_candidate(&[
                active,
                later_reset_slightly_more_weekly,
                earlier_reset_slightly_less_weekly,
            ])
            .map(|account| account.email.as_str()),
            Some("earlier@example.com")
        );
    }

    #[test]
    fn earlier_five_hour_reset_does_not_beat_meaningful_quota_gap() {
        let active = account("active@example.com", 99.0, 10.0, true);
        let mut earlier_reset_low_weekly =
            account_with_plan("earlier-low@example.com", 0.0, 60.0, false, "plus");
        let mut later_reset_high_weekly =
            account_with_plan("later-high@example.com", 0.0, 20.0, false, "plus");
        earlier_reset_low_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour
            .resets_at = json!(600.0);
        later_reset_high_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour
            .resets_at = json!(14_400.0);

        assert_eq!(
            select_auto_swap_candidate(&[
                active,
                earlier_reset_low_weekly,
                later_reset_high_weekly
            ])
            .map(|account| account.email.as_str()),
            Some("later-high@example.com")
        );
    }

    #[test]
    fn account_store_lock_serializes_writers() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let first_lock = lock_account_store(&store_path)?;
        let (sender, receiver) = mpsc::channel();
        let second_store_path = store_path.clone();

        let handle = std::thread::spawn(move || {
            let _second_lock = lock_account_store(&second_store_path).unwrap();
            sender.send(()).unwrap();
        });

        assert!(receiver
            .recv_timeout(StdDuration::from_millis(100))
            .is_err());
        drop(first_lock);
        receiver.recv_timeout(StdDuration::from_secs(2))?;
        handle.join().unwrap();
        Ok(())
    }
}

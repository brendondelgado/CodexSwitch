use anyhow::{bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use ring::digest::{digest, SHA256};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::ffi::{CString, OsStr, OsString};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

use crate::rate_limit_resets::RateLimitResetBank;

const AUTO_SWAP_DISPLAYED_ONE_PERCENT_THRESHOLD: f64 = 2.0;
const RESET_TIE_FIVE_HOUR_TOLERANCE: f64 = 2.0;
const RESET_TIE_WEEKLY_TOLERANCE: f64 = 5.0;
const UNIX_TO_SWIFT_REFERENCE_SECONDS: i64 = 978_307_200;
pub const QUOTA_OBSERVATION_MAX_AGE: ChronoDuration = ChronoDuration::minutes(15);
const ACCOUNT_STORE_FILE_MODE: u32 = 0o600;
const ACCOUNT_STORE_DIRECTORY_MODE: u32 = 0o700;
const ACCOUNT_STORE_MAX_BYTES: usize = 32 * 1024 * 1024;

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
    #[serde(
        deserialize_with = "deserialize_optional_swift_datetime",
        serialize_with = "serialize_optional_swift_datetime"
    )]
    pub runtime_unusable_until: Option<DateTime<Utc>>,
    #[serde(default)]
    pub runtime_unusable_reason: Option<String>,
    #[serde(default)]
    pub rate_limit_reset_bank: Option<RateLimitResetBank>,
    pub is_active: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaWindowKind {
    FiveHour,
    Weekly,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuotaAvailability {
    Usable,
    Blocked,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct CurrentQuotaObservations {
    started_at: DateTime<Utc>,
    account_ids: HashSet<Uuid>,
}

impl CurrentQuotaObservations {
    pub fn new(started_at: DateTime<Utc>) -> Self {
        Self {
            started_at,
            account_ids: HashSet::new(),
        }
    }

    pub fn record_success(&mut self, account: &CodexAccount) -> bool {
        let current = real_quota_snapshot(account)
            .is_some_and(|snapshot| snapshot.fetched_at >= self.started_at);
        if current {
            self.account_ids.insert(account.id);
        }
        current
    }

    pub(crate) fn contains(&self, account: &CodexAccount) -> bool {
        self.account_ids.contains(&account.id)
    }
}

impl QuotaWindowKind {
    pub fn classify(duration_seconds: i64) -> Self {
        match duration_seconds {
            18_000 => Self::FiveHour,
            604_800 => Self::Weekly,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaWindowRateLimitSource {
    Main,
    Additional,
    Legacy,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaWindowSlot {
    Primary,
    Secondary,
    LegacyFiveHour,
    LegacyWeekly,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindowSourceMetadata {
    pub rate_limit: QuotaWindowRateLimitSource,
    pub slot: QuotaWindowSlot,
    pub limit_name: Option<String>,
    pub metered_feature: Option<String>,
}

impl QuotaWindowSourceMetadata {
    pub fn new(rate_limit: QuotaWindowRateLimitSource, slot: QuotaWindowSlot) -> Self {
        Self {
            rate_limit,
            slot,
            limit_name: None,
            metered_feature: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct QuotaSnapshot {
    pub allowed: Option<bool>,
    pub limit_reached: Option<bool>,
    pub fetched_at: DateTime<Utc>,
    pub windows: Vec<QuotaWindow>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub kind: QuotaWindowKind,
    pub duration_seconds: i64,
    pub used_percent: f64,
    #[serde(serialize_with = "serialize_swift_datetime")]
    pub resets_at: DateTime<Utc>,
    pub source: QuotaWindowSourceMetadata,
    #[serde(default)]
    pub hard_limit_reached: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuotaSnapshotWire {
    #[serde(default)]
    version: Option<u32>,
    #[serde(default)]
    schema_version: Option<u32>,
    #[serde(default)]
    allowed: Option<bool>,
    #[serde(default)]
    limit_reached: Option<bool>,
    #[serde(default, deserialize_with = "deserialize_optional_swift_datetime")]
    fetched_at: Option<DateTime<Utc>>,
    #[serde(default)]
    windows: Option<Vec<QuotaWindow>>,
    #[serde(default)]
    five_hour: Option<QuotaWindow>,
    #[serde(default)]
    weekly: Option<QuotaWindow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct QuotaSnapshotV2<'a> {
    version: u32,
    allowed: Option<bool>,
    limit_reached: Option<bool>,
    #[serde(serialize_with = "serialize_swift_datetime")]
    fetched_at: &'a DateTime<Utc>,
    windows: Vec<QuotaWindowV2<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct QuotaWindowV2<'a> {
    kind: QuotaWindowKind,
    duration_seconds: i64,
    used_percent: f64,
    #[serde(serialize_with = "serialize_swift_datetime")]
    resets_at: &'a DateTime<Utc>,
    source: &'a QuotaWindowSourceMetadata,
    hard_limit_reached: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuotaWindowWire {
    #[serde(default)]
    kind: Option<QuotaWindowKind>,
    #[serde(default)]
    duration_seconds: Option<i64>,
    #[serde(default)]
    window_duration_mins: Option<i64>,
    used_percent: f64,
    #[serde(deserialize_with = "deserialize_swift_datetime")]
    resets_at: DateTime<Utc>,
    #[serde(default)]
    source: Option<QuotaWindowSourceMetadata>,
    #[serde(default)]
    hard_limit_reached: bool,
}

impl Serialize for QuotaSnapshot {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let windows = self
            .windows
            .iter()
            .filter(|window| window.has_valid_duration())
            .map(|window| QuotaWindowV2 {
                kind: QuotaWindowKind::classify(window.duration_seconds),
                duration_seconds: window.duration_seconds,
                used_percent: window.used_percent,
                resets_at: &window.resets_at,
                source: &window.source,
                hard_limit_reached: window.hard_limit_reached,
            })
            .collect();
        QuotaSnapshotV2 {
            version: Self::CODING_VERSION,
            allowed: self.allowed,
            limit_reached: self.limit_reached,
            fetched_at: &self.fetched_at,
            windows,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for QuotaSnapshot {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = QuotaSnapshotWire::deserialize(deserializer)?;
        let fetched_at = wire
            .fetched_at
            .ok_or_else(|| serde::de::Error::missing_field("fetchedAt"))?;

        if let Some(version) = wire.version.or(wire.schema_version) {
            if version != Self::CODING_VERSION {
                return Err(serde::de::Error::custom(format!(
                    "unsupported quota snapshot version {version}"
                )));
            }
            return Ok(Self {
                allowed: wire.allowed,
                limit_reached: wire.limit_reached,
                fetched_at,
                windows: wire
                    .windows
                    .ok_or_else(|| serde::de::Error::missing_field("windows"))?
                    .into_iter()
                    .filter(QuotaWindow::has_valid_duration)
                    .collect(),
            });
        }

        let mut windows = Vec::new();
        if let Some(window) = wire.five_hour.filter(QuotaWindow::has_valid_duration) {
            windows.push(window.with_kind_and_source(
                QuotaWindowKind::FiveHour,
                QuotaWindowSourceMetadata::new(
                    QuotaWindowRateLimitSource::Legacy,
                    QuotaWindowSlot::LegacyFiveHour,
                ),
            ));
        }
        if let Some(window) = wire.weekly.filter(QuotaWindow::has_valid_duration) {
            windows.push(window.with_kind_and_source(
                QuotaWindowKind::Weekly,
                QuotaWindowSourceMetadata::new(
                    QuotaWindowRateLimitSource::Legacy,
                    QuotaWindowSlot::LegacyWeekly,
                ),
            ));
        }
        let legacy_limit_reached = windows.iter().any(|window| window.hard_limit_reached);
        Ok(Self {
            allowed: legacy_limit_reached.then_some(false),
            limit_reached: legacy_limit_reached.then_some(true),
            fetched_at,
            windows,
        })
    }
}

impl<'de> Deserialize<'de> for QuotaWindow {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = QuotaWindowWire::deserialize(deserializer)?;
        let duration_seconds = wire
            .duration_seconds
            .or_else(|| wire.window_duration_mins.map(|minutes| minutes * 60))
            .ok_or_else(|| serde::de::Error::missing_field("durationSeconds"))?;
        Ok(Self {
            kind: if wire.duration_seconds.is_some() {
                QuotaWindowKind::classify(duration_seconds)
            } else {
                wire.kind
                    .unwrap_or_else(|| QuotaWindowKind::classify(duration_seconds))
            },
            duration_seconds,
            used_percent: wire.used_percent,
            resets_at: wire.resets_at,
            source: wire.source.unwrap_or_else(|| {
                QuotaWindowSourceMetadata::new(
                    if wire.window_duration_mins.is_some() {
                        QuotaWindowRateLimitSource::Legacy
                    } else {
                        QuotaWindowRateLimitSource::Unknown
                    },
                    QuotaWindowSlot::Unknown,
                )
            }),
            hard_limit_reached: wire.hard_limit_reached,
        })
    }
}

impl QuotaWindow {
    fn has_valid_duration(&self) -> bool {
        self.duration_seconds > 0
    }

    fn is_known(&self) -> bool {
        matches!(
            self.kind,
            QuotaWindowKind::FiveHour | QuotaWindowKind::Weekly
        )
    }

    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).max(0.0)
    }

    pub fn effective_remaining_percent(&self) -> f64 {
        if self.is_exhausted() {
            0.0
        } else {
            self.remaining_percent()
        }
    }

    pub fn is_exhausted(&self) -> bool {
        self.has_valid_duration()
            && self.is_known()
            && (self.hard_limit_reached || self.remaining_percent() < 1.0)
    }

    pub fn should_auto_swap_away(&self) -> bool {
        self.has_valid_duration()
            && self.is_known()
            && (self.hard_limit_reached
                || self.remaining_percent() < AUTO_SWAP_DISPLAYED_ONE_PERCENT_THRESHOLD)
    }

    fn looks_like_backend_usage_placeholder(&self, fetched_at: Option<f64>) -> bool {
        let Some(fetched_at) = fetched_at else {
            return false;
        };
        !self.hard_limit_reached
            && self.used_percent <= 0.0001
            && (reset_timestamp(self) - fetched_at).abs() <= 10.0
    }

    fn with_kind_and_source(
        mut self,
        kind: QuotaWindowKind,
        source: QuotaWindowSourceMetadata,
    ) -> Self {
        self.kind = kind;
        self.source = source;
        self
    }
}

impl QuotaSnapshot {
    pub const CODING_VERSION: u32 = 2;

    pub fn five_hour(&self) -> Option<&QuotaWindow> {
        self.windows
            .iter()
            .find(|window| window.has_valid_duration() && window.kind == QuotaWindowKind::FiveHour)
    }

    #[cfg(test)]
    pub fn five_hour_mut(&mut self) -> Option<&mut QuotaWindow> {
        self.windows
            .iter_mut()
            .find(|window| window.has_valid_duration() && window.kind == QuotaWindowKind::FiveHour)
    }

    pub fn weekly(&self) -> Option<&QuotaWindow> {
        self.windows
            .iter()
            .find(|window| window.has_valid_duration() && window.kind == QuotaWindowKind::Weekly)
    }

    #[cfg(test)]
    pub fn weekly_mut(&mut self) -> Option<&mut QuotaWindow> {
        self.windows
            .iter_mut()
            .find(|window| window.has_valid_duration() && window.kind == QuotaWindowKind::Weekly)
    }

    pub fn ordered_windows(&self) -> Vec<&QuotaWindow> {
        let mut windows = self
            .windows
            .iter()
            .enumerate()
            .filter(|(_, window)| window.has_valid_duration())
            .collect::<Vec<_>>();
        windows.sort_by_key(|(index, window)| (window_kind_sort_rank(window.kind), *index));
        windows.into_iter().map(|(_, window)| window).collect()
    }

    pub fn is_denied(&self) -> bool {
        self.allowed == Some(false) || self.limit_reached == Some(true)
    }

    pub fn blocking_windows(&self) -> Vec<&QuotaWindow> {
        let windows = self.ordered_windows();
        if self.is_denied() {
            return windows
                .into_iter()
                .filter(|window| window.is_known())
                .collect();
        }
        windows
            .into_iter()
            .filter(|window| window.is_known() && window.should_auto_swap_away())
            .collect()
    }

    pub fn minimum_remaining_percent(&self) -> Option<f64> {
        if self.is_denied() {
            return Some(0.0);
        }
        self.windows
            .iter()
            .filter(|window| window.has_valid_duration() && window.is_known())
            .map(QuotaWindow::effective_remaining_percent)
            .reduce(f64::min)
    }

    pub fn is_fresh_at(&self, now: DateTime<Utc>) -> bool {
        let age = now.signed_duration_since(self.fetched_at);
        age >= ChronoDuration::zero() && age <= QUOTA_OBSERVATION_MAX_AGE
    }

    pub fn availability_at(&self, now: DateTime<Utc>) -> QuotaAvailability {
        if !self.is_fresh_at(now) {
            return QuotaAvailability::Unknown;
        }
        if self.is_denied() || !self.blocking_windows().is_empty() {
            return QuotaAvailability::Blocked;
        }
        if self
            .windows
            .iter()
            .any(|window| window.has_valid_duration() && window.is_known())
        {
            QuotaAvailability::Usable
        } else {
            QuotaAvailability::Unknown
        }
    }

    pub fn next_recovery_at(&self) -> Option<DateTime<Utc>> {
        self.blocking_windows()
            .into_iter()
            .map(|window| window.resets_at)
            .max()
    }

    pub fn has_expired_exhausted_window(&self, now: DateTime<Utc>) -> bool {
        self.blocking_windows()
            .into_iter()
            .any(|window| window.resets_at <= now)
    }

    pub fn has_backend_usage_placeholder(&self) -> bool {
        let fetched_at = swift_reference_seconds(self.fetched_at);
        self.windows
            .iter()
            .filter(|window| window.has_valid_duration())
            .any(|window| window.looks_like_backend_usage_placeholder(Some(fetched_at)))
    }
}

fn window_kind_sort_rank(kind: QuotaWindowKind) -> u8 {
    match kind {
        QuotaWindowKind::FiveHour => 0,
        QuotaWindowKind::Weekly => 1,
        QuotaWindowKind::Unknown => 2,
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

fn deserialize_swift_datetime<'de, D>(
    deserializer: D,
) -> std::result::Result<DateTime<Utc>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Value::deserialize(deserializer)?;
    datetime_from_swift_value(&value).ok_or_else(|| {
        serde::de::Error::custom(
            "expected Swift reference seconds, Unix timestamp string, or RFC3339 date",
        )
    })
}

fn serialize_swift_datetime<S>(
    value: &DateTime<Utc>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_f64(swift_reference_seconds(*value))
}

fn datetime_from_swift_value(value: &Value) -> Option<DateTime<Utc>> {
    let swift_reference_seconds = value_as_swift_reference_seconds(Some(value))?;
    let unix_seconds = swift_reference_seconds + UNIX_TO_SWIFT_REFERENCE_SECONDS as f64;
    let whole_seconds = unix_seconds.floor() as i64;
    let nanos = ((unix_seconds - whole_seconds as f64) * 1_000_000_000.0).round() as u32;
    if nanos == 1_000_000_000 {
        return DateTime::<Utc>::from_timestamp(whole_seconds + 1, 0);
    }
    DateTime::<Utc>::from_timestamp(whole_seconds, nanos)
}

pub fn swift_reference_seconds(value: DateTime<Utc>) -> f64 {
    value.timestamp() as f64 + value.timestamp_subsec_nanos() as f64 / 1_000_000_000.0
        - UNIX_TO_SWIFT_REFERENCE_SECONDS as f64
}

pub fn swift_reference_value(value: DateTime<Utc>) -> Value {
    json!(swift_reference_seconds(value))
}

fn deserialize_optional_swift_datetime<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<DateTime<Utc>>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    let Some(value) = value else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    datetime_from_swift_value(&value)
        .ok_or_else(|| serde::de::Error::custom("date is out of range"))
        .map(Some)
}

fn serialize_optional_swift_datetime<S>(
    value: &Option<DateTime<Utc>>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match value {
        Some(datetime) => serializer.serialize_f64(swift_reference_seconds(*datetime)),
        None => serializer.serialize_none(),
    }
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
        self.runtime_unusable_at(Utc::now())
    }

    pub fn runtime_unusable_at(&self, now: DateTime<Utc>) -> bool {
        self.runtime_unusable_until.is_some_and(|until| until > now)
    }

    pub fn runtime_block_is_usage_limit(&self) -> bool {
        self.runtime_unusable_reason
            .as_deref()
            .map(normalized_runtime_reason_is_usage_limit)
            .unwrap_or(false)
    }
}

fn normalized_runtime_reason_is_usage_limit(reason: &str) -> bool {
    let normalized = reason.trim().to_ascii_lowercase().replace(['-', ' '], "_");
    normalized.contains("usage_limit") || normalized.contains("insufficient_quota")
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
    normalize_account_store_path(&PathBuf::from(home).join(".codexswitch/accounts.json"))
}

pub struct AccountStoreLock {
    file: fs::File,
    directory: AccountStoreDirectory,
    store_path: PathBuf,
    store_name: OsString,
}

struct AccountStoreDirectory {
    file: fs::File,
    path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountStoreGeneration(String);

impl AccountStoreGeneration {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone)]
pub struct AccountStoreSnapshot {
    pub accounts: Vec<CodexAccount>,
    pub generation: AccountStoreGeneration,
    raw_bytes: Option<Vec<u8>>,
}

impl AccountStoreSnapshot {
    pub(crate) fn raw_bytes(&self) -> Option<&[u8]> {
        self.raw_bytes.as_deref()
    }
}

pub fn lock_account_store(path: &Path) -> Result<AccountStoreLock> {
    let store_path = normalize_account_store_path(path)?;
    let directory = open_account_store_directory(&store_path, true)?;
    let store_name = account_store_file_name(&store_path)?.to_os_string();
    let lock_path = store_path.with_extension("json.lock");
    let lock_name = account_store_file_name(&lock_path)?;
    let file = open_file_at(
        &directory.file,
        lock_name,
        libc::O_CREAT | libc::O_RDWR | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        0o600,
    )
    .with_context(|| format!("failed to open account store lock {}", lock_path.display()))?;
    validate_owned_regular_file_identity(&file, &lock_path, current_uid())?;
    set_descriptor_mode(&file, &lock_path, ACCOUNT_STORE_FILE_MODE)?;
    validate_owned_regular_file(&file, &lock_path, current_uid())?;
    flock(file.as_raw_fd(), LOCK_EX)
        .with_context(|| format!("failed to lock {}", lock_path.display()))?;
    Ok(AccountStoreLock {
        file,
        directory,
        store_path,
        store_name,
    })
}

impl AccountStoreLock {
    pub(crate) fn store_path(&self) -> &Path {
        &self.store_path
    }

    pub fn load(&self) -> Result<AccountStoreSnapshot> {
        load_account_store_snapshot_at(&self.directory, &self.store_name, &self.store_path, true)
    }

    pub(crate) fn with_lock_released<T, F>(&self, operation: F) -> Result<T>
    where
        F: FnOnce() -> Result<T>,
    {
        flock(self.file.as_raw_fd(), LOCK_UN)
            .context("failed to release account-store lock for external I/O")?;
        struct Relock<'a> {
            lock: &'a AccountStoreLock,
            active: bool,
        }
        impl Drop for Relock<'_> {
            fn drop(&mut self) {
                if self.active {
                    let _ = flock(self.lock.file.as_raw_fd(), LOCK_EX);
                }
            }
        }
        let mut relock = Relock {
            lock: self,
            active: true,
        };
        let result = operation();
        flock(self.file.as_raw_fd(), LOCK_EX)
            .context("failed to reacquire account-store lock after external I/O")?;
        relock.active = false;
        result
    }

    pub fn commit(
        &self,
        expected_generation: &AccountStoreGeneration,
        accounts: &[CodexAccount],
    ) -> Result<AccountStoreSnapshot> {
        validate_accounts(accounts)?;
        let current = load_account_store_snapshot_at(
            &self.directory,
            &self.store_name,
            &self.store_path,
            true,
        )?;
        if &current.generation != expected_generation {
            bail!(
                "account store generation changed while locked: expected {}, found {}",
                expected_generation.0,
                current.generation.0
            );
        }

        let accounts = remove_placeholder_quota_snapshots(accounts);
        validate_accounts(&accounts)?;
        let data = serde_json::to_vec_pretty(&accounts).context("failed to encode accounts")?;
        validate_account_store_byte_length(data.len())?;
        let expected_written_generation = account_store_generation(&data);
        let file_name = self
            .store_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("accounts.json");
        let temporary_name = OsString::from(format!(
            ".{file_name}.tmp-{}-{}",
            std::process::id(),
            Uuid::new_v4()
        ));
        let temporary = self.directory.path.join(&temporary_name);
        let write_result = (|| -> Result<()> {
            let mut file =
                create_account_store_temp_file(&self.directory, &temporary_name, &temporary)?;
            let created = descriptor_identity(&file, &temporary)?;
            file.write_all(&data)
                .with_context(|| format!("failed to write {}", temporary.display()))?;
            file.sync_all()
                .with_context(|| format!("failed to sync {}", temporary.display()))?;
            rename_file_at(&self.directory.file, &temporary_name, &self.store_name).with_context(
                || {
                    format!(
                        "failed to atomically replace {} with {}",
                        self.store_path.display(),
                        temporary.display()
                    )
                },
            )?;
            verify_reopened_store_inode(
                &self.directory,
                &self.store_name,
                &self.store_path,
                created,
            )?;
            self.directory
                .file
                .sync_all()
                .with_context(|| format!("failed to sync {}", self.directory.path.display()))?;
            Ok(())
        })();
        if write_result.is_err() {
            let _ = unlink_file_at(&self.directory.file, &temporary_name);
        }
        write_result?;

        let readback = load_account_store_snapshot_at(
            &self.directory,
            &self.store_name,
            &self.store_path,
            false,
        )?;
        if readback.generation != expected_written_generation {
            bail!("account store readback generation did not match committed bytes");
        }
        Ok(readback)
    }

    pub(crate) fn prospective_generation(
        &self,
        accounts: &[CodexAccount],
    ) -> Result<AccountStoreGeneration> {
        let accounts = remove_placeholder_quota_snapshots(accounts);
        validate_accounts(&accounts)?;
        let data = serde_json::to_vec_pretty(&accounts).context("failed to encode accounts")?;
        validate_account_store_byte_length(data.len())?;
        Ok(account_store_generation(&data))
    }

    pub(crate) fn restore_if_owned(
        &self,
        owned_generation: &AccountStoreGeneration,
        previous_raw_bytes: Option<&[u8]>,
    ) -> Result<AccountStoreSnapshot> {
        let current = self.load()?;
        if &current.generation != owned_generation {
            bail!(
                "account store rollback ownership lost: activation owned {}, found {}",
                owned_generation.0,
                current.generation.0
            );
        }

        match previous_raw_bytes {
            Some(data) => {
                let previous_accounts: Vec<CodexAccount> = serde_json::from_slice(data)
                    .context("failed to decode durable account-store rollback image")?;
                validate_accounts(&previous_accounts)?;
                self.replace_bytes(data)?;
                let restored = self.load()?;
                let expected = account_store_generation(data);
                if restored.generation != expected {
                    bail!("account store rollback readback generation mismatch");
                }
                Ok(restored)
            }
            None => {
                match unlink_file_at(&self.directory.file, &self.store_name) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!(
                                "failed to remove {} during rollback",
                                self.store_path.display()
                            )
                        })
                    }
                }
                self.directory.file.sync_all().with_context(|| {
                    format!(
                        "failed to sync {} after rollback",
                        self.directory.path.display()
                    )
                })?;
                self.load()
            }
        }
    }

    fn replace_bytes(&self, data: &[u8]) -> Result<()> {
        validate_account_store_byte_length(data.len())?;
        let file_name = self
            .store_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("accounts.json");
        let temporary_name = OsString::from(format!(
            ".{file_name}.rollback-{}-{}",
            std::process::id(),
            Uuid::new_v4()
        ));
        let temporary = self.directory.path.join(&temporary_name);
        let result = (|| -> Result<()> {
            let mut file =
                create_account_store_temp_file(&self.directory, &temporary_name, &temporary)?;
            let created = descriptor_identity(&file, &temporary)?;
            file.write_all(data)
                .with_context(|| format!("failed to write {}", temporary.display()))?;
            file.sync_all()
                .with_context(|| format!("failed to sync {}", temporary.display()))?;
            rename_file_at(&self.directory.file, &temporary_name, &self.store_name)?;
            verify_reopened_store_inode(
                &self.directory,
                &self.store_name,
                &self.store_path,
                created,
            )?;
            self.directory
                .file
                .sync_all()
                .with_context(|| format!("failed to sync {}", self.directory.path.display()))
        })();
        if result.is_err() {
            let _ = unlink_file_at(&self.directory.file, &temporary_name);
        }
        result
    }
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

fn open_account_store_directory(path: &Path, create: bool) -> Result<AccountStoreDirectory> {
    open_account_store_directory_with(path, create, |_parent, _component| Ok(()))
}

fn open_account_store_directory_with<F>(
    path: &Path,
    create: bool,
    mut before_component_open: F,
) -> Result<AccountStoreDirectory>
where
    F: FnMut(&Path, &OsStr) -> Result<()>,
{
    let parent = account_store_parent(path);
    if !parent.is_absolute() {
        bail!("account store path must be absolute before secure traversal");
    }

    let mut directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/")
        .context("failed to open filesystem root for account store traversal")?;
    let mut traversed = PathBuf::from("/");
    let components = parent
        .components()
        .filter_map(|component| match component {
            std::path::Component::RootDir | std::path::Component::CurDir => None,
            std::path::Component::Normal(component) => Some(Ok(component)),
            std::path::Component::ParentDir => Some(Err(anyhow::anyhow!(
                "account store path contains a parent traversal"
            ))),
            std::path::Component::Prefix(_) => Some(Err(anyhow::anyhow!(
                "account store path contains an unsupported prefix"
            ))),
        })
        .collect::<Result<Vec<_>>>()?;
    for (index, component) in components.iter().enumerate() {
        before_component_open(&traversed, component)?;
        let next = match open_directory_at(&directory, component) {
            Ok(next) => next,
            Err(error)
                if create && error.kind() == std::io::ErrorKind::NotFound =>
            {
                match create_directory_at(&directory, component, 0o700) {
                    Ok(()) => directory.sync_all().with_context(|| {
                        format!("failed to sync parent directory {}", traversed.display())
                    })?,
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!(
                                "failed to create account store parent component {}/{}",
                                traversed.display(),
                                component.to_string_lossy()
                            )
                        })
                    }
                }
                open_directory_at(&directory, component).with_context(|| {
                    format!(
                        "failed to open newly created account store parent component {}/{} without following symlinks",
                        traversed.display(),
                        component.to_string_lossy()
                    )
                })?
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "failed to open account store parent component {}/{} without following symlinks",
                        traversed.display(),
                        component.to_string_lossy()
                    )
                })
            }
        };
        traversed.push(component);
        validate_directory_component(
            &next,
            &traversed,
            current_uid(),
            index + 1 == components.len(),
        )?;
        directory = next;
    }
    if components.is_empty() {
        bail!("account store parent cannot be the filesystem root");
    }
    if create {
        set_descriptor_mode(&directory, parent, ACCOUNT_STORE_DIRECTORY_MODE)?;
    }
    validate_final_directory_mode(&directory, parent)?;
    Ok(AccountStoreDirectory {
        file: directory,
        path: parent.to_path_buf(),
    })
}

fn account_store_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn account_store_file_name(path: &Path) -> Result<&OsStr> {
    path.file_name()
        .filter(|name| !name.is_empty())
        .context("account store path must include a file name")
}

fn validate_directory_component(
    directory: &fs::File,
    path: &Path,
    expected_uid: u32,
    final_component: bool,
) -> Result<()> {
    let metadata = directory
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    if !metadata.file_type().is_dir() {
        bail!("account store parent {} is not a directory", path.display());
    }
    if metadata.uid() != expected_uid && metadata.uid() != 0 {
        bail!(
            "unsafe account store parent component {} is owned by uid {}, expected {} or root",
            path.display(),
            metadata.uid(),
            expected_uid
        );
    }
    let mode = metadata.mode();
    let writable_by_others = mode & 0o022 != 0;
    let trusted_sticky_directory = metadata.uid() == 0 && mode & libc::S_ISVTX as u32 != 0;
    if writable_by_others && !trusted_sticky_directory {
        bail!(
            "unsafe account store parent component {} is group- or world-writable",
            path.display()
        );
    }
    if final_component && metadata.uid() != expected_uid {
        bail!(
            "account store parent {} is owned by uid {}, expected {}",
            path.display(),
            metadata.uid(),
            expected_uid
        );
    }
    Ok(())
}

fn validate_final_directory_mode(directory: &fs::File, path: &Path) -> Result<()> {
    let metadata = directory
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    let actual = metadata.mode() & 0o777;
    if actual != ACCOUNT_STORE_DIRECTORY_MODE {
        bail!(
            "account store parent {} has mode {:03o}, expected {:03o}",
            path.display(),
            actual,
            ACCOUNT_STORE_DIRECTORY_MODE
        );
    }
    Ok(())
}

fn validate_owned_regular_file(file: &fs::File, path: &Path, expected_uid: u32) -> Result<()> {
    validate_owned_regular_file_identity(file, path, expected_uid)?;
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    let actual = metadata.mode() & 0o777;
    if actual != ACCOUNT_STORE_FILE_MODE {
        bail!(
            "unsafe account store file {} has mode {:03o}, expected {:03o}",
            path.display(),
            actual,
            ACCOUNT_STORE_FILE_MODE
        );
    }
    Ok(())
}

fn validate_owned_regular_file_identity(
    file: &fs::File,
    path: &Path,
    expected_uid: u32,
) -> Result<()> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    validate_regular_file_metadata(&metadata, expected_uid)
        .with_context(|| format!("unsafe account store file {}", path.display()))
}

fn validate_regular_file_metadata(metadata: &fs::Metadata, expected_uid: u32) -> Result<()> {
    if !metadata.file_type().is_file() {
        bail!("descriptor is not a regular file");
    }
    if metadata.uid() != expected_uid {
        bail!(
            "descriptor is owned by uid {}, expected {}",
            metadata.uid(),
            expected_uid
        );
    }
    Ok(())
}

fn set_descriptor_mode(file: &fs::File, path: &Path, mode: u32) -> Result<()> {
    let status = unsafe { libc::fchmod(file.as_raw_fd(), mode as libc::mode_t) };
    if status != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("failed to fchmod {}", path.display()));
    }
    Ok(())
}

fn validate_account_store_byte_length(length: usize) -> Result<()> {
    if length > ACCOUNT_STORE_MAX_BYTES {
        bail!(
            "account store exceeds the {} byte limit",
            ACCOUNT_STORE_MAX_BYTES
        );
    }
    Ok(())
}

fn descriptor_identity(file: &fs::File, path: &Path) -> Result<(u64, u64)> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    Ok((metadata.dev(), metadata.ino()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StableAccountStoreIdentity {
    device: u64,
    inode: u64,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

fn stable_account_store_identity(
    file: &fs::File,
    path: &Path,
) -> Result<StableAccountStoreIdentity> {
    let metadata = file
        .metadata()
        .with_context(|| format!("failed to fstat {}", path.display()))?;
    Ok(StableAccountStoreIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        length: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
    })
}

fn verify_reopened_store_inode(
    directory: &AccountStoreDirectory,
    store_name: &OsStr,
    store_path: &Path,
    expected: (u64, u64),
) -> Result<()> {
    let file = open_file_at(
        &directory.file,
        store_name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        0,
    )
    .with_context(|| format!("failed to reopen {} after rename", store_path.display()))?;
    validate_owned_regular_file(&file, store_path, current_uid())?;
    let observed = descriptor_identity(&file, store_path)?;
    if observed != expected {
        bail!(
            "account store inode changed during atomic rename: expected {}:{}, found {}:{}",
            expected.0,
            expected.1,
            observed.0,
            observed.1
        );
    }
    Ok(())
}

fn normalize_account_store_path(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        bail!("account store path must be absolute");
    }
    if path
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        bail!("account store path cannot contain parent traversal");
    }

    #[cfg(target_os = "macos")]
    {
        for (alias, canonical) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if let Ok(remainder) = path.strip_prefix(alias) {
                return Ok(Path::new(canonical).join(remainder));
            }
        }
    }
    Ok(path.to_path_buf())
}

fn open_directory_at(directory: &fs::File, name: &OsStr) -> std::io::Result<fs::File> {
    open_file_at(
        directory,
        name,
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        0,
    )
}

fn create_directory_at(directory: &fs::File, name: &OsStr, mode: u32) -> std::io::Result<()> {
    let name = c_path_component(name)?;
    let status =
        unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), mode as libc::mode_t) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn create_account_store_temp_file(
    directory: &AccountStoreDirectory,
    temporary_name: &OsStr,
    temporary_path: &Path,
) -> Result<fs::File> {
    let file = open_file_at(
        &directory.file,
        temporary_name,
        libc::O_CREAT
            | libc::O_EXCL
            | libc::O_WRONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK,
        0o600,
    )
    .with_context(|| format!("failed to create {}", temporary_path.display()))?;
    validate_owned_regular_file_identity(&file, temporary_path, current_uid())?;
    set_descriptor_mode(&file, temporary_path, ACCOUNT_STORE_FILE_MODE)?;
    validate_owned_regular_file(&file, temporary_path, current_uid())?;
    Ok(file)
}

fn open_file_at(
    directory: &fs::File,
    name: &OsStr,
    flags: i32,
    mode: u32,
) -> std::io::Result<fs::File> {
    let name = c_path_component(name)?;
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags,
            mode as libc::c_uint,
        )
    };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { fs::File::from_raw_fd(descriptor) })
}

fn rename_file_at(directory: &fs::File, from: &OsStr, to: &OsStr) -> std::io::Result<()> {
    let from = c_path_component(from)?;
    let to = c_path_component(to)?;
    let status = unsafe {
        libc::renameat(
            directory.as_raw_fd(),
            from.as_ptr(),
            directory.as_raw_fd(),
            to.as_ptr(),
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn unlink_file_at(directory: &fs::File, name: &OsStr) -> std::io::Result<()> {
    let name = c_path_component(name)?;
    let status = unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn c_path_component(name: &OsStr) -> std::io::Result<CString> {
    if name.as_bytes().contains(&b'/') {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path component contains a separator",
        ));
    }
    CString::new(name.as_bytes()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path component contains a null byte",
        )
    })
}

fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}

fn load_account_store_snapshot_at(
    directory: &AccountStoreDirectory,
    store_name: &OsStr,
    path: &Path,
    allow_missing: bool,
) -> Result<AccountStoreSnapshot> {
    let data = match open_file_at(
        &directory.file,
        store_name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        0,
    ) {
        Ok(mut file) => {
            validate_owned_regular_file(&file, path, current_uid())?;
            let before = stable_account_store_identity(&file, path)?;
            let length = usize::try_from(before.length)
                .context("account store length does not fit in memory")?;
            validate_account_store_byte_length(length)?;
            let mut data = Vec::with_capacity(length);
            file.read_to_end(&mut data)
                .with_context(|| format!("failed to read {}", path.display()))?;
            validate_account_store_byte_length(data.len())?;
            if stable_account_store_identity(&file, path)? != before {
                bail!("account store changed during observation");
            }
            let reopened = open_file_at(
                &directory.file,
                store_name,
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                0,
            )
            .with_context(|| format!("failed to reopen {} after observation", path.display()))?;
            validate_owned_regular_file(&reopened, path, current_uid())?;
            if stable_account_store_identity(&reopened, path)? != before {
                bail!("account store was replaced during observation");
            }
            data
        }
        Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AccountStoreSnapshot {
                accounts: Vec::new(),
                generation: AccountStoreGeneration("missing".to_string()),
                raw_bytes: None,
            });
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to open {}", path.display()))
        }
    };
    let accounts: Vec<CodexAccount> = serde_json::from_slice(&data)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    let accounts = remove_placeholder_quota_snapshots(&accounts);
    validate_accounts(&accounts)?;
    Ok(AccountStoreSnapshot {
        accounts,
        generation: account_store_generation(&data),
        raw_bytes: Some(data),
    })
}

pub(crate) fn load_account_store_snapshot(path: &Path) -> Result<AccountStoreSnapshot> {
    let store_path = normalize_account_store_path(path)?;
    let directory = open_account_store_directory(&store_path, false)?;
    let store_name = account_store_file_name(&store_path)?;
    load_account_store_snapshot_at(&directory, store_name, &store_path, false)
}

pub fn load_accounts(path: &Path) -> Result<Vec<CodexAccount>> {
    Ok(load_account_store_snapshot(path)?.accounts)
}

pub fn commit_accounts(
    store_lock: &AccountStoreLock,
    generation: &mut AccountStoreGeneration,
    accounts: &[CodexAccount],
) -> Result<()> {
    let committed = store_lock.commit(generation, accounts)?;
    *generation = committed.generation;
    Ok(())
}

#[cfg(test)]
pub fn save_accounts(path: &Path, accounts: &[CodexAccount]) -> Result<()> {
    let store_lock = lock_account_store(path)?;
    let snapshot = store_lock.load()?;
    store_lock.commit(&snapshot.generation, accounts)?;
    Ok(())
}

fn account_store_generation(data: &[u8]) -> AccountStoreGeneration {
    AccountStoreGeneration(
        digest(&SHA256, data)
            .as_ref()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

pub fn validate_accounts(accounts: &[CodexAccount]) -> Result<()> {
    if accounts.is_empty() {
        return Ok(());
    }
    if accounts.iter().filter(|account| account.is_active).count() != 1 {
        bail!("non-empty account store must contain exactly one active account");
    }

    let mut local_ids = HashSet::new();
    let mut provider_ids = HashSet::new();
    for account in accounts {
        if account.id.is_nil() || !local_ids.insert(account.id) {
            bail!("account store contains a missing or duplicate local account identity");
        }
        let provider_id = account.account_id.trim();
        if provider_id.is_empty() || !provider_ids.insert(provider_id.to_string()) {
            bail!("account store contains a missing or duplicate provider account identity");
        }
    }
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

pub fn active_account(accounts: &[CodexAccount]) -> Option<&CodexAccount> {
    accounts.iter().find(|account| account.is_active)
}

pub fn resolve_account_selector(accounts: &[CodexAccount], selector: &str) -> Result<Uuid> {
    let matches = accounts
        .iter()
        .filter(|account| {
            account.account_id == selector
                || account.email.eq_ignore_ascii_case(selector)
                || account.id.to_string() == selector
        })
        .map(|account| account.id)
        .collect::<HashSet<_>>();
    match matches.len() {
        0 => bail!("no account matched {selector}"),
        1 => matches
            .into_iter()
            .next()
            .context("resolved account selector lost its only match"),
        _ => bail!("account selector {selector} is ambiguous"),
    }
}

pub fn activate_account(accounts: &mut [CodexAccount], target_id: Uuid) -> Result<()> {
    if accounts
        .iter()
        .filter(|account| account.id == target_id)
        .count()
        != 1
    {
        bail!("activation target must match exactly one stable local identity");
    }
    for account in accounts.iter_mut() {
        account.is_active = account.id == target_id;
    }
    validate_accounts(accounts)
}

pub fn quota_availability_at(account: &CodexAccount, now: DateTime<Utc>) -> QuotaAvailability {
    if !account.has_complete_token_material() {
        return QuotaAvailability::Unknown;
    }
    if account.runtime_unusable_at(now) {
        return QuotaAvailability::Blocked;
    }
    real_quota_snapshot(account)
        .map(|snapshot| snapshot.availability_at(now))
        .unwrap_or(QuotaAvailability::Unknown)
}

impl CodexAccount {
    pub fn has_complete_token_material(&self) -> bool {
        [
            self.id_token.as_str(),
            self.access_token.as_str(),
            self.refresh_token.as_str(),
            self.account_id.as_str(),
        ]
        .iter()
        .all(|value| !value.trim().is_empty())
    }
}

pub fn score(account: &CodexAccount, now: DateTime<Utc>) -> f64 {
    if quota_availability_at(account, now) != QuotaAvailability::Usable {
        return -1.0;
    }

    let Some(snapshot) = real_quota_snapshot(account) else {
        return -1.0;
    };

    let plan_base = match account.plan_priority() {
        4 => 15_000.0,
        3 => 10_000.0,
        2 => 5_000.0,
        _ => 100.0,
    };

    let mut score = plan_base;
    if let Some(five_hour) = snapshot.five_hour() {
        score += five_hour.remaining_percent();
    }
    if let Some(weekly) = snapshot.weekly() {
        score += weekly.remaining_percent() * 0.3;
        if weekly.remaining_percent() < 20.0 {
            score -= 50.0;
        }
    }
    score
}

#[cfg(test)]
fn select_auto_swap_candidate(
    accounts: &[CodexAccount],
    now: DateTime<Utc>,
) -> Option<&CodexAccount> {
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| quota_availability_at(account, now) == QuotaAvailability::Usable)
        .max_by(|left, right| candidate_cmp(left, right, now))
}

pub fn select_auto_swap_candidate_from_observations<'a>(
    accounts: &'a [CodexAccount],
    observations: &CurrentQuotaObservations,
    now: DateTime<Utc>,
) -> Option<&'a CodexAccount> {
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| observations.contains(account))
        .filter(|account| quota_availability_at(account, now) == QuotaAvailability::Usable)
        .max_by(|left, right| candidate_cmp(left, right, now))
}

pub fn select_plan_upgrade_candidate(
    accounts: &[CodexAccount],
    now: DateTime<Utc>,
) -> Option<&CodexAccount> {
    let active = active_account(accounts)?;
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| account.plan_priority() > active.plan_priority())
        .filter(|account| quota_availability_at(account, now) == QuotaAvailability::Usable)
        .max_by(|left, right| candidate_cmp(left, right, now))
}

pub fn select_plan_upgrade_candidate_from_observations<'a>(
    accounts: &'a [CodexAccount],
    observations: &CurrentQuotaObservations,
    now: DateTime<Utc>,
) -> Option<&'a CodexAccount> {
    let active = active_account(accounts)?;
    accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| observations.contains(account))
        .filter(|account| account.plan_priority() > active.plan_priority())
        .filter(|account| quota_availability_at(account, now) == QuotaAvailability::Usable)
        .max_by(|left, right| candidate_cmp(left, right, now))
}

fn candidate_cmp(
    left: &CodexAccount,
    right: &CodexAccount,
    now: DateTime<Utc>,
) -> std::cmp::Ordering {
    if should_use_five_hour_reset_tiebreaker(left, right) {
        let left_reset = reset_timestamp(real_quota_snapshot(left).unwrap().five_hour().unwrap());
        let right_reset = reset_timestamp(real_quota_snapshot(right).unwrap().five_hour().unwrap());
        if left_reset != right_reset {
            return right_reset.total_cmp(&left_reset);
        }
    }
    score(left, now).total_cmp(&score(right, now))
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
    let (Some(left_five_hour), Some(right_five_hour)) =
        (left_snapshot.five_hour(), right_snapshot.five_hour())
    else {
        return false;
    };
    let (Some(left_weekly), Some(right_weekly)) = (left_snapshot.weekly(), right_snapshot.weekly())
    else {
        return false;
    };

    (left_five_hour.remaining_percent() - right_five_hour.remaining_percent()).abs()
        <= RESET_TIE_FIVE_HOUR_TOLERANCE
        && (left_weekly.remaining_percent() - right_weekly.remaining_percent()).abs()
            <= RESET_TIE_WEEKLY_TOLERANCE
        && reset_timestamp(left_five_hour).is_finite()
        && reset_timestamp(right_five_hour).is_finite()
}

fn reset_timestamp(window: &QuotaWindow) -> f64 {
    reset_datetime(window)
        .map(|datetime| {
            datetime.timestamp_millis() as f64 / 1000.0 - UNIX_TO_SWIFT_REFERENCE_SECONDS as f64
        })
        .unwrap_or(f64::INFINITY)
}

pub fn reset_datetime(window: &QuotaWindow) -> Option<DateTime<Utc>> {
    Some(window.resets_at)
}

pub fn usage_limit_runtime_block_until(
    account: &CodexAccount,
    fallback_until: DateTime<Utc>,
) -> DateTime<Utc> {
    let Some(snapshot) = real_quota_snapshot(account) else {
        return fallback_until;
    };

    snapshot.next_recovery_at().unwrap_or(fallback_until)
}

pub fn mark_runtime_unusable(account: &mut CodexAccount, reason: &str, until: DateTime<Utc>) {
    account.runtime_unusable_until = Some(until);
    account.runtime_unusable_reason = Some(reason.to_string());

    if normalized_runtime_reason_is_usage_limit(reason) {
        let snapshot = account.quota_snapshot.get_or_insert_with(|| QuotaSnapshot {
            allowed: Some(false),
            limit_reached: Some(true),
            fetched_at: Utc::now(),
            windows: Vec::new(),
        });
        snapshot.allowed = Some(false);
        snapshot.limit_reached = Some(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::process::Command;
    use std::sync::mpsc;
    use std::time::{Duration as StdDuration, Instant};

    fn create_fifo(path: &Path) -> Result<()> {
        let path = std::ffi::CString::new(path.as_os_str().as_bytes())?;
        let status = unsafe { libc::mkfifo(path.as_ptr(), 0o600) };
        if status == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error()).context("failed to create test fifo")
        }
    }

    fn wait_for_test_child(mut child: std::process::Child) -> Result<std::process::ExitStatus> {
        let deadline = Instant::now() + StdDuration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                bail!("account-store test child exceeded its deadline");
            }
            std::thread::sleep(StdDuration::from_millis(20));
        }
    }

    #[test]
    #[ignore = "cross-process helper invoked by account-store protocol tests"]
    fn account_store_cross_process_helper() -> Result<()> {
        let Some(action) = std::env::var_os("CODEXSWITCH_ACCOUNT_STORE_CHILD_ACTION") else {
            return Ok(());
        };
        let store_path = PathBuf::from(
            std::env::var_os("CODEXSWITCH_ACCOUNT_STORE_CHILD_PATH")
                .context("missing child store path")?,
        );
        match action.to_string_lossy().as_ref() {
            "lock" => {
                let _lock = lock_account_store(&store_path)?;
                let marker = std::env::var_os("CODEXSWITCH_ACCOUNT_STORE_CHILD_MARKER")
                    .context("missing child marker path")?;
                fs::write(marker, b"locked")?;
            }
            "hostile-umask" => {
                unsafe {
                    libc::umask(0o777);
                }
                save_accounts(
                    &store_path,
                    &[
                        account("first@example.com", 10.0, 10.0, true),
                        account("second@example.com", 10.0, 10.0, false),
                    ],
                )?;
                let directory_mode = fs::metadata(store_path.parent().unwrap())?.mode() & 0o777;
                let store_mode = fs::metadata(&store_path)?.mode() & 0o777;
                let lock_mode =
                    fs::metadata(store_path.with_extension("json.lock"))?.mode() & 0o777;
                assert_eq!(directory_mode, ACCOUNT_STORE_DIRECTORY_MODE);
                assert_eq!(store_mode, ACCOUNT_STORE_FILE_MODE);
                assert_eq!(lock_mode, ACCOUNT_STORE_FILE_MODE);
            }
            other => bail!("unknown account-store child action {other}"),
        }
        Ok(())
    }

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
                allowed: Some(true),
                limit_reached: Some(false),
                fetched_at: Utc::now(),
                windows: vec![
                    window(QuotaWindowKind::FiveHour, five_used),
                    window(QuotaWindowKind::Weekly, weekly_used),
                ],
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
            resets_at: DateTime::<Utc>::from_timestamp(978_307_200, 0).unwrap(),
            source: QuotaWindowSourceMetadata::new(
                QuotaWindowRateLimitSource::Main,
                QuotaWindowSlot::Primary,
            ),
            hard_limit_reached: false,
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
            select_auto_swap_candidate(&accounts, Utc::now()).map(|account| account.email.as_str()),
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
            select_auto_swap_candidate(&accounts, Utc::now()).map(|account| account.email.as_str()),
            Some("ready@example.com")
        );
        assert_eq!(score(&accounts[1], Utc::now()), -1.0);
    }

    #[test]
    fn auto_swap_threshold_matches_displayed_one_percent() {
        let displayed_as_two_percent = window(QuotaWindowKind::FiveHour, 98.0);
        let displayed_as_one_percent = window(QuotaWindowKind::FiveHour, 98.01);

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
        assert!(score(&pro, Utc::now()) > score(&pro_lite, Utc::now()));
        assert!(score(&pro_lite, Utc::now()) > score(&plus, Utc::now()));
        assert!(score(&plus, Utc::now()) > score(&free, Utc::now()));
        assert_eq!(
            select_auto_swap_candidate(&[active, free, plus, pro_lite, pro], Utc::now())
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
        assert!(score(&pro, Utc::now()) > score(&plus, Utc::now()));
    }

    #[test]
    fn healthy_plus_selects_usable_pro_upgrade() {
        let active_plus = account_with_plan("active@example.com", 20.0, 20.0, true, "plus");
        let ready_plus = account_with_plan("ready-plus@example.com", 0.0, 0.0, false, "plus");
        let ready_pro = account_with_plan("ready-pro@example.com", 90.0, 70.0, false, "pro");
        let spent_pro = account_with_plan("spent-pro@example.com", 99.0, 0.0, false, "pro");

        assert_eq!(
            select_plan_upgrade_candidate(
                &[active_plus, ready_plus, ready_pro, spent_pro],
                Utc::now(),
            )
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
        snapshot.fetched_at = datetime_from_swift_value(&json!(fetched_at)).unwrap();
        snapshot.five_hour_mut().unwrap().resets_at = snapshot.fetched_at;
        snapshot.weekly_mut().unwrap().resets_at =
            datetime_from_swift_value(&json!(fetched_at + 604_800.0)).unwrap();
        let ready_plus = account_with_plan("ready-plus@example.com", 40.0, 40.0, false, "plus");

        assert!(placeholder
            .quota_snapshot
            .as_ref()
            .unwrap()
            .has_backend_usage_placeholder());
        assert_eq!(score(&placeholder, Utc::now()), -1.0);
        assert_eq!(
            quota_availability_at(&placeholder, Utc::now()),
            QuotaAvailability::Unknown
        );
        assert_eq!(
            select_auto_swap_candidate(&[active, placeholder, ready_plus], Utc::now())
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
        snapshot.fetched_at = datetime_from_swift_value(&json!(fetched_at)).unwrap();
        snapshot.five_hour_mut().unwrap().resets_at = snapshot.fetched_at;
        snapshot.weekly_mut().unwrap().resets_at =
            datetime_from_swift_value(&json!(fetched_at + 604_800.0)).unwrap();
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
            .five_hour_mut()
            .unwrap()
            .resets_at = datetime_from_swift_value(&json!(14_400.0)).unwrap();
        earlier_reset_slightly_less_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour_mut()
            .unwrap()
            .resets_at = datetime_from_swift_value(&json!(600.0)).unwrap();

        assert_eq!(
            select_auto_swap_candidate(
                &[
                    active,
                    later_reset_slightly_more_weekly,
                    earlier_reset_slightly_less_weekly,
                ],
                Utc::now(),
            )
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
            .five_hour_mut()
            .unwrap()
            .resets_at = datetime_from_swift_value(&json!(600.0)).unwrap();
        later_reset_high_weekly
            .quota_snapshot
            .as_mut()
            .unwrap()
            .five_hour_mut()
            .unwrap()
            .resets_at = datetime_from_swift_value(&json!(14_400.0)).unwrap();

        assert_eq!(
            select_auto_swap_candidate(
                &[active, earlier_reset_low_weekly, later_reset_high_weekly],
                Utc::now(),
            )
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

    #[test]
    fn account_store_lock_serializes_distinct_processes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let marker = dir.path().join("child-acquired-lock");
        let first_lock = lock_account_store(&store_path)?;
        let child = Command::new(std::env::current_exe()?)
            .args([
                "--exact",
                "account_store::tests::account_store_cross_process_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("CODEXSWITCH_ACCOUNT_STORE_CHILD_ACTION", "lock")
            .env("CODEXSWITCH_ACCOUNT_STORE_CHILD_PATH", &store_path)
            .env("CODEXSWITCH_ACCOUNT_STORE_CHILD_MARKER", &marker)
            .spawn()
            .context("failed to spawn account-store lock test child")?;

        std::thread::sleep(StdDuration::from_millis(150));
        assert!(
            !marker.exists(),
            "child acquired a lock held by another process"
        );
        drop(first_lock);

        let status = wait_for_test_child(child)?;
        assert!(status.success());
        assert_eq!(fs::read(&marker)?, b"locked");
        Ok(())
    }

    #[test]
    fn hostile_umask_cannot_weaken_store_lock_or_directory_modes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let secure_parent = dir.path().join("secure");
        fs::create_dir(&secure_parent)?;
        fs::set_permissions(&secure_parent, fs::Permissions::from_mode(0o700))?;
        let store_path = secure_parent.join("accounts.json");
        let child = Command::new(std::env::current_exe()?)
            .args([
                "--exact",
                "account_store::tests::account_store_cross_process_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("CODEXSWITCH_ACCOUNT_STORE_CHILD_ACTION", "hostile-umask")
            .env("CODEXSWITCH_ACCOUNT_STORE_CHILD_PATH", &store_path)
            .spawn()
            .context("failed to spawn hostile-umask test child")?;

        assert!(wait_for_test_child(child)?.success());
        assert_eq!(fs::metadata(&secure_parent)?.mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(&store_path)?.mode() & 0o777, 0o600);
        assert_eq!(
            fs::metadata(store_path.with_extension("json.lock"))?.mode() & 0o777,
            0o600
        );
        Ok(())
    }

    #[test]
    fn account_store_lock_rejects_symlink() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let outside = dir.path().join("outside.lock");
        fs::write(&outside, b"outside")?;
        symlink(&outside, store_path.with_extension("json.lock"))?;

        let error = match lock_account_store(&store_path) {
            Ok(_) => panic!("symlink lock unexpectedly opened"),
            Err(error) => error,
        };
        assert!(format!("{error:#}").contains("failed to open account store lock"));
        assert_eq!(fs::read(&outside)?, b"outside");
        Ok(())
    }

    #[test]
    fn account_store_rejects_user_owned_symlinked_parent() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let real_parent = dir.path().join("real-parent");
        fs::create_dir(&real_parent)?;
        let linked_parent = dir.path().join("linked-parent");
        symlink(&real_parent, &linked_parent)?;
        let store_path = linked_parent.join("nested/accounts.json");

        let error = match lock_account_store(&store_path) {
            Ok(_) => panic!("symlinked account store parent unexpectedly opened"),
            Err(error) => error,
        };

        assert!(format!("{error:#}").contains("without following symlinks"));
        assert!(!real_parent.join("nested").exists());
        Ok(())
    }

    #[test]
    fn account_store_descriptor_walk_rejects_component_swapped_to_symlink() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let anchor = dir.path().join("anchor");
        let swappable = anchor.join("swappable");
        let parked = anchor.join("parked");
        let outside = dir.path().join("outside");
        fs::create_dir_all(&swappable)?;
        fs::create_dir(&outside)?;
        let store_path = normalize_account_store_path(&swappable.join("accounts.json"))?;
        let mut swapped = false;

        let error = match open_account_store_directory_with(
            &store_path,
            false,
            |_opened_parent, component| {
                if !swapped && component == OsStr::new("swappable") {
                    fs::rename(&swappable, &parked)?;
                    symlink(&outside, &swappable)?;
                    swapped = true;
                }
                Ok(())
            },
        ) {
            Ok(_) => panic!("a swapped symlink component was followed"),
            Err(error) => error,
        };

        assert!(swapped);
        assert!(format!("{error:#}").contains("without following symlinks"));
        assert!(outside.read_dir()?.next().is_none());
        Ok(())
    }

    #[test]
    fn account_store_descriptor_walk_pins_opened_component_across_path_swap() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let anchor = dir.path().join("anchor");
        let swappable = anchor.join("swappable");
        let parked = anchor.join("parked");
        let outside = dir.path().join("outside");
        fs::create_dir_all(swappable.join("nested"))?;
        fs::create_dir_all(outside.join("nested"))?;
        fs::set_permissions(
            swappable.join("nested"),
            fs::Permissions::from_mode(ACCOUNT_STORE_DIRECTORY_MODE),
        )?;
        fs::write(swappable.join("nested/probe"), b"pinned")?;
        fs::write(outside.join("nested/probe"), b"redirected")?;
        let store_path = normalize_account_store_path(&swappable.join("nested/accounts.json"))?;
        let mut swapped = false;

        let directory =
            open_account_store_directory_with(&store_path, false, |_opened_parent, component| {
                if !swapped && component == OsStr::new("nested") {
                    fs::rename(&swappable, &parked)?;
                    symlink(&outside, &swappable)?;
                    swapped = true;
                }
                Ok(())
            })?;
        let mut probe = open_file_at(
            &directory.file,
            OsStr::new("probe"),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0,
        )?;
        let mut contents = String::new();
        probe.read_to_string(&mut contents)?;

        assert!(swapped);
        assert_eq!(contents, "pinned");
        Ok(())
    }

    #[test]
    fn account_store_read_rejects_final_store_symlink() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(
            dir.path(),
            fs::Permissions::from_mode(ACCOUNT_STORE_DIRECTORY_MODE),
        )?;
        let store_path = dir.path().join("accounts.json");
        let outside = dir.path().join("outside.json");
        fs::write(&outside, b"[]")?;
        symlink(&outside, &store_path)?;

        let error = load_accounts(&store_path).unwrap_err();

        assert!(
            format!("{error:#}").contains("failed to open"),
            "unexpected error: {error:#}"
        );
        assert_eq!(fs::read(&outside)?, b"[]");
        Ok(())
    }

    #[test]
    fn account_store_observation_does_not_create_a_lock_file() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(
            dir.path(),
            fs::Permissions::from_mode(ACCOUNT_STORE_DIRECTORY_MODE),
        )?;
        let store_path = dir.path().join("accounts.json");
        let accounts = vec![
            account("first@example.com", 10.0, 10.0, true),
            account("second@example.com", 20.0, 20.0, false),
        ];
        fs::write(&store_path, serde_json::to_vec(&accounts)?)?;
        fs::set_permissions(
            &store_path,
            fs::Permissions::from_mode(ACCOUNT_STORE_FILE_MODE),
        )?;

        assert_eq!(load_accounts(&store_path)?.len(), 2);
        assert!(!store_path.with_extension("json.lock").exists());
        Ok(())
    }

    #[test]
    fn account_store_write_rejects_final_temp_symlink() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = normalize_account_store_path(&dir.path().join("accounts.json"))?;
        let directory = open_account_store_directory(&store_path, true)?;
        let temporary_name = OsStr::new(".accounts.json.tmp-symlink-test");
        let temporary_path = directory.path.join(temporary_name);
        let outside = directory.path.join("outside.json");
        fs::write(&outside, b"outside")?;
        symlink(&outside, &temporary_path)?;

        let error = create_account_store_temp_file(&directory, temporary_name, &temporary_path)
            .unwrap_err();

        assert!(format!("{error:#}").contains("failed to create"));
        assert_eq!(fs::read(&outside)?, b"outside");
        Ok(())
    }

    #[test]
    fn account_store_lock_rejects_fifo() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        create_fifo(&store_path.with_extension("json.lock"))?;

        let error = match lock_account_store(&store_path) {
            Ok(_) => panic!("fifo account store lock unexpectedly opened"),
            Err(error) => error,
        };

        assert!(
            format!("{error:#}").contains("not a regular file"),
            "unexpected error: {error:#}"
        );
        Ok(())
    }

    #[test]
    fn account_store_read_rejects_fifo() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(
            dir.path(),
            fs::Permissions::from_mode(ACCOUNT_STORE_DIRECTORY_MODE),
        )?;
        let store_path = dir.path().join("accounts.json");
        create_fifo(&store_path)?;

        let error = load_accounts(&store_path).unwrap_err();

        assert!(format!("{error:#}").contains("not a regular file"));
        Ok(())
    }

    #[test]
    fn account_store_descriptor_rejects_wrong_expected_owner() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("accounts.json");
        let file = fs::File::create(path)?;
        let metadata = file.metadata()?;
        let wrong_uid = current_uid()
            .checked_add(1)
            .unwrap_or_else(|| current_uid() - 1);

        let error = validate_regular_file_metadata(&metadata, wrong_uid).unwrap_err();

        assert!(format!("{error:#}").contains("owned by uid"));
        Ok(())
    }

    #[test]
    fn account_store_read_rejects_broad_file_mode() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        save_accounts(
            &store_path,
            &[
                account("first@example.com", 10.0, 10.0, true),
                account("second@example.com", 10.0, 10.0, false),
            ],
        )?;
        fs::set_permissions(&store_path, fs::Permissions::from_mode(0o644))?;

        let error = load_accounts(&store_path).unwrap_err();
        assert!(format!("{error:#}").contains("mode 644"));
        Ok(())
    }

    #[test]
    fn renamed_store_must_reopen_as_the_created_inode() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = normalize_account_store_path(&dir.path().join("accounts.json"))?;
        let directory = open_account_store_directory(&store_path, true)?;
        let first_name = OsStr::new("first");
        let second_name = OsStr::new("second");
        let first_path = directory.path.join(first_name);
        let second_path = directory.path.join(second_name);
        let first = create_account_store_temp_file(&directory, first_name, &first_path)?;
        let second = create_account_store_temp_file(&directory, second_name, &second_path)?;
        let first_identity = descriptor_identity(&first, &first_path)?;
        let second_identity = descriptor_identity(&second, &second_path)?;

        assert_ne!(first_identity, second_identity);
        drop(first);
        drop(second);
        unlink_file_at(&directory.file, first_name)?;
        unlink_file_at(&directory.file, second_name)?;
        Ok(())
    }

    #[test]
    fn account_store_validation_requires_unique_identities_and_one_active() {
        let first = account("first@example.com", 10.0, 10.0, true);
        let mut second = account("second@example.com", 10.0, 10.0, false);

        let mut no_active = vec![first.clone(), second.clone()];
        no_active[0].is_active = false;
        assert!(validate_accounts(&no_active).is_err());

        let mut two_active = vec![first.clone(), second.clone()];
        two_active[1].is_active = true;
        assert!(validate_accounts(&two_active).is_err());

        second.id = first.id;
        assert!(validate_accounts(&[first.clone(), second.clone()]).is_err());
        assert!(activate_account(&mut [first.clone(), second], first.id).is_err());

        let mut duplicate_provider = account("other@example.com", 10.0, 10.0, false);
        duplicate_provider.account_id = first.account_id.clone();
        assert!(validate_accounts(&[first, duplicate_provider]).is_err());
    }

    #[test]
    fn commit_rejects_stale_generation_and_readback_proves_activation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store_path = dir.path().join("accounts.json");
        let mut accounts = vec![
            account("first@example.com", 10.0, 10.0, true),
            account("second@example.com", 10.0, 10.0, false),
        ];
        save_accounts(&store_path, &accounts)?;

        let store_lock = lock_account_store(&store_path)?;
        let stale = store_lock.load()?;
        accounts[0].email = "changed@example.com".to_string();
        fs::write(&store_path, serde_json::to_vec_pretty(&accounts)?)?;
        assert!(store_lock.commit(&stale.generation, &accounts).is_err());

        let current = store_lock.load()?;
        let target_id = current.accounts[1].id;
        let mut activated = current.accounts;
        activate_account(&mut activated, target_id)?;
        let committed = store_lock.commit(&current.generation, &activated)?;
        assert_eq!(
            active_account(&committed.accounts).map(|value| value.id),
            Some(target_id)
        );
        assert_ne!(committed.generation, current.generation);
        Ok(())
    }

    #[test]
    fn ambiguous_selector_cannot_activate_duplicate_email() {
        let accounts = vec![
            account("same@example.com", 10.0, 10.0, true),
            account("same@example.com", 10.0, 10.0, false),
        ];
        assert!(resolve_account_selector(&accounts, "same@example.com").is_err());
    }

    #[test]
    fn legacy_snapshot_fixture_reads_and_writes_explicit_v2() -> Result<()> {
        let snapshot: QuotaSnapshot = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Quota/snapshot-v1.json"
        ))?;

        assert_eq!(snapshot.allowed, None);
        assert_eq!(snapshot.limit_reached, None);
        assert_eq!(snapshot.windows.len(), 2);
        assert_eq!(
            snapshot.five_hour().unwrap().kind,
            QuotaWindowKind::FiveHour
        );
        assert_eq!(
            snapshot.five_hour().unwrap().source.rate_limit,
            QuotaWindowRateLimitSource::Legacy
        );
        assert_eq!(
            snapshot.weekly().unwrap().source.slot,
            QuotaWindowSlot::LegacyWeekly
        );

        let encoded = serde_json::to_value(&snapshot)?;
        assert_eq!(encoded["version"], QuotaSnapshot::CODING_VERSION);
        assert!(encoded.get("fiveHour").is_none());
        assert!(encoded.get("weekly").is_none());
        assert!(encoded["fetchedAt"].is_number());
        assert_eq!(encoded["windows"].as_array().unwrap().len(), 2);
        assert!(encoded["windows"][0].get("windowDurationMins").is_none());
        assert_eq!(serde_json::from_value::<QuotaSnapshot>(encoded)?, snapshot);
        Ok(())
    }

    #[test]
    fn shared_five_hour_only_policy_fixture_is_usable_without_weekly_fabrication() -> Result<()> {
        let fixture: Value = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Policy/five-hour-only.json"
        ))?;
        let snapshot: QuotaSnapshot = serde_json::from_value(fixture["snapshot"].clone())?;
        let now = datetime_from_swift_value(&fixture["now"]).unwrap();

        assert_eq!(snapshot.availability_at(now), QuotaAvailability::Usable);
        assert!(snapshot.weekly().is_none());
        assert_eq!(snapshot.five_hour().unwrap().remaining_percent(), 75.0);
        assert_eq!(snapshot.minimum_remaining_percent(), Some(75.0));
        assert_eq!(
            serde_json::to_value(&snapshot)?["windows"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        Ok(())
    }

    #[test]
    fn shared_candidate_order_fixture_keeps_pro_first() -> Result<()> {
        let fixture: Value = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Policy/candidate-order.json"
        ))?;
        let accounts: Vec<CodexAccount> = serde_json::from_value(fixture["accounts"].clone())?;
        validate_accounts(&accounts)?;
        let now = datetime_from_swift_value(&fixture["now"]).unwrap();
        let expected = fixture["expectedCandidateOrder"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .map(Uuid::parse_str)
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut candidates = accounts
            .iter()
            .filter(|account| !account.is_active)
            .filter(|account| quota_availability_at(account, now) == QuotaAvailability::Usable)
            .collect::<Vec<_>>();
        candidates.sort_by(|left, right| candidate_cmp(right, left, now));

        assert_eq!(
            candidates
                .iter()
                .map(|account| account.id)
                .collect::<Vec<_>>(),
            expected
        );
        assert_eq!(
            select_auto_swap_candidate(&accounts, now).map(|account| account.id),
            expected.first().copied()
        );
        Ok(())
    }

    #[test]
    fn v2_weekly_only_fixture_round_trips_without_five_hour_window() -> Result<()> {
        let snapshot: QuotaSnapshot = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Quota/snapshot-v2.json"
        ))?;

        assert_eq!(snapshot.allowed, Some(true));
        assert_eq!(snapshot.limit_reached, Some(false));
        assert_eq!(snapshot.windows.len(), 1);
        assert!(snapshot.five_hour().is_none());
        let weekly = snapshot.weekly().unwrap();
        assert_eq!(weekly.duration_seconds, 604_800);
        assert_eq!(
            weekly.source.rate_limit,
            QuotaWindowRateLimitSource::Additional
        );
        assert_eq!(weekly.source.slot, QuotaWindowSlot::Primary);
        assert_eq!(weekly.source.limit_name.as_deref(), Some("GPT-5.5"));
        assert_eq!(weekly.source.metered_feature.as_deref(), Some("codex"));

        let encoded = serde_json::to_value(&snapshot)?;
        assert_eq!(encoded["version"], 2);
        assert_eq!(encoded["windows"].as_array().unwrap().len(), 1);
        assert!(encoded["fetchedAt"].is_number());
        assert!(encoded["windows"][0]["resetsAt"].is_number());
        assert_eq!(serde_json::from_value::<QuotaSnapshot>(encoded)?, snapshot);
        Ok(())
    }

    #[test]
    fn v2_duration_classification_normalizes_contradictory_kinds() -> Result<()> {
        let snapshot: QuotaSnapshot = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Quota/snapshot-v2-kind-duration-mismatch.json"
        ))?;

        assert_eq!(snapshot.windows[0].kind, QuotaWindowKind::Weekly);
        assert_eq!(snapshot.windows[1].kind, QuotaWindowKind::FiveHour);
        assert_eq!(snapshot.windows[2].kind, QuotaWindowKind::Unknown);

        let encoded = serde_json::to_value(&snapshot)?;
        assert_eq!(encoded["windows"][0]["kind"], "weekly");
        assert_eq!(encoded["windows"][1]["kind"], "fiveHour");
        assert_eq!(encoded["windows"][2]["kind"], "unknown");
        Ok(())
    }

    #[test]
    fn stale_quota_is_unknown_and_current_rotation_observation_is_required() {
        let now = Utc::now();
        let active = account("active@example.com", 100.0, 100.0, true);
        let mut candidate = account("candidate@example.com", 20.0, 20.0, false);
        candidate.quota_snapshot.as_mut().unwrap().fetched_at = now - ChronoDuration::seconds(1);

        assert_eq!(
            quota_availability_at(&candidate, now),
            QuotaAvailability::Usable
        );
        let mut observations = CurrentQuotaObservations::new(now);
        assert!(!observations.record_success(&candidate));
        assert!(select_auto_swap_candidate_from_observations(
            &[active.clone(), candidate.clone()],
            &observations,
            now,
        )
        .is_none());

        candidate.quota_snapshot.as_mut().unwrap().fetched_at = now;
        assert!(observations.record_success(&candidate));
        assert_eq!(
            select_auto_swap_candidate_from_observations(&[active, candidate], &observations, now,)
                .map(|account| account.email.as_str()),
            Some("candidate@example.com")
        );

        let mut stale = account("stale@example.com", 20.0, 20.0, false);
        stale.quota_snapshot.as_mut().unwrap().fetched_at =
            now - QUOTA_OBSERVATION_MAX_AGE - ChronoDuration::milliseconds(1);
        assert_eq!(
            quota_availability_at(&stale, now),
            QuotaAvailability::Unknown
        );
        assert_eq!(score(&stale, now), -1.0);
    }

    #[test]
    fn quota_freshness_includes_exact_boundary_and_rejects_outside_it() {
        let now = Utc::now();
        let mut account = account("freshness@example.com", 20.0, 20.0, false);
        let snapshot = account.quota_snapshot.as_mut().unwrap();

        snapshot.fetched_at = now - QUOTA_OBSERVATION_MAX_AGE + ChronoDuration::milliseconds(1);
        assert!(snapshot.is_fresh_at(now));

        snapshot.fetched_at = now - QUOTA_OBSERVATION_MAX_AGE;
        assert!(snapshot.is_fresh_at(now));
        assert_eq!(snapshot.availability_at(now), QuotaAvailability::Usable);

        snapshot.fetched_at = now - QUOTA_OBSERVATION_MAX_AGE - ChronoDuration::milliseconds(1);
        assert!(!snapshot.is_fresh_at(now));
        assert_eq!(snapshot.availability_at(now), QuotaAvailability::Unknown);

        snapshot.fetched_at = now + ChronoDuration::milliseconds(1);
        assert!(!snapshot.is_fresh_at(now));
        assert_eq!(snapshot.availability_at(now), QuotaAvailability::Unknown);
    }

    #[test]
    fn weekly_only_policy_uses_only_the_present_window() {
        let mut healthy = account("healthy@example.com", 10.0, 30.0, false);
        healthy
            .quota_snapshot
            .as_mut()
            .unwrap()
            .windows
            .retain(|window| window.kind == QuotaWindowKind::Weekly);
        let snapshot = healthy.quota_snapshot.as_ref().unwrap();
        assert_eq!(snapshot.minimum_remaining_percent(), Some(70.0));
        assert!(snapshot.blocking_windows().is_empty());
        assert_eq!(
            snapshot.availability_at(Utc::now()),
            QuotaAvailability::Usable
        );
        assert_eq!(
            quota_availability_at(&healthy, Utc::now()),
            QuotaAvailability::Usable
        );
        assert!(score(&healthy, Utc::now()) > 0.0);

        healthy
            .quota_snapshot
            .as_mut()
            .unwrap()
            .weekly_mut()
            .unwrap()
            .used_percent = 100.0;
        let exhausted = healthy.quota_snapshot.as_ref().unwrap();
        assert_eq!(exhausted.minimum_remaining_percent(), Some(0.0));
        assert_eq!(
            exhausted.availability_at(Utc::now()),
            QuotaAvailability::Blocked
        );
        assert_eq!(
            quota_availability_at(&healthy, Utc::now()),
            QuotaAvailability::Blocked
        );

        let denied = healthy.quota_snapshot.as_mut().unwrap();
        denied.weekly_mut().unwrap().used_percent = 30.0;
        denied.allowed = Some(false);
        denied.limit_reached = Some(true);
        assert_eq!(
            denied.availability_at(Utc::now()),
            QuotaAvailability::Blocked
        );
    }

    #[test]
    fn unknown_only_snapshot_is_diagnostic_not_candidate_capacity() -> Result<()> {
        let active = account("active@example.com", 100.0, 100.0, true);
        let mut unknown = account_with_plan("unknown@example.com", 10.0, 10.0, false, "pro");
        unknown.quota_snapshot.as_mut().unwrap().windows =
            vec![window(QuotaWindowKind::Unknown, 100.0)];
        let ready = account("ready@example.com", 20.0, 20.0, false);

        let snapshot = unknown.quota_snapshot.as_ref().unwrap();
        assert_eq!(snapshot.ordered_windows().len(), 1);
        assert_eq!(snapshot.minimum_remaining_percent(), None);
        assert!(snapshot.blocking_windows().is_empty());
        assert!(!snapshot.windows[0].is_exhausted());
        assert!(!snapshot.windows[0].should_auto_swap_away());
        assert_eq!(
            snapshot.availability_at(Utc::now()),
            QuotaAvailability::Unknown
        );
        assert_eq!(
            quota_availability_at(&unknown, Utc::now()),
            QuotaAvailability::Unknown
        );
        assert_eq!(score(&unknown, Utc::now()), -1.0);
        assert_eq!(
            select_auto_swap_candidate(&[active, unknown.clone(), ready], Utc::now())
                .map(|account| account.email.as_str()),
            Some("ready@example.com")
        );

        let encoded = serde_json::to_value(snapshot)?;
        assert_eq!(encoded["windows"].as_array().unwrap().len(), 1);
        assert_eq!(encoded["windows"][0]["kind"], "unknown");
        Ok(())
    }

    #[test]
    fn incomplete_token_set_cannot_contribute_candidate_capacity() {
        let mut candidate = account("candidate@example.com", 10.0, 10.0, false);
        candidate.refresh_token.clear();

        assert_eq!(
            quota_availability_at(&candidate, Utc::now()),
            QuotaAvailability::Unknown
        );
        assert_eq!(score(&candidate, Utc::now()), -1.0);
    }

    #[test]
    fn stored_non_positive_duration_windows_are_removed_before_domain_and_v2_write() -> Result<()> {
        for fixture in [
            include_bytes!("../../../Tests/Fixtures/Quota/snapshot-v1-disabled.json").as_slice(),
            include_bytes!("../../../Tests/Fixtures/Quota/snapshot-v2-disabled.json").as_slice(),
        ] {
            let snapshot: QuotaSnapshot = serde_json::from_slice(fixture)?;
            assert_eq!(snapshot.windows.len(), 1);
            assert!(snapshot.five_hour().is_none());
            assert_eq!(snapshot.weekly().unwrap().duration_seconds, 604_800);
            assert_eq!(snapshot.minimum_remaining_percent(), Some(81.0));

            let encoded = serde_json::to_value(&snapshot)?;
            let windows = encoded["windows"].as_array().unwrap();
            assert_eq!(windows.len(), 1);
            assert_eq!(windows[0]["kind"], "weekly");
            assert!(windows
                .iter()
                .all(|window| window["durationSeconds"].as_i64().unwrap() > 0));
        }
        Ok(())
    }

    #[test]
    fn domain_and_v2_writer_ignore_in_memory_non_positive_duration_windows() -> Result<()> {
        let mut snapshot: QuotaSnapshot = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Quota/snapshot-v2.json"
        ))?;
        let mut disabled_five_hour = window(QuotaWindowKind::FiveHour, 0.0);
        disabled_five_hour.duration_seconds = 0;
        let mut disabled_unknown = window(QuotaWindowKind::Unknown, 99.0);
        disabled_unknown.duration_seconds = -60;
        snapshot
            .windows
            .extend([disabled_five_hour, disabled_unknown]);

        assert_eq!(snapshot.ordered_windows().len(), 1);
        assert!(snapshot.five_hour().is_none());
        assert_eq!(snapshot.minimum_remaining_percent(), Some(81.0));
        assert_eq!(
            snapshot.availability_at(snapshot.fetched_at),
            QuotaAvailability::Usable
        );

        let encoded = serde_json::to_value(&snapshot)?;
        assert_eq!(encoded["windows"].as_array().unwrap().len(), 1);
        assert_eq!(encoded["windows"][0]["kind"], "weekly");
        Ok(())
    }

    #[test]
    fn runtime_usage_limit_without_telemetry_fabricates_no_windows() {
        let mut blocked = account("blocked@example.com", 10.0, 10.0, false);
        blocked.quota_snapshot = None;

        mark_runtime_unusable(
            &mut blocked,
            "usage_limit",
            Utc::now() + chrono::Duration::hours(5),
        );

        let snapshot = blocked.quota_snapshot.as_ref().unwrap();
        assert!(snapshot.is_denied());
        assert!(snapshot.windows.is_empty());
        assert_eq!(
            snapshot.availability_at(Utc::now()),
            QuotaAvailability::Blocked
        );
    }

    #[test]
    fn runtime_unusable_until_decodes_and_encodes_swift_reference_seconds() -> Result<()> {
        let swift_reference_seconds = 803_847_791.0;
        let json = format!(
            r#"{{
              "id":"{}",
              "email":"blocked@example.com",
              "accessToken":"access",
              "refreshToken":"refresh",
              "idToken":"id",
              "accountId":"blocked@example.com",
              "runtimeUnusableUntil":{},
              "runtimeUnusableReason":"usage_limit",
              "isActive":false
            }}"#,
            Uuid::new_v4(),
            swift_reference_seconds
        );

        let account: CodexAccount = serde_json::from_str(&json)?;

        assert!(account.rate_limit_reset_bank.is_none());
        assert_eq!(
            account.runtime_unusable_until.unwrap().timestamp_millis() as f64 / 1000.0
                - UNIX_TO_SWIFT_REFERENCE_SECONDS as f64,
            swift_reference_seconds
        );
        let encoded = serde_json::to_value(&account)?;
        assert_eq!(
            encoded
                .get("runtimeUnusableUntil")
                .and_then(|value| value.as_f64()),
            Some(swift_reference_seconds)
        );
        Ok(())
    }
}

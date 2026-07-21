//! Banked-reset policy and durable redemption reconciliation.
//!
//! A consume request is journaled before I/O and is never retried. Only a
//! fresh inventory decrease plus a fresh usable quota snapshot can report a
//! reset as usable; every pending, uncertain, or consumed-but-unusable attempt
//! continues to suppress redemption across process restarts.

use crate::account_store::{
    quota_availability_at, real_quota_snapshot, AccountStoreGeneration, AccountStoreLock,
    CodexAccount, CurrentQuotaObservations, QuotaAvailability, QuotaWindowKind,
    QuotaWindowRateLimitSource, QuotaWindowSlot,
};
use crate::activation::acquire_provider_io_lease;
use crate::secure_file::{self, SecureFileGeneration, SecureFileLock};
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use ring::digest::{Context as DigestContext, SHA256};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

const RESET_CREDITS_URL: &str = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
const RESET_CONSUME_URL: &str =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";
const UNIX_TO_SWIFT_REFERENCE_SECONDS: f64 = 978_307_200.0;
pub const RESET_BANK_REFRESH_INTERVAL: ChronoDuration = ChronoDuration::minutes(1);
pub const RESET_RECONCILIATION_INTERVAL: ChronoDuration = ChronoDuration::minutes(2);
const EXPIRING_SOON_INTERVAL: ChronoDuration = ChronoDuration::hours(24);
const NATURAL_RESET_PROTECTION_INTERVAL: ChronoDuration = ChronoDuration::hours(24);
const RESET_ATTEMPT_JOURNAL_VERSION: u32 = 3;
const RESET_ATTEMPT_JOURNAL_VERSION_1: u32 = 1;
const RESET_ATTEMPT_JOURNAL_VERSION_2: u32 = 2;
const RESET_TERMINAL_RETENTION: ChronoDuration = ChronoDuration::days(30);
const RESET_TERMINAL_ENTRY_CAP: usize = 64;
const RESET_UNRESOLVED_ENTRY_CAP: usize = 128;
const RESET_ERROR_DETAIL_MAX_BYTES: usize = 2_048;
const RESET_ATTEMPT_JOURNAL_MAX_BYTES: usize = 256 * 1_024;
const RESET_GENERATION_MAX_BYTES: usize = 128;
const RESET_IDENTIFIER_MAX_BYTES: usize = 512;
const RESET_MANUAL_REVIEW_REASON_MAX_BYTES: usize = 2_048;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitResetBank {
    pub available_count: u32,
    pub total_earned_count: u32,
    pub credits: Vec<RateLimitResetCredit>,
    #[serde(
        deserialize_with = "deserialize_swift_datetime",
        serialize_with = "serialize_swift_datetime"
    )]
    pub fetched_at: DateTime<Utc>,
}

impl RateLimitResetBank {
    fn structurally_valid_available_credits(
        &self,
        now: DateTime<Utc>,
    ) -> Option<Vec<&RateLimitResetCredit>> {
        if self.available_count > self.total_earned_count {
            return None;
        }

        let mut identifiers = std::collections::HashSet::new();
        let mut available = Vec::new();
        for credit in &self.credits {
            let provider_marks_available =
                credit.status.eq_ignore_ascii_case("available") && credit.redeemed_at.is_none();
            if !provider_marks_available {
                continue;
            }
            let Some(identifier) = credit.normalized_id() else {
                return None;
            };
            if identifier.len() > RESET_IDENTIFIER_MAX_BYTES
                || !credit.is_available(now)
                || !identifiers.insert(identifier)
            {
                return None;
            }
            available.push(credit);
        }
        if available.len() != self.available_count as usize {
            return None;
        }
        available.sort_by(|left, right| match (left.expires_at, right.expires_at) {
            (Some(left_expiration), Some(right_expiration)) => left_expiration
                .cmp(&right_expiration)
                .then_with(|| left.id.cmp(&right.id)),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => left.id.cmp(&right.id),
        });
        Some(available)
    }

    pub fn oldest_expiring_available_credit(
        &self,
        now: DateTime<Utc>,
    ) -> Option<&RateLimitResetCredit> {
        self.structurally_valid_available_credits(now)?
            .into_iter()
            .next()
    }

    pub fn has_available_reset(&self, now: DateTime<Utc>) -> bool {
        self.available_count > 0 && self.oldest_expiring_available_credit(now).is_some()
    }

    pub fn is_stale(&self, now: DateTime<Utc>) -> bool {
        let age = now.signed_duration_since(self.fetched_at);
        age < ChronoDuration::zero() || age >= RESET_BANK_REFRESH_INTERVAL
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateLimitResetCredit {
    pub id: String,
    #[serde(default)]
    pub reset_type: Option<String>,
    pub status: String,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_swift_datetime",
        serialize_with = "serialize_optional_swift_datetime"
    )]
    pub granted_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_swift_datetime",
        serialize_with = "serialize_optional_swift_datetime"
    )]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_swift_datetime",
        serialize_with = "serialize_optional_swift_datetime"
    )]
    pub redeem_started_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_swift_datetime",
        serialize_with = "serialize_optional_swift_datetime"
    )]
    pub redeemed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
}

impl RateLimitResetCredit {
    fn normalized_id(&self) -> Option<&str> {
        let identifier = self.id.trim();
        (!identifier.is_empty()).then_some(identifier)
    }

    fn is_available(&self, now: DateTime<Utc>) -> bool {
        self.normalized_id().is_some()
            && self.status.eq_ignore_ascii_case("available")
            && self.redeemed_at.is_none()
            && self.expires_at.is_some_and(|expires_at| expires_at > now)
    }

    fn has_terminal_consumption_status(&self) -> bool {
        self.redeemed_at.is_some()
            || matches!(
                self.status.trim().to_ascii_lowercase().as_str(),
                "redeemed" | "consumed" | "used"
            )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SmartResetReason {
    WeeklyExhausted,
    NoImmediatelyUsableAccount,
    ExpiringSoon,
    RuntimeUsageLimitNoReplacement,
    PreserveFasterTier,
}

impl SmartResetReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WeeklyExhausted => "weekly_exhausted",
            Self::NoImmediatelyUsableAccount => "no_immediately_usable_account",
            Self::ExpiringSoon => "expiring_soon",
            Self::RuntimeUsageLimitNoReplacement => "runtime_usage_limit_no_replacement",
            Self::PreserveFasterTier => "preserve_faster_tier",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SmartResetCandidate {
    pub(crate) account_index: usize,
    pub(crate) reason: SmartResetReason,
}

pub(crate) fn select_smart_reset_candidate(
    accounts: &[CodexAccount],
    active_index: usize,
    direct_runtime_usage_limit: bool,
    now: DateTime<Utc>,
    observations: Option<&CurrentQuotaObservations>,
) -> Option<SmartResetCandidate> {
    accounts
        .iter()
        .enumerate()
        .filter_map(|(account_index, account)| {
            let bank = account.rate_limit_reset_bank.as_ref()?;
            let runtime_usage_limit = (account_index == active_index && direct_runtime_usage_limit)
                || (account.runtime_unusable_at(now) && account.runtime_block_is_usage_limit());
            let reason = smart_reset_reason_with_observations(
                account,
                accounts,
                bank,
                runtime_usage_limit,
                now,
                observations,
            )?;
            Some(SmartResetCandidate {
                account_index,
                reason,
            })
        })
        .min_by(|left, right| {
            let left_account = &accounts[left.account_index];
            let right_account = &accounts[right.account_index];
            right_account
                .plan_priority()
                .cmp(&left_account.plan_priority())
                .then_with(|| {
                    let left_expiration = left_account
                        .rate_limit_reset_bank
                        .as_ref()
                        .and_then(|bank| bank.oldest_expiring_available_credit(now))
                        .and_then(|credit| credit.expires_at);
                    let right_expiration = right_account
                        .rate_limit_reset_bank
                        .as_ref()
                        .and_then(|bank| bank.oldest_expiring_available_credit(now))
                        .and_then(|credit| credit.expires_at);
                    match (left_expiration, right_expiration) {
                        (Some(left), Some(right)) => left.cmp(&right),
                        (Some(_), None) => std::cmp::Ordering::Less,
                        (None, Some(_)) => std::cmp::Ordering::Greater,
                        (None, None) => std::cmp::Ordering::Equal,
                    }
                })
                .then_with(|| {
                    left_account
                        .email
                        .to_ascii_lowercase()
                        .cmp(&right_account.email.to_ascii_lowercase())
                })
                .then_with(|| left_account.account_id.cmp(&right_account.account_id))
                .then_with(|| left_account.id.as_bytes().cmp(right_account.id.as_bytes()))
        })
}

#[cfg(test)]
fn smart_reset_reason(
    candidate: &CodexAccount,
    accounts: &[CodexAccount],
    bank: &RateLimitResetBank,
    direct_runtime_usage_limit: bool,
    now: DateTime<Utc>,
) -> Option<SmartResetReason> {
    smart_reset_reason_with_observations(
        candidate,
        accounts,
        bank,
        direct_runtime_usage_limit,
        now,
        None,
    )
}

fn smart_reset_reason_with_observations(
    candidate: &CodexAccount,
    accounts: &[CodexAccount],
    bank: &RateLimitResetBank,
    direct_runtime_usage_limit: bool,
    now: DateTime<Utc>,
    observations: Option<&CurrentQuotaObservations>,
) -> Option<SmartResetReason> {
    if bank.is_stale(now) || !bank.has_available_reset(now) {
        return None;
    }

    let ready_replacements = accounts
        .iter()
        .filter(|account| {
            account.id != candidate.id
                && observations
                    .is_none_or(|observations| account.is_active || observations.contains(account))
                && quota_availability_at(account, now) == QuotaAvailability::Usable
        })
        .collect::<Vec<_>>();
    let ready_replacement_exists = !ready_replacements.is_empty();
    let same_or_higher_tier_replacement_exists = ready_replacements
        .iter()
        .any(|account| account.plan_priority() >= candidate.plan_priority());
    let snapshot = real_quota_snapshot(candidate)?;
    let quota_availability = quota_availability_at(candidate, now);
    if quota_availability == QuotaAvailability::Unknown
        || snapshot.has_expired_exhausted_window(now)
        || (snapshot.five_hour().is_none() && snapshot.weekly().is_none())
    {
        return None;
    }
    let quota_blocked = quota_availability == QuotaAvailability::Blocked;
    let weekly_at_threshold = snapshot
        .weekly()
        .map(|window| snapshot.is_denied() || window.should_auto_swap_away())
        .unwrap_or(false);
    let exhausted_window =
        snapshot.is_denied() || snapshot.windows.iter().any(|window| window.is_exhausted());

    let expires_soon = bank
        .oldest_expiring_available_credit(now)
        .and_then(|credit| credit.expires_at)
        .map(|expires_at| expires_at <= now + EXPIRING_SOON_INTERVAL)
        .unwrap_or(false);

    // Using another account in the same or a higher tier preserves both the
    // current inference tier and the banked reset.
    if same_or_higher_tier_replacement_exists {
        return None;
    }

    // A banked reset does not move the scheduled natural reset. Preserve it
    // when another account can carry traffic through a near-term recovery.
    if ready_replacement_exists
        && blocking_natural_reset_at(candidate, now)
            .is_some_and(|reset_at| reset_at <= now + NATURAL_RESET_PROTECTION_INTERVAL)
    {
        return None;
    }

    if exhausted_window && expires_soon {
        return Some(SmartResetReason::ExpiringSoon);
    }

    // A higher-tier account may spend its own reset before falling to a lower
    // tier, provided the natural reset is not close enough to protect.
    if ready_replacement_exists && (quota_blocked || direct_runtime_usage_limit) {
        return Some(SmartResetReason::PreserveFasterTier);
    }

    if direct_runtime_usage_limit && !ready_replacement_exists {
        return Some(SmartResetReason::RuntimeUsageLimitNoReplacement);
    }
    if weekly_at_threshold && !ready_replacement_exists {
        return Some(SmartResetReason::WeeklyExhausted);
    }
    if quota_blocked && !ready_replacement_exists {
        return Some(SmartResetReason::NoImmediatelyUsableAccount);
    }

    None
}

fn blocking_natural_reset_at(active: &CodexAccount, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let snapshot = real_quota_snapshot(active)?;
    snapshot
        .next_recovery_at()
        .filter(|reset_at| *reset_at > now)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsumeCode {
    Reset,
    AlreadyRedeemed,
    NoCredit,
    NothingToReset,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsumeResult {
    pub code: ConsumeCode,
    pub credit_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetFlowState {
    NoAttempt,
    Suppressed,
    TerminalNotApplied,
    ReconciledUsable,
}

#[derive(Debug, Clone)]
pub struct ResetFlowResult {
    pub state: ResetFlowState,
    pub consumption_observed: bool,
    pub quota_reconciled: bool,
    pub detail: Option<String>,
}

impl ResetFlowResult {
    pub fn is_usable_success(&self) -> bool {
        self.state == ResetFlowState::ReconciledUsable
            && self.consumption_observed
            && self.quota_reconciled
    }

    pub fn suppresses_redemption(&self) -> bool {
        self.state == ResetFlowState::Suppressed
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ResetAttemptOrigin {
    LocalRequest,
    ExternalInventoryDecrease,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ResetAttemptState {
    Prepared,
    Uncertain,
    ConsumptionObserved,
    ReconciliationOverdue,
    TerminalNotApplied,
    ReconciledUsable,
}

impl ResetAttemptState {
    fn suppresses_redemption(self) -> bool {
        !self.is_terminal()
    }

    fn is_terminal(self) -> bool {
        matches!(self, Self::TerminalNotApplied | Self::ReconciledUsable)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetAttempt {
    account_id: String,
    local_account_id: Uuid,
    #[serde(default)]
    stable_owner: Option<String>,
    selected_credit_id: Option<String>,
    #[serde(default)]
    selected_credit_expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pre_available_credit_ids: Vec<String>,
    request_id: Uuid,
    pre_inventory_generation: String,
    #[serde(default)]
    starting_quota_generation: Option<String>,
    pre_inventory_count: u32,
    #[serde(default)]
    pre_inventory_fetched_at: Option<DateTime<Utc>>,
    started_at: DateTime<Utc>,
    #[serde(default)]
    submitted_at: Option<DateTime<Utc>>,
    state: ResetAttemptState,
    reconciliation_deadline: DateTime<Utc>,
    origin: ResetAttemptOrigin,
    #[serde(default)]
    response_code: Option<ConsumeCode>,
    #[serde(default)]
    last_inventory_generation: Option<String>,
    #[serde(default)]
    last_quota_generation: Option<String>,
    #[serde(default)]
    last_inventory_count: Option<u32>,
    #[serde(default)]
    quota_reconciled_at: Option<DateTime<Utc>>,
    #[serde(default)]
    quota_usable: Option<bool>,
    #[serde(default)]
    last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetManualReviewSentinel {
    first_compacted_at: DateTime<Utc>,
    last_compacted_at: DateTime<Utc>,
    compacted_attempt_count: u64,
    reason: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetAttemptJournal {
    version: u32,
    attempts: Vec<ResetAttempt>,
    #[serde(default)]
    manual_review: Option<ResetManualReviewSentinel>,
}

impl Default for ResetAttemptJournal {
    fn default() -> Self {
        Self {
            version: RESET_ATTEMPT_JOURNAL_VERSION,
            attempts: Vec::new(),
            manual_review: None,
        }
    }
}

pub fn reset_attempt_journal_path(store_path: &Path) -> PathBuf {
    store_path.with_extension("reset-attempts.json")
}

struct ResetJournalTransaction {
    file: SecureFileLock,
    generation: SecureFileGeneration,
    path: PathBuf,
}

impl ResetJournalTransaction {
    fn open(path: &Path, now: DateTime<Utc>) -> Result<(Self, ResetAttemptJournal)> {
        let file = secure_file::lock(path, true)?;
        let snapshot = match file.load(RESET_ATTEMPT_JOURNAL_MAX_BYTES, true) {
            Ok(snapshot) => snapshot,
            Err(load_error) => {
                let Some(oversized) = file.inspect_oversized(RESET_ATTEMPT_JOURNAL_MAX_BYTES)?
                else {
                    return Err(load_error);
                };
                let mut journal = oversized_reset_journal(oversized.length(), now);
                let data = prepare_reset_attempt_journal_write(&mut journal, now)?;
                let snapshot = file
                    .replace_oversized(&oversized, &data, RESET_ATTEMPT_JOURNAL_MAX_BYTES)
                    .context(
                        "oversized reset journal changed before its manual-review replacement",
                    )?;
                let transaction = Self {
                    file,
                    generation: snapshot.generation().clone(),
                    path: path.to_path_buf(),
                };
                return Ok((transaction, journal));
            }
        };
        let generation = snapshot.generation().clone();
        let (mut journal, requires_write) =
            decode_reset_attempt_journal(snapshot.bytes(), path, now)?;
        let mut transaction = Self {
            file,
            generation,
            path: path.to_path_buf(),
        };
        if requires_write {
            transaction.save(&mut journal, now)?;
        }
        Ok((transaction, journal))
    }

    fn save(&mut self, journal: &mut ResetAttemptJournal, now: DateTime<Utc>) -> Result<()> {
        let data = prepare_reset_attempt_journal_write(journal, now)?;
        match self
            .file
            .commit(&self.generation, &data, RESET_ATTEMPT_JOURNAL_MAX_BYTES)
        {
            Ok(snapshot) => {
                self.generation = snapshot.generation().clone();
                Ok(())
            }
            Err(error) => self.fail_closed_after_generation_loss(error, now),
        }
    }

    #[cfg(test)]
    fn save_with_test_hook<F>(
        &mut self,
        journal: &mut ResetAttemptJournal,
        now: DateTime<Utc>,
        before_final_compare: F,
    ) -> Result<()>
    where
        F: FnOnce() -> Result<()>,
    {
        let data = prepare_reset_attempt_journal_write(journal, now)?;
        match self.file.commit_with_test_hook(
            &self.generation,
            &data,
            RESET_ATTEMPT_JOURNAL_MAX_BYTES,
            before_final_compare,
        ) {
            Ok(snapshot) => {
                self.generation = snapshot.generation().clone();
                Ok(())
            }
            Err(error) => self.fail_closed_after_generation_loss(error, now),
        }
    }

    fn fail_closed_after_generation_loss(
        &mut self,
        original_error: anyhow::Error,
        now: DateTime<Utc>,
    ) -> Result<()> {
        let latest = match self.file.load(RESET_ATTEMPT_JOURNAL_MAX_BYTES, true) {
            Ok(latest) => latest,
            Err(load_error) => {
                let Some(oversized) = self
                    .file
                    .inspect_oversized(RESET_ATTEMPT_JOURNAL_MAX_BYTES)?
                else {
                    return Err(original_error.context(format!(
                        "reset journal commit failed and current state could not be inspected: {load_error:#}"
                    )));
                };
                let mut sentinel = oversized_reset_journal(oversized.length(), now);
                mark_reset_journal_manual_review(
                    &mut sentinel,
                    now,
                    0,
                    "reset journal generation changed during a secure transaction; manual review is required",
                );
                let data = prepare_reset_attempt_journal_write(&mut sentinel, now)?;
                let persisted = self.file.replace_oversized(
                    &oversized,
                    &data,
                    RESET_ATTEMPT_JOURNAL_MAX_BYTES,
                )?;
                self.generation = persisted.generation().clone();
                bail!(
                    "reset journal generation changed; a durable manual-review sentinel was persisted: {original_error:#}"
                );
            }
        };
        if latest.generation() == &self.generation {
            return Err(original_error);
        }

        let mut latest_journal = decode_reset_attempt_journal(latest.bytes(), &self.path, now)
            .map(|(journal, _)| journal)
            .unwrap_or_default();
        mark_reset_journal_manual_review(
            &mut latest_journal,
            now,
            0,
            "reset journal generation changed during a secure transaction; concurrent state was preserved and manual review is required",
        );
        let data = prepare_reset_attempt_journal_write(&mut latest_journal, now)?;
        let persisted =
            self.file
                .commit(latest.generation(), &data, RESET_ATTEMPT_JOURNAL_MAX_BYTES)?;
        self.generation = persisted.generation().clone();
        bail!(
            "reset journal generation changed; a durable manual-review sentinel was persisted: {original_error:#}"
        )
    }
}

enum ResetPreparation {
    Suppressed(String),
    NoAttempt,
    Reconcile(ResetAttempt),
    Submit {
        attempt: ResetAttempt,
        bank: RateLimitResetBank,
    },
}

fn with_account_store_unlocked<T, F>(
    store_lock: &AccountStoreLock,
    expected_generation: &AccountStoreGeneration,
    operation: F,
) -> Result<T>
where
    F: FnOnce() -> T,
{
    let result = store_lock.with_lock_released(|| Ok(operation()))?;
    let current_generation = store_lock.load()?.generation;
    if &current_generation != expected_generation {
        bail!(
            "account store changed during reset provider I/O; preserving the durable reset journal for recovery (expected {}, found {})",
            expected_generation.as_str(),
            current_generation.as_str()
        );
    }
    Ok(result)
}

fn validate_reset_provider_io<V>(
    store_lock: &AccountStoreLock,
    expected_generation: &AccountStoreGeneration,
    validate_provider_io: &mut V,
) -> Result<()>
where
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    let current_generation = store_lock.load()?.generation;
    if &current_generation != expected_generation {
        bail!(
            "account store changed before reset provider I/O (expected {}, found {})",
            expected_generation.as_str(),
            current_generation.as_str()
        );
    }
    validate_provider_io(store_lock)
}

fn open_exact_reset_attempt(
    path: &Path,
    expected: &ResetAttempt,
    now: DateTime<Utc>,
) -> Result<(ResetJournalTransaction, ResetAttemptJournal, usize)> {
    let (mut transaction, mut journal) = ResetJournalTransaction::open(path, now)?;
    if let Some(manual_review) = journal.manual_review.as_ref() {
        bail!(
            "reset journal entered manual review during provider I/O: {}",
            manual_review.reason
        );
    }
    let attempt_index = journal
        .attempts
        .iter()
        .position(|attempt| attempt.request_id == expected.request_id);
    if let Some(attempt_index) = attempt_index {
        if journal.attempts.get(attempt_index) == Some(expected) {
            return Ok((transaction, journal, attempt_index));
        }
    }

    mark_reset_journal_manual_review(
        &mut journal,
        now,
        0,
        "reset attempt changed during unlocked provider I/O; concurrent state was preserved and manual review is required",
    );
    transaction.save(&mut journal, now)?;
    bail!(
        "reset attempt {} changed during unlocked provider I/O; concurrent state was preserved",
        expected.request_id
    )
}

fn revalidate_exact_reset_attempt(
    path: &Path,
    expected: &ResetAttempt,
    now: DateTime<Utc>,
) -> Result<()> {
    let (_transaction, _journal, _attempt_index) = open_exact_reset_attempt(path, expected, now)?;
    Ok(())
}

fn update_exact_reset_attempt<F>(
    path: &Path,
    expected: &ResetAttempt,
    now: DateTime<Utc>,
    update: F,
) -> Result<ResetAttempt>
where
    F: FnOnce(&mut ResetAttemptJournal, usize),
{
    let (mut transaction, mut journal, attempt_index) =
        open_exact_reset_attempt(path, expected, now)?;
    update(&mut journal, attempt_index);
    transaction.save(&mut journal, now)?;
    Ok(journal.attempts[attempt_index].clone())
}

pub struct ResetReconciliationContext<'a> {
    pub store_lock: &'a AccountStoreLock,
    pub account: &'a mut CodexAccount,
    pub previous_bank: Option<&'a RateLimitResetBank>,
    pub observed_bank: RateLimitResetBank,
    pub attempt_reset: bool,
    pub now: DateTime<Utc>,
}

pub struct ResetReconciliationDependencies<B, Q, C> {
    pub fetch_bank: B,
    pub refresh_quota: Q,
    pub consume: C,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetQuotaRefreshStrategy {
    Direct,
    RefreshExpiredToken,
}

pub struct ResetOrchestrationContext<'a> {
    pub store_lock: &'a AccountStoreLock,
    pub accounts: &'a mut [CodexAccount],
    pub active_index: usize,
    pub candidate_observations: Option<&'a CurrentQuotaObservations>,
    pub allow_reset: bool,
    pub direct_runtime_usage_limit: bool,
    pub refresh_strategy: ResetQuotaRefreshStrategy,
    pub now: DateTime<Utc>,
}

pub struct ResetOrchestrationDependencies<B, Q, C, S> {
    pub fetch_bank: B,
    pub refresh_quota: Q,
    pub consume: C,
    pub on_reconciled_usable: S,
}

impl<B, Q, C, S> ResetOrchestrationDependencies<B, Q, C, S> {
    pub fn new(fetch_bank: B, refresh_quota: Q, consume: C, on_reconciled_usable: S) -> Self {
        Self {
            fetch_bank,
            refresh_quota,
            consume,
            on_reconciled_usable,
        }
    }
}

pub struct ResetOrchestrationResult<O> {
    pub account_index: usize,
    pub reason: Option<SmartResetReason>,
    pub flow: ResetFlowResult,
    pub completion: Option<O>,
}

pub fn orchestrate_reset_with_provider_guard<B, Q, C, S, O, V>(
    context: ResetOrchestrationContext<'_>,
    dependencies: ResetOrchestrationDependencies<B, Q, C, S>,
    validate_provider_io: V,
) -> Result<ResetOrchestrationResult<O>>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount, ResetQuotaRefreshStrategy) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    S: FnMut(&mut [CodexAccount], usize) -> Result<O>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    orchestrate_reset_with_scope(context, dependencies, false, None, validate_provider_io)
}

pub fn orchestrate_pool_reset_with_selection_and_provider_guard<B, Q, C, S, O, V>(
    context: ResetOrchestrationContext<'_>,
    dependencies: ResetOrchestrationDependencies<B, Q, C, S>,
    selection_accounts: &[CodexAccount],
    validate_provider_io: V,
) -> Result<ResetOrchestrationResult<O>>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount, ResetQuotaRefreshStrategy) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    S: FnMut(&mut [CodexAccount], usize) -> Result<O>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    if context.accounts.len() != selection_accounts.len()
        || context
            .accounts
            .iter()
            .zip(selection_accounts)
            .any(|(persisted, observed)| persisted.id != observed.id)
    {
        bail!("reset-selection observations do not match the persisted account order");
    }
    orchestrate_reset_with_scope(
        context,
        dependencies,
        true,
        Some(selection_accounts),
        validate_provider_io,
    )
}

fn orchestrate_reset_with_scope<B, Q, C, S, O, V>(
    context: ResetOrchestrationContext<'_>,
    dependencies: ResetOrchestrationDependencies<B, Q, C, S>,
    pool_wide: bool,
    selection_accounts: Option<&[CodexAccount]>,
    mut validate_provider_io: V,
) -> Result<ResetOrchestrationResult<O>>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount, ResetQuotaRefreshStrategy) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    S: FnMut(&mut [CodexAccount], usize) -> Result<O>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    let reset_account_index = if pool_wide && context.allow_reset {
        let candidate_accounts = selection_accounts.unwrap_or(&*context.accounts);
        select_smart_reset_candidate(
            candidate_accounts,
            context.active_index,
            context.direct_runtime_usage_limit,
            context.now,
            context.candidate_observations,
        )
        .map(|candidate| candidate.account_index)
        .unwrap_or(context.active_index)
    } else {
        context.active_index
    };
    let prefetched_observed_bank = if pool_wide && context.allow_reset {
        selection_accounts
            .and_then(|accounts| accounts[reset_account_index].rate_limit_reset_bank.clone())
            .filter(|bank| !bank.is_stale(context.now))
    } else {
        None
    };
    let ResetOrchestrationContext {
        store_lock,
        accounts,
        active_index,
        candidate_observations,
        allow_reset,
        direct_runtime_usage_limit,
        refresh_strategy,
        now,
    } = context;
    let ResetOrchestrationDependencies {
        mut fetch_bank,
        mut refresh_quota,
        mut consume,
        mut on_reconciled_usable,
    } = dependencies;
    let expected_store_generation = store_lock.load()?.generation;

    let previous_bank = accounts[reset_account_index].rate_limit_reset_bank.clone();
    let observed_bank = match prefetched_observed_bank {
        Some(bank) => bank,
        None => {
            validate_reset_provider_io(
                store_lock,
                &expected_store_generation,
                &mut validate_provider_io,
            )
            .context("reset activation guard changed before reset-bank refresh")?;
            with_account_store_unlocked(store_lock, &expected_store_generation, || {
                fetch_bank(&accounts[reset_account_index])
            })??
        }
    };
    let decision_now = std::cmp::max(now, observed_bank.fetched_at);
    let reset_account_runtime_usage_limit = (reset_account_index == active_index
        && direct_runtime_usage_limit)
        || (accounts[reset_account_index].runtime_unusable_at(decision_now)
            && accounts[reset_account_index].runtime_block_is_usage_limit());
    let reason = allow_reset.then(|| {
        smart_reset_reason_with_observations(
            &accounts[reset_account_index],
            accounts,
            &observed_bank,
            reset_account_runtime_usage_limit,
            decision_now,
            candidate_observations,
        )
    });
    let reason = reason.flatten();
    let flow = reconcile_or_attempt_reset_with_provider_guard(
        ResetReconciliationContext {
            store_lock,
            account: &mut accounts[reset_account_index],
            previous_bank: previous_bank.as_ref(),
            observed_bank,
            attempt_reset: reason.is_some(),
            now: decision_now,
        },
        ResetReconciliationDependencies::new(
            &mut fetch_bank,
            |account| refresh_quota(account, refresh_strategy),
            &mut consume,
        ),
        &mut validate_provider_io,
    )?;

    let completion = if flow.is_usable_success() {
        validate_reset_provider_io(
            store_lock,
            &expected_store_generation,
            &mut validate_provider_io,
        )
        .context("reset activation guard changed before completion commit")?;
        accounts[reset_account_index].runtime_unusable_until = None;
        accounts[reset_account_index].runtime_unusable_reason = None;
        Some(on_reconciled_usable(accounts, reset_account_index)?)
    } else {
        None
    };

    Ok(ResetOrchestrationResult {
        account_index: reset_account_index,
        reason,
        flow,
        completion,
    })
}

impl<B, Q, C> ResetReconciliationDependencies<B, Q, C>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
{
    pub fn new(fetch_bank: B, refresh_quota: Q, consume: C) -> Self {
        Self {
            fetch_bank,
            refresh_quota,
            consume,
        }
    }
}

#[cfg(test)]
pub fn reconcile_or_attempt_reset<B, Q, C>(
    context: ResetReconciliationContext<'_>,
    dependencies: ResetReconciliationDependencies<B, Q, C>,
) -> Result<ResetFlowResult>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
{
    reconcile_or_attempt_reset_with_provider_guard(context, dependencies, |_| Ok(()))
}

pub fn reconcile_or_attempt_reset_with_provider_guard<B, Q, C, V>(
    context: ResetReconciliationContext<'_>,
    dependencies: ResetReconciliationDependencies<B, Q, C>,
    mut validate_provider_io: V,
) -> Result<ResetFlowResult>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    let ResetReconciliationContext {
        store_lock,
        account,
        previous_bank,
        observed_bank,
        attempt_reset,
        now,
    } = context;
    let expected_store_generation = store_lock.load()?.generation;
    let previous_bank = previous_bank.cloned();
    let mut working_account = account.clone();
    let flow = reconcile_or_attempt_reset_inner(
        store_lock,
        &expected_store_generation,
        &mut working_account,
        previous_bank,
        observed_bank,
        attempt_reset,
        now,
        dependencies,
        &mut validate_provider_io,
    )?;
    *account = working_account;
    Ok(flow)
}

#[allow(clippy::too_many_arguments)]
fn reconcile_or_attempt_reset_inner<B, Q, C, V>(
    store_lock: &AccountStoreLock,
    expected_store_generation: &AccountStoreGeneration,
    account: &mut CodexAccount,
    previous_bank: Option<RateLimitResetBank>,
    observed_bank: RateLimitResetBank,
    attempt_reset: bool,
    now: DateTime<Utc>,
    dependencies: ResetReconciliationDependencies<B, Q, C>,
    validate_provider_io: &mut V,
) -> Result<ResetFlowResult>
where
    B: FnMut(&CodexAccount) -> Result<RateLimitResetBank>,
    Q: FnMut(&mut CodexAccount) -> Result<()>,
    C: FnMut(&CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    let ResetReconciliationDependencies {
        mut fetch_bank,
        mut refresh_quota,
        mut consume,
    } = dependencies;
    let journal_path = reset_attempt_journal_path(store_lock.store_path());
    account.rate_limit_reset_bank = Some(observed_bank.clone());
    let preparation = with_account_store_unlocked(
        store_lock,
        expected_store_generation,
        || -> Result<ResetPreparation> {
            let (mut journal_transaction, mut journal) =
                ResetJournalTransaction::open(&journal_path, now)?;
            let unpruned_len = journal.attempts.len();
            let previous_manual_review = journal.manual_review.clone();
            prune_reset_attempt_journal(&mut journal, now);
            if journal.attempts.len() != unpruned_len
                || journal.manual_review != previous_manual_review
            {
                journal_transaction.save(&mut journal, now)?;
            }

            if let Some(manual_review) = journal.manual_review.as_ref() {
                return Ok(ResetPreparation::Suppressed(manual_review.reason.clone()));
            }

            let mut active_attempt = journal.attempts.iter().rposition(|attempt| {
                (attempt.account_id == account.account_id || attempt.local_account_id == account.id)
                    && attempt.state.suppresses_redemption()
            });

            if active_attempt.is_none() {
                if let Some(previous) = previous_bank.as_ref() {
                    if let Some(evidence) =
                        external_inventory_decrease_evidence(previous, &observed_bank, now)
                    {
                        let request_id = Uuid::new_v4();
                        journal.attempts.push(new_reset_attempt(
                            account,
                            previous,
                            evidence.selected_credit_id,
                            request_id,
                            now,
                            ResetAttemptOrigin::ExternalInventoryDecrease,
                            ResetAttemptState::ConsumptionObserved,
                        ));
                        journal_transaction.save(&mut journal, now)?;
                        if let Some(manual_review) = journal.manual_review.as_ref() {
                            return Ok(ResetPreparation::Suppressed(manual_review.reason.clone()));
                        }
                        active_attempt = journal
                            .attempts
                            .iter()
                            .position(|attempt| attempt.request_id == request_id);
                        if active_attempt.is_none() {
                            bail!(
                                "external reset evidence disappeared during durable journal preparation"
                            );
                        }
                    }
                }
            }

            if let Some(index) = active_attempt {
                return Ok(ResetPreparation::Reconcile(journal.attempts[index].clone()));
            }

            if !attempt_reset || !observed_bank.has_available_reset(now) {
                return Ok(ResetPreparation::NoAttempt);
            }

            let selected_credit_id = observed_bank
                .oldest_expiring_available_credit(now)
                .and_then(RateLimitResetCredit::normalized_id)
                .map(str::to_string);
            let request_id = Uuid::new_v4();
            journal.attempts.push(new_reset_attempt(
                account,
                &observed_bank,
                selected_credit_id,
                request_id,
                now,
                ResetAttemptOrigin::LocalRequest,
                ResetAttemptState::Prepared,
            ));
            let attempt_index = journal.attempts.len() - 1;
            journal.attempts[attempt_index].submitted_at = Some(now);

            // A crash after this durable write is intentionally uncertain.
            // Every replay observes this exact attempt and cannot repeat the POST.
            journal_transaction.save(&mut journal, now)?;
            if let Some(manual_review) = journal.manual_review.as_ref() {
                return Ok(ResetPreparation::Suppressed(manual_review.reason.clone()));
            }
            let attempt = journal
                .attempts
                .iter()
                .find(|attempt| attempt.request_id == request_id)
                .cloned()
                .context("prepared reset attempt disappeared during durable journal write")?;
            Ok(ResetPreparation::Submit {
                attempt,
                bank: observed_bank.clone(),
            })
        },
    )??;

    let (mut expected_attempt, submitted_bank) = match preparation {
        ResetPreparation::Suppressed(detail) => {
            return Ok(ResetFlowResult {
                state: ResetFlowState::Suppressed,
                consumption_observed: false,
                quota_reconciled: false,
                detail: Some(detail),
            });
        }
        ResetPreparation::NoAttempt => {
            return Ok(ResetFlowResult {
                state: ResetFlowState::NoAttempt,
                consumption_observed: false,
                quota_reconciled: false,
                detail: None,
            });
        }
        ResetPreparation::Reconcile(expected_attempt) => {
            return reconcile_attempt(
                store_lock,
                expected_store_generation,
                &journal_path,
                expected_attempt,
                account,
                ResetReconciliationObservation {
                    bank: observed_bank,
                    inventory_fresh: true,
                    inventory_error: None,
                    now,
                },
                &mut refresh_quota,
                validate_provider_io,
            );
        }
        ResetPreparation::Submit { attempt, bank } => (attempt, bank),
    };

    with_account_store_unlocked(store_lock, expected_store_generation, || {
        revalidate_exact_reset_attempt(&journal_path, &expected_attempt, now)
    })??;
    let request_id = expected_attempt.request_id;
    let selected_credit_id = expected_attempt.selected_credit_id.clone();
    let provider_io_lease = acquire_provider_io_lease(store_lock.store_path()).and_then(|lease| {
        validate_reset_provider_io(store_lock, expected_store_generation, validate_provider_io)?;
        Ok(lease)
    });
    let provider_io_lease = match provider_io_lease {
        Ok(lease) => lease,
        Err(error) => {
            let detail = format!(
            "reset provider submission was cancelled before POST because its activation guard or provider-I/O lease changed: {error:#}"
        );
            with_account_store_unlocked(store_lock, expected_store_generation, || {
                update_exact_reset_attempt(
                    &journal_path,
                    &expected_attempt,
                    now,
                    |journal, attempt_index| {
                        let attempt = &mut journal.attempts[attempt_index];
                        attempt.state = ResetAttemptState::TerminalNotApplied;
                        attempt.last_error = Some(detail.clone());
                    },
                )
            })??;
            return Err(error)
                .context("reset provider submission gate changed immediately before POST");
        }
    };
    let consume_result =
        with_account_store_unlocked(store_lock, expected_store_generation, || {
            consume(account, &submitted_bank, request_id)
        })?;
    drop(provider_io_lease);

    let (response_code, state, last_error) = match consume_result {
        Ok(result) => {
            let state = if matches!(
                result.code,
                ConsumeCode::NoCredit | ConsumeCode::NothingToReset
            ) {
                ResetAttemptState::TerminalNotApplied
            } else {
                ResetAttemptState::Uncertain
            };
            let returned_credit_id = result
                .credit_id
                .as_deref()
                .map(str::trim)
                .filter(|identifier| !identifier.is_empty());
            let selected_credit_id = selected_credit_id
                .as_deref()
                .map(str::trim)
                .filter(|identifier| !identifier.is_empty());
            let last_error = returned_credit_id
                .zip(selected_credit_id)
                .filter(|(returned, selected)| returned != selected)
                .map(|(returned, selected)| {
                    format!(
                        "reset response named credit {returned}, but the durable request selected {selected}; reconciliation requires the selected credit"
                    )
                });
            (Some(result.code), state, last_error)
        }
        Err(error) => (
            None,
            ResetAttemptState::Uncertain,
            Some(format!("reset request outcome is uncertain: {error:#}")),
        ),
    };
    expected_attempt = with_account_store_unlocked(store_lock, expected_store_generation, || {
        update_exact_reset_attempt(
            &journal_path,
            &expected_attempt,
            now,
            |journal, attempt_index| {
                let attempt = &mut journal.attempts[attempt_index];
                attempt.response_code = response_code;
                attempt.state = state;
                attempt.last_error = last_error;
            },
        )
    })??;

    if state == ResetAttemptState::TerminalNotApplied {
        return Ok(ResetFlowResult {
            state: ResetFlowState::TerminalNotApplied,
            consumption_observed: false,
            quota_reconciled: false,
            detail: Some(format!(
                "reset was definitively not applied ({})",
                consume_code_name(
                    response_code
                        .context("terminal reset response lost its durable response code")?
                )
            )),
        });
    }

    with_account_store_unlocked(store_lock, expected_store_generation, || {
        revalidate_exact_reset_attempt(&journal_path, &expected_attempt, now)
    })??;
    validate_reset_provider_io(store_lock, expected_store_generation, validate_provider_io)
        .context("reset activation guard changed before inventory reconciliation")?;
    let reconciled_bank_result =
        with_account_store_unlocked(store_lock, expected_store_generation, || {
            fetch_bank(account)
        })?;
    let (reconciled_bank, inventory_fresh, inventory_error) = match reconciled_bank_result {
        Ok(bank) => {
            account.rate_limit_reset_bank = Some(bank.clone());
            (bank, true, None)
        }
        Err(error) => (
            observed_bank,
            false,
            Some(format!("reset inventory reconciliation failed: {error:#}")),
        ),
    };

    reconcile_attempt(
        store_lock,
        expected_store_generation,
        &journal_path,
        expected_attempt,
        account,
        ResetReconciliationObservation {
            bank: reconciled_bank,
            inventory_fresh,
            inventory_error,
            now,
        },
        &mut refresh_quota,
        validate_provider_io,
    )
}

fn new_reset_attempt(
    account: &CodexAccount,
    bank: &RateLimitResetBank,
    selected_credit_id: Option<String>,
    request_id: Uuid,
    now: DateTime<Utc>,
    origin: ResetAttemptOrigin,
    state: ResetAttemptState,
) -> ResetAttempt {
    let pre_available_credits = bank
        .structurally_valid_available_credits(bank.fetched_at)
        .unwrap_or_default();
    let selected_credit_expires_at = selected_credit_id.as_deref().and_then(|selected_id| {
        pre_available_credits
            .iter()
            .find(|credit| credit.normalized_id() == Some(selected_id.trim()))
            .and_then(|credit| credit.expires_at)
    });
    let pre_available_credit_ids = pre_available_credits
        .into_iter()
        .filter_map(RateLimitResetCredit::normalized_id)
        .map(str::to_string)
        .collect();
    ResetAttempt {
        account_id: account.account_id.clone(),
        local_account_id: account.id,
        stable_owner: Some(reset_attempt_owner(account)),
        selected_credit_id,
        selected_credit_expires_at,
        pre_available_credit_ids,
        request_id,
        pre_inventory_generation: inventory_generation(bank),
        starting_quota_generation: Some(quota_evidence_generation(account)),
        pre_inventory_count: bank.available_count,
        pre_inventory_fetched_at: Some(bank.fetched_at),
        started_at: now,
        submitted_at: None,
        state,
        reconciliation_deadline: now + RESET_RECONCILIATION_INTERVAL,
        origin,
        response_code: None,
        last_inventory_generation: None,
        last_quota_generation: None,
        last_inventory_count: None,
        quota_reconciled_at: None,
        quota_usable: None,
        last_error: None,
    }
}

struct ResetReconciliationObservation {
    bank: RateLimitResetBank,
    inventory_fresh: bool,
    inventory_error: Option<String>,
    now: DateTime<Utc>,
}

fn reconcile_attempt<Q, V>(
    store_lock: &AccountStoreLock,
    expected_store_generation: &AccountStoreGeneration,
    journal_path: &Path,
    expected_attempt: ResetAttempt,
    account: &mut CodexAccount,
    observation: ResetReconciliationObservation,
    refresh_quota: &mut Q,
    validate_provider_io: &mut V,
) -> Result<ResetFlowResult>
where
    Q: FnMut(&mut CodexAccount) -> Result<()>,
    V: FnMut(&AccountStoreLock) -> Result<()>,
{
    let ResetReconciliationObservation {
        bank,
        inventory_fresh,
        inventory_error,
        now,
    } = observation;
    let expected_owner = expected_attempt.stable_owner.clone();
    let starting_quota_generation = expected_attempt.starting_quota_generation.clone();
    let current_owner = reset_attempt_owner(account);
    let starting_quota_generation = starting_quota_generation
        .filter(|_| expected_owner.as_deref() == Some(current_owner.as_str()));
    let Some(starting_quota_generation) = starting_quota_generation else {
        let detail = "reset attempt lacks matching stable-owner or starting-quota evidence; manual review is required"
            .to_string();
        with_account_store_unlocked(store_lock, expected_store_generation, || {
            update_exact_reset_attempt(
                journal_path,
                &expected_attempt,
                now,
                |journal, attempt_index| {
                    journal.attempts[attempt_index].state =
                        ResetAttemptState::ReconciliationOverdue;
                    journal.attempts[attempt_index].last_error = Some(detail.clone());
                    mark_reset_journal_manual_review(journal, now, 0, detail.clone());
                },
            )
        })??;
        return Ok(ResetFlowResult {
            state: ResetFlowState::Suppressed,
            consumption_observed: false,
            quota_reconciled: false,
            detail: Some(detail),
        });
    };
    with_account_store_unlocked(store_lock, expected_store_generation, || {
        revalidate_exact_reset_attempt(journal_path, &expected_attempt, now)
    })??;
    validate_reset_provider_io(store_lock, expected_store_generation, validate_provider_io)
        .context("reset activation guard changed before quota reconciliation")?;
    let mut refreshed_account = account.clone();
    let quota_result = with_account_store_unlocked(store_lock, expected_store_generation, || {
        refresh_quota(&mut refreshed_account)
    })?;
    *account = refreshed_account;
    let quota_freshness_boundary = expected_attempt
        .submitted_at
        .unwrap_or(expected_attempt.started_at);
    let observed_quota_generation = quota_evidence_generation(account);
    let fresh_snapshot = real_quota_snapshot(account)
        .filter(|snapshot| snapshot.fetched_at > quota_freshness_boundary);
    let fresh_snapshot_at = fresh_snapshot.map(|snapshot| snapshot.fetched_at);
    let quota_checked_at = fresh_snapshot
        .map(|snapshot| now.max(snapshot.fetched_at))
        .unwrap_or(now);
    let owner_still_matches = reset_attempt_owner(account) == current_owner;
    let quota_generation_changed =
        fresh_snapshot.is_some() && observed_quota_generation != starting_quota_generation;
    let quota_reconciled = quota_result.is_ok()
        && fresh_snapshot.is_some()
        && quota_generation_changed
        && owner_still_matches;
    let quota_usable = quota_reconciled
        && quota_availability_at(account, quota_checked_at) == QuotaAvailability::Usable;
    let quota_error = match quota_result {
        Err(error) => Some(format!("quota reconciliation failed: {error:#}")),
        Ok(()) if !owner_still_matches => Some(
            "quota reconciliation changed the stable reset owner; manual review is required"
                .to_string(),
        ),
        Ok(()) if fresh_snapshot.is_none() => Some(format!(
            "quota reconciliation returned no snapshot newer than {}",
            quota_freshness_boundary.to_rfc3339()
        )),
        Ok(()) if !quota_generation_changed => Some(
            "quota reconciliation returned no evidence generation newer than the durable starting quota"
                .to_string(),
        ),
        Ok(()) => None,
    };

    let mut updated_attempt = expected_attempt.clone();
    if inventory_fresh {
        updated_attempt.last_inventory_generation = Some(inventory_generation(&bank));
        updated_attempt.last_inventory_count = Some(bank.available_count);
    }
    if quota_reconciled {
        updated_attempt.quota_reconciled_at = fresh_snapshot_at;
        updated_attempt.quota_usable = Some(quota_usable);
    }
    if fresh_snapshot.is_some() {
        updated_attempt.last_quota_generation = Some(observed_quota_generation);
    }

    let consumption_observed = inventory_fresh
        && inventory_is_newer_than_attempt(&updated_attempt, &bank)
        && inventory_is_consumed(&updated_attempt, &bank, now);
    let external_hold_active = updated_attempt.origin
        == ResetAttemptOrigin::ExternalInventoryDecrease
        && now < updated_attempt.reconciliation_deadline;
    updated_attempt.state = if consumption_observed && quota_usable && !external_hold_active {
        ResetAttemptState::ReconciledUsable
    } else if consumption_observed {
        ResetAttemptState::ConsumptionObserved
    } else if now >= updated_attempt.reconciliation_deadline {
        ResetAttemptState::ReconciliationOverdue
    } else {
        ResetAttemptState::Uncertain
    };
    updated_attempt.last_error = join_details([
        updated_attempt.last_error.take(),
        inventory_error.clone(),
        quota_error.clone(),
    ]);
    let state = if updated_attempt.state == ResetAttemptState::ReconciledUsable {
        ResetFlowState::ReconciledUsable
    } else {
        ResetFlowState::Suppressed
    };
    let detail = updated_attempt.last_error.clone();

    let result = ResetFlowResult {
        state,
        consumption_observed,
        quota_reconciled,
        detail,
    };
    with_account_store_unlocked(store_lock, expected_store_generation, || {
        update_exact_reset_attempt(
            journal_path,
            &expected_attempt,
            now,
            |journal, attempt_index| {
                journal.attempts[attempt_index] = updated_attempt;
                if !owner_still_matches {
                    mark_reset_journal_manual_review(
                        journal,
                        now,
                        0,
                        "quota reconciliation changed the stable reset owner; manual review is required",
                    );
                }
            },
        )
    })??;
    account.rate_limit_reset_bank = Some(bank);
    Ok(result)
}

fn inventory_is_consumed(
    attempt: &ResetAttempt,
    bank: &RateLimitResetBank,
    now: DateTime<Utc>,
) -> bool {
    let Some(selected_credit_id) = attempt.selected_credit_id.as_deref() else {
        return false;
    };
    let selected_credit_id = selected_credit_id.trim();
    if bank
        .credits
        .iter()
        .find(|credit| credit.normalized_id() == Some(selected_credit_id))
        .is_some_and(RateLimitResetCredit::has_terminal_consumption_status)
    {
        return true;
    }

    let Some(selected_credit_expires_at) = attempt.selected_credit_expires_at else {
        return false;
    };
    let observation_at = now.max(bank.fetched_at);
    if selected_credit_expires_at <= observation_at
        || bank.available_count.checked_add(1) != Some(attempt.pre_inventory_count)
        || attempt.pre_available_credit_ids.len() != attempt.pre_inventory_count as usize
    {
        return false;
    }

    let mut starting_ids = std::collections::HashSet::new();
    if attempt.pre_available_credit_ids.iter().any(|identifier| {
        let identifier = identifier.trim();
        identifier.is_empty() || !starting_ids.insert(identifier)
    }) || !starting_ids.contains(selected_credit_id)
    {
        return false;
    }

    let Some(observed_credits) = bank.structurally_valid_available_credits(observation_at) else {
        return false;
    };
    let observed_ids = observed_credits
        .into_iter()
        .filter_map(RateLimitResetCredit::normalized_id)
        .collect::<Vec<_>>();
    let expected_ids = attempt
        .pre_available_credit_ids
        .iter()
        .map(|identifier| identifier.trim())
        .filter(|identifier| *identifier != selected_credit_id)
        .collect::<Vec<_>>();

    observed_ids == expected_ids
}

fn reset_attempt_has_complete_inventory_evidence(attempt: &ResetAttempt) -> bool {
    let Some(selected_credit_id) = attempt
        .selected_credit_id
        .as_deref()
        .map(str::trim)
        .filter(|identifier| !identifier.is_empty())
    else {
        return false;
    };
    let Some(selected_credit_expires_at) = attempt.selected_credit_expires_at else {
        return false;
    };
    if attempt.pre_available_credit_ids.len() != attempt.pre_inventory_count as usize
        || attempt
            .pre_inventory_fetched_at
            .is_none_or(|fetched_at| selected_credit_expires_at <= fetched_at)
    {
        return false;
    }

    let mut identifiers = std::collections::HashSet::new();
    attempt.pre_available_credit_ids.iter().all(|identifier| {
        let identifier = identifier.trim();
        !identifier.is_empty() && identifiers.insert(identifier)
    }) && identifiers.contains(selected_credit_id)
}

fn inventory_is_newer_than_attempt(attempt: &ResetAttempt, bank: &RateLimitResetBank) -> bool {
    attempt
        .pre_inventory_fetched_at
        .is_some_and(|started_at| bank.fetched_at > started_at)
        && inventory_generation(bank) != attempt.pre_inventory_generation
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ExternalInventoryDecreaseEvidence {
    selected_credit_id: Option<String>,
}

fn external_inventory_decrease_evidence(
    previous: &RateLimitResetBank,
    observed: &RateLimitResetBank,
    now: DateTime<Utc>,
) -> Option<ExternalInventoryDecreaseEvidence> {
    if observed.available_count >= previous.available_count {
        return None;
    }

    let observation_at = now.max(observed.fetched_at);
    let Some(previous_credits) = previous.structurally_valid_available_credits(previous.fetched_at)
    else {
        return Some(ExternalInventoryDecreaseEvidence {
            selected_credit_id: None,
        });
    };
    let Some(observed_credits) = observed.structurally_valid_available_credits(observation_at)
    else {
        return Some(ExternalInventoryDecreaseEvidence {
            selected_credit_id: None,
        });
    };

    let expected_after_natural_expiry = previous_credits
        .iter()
        .copied()
        .filter(|credit| {
            credit
                .expires_at
                .is_some_and(|expiration| expiration > observation_at)
        })
        .collect::<Vec<_>>();
    let observed_ids = observed_credits
        .iter()
        .filter_map(|credit| credit.normalized_id())
        .collect::<Vec<_>>();
    let expected_ids = expected_after_natural_expiry
        .iter()
        .filter_map(|credit| credit.normalized_id())
        .collect::<Vec<_>>();
    if observed.available_count == expected_after_natural_expiry.len() as u32
        && observed_ids == expected_ids
    {
        return None;
    }

    let observed_id_set = observed_ids
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    let selected_credit_id = expected_after_natural_expiry
        .into_iter()
        .filter_map(RateLimitResetCredit::normalized_id)
        .find(|identifier| !observed_id_set.contains(identifier))
        .map(str::to_string);
    Some(ExternalInventoryDecreaseEvidence { selected_credit_id })
}

fn inventory_generation(bank: &RateLimitResetBank) -> String {
    let mut digest = DigestContext::new(&SHA256);
    digest.update(&bank.fetched_at.timestamp_millis().to_be_bytes());
    digest.update(&bank.available_count.to_be_bytes());
    digest.update(&bank.total_earned_count.to_be_bytes());
    let mut credits = bank.credits.iter().collect::<Vec<_>>();
    credits.sort_by(|left, right| {
        (
            left.id.as_str(),
            left.status.as_str(),
            left.redeemed_at.map(|value| value.timestamp_millis()),
        )
            .cmp(&(
                right.id.as_str(),
                right.status.as_str(),
                right.redeemed_at.map(|value| value.timestamp_millis()),
            ))
    });
    for credit in credits {
        update_generation_digest(&mut digest, credit.id.as_bytes());
        update_generation_digest(&mut digest, credit.status.as_bytes());
        digest.update(
            &credit
                .redeemed_at
                .map(|value| value.timestamp_millis())
                .unwrap_or_default()
                .to_be_bytes(),
        );
    }
    finish_generation_digest(digest)
}

fn reset_attempt_owner(account: &CodexAccount) -> String {
    reset_attempt_owner_from_account_id(&account.account_id)
}

fn reset_attempt_owner_from_account_id(account_id: &str) -> String {
    let mut digest = DigestContext::new(&SHA256);
    update_generation_digest(&mut digest, account_id.as_bytes());
    finish_generation_digest(digest)
}

fn quota_evidence_generation(account: &CodexAccount) -> String {
    let mut digest = DigestContext::new(&SHA256);
    let Some(snapshot) = real_quota_snapshot(account) else {
        update_generation_digest(&mut digest, b"missing");
        return finish_generation_digest(digest);
    };

    // fetched_at proves observation order separately; excluding it ensures a
    // newer timestamp alone cannot manufacture changed quota evidence.
    digest.update(&[
        optional_bool_code(snapshot.allowed),
        optional_bool_code(snapshot.limit_reached),
    ]);
    let mut windows = snapshot.windows.iter().collect::<Vec<_>>();
    windows.sort_by_key(|window| {
        (
            quota_window_kind_code(window.kind),
            window.duration_seconds,
            window.used_percent.to_bits(),
            window.resets_at.timestamp_millis(),
            quota_source_code(window.source.rate_limit),
            quota_slot_code(window.source.slot),
            window.source.limit_name.as_deref().unwrap_or(""),
            window.source.metered_feature.as_deref().unwrap_or(""),
            window.hard_limit_reached,
        )
    });
    digest.update(&(windows.len() as u64).to_be_bytes());
    for window in windows {
        digest.update(&[quota_window_kind_code(window.kind)]);
        digest.update(&window.duration_seconds.to_be_bytes());
        digest.update(&window.used_percent.to_bits().to_be_bytes());
        digest.update(&window.resets_at.timestamp_millis().to_be_bytes());
        digest.update(&[quota_source_code(window.source.rate_limit)]);
        digest.update(&[quota_slot_code(window.source.slot)]);
        update_generation_digest(
            &mut digest,
            window.source.limit_name.as_deref().unwrap_or("").as_bytes(),
        );
        update_generation_digest(
            &mut digest,
            window
                .source
                .metered_feature
                .as_deref()
                .unwrap_or("")
                .as_bytes(),
        );
        digest.update(&[u8::from(window.hard_limit_reached)]);
    }
    finish_generation_digest(digest)
}

fn optional_bool_code(value: Option<bool>) -> u8 {
    match value {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    }
}

fn quota_window_kind_code(kind: QuotaWindowKind) -> u8 {
    match kind {
        QuotaWindowKind::FiveHour => 1,
        QuotaWindowKind::Weekly => 2,
        QuotaWindowKind::Unknown => 3,
    }
}

fn quota_source_code(source: QuotaWindowRateLimitSource) -> u8 {
    match source {
        QuotaWindowRateLimitSource::Main => 1,
        QuotaWindowRateLimitSource::Additional => 2,
        QuotaWindowRateLimitSource::Legacy => 3,
        QuotaWindowRateLimitSource::Unknown => 4,
    }
}

fn quota_slot_code(slot: QuotaWindowSlot) -> u8 {
    match slot {
        QuotaWindowSlot::Primary => 1,
        QuotaWindowSlot::Secondary => 2,
        QuotaWindowSlot::LegacyFiveHour => 3,
        QuotaWindowSlot::LegacyWeekly => 4,
        QuotaWindowSlot::Unknown => 5,
    }
}

fn finish_generation_digest(digest: DigestContext) -> String {
    digest
        .finish()
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn update_generation_digest(digest: &mut DigestContext, value: &[u8]) {
    digest.update(&(value.len() as u64).to_be_bytes());
    digest.update(value);
}

fn join_details<const N: usize>(details: [Option<String>; N]) -> Option<String> {
    let mut unique = Vec::new();
    for detail in details.into_iter().flatten() {
        if !detail.is_empty() && !unique.contains(&detail) {
            unique.push(detail);
        }
    }
    if unique.is_empty() {
        return None;
    }
    Some(truncate_utf8(
        unique.join("; "),
        RESET_ERROR_DETAIL_MAX_BYTES,
    ))
}

fn truncate_utf8(mut value: String, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value;
    }
    let mut boundary = max_bytes.saturating_sub(3).min(value.len());
    while !value.is_char_boundary(boundary) {
        boundary = boundary.saturating_sub(1);
    }
    value.truncate(boundary);
    value.push_str("...");
    value
}

fn consume_code_name(code: ConsumeCode) -> &'static str {
    match code {
        ConsumeCode::Reset => "reset",
        ConsumeCode::AlreadyRedeemed => "already_redeemed",
        ConsumeCode::NoCredit => "no_credit",
        ConsumeCode::NothingToReset => "nothing_to_reset",
    }
}

fn decode_reset_attempt_journal(
    bytes: Option<&[u8]>,
    path: &Path,
    now: DateTime<Utc>,
) -> Result<(ResetAttemptJournal, bool)> {
    let Some(data) = bytes else {
        return Ok((ResetAttemptJournal::default(), false));
    };
    let mut journal: ResetAttemptJournal = serde_json::from_slice(data)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    if !matches!(
        journal.version,
        RESET_ATTEMPT_JOURNAL_VERSION_1
            | RESET_ATTEMPT_JOURNAL_VERSION_2
            | RESET_ATTEMPT_JOURNAL_VERSION
    ) {
        bail!(
            "unsupported reset-attempt journal version {} in {}",
            journal.version,
            path.display()
        );
    }
    let original_version = journal.version;
    if original_version == RESET_ATTEMPT_JOURNAL_VERSION_1 {
        for attempt in &mut journal.attempts {
            attempt.stable_owner = Some(reset_attempt_owner_from_account_id(&attempt.account_id));
        }
    }
    journal.version = RESET_ATTEMPT_JOURNAL_VERSION;
    let truncated_fields = sanitize_reset_attempt_journal(&mut journal);
    let incomplete_quota_evidence = journal
        .attempts
        .iter()
        .filter(|attempt| {
            !attempt.state.is_terminal()
                && (attempt.stable_owner.is_none() || attempt.starting_quota_generation.is_none())
        })
        .count();
    let incomplete_inventory_evidence = journal
        .attempts
        .iter()
        .filter(|attempt| {
            !attempt.state.is_terminal()
                && attempt.origin == ResetAttemptOrigin::LocalRequest
                && !reset_attempt_has_complete_inventory_evidence(attempt)
        })
        .count();
    if truncated_fields > 0 {
        mark_reset_journal_manual_review(
            &mut journal,
            now,
            0,
            format!(
                "{truncated_fields} oversized reset journal evidence field(s) were truncated; manual review is required"
            ),
        );
    }
    if incomplete_quota_evidence > 0 {
        mark_reset_journal_manual_review(
            &mut journal,
            now,
            0,
            format!(
                "{incomplete_quota_evidence} unresolved legacy reset attempt(s) lack a durable starting quota generation; manual review is required"
            ),
        );
    }
    if incomplete_inventory_evidence > 0 {
        mark_reset_journal_manual_review(
            &mut journal,
            now,
            0,
            format!(
                "{incomplete_inventory_evidence} unresolved legacy reset attempt(s) lack exact selected-credit expiration or starting inventory evidence; manual review is required"
            ),
        );
    }
    Ok((
        journal,
        original_version != RESET_ATTEMPT_JOURNAL_VERSION
            || truncated_fields > 0
            || incomplete_quota_evidence > 0
            || incomplete_inventory_evidence > 0,
    ))
}

fn oversized_reset_journal(observed_size: u64, now: DateTime<Utc>) -> ResetAttemptJournal {
    let mut journal = ResetAttemptJournal::default();
    mark_reset_journal_manual_review(
        &mut journal,
        now,
        1,
        format!(
            "reset journal exceeded the {} byte safety limit (observed {observed_size}); unresolved reset state requires manual review",
            RESET_ATTEMPT_JOURNAL_MAX_BYTES
        ),
    );
    journal
}

#[cfg(test)]
fn load_reset_attempt_journal(path: &Path) -> Result<ResetAttemptJournal> {
    ResetJournalTransaction::open(path, Utc::now()).map(|(_, journal)| journal)
}

fn prune_reset_attempt_journal(journal: &mut ResetAttemptJournal, now: DateTime<Utc>) {
    let cutoff = now - RESET_TERMINAL_RETENTION;
    let mut retained_terminal_ids = journal
        .attempts
        .iter()
        .filter(|attempt| attempt.state.is_terminal() && attempt.started_at >= cutoff)
        .map(|attempt| (attempt.started_at, attempt.request_id))
        .collect::<Vec<_>>();
    retained_terminal_ids.sort_by(|left, right| right.0.cmp(&left.0));
    let retained_terminal_ids = retained_terminal_ids
        .into_iter()
        .take(RESET_TERMINAL_ENTRY_CAP)
        .map(|(_, request_id)| request_id)
        .collect::<std::collections::HashSet<_>>();
    journal.attempts.retain(|attempt| {
        !attempt.state.is_terminal() || retained_terminal_ids.contains(&attempt.request_id)
    });

    let mut unresolved = journal
        .attempts
        .iter()
        .filter(|attempt| !attempt.state.is_terminal())
        .map(|attempt| (attempt.started_at, attempt.request_id))
        .collect::<Vec<_>>();
    unresolved.sort_by(|left, right| right.0.cmp(&left.0));
    if unresolved.len() <= RESET_UNRESOLVED_ENTRY_CAP {
        return;
    }
    let retained_unresolved_ids = unresolved
        .iter()
        .take(RESET_UNRESOLVED_ENTRY_CAP)
        .map(|(_, request_id)| *request_id)
        .collect::<std::collections::HashSet<_>>();
    let compacted_count = unresolved.len() - retained_unresolved_ids.len();
    journal.attempts.retain(|attempt| {
        attempt.state.is_terminal() || retained_unresolved_ids.contains(&attempt.request_id)
    });
    mark_reset_journal_manual_review(
        journal,
        now,
        compacted_count as u64,
        "unresolved reset history was compacted; manual review is required before another redemption",
    );
}

fn sanitize_reset_attempt_journal(journal: &mut ResetAttemptJournal) -> usize {
    let mut truncated = 0;
    for attempt in &mut journal.attempts {
        truncated += usize::from(truncate_field(
            &mut attempt.account_id,
            RESET_IDENTIFIER_MAX_BYTES,
        ));
        truncated += usize::from(truncate_optional_field(
            &mut attempt.selected_credit_id,
            RESET_IDENTIFIER_MAX_BYTES,
        ));
        for identifier in &mut attempt.pre_available_credit_ids {
            truncated += usize::from(truncate_field(identifier, RESET_IDENTIFIER_MAX_BYTES));
        }
        truncated += usize::from(truncate_optional_field(
            &mut attempt.stable_owner,
            RESET_GENERATION_MAX_BYTES,
        ));
        truncated += usize::from(truncate_field(
            &mut attempt.pre_inventory_generation,
            RESET_GENERATION_MAX_BYTES,
        ));
        truncated += usize::from(truncate_optional_field(
            &mut attempt.starting_quota_generation,
            RESET_GENERATION_MAX_BYTES,
        ));
        truncated += usize::from(truncate_optional_field(
            &mut attempt.last_inventory_generation,
            RESET_GENERATION_MAX_BYTES,
        ));
        truncated += usize::from(truncate_optional_field(
            &mut attempt.last_quota_generation,
            RESET_GENERATION_MAX_BYTES,
        ));
        truncated += usize::from(truncate_optional_field(
            &mut attempt.last_error,
            RESET_ERROR_DETAIL_MAX_BYTES,
        ));
    }
    if let Some(sentinel) = journal.manual_review.as_mut() {
        truncated += usize::from(truncate_field(
            &mut sentinel.reason,
            RESET_MANUAL_REVIEW_REASON_MAX_BYTES,
        ));
    }
    truncated
}

fn truncate_optional_field(value: &mut Option<String>, max_bytes: usize) -> bool {
    value
        .as_mut()
        .is_some_and(|value| truncate_field(value, max_bytes))
}

fn truncate_field(value: &mut String, max_bytes: usize) -> bool {
    if value.len() <= max_bytes {
        return false;
    }
    *value = truncate_utf8(std::mem::take(value), max_bytes);
    true
}

fn mark_reset_journal_manual_review(
    journal: &mut ResetAttemptJournal,
    now: DateTime<Utc>,
    compacted_attempt_count: u64,
    reason: impl Into<String>,
) {
    let reason = truncate_utf8(reason.into(), RESET_MANUAL_REVIEW_REASON_MAX_BYTES);
    let sentinel = journal
        .manual_review
        .get_or_insert_with(|| ResetManualReviewSentinel {
            first_compacted_at: now,
            last_compacted_at: now,
            compacted_attempt_count: 0,
            reason: reason.clone(),
        });
    sentinel.last_compacted_at = now;
    sentinel.compacted_attempt_count = sentinel
        .compacted_attempt_count
        .saturating_add(compacted_attempt_count);
    if sentinel.reason != reason {
        sentinel.reason = truncate_utf8(
            format!("{}; {reason}", sentinel.reason),
            RESET_MANUAL_REVIEW_REASON_MAX_BYTES,
        );
    }
}

fn serialize_reset_attempt_journal_bounded(
    journal: &mut ResetAttemptJournal,
    now: DateTime<Utc>,
) -> Result<Vec<u8>> {
    loop {
        let data =
            serde_json::to_vec_pretty(journal).context("failed to encode reset-attempt journal")?;
        if data.len() <= RESET_ATTEMPT_JOURNAL_MAX_BYTES {
            return Ok(data);
        }

        mark_reset_journal_manual_review(
            journal,
            now,
            0,
            format!(
                "reset journal serialization exceeded the {} byte safety limit; history was compacted and manual review is required",
                RESET_ATTEMPT_JOURNAL_MAX_BYTES
            ),
        );
        let removable = journal
            .attempts
            .iter()
            .enumerate()
            .filter(|(_, attempt)| attempt.state.is_terminal())
            .min_by_key(|(_, attempt)| attempt.started_at)
            .map(|(index, _)| index)
            .or_else(|| {
                journal
                    .attempts
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, attempt)| attempt.started_at)
                    .map(|(index, _)| index)
            });
        let Some(index) = removable else {
            bail!(
                "manual-review reset journal cannot fit within {} bytes",
                RESET_ATTEMPT_JOURNAL_MAX_BYTES
            );
        };
        journal.attempts.remove(index);
        if let Some(sentinel) = journal.manual_review.as_mut() {
            sentinel.compacted_attempt_count = sentinel.compacted_attempt_count.saturating_add(1);
        }
    }
}

fn prepare_reset_attempt_journal_write(
    journal: &mut ResetAttemptJournal,
    now: DateTime<Utc>,
) -> Result<Vec<u8>> {
    prune_reset_attempt_journal(journal, now);
    let truncated_fields = sanitize_reset_attempt_journal(journal);
    if truncated_fields > 0 {
        mark_reset_journal_manual_review(
            journal,
            now,
            0,
            format!(
                "{truncated_fields} oversized reset journal evidence field(s) were truncated; manual review is required"
            ),
        );
    }
    let data = serialize_reset_attempt_journal_bounded(journal, now)?;
    if data.len() > RESET_ATTEMPT_JOURNAL_MAX_BYTES {
        bail!("reset-attempt journal exceeded byte limit before write");
    }
    Ok(data)
}

#[cfg(test)]
fn save_reset_attempt_journal(
    path: &Path,
    journal: &mut ResetAttemptJournal,
    now: DateTime<Utc>,
) -> Result<()> {
    let (mut transaction, _) = ResetJournalTransaction::open(path, now)?;
    transaction.save(journal, now)
}

#[derive(Debug, Serialize)]
struct ConsumeRequest<'a> {
    credit_id: &'a str,
    redeem_request_id: Uuid,
}

#[derive(Debug)]
struct HttpResponse {
    status: u16,
    body: Vec<u8>,
}

#[derive(Debug, Deserialize)]
struct BackendResetBank {
    available_count: u32,
    total_earned_count: u32,
    credits: Vec<BackendResetCredit>,
}

#[derive(Debug, Deserialize)]
struct BackendResetCredit {
    id: String,
    #[serde(default)]
    reset_type: Option<String>,
    status: String,
    #[serde(default)]
    granted_at: Option<DateTime<Utc>>,
    #[serde(default)]
    expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    redeem_started_at: Option<DateTime<Utc>>,
    #[serde(default)]
    redeemed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
}

#[derive(Debug, Deserialize)]
struct BackendConsumeResponse {
    code: String,
    #[serde(default)]
    credit: Option<BackendConsumeCredit>,
}

#[derive(Debug, Deserialize)]
struct BackendConsumeCredit {
    id: String,
}

pub fn fetch_rate_limit_reset_bank(account: &CodexAccount) -> Result<RateLimitResetBank> {
    let client = reset_http_client()?;
    fetch_rate_limit_reset_bank_with(
        account,
        |account| {
            let response = client
                .get(RESET_CREDITS_URL)
                .bearer_auth(&account.access_token)
                .header("ChatGPT-Account-Id", &account.account_id)
                .header("Accept", "application/json")
                .send()
                .with_context(|| format!("failed to fetch reset bank for {}", account.email))?;
            let status = response.status().as_u16();
            let body = response
                .bytes()
                .context("failed to read reset-bank response body")?
                .to_vec();
            Ok(HttpResponse { status, body })
        },
        Utc::now,
    )
}

fn fetch_rate_limit_reset_bank_with<F, N>(
    account: &CodexAccount,
    fetch: F,
    completed_at: N,
) -> Result<RateLimitResetBank>
where
    F: FnOnce(&CodexAccount) -> Result<HttpResponse>,
    N: FnOnce() -> DateTime<Utc>,
{
    let response = fetch(account)?;
    let fetched_at = completed_at();
    match response.status {
        200 => parse_reset_bank(&response.body, fetched_at),
        401 => bail!(
            "token expired while fetching reset bank for {}",
            account.email
        ),
        429 => bail!(
            "rate limited while fetching reset bank for {}",
            account.email
        ),
        status => bail!(
            "reset-bank API returned HTTP {status} for {}",
            account.email
        ),
    }
}

fn parse_reset_bank(data: &[u8], fetched_at: DateTime<Utc>) -> Result<RateLimitResetBank> {
    let response: BackendResetBank =
        serde_json::from_slice(data).context("failed to decode reset-bank response")?;
    Ok(RateLimitResetBank {
        available_count: response.available_count,
        total_earned_count: response.total_earned_count,
        credits: response
            .credits
            .into_iter()
            .map(|credit| RateLimitResetCredit {
                id: credit.id,
                reset_type: credit.reset_type,
                status: credit.status,
                granted_at: credit.granted_at,
                expires_at: credit.expires_at,
                redeem_started_at: credit.redeem_started_at,
                redeemed_at: credit.redeemed_at,
                title: credit.title,
                description: credit.description,
            })
            .collect(),
        fetched_at,
    })
}

pub fn consume_rate_limit_reset(
    account: &CodexAccount,
    bank: &RateLimitResetBank,
    redeem_request_id: Uuid,
) -> Result<ConsumeResult> {
    let client = reset_http_client()?;
    consume_rate_limit_reset_with(
        account,
        bank,
        Utc::now(),
        redeem_request_id,
        |account, body| {
            let response = client
                .post(RESET_CONSUME_URL)
                .bearer_auth(&account.access_token)
                .header("ChatGPT-Account-Id", &account.account_id)
                .header("Accept", "application/json")
                .json(body)
                .send()
                .with_context(|| format!("failed to consume reset for {}", account.email))?;
            let status = response.status().as_u16();
            let body = response
                .bytes()
                .context("failed to read reset-consume response body")?
                .to_vec();
            Ok(HttpResponse { status, body })
        },
    )
}

fn consume_rate_limit_reset_with<F>(
    account: &CodexAccount,
    bank: &RateLimitResetBank,
    now: DateTime<Utc>,
    redeem_request_id: Uuid,
    send: F,
) -> Result<ConsumeResult>
where
    F: FnOnce(&CodexAccount, &ConsumeRequest<'_>) -> Result<HttpResponse>,
{
    if !bank.has_available_reset(now) {
        bail!(
            "reset bank has no concrete unexpired available credit for {}",
            account.email
        );
    }
    let selected_credit_id = bank
        .oldest_expiring_available_credit(now)
        .and_then(RateLimitResetCredit::normalized_id)
        .context("reset bank has no concrete available credit identifier")?;
    let request = ConsumeRequest {
        credit_id: selected_credit_id,
        redeem_request_id,
    };

    let response = send(account, &request).with_context(|| {
        format!(
            "reset consume transport outcome is uncertain for {}",
            account.email
        )
    })?;
    if !(200..300).contains(&response.status) {
        bail!(
            "reset-consume API returned HTTP {} for {} with an uncertain outcome",
            response.status,
            account.email
        );
    }

    let response: BackendConsumeResponse = serde_json::from_slice(&response.body)
        .context("failed to decode reset-consume response; outcome is uncertain")?;
    let code = match response.code.as_str() {
        "reset" => ConsumeCode::Reset,
        "already_redeemed" => ConsumeCode::AlreadyRedeemed,
        "no_credit" => ConsumeCode::NoCredit,
        "nothing_to_reset" => ConsumeCode::NothingToReset,
        other => bail!("reset-consume API returned unknown code {other}; outcome is uncertain"),
    };
    let credit_id = response
        .credit
        .and_then(|credit| {
            let identifier = credit.id.trim();
            (!identifier.is_empty()).then(|| identifier.to_string())
        })
        .or_else(|| Some(selected_credit_id.to_string()));
    Ok(ConsumeResult { code, credit_id })
}

fn reset_http_client() -> Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent("codex-cli")
        .build()
        .context("failed to build reset-bank HTTP client")
}

fn serialize_swift_datetime<S>(
    value: &DateTime<Utc>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer
        .serialize_f64(value.timestamp_millis() as f64 / 1000.0 - UNIX_TO_SWIFT_REFERENCE_SECONDS)
}

fn deserialize_swift_datetime<'de, D>(
    deserializer: D,
) -> std::result::Result<DateTime<Utc>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    decode_swift_datetime(&value).ok_or_else(|| {
        serde::de::Error::custom("expected Swift reference seconds or an RFC3339 date")
    })
}

fn serialize_optional_swift_datetime<S>(
    value: &Option<DateTime<Utc>>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match value {
        Some(value) => serialize_swift_datetime(value, serializer),
        None => serializer.serialize_none(),
    }
}

fn deserialize_optional_swift_datetime<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<DateTime<Utc>>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    match value {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(value) => decode_swift_datetime(&value).map(Some).ok_or_else(|| {
            serde::de::Error::custom("expected Swift reference seconds or an RFC3339 date")
        }),
    }
}

fn decode_swift_datetime(value: &serde_json::Value) -> Option<DateTime<Utc>> {
    if let Some(swift_seconds) = value
        .as_f64()
        .or_else(|| value.as_str().and_then(|value| value.parse::<f64>().ok()))
    {
        let unix_millis = ((swift_seconds + UNIX_TO_SWIFT_REFERENCE_SECONDS) * 1000.0).round();
        return DateTime::<Utc>::from_timestamp_millis(unix_millis as i64);
    }
    value
        .as_str()
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{
        lock_account_store, save_accounts, QuotaSnapshot, QuotaWindow, QuotaWindowKind,
        QuotaWindowRateLimitSource, QuotaWindowSlot, QuotaWindowSourceMetadata,
    };
    use anyhow::anyhow;
    use serde_json::json;
    use std::fs::{self, OpenOptions};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;

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
                fetched_at: Utc::now() - ChronoDuration::seconds(1),
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

    fn bank(now: DateTime<Utc>, expirations: &[ChronoDuration]) -> RateLimitResetBank {
        RateLimitResetBank {
            available_count: expirations.len() as u32,
            total_earned_count: expirations.len() as u32,
            credits: expirations
                .iter()
                .enumerate()
                .map(|(index, expiration)| RateLimitResetCredit {
                    id: format!("credit-{index}"),
                    reset_type: Some("full".to_string()),
                    status: "available".to_string(),
                    granted_at: Some(now - ChronoDuration::days(1)),
                    expires_at: Some(now + *expiration),
                    redeem_started_at: None,
                    redeemed_at: None,
                    title: Some("Full reset (Weekly + 5 hr)".to_string()),
                    description: None,
                })
                .collect(),
            fetched_at: now,
        }
    }

    fn fixed_policy_now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-07-12T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    fn policy_account(
        email: &str,
        active: bool,
        plan: &str,
        weekly_used: f64,
        weekly_reset_after: ChronoDuration,
        has_banked_reset: bool,
        now: DateTime<Utc>,
    ) -> CodexAccount {
        let mut account = account(email, active, 20.0, weekly_used);
        account.plan_type = Some(plan.to_string());
        let snapshot = account.quota_snapshot.as_mut().unwrap();
        snapshot.fetched_at = now;
        snapshot.weekly_mut().unwrap().resets_at = now + weekly_reset_after;
        if has_banked_reset {
            account.rate_limit_reset_bank = Some(bank(now, &[ChronoDuration::days(10)]));
        }
        account
    }

    fn consumed_bank(mut bank: RateLimitResetBank, now: DateTime<Utc>) -> RateLimitResetBank {
        bank.available_count = bank.available_count.saturating_sub(1);
        bank.fetched_at = now;
        if let Some(credit) = bank.credits.first_mut() {
            credit.status = "redeemed".to_string();
            credit.redeemed_at = Some(now);
        }
        bank
    }

    fn make_quota_usable(account: &mut CodexAccount, fetched_at: DateTime<Utc>) {
        let snapshot = account.quota_snapshot.as_mut().unwrap();
        let five_hour = snapshot.five_hour_mut().unwrap();
        five_hour.used_percent = 0.0;
        five_hour.hard_limit_reached = false;
        let weekly = snapshot.weekly_mut().unwrap();
        weekly.used_percent = 0.0;
        weekly.hard_limit_reached = false;
        snapshot.allowed = Some(true);
        snapshot.limit_reached = Some(false);
        snapshot.fetched_at = fetched_at;
    }

    fn make_quota_precede_attempt(account: &mut CodexAccount, attempt_at: DateTime<Utc>) {
        account.quota_snapshot.as_mut().unwrap().fetched_at =
            attempt_at - ChronoDuration::seconds(1);
    }

    fn assert_advisory_lock_available(path: &Path, label: &str) -> Result<()> {
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            bail!(
                "{label} was held during provider callback: {}",
                std::io::Error::last_os_error()
            );
        }
        let unlock_result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        if unlock_result != 0 {
            bail!(
                "failed to release {label} probe: {}",
                std::io::Error::last_os_error()
            );
        }
        Ok(())
    }

    fn assert_reset_locks_available(store_path: &Path) -> Result<()> {
        assert_advisory_lock_available(
            &store_path.with_extension("json.lock"),
            "account-store lock",
        )?;
        let journal_path = reset_attempt_journal_path(store_path);
        let mut journal_lock = journal_path.as_os_str().to_os_string();
        journal_lock.push(".lock");
        assert_advisory_lock_available(Path::new(&journal_lock), "reset-journal lock")
    }

    #[test]
    fn inventory_evidence_requires_a_new_generation_and_unambiguous_consumption() {
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let initial = bank(now, &[ChronoDuration::days(10), ChronoDuration::days(20)]);
        let attempt = new_reset_attempt(
            &account,
            &initial,
            Some("credit-0".to_string()),
            Uuid::new_v4(),
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Uncertain,
        );

        let mut missing_same_count = initial.clone();
        missing_same_count.fetched_at = now + ChronoDuration::seconds(1);
        missing_same_count.credits.remove(0);
        assert!(inventory_is_newer_than_attempt(
            &attempt,
            &missing_same_count
        ));
        assert!(!inventory_is_consumed(
            &attempt,
            &missing_same_count,
            missing_same_count.fetched_at
        ));

        let mut terminal_same_count = initial.clone();
        terminal_same_count.fetched_at = now + ChronoDuration::seconds(1);
        terminal_same_count.credits[0].status = "redeemed".to_string();
        assert!(inventory_is_consumed(
            &attempt,
            &terminal_same_count,
            terminal_same_count.fetched_at
        ));

        let mut decreased_but_not_newer = initial.clone();
        decreased_but_not_newer.available_count -= 1;
        assert!(!inventory_is_newer_than_attempt(
            &attempt,
            &decreased_but_not_newer
        ));
    }

    #[test]
    fn terminal_journal_entries_are_aged_and_capped_without_dropping_unresolved() -> Result<()> {
        let temp = TempDir::new()?;
        let path = temp.path().join("reset-attempts.json");
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let initial = bank(now, &[ChronoDuration::days(10)]);
        let mut journal = ResetAttemptJournal::default();

        for index in 0..80 {
            let mut attempt = new_reset_attempt(
                &account,
                &initial,
                Some("credit-0".to_string()),
                Uuid::new_v4(),
                now - ChronoDuration::hours(index),
                ResetAttemptOrigin::LocalRequest,
                ResetAttemptState::ReconciledUsable,
            );
            if index >= 75 {
                attempt.started_at = now - ChronoDuration::days(45);
            }
            journal.attempts.push(attempt);
        }
        for index in 0..3 {
            journal.attempts.push(new_reset_attempt(
                &account,
                &initial,
                Some("credit-0".to_string()),
                Uuid::new_v4(),
                now - ChronoDuration::days(60 + index),
                ResetAttemptOrigin::LocalRequest,
                ResetAttemptState::Uncertain,
            ));
        }

        save_reset_attempt_journal(&path, &mut journal, now)?;
        let persisted = load_reset_attempt_journal(&path)?;
        assert_eq!(
            persisted
                .attempts
                .iter()
                .filter(|attempt| attempt.state.is_terminal())
                .count(),
            RESET_TERMINAL_ENTRY_CAP
        );
        assert_eq!(
            persisted
                .attempts
                .iter()
                .filter(|attempt| !attempt.state.is_terminal())
                .count(),
            3
        );
        Ok(())
    }

    #[test]
    fn parses_inventory_and_selects_earliest_expiration() -> Result<()> {
        let now = DateTime::parse_from_rfc3339("2026-07-12T12:00:00Z")?.with_timezone(&Utc);
        let response = json!({
            "available_count": 2,
            "total_earned_count": 3,
            "credits": [
                {
                    "id": "later",
                    "status": "available",
                    "reset_type": "full",
                    "expires_at": "2026-07-20T12:00:00Z"
                },
                {
                    "id": "earlier",
                    "status": "available",
                    "reset_type": "full",
                    "expires_at": "2026-07-13T12:00:00.123Z"
                }
            ]
        });
        let parsed = fetch_rate_limit_reset_bank_with(
            &account("a@example.com", true, 10.0, 10.0),
            |_| {
                Ok(HttpResponse {
                    status: 200,
                    body: serde_json::to_vec(&response)?,
                })
            },
            || now,
        )?;

        assert_eq!(parsed.available_count, 2);
        assert_eq!(parsed.total_earned_count, 3);
        assert_eq!(
            parsed
                .oldest_expiring_available_credit(now)
                .map(|credit| credit.id.as_str()),
            Some("earlier")
        );
        Ok(())
    }

    #[test]
    fn malformed_inventory_is_rejected() {
        let now = Utc::now();
        let error = fetch_rate_limit_reset_bank_with(
            &account("a@example.com", true, 10.0, 10.0),
            |_| {
                Ok(HttpResponse {
                    status: 200,
                    body: br#"{"available_count":3}"#.to_vec(),
                })
            },
            || now,
        )
        .unwrap_err();
        assert!(error.to_string().contains("decode reset-bank"));
    }

    #[test]
    fn inventory_timestamp_is_captured_after_response_completion() -> Result<()> {
        let request_started_at = fixed_policy_now();
        let response_completed_at = request_started_at + ChronoDuration::seconds(30);
        let response = json!({
            "available_count": 0,
            "total_earned_count": 1,
            "credits": []
        });
        let events = Arc::new(Mutex::new(Vec::new()));
        let fetch_events = Arc::clone(&events);
        let completion_events = Arc::clone(&events);

        let parsed = fetch_rate_limit_reset_bank_with(
            &account("a@example.com", true, 10.0, 10.0),
            move |_| {
                fetch_events.lock().unwrap().push("response");
                Ok(HttpResponse {
                    status: 200,
                    body: serde_json::to_vec(&response)?,
                })
            },
            move || {
                completion_events.lock().unwrap().push("completed_at");
                response_completed_at
            },
        )?;

        assert_eq!(parsed.fetched_at, response_completed_at);
        assert_eq!(*events.lock().unwrap(), ["response", "completed_at"]);
        Ok(())
    }

    #[test]
    fn count_only_inventory_is_observable_but_never_redeemable() -> Result<()> {
        let now = fixed_policy_now();
        let count_only = RateLimitResetBank {
            available_count: 1,
            total_earned_count: 1,
            credits: Vec::new(),
            fetched_at: now,
        };
        assert_eq!(count_only.available_count, 1);
        assert!(!count_only.has_available_reset(now));

        let mut empty_identifier = bank(now, &[ChronoDuration::days(10)]);
        empty_identifier.credits[0].id = "  ".to_string();
        assert!(!empty_identifier.has_available_reset(now));

        let mut missing_expiration = bank(now, &[ChronoDuration::days(10)]);
        missing_expiration.credits[0].expires_at = None;
        assert!(!missing_expiration.has_available_reset(now));

        let mut oversized_identifier = bank(now, &[ChronoDuration::days(10)]);
        oversized_identifier.credits[0].id = "x".repeat(RESET_IDENTIFIER_MAX_BYTES + 1);
        assert!(!oversized_identifier.has_available_reset(now));

        let mut active = policy_account(
            "active@example.com",
            true,
            "pro",
            100.0,
            ChronoDuration::days(3),
            false,
            now,
        );
        active.rate_limit_reset_bank = Some(count_only.clone());
        let accounts = vec![active.clone()];
        assert_eq!(
            select_smart_reset_candidate(&accounts, 0, false, now, None),
            None
        );
        assert_eq!(
            smart_reset_reason(&active, &accounts, &count_only, false, now),
            None
        );

        let send_calls = Arc::new(Mutex::new(0usize));
        let send_calls_for_closure = Arc::clone(&send_calls);
        let error = consume_rate_limit_reset_with(
            &active,
            &count_only,
            now,
            Uuid::new_v4(),
            move |_account, _request| {
                *send_calls_for_closure.lock().unwrap() += 1;
                Ok(HttpResponse {
                    status: 200,
                    body: br#"{"code":"reset"}"#.to_vec(),
                })
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("no concrete unexpired available credit"));
        assert_eq!(*send_calls.lock().unwrap(), 0);

        let oversized_send_calls = Arc::new(Mutex::new(0usize));
        let oversized_send_calls_for_closure = Arc::clone(&oversized_send_calls);
        let error = consume_rate_limit_reset_with(
            &active,
            &oversized_identifier,
            now,
            Uuid::new_v4(),
            move |_account, _request| {
                *oversized_send_calls_for_closure.lock().unwrap() += 1;
                Ok(HttpResponse {
                    status: 200,
                    body: br#"{"code":"reset"}"#.to_vec(),
                })
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("no concrete unexpired available credit"));
        assert_eq!(*oversized_send_calls.lock().unwrap(), 0);

        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        let store_lock = lock_account_store(&store_path)?;
        let mut working_account = store_lock.load()?.accounts.remove(0);
        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut working_account,
                previous_bank: None,
                observed_bank: oversized_identifier,
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("malformed inventory must not trigger an inventory callback"),
                |_account| bail!("malformed inventory must not trigger a quota callback"),
                |_account, _bank, _request_id| {
                    bail!("malformed inventory must not trigger a reset POST")
                },
            ),
        )?;
        assert_eq!(flow.state, ResetFlowState::NoAttempt);
        let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
        assert!(journal.attempts.is_empty());
        assert!(journal.manual_review.is_none());
        Ok(())
    }

    #[test]
    fn weekly_exhaustion_rotates_to_same_tier_before_spending_reset() {
        let now = Utc::now();
        let active = account("active@example.com", true, 10.0, 99.0);
        let replacement = account("ready@example.com", false, 10.0, 10.0);
        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), replacement],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            None
        );
    }

    #[test]
    fn pool_selector_redeems_inactive_pro_ahead_of_active_usable_plus() {
        let now = fixed_policy_now();
        let active_plus = policy_account(
            "plus@example.com",
            true,
            "plus",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );
        let exhausted_pro = policy_account(
            "pro@example.com",
            false,
            "pro",
            100.0,
            ChronoDuration::hours(36),
            true,
            now,
        );
        let accounts = vec![active_plus, exhausted_pro];

        assert_eq!(
            select_smart_reset_candidate(&accounts, 0, false, now, None),
            Some(SmartResetCandidate {
                account_index: 1,
                reason: SmartResetReason::PreserveFasterTier,
            })
        );
    }

    #[test]
    fn pool_selector_preserves_pro_credit_at_twenty_four_hour_boundary() {
        let now = fixed_policy_now();
        let active_plus = policy_account(
            "plus@example.com",
            true,
            "plus",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );

        for (reset_after, expected) in [
            (ChronoDuration::hours(24), None),
            (
                ChronoDuration::hours(24) + ChronoDuration::seconds(1),
                Some(SmartResetCandidate {
                    account_index: 1,
                    reason: SmartResetReason::PreserveFasterTier,
                }),
            ),
        ] {
            let exhausted_pro = policy_account(
                "pro@example.com",
                false,
                "pro",
                100.0,
                reset_after,
                true,
                now,
            );
            let accounts = vec![active_plus.clone(), exhausted_pro];

            assert_eq!(
                select_smart_reset_candidate(&accounts, 0, false, now, None),
                expected
            );
        }
    }

    #[test]
    fn pool_selector_waits_for_quota_confirmation_at_and_after_natural_reset() {
        let now = fixed_policy_now();

        for reset_after in [ChronoDuration::zero(), ChronoDuration::seconds(-1)] {
            let exhausted_pro = policy_account(
                "pro@example.com",
                true,
                "pro",
                100.0,
                reset_after,
                true,
                now,
            );

            assert_eq!(
                select_smart_reset_candidate(&[exhausted_pro], 0, false, now, None),
                None
            );
        }
    }

    #[test]
    fn pool_selector_counts_active_same_or_higher_tier_capacity() {
        let now = fixed_policy_now();
        let active_pro = policy_account(
            "active-pro@example.com",
            true,
            "pro",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );
        let exhausted_plus = policy_account(
            "exhausted-plus@example.com",
            false,
            "plus",
            100.0,
            ChronoDuration::days(3),
            true,
            now,
        );

        assert_eq!(
            select_smart_reset_candidate(&[active_pro, exhausted_plus], 0, false, now, None),
            None
        );
    }

    #[test]
    fn pool_selector_does_not_spend_when_another_pro_is_usable() {
        let now = fixed_policy_now();
        let active_plus = policy_account(
            "plus@example.com",
            true,
            "plus",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );
        let exhausted_pro = policy_account(
            "exhausted-pro@example.com",
            false,
            "pro",
            100.0,
            ChronoDuration::days(3),
            true,
            now,
        );
        let usable_pro = policy_account(
            "usable-pro@example.com",
            false,
            "pro",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );

        assert_eq!(
            select_smart_reset_candidate(
                &[active_plus, exhausted_pro, usable_pro],
                0,
                false,
                now,
                None,
            ),
            None
        );
    }

    #[test]
    fn pool_selector_ranks_plan_expiration_then_stable_identity() {
        let now = fixed_policy_now();
        let active_free = policy_account(
            "free@example.com",
            true,
            "free",
            20.0,
            ChronoDuration::days(3),
            false,
            now,
        );
        let exhausted_plus = policy_account(
            "plus@example.com",
            false,
            "plus",
            100.0,
            ChronoDuration::days(3),
            true,
            now,
        );
        let mut alpha_pro = policy_account(
            "alpha@example.com",
            false,
            "pro",
            100.0,
            ChronoDuration::days(3),
            true,
            now,
        );
        let mut zulu_pro = policy_account(
            "zulu@example.com",
            false,
            "pro",
            100.0,
            ChronoDuration::days(3),
            true,
            now,
        );
        alpha_pro.rate_limit_reset_bank = Some(bank(now, &[ChronoDuration::days(10)]));
        zulu_pro.rate_limit_reset_bank = Some(bank(now, &[ChronoDuration::days(2)]));

        let forward = vec![
            active_free.clone(),
            exhausted_plus.clone(),
            zulu_pro.clone(),
            alpha_pro.clone(),
        ];
        let reverse = vec![active_free, alpha_pro, zulu_pro, exhausted_plus];

        assert_eq!(
            select_smart_reset_candidate(&forward, 0, false, now, None)
                .map(|candidate| forward[candidate.account_index].email.as_str()),
            Some("zulu@example.com")
        );
        assert_eq!(
            select_smart_reset_candidate(&reverse, 0, false, now, None)
                .map(|candidate| reverse[candidate.account_index].email.as_str()),
            Some("zulu@example.com")
        );
    }

    #[test]
    fn pro_spends_reset_before_falling_to_plus_when_natural_reset_is_not_close() {
        let now = Utc::now();
        let mut active = account("active@example.com", true, 10.0, 100.0);
        active
            .quota_snapshot
            .as_mut()
            .unwrap()
            .weekly_mut()
            .unwrap()
            .resets_at = now + ChronoDuration::hours(36);
        let mut replacement = account("plus@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("plus".to_string());

        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), replacement],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            Some(SmartResetReason::PreserveFasterTier)
        );
    }

    #[test]
    fn near_natural_reset_is_protected_when_plus_can_bridge_the_gap() {
        let now = Utc::now();
        let mut active = account("active@example.com", true, 10.0, 100.0);
        active
            .quota_snapshot
            .as_mut()
            .unwrap()
            .weekly_mut()
            .unwrap()
            .resets_at = now + ChronoDuration::hours(12);
        let mut replacement = account("plus@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("plus".to_string());

        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), replacement],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            None
        );
    }

    #[test]
    fn natural_reset_guard_includes_exact_twenty_four_hour_boundary() {
        let now = Utc::now();
        let mut replacement = account("plus@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("plus".to_string());
        for (offset, expected) in [
            (ChronoDuration::hours(24), None),
            (
                ChronoDuration::hours(24) + ChronoDuration::seconds(1),
                Some(SmartResetReason::PreserveFasterTier),
            ),
        ] {
            let mut active = account("active@example.com", true, 10.0, 100.0);
            active
                .quota_snapshot
                .as_mut()
                .unwrap()
                .weekly_mut()
                .unwrap()
                .resets_at = now + offset;

            assert_eq!(
                smart_reset_reason(
                    &active,
                    &[active.clone(), replacement.clone()],
                    &bank(now, &[ChronoDuration::days(10)]),
                    false,
                    now,
                ),
                expected
            );
        }
    }

    #[test]
    fn pool_exhaustion_overrides_near_natural_reset_protection() {
        let now = Utc::now();
        let mut active = account("active@example.com", true, 10.0, 100.0);
        active
            .quota_snapshot
            .as_mut()
            .unwrap()
            .weekly_mut()
            .unwrap()
            .resets_at = now + ChronoDuration::hours(12);
        let blocked = account("blocked@example.com", false, 100.0, 100.0);

        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), blocked],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            Some(SmartResetReason::WeeklyExhausted)
        );
    }

    #[test]
    fn weekly_only_exhausted_or_denied_snapshot_uses_weekly_reset_policy() {
        let now = Utc::now();
        let mut active = account("active@example.com", true, 10.0, 100.0);
        active
            .quota_snapshot
            .as_mut()
            .unwrap()
            .windows
            .retain(|window| window.kind == QuotaWindowKind::Weekly);

        assert_eq!(
            smart_reset_reason(
                &active,
                std::slice::from_ref(&active),
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            Some(SmartResetReason::WeeklyExhausted)
        );

        let snapshot = active.quota_snapshot.as_mut().unwrap();
        snapshot.weekly_mut().unwrap().used_percent = 30.0;
        snapshot.allowed = Some(false);
        snapshot.limit_reached = Some(true);
        assert_eq!(
            smart_reset_reason(
                &active,
                std::slice::from_ref(&active),
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            Some(SmartResetReason::WeeklyExhausted)
        );
    }

    #[test]
    fn five_hour_only_exhaustion_rotates_when_replacement_is_ready() {
        let now = Utc::now();
        let active = account("active@example.com", true, 100.0, 20.0);
        let replacement = account("ready@example.com", false, 10.0, 10.0);
        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), replacement],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            None
        );
    }

    #[test]
    fn shared_natural_reset_guard_fixture_preserves_credit() -> Result<()> {
        let fixture: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Policy/natural-reset-guard.json"
        ))?;
        let now = decode_swift_datetime(&fixture["now"]).unwrap();
        let active: CodexAccount = serde_json::from_value(fixture["active"].clone())?;
        let replacement: CodexAccount = serde_json::from_value(fixture["replacement"].clone())?;
        let bank: RateLimitResetBank = serde_json::from_value(fixture["bank"].clone())?;

        assert_eq!(
            smart_reset_reason(&active, &[active.clone(), replacement], &bank, false, now),
            None
        );
        assert_eq!(
            blocking_natural_reset_at(&active, now),
            Some(now + ChronoDuration::hours(1))
        );
        Ok(())
    }

    #[test]
    fn no_ready_replacement_spends_reset_for_exhausted_window() {
        let now = Utc::now();
        let active = account("active@example.com", true, 100.0, 20.0);
        let blocked = account("blocked@example.com", false, 100.0, 100.0);
        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), blocked],
                &bank(now, &[ChronoDuration::days(10)]),
                false,
                now,
            ),
            Some(SmartResetReason::NoImmediatelyUsableAccount)
        );
    }

    #[test]
    fn direct_runtime_limit_requires_no_ready_replacement() {
        let now = Utc::now();
        let active = account("active@example.com", true, 10.0, 10.0);
        assert_eq!(
            smart_reset_reason(
                &active,
                std::slice::from_ref(&active),
                &bank(now, &[ChronoDuration::days(10)]),
                true,
                now,
            ),
            Some(SmartResetReason::RuntimeUsageLimitNoReplacement)
        );
    }

    #[test]
    fn same_tier_replacement_still_preserves_expiring_credit() {
        let now = Utc::now();
        let mut active = account("active@example.com", true, 20.0, 100.0);
        let replacement = account("ready@example.com", false, 10.0, 10.0);
        assert_eq!(
            smart_reset_reason(
                &active,
                &[active.clone(), replacement],
                &bank(now, &[ChronoDuration::hours(12)]),
                false,
                now,
            ),
            None
        );

        active
            .quota_snapshot
            .as_mut()
            .unwrap()
            .weekly_mut()
            .unwrap()
            .used_percent = 10.0;
        assert_eq!(
            smart_reset_reason(
                &active,
                std::slice::from_ref(&active),
                &bank(now, &[ChronoDuration::hours(12)]),
                false,
                now,
            ),
            None
        );
    }

    #[test]
    fn expiring_credit_is_used_for_five_hour_exhaustion_without_replacement() {
        let now = Utc::now();
        let active = account("active@example.com", true, 100.0, 20.0);

        assert_eq!(
            smart_reset_reason(
                &active,
                std::slice::from_ref(&active),
                &bank(now, &[ChronoDuration::hours(12)]),
                false,
                now,
            ),
            Some(SmartResetReason::ExpiringSoon)
        );
    }

    #[test]
    fn uncertain_transport_sends_exactly_once() -> Result<()> {
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let request_id = Uuid::parse_str("5b1836ab-1eec-4c2d-b08e-4ba5fb6ec8c9")?;
        let seen = Arc::new(Mutex::new(Vec::new()));
        let seen_for_closure = Arc::clone(&seen);
        let error = consume_rate_limit_reset_with(
            &account,
            &bank(now, &[ChronoDuration::days(10)]),
            now,
            request_id,
            move |_account, body| {
                seen_for_closure
                    .lock()
                    .unwrap()
                    .push((body.redeem_request_id, body.credit_id.to_string()));
                Err(anyhow!("connection reset after write"))
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("outcome is uncertain"));
        assert_eq!(
            seen.lock().unwrap().as_slice(),
            &[(request_id, "credit-0".to_string())]
        );
        Ok(())
    }

    #[test]
    fn reset_provider_callbacks_run_without_store_or_journal_locks() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let reconciled_bank = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(1));
        let mut stored_account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut stored_account, now);
        save_accounts(&store_path, std::slice::from_ref(&stored_account))?;

        let store_lock = lock_account_store(&store_path)?;
        let mut working_account = store_lock.load()?.accounts.remove(0);
        let callback_order = Arc::new(Mutex::new(Vec::new()));
        let bank_path = store_path.clone();
        let bank_callbacks = Arc::clone(&callback_order);
        let quota_path = store_path.clone();
        let quota_callbacks = Arc::clone(&callback_order);
        let consume_path = store_path.clone();
        let consume_callbacks = Arc::clone(&callback_order);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut working_account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                move |_account| {
                    assert_reset_locks_available(&bank_path)?;
                    bank_callbacks.lock().unwrap().push("bank");
                    Ok(reconciled_bank.clone())
                },
                move |account| {
                    assert_reset_locks_available(&quota_path)?;
                    quota_callbacks.lock().unwrap().push("quota");
                    make_quota_usable(account, now + ChronoDuration::seconds(2));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    assert_reset_locks_available(&consume_path)?;
                    assert!(
                        acquire_provider_io_lease(&consume_path).is_err(),
                        "reset POST callback ran without the provider-I/O lease"
                    );
                    consume_callbacks.lock().unwrap().push("consume");
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )?;

        assert!(flow.is_usable_success());
        assert_eq!(
            callback_order.lock().unwrap().as_slice(),
            &["consume", "bank", "quota"]
        );
        Ok(())
    }

    #[test]
    fn store_generation_race_preserves_prepared_attempt_and_never_reconsumes() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let reconciled_bank = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(1));
        let mut stored_account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut stored_account, now);
        save_accounts(&store_path, std::slice::from_ref(&stored_account))?;

        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut working_account = snapshot.accounts[0].clone();
        let mut concurrent_account = snapshot.accounts[0].clone();
        concurrent_account.runtime_unusable_reason = Some("concurrent-mutation".to_string());
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_callback = Arc::clone(&consume_calls);
        let mutation_path = store_path.clone();

        let error = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut working_account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("store race must stop before inventory reconciliation"),
                |_account| bail!("store race must stop before quota reconciliation"),
                move |_account, _bank, _request_id| {
                    assert_reset_locks_available(&mutation_path)?;
                    *consume_calls_for_callback.lock().unwrap() += 1;
                    save_accounts(&mutation_path, std::slice::from_ref(&concurrent_account))?;
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("account store changed during reset provider I/O"));
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
        assert_eq!(journal.attempts.len(), 1);
        assert_eq!(journal.attempts[0].state, ResetAttemptState::Prepared);
        assert!(journal.manual_review.is_none());

        drop(store_lock);
        let replay_lock = lock_account_store(&store_path)?;
        let mut replay_account = replay_lock.load()?.accounts.remove(0);
        let replay_consume_calls = Arc::clone(&consume_calls);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &replay_lock,
                account: &mut replay_account,
                previous_bank: Some(&initial_bank),
                observed_bank: reconciled_bank.clone(),
                attempt_reset: true,
                now: now + ChronoDuration::seconds(2),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(reconciled_bank.clone()),
                |account| {
                    make_quota_usable(account, now + ChronoDuration::seconds(3));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_consume_calls.lock().unwrap() += 1;
                    bail!("journal replay must never issue a second consume request")
                },
            ),
        )?;

        assert!(replay.is_usable_success());
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn journal_identity_race_fails_closed_and_suppresses_reconsume() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let journal_path = reset_attempt_journal_path(&store_path);
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut stored_account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut stored_account, now);
        save_accounts(&store_path, std::slice::from_ref(&stored_account))?;

        let store_lock = lock_account_store(&store_path)?;
        let mut working_account = store_lock.load()?.accounts.remove(0);
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_callback = Arc::clone(&consume_calls);
        let callback_store_path = store_path.clone();
        let callback_journal_path = journal_path.clone();
        let error = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut working_account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("journal race must stop before inventory reconciliation"),
                |_account| bail!("journal race must stop before quota reconciliation"),
                move |_account, _bank, _request_id| {
                    assert_reset_locks_available(&callback_store_path)?;
                    *consume_calls_for_callback.lock().unwrap() += 1;
                    let (mut transaction, mut journal) =
                        ResetJournalTransaction::open(&callback_journal_path, now)?;
                    let attempt = journal
                        .attempts
                        .last_mut()
                        .context("prepared reset attempt disappeared before concurrent mutation")?;
                    attempt.state = ResetAttemptState::Uncertain;
                    attempt.last_error = Some("concurrent reconciler updated attempt".to_string());
                    transaction.save(&mut journal, now)?;
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("reset attempt"));
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        let journal = load_reset_attempt_journal(&journal_path)?;
        assert_eq!(journal.attempts.len(), 1);
        assert_eq!(journal.attempts[0].state, ResetAttemptState::Uncertain);
        assert!(journal.manual_review.is_some());

        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut working_account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now: now + ChronoDuration::seconds(1),
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("manual review must block inventory I/O"),
                |_account| bail!("manual review must block quota I/O"),
                |_account, _bank, _request_id| {
                    bail!("manual review must block a second consume request")
                },
            ),
        )?;
        assert!(replay.suppresses_redemption());
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn timeout_is_journaled_before_io_and_suppresses_redemption() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let journal_path = reset_attempt_journal_path(&store_path);
        let now = DateTime::parse_from_rfc3339("2026-07-12T12:00:00Z")?.with_timezone(&Utc);
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let calls = Arc::new(Mutex::new(0usize));
        let calls_for_closure = Arc::clone(&calls);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |request_account, _bank, request_id| {
                    *calls_for_closure.lock().unwrap() += 1;
                    let journal_data = fs::read(&journal_path)?;
                    assert!(journal_data.len() <= RESET_ATTEMPT_JOURNAL_MAX_BYTES);
                    let journal: ResetAttemptJournal = serde_json::from_slice(&journal_data)?;
                    let attempt = journal.attempts.last().unwrap();
                    assert_eq!(attempt.state, ResetAttemptState::Prepared);
                    assert_eq!(attempt.request_id, request_id);
                    assert_eq!(attempt.pre_inventory_count, 1);
                    assert!(!attempt.pre_inventory_generation.is_empty());
                    assert_eq!(
                        attempt.selected_credit_expires_at,
                        Some(now + ChronoDuration::days(10))
                    );
                    assert_eq!(
                        attempt.pre_available_credit_ids,
                        vec!["credit-0".to_string()]
                    );
                    assert!(reset_attempt_has_complete_inventory_evidence(attempt));
                    assert_eq!(
                        attempt.stable_owner.as_deref(),
                        Some(reset_attempt_owner(request_account).as_str())
                    );
                    assert_eq!(
                        attempt.starting_quota_generation.as_deref(),
                        Some(quota_evidence_generation(request_account).as_str())
                    );
                    assert_eq!(attempt.account_id, "active@example.com");
                    assert_eq!(
                        attempt.reconciliation_deadline,
                        now + RESET_RECONCILIATION_INTERVAL
                    );
                    Err(anyhow!("timed out after request write"))
                },
            ),
        )?;

        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(!flow.consumption_observed);
        assert!(!flow.is_usable_success());
        assert_eq!(*calls.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn malformed_success_is_uncertain_and_never_usable_success() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                |account, bank, request_id| {
                    consume_rate_limit_reset_with(
                        account,
                        bank,
                        now,
                        request_id,
                        |_account, _body| {
                            Ok(HttpResponse {
                                status: 200,
                                body: br#"{"accepted":true}"#.to_vec(),
                            })
                        },
                    )
                },
            ),
        )?;

        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(!flow.consumption_observed);
        assert!(flow
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("decode reset-consume response")));
        Ok(())
    }

    #[test]
    fn accepted_reset_without_inventory_consumption_is_not_usable_success() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |account| {
                    make_quota_usable(account, now + ChronoDuration::seconds(1));
                    Ok(())
                },
                |_account, _bank, _request_id| {
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )?;

        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(!flow.consumption_observed);
        assert!(flow.quota_reconciled);
        assert!(!flow.is_usable_success());
        Ok(())
    }

    #[test]
    fn server_error_is_uncertain_and_never_retried() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let calls = Arc::new(Mutex::new(0usize));
        let calls_for_closure = Arc::clone(&calls);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |account, bank, request_id| {
                    *calls_for_closure.lock().unwrap() += 1;
                    consume_rate_limit_reset_with(
                        account,
                        bank,
                        now,
                        request_id,
                        |_account, _body| {
                            Ok(HttpResponse {
                                status: 503,
                                body: Vec::new(),
                            })
                        },
                    )
                },
            ),
        )?;

        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert_eq!(*calls.lock().unwrap(), 1);
        assert!(flow
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("HTTP 503")));
        Ok(())
    }

    #[test]
    fn inventory_consumption_with_exhausted_quota_is_not_success() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let after_consume = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(1));
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(after_consume.clone()),
                |account| {
                    account.quota_snapshot.as_mut().unwrap().fetched_at =
                        now + ChronoDuration::seconds(1);
                    Ok(())
                },
                |_account, _bank, _request_id| {
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )?;

        assert!(flow.consumption_observed);
        assert!(!flow.quota_reconciled);
        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(!flow.is_usable_success());
        assert!(flow
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("evidence generation")));
        Ok(())
    }

    #[test]
    fn inventory_consumption_with_quota_fetch_failure_is_not_success() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let after_consume = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(1));
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(after_consume.clone()),
                |_account| bail!("quota endpoint unavailable"),
                |_account, _bank, _request_id| {
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )?;

        assert!(flow.consumption_observed);
        assert!(!flow.quota_reconciled);
        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(flow
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("quota endpoint unavailable")));
        Ok(())
    }

    #[test]
    fn delayed_inventory_decrease_reconciles_without_a_second_request() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let delayed_bank = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(30));
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let calls = Arc::new(Mutex::new(0usize));
        let calls_for_first = Arc::clone(&calls);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *calls_for_first.lock().unwrap() += 1;
                    Err(anyhow!("timeout"))
                },
            ),
        )?;
        assert_eq!(first.state, ResetFlowState::Suppressed);

        let calls_for_second = Arc::clone(&calls);
        let second = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&initial_bank),
                observed_bank: delayed_bank.clone(),
                attempt_reset: true,
                now: now + ChronoDuration::seconds(30),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(delayed_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *calls_for_second.lock().unwrap() += 1;
                    bail!("a delayed decrease must suppress another POST")
                },
            ),
        )?;

        assert_eq!(second.state, ResetFlowState::Suppressed);
        assert!(second.consumption_observed);
        assert!(!second.quota_reconciled);
        assert!(second
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("no snapshot newer")));
        assert_eq!(*calls.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn selected_credit_natural_expiration_remains_unresolved_without_a_second_post() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = fixed_policy_now();
        let initial_bank = bank(now, &[ChronoDuration::seconds(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let posts = Arc::new(Mutex::new(0usize));
        let first_posts = Arc::clone(&posts);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *first_posts.lock().unwrap() += 1;
                    Err(anyhow!("timeout"))
                },
            ),
        )?;
        assert_eq!(first.state, ResetFlowState::Suppressed);

        let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
        let attempt = journal.attempts.last().unwrap();
        assert_eq!(
            attempt.selected_credit_expires_at,
            Some(now + ChronoDuration::seconds(10))
        );
        assert_eq!(
            attempt.pre_available_credit_ids,
            vec!["credit-0".to_string()]
        );

        let observed_at = now + ChronoDuration::seconds(20);
        let expired_bank = RateLimitResetBank {
            available_count: 0,
            total_earned_count: 1,
            credits: Vec::new(),
            fetched_at: now + ChronoDuration::seconds(5),
        };
        let replay_posts = Arc::clone(&posts);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&initial_bank),
                observed_bank: expired_bank.clone(),
                attempt_reset: true,
                now: observed_at,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(expired_bank.clone()),
                |account| {
                    make_quota_usable(account, observed_at + ChronoDuration::seconds(1));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_posts.lock().unwrap() += 1;
                    bail!("natural expiry reconciliation must not issue a second POST")
                },
            ),
        )?;

        assert_eq!(replay.state, ResetFlowState::Suppressed);
        assert!(!replay.consumption_observed);
        assert!(replay.quota_reconciled);
        assert_eq!(*posts.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn different_credit_disappearance_cannot_prove_the_selected_redemption() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = fixed_policy_now();
        let initial_bank = bank(now, &[ChronoDuration::days(10), ChronoDuration::days(20)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let posts = Arc::new(Mutex::new(0usize));
        let first_posts = Arc::clone(&posts);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *first_posts.lock().unwrap() += 1;
                    Err(anyhow!("timeout"))
                },
            ),
        )?;
        assert_eq!(first.state, ResetFlowState::Suppressed);

        let observed_at = now + ChronoDuration::seconds(30);
        let mut wrong_credit_removed = initial_bank.clone();
        wrong_credit_removed.available_count = 1;
        wrong_credit_removed.credits.remove(1);
        wrong_credit_removed.fetched_at = observed_at;
        let replay_posts = Arc::clone(&posts);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&initial_bank),
                observed_bank: wrong_credit_removed.clone(),
                attempt_reset: true,
                now: observed_at,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(wrong_credit_removed.clone()),
                |account| {
                    make_quota_usable(account, observed_at + ChronoDuration::seconds(1));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_posts.lock().unwrap() += 1;
                    bail!("wrong-credit reconciliation must not issue a second POST")
                },
            ),
        )?;

        assert_eq!(replay.state, ResetFlowState::Suppressed);
        assert!(!replay.consumption_observed);
        assert_eq!(*posts.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn multiple_credit_decrease_cannot_prove_one_selected_redemption() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = fixed_policy_now();
        let initial_bank = bank(
            now,
            &[
                ChronoDuration::days(10),
                ChronoDuration::days(20),
                ChronoDuration::days(30),
            ],
        );
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let posts = Arc::new(Mutex::new(0usize));
        let first_posts = Arc::clone(&posts);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *first_posts.lock().unwrap() += 1;
                    Err(anyhow!("timeout"))
                },
            ),
        )?;
        assert_eq!(first.state, ResetFlowState::Suppressed);

        let observed_at = now + ChronoDuration::seconds(30);
        let mut multiple_removed = initial_bank.clone();
        multiple_removed.available_count = 1;
        multiple_removed.credits.drain(0..2);
        multiple_removed.fetched_at = observed_at;
        let replay_posts = Arc::clone(&posts);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&initial_bank),
                observed_bank: multiple_removed.clone(),
                attempt_reset: true,
                now: observed_at,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(multiple_removed.clone()),
                |account| {
                    make_quota_usable(account, observed_at + ChronoDuration::seconds(1));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_posts.lock().unwrap() += 1;
                    bail!("multi-credit reconciliation must not issue a second POST")
                },
            ),
        )?;

        assert_eq!(replay.state, ResetFlowState::Suppressed);
        assert!(!replay.consumption_observed);
        assert_eq!(*posts.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn replay_requires_quota_generation_change_without_reissuing_post() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let consumed = consumed_bank(initial_bank.clone(), now + ChronoDuration::seconds(1));
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let posts = Arc::new(Mutex::new(0usize));
        let first_posts = Arc::clone(&posts);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(consumed.clone()),
                |account| {
                    account.quota_snapshot.as_mut().unwrap().fetched_at =
                        now + ChronoDuration::seconds(1);
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *first_posts.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: ConsumeCode::Reset,
                        credit_id: Some("credit-0".to_string()),
                    })
                },
            ),
        )?;

        assert!(first.consumption_observed);
        assert!(!first.quota_reconciled);
        assert!(first
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("evidence generation")));

        let replay_posts = Arc::clone(&posts);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&initial_bank),
                observed_bank: consumed.clone(),
                attempt_reset: true,
                now: now + ChronoDuration::seconds(2),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(consumed.clone()),
                |account| {
                    make_quota_usable(account, now + ChronoDuration::seconds(2));
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_posts.lock().unwrap() += 1;
                    bail!("journal replay must never reissue the POST")
                },
            ),
        )?;

        assert!(replay.is_usable_success());
        assert_eq!(*posts.lock().unwrap(), 1);
        let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
        let attempt = journal.attempts.last().unwrap();
        assert_ne!(
            attempt.starting_quota_generation,
            attempt.last_quota_generation
        );
        Ok(())
    }

    #[test]
    fn process_restart_replays_journal_without_reissuing_request() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut first_process_account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut first_process_account, now);
        let calls = Arc::new(Mutex::new(0usize));
        let first_calls = Arc::clone(&calls);

        reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut first_process_account,
                previous_bank: None,
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *first_calls.lock().unwrap() += 1;
                    Err(anyhow!("process lost response"))
                },
            ),
        )?;

        let mut restarted_account = first_process_account.clone();
        restarted_account.id = Uuid::new_v4();
        let replay_calls = Arc::clone(&calls);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut restarted_account,
                previous_bank: Some(&initial_bank),
                observed_bank: initial_bank.clone(),
                attempt_reset: true,
                now: now + ChronoDuration::seconds(10),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(initial_bank.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *replay_calls.lock().unwrap() += 1;
                    bail!("journal replay must not issue a request")
                },
            ),
        )?;

        assert_eq!(replay.state, ResetFlowState::Suppressed);
        assert_eq!(*calls.lock().unwrap(), 1);
        Ok(())
    }

    #[test]
    fn legacy_unresolved_journal_migrates_to_manual_review_without_post() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let journal_path = reset_attempt_journal_path(&store_path);
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        let mut attempt = new_reset_attempt(
            &account,
            &initial_bank,
            Some("credit-0".to_string()),
            Uuid::new_v4(),
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Uncertain,
        );
        attempt.submitted_at = Some(now);
        let mut legacy = serde_json::to_value(ResetAttemptJournal {
            version: RESET_ATTEMPT_JOURNAL_VERSION_1,
            attempts: vec![attempt],
            manual_review: None,
        })?;
        let legacy_attempt = legacy["attempts"][0].as_object_mut().unwrap();
        legacy_attempt.remove("stableOwner");
        legacy_attempt.remove("startingQuotaGeneration");
        legacy_attempt.remove("lastQuotaGeneration");
        fs::write(&journal_path, serde_json::to_vec_pretty(&legacy)?)?;

        let migrated = load_reset_attempt_journal(&journal_path)?;

        assert_eq!(migrated.version, RESET_ATTEMPT_JOURNAL_VERSION);
        assert!(migrated.attempts[0].stable_owner.is_some());
        assert!(migrated.attempts[0].starting_quota_generation.is_none());
        assert!(migrated
            .manual_review
            .as_ref()
            .is_some_and(|sentinel| sentinel.reason.contains("starting quota generation")));
        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now: now + ChronoDuration::minutes(5),
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("legacy manual review must block inventory I/O"),
                |_account| bail!("legacy manual review must block quota I/O"),
                |_account, _bank, _request_id| {
                    bail!("legacy manual review must block another POST")
                },
            ),
        )?;
        assert_eq!(flow.state, ResetFlowState::Suppressed);
        Ok(())
    }

    #[test]
    fn version_two_unresolved_attempt_without_credit_evidence_requires_manual_review() -> Result<()>
    {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let journal_path = reset_attempt_journal_path(&store_path);
        let now = fixed_policy_now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let account = account("active@example.com", true, 100.0, 100.0);
        let mut attempt = new_reset_attempt(
            &account,
            &initial_bank,
            Some("credit-0".to_string()),
            Uuid::new_v4(),
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Uncertain,
        );
        attempt.submitted_at = Some(now);
        let mut legacy = serde_json::to_value(ResetAttemptJournal {
            version: RESET_ATTEMPT_JOURNAL_VERSION_2,
            attempts: vec![attempt],
            manual_review: None,
        })?;
        let legacy_attempt = legacy["attempts"][0].as_object_mut().unwrap();
        legacy_attempt.remove("selectedCreditExpiresAt");
        legacy_attempt.remove("preAvailableCreditIds");
        fs::write(&journal_path, serde_json::to_vec_pretty(&legacy)?)?;

        let migrated = load_reset_attempt_journal(&journal_path)?;

        assert_eq!(migrated.version, RESET_ATTEMPT_JOURNAL_VERSION);
        assert!(migrated
            .manual_review
            .as_ref()
            .is_some_and(|sentinel| sentinel.reason.contains("starting inventory evidence")));
        assert!(migrated.attempts[0].selected_credit_expires_at.is_none());
        assert!(migrated.attempts[0].pre_available_credit_ids.is_empty());
        Ok(())
    }

    #[test]
    fn shared_uncertain_crash_fixture_reconciles_without_second_post() -> Result<()> {
        let fixture: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Policy/uncertain-crash-reconcile.json"
        ))?;
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = decode_swift_datetime(&fixture["now"]).unwrap();
        let before: RateLimitResetBank = serde_json::from_value(fixture["beforeBank"].clone())?;
        let after: RateLimitResetBank = serde_json::from_value(fixture["afterBank"].clone())?;
        let quota_fetched_at = decode_swift_datetime(&fixture["quotaFetchedAt"]).unwrap();
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let posts = Arc::new(Mutex::new(0usize));
        let first_posts = Arc::clone(&posts);

        let first = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: before.clone(),
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(before.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *first_posts.lock().unwrap() += 1;
                    bail!("simulated crash after submission")
                },
            ),
        )?;
        assert_eq!(first.state, ResetFlowState::Suppressed);

        let replay_posts = Arc::clone(&posts);
        let replay = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&before),
                observed_bank: after.clone(),
                attempt_reset: true,
                now: after.fetched_at,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(after.clone()),
                |account| {
                    make_quota_usable(account, quota_fetched_at);
                    Ok(())
                },
                move |_account, _bank, _request_id| {
                    *replay_posts.lock().unwrap() += 1;
                    bail!("reconciliation must not issue a second POST")
                },
            ),
        )?;

        assert!(replay.is_usable_success());
        assert_eq!(*posts.lock().unwrap(), 1);
        assert_eq!(fixture["expected"]["postCount"], 1);
        Ok(())
    }

    #[test]
    fn external_inventory_decrease_blocks_redemption_until_quota_recovers() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let now = Utc::now();
        let previous = bank(now, &[ChronoDuration::days(10), ChronoDuration::days(20)]);
        let external_attempt_at = now + ChronoDuration::seconds(5);
        let observed = consumed_bank(previous.clone(), external_attempt_at);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        make_quota_precede_attempt(&mut account, now);
        let calls = Arc::new(Mutex::new(0usize));
        let calls_for_closure = Arc::clone(&calls);

        let blocked = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&previous),
                observed_bank: observed.clone(),
                attempt_reset: true,
                now: external_attempt_at,
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(observed.clone()),
                |_account| Ok(()),
                move |_account, _bank, _request_id| {
                    *calls_for_closure.lock().unwrap() += 1;
                    bail!("external consumption must block a local POST")
                },
            ),
        )?;
        assert_eq!(blocked.state, ResetFlowState::Suppressed);
        assert!(blocked.consumption_observed);
        assert_eq!(*calls.lock().unwrap(), 0);

        let still_held = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&observed),
                observed_bank: observed.clone(),
                attempt_reset: true,
                now: external_attempt_at + ChronoDuration::seconds(119),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(observed.clone()),
                |account| {
                    make_quota_usable(account, now + ChronoDuration::seconds(21));
                    Ok(())
                },
                |_account, _bank, _request_id| bail!("reconciliation must not issue a POST"),
            ),
        )?;
        assert_eq!(still_held.state, ResetFlowState::Suppressed);
        assert!(still_held.consumption_observed);
        assert!(still_held.quota_reconciled);

        let reconciled = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: Some(&observed),
                observed_bank: observed.clone(),
                attempt_reset: true,
                now: external_attempt_at + ChronoDuration::seconds(120),
            },
            ResetReconciliationDependencies::new(
                |_account| Ok(observed.clone()),
                |_account| Ok(()),
                |_account, _bank, _request_id| bail!("reconciliation must not issue a POST"),
            ),
        )?;
        assert!(reconciled.is_usable_success());
        assert_eq!(*calls.lock().unwrap(), 0);
        Ok(())
    }

    #[test]
    fn natural_credit_expiration_is_not_an_external_inventory_decrease() {
        let now = fixed_policy_now();
        let previous = bank(now, &[ChronoDuration::seconds(10)]);
        let observed_at = now + ChronoDuration::seconds(20);
        let observed = RateLimitResetBank {
            available_count: 0,
            total_earned_count: previous.total_earned_count,
            credits: Vec::new(),
            fetched_at: now + ChronoDuration::seconds(5),
        };

        assert!(external_inventory_decrease_evidence(&previous, &observed, observed_at).is_none());
    }

    #[test]
    fn inventory_decrease_does_not_depend_on_cross_host_wall_clock_order() {
        let now = Utc::now();
        let previous = bank(
            now + ChronoDuration::minutes(5),
            &[ChronoDuration::days(10)],
        );
        let observed = RateLimitResetBank {
            available_count: 0,
            total_earned_count: previous.total_earned_count,
            credits: Vec::new(),
            fetched_at: now,
        };

        assert!(external_inventory_decrease_evidence(&previous, &observed, now).is_some());
    }

    #[test]
    fn definitive_non_consumption_is_terminal_not_uncertain() -> Result<()> {
        let fixture: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../Tests/Fixtures/Policy/terminal-non-consumption.json"
        ))?;
        let codes = fixture["consumeCodes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|code| match code.as_str().unwrap() {
                "no_credit" => ConsumeCode::NoCredit,
                "nothing_to_reset" => ConsumeCode::NothingToReset,
                other => panic!("unexpected fixture code {other}"),
            })
            .collect::<Vec<_>>();
        for code in codes {
            let temp = TempDir::new()?;
            let store_path = temp.path().join("accounts.json");
            let store_lock = lock_account_store(&store_path)?;
            let now = Utc::now();
            let initial_bank = bank(now, &[ChronoDuration::days(10)]);
            let mut account = account("active@example.com", true, 100.0, 100.0);

            let flow = reconcile_or_attempt_reset(
                ResetReconciliationContext {
                    store_lock: &store_lock,
                    account: &mut account,
                    previous_bank: None,
                    observed_bank: initial_bank,
                    attempt_reset: true,
                    now,
                },
                ResetReconciliationDependencies::new(
                    |_account| bail!("terminal non-consumption must not reconcile inventory"),
                    |_account| bail!("terminal non-consumption must not refresh quota"),
                    move |_account, _bank, _request_id| {
                        Ok(ConsumeResult {
                            code,
                            credit_id: None,
                        })
                    },
                ),
            )?;

            assert_eq!(flow.state, ResetFlowState::TerminalNotApplied);
            assert_eq!(fixture["expected"]["state"], "terminal_not_applied");
            assert!(!flow.suppresses_redemption());
            assert!(!flow.consumption_observed);
            let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
            assert_eq!(journal.attempts.len(), 1);
            assert_eq!(
                journal.attempts[0].state,
                ResetAttemptState::TerminalNotApplied
            );
            assert_eq!(journal.attempts[0].response_code, Some(code));

            let later_at = now + ChronoDuration::seconds(10);
            let mut later_bank = bank(later_at, &[ChronoDuration::days(20)]);
            later_bank.credits[0].id = "later-credit".to_string();
            let reconciled_bank =
                consumed_bank(later_bank.clone(), later_at + ChronoDuration::seconds(1));
            let consume_calls = Arc::new(Mutex::new(0usize));
            let consume_calls_for_closure = Arc::clone(&consume_calls);
            let later_flow = reconcile_or_attempt_reset(
                ResetReconciliationContext {
                    store_lock: &store_lock,
                    account: &mut account,
                    previous_bank: None,
                    observed_bank: later_bank,
                    attempt_reset: true,
                    now: later_at,
                },
                ResetReconciliationDependencies::new(
                    move |_account| Ok(reconciled_bank.clone()),
                    move |account| {
                        make_quota_usable(account, later_at + ChronoDuration::seconds(2));
                        Ok(())
                    },
                    move |_account, bank, _request_id| {
                        *consume_calls_for_closure.lock().unwrap() += 1;
                        assert_eq!(
                            bank.oldest_expiring_available_credit(later_at)
                                .map(|credit| credit.id.as_str()),
                            Some("later-credit")
                        );
                        Ok(ConsumeResult {
                            code: ConsumeCode::Reset,
                            credit_id: Some("later-credit".to_string()),
                        })
                    },
                ),
            )?;

            assert!(later_flow.is_usable_success());
            assert_eq!(*consume_calls.lock().unwrap(), 1);
            let journal = load_reset_attempt_journal(&reset_attempt_journal_path(&store_path))?;
            assert_eq!(journal.attempts.len(), 2);
            assert_eq!(
                journal.attempts[0].state,
                ResetAttemptState::TerminalNotApplied
            );
            assert_eq!(
                journal.attempts[1].state,
                ResetAttemptState::ReconciledUsable
            );
        }
        Ok(())
    }

    #[test]
    fn unresolved_journal_is_bounded_by_manual_review_sentinel() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let store_lock = lock_account_store(&store_path)?;
        let journal_path = reset_attempt_journal_path(&store_path);
        let now = Utc::now();
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut account = account("active@example.com", true, 100.0, 100.0);
        let mut journal = ResetAttemptJournal::default();
        for offset in 0..(RESET_UNRESOLVED_ENTRY_CAP + 7) {
            journal.attempts.push(new_reset_attempt(
                &account,
                &initial_bank,
                Some("credit-0".to_string()),
                Uuid::new_v4(),
                now + ChronoDuration::seconds(offset as i64),
                ResetAttemptOrigin::LocalRequest,
                ResetAttemptState::Uncertain,
            ));
        }
        save_reset_attempt_journal(&journal_path, &mut journal, now)?;
        let bounded = load_reset_attempt_journal(&journal_path)?;
        assert_eq!(bounded.attempts.len(), RESET_UNRESOLVED_ENTRY_CAP);
        let sentinel = bounded.manual_review.as_ref().unwrap();
        assert_eq!(sentinel.compacted_attempt_count, 7);

        let flow = reconcile_or_attempt_reset(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut account,
                previous_bank: None,
                observed_bank: initial_bank,
                attempt_reset: true,
                now: now + ChronoDuration::minutes(10),
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("manual review must block inventory I/O"),
                |_account| bail!("manual review must block quota I/O"),
                |_account, _bank, _request_id| bail!("manual review must block redemption"),
            ),
        )?;
        assert_eq!(flow.state, ResetFlowState::Suppressed);
        assert!(flow.detail.unwrap().contains("manual review"));
        Ok(())
    }

    #[test]
    fn oversized_journal_read_is_replaced_by_durable_manual_review_sentinel() -> Result<()> {
        let temp = TempDir::new()?;
        let journal_path = temp.path().join("reset-attempts.json");
        fs::write(
            &journal_path,
            vec![b'x'; RESET_ATTEMPT_JOURNAL_MAX_BYTES + 1],
        )?;

        let journal = load_reset_attempt_journal(&journal_path)?;

        assert!(journal.attempts.is_empty());
        assert!(journal
            .manual_review
            .as_ref()
            .is_some_and(|sentinel| sentinel.reason.contains("byte safety limit")));
        assert!(fs::metadata(&journal_path)?.len() <= RESET_ATTEMPT_JOURNAL_MAX_BYTES as u64);
        let persisted = load_reset_attempt_journal(&journal_path)?;
        assert!(persisted.manual_review.is_some());
        Ok(())
    }

    #[test]
    fn reset_journal_generation_race_preserves_new_state_and_persists_manual_review() -> Result<()>
    {
        let temp = TempDir::new()?;
        let journal_path = temp.path().join("reset-attempts.json");
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let (mut transaction, mut journal) = ResetJournalTransaction::open(&journal_path, now)?;
        transaction.save(&mut journal, now)?;

        let concurrent_request_id = Uuid::new_v4();
        let mut concurrent = ResetAttemptJournal::default();
        concurrent.attempts.push(new_reset_attempt(
            &account,
            &initial_bank,
            Some("concurrent-credit".to_string()),
            concurrent_request_id,
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Uncertain,
        ));
        let concurrent_data = prepare_reset_attempt_journal_write(&mut concurrent, now)?;
        let replacement_path = temp.path().join("outside-journal.tmp");

        journal.attempts.push(new_reset_attempt(
            &account,
            &initial_bank,
            Some("stale-writer-credit".to_string()),
            Uuid::new_v4(),
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Prepared,
        ));
        let error = transaction
            .save_with_test_hook(&mut journal, now, || {
                fs::write(&replacement_path, &concurrent_data)?;
                fs::set_permissions(&replacement_path, fs::Permissions::from_mode(0o600))?;
                fs::rename(&replacement_path, &journal_path)?;
                Ok(())
            })
            .unwrap_err();
        assert!(format!("{error:#}").contains("durable manual-review sentinel"));
        drop(transaction);

        let persisted = load_reset_attempt_journal(&journal_path)?;
        assert!(persisted
            .attempts
            .iter()
            .any(|attempt| attempt.request_id == concurrent_request_id));
        assert!(persisted
            .manual_review
            .as_ref()
            .is_some_and(|sentinel| sentinel.reason.contains("generation changed")));
        Ok(())
    }

    #[test]
    fn reset_journal_rejects_symlink_target_without_mutating_referent() -> Result<()> {
        let temp = TempDir::new()?;
        let outside = temp.path().join("outside.json");
        let outside_bytes = serde_json::to_vec_pretty(&ResetAttemptJournal::default())?;
        fs::write(&outside, &outside_bytes)?;
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o600))?;
        let journal_path = temp.path().join("reset-attempts.json");
        symlink(&outside, &journal_path)?;

        assert!(load_reset_attempt_journal(&journal_path).is_err());
        assert_eq!(fs::read(&outside)?, outside_bytes);
        assert!(journal_path.is_symlink());
        Ok(())
    }

    #[test]
    fn oversized_journal_write_compacts_under_limit_and_preserves_uncertainty() -> Result<()> {
        let temp = TempDir::new()?;
        let journal_path = temp.path().join("reset-attempts.json");
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut journal = ResetAttemptJournal::default();
        while serde_json::to_vec_pretty(&journal)?.len() <= RESET_ATTEMPT_JOURNAL_MAX_BYTES {
            let mut attempt = new_reset_attempt(
                &account,
                &initial_bank,
                Some("credit-0".to_string()),
                Uuid::new_v4(),
                now + ChronoDuration::seconds(journal.attempts.len() as i64),
                ResetAttemptOrigin::LocalRequest,
                ResetAttemptState::Uncertain,
            );
            attempt.last_error = Some("e".repeat(RESET_ERROR_DETAIL_MAX_BYTES));
            journal.attempts.push(attempt);
            assert!(journal.attempts.len() <= RESET_UNRESOLVED_ENTRY_CAP);
        }
        let original_count = journal.attempts.len();

        save_reset_attempt_journal(&journal_path, &mut journal, now)?;

        assert!(fs::metadata(&journal_path)?.len() <= RESET_ATTEMPT_JOURNAL_MAX_BYTES as u64);
        assert!(journal.attempts.len() < original_count);
        assert!(journal.manual_review.is_some());
        let persisted = load_reset_attempt_journal(&journal_path)?;
        assert_eq!(persisted.attempts.len(), journal.attempts.len());
        assert!(persisted
            .attempts
            .iter()
            .all(|attempt| !attempt.state.is_terminal()));
        assert!(persisted.manual_review.is_some());
        Ok(())
    }

    #[test]
    fn reset_journal_variable_fields_are_bounded_directly() {
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        let initial_bank = bank(now, &[ChronoDuration::days(10)]);
        let mut attempt = new_reset_attempt(
            &account,
            &initial_bank,
            Some("credit-0".to_string()),
            Uuid::new_v4(),
            now,
            ResetAttemptOrigin::LocalRequest,
            ResetAttemptState::Uncertain,
        );
        attempt.account_id = "a".repeat(RESET_IDENTIFIER_MAX_BYTES + 100);
        attempt.selected_credit_id = Some("c".repeat(RESET_IDENTIFIER_MAX_BYTES + 100));
        attempt.stable_owner = Some("o".repeat(RESET_GENERATION_MAX_BYTES + 100));
        attempt.pre_inventory_generation = "i".repeat(RESET_GENERATION_MAX_BYTES + 100);
        attempt.starting_quota_generation = Some("q".repeat(RESET_GENERATION_MAX_BYTES + 100));
        attempt.last_inventory_generation = Some("l".repeat(RESET_GENERATION_MAX_BYTES + 100));
        attempt.last_quota_generation = Some("g".repeat(RESET_GENERATION_MAX_BYTES + 100));
        attempt.last_error = Some("e".repeat(RESET_ERROR_DETAIL_MAX_BYTES + 100));
        let mut journal = ResetAttemptJournal {
            version: RESET_ATTEMPT_JOURNAL_VERSION,
            attempts: vec![attempt],
            manual_review: Some(ResetManualReviewSentinel {
                first_compacted_at: now,
                last_compacted_at: now,
                compacted_attempt_count: 1,
                reason: "r".repeat(RESET_MANUAL_REVIEW_REASON_MAX_BYTES + 100),
            }),
        };

        assert_eq!(sanitize_reset_attempt_journal(&mut journal), 9);
        let attempt = &journal.attempts[0];
        assert!(attempt.account_id.len() <= RESET_IDENTIFIER_MAX_BYTES);
        assert!(attempt
            .selected_credit_id
            .as_ref()
            .is_some_and(|value| value.len() <= RESET_IDENTIFIER_MAX_BYTES));
        for generation in [
            attempt.stable_owner.as_ref(),
            Some(&attempt.pre_inventory_generation),
            attempt.starting_quota_generation.as_ref(),
            attempt.last_inventory_generation.as_ref(),
            attempt.last_quota_generation.as_ref(),
        ] {
            assert!(generation.is_some_and(|value| value.len() <= RESET_GENERATION_MAX_BYTES));
        }
        assert!(attempt
            .last_error
            .as_ref()
            .is_some_and(|value| value.len() <= RESET_ERROR_DETAIL_MAX_BYTES));
        assert!(journal
            .manual_review
            .as_ref()
            .is_some_and(|sentinel| sentinel.reason.len() <= RESET_MANUAL_REVIEW_REASON_MAX_BYTES));
    }

    #[test]
    fn reset_error_detail_growth_is_bounded() {
        let detail = join_details([
            Some("first".repeat(1_000)),
            Some("second".repeat(1_000)),
            Some("third".repeat(1_000)),
        ])
        .unwrap();
        assert!(detail.len() <= RESET_ERROR_DETAIL_MAX_BYTES);
        assert!(detail.ends_with("..."));
    }

    #[test]
    fn consume_codes_are_classified_without_live_requests() -> Result<()> {
        let now = Utc::now();
        let account = account("active@example.com", true, 100.0, 100.0);
        for (wire_code, expected) in [
            ("reset", ConsumeCode::Reset),
            ("already_redeemed", ConsumeCode::AlreadyRedeemed),
            ("no_credit", ConsumeCode::NoCredit),
            ("nothing_to_reset", ConsumeCode::NothingToReset),
        ] {
            let result = consume_rate_limit_reset_with(
                &account,
                &bank(now, &[ChronoDuration::days(10)]),
                now,
                Uuid::new_v4(),
                |_account, _body| {
                    Ok(HttpResponse {
                        status: 200,
                        body: serde_json::to_vec(&json!({ "code": wire_code }))?,
                    })
                },
            )?;
            assert_eq!(result.code, expected);
        }
        Ok(())
    }

    #[test]
    fn bank_state_round_trips_in_swift_compatible_camel_case() -> Result<()> {
        let now = DateTime::parse_from_rfc3339("2026-07-12T12:00:00Z")?.with_timezone(&Utc);
        let encoded = serde_json::to_value(bank(now, &[ChronoDuration::days(1)]))?;
        assert_eq!(encoded["availableCount"], 1);
        assert!(encoded.get("available_count").is_none());
        assert!(encoded["fetchedAt"].is_number());
        assert!(encoded["credits"][0]["expiresAt"].is_number());
        let decoded: RateLimitResetBank = serde_json::from_value(encoded)?;
        assert_eq!(decoded.available_count, 1);
        assert_eq!(decoded.credits[0].id, "credit-0");
        Ok(())
    }
}

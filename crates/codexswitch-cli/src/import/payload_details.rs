use super::bounds::{
    BoundedText, BoundedVec, MAX_INNER_STRING_BYTES, MAX_QUOTA_WINDOWS_PER_ACCOUNT,
    MAX_RESET_CREDITS_PER_ACCOUNT, UNIX_TO_SWIFT_REFERENCE_SECONDS,
};
use crate::account_store::{
    QuotaSnapshot, QuotaWindow, QuotaWindowKind, QuotaWindowRateLimitSource, QuotaWindowSlot,
    QuotaWindowSourceMetadata,
};
use crate::rate_limit_resets::{RateLimitResetBank, RateLimitResetCredit};
use anyhow::{anyhow, bail, Result};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Number, Value};

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum StrictDateScalar {
    Number(Number),
    Text(BoundedText<MAX_INNER_STRING_BYTES>),
}

impl StrictDateScalar {
    pub(super) fn into_value(self) -> Value {
        match self {
            Self::Number(number) => Value::Number(number),
            Self::Text(text) => Value::String(text.into_string()),
        }
    }

    pub(super) fn into_datetime(self, label: &str) -> Result<DateTime<Utc>> {
        parse_swift_datetime(&self, label)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StrictQuotaSnapshot {
    #[serde(default)]
    version: Option<u32>,
    #[serde(default)]
    schema_version: Option<u32>,
    #[serde(default)]
    allowed: Option<bool>,
    #[serde(default)]
    limit_reached: Option<bool>,
    fetched_at: StrictDateScalar,
    #[serde(default)]
    windows: Option<BoundedQuotaWindows>,
    #[serde(default)]
    five_hour: Option<StrictQuotaWindow>,
    #[serde(default)]
    weekly: Option<StrictQuotaWindow>,
}

impl StrictQuotaSnapshot {
    pub(super) fn into_snapshot(self) -> Result<QuotaSnapshot> {
        if self
            .version
            .zip(self.schema_version)
            .is_some_and(|(version, schema_version)| version != schema_version)
        {
            bail!("quota snapshot contains conflicting versions");
        }

        let version = self.version.or(self.schema_version);
        let fetched_at = self.fetched_at.into_datetime("quota fetchedAt")?;
        if let Some(version) = version {
            if version != 2 {
                bail!("unsupported quota snapshot version {version}");
            }
            if self.five_hour.is_some() || self.weekly.is_some() {
                bail!("versioned quota snapshot contains legacy windows");
            }
            let windows = self
                .windows
                .ok_or_else(|| anyhow!("versioned quota snapshot is missing windows"))?
                .into_values()
                .into_iter()
                .map(|window| window.into_window(None))
                .collect::<Result<Vec<_>>>()?
                .into_iter()
                .filter(|window| window.duration_seconds > 0)
                .collect();
            return Ok(QuotaSnapshot {
                allowed: self.allowed,
                limit_reached: self.limit_reached,
                fetched_at,
                windows,
            });
        }

        if self.windows.is_some() || self.allowed.is_some() || self.limit_reached.is_some() {
            bail!("legacy quota snapshot contains versioned fields");
        }
        let mut windows = Vec::with_capacity(2);
        if let Some(window) = self.five_hour {
            let window = window.into_window(Some(QuotaWindowSlot::LegacyFiveHour))?;
            if window.duration_seconds > 0 {
                windows.push(window);
            }
        }
        if let Some(window) = self.weekly {
            let window = window.into_window(Some(QuotaWindowSlot::LegacyWeekly))?;
            if window.duration_seconds > 0 {
                windows.push(window);
            }
        }
        let hard_limit_reached = windows.iter().any(|window| window.hard_limit_reached);
        Ok(QuotaSnapshot {
            allowed: hard_limit_reached.then_some(false),
            limit_reached: hard_limit_reached.then_some(true),
            fetched_at,
            windows,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictQuotaWindow {
    #[serde(default)]
    kind: Option<QuotaWindowKind>,
    #[serde(default)]
    duration_seconds: Option<i64>,
    #[serde(default)]
    window_duration_mins: Option<i64>,
    used_percent: f64,
    resets_at: StrictDateScalar,
    #[serde(default)]
    source: Option<StrictQuotaWindowSource>,
    #[serde(default)]
    hard_limit_reached: bool,
}

impl StrictQuotaWindow {
    fn into_window(self, legacy_slot: Option<QuotaWindowSlot>) -> Result<QuotaWindow> {
        let used_legacy_duration = self.duration_seconds.is_none();
        let duration_seconds = match (self.duration_seconds, self.window_duration_mins) {
            (Some(seconds), None) => seconds,
            (None, Some(minutes)) => minutes
                .checked_mul(60)
                .ok_or_else(|| anyhow!("quota window duration is out of range"))?,
            (None, None) => bail!("quota window is missing its duration"),
            (Some(_), Some(_)) => bail!("quota window contains conflicting duration fields"),
        };
        let source = if let Some(slot) = legacy_slot {
            QuotaWindowSourceMetadata::new(QuotaWindowRateLimitSource::Legacy, slot)
        } else if let Some(source) = self.source {
            source.into_source()
        } else {
            QuotaWindowSourceMetadata::new(
                if used_legacy_duration {
                    QuotaWindowRateLimitSource::Legacy
                } else {
                    QuotaWindowRateLimitSource::Unknown
                },
                QuotaWindowSlot::Unknown,
            )
        };
        let kind = if legacy_slot.is_some() || !used_legacy_duration {
            QuotaWindowKind::classify(duration_seconds)
        } else {
            self.kind
                .unwrap_or_else(|| QuotaWindowKind::classify(duration_seconds))
        };
        Ok(QuotaWindow {
            kind,
            duration_seconds,
            used_percent: self.used_percent,
            resets_at: self.resets_at.into_datetime("quota resetsAt")?,
            source,
            hard_limit_reached: self.hard_limit_reached,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictQuotaWindowSource {
    rate_limit: QuotaWindowRateLimitSource,
    slot: QuotaWindowSlot,
    #[serde(default)]
    limit_name: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    #[serde(default)]
    metered_feature: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
}

impl StrictQuotaWindowSource {
    fn into_source(self) -> QuotaWindowSourceMetadata {
        QuotaWindowSourceMetadata {
            rate_limit: self.rate_limit,
            slot: self.slot,
            limit_name: self.limit_name.map(BoundedText::into_string),
            metered_feature: self.metered_feature.map(BoundedText::into_string),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StrictRateLimitResetBank {
    available_count: u32,
    total_earned_count: u32,
    credits: BoundedResetCredits,
    fetched_at: StrictDateScalar,
}

impl StrictRateLimitResetBank {
    pub(super) fn into_bank(self) -> Result<RateLimitResetBank> {
        Ok(RateLimitResetBank {
            available_count: self.available_count,
            total_earned_count: self.total_earned_count,
            credits: self
                .credits
                .into_values()
                .into_iter()
                .map(StrictRateLimitResetCredit::into_credit)
                .collect::<Result<Vec<_>>>()?,
            fetched_at: self.fetched_at.into_datetime("reset bank fetchedAt")?,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StrictRateLimitResetCredit {
    id: BoundedText<MAX_INNER_STRING_BYTES>,
    #[serde(default)]
    reset_type: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    status: BoundedText<MAX_INNER_STRING_BYTES>,
    #[serde(default)]
    granted_at: Option<StrictDateScalar>,
    #[serde(default)]
    expires_at: Option<StrictDateScalar>,
    #[serde(default)]
    redeem_started_at: Option<StrictDateScalar>,
    #[serde(default)]
    redeemed_at: Option<StrictDateScalar>,
    #[serde(default)]
    title: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
    #[serde(default)]
    description: Option<BoundedText<MAX_INNER_STRING_BYTES>>,
}

impl StrictRateLimitResetCredit {
    fn into_credit(self) -> Result<RateLimitResetCredit> {
        Ok(RateLimitResetCredit {
            id: self.id.into_string(),
            reset_type: self.reset_type.map(BoundedText::into_string),
            status: self.status.into_string(),
            granted_at: parse_optional_datetime(self.granted_at, "reset credit grantedAt")?,
            expires_at: parse_optional_datetime(self.expires_at, "reset credit expiresAt")?,
            redeem_started_at: parse_optional_datetime(
                self.redeem_started_at,
                "reset credit redeemStartedAt",
            )?,
            redeemed_at: parse_optional_datetime(self.redeemed_at, "reset credit redeemedAt")?,
            title: self.title.map(BoundedText::into_string),
            description: self.description.map(BoundedText::into_string),
        })
    }
}

fn parse_optional_datetime(
    value: Option<StrictDateScalar>,
    label: &str,
) -> Result<Option<DateTime<Utc>>> {
    value.map(|value| value.into_datetime(label)).transpose()
}

fn parse_swift_datetime(value: &StrictDateScalar, label: &str) -> Result<DateTime<Utc>> {
    let swift_seconds = match value {
        StrictDateScalar::Number(number) => number
            .as_f64()
            .ok_or_else(|| anyhow!("{label} is out of range"))?,
        StrictDateScalar::Text(text) => {
            if let Ok(number) = text.as_str().parse::<f64>() {
                number
            } else {
                let datetime = DateTime::parse_from_rfc3339(text.as_str())
                    .map_err(|_| anyhow!("{label} is not a supported date"))?;
                return Ok(datetime.with_timezone(&Utc));
            }
        }
    };
    if !swift_seconds.is_finite() {
        bail!("{label} is out of range");
    }
    let unix_seconds = swift_seconds + UNIX_TO_SWIFT_REFERENCE_SECONDS;
    let whole_seconds = unix_seconds.floor() as i64;
    let nanos = ((unix_seconds - whole_seconds as f64) * 1_000_000_000.0).round() as u32;
    let (whole_seconds, nanos) = if nanos == 1_000_000_000 {
        (
            whole_seconds
                .checked_add(1)
                .ok_or_else(|| anyhow!("{label} is out of range"))?,
            0,
        )
    } else {
        (whole_seconds, nanos)
    };
    DateTime::<Utc>::from_timestamp(whole_seconds, nanos)
        .ok_or_else(|| anyhow!("{label} is out of range"))
}

type BoundedQuotaWindows = BoundedVec<StrictQuotaWindow, MAX_QUOTA_WINDOWS_PER_ACCOUNT>;
type BoundedResetCredits = BoundedVec<StrictRateLimitResetCredit, MAX_RESET_CREDITS_PER_ACCOUNT>;

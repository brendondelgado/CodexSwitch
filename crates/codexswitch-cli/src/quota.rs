use crate::account_store::{
    swift_reference_value, CodexAccount, QuotaSnapshot, QuotaWindow, QuotaWindowKind,
    QuotaWindowRateLimitSource, QuotaWindowSlot, QuotaWindowSourceMetadata,
};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::Deserialize;
use serde_json::Value;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
#[derive(Debug, Clone)]
pub struct FetchResult {
    pub snapshot: QuotaSnapshot,
    pub plan_type: String,
}

#[derive(Debug, Deserialize)]
struct UsageResponse {
    #[serde(rename = "plan_type")]
    plan_type: String,
    #[serde(rename = "rate_limit")]
    rate_limit: Option<RateLimitDetails>,
    #[serde(rename = "additional_rate_limits")]
    additional_rate_limits: Option<Vec<AdditionalRateLimit>>,
}

#[derive(Debug, Deserialize)]
struct RateLimitDetails {
    allowed: Option<bool>,
    #[serde(rename = "limit_reached")]
    limit_reached: Option<bool>,
    #[serde(rename = "primary_window")]
    primary_window: Option<WindowSnapshot>,
    #[serde(rename = "secondary_window")]
    secondary_window: Option<WindowSnapshot>,
}

#[derive(Debug, Deserialize)]
struct AdditionalRateLimit {
    #[serde(rename = "limit_name")]
    limit_name: Option<String>,
    #[serde(rename = "metered_feature")]
    metered_feature: Option<String>,
    #[serde(rename = "rate_limit")]
    rate_limit: Option<RateLimitDetails>,
}

#[derive(Debug, Deserialize)]
struct WindowSnapshot {
    #[serde(rename = "used_percent")]
    used_percent: f64,
    #[serde(rename = "limit_window_seconds")]
    limit_window_seconds: i64,
    #[serde(rename = "reset_at")]
    reset_at: i64,
}

#[derive(Debug, Clone, Copy)]
struct SelectedRateLimit<'a> {
    details: &'a RateLimitDetails,
    source: QuotaWindowRateLimitSource,
    limit_name: Option<&'a str>,
    metered_feature: Option<&'a str>,
}

pub fn fetch_quota(account: &CodexAccount) -> Result<FetchResult> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("codex-cli")
        .build()
        .context("failed to build HTTP client")?;

    for attempt in 1..=3 {
        let response = client
            .get(USAGE_URL)
            .bearer_auth(&account.access_token)
            .header("ChatGPT-Account-Id", &account.account_id)
            .header("Accept", "application/json")
            .send()
            .with_context(|| format!("failed to fetch quota for {}", account.email))?;

        let status = response.status();
        let body = response
            .text()
            .context("failed to read quota response body")?;
        match status.as_u16() {
            200 => match parse_usage_response(body.as_bytes()) {
                Ok(result) => return Ok(result),
                Err(error)
                    if error.to_string().contains("placeholder usage window") && attempt < 3 =>
                {
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    continue;
                }
                Err(error) => return Err(error),
            },
            401 => bail!("token expired for {}", account.email),
            429 => bail!("rate limited while polling {}", account.email),
            code => bail!("quota API returned HTTP {code} for {}", account.email),
        }
    }
    bail!("rate limits unavailable: placeholder usage window")
}

pub fn parse_usage_response(data: &[u8]) -> Result<FetchResult> {
    let response: UsageResponse =
        serde_json::from_slice(data).context("failed to decode quota response")?;
    let Some(selected) = selected_rate_limit(&response) else {
        bail!("rate limits unavailable: placeholder usage window");
    };
    let fetched_at = Utc::now();
    let mut windows = mapped_windows(&selected)?;
    if selected.source == QuotaWindowRateLimitSource::Additional {
        if let Some(main) = response.rate_limit.as_ref() {
            windows.extend(
                mapped_windows(&SelectedRateLimit {
                    details: main,
                    source: QuotaWindowRateLimitSource::Main,
                    limit_name: None,
                    metered_feature: None,
                })?
                .into_iter()
                .filter(|window| window.kind == QuotaWindowKind::Unknown),
            );
        }
    }
    let snapshot = QuotaSnapshot {
        allowed: selected.details.allowed,
        limit_reached: selected.details.limit_reached,
        fetched_at,
        windows,
    };
    if snapshot.windows.is_empty() && !snapshot.is_denied() {
        bail!("rate limits unavailable: placeholder usage window");
    }

    Ok(FetchResult {
        snapshot,
        plan_type: response.plan_type,
    })
}

pub fn apply_fetch_result(account: &mut CodexAccount, result: FetchResult) {
    let fetched_at = swift_reference_value(result.snapshot.fetched_at);
    let plan_type = result.plan_type;
    account.has_active_subscription = Some(plan_has_active_subscription(&plan_type));
    if result.snapshot.has_backend_usage_placeholder() {
        account.plan_type = Some(plan_type);
        return;
    }
    account.quota_snapshot = Some(result.snapshot);
    account.plan_type = Some(plan_type);
    account.last_refreshed = Some(fetched_at);
    account.runtime_unusable_until = None;
    account.runtime_unusable_reason = None;
}

fn plan_has_active_subscription(plan_type: &str) -> bool {
    !matches!(
        plan_type
            .trim()
            .to_ascii_lowercase()
            .replace(['-', ' '], "_")
            .as_str(),
        "" | "free" | "free_workspace" | "guest" | "unknown"
    )
}

fn selected_rate_limit(response: &UsageResponse) -> Option<SelectedRateLimit<'_>> {
    let main = response
        .rate_limit
        .as_ref()
        .map(|details| SelectedRateLimit {
            details,
            source: QuotaWindowRateLimitSource::Main,
            limit_name: None,
            metered_feature: None,
        });
    if let Some(main) = main {
        if has_recognized_policy_window(main.details) || is_denied(main.details) {
            return Some(main);
        }
    }

    let candidates = response
        .additional_rate_limits
        .as_deref()
        .unwrap_or_default()
        .iter()
        .enumerate()
        .filter_map(|(index, additional)| {
            let rank = codex_metadata_rank(additional)?;
            let details = additional.rate_limit.as_ref()?;
            (has_positive_window(details) || is_denied(details)).then_some((
                rank,
                index,
                SelectedRateLimit {
                    details,
                    source: QuotaWindowRateLimitSource::Additional,
                    limit_name: additional.limit_name.as_deref(),
                    metered_feature: additional.metered_feature.as_deref(),
                },
            ))
        })
        .collect::<Vec<_>>();

    if let Some(selected) = candidates
        .iter()
        .filter(|(_, _, selected)| {
            has_recognized_policy_window(selected.details) || is_denied(selected.details)
        })
        .min_by_key(|(rank, index, _)| (*rank, *index))
        .map(|(_, _, selected)| *selected)
    {
        return Some(selected);
    }

    if main.is_some_and(|selected| has_positive_window(selected.details)) {
        return main;
    }

    candidates
        .into_iter()
        .min_by_key(|(rank, index, _)| (*rank, *index))
        .map(|(_, _, selected)| selected)
}

fn has_positive_window(details: &RateLimitDetails) -> bool {
    [
        details.primary_window.as_ref(),
        details.secondary_window.as_ref(),
    ]
    .into_iter()
    .flatten()
    .any(|window| window.limit_window_seconds > 0)
}

fn has_recognized_policy_window(details: &RateLimitDetails) -> bool {
    [
        details.primary_window.as_ref(),
        details.secondary_window.as_ref(),
    ]
    .into_iter()
    .flatten()
    .any(|window| {
        window.limit_window_seconds > 0
            && QuotaWindowKind::classify(window.limit_window_seconds) != QuotaWindowKind::Unknown
    })
}

fn is_denied(details: &RateLimitDetails) -> bool {
    details.allowed == Some(false) || details.limit_reached == Some(true)
}

fn codex_metadata_rank(additional: &AdditionalRateLimit) -> Option<u8> {
    let limit_name = additional
        .limit_name
        .as_deref()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let metered_feature = additional
        .metered_feature
        .as_deref()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let is_excluded_model_family = limit_name.contains("spark")
        || limit_name.contains("bengalfox")
        || metered_feature.contains("spark")
        || metered_feature.contains("bengalfox");
    if is_excluded_model_family {
        return None;
    }
    if metered_feature == "codex" {
        return Some(0);
    }
    if metered_feature.contains("codex") {
        return Some(1);
    }
    if limit_name.contains("codex") {
        return Some(2);
    }
    None
}

fn mapped_windows(selected: &SelectedRateLimit<'_>) -> Result<Vec<QuotaWindow>> {
    [
        (
            selected.details.primary_window.as_ref(),
            QuotaWindowSlot::Primary,
        ),
        (
            selected.details.secondary_window.as_ref(),
            QuotaWindowSlot::Secondary,
        ),
    ]
    .into_iter()
    .filter_map(|(window, slot)| window.map(|window| (window, slot)))
    .filter(|(window, _)| window.limit_window_seconds > 0)
    .map(|(window, slot)| {
        Ok(QuotaWindow {
            kind: QuotaWindowKind::classify(window.limit_window_seconds),
            duration_seconds: window.limit_window_seconds,
            used_percent: window.used_percent,
            resets_at: chrono::DateTime::<Utc>::from_timestamp(window.reset_at, 0)
                .context("quota API reset timestamp is out of range")?,
            source: QuotaWindowSourceMetadata {
                rate_limit: selected.source,
                slot,
                limit_name: selected.limit_name.map(str::to_string),
                metered_feature: selected.metered_feature.map(str::to_string),
            },
            hard_limit_reached: false,
        })
    })
    .collect()
}

pub fn now_swift_reference_value() -> Value {
    swift_reference_value(Utc::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn fixture(name: &str) -> &'static [u8] {
        match name {
            "legacy-two" => include_bytes!("../../../Tests/Fixtures/Quota/legacy-two.json"),
            "weekly-primary" => {
                include_bytes!("../../../Tests/Fixtures/Quota/weekly-primary.json")
            }
            "weekly-secondary" => {
                include_bytes!("../../../Tests/Fixtures/Quota/weekly-secondary.json")
            }
            "disabled-primary-weekly" => {
                include_bytes!("../../../Tests/Fixtures/Quota/disabled-primary-weekly.json")
            }
            "spark-before-codex" => {
                include_bytes!("../../../Tests/Fixtures/Quota/spark-before-codex.json")
            }
            "spark-after-codex" => {
                include_bytes!("../../../Tests/Fixtures/Quota/spark-after-codex.json")
            }
            "bengalfox-name-codex-feature" => {
                include_bytes!("../../../Tests/Fixtures/Quota/bengalfox-name-codex-feature.json")
            }
            "denied-weekly" => {
                include_bytes!("../../../Tests/Fixtures/Quota/denied-weekly.json")
            }
            "allowed-no-windows" => {
                include_bytes!("../../../Tests/Fixtures/Quota/allowed-no-windows.json")
            }
            "unknown-duration" => {
                include_bytes!("../../../Tests/Fixtures/Quota/unknown-duration.json")
            }
            "allowed-rounded-100" => {
                include_bytes!("../../../Tests/Fixtures/Quota/allowed-rounded-100.json")
            }
            "unknown-main-recognized-additional" => include_bytes!(
                "../../../Tests/Fixtures/Quota/unknown-main-recognized-additional.json"
            ),
            _ => panic!("unknown fixture {name}"),
        }
    }

    #[test]
    fn shared_fixtures_classify_windows_by_duration_without_fabrication() {
        let legacy = parse_usage_response(fixture("legacy-two")).unwrap();
        assert_eq!(legacy.snapshot.windows.len(), 2);
        assert_eq!(legacy.snapshot.five_hour().unwrap().used_percent, 28.0);
        assert_eq!(legacy.snapshot.weekly().unwrap().used_percent, 5.0);
        assert_eq!(
            legacy.snapshot.five_hour().unwrap().source.rate_limit,
            QuotaWindowRateLimitSource::Main
        );

        let primary = parse_usage_response(fixture("weekly-primary")).unwrap();
        assert_eq!(primary.snapshot.windows.len(), 1);
        assert!(primary.snapshot.five_hour().is_none());
        assert_eq!(
            primary.snapshot.weekly().unwrap().source.slot,
            QuotaWindowSlot::Primary
        );

        let secondary = parse_usage_response(fixture("weekly-secondary")).unwrap();
        assert_eq!(secondary.snapshot.windows.len(), 2);
        assert_eq!(
            secondary.snapshot.weekly().unwrap().source.slot,
            QuotaWindowSlot::Secondary
        );

        let disabled = parse_usage_response(fixture("disabled-primary-weekly")).unwrap();
        assert_eq!(disabled.snapshot.windows.len(), 1);
        assert!(disabled.snapshot.five_hour().is_none());
        assert_eq!(disabled.snapshot.weekly().unwrap().used_percent, 16.0);
    }

    #[test]
    fn shared_fixtures_rank_codex_metadata_and_exclude_spark_and_bengalfox() {
        for name in [
            "spark-before-codex",
            "spark-after-codex",
            "bengalfox-name-codex-feature",
        ] {
            let result = parse_usage_response(fixture(name)).unwrap();
            let weekly = result.snapshot.weekly().unwrap();
            assert_eq!(weekly.used_percent, 27.0);
            assert_eq!(
                weekly.source.rate_limit,
                QuotaWindowRateLimitSource::Additional
            );
            assert_eq!(weekly.source.limit_name.as_deref(), Some("GPT-5.5"));
            assert_eq!(weekly.source.metered_feature.as_deref(), Some("codex"));
        }
    }

    #[test]
    fn recognized_codex_additional_beats_unknown_main_and_retains_diagnostic() {
        let result = parse_usage_response(fixture("unknown-main-recognized-additional")).unwrap();

        assert_eq!(result.snapshot.windows.len(), 2);
        assert!(result.snapshot.five_hour().is_none());
        let weekly = result.snapshot.weekly().unwrap();
        assert_eq!(weekly.used_percent, 19.0);
        assert_eq!(
            weekly.source.rate_limit,
            QuotaWindowRateLimitSource::Additional
        );
        assert_eq!(weekly.source.limit_name.as_deref(), Some("Codex"));
        let diagnostic = result
            .snapshot
            .windows
            .iter()
            .find(|window| window.kind == QuotaWindowKind::Unknown)
            .unwrap();
        assert_eq!(diagnostic.duration_seconds, 86_400);
        assert_eq!(diagnostic.used_percent, 33.0);
        assert_eq!(
            diagnostic.source.rate_limit,
            QuotaWindowRateLimitSource::Main
        );
        assert_eq!(result.snapshot.minimum_remaining_percent(), Some(81.0));
        assert_eq!(
            result.snapshot.availability_at(result.snapshot.fetched_at),
            crate::account_store::QuotaAvailability::Usable
        );
    }

    #[test]
    fn metadata_exclusion_checks_either_name_or_feature() {
        for (limit_name, metered_feature) in [
            ("Codex Spark", "codex"),
            ("GPT-5.5", "codex_spark"),
            ("Codex Bengalfox", "codex"),
            ("GPT-5.5", "codex_bengalfox"),
        ] {
            let additional = AdditionalRateLimit {
                limit_name: Some(limit_name.to_string()),
                metered_feature: Some(metered_feature.to_string()),
                rate_limit: None,
            };
            assert_eq!(codex_metadata_rank(&additional), None);
        }
    }

    #[test]
    fn shared_fixtures_preserve_denial_unknown_and_rounded_usage() {
        let denied = parse_usage_response(fixture("denied-weekly")).unwrap();
        assert!(denied.snapshot.is_denied());
        assert_eq!(
            denied.snapshot.availability_at(denied.snapshot.fetched_at),
            crate::account_store::QuotaAvailability::Blocked
        );
        assert!(denied.snapshot.five_hour().is_none());

        let unknown = parse_usage_response(fixture("unknown-duration")).unwrap();
        assert_eq!(unknown.snapshot.windows.len(), 1);
        assert_eq!(unknown.snapshot.windows[0].kind, QuotaWindowKind::Unknown);
        assert_eq!(unknown.snapshot.windows[0].duration_seconds, 86_400);
        assert_eq!(unknown.snapshot.minimum_remaining_percent(), None);
        assert_eq!(
            unknown
                .snapshot
                .availability_at(unknown.snapshot.fetched_at),
            crate::account_store::QuotaAvailability::Unknown
        );

        let rounded = parse_usage_response(fixture("allowed-rounded-100")).unwrap();
        assert_eq!(rounded.snapshot.weekly().unwrap().used_percent, 100.0);
        assert_eq!(
            rounded
                .snapshot
                .availability_at(rounded.snapshot.fetched_at),
            crate::account_store::QuotaAvailability::Blocked
        );
    }

    #[test]
    fn shared_allowed_no_windows_fixture_is_unavailable() {
        assert!(parse_usage_response(fixture("allowed-no-windows"))
            .unwrap_err()
            .to_string()
            .contains("placeholder usage window"));
    }

    #[test]
    fn parses_usage_response_with_hard_limit() {
        let data = br#"{
          "plan_type":"plus",
          "rate_limit":{
            "allowed":false,
            "limit_reached":true,
            "primary_window":{"used_percent":99.2,"limit_window_seconds":18000,"reset_at":1893456000},
            "secondary_window":{"used_percent":22.5,"limit_window_seconds":604800,"reset_at":1894060800}
          }
        }"#;

        let result = parse_usage_response(data).unwrap();
        assert_eq!(result.plan_type, "plus");
        assert!(result.snapshot.is_denied());
        assert!(!result.snapshot.five_hour().unwrap().hard_limit_reached);
        assert_eq!(result.snapshot.weekly().unwrap().used_percent, 22.5);
    }

    #[test]
    fn successful_fetch_result_clears_runtime_unusable_block() {
        let mut account = CodexAccount {
            id: Uuid::new_v4(),
            email: "blocked@example.com".to_string(),
            access_token: "access".to_string(),
            refresh_token: "refresh".to_string(),
            id_token: "id".to_string(),
            account_id: "blocked@example.com".to_string(),
            quota_snapshot: None,
            plan_type: Some("plus".to_string()),
            last_refreshed: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: Some(true),
            five_hour_primed_at: None,
            runtime_unusable_until: Some(Utc::now() + chrono::Duration::hours(6)),
            runtime_unusable_reason: Some("usage_limit_reached".to_string()),
            rate_limit_reset_bank: None,
            is_active: false,
        };
        let result = parse_usage_response(
            br#"{
              "plan_type":"plus",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":1.0,"limit_window_seconds":18000,"reset_at":1893456000},
                "secondary_window":{"used_percent":2.0,"limit_window_seconds":604800,"reset_at":1894060800}
              }
            }"#,
        )
        .unwrap();

        apply_fetch_result(&mut account, result);

        assert_eq!(account.runtime_unusable_until, None);
        assert_eq!(account.runtime_unusable_reason, None);
        assert!(account.quota_snapshot.is_some());
    }

    #[test]
    fn allowed_response_with_rounded_weekly_hundred_is_preserved_and_exhausted() {
        let result = parse_usage_response(
            br#"{
              "plan_type":"pro",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":0.0,"limit_window_seconds":18000,"reset_at":1893456000},
                "secondary_window":{"used_percent":100.0,"limit_window_seconds":604800,"reset_at":1894060800}
              }
            }"#,
        )
        .unwrap();

        assert_eq!(result.snapshot.weekly().unwrap().used_percent, 100.0);
        assert!(result.snapshot.weekly().unwrap().is_exhausted());
        assert_eq!(
            result.snapshot.availability_at(result.snapshot.fetched_at),
            crate::account_store::QuotaAvailability::Blocked
        );
    }

    #[test]
    fn ignores_zero_length_primary_when_weekly_secondary_is_present() {
        let result = parse_usage_response(
            br#"{
              "plan_type":"pro",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":0.0,"limit_window_seconds":0,"reset_at":1893456000},
                "secondary_window":{"used_percent":0.0,"limit_window_seconds":604800,"reset_at":1894060800}
              },
              "additional_rate_limits":[{
                "limit_name":"Codex Spark",
                "rate_limit":{
                  "allowed":true,
                  "limit_reached":false,
                  "primary_window":{"used_percent":0.0,"limit_window_seconds":0,"reset_at":1893456000},
                  "secondary_window":{"used_percent":0.0,"limit_window_seconds":0,"reset_at":1893456000}
                }
              }]
            }"#,
        )
        .unwrap();

        assert!(result.snapshot.five_hour().is_none());
        assert_eq!(result.snapshot.weekly().unwrap().duration_seconds, 604_800);
    }

    #[test]
    fn falls_back_to_valid_additional_rate_limit() {
        let result = parse_usage_response(
            br#"{
              "plan_type":"pro",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":0.0,"limit_window_seconds":0,"reset_at":1893456000},
                "secondary_window":{"used_percent":0.0,"limit_window_seconds":0,"reset_at":1894060800}
              },
              "additional_rate_limits":[{
                "limit_name":"Codex",
                "rate_limit":{
                  "allowed":true,
                  "limit_reached":false,
                  "primary_window":{"used_percent":23.0,"limit_window_seconds":18000,"reset_at":1893456000},
                  "secondary_window":{"used_percent":9.0,"limit_window_seconds":604800,"reset_at":1894060800}
                }
              }]
            }"#,
        )
        .unwrap();

        assert_eq!(result.snapshot.five_hour().unwrap().used_percent, 23.0);
        assert_eq!(result.snapshot.weekly().unwrap().used_percent, 9.0);
    }

    #[test]
    fn denied_response_with_primary_hundred_stays_exhausted() {
        let result = parse_usage_response(
            br#"{
              "plan_type":"pro",
              "rate_limit":{
                "allowed":false,
                "limit_reached":true,
                "primary_window":{"used_percent":100.0,"limit_window_seconds":18000,"reset_at":1893456000},
                "secondary_window":{"used_percent":100.0,"limit_window_seconds":604800,"reset_at":1894060800}
              }
            }"#,
        )
        .unwrap();

        assert_eq!(result.snapshot.five_hour().unwrap().used_percent, 100.0);
        assert!(result.snapshot.is_denied());
    }

    #[test]
    fn successful_fetch_result_normalizes_subscription_flag_from_plan_type() {
        let mut account = CodexAccount {
            id: Uuid::new_v4(),
            email: "upgraded@example.com".to_string(),
            access_token: "access".to_string(),
            refresh_token: "refresh".to_string(),
            id_token: "id".to_string(),
            account_id: "upgraded@example.com".to_string(),
            quota_snapshot: None,
            plan_type: Some("free".to_string()),
            last_refreshed: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: Some(false),
            five_hour_primed_at: None,
            runtime_unusable_until: None,
            runtime_unusable_reason: None,
            rate_limit_reset_bank: None,
            is_active: false,
        };

        let result = parse_usage_response(
            br#"{
              "plan_type":"pro",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":1.0,"limit_window_seconds":18000,"reset_at":1893456000},
                "secondary_window":{"used_percent":2.0,"limit_window_seconds":604800,"reset_at":1894060800}
              }
            }"#,
        )
        .unwrap();

        apply_fetch_result(&mut account, result);

        assert_eq!(account.plan_type.as_deref(), Some("pro"));
        assert_eq!(account.has_active_subscription, Some(true));
    }

    #[test]
    fn successful_fetch_result_marks_free_plan_as_not_subscribed() {
        let mut account = CodexAccount {
            id: Uuid::new_v4(),
            email: "downgraded@example.com".to_string(),
            access_token: "access".to_string(),
            refresh_token: "refresh".to_string(),
            id_token: "id".to_string(),
            account_id: "downgraded@example.com".to_string(),
            quota_snapshot: None,
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
            is_active: false,
        };

        let result = parse_usage_response(
            br#"{
              "plan_type":"free",
              "rate_limit":{
                "allowed":true,
                "limit_reached":false,
                "primary_window":{"used_percent":1.0,"limit_window_seconds":18000,"reset_at":1893456000},
                "secondary_window":{"used_percent":2.0,"limit_window_seconds":604800,"reset_at":1894060800}
              }
            }"#,
        )
        .unwrap();

        apply_fetch_result(&mut account, result);

        assert_eq!(account.plan_type.as_deref(), Some("free"));
        assert_eq!(account.has_active_subscription, Some(false));
    }
}

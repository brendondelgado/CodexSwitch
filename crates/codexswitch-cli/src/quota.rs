use crate::account_store::{CodexAccount, QuotaSnapshot, QuotaWindow};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::Deserialize;
use serde_json::json;
use serde_json::Value;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const UNIX_TO_SWIFT_REFERENCE_SECONDS: i64 = 978_307_200;

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
    let Some(rate_limit) = selected_rate_limit(&response) else {
        bail!("rate limits unavailable: placeholder usage window");
    };
    let hard_limit_reached =
        rate_limit.limit_reached == Some(true) || rate_limit.allowed == Some(false);
    let backend_allows_requests =
        rate_limit.allowed == Some(true) && rate_limit.limit_reached != Some(true);

    let five_hour = map_window(
        rate_limit.primary_window.as_ref(),
        300,
        hard_limit_reached,
        backend_allows_requests,
    );
    let weekly = map_window(
        rate_limit.secondary_window.as_ref(),
        10_080,
        false,
        backend_allows_requests,
    );

    Ok(FetchResult {
        snapshot: QuotaSnapshot {
            five_hour,
            weekly,
            fetched_at: Some(json!(swift_reference_seconds(Utc::now().timestamp()))),
        },
        plan_type: response.plan_type,
    })
}

pub fn apply_fetch_result(account: &mut CodexAccount, result: FetchResult) {
    let fetched_at = result
        .snapshot
        .fetched_at
        .clone()
        .unwrap_or_else(now_swift_reference_value);
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

fn selected_rate_limit(response: &UsageResponse) -> Option<&RateLimitDetails> {
    if let Some(rate_limit) = response.rate_limit.as_ref() {
        if is_usable_primary_window(rate_limit.primary_window.as_ref()) {
            return Some(rate_limit);
        }
    }

    if let Some(additional) = response.additional_rate_limits.as_ref() {
        if let Some(rate_limit) = additional
            .iter()
            .filter_map(|limit| limit.rate_limit.as_ref())
            .find(|limit| is_usable_primary_window(limit.primary_window.as_ref()))
        {
            return Some(rate_limit);
        }
    }

    response.rate_limit.as_ref().filter(|rate_limit| {
        rate_limit.allowed == Some(false) || rate_limit.limit_reached == Some(true)
    })
}

fn is_usable_primary_window(window: Option<&WindowSnapshot>) -> bool {
    window
        .map(|window| window.limit_window_seconds > 0)
        .unwrap_or(false)
}

fn map_window(
    window: Option<&WindowSnapshot>,
    fallback_window_mins: i64,
    hard_limit_reached: bool,
    backend_allows_requests: bool,
) -> QuotaWindow {
    let Some(window) = window else {
        return QuotaWindow {
            used_percent: 0.0,
            window_duration_mins: fallback_window_mins,
            resets_at: json!(swift_reference_seconds(
                Utc::now().timestamp() + fallback_window_mins * 60
            )),
            hard_limit_reached,
        };
    };

    let mut used_percent = window.used_percent.clamp(0.0, 100.0);
    if backend_allows_requests && !hard_limit_reached && used_percent >= 100.0 {
        used_percent = 98.0;
    }

    QuotaWindow {
        used_percent,
        window_duration_mins: if window.limit_window_seconds > 0 {
            (window.limit_window_seconds + 59) / 60
        } else {
            fallback_window_mins
        },
        resets_at: json!(swift_reference_seconds(window.reset_at)),
        hard_limit_reached,
    }
}

fn swift_reference_seconds(unix_seconds: i64) -> f64 {
    (unix_seconds - UNIX_TO_SWIFT_REFERENCE_SECONDS) as f64
}

pub fn now_swift_reference_value() -> Value {
    json!(swift_reference_seconds(Utc::now().timestamp()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

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
        assert!(result.snapshot.five_hour.hard_limit_reached);
        assert_eq!(result.snapshot.weekly.used_percent, 22.5);
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
    fn allowed_response_with_rounded_weekly_hundred_is_not_exhausted() {
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

        assert_eq!(result.snapshot.weekly.used_percent, 98.0);
        assert!(!result.snapshot.weekly.is_exhausted());
        assert!(!result.snapshot.weekly.should_auto_swap_away());
    }

    #[test]
    fn rejects_zero_length_placeholder_usage_window() {
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
        );

        assert!(result
            .unwrap_err()
            .to_string()
            .contains("placeholder usage window"));
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
                "secondary_window":{"used_percent":0.0,"limit_window_seconds":604800,"reset_at":1894060800}
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

        assert_eq!(result.snapshot.five_hour.used_percent, 23.0);
        assert_eq!(result.snapshot.weekly.used_percent, 9.0);
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

        assert_eq!(result.snapshot.five_hour.used_percent, 100.0);
        assert!(result.snapshot.five_hour.is_exhausted());
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

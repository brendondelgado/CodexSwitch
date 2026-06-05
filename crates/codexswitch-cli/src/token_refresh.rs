use crate::account_store::CodexAccount;
use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::Deserialize;

const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";

#[derive(Debug, Deserialize)]
struct TokenResponse {
    #[serde(rename = "access_token")]
    access_token: String,
    #[serde(rename = "id_token")]
    id_token: Option<String>,
    #[serde(rename = "refresh_token")]
    refresh_token: Option<String>,
}

pub fn refresh_account_tokens(account: &mut CodexAccount) -> Result<()> {
    if account.refresh_token.is_empty() {
        bail!("account {} has no refresh token", account.email);
    }

    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("codexswitch-cli")
        .build()
        .context("failed to build HTTP client")?;

    let response = client
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", account.refresh_token.as_str()),
        ])
        .send()
        .with_context(|| format!("failed to refresh token for {}", account.email))?;

    let status = response.status();
    let body = response
        .text()
        .context("failed to read token refresh response body")?;
    if !status.is_success() {
        bail!(
            "token refresh failed for {}: HTTP {}: {}",
            account.email,
            status.as_u16(),
            body.chars().take(500).collect::<String>()
        );
    }

    let token_response: TokenResponse =
        serde_json::from_str(&body).context("failed to decode token refresh response")?;
    account.access_token = token_response.access_token;
    if let Some(id_token) = token_response.id_token {
        account.id_token = id_token;
    }
    if let Some(refresh_token) = token_response.refresh_token {
        account.refresh_token = refresh_token;
    }
    account.last_refreshed = Some(crate::quota::now_swift_reference_value());
    account.runtime_unusable_until = None;
    account.runtime_unusable_reason = None;
    eprintln!(
        "refreshed token for {} at {}",
        account.email,
        Utc::now().to_rfc3339()
    );
    Ok(())
}

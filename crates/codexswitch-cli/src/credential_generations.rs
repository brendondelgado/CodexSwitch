//! Read-only export of this host's newest credential generation per provider
//! account. The Mac pulls this report over the authenticated SSH transport so a
//! refresh performed on the VPS can return to the Mac (see "Token refresh
//! ownership" in `docs/architecture/runtime-and-host-ownership.md`).
//!
//! The report contains live OAuth tokens. It is written only to stdout, never to
//! a log, and the command performs no provider I/O, lock creation, or mutation.

use crate::account_store::{
    inference_token_expiration, inference_token_issued_at, load_accounts,
    normalize_provider_account_id,
};
use crate::secure_file;
use anyhow::Result;
use serde::Serialize;
use serde_json::Value;
use std::path::Path;

pub const REPORT_VERSION: u32 = 1;
const AUTH_FILE_MAX_BYTES: usize = 1024 * 1024;

/// Orders token generations: later access-token `exp`, then later `iat`.
/// `None` means the access token is not a decodable JWT and cannot be ordered.
pub(crate) fn generation_key(access_token: &str) -> Option<(i64, i64)> {
    let expires_at = inference_token_expiration(access_token)?.timestamp();
    let issued_at =
        inference_token_issued_at(access_token).map_or(i64::MIN, |value| value.timestamp());
    Some((expires_at, issued_at))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialGenerationReport {
    version: u32,
    accounts: Vec<CredentialGeneration>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct CredentialGeneration {
    provider_account_id: String,
    access_token_expires_at: Option<i64>,
    access_token_issued_at: Option<i64>,
    /// `store` (account store) or `auth` (a newer runtime-refreshed auth.json).
    source: &'static str,
    id_token: String,
    access_token: String,
    refresh_token: String,
}

struct TokenSet {
    account_id: String,
    id_token: String,
    access_token: String,
    refresh_token: String,
}

/// Emits one `store` entry per account with complete tokens, plus one `auth`
/// entry when a runtime on this host refreshed its account into auth.json and
/// the coordinator has not adopted that newer generation into the store yet.
/// The Mac adopts the newest entry but pushes against the `store` entry, so a
/// dead store chain is still repaired while the runtime holds the live one.
pub fn observe(store_path: &Path, auth_path: &Path) -> Result<CredentialGenerationReport> {
    let accounts = load_accounts(store_path)?;
    let mut generations: Vec<_> = accounts
        .iter()
        .filter(|account| account.has_complete_token_material())
        .map(|account| {
            generation(
                "store",
                &account.account_id,
                &account.id_token,
                &account.access_token,
                &account.refresh_token,
            )
        })
        .collect();
    // An unreadable or foreign auth file only drops the auth candidate.
    if let Some(auth) = observe_auth_tokens(auth_path) {
        let owner = accounts.iter().find(|account| {
            account.has_complete_token_material()
                && normalize_provider_account_id(&account.account_id)
                    == normalize_provider_account_id(&auth.account_id)
        });
        if let Some(account) = owner {
            let newer = match (
                generation_key(&auth.access_token),
                generation_key(&account.access_token),
            ) {
                (Some(auth_key), Some(store_key)) => auth_key > store_key,
                (Some(_), None) => true,
                (None, _) => false,
            };
            if newer {
                generations.push(generation(
                    "auth",
                    &account.account_id,
                    &auth.id_token,
                    &auth.access_token,
                    &auth.refresh_token,
                ));
            }
        }
    }
    Ok(CredentialGenerationReport {
        version: REPORT_VERSION,
        accounts: generations,
    })
}

fn generation(
    source: &'static str,
    provider_account_id: &str,
    id_token: &str,
    access_token: &str,
    refresh_token: &str,
) -> CredentialGeneration {
    CredentialGeneration {
        provider_account_id: provider_account_id.to_string(),
        access_token_expires_at: inference_token_expiration(access_token)
            .map(|value| value.timestamp()),
        access_token_issued_at: inference_token_issued_at(access_token)
            .map(|value| value.timestamp()),
        source,
        id_token: id_token.to_string(),
        access_token: access_token.to_string(),
        refresh_token: refresh_token.to_string(),
    }
}

fn observe_auth_tokens(auth_path: &Path) -> Option<TokenSet> {
    let snapshot = secure_file::observe(auth_path, AUTH_FILE_MAX_BYTES, true).ok()?;
    let value: Value = serde_json::from_slice(snapshot.bytes()?).ok()?;
    let tokens = value.get("tokens")?;
    let field = |name: &str| {
        tokens
            .get(name)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
    };
    Some(TokenSet {
        account_id: field("account_id")?,
        id_token: field("id_token")?,
        access_token: field("access_token")?,
        refresh_token: field("refresh_token")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{save_accounts, test_inference_token};
    use chrono::{Duration, Utc};

    #[test]
    fn report_prefers_a_newer_runtime_auth_generation_for_the_same_account() -> Result<()> {
        let temp = tempfile::TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = crate::account_store::CodexAccount {
            id: uuid::Uuid::new_v4(),
            email: "active@example.com".to_string(),
            access_token: test_inference_token(Utc::now() + Duration::days(1)),
            refresh_token: "store-refresh".to_string(),
            id_token: "id".to_string(),
            account_id: "Provider-A".to_string(),
            quota_snapshot: None,
            plan_type: None,
            last_refreshed: None,
            subscription_renews_at: None,
            subscription_expires_at: None,
            subscription_will_renew: None,
            has_active_subscription: None,
            five_hour_primed_at: None,
            runtime_unusable_until: None,
            runtime_unusable_reason: None,
            rate_limit_reset_bank: None,
            is_active: true,
        };
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        active.access_token = test_inference_token(Utc::now() + Duration::days(10));
        active.refresh_token = "runtime-refresh".to_string();
        active.account_id = "provider-a".to_string();
        crate::auth::write_auth_file(&auth_path, &active)?;

        let report = observe(&store_path, &auth_path)?;
        assert_eq!(report.accounts.len(), 2);
        assert_eq!(report.accounts[0].source, "store");
        assert_eq!(report.accounts[0].refresh_token, "store-refresh");
        assert_eq!(report.accounts[1].source, "auth");
        assert_eq!(report.accounts[1].refresh_token, "runtime-refresh");
        assert_eq!(report.accounts[1].provider_account_id, "Provider-A");

        // An older auth generation is not reported.
        active.access_token = test_inference_token(Utc::now() + Duration::hours(1));
        active.refresh_token = "stale-refresh".to_string();
        crate::auth::write_auth_file(&auth_path, &active)?;
        let report = observe(&store_path, &auth_path)?;
        assert_eq!(report.accounts.len(), 1);
        assert_eq!(report.accounts[0].source, "store");
        Ok(())
    }
}

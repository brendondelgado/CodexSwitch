use crate::account_store::CodexAccount;
use crate::secure_file::{self, SecureFileGeneration};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use ring::digest::{Context as DigestContext, SHA256};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};

const AUTH_FILE_MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug, Serialize)]
struct AuthFile<'a> {
    #[serde(rename = "auth_mode")]
    auth_mode: &'static str,
    #[serde(rename = "OPENAI_API_KEY")]
    openai_api_key: Option<&'a str>,
    tokens: AuthTokens<'a>,
    #[serde(rename = "last_refresh")]
    last_refresh: String,
}

#[derive(Debug, Serialize)]
struct AuthTokens<'a> {
    #[serde(rename = "id_token")]
    id_token: &'a str,
    #[serde(rename = "access_token")]
    access_token: &'a str,
    #[serde(rename = "refresh_token")]
    refresh_token: &'a str,
    #[serde(rename = "account_id")]
    account_id: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthFileSnapshot {
    bytes: Option<Vec<u8>>,
    #[serde(default)]
    generation: Option<SecureFileGeneration>,
}

impl AuthFileSnapshot {
    pub fn generation(&self) -> Option<&SecureFileGeneration> {
        self.generation.as_ref()
    }
}

#[derive(Debug, Clone)]
pub struct AuthFileCommit {
    pub token_fingerprint: String,
    pub generation: SecureFileGeneration,
}

pub fn default_auth_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".codex/auth.json"))
}

#[cfg(test)]
pub fn write_auth_file(path: &Path, account: &CodexAccount) -> Result<()> {
    commit_auth_file(path, account).map(|_| ())
}

pub fn commit_auth_file(path: &Path, account: &CodexAccount) -> Result<AuthFileCommit> {
    let expected_fingerprint = account_token_fingerprint(account)
        .context("cannot activate account with incomplete token material")?;
    let auth = AuthFile {
        auth_mode: "chatgpt",
        openai_api_key: None,
        tokens: AuthTokens {
            id_token: &account.id_token,
            access_token: &account.access_token,
            refresh_token: &account.refresh_token,
            account_id: &account.account_id,
        },
        last_refresh: Utc::now().to_rfc3339(),
    };

    let data = serde_json::to_vec_pretty(&auth).context("failed to encode auth file")?;
    let transaction = secure_file::lock(path, true)?;
    let current = transaction.load(AUTH_FILE_MAX_BYTES, true)?;
    if current
        .bytes()
        .and_then(auth_fingerprint_from_bytes)
        .as_deref()
        == Some(expected_fingerprint.as_str())
    {
        return Ok(AuthFileCommit {
            token_fingerprint: expected_fingerprint,
            generation: current.generation().clone(),
        });
    }
    let readback = transaction.commit(current.generation(), &data, AUTH_FILE_MAX_BYTES)?;
    let readback_fingerprint = readback
        .bytes()
        .and_then(auth_fingerprint_from_bytes)
        .context("auth readback is incomplete")?;
    if readback_fingerprint != expected_fingerprint {
        bail!("auth readback fingerprint did not match selected account");
    }
    Ok(AuthFileCommit {
        token_fingerprint: readback_fingerprint,
        generation: readback.generation().clone(),
    })
}

pub fn capture_auth_file(path: &Path) -> Result<AuthFileSnapshot> {
    let transaction = secure_file::lock(path, true)?;
    let snapshot = transaction.load(AUTH_FILE_MAX_BYTES, true)?;
    Ok(AuthFileSnapshot {
        bytes: snapshot.bytes().map(<[u8]>::to_vec),
        generation: Some(snapshot.generation().clone()),
    })
}

pub fn auth_file_matches_snapshot(path: &Path, snapshot: &AuthFileSnapshot) -> bool {
    secure_file::lock(path, false)
        .and_then(|transaction| transaction.load(AUTH_FILE_MAX_BYTES, true))
        .is_ok_and(|current| current.bytes() == snapshot.bytes.as_deref())
}

pub fn restore_auth_file_if_owned(
    path: &Path,
    owned_generation: &SecureFileGeneration,
    snapshot: &AuthFileSnapshot,
) -> Result<()> {
    let transaction = secure_file::lock(path, false)?;
    let current = transaction.load(AUTH_FILE_MAX_BYTES, true)?;
    if current.bytes() == snapshot.bytes.as_deref() {
        return Ok(());
    }
    let restored = transaction
        .replace(
            owned_generation,
            snapshot.bytes.as_deref(),
            AUTH_FILE_MAX_BYTES,
        )
        .context("auth rollback generation CAS failed; concurrent auth state was preserved")?;
    if restored.bytes() != snapshot.bytes.as_deref() {
        bail!("auth rollback readback did not match the pre-activation bytes");
    }
    Ok(())
}

#[cfg(test)]
fn restore_auth_file_if_owned_with_test_hook<F>(
    path: &Path,
    owned_generation: &SecureFileGeneration,
    snapshot: &AuthFileSnapshot,
    before_final_compare: F,
) -> Result<()>
where
    F: FnOnce() -> Result<()>,
{
    let transaction = secure_file::lock(path, false)?;
    let current = transaction.load(AUTH_FILE_MAX_BYTES, true)?;
    if current.bytes() == snapshot.bytes.as_deref() {
        return Ok(());
    }
    let bytes = snapshot
        .bytes
        .as_deref()
        .context("test hook requires a present rollback image")?;
    transaction
        .commit_with_test_hook(
            owned_generation,
            bytes,
            AUTH_FILE_MAX_BYTES,
            before_final_compare,
        )
        .map(|_| ())
}

pub fn auth_file_matches_account(path: &Path, account: &CodexAccount) -> bool {
    auth_file_fingerprint(path)
        .zip(account_token_fingerprint(account))
        .is_some_and(|(auth, account)| auth == account)
}

pub fn account_token_fingerprint(account: &CodexAccount) -> Option<String> {
    token_fingerprint(
        &account.id_token,
        &account.access_token,
        &account.refresh_token,
        &account.account_id,
    )
}

pub fn auth_file_fingerprint(path: &Path) -> Option<String> {
    let snapshot = secure_file::observe(path, AUTH_FILE_MAX_BYTES, false).ok()?;
    auth_fingerprint_from_bytes(snapshot.bytes()?)
}

pub fn auth_file_generation(path: &Path) -> Option<SecureFileGeneration> {
    secure_file::observe(path, AUTH_FILE_MAX_BYTES, true)
        .ok()
        .map(|snapshot| snapshot.generation().clone())
}

fn auth_fingerprint_from_bytes(data: &[u8]) -> Option<String> {
    let Ok(value) = serde_json::from_slice::<Value>(data) else {
        return None;
    };
    let tokens = value.get("tokens")?;
    token_fingerprint(
        tokens.get("id_token")?.as_str()?,
        tokens.get("access_token")?.as_str()?,
        tokens.get("refresh_token")?.as_str()?,
        tokens.get("account_id")?.as_str()?,
    )
}

fn token_fingerprint(id: &str, access: &str, refresh: &str, account_id: &str) -> Option<String> {
    let parts = [id, access, refresh, account_id];
    if parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    let mut digest = DigestContext::new(&SHA256);
    for part in parts {
        digest.update(&(part.len() as u64).to_be_bytes());
        digest.update(part.as_bytes());
    }
    Some(
        digest
            .finish()
            .as_ref()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::CodexAccount;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use uuid::Uuid;

    fn account(label: &str) -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: format!("{label}@example.com"),
            access_token: format!("access-{label}"),
            refresh_token: format!("refresh-{label}"),
            id_token: format!("id-{label}"),
            account_id: format!("account-{label}"),
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
            is_active: true,
        }
    }

    #[test]
    fn rollback_cas_preserves_concurrent_auth_replacement() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("auth.json");
        let concurrent_path = temp.path().join("concurrent.json");
        let original = account("original");
        let owned = account("owned");
        let concurrent = account("concurrent");
        commit_auth_file(&path, &original)?;
        let rollback = capture_auth_file(&path)?;
        let owned_commit = commit_auth_file(&path, &owned)?;
        commit_auth_file(&concurrent_path, &concurrent)?;
        let concurrent_bytes = fs::read(&concurrent_path)?;

        let error = restore_auth_file_if_owned_with_test_hook(
            &path,
            &owned_commit.generation,
            &rollback,
            || {
                let replacement = temp.path().join("outside-auth.tmp");
                fs::write(&replacement, &concurrent_bytes)?;
                fs::set_permissions(&replacement, fs::Permissions::from_mode(0o600))?;
                fs::rename(replacement, &path)?;
                Ok(())
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("generation changed"));
        assert!(auth_file_matches_account(&path, &concurrent));
        assert!(!auth_file_matches_account(&path, &original));
        Ok(())
    }
}

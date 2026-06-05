use crate::account_store::CodexAccount;
use anyhow::{Context, Result};
use chrono::Utc;
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

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

pub fn default_auth_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".codex/auth.json"))
}

pub fn write_auth_file(path: &Path, account: &CodexAccount) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        ensure_permissions(parent, 0o700)?;
    }

    if auth_file_matches_account(path, account) {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod {}", path.display()))?;
        return Ok(());
    }

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

    let tmp = path.with_extension("json.tmp");
    let data = serde_json::to_vec_pretty(&auth).context("failed to encode auth file")?;
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

fn auth_file_matches_account(path: &Path, account: &CodexAccount) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    let Ok(value) = serde_json::from_slice::<Value>(&data) else {
        return false;
    };
    let Some(tokens) = value.get("tokens") else {
        return false;
    };
    value.get("auth_mode").and_then(Value::as_str) == Some("chatgpt")
        && tokens.get("id_token").and_then(Value::as_str) == Some(account.id_token.as_str())
        && tokens.get("access_token").and_then(Value::as_str) == Some(account.access_token.as_str())
        && tokens.get("refresh_token").and_then(Value::as_str)
            == Some(account.refresh_token.as_str())
        && tokens.get("account_id").and_then(Value::as_str) == Some(account.account_id.as_str())
}

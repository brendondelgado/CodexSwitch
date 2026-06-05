use crate::account_store::{active_account, CodexAccount};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use ring::digest::{digest, SHA256};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const PROVIDER: &str = "openai-codex";
const MODEL: &str = "gpt-5.5";
const BASE_URL: &str = "https://chatgpt.com/backend-api/codex";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HermesStatus {
    pub hermes_home: String,
    pub hermes_home_exists: bool,
    pub auth_exists: bool,
    pub env_exists: bool,
    pub config_exists: bool,
    pub active_provider: Option<String>,
    pub token_hash_prefix: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub tui_running: bool,
    pub gateway_status: Option<String>,
    pub summary: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HermesApplyReport {
    pub auth_path: String,
    pub token_hash_prefix: String,
    pub auth_backup_path: Option<String>,
    pub env_backup_path: Option<String>,
    pub gateway_restarted: bool,
    pub tui_running: bool,
    pub restart_hint: Option<String>,
}

pub fn default_home() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".hermes"))
}

pub fn status(json_output: bool, include_gateway: bool) -> Result<()> {
    let status = inspect(default_home()?, include_gateway)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&status)?);
    } else {
        println!("Hermes status: {}", status.summary);
        println!("home: {}", status.hermes_home);
        println!("auth exists: {}", status.auth_exists);
        println!("config exists: {}", status.config_exists);
        println!(
            "provider: {}",
            status.provider.as_deref().unwrap_or("unknown")
        );
        println!("model: {}", status.model.as_deref().unwrap_or("unknown"));
        println!(
            "token hash: {}",
            status.token_hash_prefix.as_deref().unwrap_or("none")
        );
        println!("Hermes TUI running: {}", status.tui_running);
        if let Some(gateway) = status.gateway_status {
            println!("gateway: {gateway}");
        }
    }
    Ok(())
}

pub fn apply_active(
    accounts: &[CodexAccount],
    restart_gateway: bool,
    json_output: bool,
) -> Result<()> {
    let active = active_account(accounts).context("no active account in store")?;
    let report = apply_account(active, restart_gateway)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!(
            "Hermes OpenAI Codex auth updated at {}; token hash {}",
            report.auth_path, report.token_hash_prefix
        );
        if report.gateway_restarted {
            println!("Hermes gateway restarted");
        }
        if let Some(hint) = report.restart_hint {
            println!("{hint}");
        }
    }
    Ok(())
}

pub fn apply_account_if_configured(account: &CodexAccount) -> Result<Option<HermesApplyReport>> {
    let home = default_home()?;
    if !home.exists() {
        return Ok(None);
    }
    apply_account_to_home(account, &home, false).map(Some)
}

fn inspect(home: PathBuf, include_gateway: bool) -> Result<HermesStatus> {
    let auth_path = home.join("auth.json");
    let config_path = home.join("config.yaml");
    let auth = read_json_object_if_present(&auth_path)?;
    let active_provider = auth
        .get("active_provider")
        .and_then(Value::as_str)
        .map(str::to_string);
    let auth_value = Value::Object(auth.clone());
    let token_hash_prefix = auth_value
        .pointer("/providers/openai-codex/tokens/access_token")
        .and_then(Value::as_str)
        .map(token_hash_prefix);
    let config = fs::read_to_string(&config_path).unwrap_or_default();
    let summary = if !home.exists() {
        "Hermes home not found".to_string()
    } else if !auth_path.exists() {
        "Hermes OpenAI Codex auth not installed".to_string()
    } else if active_provider.as_deref() != Some(PROVIDER) {
        "Hermes auth exists but OpenAI Codex is not active".to_string()
    } else {
        "Hermes OpenAI Codex auth ready".to_string()
    };
    Ok(HermesStatus {
        hermes_home: home.display().to_string(),
        hermes_home_exists: home.exists(),
        auth_exists: auth_path.exists(),
        env_exists: home.join(".env").exists(),
        config_exists: config_path.exists(),
        active_provider,
        token_hash_prefix,
        provider: yaml_scalar(&config, "model", "provider"),
        model: yaml_scalar(&config, "model", "default"),
        tui_running: hermes_tui_running(),
        gateway_status: if include_gateway {
            gateway_status()
        } else {
            None
        },
        summary,
    })
}

fn apply_account(account: &CodexAccount, restart_gateway: bool) -> Result<HermesApplyReport> {
    apply_account_to_home(account, &default_home()?, restart_gateway)
}

fn apply_account_to_home(
    account: &CodexAccount,
    home: &Path,
    restart_gateway: bool,
) -> Result<HermesApplyReport> {
    if account.access_token.is_empty() || account.refresh_token.is_empty() {
        bail!("selected account is missing OAuth token material");
    }

    fs::create_dir_all(home).with_context(|| format!("failed to create {}", home.display()))?;
    fs::set_permissions(home, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to chmod {}", home.display()))?;

    let env_backup = harden_env_if_present(home)?;
    let auth_path = home.join("auth.json");
    let auth_backup = backup_if_exists(&auth_path)?;
    write_auth(account, &auth_path)?;
    configure_model(home)?;
    let mut gateway_restarted = false;
    if restart_gateway {
        restart_gateway_process()?;
        gateway_restarted = true;
    }
    let tui_running = hermes_tui_running();
    Ok(HermesApplyReport {
        auth_path: auth_path.display().to_string(),
        token_hash_prefix: token_hash_prefix(&account.access_token),
        auth_backup_path: auth_backup.map(|path| path.display().to_string()),
        env_backup_path: env_backup.map(|path| path.display().to_string()),
        gateway_restarted,
        tui_running,
        restart_hint: tui_running.then(|| {
            "Hermes TUI is running; restart/resume it to pick up the updated token.".to_string()
        }),
    })
}

fn write_auth(account: &CodexAccount, path: &Path) -> Result<()> {
    let mut root = read_json_object_if_present(path)?;
    merge_auth(account, &mut root);
    let data =
        serde_json::to_vec_pretty(&Value::Object(root)).context("failed to encode Hermes auth")?;
    let tmp = path.with_extension(format!("json.codexswitch-{}.tmp", std::process::id()));
    fs::write(&tmp, data).with_context(|| format!("failed to write {}", tmp.display()))?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", tmp.display()))?;
    fs::rename(&tmp, path)
        .with_context(|| format!("failed to atomically replace {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", path.display()))?;
    Ok(())
}

fn merge_auth(account: &CodexAccount, root: &mut Map<String, Value>) {
    let timestamp = Utc::now().to_rfc3339();
    root.entry("version").or_insert(json!(1));
    root.insert("updated_at".to_string(), json!(timestamp));
    root.insert("active_provider".to_string(), json!(PROVIDER));

    let providers = root
        .entry("providers")
        .or_insert_with(|| Value::Object(Map::new()));
    if !providers.is_object() {
        *providers = Value::Object(Map::new());
    }
    let providers = providers.as_object_mut().expect("providers object");
    let provider = providers
        .entry(PROVIDER)
        .or_insert_with(|| Value::Object(Map::new()));
    if !provider.is_object() {
        *provider = Value::Object(Map::new());
    }
    let provider = provider.as_object_mut().expect("provider object");
    provider.insert("auth_mode".to_string(), json!("chatgpt"));
    provider.insert("last_refresh".to_string(), json!(timestamp));
    provider.insert("label".to_string(), json!(account.email));
    provider.insert(
        "tokens".to_string(),
        json!({
            "id_token": account.id_token,
            "access_token": account.access_token,
            "refresh_token": account.refresh_token,
            "account_id": account.account_id,
        }),
    );
}

fn read_json_object_if_present(path: &Path) -> Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(Map::new());
    }
    let data = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let value: Value = match serde_json::from_slice(&data) {
        Ok(value) => value,
        Err(_) => {
            let backup = corrupt_backup_path(path);
            fs::rename(path, &backup).with_context(|| {
                format!(
                    "failed to move corrupt Hermes auth {} to {}",
                    path.display(),
                    backup.display()
                )
            })?;
            return Ok(Map::new());
        }
    };
    value
        .as_object()
        .cloned()
        .context("Hermes auth store is not a JSON object")
}

fn corrupt_backup_path(path: &Path) -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    path.with_extension(format!("json.corrupt-{timestamp}"))
}

fn harden_env_if_present(home: &Path) -> Result<Option<PathBuf>> {
    let env = home.join(".env");
    if !env.exists() {
        return Ok(None);
    }
    let backup = backup_if_exists(&env)?;
    fs::set_permissions(&env, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", env.display()))?;
    Ok(backup)
}

fn backup_if_exists(path: &Path) -> Result<Option<PathBuf>> {
    if !path.exists() {
        return Ok(None);
    }
    let backup = path.with_file_name(format!(
        "{}.codexswitch-backup-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("file"),
        Utc::now().format("%Y%m%d-%H%M%S")
    ));
    fs::copy(path, &backup).with_context(|| {
        format!(
            "failed to back up {} to {}",
            path.display(),
            backup.display()
        )
    })?;
    fs::set_permissions(&backup, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to chmod {}", backup.display()))?;
    Ok(Some(backup))
}

fn configure_model(home: &Path) -> Result<()> {
    let config = home.join("config.yaml");
    let existing = fs::read_to_string(&config).unwrap_or_default();
    let updated = update_model_config(&existing);
    fs::write(&config, updated).with_context(|| format!("failed to write {}", config.display()))
}

pub(crate) fn update_model_config(text: &str) -> String {
    let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
    if text.is_empty() {
        lines.clear();
    }
    let Some(model_index) = lines.iter().position(|line| line.trim() == "model:") else {
        let mut output = text.to_string();
        if !output.is_empty() && !output.ends_with('\n') {
            output.push('\n');
        }
        output.push_str(&format!(
            "model:\n  default: \"{MODEL}\"\n  provider: \"{PROVIDER}\"\n  base_url: \"{BASE_URL}\"\n"
        ));
        return output;
    };
    let end_index = lines[model_index + 1..]
        .iter()
        .position(|line| !line.is_empty() && !line.starts_with(' ') && !line.starts_with('\t'))
        .map(|offset| model_index + 1 + offset)
        .unwrap_or(lines.len());
    let mut block = lines[model_index..end_index].to_vec();
    upsert_yaml_scalar(&mut block, "default", MODEL);
    upsert_yaml_scalar(&mut block, "provider", PROVIDER);
    upsert_yaml_scalar(&mut block, "base_url", BASE_URL);
    lines.splice(model_index..end_index, block);
    let mut output = lines.join("\n");
    if text.ends_with('\n') && !output.ends_with('\n') {
        output.push('\n');
    }
    output
}

fn upsert_yaml_scalar(block: &mut Vec<String>, key: &str, value: &str) {
    let replacement = format!("  {key}: \"{value}\"");
    if let Some(index) = block
        .iter()
        .position(|line| line.trim_start().starts_with(&format!("{key}:")))
    {
        block[index] = replacement;
    } else {
        block.push(replacement);
    }
}

fn yaml_scalar(text: &str, parent: &str, key: &str) -> Option<String> {
    let lines: Vec<&str> = text.lines().collect();
    let parent_index = lines
        .iter()
        .position(|line| line.trim() == format!("{parent}:"))?;
    for line in lines.iter().skip(parent_index + 1) {
        if !line.is_empty() && !line.starts_with(' ') && !line.starts_with('\t') {
            return None;
        }
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix(&format!("{key}:")) {
            return Some(
                value
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string(),
            );
        }
    }
    None
}

fn token_hash_prefix(token: &str) -> String {
    let hash = digest(&SHA256, token.as_bytes());
    hash.as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()[..12]
        .to_string()
}

fn hermes_tui_running() -> bool {
    let output = Command::new("ps").args(["-eo", "pid=,args="]).output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    String::from_utf8_lossy(&output.stdout).lines().any(|line| {
        let lower = line.to_ascii_lowercase();
        lower.contains("hermes")
            && (lower.contains("--tui") || lower.contains(" hermes tui"))
            && !lower.contains("codexswitch-cli")
            && !lower.contains("pgrep")
    })
}

fn gateway_status() -> Option<String> {
    let hermes = hermes_executable_path()?;
    let output = Command::new(hermes)
        .args(["gateway", "status"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !text.is_empty() {
        return Some(text);
    }
    let text = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if text.is_empty() {
        Some(format!("exit {}", output.status.code().unwrap_or(-1)))
    } else {
        Some(text)
    }
}

fn restart_gateway_process() -> Result<()> {
    let hermes = hermes_executable_path().context("hermes executable not found")?;
    let output = Command::new(&hermes)
        .args(["gateway", "restart"])
        .output()
        .with_context(|| format!("failed to run {} gateway restart", hermes.display()))?;
    if output.status.success() {
        return Ok(());
    }
    let message = String::from_utf8_lossy(if output.stderr.is_empty() {
        &output.stdout
    } else {
        &output.stderr
    })
    .trim()
    .to_string();
    bail!(
        "hermes gateway restart failed: {}",
        if message.is_empty() {
            "unknown error"
        } else {
            &message
        }
    )
}

fn hermes_executable_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CODEXSWITCH_HERMES_BIN").map(PathBuf::from) {
        if path.exists() {
            return Some(path);
        }
    }

    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut candidates = Vec::new();
    if let Some(home) = home.as_ref() {
        candidates.extend(hermes_executable_candidates(home));
    }
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin/hermes"),
        PathBuf::from("/usr/local/bin/hermes"),
        PathBuf::from("/usr/bin/hermes"),
    ]);

    candidates.into_iter().find(|path| path.exists())
}

fn hermes_executable_candidates(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".hermes/hermes-agent/venv/bin/hermes"),
        home.join(".local/bin/hermes"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::CodexAccount;
    use tempfile::TempDir;
    use uuid::Uuid;

    fn account() -> CodexAccount {
        CodexAccount {
            id: Uuid::new_v4(),
            email: "hermes@example.com".to_string(),
            access_token: "access-secret".to_string(),
            refresh_token: "refresh-secret".to_string(),
            id_token: "id-secret".to_string(),
            account_id: "acct-123".to_string(),
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
            is_active: true,
        }
    }

    #[test]
    fn update_model_config_replaces_only_model_block() {
        let updated = update_model_config(
            "ui:\n  theme: dark\nmodel:\n  default: \"old\"\n  provider: \"auto\"\nother:\n  enabled: true\n",
        );
        assert!(updated.contains("ui:\n  theme: dark"));
        assert!(updated.contains("default: \"gpt-5.5\""));
        assert!(updated.contains("provider: \"openai-codex\""));
        assert!(updated.contains("base_url: \"https://chatgpt.com/backend-api/codex\""));
        assert!(updated.contains("other:\n  enabled: true"));
    }

    #[test]
    fn hermes_executable_candidates_prefer_venv_install() {
        let home = PathBuf::from("/home/signul");
        let candidates = hermes_executable_candidates(&home);

        assert_eq!(
            candidates[0],
            PathBuf::from("/home/signul/.hermes/hermes-agent/venv/bin/hermes")
        );
        assert_eq!(
            candidates[1],
            PathBuf::from("/home/signul/.local/bin/hermes")
        );
    }

    #[test]
    fn apply_account_writes_auth_and_hardens_env_without_printing_secret() -> Result<()> {
        let temp = TempDir::new()?;
        let env = temp.path().join(".env");
        fs::write(&env, "UNRELATED=1\n")?;
        fs::set_permissions(&env, fs::Permissions::from_mode(0o644))?;

        let report = apply_account_to_home(&account(), temp.path(), false)?;

        assert_eq!(report.token_hash_prefix, token_hash_prefix("access-secret"));
        assert!(report.env_backup_path.is_some());
        let auth: Value = serde_json::from_slice(&fs::read(temp.path().join("auth.json"))?)?;
        assert_eq!(auth["active_provider"], PROVIDER);
        assert_eq!(
            auth.pointer("/providers/openai-codex/tokens/access_token")
                .and_then(Value::as_str),
            Some("access-secret")
        );
        assert_eq!(
            fs::metadata(temp.path().join("auth.json"))?
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(fs::metadata(env)?.permissions().mode() & 0o777, 0o600);
        Ok(())
    }
}

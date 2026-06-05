use crate::patched_codex;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

const NPM_LATEST_URL: &str = "https://registry.npmjs.org/@openai%2Fcodex/latest";
const CODEX_REPO_URL: &str = "https://github.com/openai/codex.git";
const DAILY_CHECK_HOURS: i64 = 24;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatus {
    Idle,
    Checking,
    Preparing,
    Installing,
    ReadyToInstall,
    Installed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexUpdateState {
    pub status: UpdateStatus,
    pub last_checked_at: Option<DateTime<Utc>>,
    pub latest_stable_version: Option<String>,
    pub installed_version: Option<String>,
    pub prepared_version: Option<String>,
    pub prepared_source_path: Option<String>,
    pub prepared_binary_path: Option<String>,
    pub error: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexUpdateReport {
    pub status: UpdateStatus,
    pub summary: String,
    pub last_checked_at: Option<DateTime<Utc>>,
    pub latest_stable_version: Option<String>,
    pub installed_version: Option<String>,
    pub prepared_version: Option<String>,
    pub prepared_source_path: Option<String>,
    pub prepared_binary_path: Option<String>,
    pub install_command: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NpmLatest {
    version: String,
}

impl Default for CodexUpdateState {
    fn default() -> Self {
        Self {
            status: UpdateStatus::Idle,
            last_checked_at: None,
            latest_stable_version: None,
            installed_version: installed_codex_version(),
            prepared_version: None,
            prepared_source_path: None,
            prepared_binary_path: None,
            error: None,
            updated_at: Utc::now(),
        }
    }
}

pub fn status_report() -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    state.installed_version = installed_codex_version();
    let changed = reconcile_installed_state(&mut state);
    if changed {
        save_state(&state)?;
    }
    let report = report_from_state(state);
    Ok(report)
}

pub fn check_for_update(force: bool, prepare: bool) -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    if !force && !check_due(&state) {
        state.installed_version = installed_codex_version();
        return Ok(report_from_state(state));
    }

    state.status = UpdateStatus::Checking;
    state.last_checked_at = Some(Utc::now());
    state.error = None;
    save_state(&state)?;

    match fetch_latest_stable_version() {
        Ok(latest) => {
            state.latest_stable_version = Some(latest.clone());
            state.installed_version = installed_codex_version();
            if !version_is_stable(&latest) {
                state.status = UpdateStatus::Failed;
                state.error = Some(format!(
                    "registry latest resolved to non-stable version {latest}; refusing"
                ));
            } else if state.installed_version.as_deref() == Some(latest.as_str()) {
                state.status = UpdateStatus::Installed;
                state.prepared_version = None;
                state.prepared_source_path = None;
                state.prepared_binary_path = None;
            } else if state.prepared_version.as_deref() == Some(latest.as_str())
                && state
                    .prepared_binary_path
                    .as_deref()
                    .map(Path::new)
                    .is_some_and(patched_codex::binary_has_hot_swap_markers)
            {
                state.status = UpdateStatus::ReadyToInstall;
            } else if prepare {
                save_state(&state)?;
                return prepare_version(&latest);
            } else {
                state.status = UpdateStatus::Idle;
            }
        }
        Err(error) => {
            state.status = UpdateStatus::Failed;
            state.error = Some(format!("{error:#}"));
        }
    }

    state.updated_at = Utc::now();
    save_state(&state)?;
    Ok(report_from_state(state))
}

pub fn prepare_version(version: &str) -> Result<CodexUpdateReport> {
    if !version_is_stable(version) {
        bail!("refusing to prepare non-stable Codex version {version}");
    }

    let source_dir = codexswitch_data_dir()?.join(format!("codex-source-stable-{version}"));
    let prepared_dir = codexswitch_data_dir()?.join("prepared-codex").join(version);
    let prepared_binary = prepared_dir.join("codex");
    let mut state = load_state()?;
    state.status = UpdateStatus::Preparing;
    state.latest_stable_version = Some(version.to_string());
    state.prepared_version = Some(version.to_string());
    state.prepared_source_path = Some(source_dir.display().to_string());
    state.prepared_binary_path = Some(prepared_binary.display().to_string());
    state.error = None;
    state.updated_at = Utc::now();
    save_state(&state)?;

    let result = (|| -> Result<()> {
        checkout_stable_source(version, &source_dir)?;
        patch_codex_source(&source_dir)?;
        let workspace = source_dir.join("codex-rs");
        let built_binary = patched_codex::build_codex(&workspace)?;
        fs::create_dir_all(&prepared_dir)?;
        fs::copy(&built_binary, &prepared_binary).with_context(|| {
            format!(
                "failed to stage {} at {}",
                built_binary.display(),
                prepared_binary.display()
            )
        })?;
        set_executable(&prepared_binary)?;
        if !patched_codex::binary_has_hot_swap_markers(&prepared_binary) {
            bail!(
                "staged Codex binary is missing hot-swap markers: {}",
                prepared_binary.display()
            );
        }
        let prepared_version = patched_codex::codex_version(&prepared_binary)
            .context("staged Codex has no version")?;
        if prepared_version != version {
            bail!("staged Codex version {prepared_version} did not match expected {version}");
        }
        Ok(())
    })();

    match result {
        Ok(()) => {
            state.status = UpdateStatus::ReadyToInstall;
            state.installed_version = installed_codex_version();
            state.error = None;
        }
        Err(error) => {
            state.status = UpdateStatus::Failed;
            state.error = Some(format!("{error:#}"));
        }
    }
    state.updated_at = Utc::now();
    save_state(&state)?;

    if state.status == UpdateStatus::Failed {
        bail!(
            "{}",
            state
                .error
                .clone()
                .unwrap_or_else(|| "failed to prepare Codex update".to_string())
        );
    }
    Ok(report_from_state(state))
}

pub fn install_prepared() -> Result<CodexUpdateReport> {
    let mut state = load_state()?;
    if state.status != UpdateStatus::ReadyToInstall {
        bail!("no patched Codex update is ready to install");
    }
    let prepared_binary = state
        .prepared_binary_path
        .as_deref()
        .map(PathBuf::from)
        .context("update state is missing prepared binary path")?;
    let installed_binary = patched_codex::default_installed_binary()?;
    let user_launcher = patched_codex::default_user_launcher()?;
    let prepared_version =
        patched_codex::codex_version(&prepared_binary).context("prepared Codex has no version")?;

    patched_codex::install_prepared_binary(&prepared_binary, &installed_binary, &user_launcher)?;
    restart_managed_app_server_after_install()?;

    state.status = UpdateStatus::Installed;
    state.installed_version = Some(prepared_version);
    state.prepared_version = None;
    state.prepared_source_path = None;
    state.prepared_binary_path = None;
    state.error = None;
    state.updated_at = Utc::now();
    save_state(&state)?;
    Ok(report_from_state(state))
}

pub fn auto_install_update() -> Result<CodexUpdateReport> {
    let report = check_for_update(true, true)?;
    if report.status == UpdateStatus::ReadyToInstall {
        install_prepared()
    } else {
        Ok(report)
    }
}

pub fn maybe_spawn_daily_auto_install() -> Result<()> {
    let state = load_state()?;
    let pending_update = state_has_pending_stable_update(&state);
    if (!pending_update && !check_due(&state))
        || matches!(
            state.status,
            UpdateStatus::Checking | UpdateStatus::Preparing | UpdateStatus::Installing
        )
    {
        return Ok(());
    }

    let mut state = state;
    state.status = if state.status == UpdateStatus::ReadyToInstall {
        UpdateStatus::Installing
    } else {
        UpdateStatus::Checking
    };
    state.last_checked_at = Some(Utc::now());
    state.updated_at = Utc::now();
    save_state(&state)?;

    let exe = background_update_executable().context("failed to resolve current executable")?;
    let log_path = codexswitch_data_dir()?.join("codex-update.log");
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let stdout = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .with_context(|| format!("failed to open {}", log_path.display()))?;
    let stderr = stdout.try_clone()?;
    Command::new(exe)
        .args(background_auto_install_args())
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .spawn()
        .context("failed to spawn background Codex auto-update")?;
    Ok(())
}

fn background_auto_install_args() -> [&'static str; 2] {
    ["auto-install-codex-update", "--json"]
}

fn state_has_pending_stable_update(state: &CodexUpdateState) -> bool {
    if state.status == UpdateStatus::ReadyToInstall {
        return true;
    }
    if state.status != UpdateStatus::Idle {
        return false;
    }
    let Some(latest) = state.latest_stable_version.as_deref() else {
        return false;
    };
    version_is_stable(latest) && state.installed_version.as_deref() != Some(latest)
}

fn report_from_state(state: CodexUpdateState) -> CodexUpdateReport {
    let install_command = if state.status == UpdateStatus::ReadyToInstall {
        Some("codexswitch-cli install-prepared-codex".to_string())
    } else {
        None
    };
    let summary = summary_for_state(&state, install_command.as_deref());
    CodexUpdateReport {
        status: state.status,
        summary,
        last_checked_at: state.last_checked_at,
        latest_stable_version: state.latest_stable_version,
        installed_version: state.installed_version,
        prepared_version: state.prepared_version,
        prepared_source_path: state.prepared_source_path,
        prepared_binary_path: state.prepared_binary_path,
        install_command,
        error: state.error,
    }
}

fn reconcile_installed_state(state: &mut CodexUpdateState) -> bool {
    if state.status != UpdateStatus::ReadyToInstall {
        return false;
    }
    let Some(prepared_version) = state.prepared_version.as_deref() else {
        return false;
    };
    if state.installed_version.as_deref() != Some(prepared_version) {
        return false;
    }
    let Ok(installed_binary) = patched_codex::default_installed_binary() else {
        return false;
    };
    if !patched_codex::binary_has_hot_swap_markers(&installed_binary) {
        return false;
    }
    if patched_codex::codex_version(&installed_binary).as_deref() != Some(prepared_version) {
        return false;
    }

    state.status = UpdateStatus::Installed;
    state.prepared_version = None;
    state.prepared_source_path = None;
    state.prepared_binary_path = None;
    state.error = None;
    state.updated_at = Utc::now();
    true
}

fn background_update_executable() -> Result<PathBuf> {
    let current = std::env::current_exe().context("failed to resolve current executable")?;
    let current_text = current.to_string_lossy();
    if current.exists() && !current_text.contains(" (deleted)") {
        return Ok(current);
    }

    let user_bin = home_dir()?.join(".local/bin/codexswitch-cli");
    if user_bin.exists() {
        return Ok(user_bin);
    }

    Ok(current)
}

fn summary_for_state(state: &CodexUpdateState, install_command: Option<&str>) -> String {
    match state.status {
        UpdateStatus::ReadyToInstall => format!(
            "updated and patched Codex CLI {} is ready to install{}",
            state.prepared_version.as_deref().unwrap_or("unknown"),
            install_command
                .map(|command| format!(" ({command})"))
                .unwrap_or_default()
        ),
        UpdateStatus::Preparing => format!(
            "preparing stable Codex CLI {} in the background",
            state
                .prepared_version
                .as_deref()
                .or(state.latest_stable_version.as_deref())
                .unwrap_or("unknown")
        ),
        UpdateStatus::Installing => format!(
            "installing stable patched Codex CLI {} in the background",
            state
                .prepared_version
                .as_deref()
                .or(state.latest_stable_version.as_deref())
                .unwrap_or("unknown")
        ),
        UpdateStatus::Checking => "checking for a stable Codex CLI update".to_string(),
        UpdateStatus::Installed => format!(
            "stable patched Codex CLI {} is installed",
            state.installed_version.as_deref().unwrap_or("unknown")
        ),
        UpdateStatus::Failed => format!(
            "Codex CLI update failed: {}",
            state.error.as_deref().unwrap_or("unknown error")
        ),
        UpdateStatus::Idle => match (&state.latest_stable_version, &state.installed_version) {
            (Some(latest), Some(installed)) if latest != installed => {
                format!("stable Codex CLI {latest} is available; run codexswitch-cli check-codex-update --prepare")
            }
            (Some(latest), _) => format!("latest stable Codex CLI is {latest}; no staged update"),
            _ => "Codex CLI stable update has not checked yet".to_string(),
        },
    }
}

fn restart_managed_app_server_after_install() -> Result<()> {
    if !cfg!(target_os = "linux") {
        return Ok(());
    }
    if !managed_app_server_service_is_active() {
        return Ok(());
    }

    let status = Command::new("systemctl")
        .arg("--user")
        .arg("restart")
        .arg("signul-codex-app-server.service")
        .status()
        .context("failed to restart signul-codex-app-server.service after Codex update")?;
    if !status.success() {
        bail!("failed to restart signul-codex-app-server.service after Codex update: {status}");
    }
    Ok(())
}

fn managed_app_server_service_is_active() -> bool {
    if !cfg!(target_os = "linux") {
        return false;
    }
    Command::new("systemctl")
        .arg("--user")
        .arg("is-active")
        .arg("--quiet")
        .arg("signul-codex-app-server.service")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn fetch_latest_stable_version() -> Result<String> {
    let package = Client::builder()
        .timeout(Duration::from_secs(20))
        .build()?
        .get(NPM_LATEST_URL)
        .send()
        .context("failed to fetch @openai/codex latest metadata")?
        .error_for_status()
        .context("npm registry returned an error for @openai/codex/latest")?
        .json::<NpmLatest>()
        .context("failed to parse @openai/codex latest metadata")?;
    if !version_is_stable(&package.version) {
        bail!(
            "@openai/codex latest resolved to non-stable version {}",
            package.version
        );
    }
    Ok(package.version)
}

fn checkout_stable_source(version: &str, source_dir: &Path) -> Result<()> {
    let tag = stable_source_tag(version)?;
    if source_dir.join(".git").exists() {
        let status = Command::new("git")
            .arg("fetch")
            .arg("--tags")
            .arg("--force")
            .current_dir(source_dir)
            .status()
            .with_context(|| format!("failed to fetch tags in {}", source_dir.display()))?;
        if !status.success() {
            bail!("git fetch failed with {status}");
        }
        let status = Command::new("git")
            .arg("checkout")
            .arg("--force")
            .arg(&tag)
            .current_dir(source_dir)
            .status()
            .with_context(|| format!("failed to checkout {tag} in {}", source_dir.display()))?;
        if !status.success() {
            bail!("git checkout {tag} failed with {status}");
        }
        return Ok(());
    }

    if let Some(parent) = source_dir.parent() {
        fs::create_dir_all(parent)?;
    }
    let status = Command::new("git")
        .arg("clone")
        .arg("--depth")
        .arg("1")
        .arg("--branch")
        .arg(&tag)
        .arg(CODEX_REPO_URL)
        .arg(source_dir)
        .status()
        .with_context(|| format!("failed to clone Codex source tag {tag}"))?;
    if !status.success() {
        bail!("git clone {tag} failed with {status}");
    }
    Ok(())
}

fn patch_codex_source(source_dir: &Path) -> Result<()> {
    let app_server = source_dir.join("codex-rs/app-server/src/lib.rs");
    let in_process_app_server = source_dir.join("codex-rs/app-server/src/in_process.rs");
    let auth_manager = source_dir.join("codex-rs/login/src/auth/manager.rs");
    let client = source_dir.join("codex-rs/core/src/client.rs");
    let turn = source_dir.join("codex-rs/core/src/session/turn.rs");
    let tui = source_dir.join("codex-rs/tui/src/lib.rs");
    patch_auth_manager_source(&auth_manager)?;
    patch_client_websocket_source(&client)?;
    patch_file_after_any(
        &app_server,
        &[
            "let processor_handle = tokio::spawn({\n        let auth_manager =\n            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;",
            "let auth_manager =\n        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;",
        ],
        r#"
        #[cfg(unix)]
        {
            let codexswitch_marker_dir = std::env::var_os("HOME").map(|home| {
                let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
                let _ = std::fs::create_dir_all(&marker_dir);
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-ack"));
                let _ = std::fs::write(marker_dir.join("sighup-verified"), "app-server\n");
                marker_dir
            });

            let auth_for_signal = auth_manager.clone();
            tokio::spawn(async move {
                use tokio::signal::unix::{signal, SignalKind};
                let mut sighup = match signal(SignalKind::hangup()) {
                    Ok(s) => s,
                    Err(err) => {
                        tracing::error!("Failed to register SIGHUP handler: {err}");
                        return;
                    }
                };
                loop {
                    if sighup.recv().await.is_none() {
                        break;
                    }
                    tracing::info!("SIGHUP: auth reload signal received");
                    let changed = auth_for_signal.reload().await;
                    if let Some(marker_dir) = codexswitch_marker_dir.as_ref() {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|duration| duration.as_secs().to_string())
                            .unwrap_or_else(|_| "unknown".to_string());
                        let _ = std::fs::write(marker_dir.join("sighup-last-received"), now);
                        let pid = std::process::id();
                        let auth_hash = format!("generation:{}", auth_for_signal.auth_generation());
                        let ack = format!(
                            "{{\"pid\":{},\"timestampUnix\":{},\"loadedAuthHash\":\"{}\",\"activeAuthHash\":\"{}\"}}",
                            pid,
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|duration| duration.as_secs())
                                .unwrap_or(0),
                            auth_hash,
                            auth_hash
                        );
                        let _ = std::fs::write(
                            marker_dir
                                .join("hotswap-ack")
                                .join(format!("{pid}.json")),
                            ack,
                        );
                    }
                    if changed {
                        tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                    } else {
                        tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                    }
                }
            });
        }
"#,
        "hotswap-ack",
    )?;
    if in_process_app_server.exists() {
        patch_file_after(
            &in_process_app_server,
            "let auth_manager =\n            AuthManager::shared_from_config(args.config.as_ref(), args.enable_codex_api_key_env)\n                .await;",
            r#"
        #[cfg(unix)]
        {
            let codexswitch_marker_dir = std::env::var_os("HOME").map(|home| {
                let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
                let _ = std::fs::create_dir_all(&marker_dir);
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-ack"));
                let _ = std::fs::write(marker_dir.join("sighup-verified"), "in-process\n");
                marker_dir
            });

            let auth_for_signal = auth_manager.clone();
            tokio::spawn(async move {
                use tokio::signal::unix::{signal, SignalKind};
                let mut sighup = match signal(SignalKind::hangup()) {
                    Ok(s) => s,
                    Err(err) => {
                        tracing::error!("Failed to register in-process SIGHUP handler: {err}");
                        return;
                    }
                };
                loop {
                    if sighup.recv().await.is_none() {
                        break;
                    }
                    tracing::info!("SIGHUP: auth reload signal received by in-process app-server");
                    let changed = auth_for_signal.reload().await;
                    if let Some(marker_dir) = codexswitch_marker_dir.as_ref() {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|duration| duration.as_secs().to_string())
                            .unwrap_or_else(|_| "unknown".to_string());
                        let _ = std::fs::write(marker_dir.join("sighup-last-received"), now);
                        let pid = std::process::id();
                        let auth_hash = format!("generation:{}", auth_for_signal.auth_generation());
                        let ack = format!(
                            "{{\"pid\":{},\"timestampUnix\":{},\"loadedAuthHash\":\"{}\",\"activeAuthHash\":\"{}\"}}",
                            pid,
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|duration| duration.as_secs())
                                .unwrap_or(0),
                            auth_hash,
                            auth_hash
                        );
                        let _ = std::fs::write(
                            marker_dir
                                .join("hotswap-ack")
                                .join(format!("{pid}.json")),
                            ack,
                        );
                    }
                    if changed {
                        tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                    } else {
                        tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                    }
                }
            });
        }
"#,
            "SIGHUP: auth reload signal received by in-process app-server",
        )?;
    }
    patch_file_before_any(
        &turn,
        &[
            "/// Takes a user message as input and runs a loop where, at each sampling request, the model",
            "/// Takes initial turn input and runs a loop where, at each sampling request,",
        ],
        r#"#[cfg(unix)]
async fn codexswitch_rotate_after_usage_limit(sess: &Session, turn_context: &TurnContext) -> bool {
    let cli = std::env::var("CODEXSWITCH_CLI").unwrap_or_else(|_| "codexswitch-cli".to_string());
    let rotate = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::process::Command::new(cli)
            .arg("rotate-now")
            .arg("--reason")
            .arg("usage_limit")
            .arg("--cooldown-seconds")
            .arg("21600")
            .arg("--json")
            .output(),
    )
    .await;

    let Ok(Ok(output)) = rotate else {
        warn!("CodexSwitch usage-limit rotation failed or timed out");
        return false;
    };
    if !output.status.success() {
        warn!(
            "CodexSwitch usage-limit rotation exited with status {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        return false;
    }

    if let Some(auth_manager) = turn_context.auth_manager.as_ref() {
        auth_manager.reload().await;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: "CodexSwitch rotated accounts after a usage limit and is retrying this turn.".to_string(),
        }),
    )
    .await;
    true
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_usage_limit(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

"#,
        "codexswitch_rotate_after_usage_limit",
    )?;
    patch_file_after(
        &turn,
        "    let mut retries = 0;",
        r#"
    let mut codexswitch_usage_limit_retry_attempted = false;"#,
        "codexswitch_usage_limit_retry_attempted",
    )?;
    patch_file_after(
        &turn,
        "                if let Some(rate_limits) = rate_limits {\n                    sess.update_rate_limits(&turn_context, *rate_limits).await;\n                }",
        r#"
                if !codexswitch_usage_limit_retry_attempted
                    && codexswitch_rotate_after_usage_limit(&sess, &turn_context).await
        {
            codexswitch_usage_limit_retry_attempted = true;
            continue;
        }"#,
        "&& codexswitch_rotate_after_usage_limit",
    )?;
    patch_file_before(
        &tui,
        "    // Initialize high-fidelity session event logging if enabled.",
        r#"    #[cfg(unix)]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
            let _ = std::fs::create_dir_all(&marker_dir);
            let _ = std::fs::write(marker_dir.join("sighup-verified-tui"), "tui\n");
        }
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sighup = match signal(SignalKind::hangup()) {
                Ok(s) => s,
                Err(err) => {
                    tracing::error!("Failed to register SIGHUP handler: {err}");
                    return;
                }
            };
            loop {
                if sighup.recv().await.is_none() {
                    break;
                }
                tracing::debug!(
                    "SIGHUP: auth reloaded from disk (foreground session ignores signal; app-server reloads auth)"
                );
            }
        });
    }

"#,
        "sighup-verified-tui",
    )?;
    Ok(())
}

fn patch_auth_manager_source(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    patch_file_after(
        path,
        "use std::sync::RwLock;",
        r#"
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;"#,
        "use std::sync::atomic::AtomicU64;",
    )?;
    patch_file_after(
        path,
        "    external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,",
        r#"
    /// Monotonically increasing counter incremented on every auth change.
    /// WebSocket sessions compare this to avoid reusing credentials after SIGHUP.
    auth_generation: AtomicU64,"#,
        "auth_generation: AtomicU64",
    )?;
    patch_auth_generation_none_initializers(path)?;
    patch_all(
        path,
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n        })",
        "            external_auth: RwLock::new(Some(\n                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>\n            )),\n            auth_generation: AtomicU64::new(0),\n        })",
    )?;
    patch_file_before(
        path,
        "    /// Current cached auth (clone) without attempting a refresh.",
        r#"    /// Current auth generation counter. Incremented whenever cached auth changes.
    pub fn auth_generation(&self) -> u64 {
        self.auth_generation.load(Ordering::Acquire)
    }

"#,
        "pub fn auth_generation(&self) -> u64",
    )?;
    patch_file_after(
        path,
        "            tracing::info!(\"Reloaded auth, changed: {changed}\");\n            guard.auth = new_auth;",
        r#"
            if auth_changed_for_refresh {
                self.auth_generation.fetch_add(1, Ordering::AcqRel);
            }"#,
        "self.auth_generation.fetch_add",
    )?;
    Ok(())
}

fn patch_auth_generation_none_initializers(path: &Path) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let mut updated = String::with_capacity(content.len() + 512);
    let lines = content.lines().collect::<Vec<_>>();
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index];
        updated.push_str(line);
        updated.push('\n');

        if line.contains("external_auth: RwLock::new(None),") {
            let lookahead_end = (index + 8).min(lines.len());
            let has_generation = lines[index + 1..lookahead_end]
                .iter()
                .any(|next| next.contains("auth_generation: AtomicU64::new(0),"));
            if !has_generation {
                updated.push_str("            auth_generation: AtomicU64::new(0),\n");
            }
        }

        index += 1;
    }
    if updated != content {
        fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    }
    Ok(())
}

fn patch_client_websocket_source(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    patch_file_after(
        path,
        "    connection: Option<ApiWebSocketConnection>,",
        r#"
    /// Auth generation that produced this cached connection.
    /// If auth_generation changes after SIGHUP, the connection must be reopened.
    auth_generation_at_creation: u64,"#,
        "auth_generation_at_creation",
    )?;
    patch_all(
        path,
        r#"    fn take_cached_websocket_session(&self) -> WebsocketSession {
        let mut cached_websocket_session = self
            .state
            .cached_websocket_session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        std::mem::take(&mut *cached_websocket_session)
    }"#,
        r#"    fn take_cached_websocket_session(&self) -> WebsocketSession {
        let mut cached_websocket_session = self
            .state
            .cached_websocket_session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let cached = std::mem::take(&mut *cached_websocket_session);
        if let Some(auth_manager) = self.state.provider.auth_manager() {
            let current_gen = auth_manager.auth_generation();
            if cached.auth_generation_at_creation != current_gen && cached.connection.is_some() {
                tracing::info!(
                    "Auth generation changed ({} -> {}), discarding cached WebSocket",
                    cached.auth_generation_at_creation,
                    current_gen
                );
                return WebsocketSession {
                    auth_generation_at_creation: current_gen,
                    ..WebsocketSession::default()
                };
            }
        }
        cached
    }"#,
    )?;
    patch_file_after(
        path,
        r#"        let client_setup = self.client.current_client_setup().await.map_err(|err| {
            ApiError::Stream(format!(
                "failed to build websocket prewarm client setup: {err}"
            ))
        })?;"#,
        r#"
        let generation_at_resolve = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());"#,
        "generation_at_resolve",
    )?;
    patch_all(
        path,
        r#"        self.websocket_session.connection = Some(connection);
        self.websocket_session
            .set_connection_reused(/*connection_reused*/ false);
        Ok(())"#,
        r#"        self.websocket_session.connection = Some(connection);
        self.websocket_session
            .set_connection_reused(/*connection_reused*/ false);
        if let Some(auth_gen) = generation_at_resolve {
            self.websocket_session.auth_generation_at_creation = auth_gen;
        }
        Ok(())"#,
    )?;
    patch_all(
        path,
        r#"        if needs_new {
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    api_provider,
                    api_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    auth_context,
                    request_route_telemetry,
                )
                .await
            {
                Ok(new_conn) => new_conn,
                Err(err) => {
                    if matches!(err, ApiError::Transport(TransportError::Timeout)) {
                        self.reset_websocket_session();
                    }
                    return Err(err);
                }
            };
            self.websocket_session.connection = Some(new_conn);
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ false);
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
        r#"        let current_auth_gen = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());
        let auth_changed = current_auth_gen
            .is_some_and(|ag| ag != self.websocket_session.auth_generation_at_creation);

        if needs_new || auth_changed {
            if auth_changed {
                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");
            }
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let (use_provider, use_auth, use_gen, use_auth_context) = if auth_changed {
                let fresh = self.client.current_client_setup().await.map_err(|err| {
                    ApiError::Stream(format!(
                        "failed to re-resolve auth after SIGHUP: {err}"
                    ))
                })?;
                let fresh_gen = self
                    .client
                    .state
                    .provider
                    .auth_manager()
                    .as_ref()
                    .map(|am| am.auth_generation());
                let fresh_auth_context = AuthRequestTelemetryContext::new(
                    fresh.auth.as_ref().map(CodexAuth::auth_mode),
                    fresh.api_auth.as_ref(),
                    PendingUnauthorizedRetry::default(),
                );
                (fresh.api_provider, fresh.api_auth, fresh_gen, fresh_auth_context)
            } else {
                (api_provider, api_auth, current_auth_gen, auth_context)
            };
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    use_provider,
                    use_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    use_auth_context,
                    request_route_telemetry,
                )
                .await
            {
                Ok(new_conn) => new_conn,
                Err(err) => {
                    if matches!(err, ApiError::Transport(TransportError::Timeout)) {
                        self.reset_websocket_session();
                    }
                    return Err(err);
                }
            };
            self.websocket_session.connection = Some(new_conn);
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ false);
            if let Some(ag) = use_gen {
                self.websocket_session.auth_generation_at_creation = ag;
            }
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
    )?;
    patch_all(
        path,
        r#"        if needs_new {
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    api_provider,
                    api_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    auth_context,
                    request_route_telemetry,
                )
                .await
            {
                Ok(new_conn) => new_conn,
                Err(err) => {
                    if matches!(err, ApiError::Transport(TransportError::Timeout)) {
                        self.reset_websocket_session();
                    }
                    return Err(err);
                }
            };
            self.websocket_session.connection = Some(new_conn);
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ false);
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
        r#"        let current_auth_gen = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());
        let auth_changed = current_auth_gen
            .is_some_and(|ag| ag != self.websocket_session.auth_generation_at_creation);

        if needs_new || auth_changed {
            if auth_changed {
                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");
            }
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let (use_provider, use_auth, use_gen, use_auth_context) = if auth_changed {
                let fresh = self.client.current_client_setup().await.map_err(|err| {
                    ApiError::Stream(format!(
                        "failed to re-resolve auth after SIGHUP: {err}"
                    ))
                })?;
                let fresh_gen = self
                    .client
                    .state
                    .provider
                    .auth_manager()
                    .as_ref()
                    .map(|am| am.auth_generation());
                let fresh_auth_context = AuthRequestTelemetryContext::new(
                    fresh.auth.as_ref().map(CodexAuth::auth_mode),
                    fresh.api_auth.as_ref(),
                    PendingUnauthorizedRetry::default(),
                );
                (fresh.api_provider, fresh.api_auth, fresh_gen, fresh_auth_context)
            } else {
                (api_provider, api_auth, current_auth_gen, auth_context)
            };
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    use_provider,
                    use_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    use_auth_context,
                    request_route_telemetry,
                )
                .await
            {
                Ok(new_conn) => new_conn,
                Err(err) => {
                    if matches!(err, ApiError::Transport(TransportError::Timeout)) {
                        self.reset_websocket_session();
                    }
                    return Err(err);
                }
            };
            self.websocket_session.connection = Some(new_conn);
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ false);
            if let Some(ag) = use_gen {
                self.websocket_session.auth_generation_at_creation = ag;
            }
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
    )?;
    Ok(())
}

fn patch_file_after(path: &Path, needle: &str, insertion: &str, marker: &str) -> Result<()> {
    patch_file_after_any(path, &[needle], insertion, marker)
}

fn patch_file_after_any(
    path: &Path,
    needles: &[&str],
    insertion: &str,
    marker: &str,
) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(marker) {
        return Ok(());
    }
    let Some((index, needle)) = needles
        .iter()
        .find_map(|needle| content.find(needle).map(|index| (index, *needle)))
    else {
        bail!("patch anchor not found in {}", path.display());
    };
    let insert_at = index + needle.len();
    let updated = format!(
        "{}{}{}",
        &content[..insert_at],
        insertion,
        &content[insert_at..]
    );
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_all(path: &Path, needle: &str, replacement: &str) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if !content.contains(needle) {
        return Ok(());
    }
    let updated = content.replace(needle, replacement);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_file_before(path: &Path, needle: &str, insertion: &str, marker: &str) -> Result<()> {
    patch_file_before_any(path, &[needle], insertion, marker)
}

fn patch_file_before_any(
    path: &Path,
    needles: &[&str],
    insertion: &str,
    marker: &str,
) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(marker) {
        return Ok(());
    }
    let Some(index) = needles.iter().find_map(|needle| content.find(needle)) else {
        bail!("patch anchor not found in {}", path.display());
    };
    let updated = format!("{}{}{}", &content[..index], insertion, &content[index..]);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn load_state() -> Result<CodexUpdateState> {
    let path = state_path()?;
    if !path.exists() {
        return Ok(CodexUpdateState::default());
    }
    let state = serde_json::from_slice::<CodexUpdateState>(
        &fs::read(&path).with_context(|| format!("failed to read {}", path.display()))?,
    )
    .with_context(|| format!("failed to decode {}", path.display()))?;
    Ok(state)
}

fn save_state(state: &CodexUpdateState) -> Result<()> {
    let path = state_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, serde_json::to_vec_pretty(state)?)
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn state_path() -> Result<PathBuf> {
    Ok(codexswitch_data_dir()?.join("codex-cli-update.json"))
}

fn codexswitch_data_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/share/codexswitch"))
}

fn installed_codex_version() -> Option<String> {
    let installed_binary = patched_codex::default_installed_binary().ok()?;
    installed_codex_version_from_path(&installed_binary)
}

fn installed_codex_version_from_path(installed_binary: &Path) -> Option<String> {
    if patched_codex::binary_has_hot_swap_markers(installed_binary) {
        return patched_codex::codex_version(installed_binary);
    }
    let launcher_target = launcher_patched_codex_target(installed_binary)?;
    if !patched_codex::binary_has_hot_swap_markers(&launcher_target) {
        return None;
    }
    patched_codex::codex_version(&launcher_target)
}

fn launcher_patched_codex_target(launcher: &Path) -> Option<PathBuf> {
    let content = fs::read_to_string(launcher).ok()?;
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("PATCHED_CODEX='") {
            let path = value.strip_suffix('\'')?;
            return Some(PathBuf::from(path));
        }
    }
    None
}

fn check_due(state: &CodexUpdateState) -> bool {
    state
        .last_checked_at
        .map(|checked| Utc::now() - checked >= ChronoDuration::hours(DAILY_CHECK_HOURS))
        .unwrap_or(true)
}

pub fn version_is_stable(version: &str) -> bool {
    !version.contains('-') && version.chars().all(|ch| ch.is_ascii_digit() || ch == '.')
}

pub fn stable_source_tag(version: &str) -> Result<String> {
    if !version_is_stable(version) {
        bail!("refusing non-stable Codex version {version}");
    }
    Ok(format!("rust-v{version}"))
}

fn set_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_source_tags_refuse_alpha_versions() {
        assert_eq!(stable_source_tag("0.128.0").unwrap(), "rust-v0.128.0");
        assert!(stable_source_tag("0.129.0-alpha.1").is_err());
    }

    #[test]
    fn stable_version_filter_rejects_prereleases() {
        assert!(version_is_stable("0.128.0"));
        assert!(!version_is_stable("0.128.0-alpha.15"));
        assert!(!version_is_stable("latest"));
    }

    #[test]
    fn ready_status_names_install_command_and_version() {
        let state = CodexUpdateState {
            status: UpdateStatus::ReadyToInstall,
            last_checked_at: None,
            latest_stable_version: Some("0.128.0".to_string()),
            installed_version: Some("0.126.0".to_string()),
            prepared_version: Some("0.128.0".to_string()),
            prepared_source_path: None,
            prepared_binary_path: None,
            error: None,
            updated_at: Utc::now(),
        };
        let report = report_from_state(state);
        assert!(report.summary.contains("0.128.0"));
        assert_eq!(
            report.install_command.as_deref(),
            Some("codexswitch-cli install-prepared-codex")
        );
    }

    #[test]
    fn daemon_background_update_command_installs_after_prepare() {
        assert_eq!(
            background_auto_install_args(),
            ["auto-install-codex-update", "--json"]
        );
    }

    #[test]
    fn idle_state_with_known_update_is_pending_even_before_daily_check() {
        let state = CodexUpdateState {
            status: UpdateStatus::Idle,
            last_checked_at: Some(Utc::now()),
            latest_stable_version: Some("0.134.0".to_string()),
            installed_version: Some("0.133.0".to_string()),
            prepared_version: None,
            prepared_source_path: None,
            prepared_binary_path: None,
            error: None,
            updated_at: Utc::now(),
        };

        assert!(state_has_pending_stable_update(&state));
    }

    #[test]
    fn installing_status_describes_background_install() {
        let state = CodexUpdateState {
            status: UpdateStatus::Installing,
            last_checked_at: None,
            latest_stable_version: Some("0.134.0".to_string()),
            installed_version: Some("0.133.0".to_string()),
            prepared_version: Some("0.134.0".to_string()),
            prepared_source_path: None,
            prepared_binary_path: None,
            error: None,
            updated_at: Utc::now(),
        };
        let report = report_from_state(state);
        assert!(report.summary.contains("installing"));
        assert!(report.summary.contains("0.134.0"));
        assert_eq!(report.install_command, None);
    }

    #[test]
    fn installed_version_ignores_launcher_or_wrapper_without_hot_swap_markers() {
        let temp_dir = tempfile::tempdir().unwrap();
        let binary = temp_dir.path().join("codex");
        fs::write(&binary, "#!/bin/sh\necho 'codex-cli 0.130.0'\n").unwrap();
        set_executable(&binary).unwrap();

        assert_eq!(installed_codex_version_from_path(&binary), None);
    }

    #[test]
    fn installed_version_follows_macos_launcher_to_prepared_binary() {
        let temp_dir = tempfile::tempdir().unwrap();
        let prepared = temp_dir.path().join("prepared-codex/0.130.0/codex");
        fs::create_dir_all(prepared.parent().unwrap()).unwrap();
        fs::write(
            &prepared,
            "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials Usage: /goal <objective>\necho 'codex-cli 0.130.0'\n",
        )
        .unwrap();
        set_executable(&prepared).unwrap();

        let launcher = temp_dir.path().join("patched-codex/codex");
        fs::create_dir_all(launcher.parent().unwrap()).unwrap();
        fs::write(
            &launcher,
            format!(
                "#!/bin/sh\nPATCHED_CODEX='{}'\nexec \"$PATCHED_CODEX\" \"$@\"\n",
                prepared.display()
            ),
        )
        .unwrap();
        set_executable(&launcher).unwrap();

        assert_eq!(
            installed_codex_version_from_path(&launcher).as_deref(),
            Some("0.130.0")
        );
    }

    #[test]
    fn app_server_sighup_patch_targets_processor_auth_manager() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn preload() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
    config_manager.replace_cloud_requirements_loader(auth_manager, config.chatgpt_base_url);
}

async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            app_server_dir.join("in_process.rs"),
            r#"
fn start_uninitialized(args: InProcessStartArgs) -> InProcessClientHandle {
    let runtime_handle = tokio::spawn(async move {
        let auth_manager =
            AuthManager::shared_from_config(args.config.as_ref(), args.enable_codex_api_key_env)
                .await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes initial turn input and runs a loop where, at each sampling request,
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let processor_index = patched.find("let processor_handle").unwrap();
        let marker_index = patched.find("sighup-verified").unwrap();
        assert!(
            marker_index > processor_index,
            "SIGHUP reload must patch the auth manager captured by MessageProcessor, not the preload auth manager"
        );
        assert!(patched.contains("SIGHUP: auth reload signal received"));
        assert!(patched.contains("hotswap-ack"));
        assert_eq!(patched.matches("SIGHUP: auth reloaded").count(), 2);

        let in_process_patched = fs::read_to_string(app_server_dir.join("in_process.rs")).unwrap();
        let auth_index = in_process_patched
            .find("AuthManager::shared_from_config")
            .unwrap();
        let in_process_ack_index = in_process_patched
            .find("SIGHUP: auth reload signal received by in-process app-server")
            .unwrap();
        assert!(
            in_process_ack_index > auth_index,
            "foreground CLI uses the in-process app-server, so its auth manager must acknowledge SIGHUP"
        );
        assert!(in_process_patched.contains("hotswap-ack"));
    }

    #[test]
    fn app_server_sighup_patch_accepts_shared_auth_manager_anchor() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn run_app_server() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;

    let remote_control_requested = runtime_options.remote_control_enabled;
    let processor_handle = tokio::spawn({
        let auth_manager = Arc::clone(&auth_manager);
        let processor = MessageProcessor::new(MessageProcessorArgs {
            auth_manager,
        });
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let shared_auth_index = patched.find("AuthManager::shared_from_config").unwrap();
        let marker_index = patched.find("SIGHUP: auth reload signal received").unwrap();
        let remote_control_index = patched.find("remote_control_requested").unwrap();
        assert!(marker_index > shared_auth_index);
        assert!(marker_index < remote_control_index);
        assert!(patched.contains("hotswap-ack"));
    }

    #[test]
    fn app_server_patch_upgrades_legacy_sighup_without_ack() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn preload() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
    #[cfg(unix)]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
            let _ = std::fs::create_dir_all(&marker_dir);
            let _ = std::fs::write(marker_dir.join("sighup-verified"), "app-server\n");
        }

        let auth_for_signal = auth_manager.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sighup = signal(SignalKind::hangup()).unwrap();
            while sighup.recv().await.is_some() {
                let changed = auth_for_signal.reload().await;
                if changed {
                    tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                } else {
                    tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                }
            }
        });
    }
    config_manager.replace_cloud_requirements_loader(auth_manager, config.chatgpt_base_url);
}

async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let processor_index = patched.find("let processor_handle").unwrap();
        let ack_index = patched.find("hotswap-ack").unwrap();
        assert!(
            ack_index > processor_index,
            "legacy SIGHUP-only patches must be upgraded at the processor auth manager"
        );
        assert!(patched.contains("SIGHUP: auth reload signal received"));
    }

    #[test]
    fn core_turn_patch_rotates_and_retries_once_on_usage_limit() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(turn_dir.join("turn.rs")).unwrap();
        assert!(patched.contains("codexswitch_rotate_after_usage_limit"));
        assert!(patched.contains("codexswitch_usage_limit_retry_attempted"));
        assert!(patched.contains("rotate-now"));
        assert!(patched.contains("usage_limit"));
        assert!(patched.contains("continue;"));
    }
}

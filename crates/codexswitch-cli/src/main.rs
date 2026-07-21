mod account_store;
mod activation;
mod auth;
mod bounded_command;
mod codex_health;
mod codex_update;
mod daemon;
mod import;
mod patched_codex;
mod quota;
mod rate_limit_resets;
mod readiness;
mod reload;
mod secure_drop;
mod secure_file;
mod token_refresh;

use account_store::{
    active_account, default_store_path, load_account_store_snapshot, load_accounts,
    lock_account_store, mark_runtime_unusable, quota_availability_at, real_quota_snapshot,
    resolve_account_selector, select_auto_swap_candidate_from_observations,
    usage_limit_runtime_block_until, validate_accounts, CurrentQuotaObservations,
    QuotaAvailability, QuotaSnapshot, QuotaWindowKind,
};
#[cfg(test)]
use account_store::{commit_accounts, save_accounts};
use activation::{
    activate_with, activate_with_unlocked_reload, commit_accounts_with_provider_io_activation,
    preflight_provider_io_activation, reconcile_activation_barrier_unlocked, replace_accounts_with,
    resolve_manual_review_activation_unlocked, validate_provider_io_activation,
    validate_provider_io_activation_locked, ActivationContext, ActivationOutcome, ActivationState,
};
use anyhow::{bail, Context, Result};
use auth::default_auth_path;
use chrono::{Duration as ChronoDuration, Utc};
use clap::{Parser, Subcommand};
use import::prepare_import_bundle;
use quota::{apply_fetch_result, fetch_quota, FetchResult};
use rate_limit_resets::{
    consume_rate_limit_reset, fetch_rate_limit_reset_bank, orchestrate_reset_with_provider_guard,
    reconcile_or_attempt_reset_with_provider_guard, ConsumeResult, RateLimitResetBank,
    ResetOrchestrationContext, ResetOrchestrationDependencies, ResetQuotaRefreshStrategy,
    ResetReconciliationContext, ResetReconciliationDependencies, SmartResetReason,
};
use reload::{
    reload_codex_hot_swap_processes, reload_codex_hot_swap_processes_for_receipt,
    restart_codex_processes, ReloadSummary,
};
use ring::digest::{digest, Context as DigestContext, SHA256};
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

fn parse_canonical_uuid(value: &str) -> std::result::Result<Uuid, String> {
    let parsed = Uuid::parse_str(value).map_err(|_| "expected a canonical UUID".to_string())?;
    if parsed.hyphenated().to_string() != value {
        return Err("expected a lowercase hyphenated canonical UUID".to_string());
    }
    Ok(parsed)
}

#[derive(Debug, Parser)]
#[command(name = "codexswitch-cli")]
#[command(about = "Headless CodexSwitch for Linux CLI hot-swap")]
#[command(version = env!("CODEXSWITCH_BUILD_VERSION"))]
struct Args {
    #[arg(long, global = true)]
    store: Option<PathBuf>,
    #[arg(long, global = true)]
    auth: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Doctor {
        #[arg(long)]
        json: bool,
    },
    Import {
        bundle: PathBuf,
        #[arg(long)]
        ignore_expiry: bool,
        /// Commit and verify store/auth while an operator-proven runtime is idle.
        #[arg(long)]
        offline_file_only: bool,
    },
    UpdateBundle {
        bundle: PathBuf,
        #[arg(long)]
        ignore_expiry: bool,
        /// Keep this host's current active provider account authoritative.
        #[arg(long)]
        preserve_active: bool,
        /// Commit and verify store/auth while an operator-proven runtime is idle.
        #[arg(long)]
        offline_file_only: bool,
    },
    Status,
    Files {
        #[command(subcommand)]
        command: secure_drop::FilesCommand,
    },
    AuthDiagnostics {
        #[arg(long)]
        json: bool,
    },
    CodexUpdateStatus {
        #[arg(long)]
        json: bool,
    },
    CheckCodexUpdate {
        #[arg(long)]
        force: bool,
        #[arg(long)]
        prepare: bool,
        #[arg(long)]
        json: bool,
    },
    PrepareCodexUpdate {
        #[arg(long)]
        version: String,
        #[arg(long)]
        json: bool,
    },
    #[command(name = "stage-macos-runtime-artifact")]
    StageMacOsRuntimeArtifact {
        #[arg(long)]
        directory: PathBuf,
        #[arg(long)]
        json: bool,
    },
    #[command(name = "activate-macos-runtime-artifact")]
    ActivateMacOsRuntimeArtifact {
        #[arg(long)]
        directory: PathBuf,
        #[arg(long)]
        json: bool,
    },
    #[command(name = "macos-runtime-contract", hide = true)]
    MacOsRuntimeContract,
    InstallPreparedCodex {
        #[arg(long)]
        json: bool,
    },
    #[command(hide = true)]
    AutoInstallCodexUpdate {
        #[arg(long)]
        json: bool,
    },
    Swap {
        account: String,
    },
    /// Redeem one banked reset for one blocked paid account without activating it.
    RedeemReset {
        account: String,
        #[arg(long)]
        json: bool,
    },
    RotateNow {
        #[arg(long, default_value = "external_runtime_failure")]
        reason: String,
        #[arg(long, default_value_t = 18_000)]
        cooldown_seconds: i64,
        /// Allow this command to consume a banked reset before rotating.
        #[arg(long)]
        allow_banked_reset: bool,
        /// Commit store/auth without claiming a hot swap. Intended only when no runtime is live.
        #[arg(long)]
        offline_file_only: bool,
        /// Bind runtime reload requests and acknowledgements to this canonical UUID.
        #[arg(
            long,
            value_parser = parse_canonical_uuid,
            conflicts_with = "offline_file_only"
        )]
        receipt_nonce: Option<Uuid>,
        #[arg(long)]
        json: bool,
    },
    /// Confirm a reviewed activation barrier without changing account credentials.
    ResolveActivation {
        #[arg(long)]
        yes: bool,
        #[arg(long)]
        json: bool,
    },
    Daemon {
        #[arg(long, default_value_t = 5)]
        interval_seconds: u64,
    },
    Poll {
        account: Option<String>,
    },
    RestartCodex {
        #[arg(long)]
        yes: bool,
        #[arg(long)]
        include_app_server: bool,
    },
    FixCodex {
        #[arg(long)]
        yes: bool,
        #[arg(long, default_value = "0.125.0")]
        version: String,
    },
    InstallPatchedCodex {
        #[arg(long, default_value = "~/.local/share/codexswitch/codex-source")]
        source: PathBuf,
        #[arg(long)]
        yes: bool,
        #[arg(long)]
        replace_system_entry: bool,
        #[arg(long)]
        replace_npm_vendor: bool,
    },
}

fn main() -> Result<()> {
    codex_update::arm_background_update_deadline();
    let args = Args::parse();
    let store_path = args.store.unwrap_or(default_store_path()?);
    let auth_path = args.auth.unwrap_or(default_auth_path()?);

    match args.command {
        Command::Doctor { json } => doctor(&store_path, &auth_path, json),
        Command::Import {
            bundle,
            ignore_expiry,
            offline_file_only,
        } => import_accounts(
            &bundle,
            &store_path,
            &auth_path,
            ignore_expiry,
            offline_file_only,
            false,
            "Imported",
        ),
        Command::UpdateBundle {
            bundle,
            ignore_expiry,
            preserve_active,
            offline_file_only,
        } => import_accounts(
            &bundle,
            &store_path,
            &auth_path,
            ignore_expiry,
            offline_file_only,
            preserve_active,
            "Updated",
        ),
        Command::Status => status(&store_path),
        Command::Files { command } => secure_drop::run(command),
        Command::AuthDiagnostics { json } => auth_diagnostics(&store_path, &auth_path, json),
        Command::CodexUpdateStatus { json } => codex_update_status(json),
        Command::CheckCodexUpdate {
            force,
            prepare,
            json,
        } => check_codex_update(force, prepare, json),
        Command::PrepareCodexUpdate { version, json } => prepare_codex_update(&version, json),
        Command::StageMacOsRuntimeArtifact { directory, json } => {
            stage_macos_runtime_artifact(&directory, json)
        }
        Command::ActivateMacOsRuntimeArtifact { directory, json } => {
            activate_macos_runtime_artifact(&directory, json)
        }
        Command::MacOsRuntimeContract => macos_runtime_contract(),
        Command::InstallPreparedCodex { json } => install_prepared_codex(json),
        Command::AutoInstallCodexUpdate { json } => auto_install_codex_update(json),
        Command::Swap { account } => swap(&store_path, &auth_path, &account),
        Command::RedeemReset { account, json } => {
            redeem_reset(&store_path, &auth_path, &account, json)
        }
        Command::RotateNow {
            reason,
            cooldown_seconds,
            allow_banked_reset,
            offline_file_only,
            receipt_nonce,
            json,
        } => rotate_now(
            &store_path,
            &auth_path,
            &reason,
            cooldown_seconds,
            allow_banked_reset,
            !offline_file_only,
            receipt_nonce,
            json,
        ),
        Command::ResolveActivation { yes, json } => {
            resolve_activation(&store_path, &auth_path, yes, json)
        }
        Command::Daemon { interval_seconds } => daemon::run_loop(
            &store_path,
            &auth_path,
            Duration::from_secs(interval_seconds),
        ),
        Command::Poll { account } => poll(&store_path, &auth_path, account.as_deref()),
        Command::RestartCodex {
            yes,
            include_app_server,
        } => restart_codex(yes, include_app_server),
        Command::FixCodex { yes, version } => fix_codex(yes, &version),
        Command::InstallPatchedCodex {
            source,
            yes,
            replace_system_entry,
            replace_npm_vendor,
        } => install_patched_codex(source, yes, replace_system_entry, replace_npm_vendor),
    }
}

fn import_accounts(
    bundle: &Path,
    store_path: &Path,
    auth_path: &Path,
    ignore_expiry: bool,
    offline_file_only: bool,
    preserve_active: bool,
    verb: &str,
) -> Result<()> {
    let imported_accounts = prepare_import_bundle(bundle, ignore_expiry)?;
    let (account_count, outcome) = replace_import_accounts_with_unlocked_reload(
        store_path,
        auth_path,
        imported_accounts,
        preserve_active,
        !offline_file_only,
        &reload_codex_hot_swap_processes,
    )?;
    require_rotation_activation(outcome, !offline_file_only)?;
    if offline_file_only {
        println!(
            "Prepared {} account(s) in file-only mode; runtime convergence is pending for {}",
            account_count,
            auth_path.display()
        );
    } else {
        println!(
            "{} {} account(s); active account written to {}",
            verb,
            account_count,
            auth_path.display()
        );
    }
    Ok(())
}

fn replace_import_accounts_with_unlocked_reload<R>(
    store_path: &Path,
    auth_path: &Path,
    imported_accounts: Vec<account_store::CodexAccount>,
    preserve_active: bool,
    reload_enabled: bool,
    reload: &R,
) -> Result<(usize, ActivationOutcome)>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    if let Some(outcome) =
        reconcile_activation_barrier_unlocked(store_path, auth_path, reload_enabled, reload)?
    {
        require_confirmed_activation(outcome)
            .context("import is blocked by unresolved prior runtime convergence")?;
    }

    let (account_count, prepared) = {
        let store_lock = lock_account_store(store_path)?;
        let snapshot = store_lock.load()?;
        let replacement_accounts = if preserve_active {
            preserve_host_active_account(imported_accounts, &snapshot.accounts)?
        } else {
            imported_accounts
        };
        let account_count = replacement_accounts.len();
        let mut generation = snapshot.generation;
        let mut stored_accounts = snapshot.accounts;
        let outcome = replace_accounts_with(
            &store_lock,
            &mut generation,
            &mut stored_accounts,
            replacement_accounts,
            auth_path,
            false,
            |_| bail!("runtime reload was requested during locked import preparation"),
        )?;
        (account_count, outcome)
    };

    if !reload_enabled || !prepared.is_file_only() {
        return Ok((account_count, prepared));
    }
    let outcome = reconcile_activation_barrier_unlocked(store_path, auth_path, true, reload)?
        .context("import activation disappeared before runtime convergence")?;
    Ok((account_count, outcome))
}

fn preserve_host_active_account(
    mut incoming: Vec<account_store::CodexAccount>,
    current: &[account_store::CodexAccount],
) -> Result<Vec<account_store::CodexAccount>> {
    validate_accounts(&incoming).context("incoming credential bundle is invalid")?;
    if current.is_empty() {
        return Ok(incoming);
    }
    validate_accounts(current).context("current host account store is invalid")?;
    let current_active = active_account(current)
        .context("current host account store has no active provider account")?;

    for account in &mut incoming {
        account.is_active = account.account_id == current_active.account_id;
    }
    if !incoming
        .iter()
        .any(|account| account.account_id == current_active.account_id)
    {
        incoming.push(current_active.clone());
    }
    validate_accounts(&incoming).context("host-preserving credential merge is invalid")?;
    Ok(incoming)
}

pub(crate) fn doctor(store_path: &Path, auth_path: &Path, json: bool) -> Result<()> {
    let report = readiness::check(store_path, auth_path)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("CodexSwitch Linux doctor");
    println!("account store: {}", store_path.display());
    println!("auth file: {}", auth_path.display());
    println!(
        "status: {}",
        if report.ready { "ready" } else { "not ready" }
    );
    println!("summary: {}", report.summary);
    println!("accounts: {}", report.account_count);
    if let Some(active) = &report.active_email {
        println!("active: {active}");
    } else {
        println!("active: none");
    }
    println!("auth writable: {}", report.auth_writable);
    println!("daemon running: {}", report.daemon_running);
    println!("live codex cli processes: {}", report.processes.len());
    for process in report.processes {
        println!(
            "- pid={} verified={} exe={} reason={}",
            process.pid, process.hot_swap_ready, process.executable, process.reason
        );
    }
    println!("codex app-server processes: {}", report.app_servers.len());
    for process in report.app_servers {
        println!(
            "- app-server pid={} verified={} exe={} reason={}",
            process.pid, process.hot_swap_ready, process.executable, process.reason
        );
    }
    if !report.issues.is_empty() {
        println!("issues:");
        for issue in report.issues {
            println!("- {issue}");
        }
    }
    print_codex_update_status_line()?;
    Ok(())
}

pub(crate) fn status(store_path: &Path) -> Result<()> {
    let accounts = load_accounts(store_path)?;
    for account in &accounts {
        let marker = if account.is_active { "*" } else { " " };
        let quota_status = quota_status_fields(account.quota_snapshot.as_ref(), Utc::now());
        let reset_status = account
            .rate_limit_reset_bank
            .as_ref()
            .map(|bank| {
                let next_expiration = bank
                    .oldest_expiring_available_credit(Utc::now())
                    .and_then(|credit| credit.expires_at)
                    .map(|expires_at| format!(" next-reset-expiry={}", expires_at.to_rfc3339()))
                    .unwrap_or_default();
                format!(" resets={}{}", bank.available_count, next_expiration)
            })
            .unwrap_or_else(|| " resets=?".to_string());
        println!(
            "{} {} ({}) {}{}{}",
            marker,
            account.email,
            account.plan_type.as_deref().unwrap_or("unknown"),
            quota_status,
            reset_status,
            account
                .runtime_unusable_until
                .filter(|until| *until > Utc::now())
                .map(|until| format!(
                    " runtime-blocked={} until={}",
                    account
                        .runtime_unusable_reason
                        .as_deref()
                        .unwrap_or("runtime_failure"),
                    until.to_rfc3339()
                ))
                .unwrap_or_default()
        );
    }
    print_codex_update_status_line()?;
    Ok(())
}

fn quota_status_fields(snapshot: Option<&QuotaSnapshot>, now: chrono::DateTime<Utc>) -> String {
    let Some(snapshot) = snapshot else {
        return "quota=?".to_string();
    };
    if !snapshot.is_fresh_at(now) {
        return "quota=stale".to_string();
    }
    let mut fields = snapshot
        .ordered_windows()
        .into_iter()
        .map(|window| {
            let label = match window.kind {
                QuotaWindowKind::FiveHour => "5h".to_string(),
                QuotaWindowKind::Weekly => "weekly".to_string(),
                QuotaWindowKind::Unknown => format!("window-{}s", window.duration_seconds),
            };
            format!("{}={:.0}%", label, window.effective_remaining_percent())
        })
        .collect::<Vec<_>>();
    if snapshot.is_denied() {
        fields.push("quota=denied".to_string());
    } else if fields.is_empty() {
        fields.push("quota=unavailable".to_string());
    }
    fields.join(" ")
}

pub(crate) fn codex_update_status(json_output: bool) -> Result<()> {
    let report = codex_update::status_report()?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(command) = report.install_command.as_deref() {
            println!("install command: {command}");
        }
        if let Some(version) = report.prepared_version.as_deref() {
            println!("prepared version: {version}");
        }
        if let Some(version) = report.installed_version.as_deref() {
            println!("installed version: {version}");
        }
        if let Some(error) = report.error.as_deref() {
            println!("last error: {error}");
        }
    }
    Ok(())
}

pub(crate) fn check_codex_update(force: bool, prepare: bool, json_output: bool) -> Result<()> {
    let report = codex_update::check_for_update(force, prepare)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(command) = report.install_command.as_deref() {
            println!("install command: {command}");
        }
    }
    Ok(())
}

pub(crate) fn prepare_codex_update(version: &str, json_output: bool) -> Result<()> {
    let report = codex_update::prepare_version(version)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(command) = report.install_command.as_deref() {
            println!("install command: {command}");
        }
    }
    Ok(())
}

pub(crate) fn stage_macos_runtime_artifact(directory: &Path, json_output: bool) -> Result<()> {
    let report = codex_update::stage_macos_runtime_artifact(directory)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(command) = report.install_command.as_deref() {
            println!("install command: {command}");
        }
    }
    Ok(())
}

pub(crate) fn activate_macos_runtime_artifact(directory: &Path, json_output: bool) -> Result<()> {
    let report = codex_update::activate_macos_runtime_artifact(directory)?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(version) = report.installed_version.as_deref() {
            println!("installed version: {version}");
        }
    }
    Ok(())
}

pub(crate) fn macos_runtime_contract() -> Result<()> {
    println!(
        "{}",
        serde_json::to_string_pretty(&codex_update::macos_runtime_contract_report())?
    );
    Ok(())
}

pub(crate) fn install_prepared_codex(json_output: bool) -> Result<()> {
    let report = codex_update::install_prepared()?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(version) = report.installed_version.as_deref() {
            println!("installed version: {version}");
        }
    }
    Ok(())
}

pub(crate) fn auto_install_codex_update(json_output: bool) -> Result<()> {
    let report = codex_update::auto_install_update()?;
    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", report.summary);
        if let Some(version) = report.installed_version.as_deref() {
            println!("installed version: {version}");
        }
        if let Some(error) = report.error.as_deref() {
            println!("last error: {error}");
        }
    }
    Ok(())
}

fn print_codex_update_status_line() -> Result<()> {
    let report = codex_update::status_report()?;
    println!("codex update: {}", report.summary);
    if let Some(command) = report.install_command.as_deref() {
        println!("codex update install: {command}");
    }
    Ok(())
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthDiagnostics {
    store_path: String,
    auth_path: String,
    active_email: Option<String>,
    active_account_id: Option<String>,
    active_plan_type: Option<String>,
    active_token_hash_prefix: Option<String>,
    active_runtime_unusable: bool,
    active_runtime_unusable_reason: Option<String>,
    active_runtime_unusable_until: Option<String>,
    auth_file_exists: bool,
    auth_file_mtime: Option<String>,
    auth_account_id: Option<String>,
    auth_token_hash_prefix: Option<String>,
    auth_matches_active_store_token: bool,
    ready_candidate_count: usize,
}

pub(crate) fn auth_diagnostics(
    store_path: &Path,
    auth_path: &Path,
    json_output: bool,
) -> Result<()> {
    let diagnostics = collect_auth_diagnostics(store_path, auth_path)?;

    if json_output {
        println!("{}", serde_json::to_string_pretty(&diagnostics)?);
    } else {
        println!("CodexSwitch auth diagnostics");
        println!("store: {}", diagnostics.store_path);
        println!("auth: {}", diagnostics.auth_path);
        println!(
            "active: {}",
            diagnostics.active_email.as_deref().unwrap_or("none")
        );
        println!(
            "active token hash: {}",
            diagnostics
                .active_token_hash_prefix
                .as_deref()
                .unwrap_or("none")
        );
        println!(
            "auth token hash: {}",
            diagnostics
                .auth_token_hash_prefix
                .as_deref()
                .unwrap_or("none")
        );
        println!(
            "auth matches active store token: {}",
            diagnostics.auth_matches_active_store_token
        );
        println!("ready candidates: {}", diagnostics.ready_candidate_count);
        if diagnostics.active_runtime_unusable {
            println!(
                "active runtime blocked: {} until {}",
                diagnostics
                    .active_runtime_unusable_reason
                    .as_deref()
                    .unwrap_or("runtime_failure"),
                diagnostics
                    .active_runtime_unusable_until
                    .as_deref()
                    .unwrap_or("unknown")
            );
        }
    }
    Ok(())
}

fn collect_auth_diagnostics(store_path: &Path, auth_path: &Path) -> Result<AuthDiagnostics> {
    let accounts = load_accounts(store_path)?;
    let active = active_account(&accounts);
    let auth_info = read_auth_info(auth_path)?;
    let active_token_fingerprint = active.and_then(auth::account_token_fingerprint);
    let diagnostics = AuthDiagnostics {
        store_path: store_path.display().to_string(),
        auth_path: auth_path.display().to_string(),
        active_email: active.map(|account| account.email.clone()),
        active_account_id: active.map(|account| account.account_id.clone()),
        active_plan_type: active.and_then(|account| account.plan_type.clone()),
        active_token_hash_prefix: active_token_fingerprint
            .as_deref()
            .map(fingerprint_hash_prefix),
        active_runtime_unusable: active
            .map(|account| account.runtime_unusable())
            .unwrap_or(false),
        active_runtime_unusable_reason: active
            .and_then(|account| account.runtime_unusable_reason.clone()),
        active_runtime_unusable_until: active
            .and_then(|account| account.runtime_unusable_until)
            .map(|until| until.to_rfc3339()),
        auth_file_exists: auth_info.exists,
        auth_file_mtime: auth_info.mtime,
        auth_account_id: auth_info.account_id,
        auth_token_hash_prefix: auth_info.token_hash_prefix.clone(),
        auth_matches_active_store_token: active_token_fingerprint.is_some()
            && active_token_fingerprint == auth_info.token_fingerprint,
        ready_candidate_count: accounts
            .iter()
            .filter(|account| !account.is_active)
            .filter(|account| {
                quota_availability_at(account, Utc::now()) == QuotaAvailability::Usable
            })
            .count(),
    };
    Ok(diagnostics)
}

pub(crate) fn swap(store_path: &Path, auth_path: &Path, selector: &str) -> Result<()> {
    let (target_email, summary) = swap_with_reload(
        store_path,
        auth_path,
        selector,
        reload_codex_hot_swap_processes,
    )?;
    println!(
        "Swapped to {}; signaled {} Codex hot-swap process(es), restarted {}",
        target_email,
        summary.signaled.len(),
        summary.restarted.len()
    );
    for (pid, reason) in &summary.skipped {
        println!("Skipped pid={pid}: {reason}");
    }
    Ok(())
}

fn swap_with_reload<R>(
    store_path: &Path,
    auth_path: &Path,
    selector: &str,
    reload: R,
) -> Result<(String, ReloadSummary)>
where
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    let prior_summary = if let Some(outcome) =
        reconcile_activation_barrier_unlocked(store_path, auth_path, true, &reload)?
    {
        Some(
            require_confirmed_activation(outcome)
                .context("swap is blocked by unresolved prior runtime convergence")?,
        )
    } else {
        None
    };
    let snapshot = load_account_store_snapshot(store_path)?;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let target_id = resolve_account_selector(&accounts, selector)?;
    let target_email = accounts
        .iter()
        .find(|account| account.id == target_id)
        .map(|account| account.email.clone())
        .context("activation target disappeared")?;
    if active_account(&accounts).map(|account| account.id) == Some(target_id) {
        if let Some(summary) = prior_summary {
            return Ok((target_email, summary));
        }
    }
    let outcome = activate_with_unlocked_reload(
        store_path,
        auth_path,
        &mut generation,
        &mut accounts,
        target_id,
        true,
        &reload,
    )?;
    let summary = require_confirmed_activation(outcome)?;
    Ok((target_email, summary))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResolveActivationReport {
    state: ActivationState,
    verified_runtime_acks: usize,
    skipped_runtime_targets: usize,
    detail: Option<String>,
}

fn resolve_activation(store_path: &Path, auth_path: &Path, yes: bool, json: bool) -> Result<()> {
    if !yes {
        bail!("resolve-activation requires --yes after reviewing the activation record");
    }

    let outcome = resolve_manual_review_activation_unlocked(
        store_path,
        auth_path,
        &reload_codex_hot_swap_processes,
    )?;
    let report = ResolveActivationReport {
        state: outcome.state,
        verified_runtime_acks: outcome.reload.signaled.len(),
        skipped_runtime_targets: outcome.reload.skipped.len(),
        detail: outcome.detail,
    };
    if json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!(
            "Resolved activation barrier with {} verified runtime ACK(s)",
            report.verified_runtime_acks
        );
    }
    Ok(())
}

fn require_confirmed_activation(outcome: ActivationOutcome) -> Result<ReloadSummary> {
    if outcome.is_confirmed() {
        return Ok(outcome.reload);
    }
    bail!(
        "activation did not publish as swapped ({:?}): {}",
        outcome.state,
        outcome.detail.as_deref().unwrap_or("no detail")
    )
}

fn require_rotation_activation(
    outcome: ActivationOutcome,
    reload_processes: bool,
) -> Result<ReloadSummary> {
    if reload_processes {
        return require_confirmed_activation(outcome);
    }
    if outcome.is_file_only() {
        return Ok(outcome.reload);
    }
    bail!(
        "offline file-only activation did not converge ({:?}): {}",
        outcome.state,
        outcome.detail.as_deref().unwrap_or("no detail")
    )
}

fn require_rotation_receipt_proof(
    summary: &ReloadSummary,
    receipt_nonce: Option<Uuid>,
    reload_processes: bool,
) -> Result<()> {
    let Some(receipt_nonce) = receipt_nonce else {
        return Ok(());
    };
    if !reload_processes {
        bail!("receipt-bound rotation requires live runtime reload");
    }
    if summary.receipt_nonce != Some(receipt_nonce) {
        bail!("runtime reload did not preserve the requested receipt nonce");
    }
    if !summary.verified_hot_swap() {
        bail!(
            "receipt-bound rotation lacks complete request, acknowledgement, count, or topology proof"
        );
    }
    Ok(())
}

fn ensure_reload_converged(skipped: &[(i32, String)]) -> Result<()> {
    if skipped.is_empty() {
        return Ok(());
    }
    bail!(
        "auth was written, but {} discovered Codex runtime(s) did not acknowledge the reload; restart is required",
        skipped.len()
    )
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RedeemResetReport {
    account: String,
    account_id: String,
    was_active: bool,
    submitted_reset: bool,
    previous_banked_resets: u32,
    banked_resets_remaining: u32,
    remaining_percent: Option<f64>,
}

pub(crate) fn redeem_reset(
    store_path: &Path,
    auth_path: &Path,
    selector: &str,
    json_output: bool,
) -> Result<()> {
    let report = redeem_reset_with(
        store_path,
        auth_path,
        selector,
        fetch_quota,
        fetch_rate_limit_reset_bank,
        consume_rate_limit_reset,
    )?;

    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        let action = if report.submitted_reset {
            "Redeemed"
        } else {
            "Reconciled"
        };
        println!(
            "{action} one banked reset for {}; {} reset(s) remain and the active account was unchanged",
            report.account, report.banked_resets_remaining
        );
    }
    Ok(())
}

fn redeem_reset_with<F, B, C>(
    store_path: &Path,
    auth_path: &Path,
    selector: &str,
    fetch_quota_fn: F,
    fetch_reset_bank_fn: B,
    consume_reset_fn: C,
) -> Result<RedeemResetReport>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    B: Fn(&account_store::CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&account_store::CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
{
    let snapshot = preflight_provider_io_activation(store_path, auth_path)
        .context("targeted reset activation preflight failed")?;
    let activation_guard = snapshot.guard;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let target_id = resolve_account_selector(&accounts, selector)?;
    let target_index = accounts
        .iter()
        .position(|account| account.id == target_id)
        .context("resolved reset target disappeared from the account store")?;
    if !accounts[target_index].has_complete_token_material() {
        bail!(
            "banked reset redemption requires complete runtime credentials for {}",
            accounts[target_index].email
        );
    }

    validate_provider_io_activation(store_path, auth_path, &activation_guard)
        .context("targeted reset activation changed before quota refresh")?;
    let quota_result = fetch_quota_fn(&accounts[target_index]).with_context(|| {
        format!(
            "failed to refresh quota for {}",
            accounts[target_index].email
        )
    })?;
    apply_fetch_result(&mut accounts[target_index], quota_result);

    if accounts[target_index].plan_priority() <= 1 {
        let email = accounts[target_index].email.clone();
        let store_lock = lock_account_store(store_path)?;
        if store_lock.load()?.generation != generation {
            bail!(
                "account store changed during targeted reset observation; retry from fresh state"
            );
        }
        commit_accounts_with_provider_io_activation(
            &store_lock,
            &mut generation,
            &accounts,
            auth_path,
            &activation_guard,
        )?;
        bail!("banked reset redemption requires a paid account; {email} is not paid");
    }

    let previous_bank = accounts[target_index].rate_limit_reset_bank.clone();
    validate_provider_io_activation(store_path, auth_path, &activation_guard)
        .context("targeted reset activation changed before reset-bank refresh")?;
    let observed_bank_result = fetch_reset_bank_fn(&accounts[target_index]);
    let store_lock = lock_account_store(store_path)?;
    validate_provider_io_activation_locked(&store_lock, auth_path, &activation_guard)
        .context("targeted reset activation changed during provider observation")?;
    let observed_bank = match observed_bank_result {
        Ok(bank) => bank,
        Err(error) => {
            let email = accounts[target_index].email.clone();
            commit_accounts_with_provider_io_activation(
                &store_lock,
                &mut generation,
                &accounts,
                auth_path,
                &activation_guard,
            )?;
            return Err(error).with_context(|| format!("failed to refresh reset bank for {email}"));
        }
    };
    let decision_now = std::cmp::max(Utc::now(), observed_bank.fetched_at);
    let quota_availability = real_quota_snapshot(&accounts[target_index])
        .map(|snapshot| snapshot.availability_at(decision_now))
        .unwrap_or(QuotaAvailability::Unknown);
    let attempt_reset = quota_availability == QuotaAvailability::Blocked;

    let email = accounts[target_index].email.clone();
    let account_id = accounts[target_index].account_id.clone();
    let was_active = accounts[target_index].is_active;
    let previous_banked_resets = observed_bank.available_count;
    let previous_runtime_unusable_until = accounts[target_index].runtime_unusable_until;
    let previous_runtime_unusable_reason = accounts[target_index].runtime_unusable_reason.clone();
    accounts[target_index].runtime_unusable_until = None;
    accounts[target_index].runtime_unusable_reason = None;

    let mut submitted_reset = false;
    let flow_result = reconcile_or_attempt_reset_with_provider_guard(
        ResetReconciliationContext {
            store_lock: &store_lock,
            account: &mut accounts[target_index],
            previous_bank: previous_bank.as_ref(),
            observed_bank,
            attempt_reset,
            now: decision_now,
        },
        ResetReconciliationDependencies::new(
            |account| fetch_reset_bank_fn(account),
            |account| {
                let result = fetch_quota_fn(&*account)?;
                apply_fetch_result(account, result);
                Ok(())
            },
            |account, bank, request_id| {
                submitted_reset = true;
                consume_reset_fn(account, bank, request_id)
            },
        ),
        |store_lock| {
            validate_provider_io_activation_locked(store_lock, auth_path, &activation_guard)
        },
    );

    let usable_success = flow_result
        .as_ref()
        .map(|flow| flow.is_usable_success())
        .unwrap_or(false);
    if !usable_success {
        accounts[target_index].runtime_unusable_until = previous_runtime_unusable_until;
        accounts[target_index].runtime_unusable_reason = previous_runtime_unusable_reason;
    }
    let banked_resets_remaining = accounts[target_index]
        .rate_limit_reset_bank
        .as_ref()
        .map(|bank| bank.available_count)
        .unwrap_or(previous_banked_resets);
    let remaining_percent = real_quota_snapshot(&accounts[target_index])
        .and_then(QuotaSnapshot::minimum_remaining_percent);
    commit_accounts_with_provider_io_activation(
        &store_lock,
        &mut generation,
        &accounts,
        auth_path,
        &activation_guard,
    )?;

    let flow = flow_result.with_context(|| format!("reset reconciliation failed for {email}"))?;
    if !flow.is_usable_success() {
        if !attempt_reset {
            bail!(
                "banked reset redemption requires a fresh blocked quota for {email}; observed {quota_availability:?}"
            );
        }
        bail!(
            "banked reset was not reconciled as usable for {email}: {}",
            flow.detail
                .as_deref()
                .unwrap_or("no available reset or no confirmed inventory decrease")
        );
    }

    Ok(RedeemResetReport {
        account: email,
        account_id,
        was_active,
        submitted_reset,
        previous_banked_resets,
        banked_resets_remaining,
        remaining_percent,
    })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RotateNowReport {
    receipt_nonce: Option<Uuid>,
    reason: String,
    previous_email: String,
    previous_token_hash_prefix: String,
    next_email: String,
    next_token_hash_prefix: String,
    next_token_fingerprint: String,
    auth_path: String,
    activation_state: ActivationState,
    runtime_converged: bool,
    reload_attempted: bool,
    topology_verified: bool,
    request_count: usize,
    sighup_sent_processes: usize,
    signaled_processes: usize,
    restarted_processes: usize,
    skipped_processes: usize,
    acknowledged_request_nonces: Vec<String>,
    used_banked_reset: bool,
    banked_resets_remaining: Option<u32>,
    reset_reason: Option<SmartResetReason>,
    #[serde(skip)]
    skipped: Vec<(i32, String)>,
}

pub(crate) fn rotate_now(
    store_path: &Path,
    auth_path: &Path,
    reason: &str,
    cooldown_seconds: i64,
    allow_banked_reset: bool,
    reload_processes: bool,
    receipt_nonce: Option<Uuid>,
    json_output: bool,
) -> Result<()> {
    if receipt_nonce.is_some() && !reload_processes {
        bail!("--receipt-nonce cannot be combined with --offline-file-only");
    }
    let receipt_evidence = std::cell::RefCell::new(ReloadSummary {
        topology_verified: true,
        receipt_nonce,
        ..ReloadSummary::default()
    });
    let reload = |path: &Path| match receipt_nonce {
        Some(receipt_nonce) => reload_codex_hot_swap_processes_for_receipt(path, receipt_nonce)
            .map(|summary| {
                merge_reload_evidence(&mut receipt_evidence.borrow_mut(), &summary);
                summary
            }),
        None => reload_codex_hot_swap_processes(path),
    };
    let mut report = rotate_now_with_resets(
        RotateNowContext {
            store_path,
            auth_path,
            reason,
            cooldown_seconds,
            reload_processes,
            allow_banked_reset,
            receipt_nonce,
        },
        RotateNowDependencies::new(
            fetch_quota,
            fetch_rate_limit_reset_bank,
            consume_rate_limit_reset,
            reload,
        ),
    )?;
    if receipt_nonce.is_some() {
        let evidence = receipt_evidence.into_inner();
        require_rotation_receipt_proof(&evidence, receipt_nonce, reload_processes)?;
        report.topology_verified = evidence.topology_verified;
        report.request_count = evidence.generated_request_nonces.len();
        report.sighup_sent_processes = evidence.sighup_sent.len();
        report.signaled_processes = evidence.signaled.len();
        report.restarted_processes = evidence.restarted.len();
        report.skipped_processes = evidence.skipped.len();
        report.acknowledged_request_nonces = evidence.acknowledged_request_nonces;
        report.skipped = evidence.skipped;
    }

    if json_output {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else if report.used_banked_reset {
        println!(
            "Applied a banked reset to {} for {}; {} reset(s) remain; signaled {} process(es), restarted {}",
            report.next_email,
            report
                .reset_reason
                .map(SmartResetReason::as_str)
                .unwrap_or("usage_limit"),
            report.banked_resets_remaining.unwrap_or(0),
            report.signaled_processes,
            report.restarted_processes
        );
        if !reload_processes {
            println!("File-only activation was requested with --offline-file-only.");
        }
    } else if report.previous_email == report.next_email {
        println!(
            "Kept {} active for {}; fresh quota says it is still usable; signaled {} process(es), restarted {}",
            report.next_email, report.reason, report.signaled_processes, report.restarted_processes
        );
        if !reload_processes {
            println!("File-only activation was requested with --offline-file-only.");
        }
    } else {
        println!(
            "Rotated from {} to {} for {}; signaled {} process(es), restarted {}",
            report.previous_email,
            report.next_email,
            report.reason,
            report.signaled_processes,
            report.restarted_processes
        );
        if !reload_processes {
            println!("File-only activation was requested with --offline-file-only.");
        }
    }
    if reload_processes {
        for (pid, reason) in &report.skipped {
            println!("Skipped pid={pid}: {reason}");
        }
        ensure_reload_converged(&report.skipped)?;
    }
    Ok(())
}

fn merge_reload_evidence(aggregate: &mut ReloadSummary, summary: &ReloadSummary) {
    aggregate.topology_verified &= summary.topology_verified;
    aggregate
        .sighup_sent
        .extend_from_slice(&summary.sighup_sent);
    aggregate.signaled.extend_from_slice(&summary.signaled);
    aggregate.restarted.extend_from_slice(&summary.restarted);
    aggregate.skipped.extend(summary.skipped.iter().cloned());
    aggregate
        .generated_request_nonces
        .extend(summary.generated_request_nonces.iter().cloned());
    aggregate
        .acknowledged_request_nonces
        .extend(summary.acknowledged_request_nonces.iter().cloned());
}

#[cfg(test)]
fn rotate_now_with<F, R>(
    store_path: &Path,
    auth_path: &Path,
    reason: &str,
    cooldown_seconds: i64,
    reload_processes: bool,
    fetch_quota_fn: F,
    reload_fn: R,
) -> Result<RotateNowReport>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    rotate_now_with_resets(
        RotateNowContext {
            store_path,
            auth_path,
            reason,
            cooldown_seconds,
            reload_processes,
            allow_banked_reset: false,
            receipt_nonce: None,
        },
        RotateNowDependencies::new(
            fetch_quota_fn,
            |_account| bail!("reset inventory unavailable in legacy test harness"),
            |_account, _bank, _request_id| {
                bail!("reset consume unavailable in legacy test harness")
            },
            reload_fn,
        ),
    )
}

struct RotateNowContext<'a> {
    store_path: &'a Path,
    auth_path: &'a Path,
    reason: &'a str,
    cooldown_seconds: i64,
    reload_processes: bool,
    allow_banked_reset: bool,
    receipt_nonce: Option<Uuid>,
}

struct RotateNowDependencies<F, B, C, R> {
    fetch_quota: F,
    fetch_reset_bank: B,
    consume_reset: C,
    reload: R,
}

impl<F, B, C, R> RotateNowDependencies<F, B, C, R>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    B: Fn(&account_store::CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&account_store::CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    fn new(fetch_quota: F, fetch_reset_bank: B, consume_reset: C, reload: R) -> Self {
        Self {
            fetch_quota,
            fetch_reset_bank,
            consume_reset,
            reload,
        }
    }
}

fn rotate_now_with_resets<F, B, C, R>(
    context: RotateNowContext<'_>,
    dependencies: RotateNowDependencies<F, B, C, R>,
) -> Result<RotateNowReport>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    B: Fn(&account_store::CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&account_store::CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
{
    rotate_now_with_resets_and_barrier_loader(context, dependencies, |store_lock| store_lock.load())
}

fn rotate_now_with_resets_and_barrier_loader<F, B, C, R, L>(
    context: RotateNowContext<'_>,
    dependencies: RotateNowDependencies<F, B, C, R>,
    load_after_barrier: L,
) -> Result<RotateNowReport>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    B: Fn(&account_store::CodexAccount) -> Result<RateLimitResetBank>,
    C: Fn(&account_store::CodexAccount, &RateLimitResetBank, Uuid) -> Result<ConsumeResult>,
    R: Fn(&Path) -> Result<ReloadSummary>,
    L: Fn(&account_store::AccountStoreLock) -> Result<account_store::AccountStoreSnapshot>,
{
    let RotateNowContext {
        store_path,
        auth_path,
        reason,
        cooldown_seconds,
        reload_processes,
        allow_banked_reset,
        receipt_nonce,
    } = context;
    let RotateNowDependencies {
        fetch_quota: fetch_quota_fn,
        fetch_reset_bank: fetch_reset_bank_fn,
        consume_reset: consume_reset_fn,
        reload: reload_fn,
    } = dependencies;
    if receipt_nonce.is_some() && !reload_processes {
        bail!("receipt-bound rotation requires live runtime reload");
    }
    if let Some(outcome) =
        reconcile_activation_barrier_unlocked(store_path, auth_path, reload_processes, &reload_fn)?
    {
        // This outcome belongs to an activation that predated the current
        // command. Offline mode may create FileOnly for the new request, but it
        // must never waive runtime convergence of an older barrier.
        require_confirmed_activation(outcome)?;
        let store_lock = lock_account_store(store_path)?;
        let _ = load_after_barrier(&store_lock)?;
    }
    let snapshot = preflight_provider_io_activation(store_path, auth_path)
        .context("rotate-now provider-I/O activation preflight failed")?;
    let activation_guard = snapshot.guard;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let fetch_quota_fn = |account: &account_store::CodexAccount| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("rotate-now activation changed before quota provider I/O")?;
        fetch_quota_fn(account)
    };
    let fetch_reset_bank_fn = |account: &account_store::CodexAccount| {
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("rotate-now activation changed before reset-bank provider I/O")?;
        fetch_reset_bank_fn(account)
    };
    let consume_reset_fn =
        |account: &account_store::CodexAccount, bank: &RateLimitResetBank, request_id: Uuid| {
            validate_provider_io_activation(store_path, auth_path, &activation_guard)
                .context("rotate-now activation changed before reset provider submission")?;
            consume_reset_fn(account, bank, request_id)
        };
    let active_index = accounts
        .iter()
        .position(|account| account.is_active)
        .context("no active account in store")?;
    let previous_email = accounts[active_index].email.clone();
    let previous_token_hash_prefix = token_hash_prefix(&accounts[active_index].access_token);

    let fallback_until = Utc::now() + ChronoDuration::seconds(cooldown_seconds.max(60));
    if reason == "usage_limit" {
        // A typed runtime usage-limit response is newer and more authoritative
        // than the separately cached quota endpoint. Refresh the active account
        // for reset timing and bank policy, but never let a healthy-looking poll
        // keep the rejected account active.
        if let Ok(result) = fetch_quota_fn(&accounts[active_index]) {
            apply_fetch_result(&mut accounts[active_index], result);
        }
    }

    let candidate_observations = refresh_direct_rotation_candidates(&mut accounts, &fetch_quota_fn);

    if reason == "usage_limit" {
        let reset_result: Result<(
            rate_limit_resets::ResetOrchestrationResult<usize>,
            Option<ActivationOutcome>,
        )> = (|| {
            let store_lock = lock_account_store(store_path)?;
            validate_provider_io_activation_locked(&store_lock, auth_path, &activation_guard)
                .context("rotate-now activation changed during reset observation")?;
            let outcome = orchestrate_reset_with_provider_guard(
                ResetOrchestrationContext {
                    store_lock: &store_lock,
                    accounts: &mut accounts,
                    active_index,
                    candidate_observations: Some(&candidate_observations),
                    allow_reset: allow_banked_reset,
                    direct_runtime_usage_limit: true,
                    refresh_strategy: ResetQuotaRefreshStrategy::Direct,
                    now: Utc::now(),
                },
                ResetOrchestrationDependencies::new(
                    |account: &account_store::CodexAccount| fetch_reset_bank_fn(account),
                    |account: &mut account_store::CodexAccount, strategy| {
                        debug_assert_eq!(strategy, ResetQuotaRefreshStrategy::Direct);
                        let result = fetch_quota_fn(&*account)?;
                        apply_fetch_result(account, result);
                        Ok(())
                    },
                    |account: &account_store::CodexAccount,
                     bank: &RateLimitResetBank,
                     request_id| consume_reset_fn(account, bank, request_id),
                    |_accounts: &mut [account_store::CodexAccount], index: usize| Ok(index),
                ),
                |store_lock| {
                    validate_provider_io_activation_locked(store_lock, auth_path, &activation_guard)
                },
            )?;
            validate_provider_io_activation_locked(
                &store_lock,
                auth_path,
                &activation_guard,
            )
            .context(
                "rotate-now activation changed during reset network I/O; the durable reset journal remains recoverable",
            )?;
            let prepared_activation = if let Some(index) = outcome.completion {
                let target_id = accounts[index].id;
                Some(activate_with(
                    ActivationContext {
                        store_lock: &store_lock,
                        generation: &mut generation,
                        accounts: &mut accounts,
                        auth_path,
                        target_id,
                        reload_enabled: false,
                    },
                    |_| bail!("runtime reload was requested during the locked reset commit"),
                )?)
            } else {
                None
            };
            Ok((outcome, prepared_activation))
        })();
        match reset_result {
            Ok((outcome, prepared_activation)) => {
                if let Some(prepared_activation) = prepared_activation {
                    let activation = if reload_processes {
                        reconcile_activation_barrier_unlocked(
                            store_path,
                            auth_path,
                            true,
                            &reload_fn,
                        )?
                        .context("reset activation disappeared before runtime convergence")?
                    } else {
                        prepared_activation
                    };
                    let activation_state = activation.state;
                    let summary = require_rotation_activation(activation, reload_processes)?;
                    require_rotation_receipt_proof(
                        &summary,
                        receipt_nonce,
                        reload_processes,
                    )?;
                    let refreshed = load_account_store_snapshot(store_path)?;
                    accounts = refreshed.accounts;
                    let next_active_index = accounts
                        .iter()
                        .position(|account| account.is_active)
                        .context("reset activation lost its active account")?;
                    let next_token_fingerprint =
                        auth::account_token_fingerprint(&accounts[next_active_index])
                    .context("reset activation has incomplete token material")?;
                    return Ok(RotateNowReport {
                        receipt_nonce,
                        reason: reason.to_string(),
                        previous_email: previous_email.clone(),
                        previous_token_hash_prefix,
                        next_email: previous_email,
                        next_token_hash_prefix: token_hash_prefix(
                            &accounts[next_active_index].access_token,
                        ),
                        next_token_fingerprint,
                        auth_path: auth_path.display().to_string(),
                        activation_state,
                        runtime_converged: summary.verified_hot_swap(),
                        reload_attempted: reload_processes,
                        topology_verified: summary.topology_verified,
                        request_count: summary.generated_request_nonces.len(),
                        sighup_sent_processes: summary.sighup_sent.len(),
                        signaled_processes: summary.signaled.len(),
                        restarted_processes: summary.restarted.len(),
                        skipped_processes: summary.skipped.len(),
                        acknowledged_request_nonces: summary
                            .acknowledged_request_nonces
                            .clone(),
                        used_banked_reset: true,
                        banked_resets_remaining: accounts[next_active_index]
                            .rate_limit_reset_bank
                            .as_ref()
                            .map(|bank| bank.available_count),
                        reset_reason: outcome.reason,
                        skipped: summary.skipped,
                    });
                }
                if outcome.flow.suppresses_redemption() {
                    eprintln!(
                        "banked reset remains unreconciled for {}; new redemption is suppressed{}",
                        accounts[active_index].email,
                        outcome
                            .flow
                            .detail
                            .as_deref()
                            .map(|detail| format!(": {detail}"))
                            .unwrap_or_default()
                    );
                }
            }
            Err(error) => eprintln!(
                "warning: reset reconciliation failed for {}; continuing with normal rotation: {error:#}",
                accounts[active_index].email
            ),
        }

        let block_until = usage_limit_runtime_block_until(&accounts[active_index], fallback_until);
        mark_runtime_unusable(&mut accounts[active_index], reason, block_until);
    } else {
        mark_runtime_unusable(&mut accounts[active_index], reason, fallback_until);
    }

    let Some(target) = select_auto_swap_candidate_from_observations(
        &accounts,
        &candidate_observations,
        Utc::now(),
    )
    .cloned() else {
        let store_lock = lock_account_store(store_path)?;
        if store_lock.load()?.generation != generation {
            bail!("account store changed before rotate-now fallback commit");
        }
        commit_accounts_with_provider_io_activation(
            &store_lock,
            &mut generation,
            &accounts,
            auth_path,
            &activation_guard,
        )?;
        bail!(
            "marked {previous_email} unusable but no freshly confirmed usable replacement exists"
        );
    };

    validate_provider_io_activation(store_path, auth_path, &activation_guard)
        .context("rotate-now activation changed before rotation")?;
    let activation = activate_with_unlocked_reload(
        store_path,
        auth_path,
        &mut generation,
        &mut accounts,
        target.id,
        reload_processes,
        &reload_fn,
    )?;
    let activation_state = activation.state;
    let summary = require_rotation_activation(activation, reload_processes)?;
    require_rotation_receipt_proof(&summary, receipt_nonce, reload_processes)?;
    let next_token_fingerprint = auth::account_token_fingerprint(&target)
        .context("rotation target has incomplete token material")?;
    Ok(RotateNowReport {
        receipt_nonce,
        reason: reason.to_string(),
        previous_email,
        previous_token_hash_prefix,
        next_email: target.email.clone(),
        next_token_hash_prefix: token_hash_prefix(&target.access_token),
        next_token_fingerprint,
        auth_path: auth_path.display().to_string(),
        activation_state,
        runtime_converged: summary.verified_hot_swap(),
        reload_attempted: reload_processes,
        topology_verified: summary.topology_verified,
        request_count: summary.generated_request_nonces.len(),
        sighup_sent_processes: summary.sighup_sent.len(),
        signaled_processes: summary.signaled.len(),
        restarted_processes: summary.restarted.len(),
        skipped_processes: summary.skipped.len(),
        acknowledged_request_nonces: summary.acknowledged_request_nonces.clone(),
        used_banked_reset: false,
        banked_resets_remaining: accounts[active_index]
            .rate_limit_reset_bank
            .as_ref()
            .map(|bank| bank.available_count),
        reset_reason: None,
        skipped: summary.skipped,
    })
}

fn refresh_direct_rotation_candidates<F>(
    accounts: &mut [account_store::CodexAccount],
    fetch_quota_fn: &F,
) -> CurrentQuotaObservations
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
{
    let mut observations = CurrentQuotaObservations::new(Utc::now());
    for account in accounts.iter_mut().filter(|account| !account.is_active) {
        if account.runtime_unusable() {
            continue;
        }
        if let Ok(result) = fetch_quota_fn(account) {
            apply_fetch_result(account, result);
            observations.record_success(account);
        }
    }
    observations
}

pub(crate) fn poll(store_path: &Path, auth_path: &Path, selector: Option<&str>) -> Result<()> {
    poll_with(
        store_path,
        auth_path,
        selector,
        fetch_quota,
        fetch_rate_limit_reset_bank,
    )
}

fn poll_with<F, B>(
    store_path: &Path,
    auth_path: &Path,
    selector: Option<&str>,
    fetch_quota_fn: F,
    fetch_reset_bank_fn: B,
) -> Result<()>
where
    F: Fn(&account_store::CodexAccount) -> Result<FetchResult>,
    B: Fn(&account_store::CodexAccount) -> Result<RateLimitResetBank>,
{
    let snapshot = preflight_provider_io_activation(store_path, auth_path)
        .context("poll activation preflight failed")?;
    let activation_guard = snapshot.guard;
    let mut generation = snapshot.generation;
    let mut accounts = snapshot.accounts;
    let selectors: Vec<String> = match selector {
        Some(selector) => vec![selector.to_string()],
        None => accounts
            .iter()
            .map(|account| account.account_id.clone())
            .collect(),
    };

    for selector in selectors {
        let Some(index) = accounts.iter().position(|account| {
            account.account_id == selector
                || account.email.eq_ignore_ascii_case(&selector)
                || account.id.to_string() == selector
        }) else {
            eprintln!("warning: no account matched {selector}");
            continue;
        };

        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("poll activation changed before quota callback")?;
        let result = fetch_quota_fn(&accounts[index])
            .with_context(|| format!("failed to poll {}", accounts[index].email))?;
        apply_fetch_result(&mut accounts[index], result);
        validate_provider_io_activation(store_path, auth_path, &activation_guard)
            .context("poll activation changed before reset-bank callback")?;
        match fetch_reset_bank_fn(&accounts[index]) {
            Ok(bank) => {
                let available_count = bank.available_count;
                accounts[index].rate_limit_reset_bank = Some(bank);
                println!(
                    "polled {} ({} banked reset(s))",
                    accounts[index].email, available_count
                );
            }
            Err(error) => {
                eprintln!(
                    "warning: failed to poll reset bank for {}: {error:#}",
                    accounts[index].email
                );
                println!("polled {}", accounts[index].email);
            }
        }
    }

    let store_lock = lock_account_store(store_path)?;
    commit_accounts_with_provider_io_activation(
        &store_lock,
        &mut generation,
        &accounts,
        auth_path,
        &activation_guard,
    )?;
    Ok(())
}

#[derive(Debug)]
struct AuthInfo {
    exists: bool,
    mtime: Option<String>,
    account_id: Option<String>,
    token_fingerprint: Option<String>,
    token_hash_prefix: Option<String>,
}

const AUTH_DIAGNOSTIC_MAX_BYTES: usize = 1024 * 1024;

fn read_auth_info(auth_path: &Path) -> Result<AuthInfo> {
    let snapshot = secure_file::observe(auth_path, AUTH_DIAGNOSTIC_MAX_BYTES, true)
        .with_context(|| format!("failed to securely observe {}", auth_path.display()))?;
    let Some(bytes) = snapshot.bytes() else {
        return Ok(AuthInfo {
            exists: false,
            mtime: None,
            account_id: None,
            token_fingerprint: None,
            token_hash_prefix: None,
        });
    };

    let mtime = snapshot
        .modified_unix()
        .and_then(|(seconds, nanoseconds)| {
            chrono::DateTime::<Utc>::from_timestamp(seconds, nanoseconds)
        })
        .map(|time| time.to_rfc3339());
    let value: Value = serde_json::from_slice(bytes)
        .with_context(|| format!("failed to decode {}", auth_path.display()))?;
    let tokens = value.get("tokens").and_then(|tokens| tokens.as_object());
    let account_id = tokens
        .and_then(|tokens| tokens.get("account_id"))
        .and_then(|value| value.as_str())
        .map(str::to_string);
    let token_fingerprint = diagnostic_auth_fingerprint(&value);
    let token_hash_prefix = token_fingerprint.as_deref().map(fingerprint_hash_prefix);

    Ok(AuthInfo {
        exists: true,
        mtime,
        account_id,
        token_fingerprint,
        token_hash_prefix,
    })
}

fn diagnostic_auth_fingerprint(value: &Value) -> Option<String> {
    let tokens = value.get("tokens")?;
    let parts = [
        tokens.get("id_token")?.as_str()?,
        tokens.get("access_token")?.as_str()?,
        tokens.get("refresh_token")?.as_str()?,
        tokens.get("account_id")?.as_str()?,
    ];
    if parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    let mut context = DigestContext::new(&SHA256);
    for part in parts {
        context.update(&(part.len() as u64).to_be_bytes());
        context.update(part.as_bytes());
    }
    Some(
        context
            .finish()
            .as_ref()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

fn fingerprint_hash_prefix(fingerprint: &str) -> String {
    fingerprint.chars().take(12).collect()
}

fn token_hash_prefix(token: &str) -> String {
    hex_prefix(digest(&SHA256, token.as_bytes()).as_ref(), 12)
}

fn hex_prefix(bytes: &[u8], chars: usize) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(chars);
    for byte in bytes {
        if output.len() >= chars {
            break;
        }
        output.push(HEX[(byte >> 4) as usize] as char);
        if output.len() >= chars {
            break;
        }
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

pub(crate) fn restart_codex(yes: bool, include_app_server: bool) -> Result<()> {
    let summary = restart_codex_processes(include_app_server, yes)?;
    if yes {
        println!(
            "Restarted Codex by terminating {} process(es). Relaunch Codex CLI normally.",
            summary.terminated.len()
        );
    } else {
        println!("Dry run only. Pass --yes to terminate Codex CLI process(es).");
    }
    for pid in summary.terminated {
        println!("Terminated pid={pid}");
    }
    for (pid, reason) in summary.skipped {
        println!("Skipped pid={pid}: {reason}");
    }
    if !include_app_server {
        println!("Tip: pass --include-app-server if the Codex app-server also needs a restart.");
    }
    Ok(())
}

pub(crate) fn fix_codex(yes: bool, version: &str) -> Result<()> {
    let health = codex_health::fix(yes, version)?;
    println!(
        "codex path: {}",
        health.path.as_deref().unwrap_or("not found")
    );
    if health.healthy {
        println!(
            "codex healthy: {}",
            health.version.as_deref().unwrap_or("version unavailable")
        );
    } else {
        println!(
            "codex unhealthy: {}",
            health.problem.as_deref().unwrap_or("unknown problem")
        );
        println!("Dry run only. Pass --yes to reinstall @openai/codex@{version}.");
    }
    Ok(())
}

pub(crate) fn install_patched_codex(
    source: PathBuf,
    yes: bool,
    replace_system_entry: bool,
    replace_npm_vendor: bool,
) -> Result<()> {
    let report = patched_codex::install(patched_codex::InstallPatchedCodexOptions {
        source,
        yes,
        replace_system_entry,
        replace_npm_vendor,
    })?;
    if report.dry_run {
        println!("Dry run only. Pass --yes to build and install patched Codex.");
    } else {
        println!(
            "installed patched Codex: {}",
            report.installed_binary.display()
        );
        println!("user launcher: {}", report.user_launcher.display());
        if report.system_launcher_replaced {
            println!("system launcher replaced: /usr/bin/codex");
        }
        if report.npm_vendor_replaced {
            println!("npm vendor binary replaced");
        }
    }
    println!("built binary: {}", report.built_binary.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use account_store::{
        CodexAccount, QuotaWindow, QuotaWindowRateLimitSource, QuotaWindowSlot,
        QuotaWindowSourceMetadata,
    };
    use std::ffi::CString;
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;
    use uuid::Uuid;

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
                fetched_at: Utc::now(),
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
            resets_at: Utc::now() + chrono::Duration::seconds(duration_seconds as i64),
            source: QuotaWindowSourceMetadata::new(
                QuotaWindowRateLimitSource::Main,
                QuotaWindowSlot::Primary,
            ),
            hard_limit_reached: false,
        }
    }

    fn fetch_from_account(account: &CodexAccount) -> Result<FetchResult> {
        let mut snapshot = account.quota_snapshot.clone().unwrap();
        snapshot.fetched_at = Utc::now();
        Ok(FetchResult {
            snapshot,
            plan_type: account.plan_type.clone().unwrap(),
        })
    }

    fn verified_reload_summary() -> ReloadSummary {
        ReloadSummary {
            sighup_sent: vec![42],
            signaled: vec![42],
            topology_verified: true,
            ..ReloadSummary::default()
        }
    }

    fn confirm_provider_io_activation(store_path: &Path, auth_path: &Path) -> Result<()> {
        let accounts = load_accounts(store_path)?;
        let active = active_account(&accounts)
            .context("provider-I/O test fixture requires one active account")?;
        auth::write_auth_file(auth_path, active)?;
        swap_with_reload(store_path, auth_path, &active.email, |_| {
            Ok(verified_reload_summary())
        })?;
        Ok(())
    }

    #[derive(Clone, Copy, Debug)]
    enum BlockedProviderIoActivation {
        State(ActivationState),
        Missing,
        Malformed,
        UnknownKind,
        StaleGeneration,
        IncompleteTransition,
    }

    fn blocked_provider_io_activations() -> Vec<(&'static str, BlockedProviderIoActivation)> {
        vec![
            (
                "prepared",
                BlockedProviderIoActivation::State(ActivationState::Prepared),
            ),
            (
                "file-only",
                BlockedProviderIoActivation::State(ActivationState::FileOnly),
            ),
            (
                "committed-degraded",
                BlockedProviderIoActivation::State(ActivationState::CommittedDegraded),
            ),
            (
                "rolled-back",
                BlockedProviderIoActivation::State(ActivationState::RolledBack),
            ),
            (
                "manual-review",
                BlockedProviderIoActivation::State(ActivationState::ManualReview),
            ),
            ("missing", BlockedProviderIoActivation::Missing),
            ("malformed", BlockedProviderIoActivation::Malformed),
            ("unknown-kind", BlockedProviderIoActivation::UnknownKind),
            (
                "stale-generation",
                BlockedProviderIoActivation::StaleGeneration,
            ),
            (
                "incomplete-transition",
                BlockedProviderIoActivation::IncompleteTransition,
            ),
        ]
    }

    fn overwrite_test_activation_record(
        store_path: &Path,
        record: &activation::ActivationRecord,
    ) -> Result<()> {
        let path = activation::activation_record_path(store_path);
        fs::write(&path, serde_json::to_vec_pretty(record)?)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        Ok(())
    }

    fn set_test_activation_state(store_path: &Path, state: ActivationState) -> Result<()> {
        let store_lock = lock_account_store(store_path)?;
        let mut record = activation::read_activation_record(&store_lock)?
            .context("test activation record disappeared")?;
        record.state = state;
        overwrite_test_activation_record(store_path, &record)
    }

    fn install_blocked_provider_io_activation(
        store_path: &Path,
        auth_path: &Path,
        active: &CodexAccount,
        fixture: BlockedProviderIoActivation,
    ) -> Result<()> {
        auth::write_auth_file(auth_path, active)?;
        if matches!(fixture, BlockedProviderIoActivation::Missing) {
            return Ok(());
        }

        confirm_provider_io_activation(store_path, auth_path)?;
        let record_path = activation::activation_record_path(store_path);
        if matches!(fixture, BlockedProviderIoActivation::Malformed) {
            fs::write(&record_path, b"{not-json")?;
            fs::set_permissions(record_path, fs::Permissions::from_mode(0o600))?;
            return Ok(());
        }

        let store_lock = lock_account_store(store_path)?;
        let mut record = activation::read_activation_record(&store_lock)?
            .context("blocked provider-I/O fixture lost its activation record")?;
        drop(store_lock);
        match fixture {
            BlockedProviderIoActivation::State(state) => record.state = state,
            BlockedProviderIoActivation::UnknownKind => {
                record.kind = activation::ActivationKind::Unknown;
            }
            BlockedProviderIoActivation::StaleGeneration => {
                record.store_generation = "stale-generation".to_string();
            }
            BlockedProviderIoActivation::IncompleteTransition => {
                record.base_store_generation = Some(record.store_generation.clone());
            }
            BlockedProviderIoActivation::Missing | BlockedProviderIoActivation::Malformed => {
                unreachable!("terminal provider-I/O fixture was handled before record mutation")
            }
        }
        overwrite_test_activation_record(store_path, &record)
    }

    fn assert_clean_provider_io_activation(
        store_path: &Path,
        auth_path: &Path,
        expected_generation: &str,
    ) -> Result<()> {
        let store_lock = lock_account_store(store_path)?;
        let current = store_lock.load()?;
        let record = activation::read_activation_record(&store_lock)?
            .context("activation preflight did not preserve confirmation")?;
        assert_eq!(current.generation.as_str(), expected_generation);
        assert_eq!(record.store_generation, expected_generation);
        assert_eq!(record.base_store_generation, None);
        assert_eq!(record.owned_store_generation, None);
        let current_active = active_account(&current.accounts)
            .context("provider callback lost the active account")?;
        let auth_fingerprint = auth::auth_file_fingerprint(auth_path);
        assert!(activation::activation_record_confirms_current(
            &record,
            current_active,
            &current.generation,
            auth_fingerprint.as_deref(),
        ));
        Ok(())
    }

    fn verified_receipt_reload_summary(receipt_nonce: Uuid) -> ReloadSummary {
        let request_nonce = format!("{receipt_nonce}:{}", Uuid::new_v4());
        ReloadSummary {
            sighup_sent: vec![42],
            signaled: vec![42],
            topology_verified: true,
            receipt_nonce: Some(receipt_nonce),
            generated_request_nonces: vec![request_nonce.clone()],
            acknowledged_request_nonces: vec![request_nonce],
            ..ReloadSummary::default()
        }
    }

    fn reset_bank(credit_ids: &[&str]) -> RateLimitResetBank {
        RateLimitResetBank {
            available_count: credit_ids.len() as u32,
            total_earned_count: credit_ids.len() as u32,
            credits: credit_ids
                .iter()
                .map(|credit_id| rate_limit_resets::RateLimitResetCredit {
                    id: (*credit_id).to_string(),
                    reset_type: Some("full".to_string()),
                    status: "available".to_string(),
                    granted_at: Some(Utc::now() - ChronoDuration::days(1)),
                    expires_at: Some(Utc::now() + ChronoDuration::days(10)),
                    redeem_started_at: None,
                    redeemed_at: None,
                    title: Some("Full reset".to_string()),
                    description: None,
                })
                .collect(),
            fetched_at: Utc::now(),
        }
    }

    #[test]
    fn poll_releases_store_lock_and_advances_matching_confirmation() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let confirmed_before = activation::read_activation_record(&store_lock)?.unwrap();
        drop(store_lock);

        let quota_store_path = store_path.clone();
        let bank_store_path = store_path.clone();
        poll_with(
            &store_path,
            &auth_path,
            None,
            move |account| {
                assert_store_lock_available(&quota_store_path)?;
                fetch_from_account(account)
            },
            move |_account| {
                assert_store_lock_available(&bank_store_path)?;
                Ok(reset_bank(&["credit-a"]))
            },
        )?;

        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let confirmed_after = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(confirmed_after.state, ActivationState::Confirmed);
        assert_eq!(
            confirmed_after.store_generation,
            snapshot.generation.as_str()
        );
        assert_eq!(confirmed_after.updated_at, confirmed_before.updated_at);
        Ok(())
    }

    #[test]
    fn poll_revalidates_generation_after_unlocked_provider_io() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let mutation_path = store_path.clone();
        let mut concurrent = active.clone();
        concurrent.plan_type = Some("concurrent-plan".to_string());
        let error = poll_with(
            &store_path,
            &auth_path,
            None,
            move |account| {
                assert_store_lock_available(&mutation_path)?;
                save_accounts(&mutation_path, std::slice::from_ref(&concurrent))?;
                fetch_from_account(account)
            },
            |_account| Ok(reset_bank(&[])),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("provider-I/O activation guard"));
        assert_eq!(
            load_accounts(&store_path)?[0].plan_type.as_deref(),
            Some("concurrent-plan")
        );
        Ok(())
    }

    #[test]
    fn poll_refuses_followup_io_and_commit_after_journal_only_transition() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_before = fs::read(&store_path)?;

        let transition_path = store_path.clone();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let error = poll_with(
            &store_path,
            &auth_path,
            None,
            {
                let quota_calls = Arc::clone(&quota_calls);
                move |account| {
                    *quota_calls.lock().unwrap() += 1;
                    set_test_activation_state(&transition_path, ActivationState::Prepared)?;
                    fetch_from_account(account)
                }
            },
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    *bank_calls.lock().unwrap() += 1;
                    Ok(reset_bank(&[]))
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("changed activation journal"));
        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 0);
        assert_eq!(fs::read(&store_path)?, store_before);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::Prepared
        );
        Ok(())
    }

    #[test]
    fn poll_blocks_all_provider_callbacks_until_activation_is_current() -> Result<()> {
        for (label, fixture) in blocked_provider_io_activations() {
            let temp = secure_temp_dir()?;
            let store_path = temp.path().join("accounts.json");
            let auth_path = temp.path().join("auth.json");
            let active = account("active@example.com", true, 10.0, 10.0);
            save_accounts(&store_path, std::slice::from_ref(&active))?;
            install_blocked_provider_io_activation(&store_path, &auth_path, &active, fixture)?;

            let quota_calls = Arc::new(Mutex::new(0usize));
            let bank_calls = Arc::new(Mutex::new(0usize));
            let error = poll_with(
                &store_path,
                &auth_path,
                None,
                {
                    let quota_calls = Arc::clone(&quota_calls);
                    move |account| {
                        *quota_calls.lock().unwrap() += 1;
                        fetch_from_account(account)
                    }
                },
                {
                    let bank_calls = Arc::clone(&bank_calls);
                    move |_account| {
                        *bank_calls.lock().unwrap() += 1;
                        Ok(reset_bank(&[]))
                    }
                },
            )
            .unwrap_err();

            assert!(
                format!("{error:#}").contains("poll activation preflight failed"),
                "unexpected {label} failure: {error:#}"
            );
            assert_eq!(*quota_calls.lock().unwrap(), 0, "{label} quota callback");
            assert_eq!(*bank_calls.lock().unwrap(), 0, "{label} bank callback");
        }
        Ok(())
    }

    #[test]
    fn poll_finalizes_staged_confirmed_generation_before_provider_callback() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut accounts = snapshot.accounts;
        accounts[0].plan_type = Some("staged-observation".to_string());
        let prospective_generation = store_lock.prospective_generation(&accounts)?;
        let mut record = activation::read_activation_record(&store_lock)?
            .context("staged provider-I/O fixture lost its activation record")?;
        let evidence_time = record.updated_at.to_owned();
        record.base_store_generation = Some(snapshot.generation.as_str().to_string());
        record.owned_store_generation = Some(prospective_generation.as_str().to_string());
        overwrite_test_activation_record(&store_path, &record)?;
        let mut committed_generation = snapshot.generation;
        commit_accounts(&store_lock, &mut committed_generation, &accounts)?;
        assert_eq!(committed_generation, prospective_generation);
        drop(store_lock);

        let callback_store_path = store_path.clone();
        let callback_auth_path = auth_path.clone();
        let callback_generation = prospective_generation.as_str().to_string();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        poll_with(
            &store_path,
            &auth_path,
            None,
            {
                let quota_calls = Arc::clone(&quota_calls);
                move |account| {
                    assert_store_lock_available(&callback_store_path)?;
                    assert_clean_provider_io_activation(
                        &callback_store_path,
                        &callback_auth_path,
                        &callback_generation,
                    )?;
                    *quota_calls.lock().unwrap() += 1;
                    fetch_from_account(account)
                }
            },
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    *bank_calls.lock().unwrap() += 1;
                    Ok(reset_bank(&[]))
                }
            },
        )?;

        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 1);
        let store_lock = lock_account_store(&store_path)?;
        let finalized = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(finalized.state, ActivationState::Confirmed);
        assert_eq!(finalized.updated_at, evidence_time);
        assert_eq!(finalized.base_store_generation, None);
        assert_eq!(finalized.owned_store_generation, None);
        Ok(())
    }

    fn secure_temp_dir() -> Result<TempDir> {
        let temp = TempDir::new()?;
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700))?;
        Ok(temp)
    }

    fn assert_store_lock_available(store_path: &Path) -> Result<()> {
        let lock_path = store_path.with_extension("json.lock");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(&lock_path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            bail!(
                "account-store lock was held during callback: {}",
                std::io::Error::last_os_error()
            );
        }
        let unlock_result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        if unlock_result != 0 {
            bail!(
                "failed to release callback probe lock: {}",
                std::io::Error::last_os_error()
            );
        }
        Ok(())
    }

    fn create_fifo(path: &Path) -> Result<()> {
        let path = CString::new(path.as_os_str().as_bytes())?;
        let status = unsafe { libc::mkfifo(path.as_ptr(), 0o600) };
        if status == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error()).context("failed to create test FIFO")
        }
    }

    #[test]
    fn status_fields_do_not_print_absent_five_hour_window() {
        let mut weekly_only = account("weekly@example.com", true, 10.0, 37.0);
        weekly_only
            .quota_snapshot
            .as_mut()
            .unwrap()
            .windows
            .retain(|window| window.kind == QuotaWindowKind::Weekly);

        let now = weekly_only.quota_snapshot.as_ref().unwrap().fetched_at;
        let fields = quota_status_fields(weekly_only.quota_snapshot.as_ref(), now);
        assert_eq!(fields, "weekly=63%");
        assert!(!fields.contains("5h="));

        assert_eq!(quota_status_fields(None, now), "quota=?");
    }

    #[test]
    fn status_fields_label_stale_quota_instead_of_cached_full_capacity() {
        let account = account("stale@example.com", false, 0.0, 0.0);
        let snapshot = account.quota_snapshot.as_ref().unwrap();
        let stale_at = snapshot.fetched_at
            + crate::account_store::QUOTA_OBSERVATION_MAX_AGE
            + chrono::Duration::milliseconds(1);

        assert_eq!(quota_status_fields(Some(snapshot), stale_at), "quota=stale");
    }

    #[test]
    fn reload_convergence_rejects_unacknowledged_runtime() {
        assert!(ensure_reload_converged(&[]).is_ok());

        let error = ensure_reload_converged(&[(
            42,
            "SIGHUP sent but live reload acknowledgement was not observed".to_string(),
        )])
        .expect_err("an unacknowledged runtime must fail the command");
        assert!(error.to_string().contains("restart is required"));
    }

    #[test]
    fn cli_version_uses_build_provenance() {
        let error = Args::try_parse_from(["codexswitch-cli", "--version"]).unwrap_err();

        assert_eq!(error.kind(), clap::error::ErrorKind::DisplayVersion);
        assert!(error
            .to_string()
            .contains(env!("CODEXSWITCH_BUILD_VERSION")));
    }

    #[test]
    fn auth_diagnostics_complete_fingerprint_detects_non_access_token_drift() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        auth::write_auth_file(&auth_path, &active)?;

        let matching = collect_auth_diagnostics(&store_path, &auth_path)?;
        assert!(matching.auth_matches_active_store_token);
        assert_eq!(
            matching.active_token_hash_prefix,
            auth::account_token_fingerprint(&active)
                .as_deref()
                .map(fingerprint_hash_prefix)
        );

        let mut id_drift = active.clone();
        id_drift.id_token = "different-id".to_string();
        let mut refresh_drift = active.clone();
        refresh_drift.refresh_token = "different-refresh".to_string();
        let mut account_drift = active.clone();
        account_drift.account_id = "different-account".to_string();
        for drifted in [id_drift, refresh_drift, account_drift] {
            assert_eq!(drifted.access_token, active.access_token);
            auth::write_auth_file(&auth_path, &drifted)?;
            assert!(
                !collect_auth_diagnostics(&store_path, &auth_path)?.auth_matches_active_store_token
            );
        }
        Ok(())
    }

    #[test]
    fn auth_diagnostics_rejects_symlink_fifo_and_oversized_auth_without_locking() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;

        let outside = temp.path().join("outside.json");
        fs::write(&outside, b"outside")?;
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o600))?;
        symlink(&outside, &auth_path)?;
        assert!(collect_auth_diagnostics(&store_path, &auth_path).is_err());
        assert_eq!(fs::read(&outside)?, b"outside");
        assert!(!auth_path.with_extension("json.lock").exists());
        fs::remove_file(&auth_path)?;

        create_fifo(&auth_path)?;
        assert!(collect_auth_diagnostics(&store_path, &auth_path).is_err());
        assert!(!auth_path.with_extension("json.lock").exists());
        fs::remove_file(&auth_path)?;

        let oversized = fs::File::create(&auth_path)?;
        oversized.set_len((AUTH_DIAGNOSTIC_MAX_BYTES + 1) as u64)?;
        fs::set_permissions(&auth_path, fs::Permissions::from_mode(0o600))?;
        let error = collect_auth_diagnostics(&store_path, &auth_path).unwrap_err();
        assert!(format!("{error:#}").contains("byte limit"));
        assert!(!auth_path.with_extension("json.lock").exists());
        Ok(())
    }

    #[test]
    fn swap_production_path_passes_custom_auth_path_to_reload() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("custom/auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        let candidate = account("candidate@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active.clone(), candidate.clone()])?;
        auth::write_auth_file(&auth_path, &active)?;
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_for_reload = Arc::clone(&observed);
        let reload_store_path = store_path.clone();

        let (email, _) = swap_with_reload(
            &store_path,
            &auth_path,
            &candidate.email,
            move |observed_path| {
                assert_store_lock_available(&reload_store_path)?;
                observed_for_reload
                    .lock()
                    .unwrap()
                    .push(observed_path.to_path_buf());
                Ok(verified_reload_summary())
            },
        )?;

        assert_eq!(email, candidate.email);
        assert_eq!(*observed.lock().unwrap(), vec![auth_path.clone()]);
        assert!(auth::auth_file_matches_account(&auth_path, &candidate));
        Ok(())
    }

    #[test]
    fn import_production_path_runs_runtime_reload_without_store_lock() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        let replacement = account("replacement@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        auth::write_auth_file(&auth_path, &active)?;
        let reload_store_path = store_path.clone();

        let (count, outcome) = replace_import_accounts_with_unlocked_reload(
            &store_path,
            &auth_path,
            vec![replacement.clone()],
            false,
            true,
            &move |_| {
                assert_store_lock_available(&reload_store_path)?;
                Ok(verified_reload_summary())
            },
        )?;

        assert_eq!(count, 1);
        assert!(outcome.is_confirmed());
        assert_eq!(
            active_account(&load_accounts(&store_path)?).map(|account| account.account_id.clone()),
            Some(replacement.account_id.clone())
        );
        assert!(auth::auth_file_matches_account(&auth_path, &replacement));
        Ok(())
    }

    #[test]
    fn rotation_production_path_passes_custom_auth_path_to_reload() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("custom/auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let candidate = account("candidate@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active.clone(), candidate.clone()])?;
        auth::write_auth_file(&auth_path, &active)?;
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_for_reload = Arc::clone(&observed);
        let receipt_nonce = Uuid::parse_str("37f84870-9b39-45ae-aee9-3e0a63e1f989").unwrap();

        let report = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 18_000,
                reload_processes: true,
                allow_banked_reset: false,
                receipt_nonce: Some(receipt_nonce),
            },
            RotateNowDependencies::new(
                fetch_from_account,
                |_account| bail!("reset inventory should not be fetched"),
                |_account, _bank, _request_id| bail!("reset should not be consumed"),
                move |observed_path| {
                    observed_for_reload
                        .lock()
                        .unwrap()
                        .push(observed_path.to_path_buf());
                    Ok(verified_receipt_reload_summary(receipt_nonce))
                },
            ),
        )?;

        assert_eq!(report.next_email, candidate.email);
        assert_eq!(report.receipt_nonce, Some(receipt_nonce));
        assert_eq!(report.auth_path, auth_path.display().to_string());
        assert!(report.topology_verified);
        assert_eq!(report.request_count, 1);
        assert_eq!(report.sighup_sent_processes, 1);
        assert_eq!(report.signaled_processes, 1);
        assert_eq!(report.acknowledged_request_nonces.len(), 1);
        assert!(report.acknowledged_request_nonces[0].starts_with(&format!("{receipt_nonce}:")));
        assert_eq!(*observed.lock().unwrap(), vec![auth_path.clone()]);
        assert!(auth::auth_file_matches_account(&auth_path, &candidate));
        Ok(())
    }

    #[test]
    fn receipt_rotation_rejects_file_only_mode_before_mutation() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let candidate = account("candidate@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active.clone(), candidate])?;
        auth::write_auth_file(&auth_path, &active)?;
        let store_before = fs::read(&store_path)?;
        let auth_before = fs::read(&auth_path)?;

        let error = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 18_000,
                reload_processes: false,
                allow_banked_reset: false,
                receipt_nonce: Some(Uuid::new_v4()),
            },
            RotateNowDependencies::new(
                |_account| bail!("quota must not be fetched"),
                |_account| bail!("reset inventory must not be fetched"),
                |_account, _bank, _request_id| bail!("reset must not be consumed"),
                |_path| bail!("reload must not run"),
            ),
        )
        .expect_err("receipt-bound file-only rotation must fail closed");

        assert!(error.to_string().contains("requires live runtime reload"));
        assert_eq!(fs::read(&store_path)?, store_before);
        assert_eq!(fs::read(&auth_path)?, auth_before);
        Ok(())
    }

    #[test]
    fn daemon_has_no_automatic_reset_option_and_manual_rotation_is_explicit() -> Result<()> {
        let default = Args::try_parse_from(["codexswitch-cli", "daemon"])?;
        assert!(matches!(default.command, Command::Daemon { .. }));

        assert!(
            Args::try_parse_from(["codexswitch-cli", "daemon", "--consume-banked-resets"]).is_err()
        );

        let default =
            Args::try_parse_from(["codexswitch-cli", "rotate-now", "--reason", "usage_limit"])?;
        assert!(matches!(
            default.command,
            Command::RotateNow {
                allow_banked_reset: false,
                ..
            }
        ));

        let opt_in = Args::try_parse_from([
            "codexswitch-cli",
            "rotate-now",
            "--reason",
            "usage_limit",
            "--allow-banked-reset",
        ])?;
        assert!(matches!(
            opt_in.command,
            Command::RotateNow {
                allow_banked_reset: true,
                ..
            }
        ));

        let targeted = Args::try_parse_from([
            "codexswitch-cli",
            "redeem-reset",
            "pro@example.com",
            "--json",
        ])?;
        assert!(matches!(
            targeted.command,
            Command::RedeemReset {
                account,
                json: true,
            } if account == "pro@example.com"
        ));
        Ok(())
    }

    #[test]
    fn rotate_now_accepts_only_canonical_receipt_uuid() -> Result<()> {
        let canonical = "37f84870-9b39-45ae-aee9-3e0a63e1f989";
        let parsed = Args::try_parse_from([
            "codexswitch-cli",
            "rotate-now",
            "--receipt-nonce",
            canonical,
        ])?;
        assert!(matches!(
            parsed.command,
            Command::RotateNow {
                receipt_nonce: Some(receipt_nonce),
                ..
            } if receipt_nonce.hyphenated().to_string() == canonical
        ));

        for invalid in [
            "37F84870-9B39-45AE-AEE9-3E0A63E1F989",
            "37f848709b3945aeaee93e0a63e1f989",
            "{37f84870-9b39-45ae-aee9-3e0a63e1f989}",
            "not-a-uuid",
        ] {
            assert!(Args::try_parse_from([
                "codexswitch-cli",
                "rotate-now",
                "--receipt-nonce",
                invalid,
            ])
            .is_err());
        }
        assert!(Args::try_parse_from([
            "codexswitch-cli",
            "rotate-now",
            "--receipt-nonce",
            canonical,
            "--offline-file-only",
        ])
        .is_err());
        Ok(())
    }

    #[test]
    fn activation_resolution_requires_explicit_operator_confirmation() -> Result<()> {
        let confirmed =
            Args::try_parse_from(["codexswitch-cli", "resolve-activation", "--yes", "--json"])?;
        assert!(matches!(
            confirmed.command,
            Command::ResolveActivation {
                yes: true,
                json: true
            }
        ));

        let unconfirmed = Args::try_parse_from(["codexswitch-cli", "resolve-activation"])?;
        assert!(matches!(
            unconfirmed.command,
            Command::ResolveActivation {
                yes: false,
                json: false
            }
        ));
        Ok(())
    }

    #[test]
    fn import_file_only_handoff_requires_explicit_flag() -> Result<()> {
        let live = Args::try_parse_from(["codexswitch-cli", "import", "bundle.json"])?;
        assert!(matches!(
            live.command,
            Command::Import {
                offline_file_only: false,
                ..
            }
        ));

        let offline = Args::try_parse_from([
            "codexswitch-cli",
            "update-bundle",
            "bundle.json",
            "--offline-file-only",
        ])?;
        assert!(matches!(
            offline.command,
            Command::UpdateBundle {
                offline_file_only: true,
                ..
            }
        ));

        let host_preserving = Args::try_parse_from([
            "codexswitch-cli",
            "update-bundle",
            "--preserve-active",
            "bundle.json",
        ])?;
        assert!(matches!(
            host_preserving.command,
            Command::UpdateBundle {
                preserve_active: true,
                ..
            }
        ));
        Ok(())
    }

    #[test]
    fn credential_bundle_merge_preserves_host_active_provider_identity() -> Result<()> {
        let current_active = account("vps-active@example.com", true, 10.0, 10.0);
        let current_inactive = account("mac-active@example.com", false, 10.0, 10.0);
        let mut incoming_vps = current_active.clone();
        incoming_vps.is_active = false;
        incoming_vps.refresh_token = "refreshed-on-mac".to_string();
        let mut incoming_mac = current_inactive.clone();
        incoming_mac.is_active = true;

        let merged = preserve_host_active_account(
            vec![incoming_mac, incoming_vps],
            &[current_active.clone(), current_inactive],
        )?;

        let active = active_account(&merged).context("merged host lost its active account")?;
        assert_eq!(active.account_id, current_active.account_id);
        assert_eq!(active.refresh_token, "refreshed-on-mac");
        Ok(())
    }

    #[test]
    fn credential_bundle_merge_retains_remote_only_active_account() -> Result<()> {
        let current_active = account("vps-only@example.com", true, 10.0, 10.0);
        let incoming_active = account("mac-only@example.com", true, 10.0, 10.0);

        let merged = preserve_host_active_account(
            vec![incoming_active],
            std::slice::from_ref(&current_active),
        )?;

        assert_eq!(merged.len(), 2);
        assert_eq!(
            active_account(&merged).map(|account| account.account_id.as_str()),
            Some(current_active.account_id.as_str())
        );
        Ok(())
    }

    #[test]
    fn typed_usage_limit_rotates_even_when_quota_poll_looks_usable() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut active = account("active@example.com", true, 100.0, 10.0);
        active.runtime_unusable_reason = Some("usage_limit".to_string());
        active.runtime_unusable_until = Some(Utc::now() + ChronoDuration::hours(6));
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, replacement])?;

        let report = rotate_now_with(
            &store_path,
            &auth_path,
            "usage_limit",
            21_600,
            true,
            |account| {
                let mut result = fetch_from_account(account)?;
                if account.email == "active@example.com" {
                    result.snapshot.five_hour_mut().unwrap().used_percent = 1.0;
                    result.snapshot.weekly_mut().unwrap().used_percent = 20.0;
                    result.snapshot.allowed = Some(true);
                    result.snapshot.limit_reached = Some(false);
                }
                Ok(result)
            },
            |_| Ok(verified_reload_summary()),
        )?;

        assert_eq!(report.previous_email, "active@example.com");
        assert_eq!(report.next_email, "replacement@example.com");
        let stored = load_accounts(&store_path)?;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.email, "replacement@example.com");
        let rejected = stored
            .iter()
            .find(|account| account.email == "active@example.com")
            .unwrap();
        assert_eq!(
            rejected.runtime_unusable_reason.as_deref(),
            Some("usage_limit")
        );
        Ok(())
    }

    #[test]
    fn usage_limit_rotate_blocks_only_until_exhausted_five_hour_reset() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 32.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        let five_hour_reset = Utc::now() + ChronoDuration::minutes(45);
        save_accounts(&store_path, &[active, replacement])?;

        let report = rotate_now_with(
            &store_path,
            &auth_path,
            "usage_limit",
            21_600,
            true,
            |account| {
                let mut result = fetch_from_account(account)?;
                if account.email == "active@example.com" {
                    let five_hour = result.snapshot.five_hour_mut().unwrap();
                    five_hour.used_percent = 100.0;
                    five_hour.hard_limit_reached = true;
                    five_hour.resets_at = five_hour_reset;
                    let weekly = result.snapshot.weekly_mut().unwrap();
                    weekly.used_percent = 32.0;
                    weekly.hard_limit_reached = false;
                }
                Ok(result)
            },
            |_| Ok(verified_reload_summary()),
        )?;

        assert_eq!(report.previous_email, "active@example.com");
        assert_eq!(report.next_email, "replacement@example.com");
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("replacement@example.com")
        );
        let previous = stored
            .iter()
            .find(|account| account.email == "active@example.com")
            .unwrap();
        assert_eq!(
            previous.runtime_unusable_reason.as_deref(),
            Some("usage_limit")
        );
        let runtime_until = previous.runtime_unusable_until.unwrap();
        assert!((runtime_until - five_hour_reset).num_seconds().abs() <= 1);
        assert!(
            previous
                .quota_snapshot
                .as_ref()
                .unwrap()
                .five_hour()
                .unwrap()
                .hard_limit_reached
        );
        assert_eq!(
            previous
                .quota_snapshot
                .as_ref()
                .unwrap()
                .weekly()
                .unwrap()
                .used_percent,
            32.0
        );
        Ok(())
    }

    #[test]
    fn usage_limit_rotate_refreshes_candidates_before_selecting() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 10.0);
        let stale_replacement = account("replacement@example.com", false, 100.0, 10.0);
        save_accounts(&store_path, &[active, stale_replacement])?;

        let report = rotate_now_with(
            &store_path,
            &auth_path,
            "usage_limit",
            21_600,
            true,
            |account| {
                let mut result = fetch_from_account(account)?;
                if account.email == "replacement@example.com" {
                    result.snapshot.five_hour_mut().unwrap().used_percent = 1.0;
                }
                Ok(result)
            },
            |_| Ok(verified_reload_summary()),
        )?;

        assert_eq!(report.previous_email, "active@example.com");
        assert_eq!(report.next_email, "replacement@example.com");
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("replacement@example.com")
        );
        Ok(())
    }

    #[test]
    fn rotate_now_defaults_to_rotation_without_consuming_banked_reset() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 20.0, 100.0);
        let mut replacement = account("replacement@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        save_accounts(&store_path, &[active, replacement])?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let report = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: false,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                fetch_from_account,
                |_account| {
                    Ok(RateLimitResetBank {
                        available_count: 1,
                        total_earned_count: 1,
                        credits: Vec::new(),
                        fetched_at: Utc::now(),
                    })
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(!report.used_banked_reset);
        assert_eq!(report.next_email, "replacement@example.com");
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("replacement@example.com")
        );
        Ok(())
    }

    #[test]
    fn rotate_now_reconciles_activation_barrier_before_reset_policy() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let first = account("first@example.com", true, 10.0, 10.0);
        let second = account("second@example.com", false, 100.0, 100.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[first.clone(), second, replacement])?;
        auth::write_auth_file(&auth_path, &first)?;

        {
            let store_lock = lock_account_store(&store_path)?;
            let snapshot = store_lock.load()?;
            let mut generation = snapshot.generation;
            let mut accounts = snapshot.accounts;
            let second_id = accounts[1].id;
            let degraded = activate_with(
                ActivationContext {
                    store_lock: &store_lock,
                    generation: &mut generation,
                    accounts: &mut accounts,
                    auth_path: &auth_path,
                    target_id: second_id,
                    reload_enabled: true,
                },
                |_| Ok(ReloadSummary::default()),
            )?;
            assert_eq!(degraded.state, ActivationState::CommittedDegraded);
        }

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let error = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                fetch_from_account,
                |_account| {
                    Ok(RateLimitResetBank {
                        available_count: 1,
                        total_earned_count: 1,
                        credits: Vec::new(),
                        fetched_at: Utc::now(),
                    })
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(ReloadSummary::default()),
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("activation did not publish as swapped"));
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(
            active_account(&load_accounts(&store_path)?)
                .map(|account| account.email.as_str().to_string()),
            Some("second@example.com".to_string())
        );
        Ok(())
    }

    #[test]
    fn rotate_now_offline_rejects_prior_file_only_barrier_before_policy() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        let prior_target = account("prior@example.com", false, 100.0, 100.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(
            &store_path,
            &[active.clone(), prior_target.clone(), replacement],
        )?;
        auth::write_auth_file(&auth_path, &active)?;

        {
            let store_lock = lock_account_store(&store_path)?;
            let snapshot = store_lock.load()?;
            let mut generation = snapshot.generation;
            let mut accounts = snapshot.accounts;
            let outcome = activate_with(
                ActivationContext {
                    store_lock: &store_lock,
                    generation: &mut generation,
                    accounts: &mut accounts,
                    auth_path: &auth_path,
                    target_id: prior_target.id,
                    reload_enabled: false,
                },
                |_| bail!("offline activation must not reload"),
            )?;
            assert_eq!(outcome.state, ActivationState::FileOnly);
        }

        let fetch_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let reload_calls = Arc::new(Mutex::new(0usize));
        let error = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: false,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                {
                    let calls = Arc::clone(&fetch_calls);
                    move |account| {
                        *calls.lock().unwrap() += 1;
                        fetch_from_account(account)
                    }
                },
                {
                    let calls = Arc::clone(&bank_calls);
                    move |_account| {
                        *calls.lock().unwrap() += 1;
                        bail!("reset-bank policy must remain blocked")
                    }
                },
                {
                    let calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *calls.lock().unwrap() += 1;
                        bail!("reset consumption must remain blocked")
                    }
                },
                {
                    let calls = Arc::clone(&reload_calls);
                    move |_| {
                        *calls.lock().unwrap() += 1;
                        Ok(verified_reload_summary())
                    }
                },
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("activation did not publish as swapped"));
        assert_eq!(*fetch_calls.lock().unwrap(), 0);
        assert_eq!(*bank_calls.lock().unwrap(), 0);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(*reload_calls.lock().unwrap(), 0);
        assert_eq!(
            active_account(&load_accounts(&store_path)?)
                .map(|account| account.email.as_str().to_string()),
            Some("prior@example.com".to_string())
        );
        Ok(())
    }

    #[test]
    fn rotate_now_refuses_reset_rotation_and_commit_after_journal_only_transition() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, replacement])?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_before = fs::read(&store_path)?;

        let transition_path = store_path.clone();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let reload_calls = Arc::new(Mutex::new(0usize));
        let error = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                {
                    let quota_calls = Arc::clone(&quota_calls);
                    move |account| {
                        *quota_calls.lock().unwrap() += 1;
                        set_test_activation_state(&transition_path, ActivationState::Prepared)?;
                        fetch_from_account(account)
                    }
                },
                {
                    let bank_calls = Arc::clone(&bank_calls);
                    move |_account| {
                        *bank_calls.lock().unwrap() += 1;
                        Ok(reset_bank(&["credit-a"]))
                    }
                },
                {
                    let consume_calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *consume_calls.lock().unwrap() += 1;
                        bail!("journal-only transition must prevent rotate-now reset POST")
                    }
                },
                {
                    let reload_calls = Arc::clone(&reload_calls);
                    move |_| {
                        *reload_calls.lock().unwrap() += 1;
                        Ok(verified_reload_summary())
                    }
                },
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("changed activation journal"));
        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 0);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(*reload_calls.lock().unwrap(), 0);
        assert_eq!(fs::read(&store_path)?, store_before);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::Prepared
        );
        Ok(())
    }

    #[test]
    fn rotate_now_repairs_legacy_barrier_then_selects_fresh_target() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let mut replacement = account("replacement@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        let fresh_target = account("fresh@example.com", false, 5.0, 5.0);
        save_accounts(&store_path, &[active.clone(), replacement.clone()])?;
        auth::write_auth_file(&auth_path, &active)?;
        let store_lock = lock_account_store(&store_path)?;
        let generation = store_lock.load()?.generation;
        let record = activation::ActivationRecord {
            version: 3,
            state: ActivationState::ManualReview,
            kind: activation::ActivationKind::Rotation,
            previous_account_id: replacement.account_id.clone(),
            target_account_id: active.account_id.clone(),
            store_generation: generation.as_str().to_string(),
            auth_fingerprint: Some("superseded-token-generation".to_string()),
            base_store_generation: None,
            owned_store_generation: None,
            base_auth_generation: None,
            owned_auth_generation: None,
            rollback: None,
            detail: Some(activation::LEGACY_DEGRADED_TOKEN_MISMATCH.to_string()),
            updated_at: Utc::now(),
        };
        fs::write(
            activation::activation_record_path(&store_path),
            serde_json::to_vec_pretty(&record)?,
        )?;
        drop(store_lock);

        let observed_fingerprints = Arc::new(Mutex::new(Vec::new()));
        let observed_for_reload = Arc::clone(&observed_fingerprints);
        let barrier_loads = Arc::new(Mutex::new(0usize));
        let barrier_loads_for_loader = Arc::clone(&barrier_loads);
        let fresh_for_loader = fresh_target.clone();
        let auth_for_loader = auth_path.clone();
        let report = rotate_now_with_resets_and_barrier_loader(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: false,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                fetch_from_account,
                |_account| {
                    Ok(RateLimitResetBank {
                        available_count: 1,
                        total_earned_count: 1,
                        credits: Vec::new(),
                        fetched_at: Utc::now(),
                    })
                },
                |_account, _bank, _request_id| bail!("reset consumption must remain disabled"),
                move |path| {
                    observed_for_reload
                        .lock()
                        .unwrap()
                        .push(auth::auth_file_fingerprint(path).unwrap());
                    Ok(verified_reload_summary())
                },
            ),
            move |store_lock| {
                *barrier_loads_for_loader.lock().unwrap() += 1;
                let snapshot = store_lock.load()?;
                let mut fresh_accounts = snapshot.accounts;
                fresh_accounts.push(fresh_for_loader.clone());
                let mut fresh_generation = snapshot.generation;
                activation::commit_accounts_with_confirmed_generation_continuity(
                    store_lock,
                    &mut fresh_generation,
                    &fresh_accounts,
                    &auth_for_loader,
                )?;
                store_lock.load()
            },
        )?;

        assert_eq!(report.next_email, fresh_target.email);
        assert!(report.runtime_converged);
        assert_eq!(observed_fingerprints.lock().unwrap().len(), 2);
        assert_eq!(*barrier_loads.lock().unwrap(), 1);
        assert_eq!(
            active_account(&load_accounts(&store_path)?)
                .map(|account| account.email.as_str().to_string()),
            Some("fresh@example.com".to_string())
        );
        Ok(())
    }

    #[test]
    fn rotate_now_no_candidate_advances_matching_confirmed_generation() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        auth::write_auth_file(&auth_path, &active)?;
        swap_with_reload(&store_path, &auth_path, &active.email, |_| {
            Ok(verified_reload_summary())
        })?;
        let store_lock = lock_account_store(&store_path)?;
        let confirmed_before = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(confirmed_before.state, ActivationState::Confirmed);
        drop(store_lock);

        let error = rotate_now_with(
            &store_path,
            &auth_path,
            "auth_failure",
            300,
            true,
            |_| bail!("no inactive account should be polled"),
            |_| bail!("no runtime reload should occur without a candidate"),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("no freshly confirmed usable replacement"));
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let confirmed_after = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(confirmed_after.state, ActivationState::Confirmed);
        assert_eq!(
            confirmed_after.store_generation,
            snapshot.generation.as_str()
        );
        assert_eq!(confirmed_after.updated_at, confirmed_before.updated_at);
        assert_eq!(
            active_account(&snapshot.accounts)
                .and_then(|account| account.runtime_unusable_reason.as_deref()),
            Some("auth_failure")
        );
        Ok(())
    }

    #[test]
    fn rotate_now_no_candidate_fails_closed_without_matching_confirmation() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 10.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&active))?;
        auth::write_auth_file(&auth_path, &active)?;
        let generation_before = load_account_store_snapshot(&store_path)?.generation;

        let error = rotate_now_with(
            &store_path,
            &auth_path,
            "auth_failure",
            300,
            true,
            |_| bail!("no inactive account should be polled"),
            |_| bail!("no runtime reload should occur without a candidate"),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("current Confirmed activation record"));
        let snapshot = load_account_store_snapshot(&store_path)?;
        assert_eq!(snapshot.generation, generation_before);
        assert_eq!(
            active_account(&snapshot.accounts)
                .and_then(|account| account.runtime_unusable_reason.as_deref()),
            None
        );
        Ok(())
    }

    #[test]
    fn rotate_now_offline_file_only_is_explicit_and_never_runtime_confirmed() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 100.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, replacement])?;

        let report = rotate_now_with(
            &store_path,
            &auth_path,
            "usage_limit",
            21_600,
            false,
            fetch_from_account,
            |_| Ok(ReloadSummary::default()),
        )?;

        assert_eq!(report.activation_state, ActivationState::FileOnly);
        assert!(!report.runtime_converged);
        assert!(!report.reload_attempted);
        let stored = load_accounts(&store_path)?;
        let selected = active_account(&stored).unwrap();
        assert_eq!(selected.email, "replacement@example.com");
        assert!(auth::auth_file_matches_account(&auth_path, selected));
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            activation::ActivationState::FileOnly
        );
        Ok(())
    }

    #[test]
    fn rotate_now_banked_reset_opt_in_consumes_and_keeps_active() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 20.0, 100.0);
        let mut replacement = account("replacement@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        save_accounts(&store_path, &[active, replacement])?;

        let active_fetches = Arc::new(Mutex::new(0usize));
        let active_fetches_for_closure = Arc::clone(&active_fetches);
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches_for_closure = Arc::clone(&bank_fetches);
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let quota_store_path = store_path.clone();
        let bank_store_path = store_path.clone();
        let consume_store_path = store_path.clone();
        let reload_store_path = store_path.clone();
        let report = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                move |account| {
                    assert_store_lock_available(&quota_store_path)?;
                    let mut result = fetch_from_account(account)?;
                    if account.email == "active@example.com" {
                        let mut calls = active_fetches_for_closure.lock().unwrap();
                        *calls += 1;
                        if *calls > 1 {
                            let five_hour = result.snapshot.five_hour_mut().unwrap();
                            five_hour.used_percent = 0.0;
                            five_hour.hard_limit_reached = false;
                            let weekly = result.snapshot.weekly_mut().unwrap();
                            weekly.used_percent = 0.0;
                            weekly.hard_limit_reached = false;
                            result.snapshot.allowed = Some(true);
                            result.snapshot.limit_reached = Some(false);
                        }
                    }
                    Ok(result)
                },
                move |_account| {
                    assert_store_lock_available(&bank_store_path)?;
                    let mut calls = bank_fetches_for_closure.lock().unwrap();
                    *calls += 1;
                    let available_count = u32::from(*calls == 1);
                    Ok(RateLimitResetBank {
                        available_count,
                        total_earned_count: 1,
                        credits: (0..available_count)
                            .map(|index| rate_limit_resets::RateLimitResetCredit {
                                id: format!("credit-{index}"),
                                reset_type: Some("full".to_string()),
                                status: "available".to_string(),
                                granted_at: Some(Utc::now() - chrono::Duration::days(1)),
                                expires_at: Some(Utc::now() + chrono::Duration::days(10)),
                                redeem_started_at: None,
                                redeemed_at: None,
                                title: Some("Full reset".to_string()),
                                description: None,
                            })
                            .collect(),
                        fetched_at: Utc::now(),
                    })
                },
                move |_account, _bank, _request_id| {
                    assert_store_lock_available(&consume_store_path)?;
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                move |_| {
                    assert_store_lock_available(&reload_store_path)?;
                    Ok(verified_reload_summary())
                },
            ),
        )?;

        assert!(report.used_banked_reset);
        assert_eq!(report.previous_email, "active@example.com");
        assert_eq!(report.next_email, "active@example.com");
        assert_eq!(report.banked_resets_remaining, Some(0));
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        assert_eq!(*bank_fetches.lock().unwrap(), 2);
        assert_eq!(*active_fetches.lock().unwrap(), 2);
        let stored = load_accounts(&store_path)?;
        let active = active_account(&stored).unwrap();
        assert_eq!(active.email, "active@example.com");
        assert_eq!(active.runtime_unusable_reason, None);
        assert_eq!(
            active
                .rate_limit_reset_bank
                .as_ref()
                .map(|bank| bank.available_count),
            Some(0)
        );
        assert_eq!(
            quota_availability_at(active, Utc::now()),
            QuotaAvailability::Usable
        );
        Ok(())
    }

    #[test]
    fn rotate_now_reload_failure_leaves_recoverable_barrier_without_second_reset() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 20.0, 100.0);
        let mut replacement = account("replacement@example.com", false, 10.0, 10.0);
        replacement.plan_type = Some("free".to_string());
        save_accounts(&store_path, &[active.clone(), replacement])?;
        auth::write_auth_file(&auth_path, &active)?;

        let active_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                {
                    let active_fetches = Arc::clone(&active_fetches);
                    move |account| {
                        let mut result = fetch_from_account(account)?;
                        if account.email == "active@example.com" {
                            let mut calls = active_fetches.lock().unwrap();
                            *calls += 1;
                            if *calls > 1 {
                                for window in &mut result.snapshot.windows {
                                    window.used_percent = 0.0;
                                    window.hard_limit_reached = false;
                                }
                                result.snapshot.allowed = Some(true);
                                result.snapshot.limit_reached = Some(false);
                            }
                        }
                        Ok(result)
                    }
                },
                {
                    let bank_fetches = Arc::clone(&bank_fetches);
                    move |_account| {
                        let mut calls = bank_fetches.lock().unwrap();
                        *calls += 1;
                        Ok(reset_bank(if *calls == 1 { &["credit-a"] } else { &[] }))
                    }
                },
                {
                    let consume_calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *consume_calls.lock().unwrap() += 1;
                        Ok(ConsumeResult {
                            code: rate_limit_resets::ConsumeCode::Reset,
                            credit_id: Some("credit-a".to_string()),
                        })
                    }
                },
                |_| bail!("simulated cancellation before runtime acknowledgement"),
            ),
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("activation did not publish as swapped"));
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::CommittedDegraded
        );
        assert_eq!(
            active_account(&store_lock.load()?.accounts).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        drop(store_lock);

        let recovered =
            reconcile_activation_barrier_unlocked(&store_path, &auth_path, true, &|_| {
                Ok(verified_reload_summary())
            })?
            .context("recoverable activation barrier disappeared")?;
        assert!(recovered.is_confirmed());
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::Confirmed
        );
        Ok(())
    }

    #[test]
    fn targeted_reset_refuses_post_and_commit_after_journal_only_transition() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
        save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_before = fs::read(&store_path)?;

        let transition_path = store_path.clone();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            {
                let quota_calls = Arc::clone(&quota_calls);
                move |account| {
                    *quota_calls.lock().unwrap() += 1;
                    fetch_from_account(account)
                }
            },
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    *bank_calls.lock().unwrap() += 1;
                    set_test_activation_state(&transition_path, ActivationState::Prepared)?;
                    Ok(reset_bank(&["credit-a"]))
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    bail!("journal-only transition must prevent reset POST")
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("changed activation journal"));
        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 1);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(fs::read(&store_path)?, store_before);
        assert!(!rate_limit_resets::reset_attempt_journal_path(&store_path).exists());
        let store_lock = lock_account_store(&store_path)?;
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::Prepared
        );
        Ok(())
    }

    #[test]
    fn reset_engine_revalidates_activation_immediately_before_post() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
        save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_before = fs::read(&store_path)?;
        let snapshot = preflight_provider_io_activation(&store_path, &auth_path)?;
        let activation_guard = snapshot.guard;
        let mut accounts = snapshot.accounts;
        let observed_bank = reset_bank(&["credit-a"]);
        let now = observed_bank.fetched_at;
        let store_lock = lock_account_store(&store_path)?;
        let consume_calls = Arc::new(Mutex::new(0usize));
        let guard_calls = Arc::new(Mutex::new(0usize));
        let guard_store_path = store_path.clone();
        let guard_auth_path = auth_path.clone();

        let error = reconcile_or_attempt_reset_with_provider_guard(
            ResetReconciliationContext {
                store_lock: &store_lock,
                account: &mut accounts[0],
                previous_bank: None,
                observed_bank,
                attempt_reset: true,
                now,
            },
            ResetReconciliationDependencies::new(
                |_account| bail!("cancelled reset must not reconcile inventory"),
                |_account| bail!("cancelled reset must not reconcile quota"),
                {
                    let consume_calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *consume_calls.lock().unwrap() += 1;
                        bail!("activation guard must run before reset POST")
                    }
                },
            ),
            {
                let guard_calls = Arc::clone(&guard_calls);
                move |store_lock| {
                    *guard_calls.lock().unwrap() += 1;
                    let mut record = activation::read_activation_record(store_lock)?
                        .context("pre-POST test lost its activation record")?;
                    record.state = ActivationState::Prepared;
                    overwrite_test_activation_record(&guard_store_path, &record)?;
                    validate_provider_io_activation_locked(
                        store_lock,
                        &guard_auth_path,
                        &activation_guard,
                    )
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("immediately before POST"));
        assert_eq!(*guard_calls.lock().unwrap(), 1);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        assert_eq!(fs::read(&store_path)?, store_before);
        let journal: Value = serde_json::from_slice(&fs::read(
            rate_limit_resets::reset_attempt_journal_path(&store_path),
        )?)?;
        assert_eq!(journal["attempts"][0]["state"], "terminal_not_applied");
        assert!(journal["attempts"][0]["lastError"]
            .as_str()
            .is_some_and(|detail| detail.contains("cancelled before POST")));
        assert_eq!(
            activation::read_activation_record(&store_lock)?
                .unwrap()
                .state,
            ActivationState::Prepared
        );
        Ok(())
    }

    #[test]
    fn targeted_reset_blocks_all_provider_callbacks_until_activation_is_current() -> Result<()> {
        for (label, fixture) in blocked_provider_io_activations() {
            let temp = secure_temp_dir()?;
            let store_path = temp.path().join("accounts.json");
            let auth_path = temp.path().join("auth.json");
            let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
            save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
            install_blocked_provider_io_activation(&store_path, &auth_path, &exhausted, fixture)?;

            let quota_calls = Arc::new(Mutex::new(0usize));
            let bank_calls = Arc::new(Mutex::new(0usize));
            let consume_calls = Arc::new(Mutex::new(0usize));
            let error = redeem_reset_with(
                &store_path,
                &auth_path,
                &exhausted.email,
                {
                    let quota_calls = Arc::clone(&quota_calls);
                    move |account| {
                        *quota_calls.lock().unwrap() += 1;
                        fetch_from_account(account)
                    }
                },
                {
                    let bank_calls = Arc::clone(&bank_calls);
                    move |_account| {
                        *bank_calls.lock().unwrap() += 1;
                        Ok(reset_bank(&["credit-a"]))
                    }
                },
                {
                    let consume_calls = Arc::clone(&consume_calls);
                    move |_account, _bank, _request_id| {
                        *consume_calls.lock().unwrap() += 1;
                        Ok(ConsumeResult {
                            code: rate_limit_resets::ConsumeCode::Reset,
                            credit_id: Some("credit-a".to_string()),
                        })
                    }
                },
            )
            .unwrap_err();

            assert!(
                format!("{error:#}").contains("targeted reset activation preflight failed"),
                "unexpected {label} failure: {error:#}"
            );
            assert_eq!(*quota_calls.lock().unwrap(), 0, "{label} quota callback");
            assert_eq!(*bank_calls.lock().unwrap(), 0, "{label} bank callback");
            assert_eq!(*consume_calls.lock().unwrap(), 0, "{label} reset POST");
        }
        Ok(())
    }

    #[test]
    fn targeted_reset_finalizes_staged_confirmed_generation_before_provider_callback() -> Result<()>
    {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
        save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let mut accounts = snapshot.accounts;
        let base_generation = snapshot.generation;
        accounts[0].plan_type = Some("plus".to_string());
        let prospective_generation = store_lock.prospective_generation(&accounts)?;
        let mut record = activation::read_activation_record(&store_lock)?
            .context("staged reset fixture lost its activation record")?;
        let evidence_time = record.updated_at.to_owned();
        record.base_store_generation = Some(base_generation.as_str().to_string());
        record.owned_store_generation = Some(prospective_generation.as_str().to_string());
        overwrite_test_activation_record(&store_path, &record)?;
        drop(store_lock);

        let quota_store_path = store_path.clone();
        let quota_auth_path = auth_path.clone();
        let quota_generation = base_generation.as_str().to_string();
        let bank_store_path = store_path.clone();
        let bank_auth_path = auth_path.clone();
        let bank_generation = base_generation.as_str().to_string();
        let quota_calls = Arc::new(Mutex::new(0usize));
        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            {
                let quota_calls = Arc::clone(&quota_calls);
                move |account| {
                    assert_store_lock_available(&quota_store_path)?;
                    assert_clean_provider_io_activation(
                        &quota_store_path,
                        &quota_auth_path,
                        &quota_generation,
                    )?;
                    *quota_calls.lock().unwrap() += 1;
                    let mut result = fetch_from_account(account)?;
                    for window in &mut result.snapshot.windows {
                        window.used_percent = 0.0;
                        window.hard_limit_reached = false;
                    }
                    result.snapshot.allowed = Some(true);
                    result.snapshot.limit_reached = Some(false);
                    Ok(result)
                }
            },
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    assert_store_lock_available(&bank_store_path)?;
                    assert_clean_provider_io_activation(
                        &bank_store_path,
                        &bank_auth_path,
                        &bank_generation,
                    )?;
                    *bank_calls.lock().unwrap() += 1;
                    Ok(reset_bank(&["credit-a"]))
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    bail!("usable quota must not submit a reset")
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("requires a fresh blocked quota"));
        assert_eq!(*quota_calls.lock().unwrap(), 1);
        assert_eq!(*bank_calls.lock().unwrap(), 1);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let store_lock = lock_account_store(&store_path)?;
        let finalized = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(finalized.state, ActivationState::Confirmed);
        assert_eq!(finalized.updated_at, evidence_time);
        assert_eq!(finalized.base_store_generation, None);
        assert_eq!(finalized.owned_store_generation, None);
        Ok(())
    }

    #[test]
    fn targeted_reset_redeems_only_requested_paid_account_and_preserves_active_auth() -> Result<()>
    {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 0.0, 10.0);
        let mut exhausted = account("exhausted@example.com", false, 0.0, 100.0);
        exhausted.plan_type = Some("plus".to_string());
        exhausted.runtime_unusable_until = Some(Utc::now() + ChronoDuration::days(7));
        exhausted.runtime_unusable_reason = Some("usage_limit".to_string());
        save_accounts(&store_path, &[active.clone(), exhausted.clone()])?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let auth_before = fs::read(&auth_path)?;

        let quota_fetches = Arc::new(Mutex::new(0usize));
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let quota_store_path = store_path.clone();
        let bank_store_path = store_path.clone();
        let consume_store_path = store_path.clone();
        let report = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            {
                let quota_fetches = Arc::clone(&quota_fetches);
                move |account| {
                    assert_store_lock_available(&quota_store_path)?;
                    let mut result = fetch_from_account(account)?;
                    let mut calls = quota_fetches.lock().unwrap();
                    *calls += 1;
                    if *calls > 1 {
                        for window in &mut result.snapshot.windows {
                            window.used_percent = 0.0;
                            window.hard_limit_reached = false;
                        }
                        result.snapshot.allowed = Some(true);
                        result.snapshot.limit_reached = Some(false);
                    }
                    Ok(result)
                }
            },
            {
                let bank_fetches = Arc::clone(&bank_fetches);
                move |_account| {
                    assert_store_lock_available(&bank_store_path)?;
                    let mut calls = bank_fetches.lock().unwrap();
                    *calls += 1;
                    Ok(if *calls == 1 {
                        reset_bank(&["credit-a", "credit-b"])
                    } else {
                        reset_bank(&["credit-b"])
                    })
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    assert_store_lock_available(&consume_store_path)?;
                    *consume_calls.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: Some("credit-a".to_string()),
                    })
                }
            },
        )?;

        assert_eq!(report.account, exhausted.email);
        assert!(!report.was_active);
        assert!(report.submitted_reset);
        assert_eq!(report.previous_banked_resets, 2);
        assert_eq!(report.banked_resets_remaining, 1);
        assert_eq!(*quota_fetches.lock().unwrap(), 2);
        assert_eq!(*bank_fetches.lock().unwrap(), 2);
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        assert_eq!(fs::read(&auth_path)?, auth_before);

        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("active@example.com")
        );
        let redeemed = stored
            .iter()
            .find(|account| account.email == exhausted.email)
            .unwrap();
        assert_eq!(redeemed.runtime_unusable_until, None);
        assert_eq!(redeemed.runtime_unusable_reason, None);
        assert_eq!(
            quota_availability_at(redeemed, Utc::now()),
            QuotaAvailability::Usable
        );
        Ok(())
    }

    #[test]
    fn targeted_reset_rejects_usable_pro_without_consuming_credit() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let usable = account("usable@example.com", true, 0.0, 10.0);
        save_accounts(&store_path, std::slice::from_ref(&usable))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;
        let store_lock = lock_account_store(&store_path)?;
        let confirmed_before = activation::read_activation_record(&store_lock)?.unwrap();
        drop(store_lock);

        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = redeem_reset_with(
            &store_path,
            &auth_path,
            &usable.email,
            fetch_from_account,
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    *bank_calls.lock().unwrap() += 1;
                    Ok(reset_bank(&["credit-a"]))
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    bail!("usable account must not consume a reset")
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("requires a fresh blocked quota"));
        assert_eq!(*bank_calls.lock().unwrap(), 1);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let store_lock = lock_account_store(&store_path)?;
        let snapshot = store_lock.load()?;
        let confirmed_after = activation::read_activation_record(&store_lock)?.unwrap();
        assert_eq!(
            confirmed_after.store_generation,
            snapshot.generation.as_str()
        );
        assert_eq!(confirmed_after.updated_at, confirmed_before.updated_at);
        Ok(())
    }

    #[test]
    fn targeted_reset_preserves_concurrent_store_change_during_observation() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
        save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let mutation_path = store_path.clone();
        let mut concurrent = exhausted.clone();
        concurrent.runtime_unusable_reason = Some("concurrent-writer".to_string());
        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let error = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            move |account| {
                assert_store_lock_available(&mutation_path)?;
                save_accounts(&mutation_path, std::slice::from_ref(&concurrent))?;
                fetch_from_account(account)
            },
            |_account| Ok(reset_bank(&["credit-a"])),
            move |_account, _bank, _request_id| {
                *consume_calls_for_closure.lock().unwrap() += 1;
                bail!("a stale targeted observation must never consume a reset")
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("provider-I/O activation guard"));
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            stored[0].runtime_unusable_reason.as_deref(),
            Some("concurrent-writer")
        );
        Ok(())
    }

    #[test]
    fn targeted_reset_reconciles_async_quota_recovery_without_second_post() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let exhausted = account("exhausted@example.com", true, 0.0, 100.0);
        save_accounts(&store_path, std::slice::from_ref(&exhausted))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let bank_fetches = Arc::new(Mutex::new(0usize));
        let first_error = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            fetch_from_account,
            {
                let bank_fetches = Arc::clone(&bank_fetches);
                move |_account| {
                    let mut calls = bank_fetches.lock().unwrap();
                    *calls += 1;
                    Ok(if *calls == 1 {
                        reset_bank(&["credit-a"])
                    } else {
                        reset_bank(&[])
                    })
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: Some("credit-a".to_string()),
                    })
                }
            },
        )
        .unwrap_err();
        assert!(format!("{first_error:#}").contains("not reconciled as usable"));
        assert_eq!(*consume_calls.lock().unwrap(), 1);

        let report = redeem_reset_with(
            &store_path,
            &auth_path,
            &exhausted.email,
            |account| {
                let mut result = fetch_from_account(account)?;
                for window in &mut result.snapshot.windows {
                    window.used_percent = 0.0;
                    window.hard_limit_reached = false;
                }
                result.snapshot.allowed = Some(true);
                result.snapshot.limit_reached = Some(false);
                Ok(result)
            },
            |_account| Ok(reset_bank(&[])),
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    bail!("journal replay must not submit a second reset")
                }
            },
        )?;

        assert!(!report.submitted_reset);
        assert_eq!(report.previous_banked_resets, 0);
        assert_eq!(report.banked_resets_remaining, 0);
        assert_eq!(report.remaining_percent, Some(100.0));
        assert_eq!(*consume_calls.lock().unwrap(), 1);
        let journal: Value = serde_json::from_slice(&fs::read(
            rate_limit_resets::reset_attempt_journal_path(&store_path),
        )?)?;
        assert_eq!(journal["attempts"][0]["state"], "reconciled_usable");
        Ok(())
    }

    #[test]
    fn targeted_reset_rejects_free_without_fetching_or_consuming_credit() -> Result<()> {
        let temp = secure_temp_dir()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let mut free = account("free@example.com", true, 0.0, 100.0);
        free.plan_type = Some("free".to_string());
        save_accounts(&store_path, std::slice::from_ref(&free))?;
        confirm_provider_io_activation(&store_path, &auth_path)?;

        let bank_calls = Arc::new(Mutex::new(0usize));
        let consume_calls = Arc::new(Mutex::new(0usize));
        let error = redeem_reset_with(
            &store_path,
            &auth_path,
            &free.email,
            fetch_from_account,
            {
                let bank_calls = Arc::clone(&bank_calls);
                move |_account| {
                    *bank_calls.lock().unwrap() += 1;
                    Ok(reset_bank(&["credit-a"]))
                }
            },
            {
                let consume_calls = Arc::clone(&consume_calls);
                move |_account, _bank, _request_id| {
                    *consume_calls.lock().unwrap() += 1;
                    bail!("free account must not consume a reset")
                }
            },
        )
        .unwrap_err();

        assert!(format!("{error:#}").contains("requires a paid account"));
        assert_eq!(*bank_calls.lock().unwrap(), 0);
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        Ok(())
    }

    #[test]
    fn usage_limit_rotate_does_not_spend_five_hour_reset_with_ready_replacement() -> Result<()> {
        let temp = TempDir::new()?;
        let store_path = temp.path().join("accounts.json");
        let auth_path = temp.path().join("auth.json");
        let active = account("active@example.com", true, 100.0, 20.0);
        let replacement = account("replacement@example.com", false, 10.0, 10.0);
        save_accounts(&store_path, &[active, replacement])?;

        let consume_calls = Arc::new(Mutex::new(0usize));
        let consume_calls_for_closure = Arc::clone(&consume_calls);
        let report = rotate_now_with_resets(
            RotateNowContext {
                store_path: &store_path,
                auth_path: &auth_path,
                reason: "usage_limit",
                cooldown_seconds: 21_600,
                reload_processes: true,
                allow_banked_reset: true,
                receipt_nonce: None,
            },
            RotateNowDependencies::new(
                fetch_from_account,
                |_account| {
                    Ok(RateLimitResetBank {
                        available_count: 1,
                        total_earned_count: 1,
                        credits: Vec::new(),
                        fetched_at: Utc::now(),
                    })
                },
                move |_account, _bank, _request_id| {
                    *consume_calls_for_closure.lock().unwrap() += 1;
                    Ok(ConsumeResult {
                        code: rate_limit_resets::ConsumeCode::Reset,
                        credit_id: None,
                    })
                },
                |_| Ok(verified_reload_summary()),
            ),
        )?;

        assert!(!report.used_banked_reset);
        assert_eq!(report.next_email, "replacement@example.com");
        assert_eq!(*consume_calls.lock().unwrap(), 0);
        let stored = load_accounts(&store_path)?;
        assert_eq!(
            active_account(&stored).map(|account| account.email.as_str()),
            Some("replacement@example.com")
        );
        Ok(())
    }
}

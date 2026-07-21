use crate::account_store::{
    active_account, load_account_store_snapshot, quota_availability_at, QuotaAvailability,
};
use crate::activation::{
    activation_record_confirms_current, read_activation_record_for_store, ActivationState,
};
use crate::auth::{account_token_fingerprint, auth_file_fingerprint};
#[cfg(not(target_os = "linux"))]
use crate::bounded_command;
use crate::reload::{
    binary_has_sighup_support_for_runtime, discover_codex_app_server_processes,
    discover_codex_cli_processes, hot_swap_runtime_kind, process_has_current_hot_swap_ack,
    process_is_sighup_safe_target, CodexProcess, HotSwapRuntimeKind,
};
use crate::secure_file;
use anyhow::{Context, Result};
use chrono::Utc;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
#[cfg(target_os = "linux")]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
#[cfg(not(target_os = "linux"))]
use std::process::Command;
#[cfg(not(target_os = "linux"))]
use std::time::Duration;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessReport {
    pub ready: bool,
    pub summary: String,
    pub account_store_ok: bool,
    pub auth_writable: bool,
    pub daemon_running: bool,
    pub activation_barrier: bool,
    pub activation_barrier_clear: bool,
    pub activation_state: Option<ActivationState>,
    pub account_count: usize,
    pub active_email: Option<String>,
    pub ready_candidate_count: usize,
    pub processes: Vec<ProcessReadiness>,
    pub app_servers: Vec<ProcessReadiness>,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessReadiness {
    pub pid: i32,
    pub executable: String,
    pub hot_swap_ready: bool,
    pub reason: String,
}

pub fn check(store_path: &Path, auth_path: &Path) -> Result<ReadinessReport> {
    let mut issues = Vec::new();
    let mut account_count = 0;
    let mut active_email = None;
    let mut active_token_fingerprint = None;
    let mut active_confirmation_account = None;
    let mut store_generation = None;
    let mut ready_candidate_count = 0;
    let mut active_availability = QuotaAvailability::Unknown;

    let accounts = match load_account_store_snapshot(store_path) {
        Ok(snapshot) => {
            store_generation = Some(snapshot.generation.clone());
            let accounts = snapshot.accounts;
            account_count = accounts.len();
            if let Some(active) = active_account(&accounts) {
                active_email = Some(active.email.clone());
                active_token_fingerprint = account_token_fingerprint(active);
                active_confirmation_account = Some(active.clone());
                if active_token_fingerprint.is_none() {
                    issues.push("active account has incomplete token material".to_string());
                }
                active_availability = quota_availability_at(active, Utc::now());
            }
            ready_candidate_count = accounts
                .iter()
                .filter(|account| !account.is_active)
                .filter(|account| {
                    quota_availability_at(account, Utc::now()) == QuotaAvailability::Usable
                })
                .count();
            if accounts.is_empty() {
                issues.push("no accounts imported".to_string());
            }
            if active_email.is_none() {
                issues.push("no active account selected".to_string());
            }
            if active_availability == QuotaAvailability::Unknown {
                issues.push("active account quota availability is unknown".to_string());
            } else if active_availability == QuotaAvailability::Blocked
                && ready_candidate_count == 0
            {
                issues.push("active account is blocked but no ready candidate exists".to_string());
            }
            Some(accounts)
        }
        Err(error) => {
            issues.push(format!("account store unreadable: {error:#}"));
            None
        }
    };

    let auth_writable = path_is_writable(auth_path);
    if !auth_writable {
        issues.push(format!(
            "auth path is not writable: {}",
            auth_path.display()
        ));
    }
    let auth_token_fingerprint = auth_file_fingerprint(auth_path);
    if auth_token_fingerprint.is_none() {
        issues.push("auth.json does not contain a complete token set".to_string());
    }
    let auth_matches_active = token_fingerprints_match(
        active_token_fingerprint.as_deref(),
        auth_token_fingerprint.as_deref(),
    );
    if active_email.is_some() && !auth_matches_active {
        issues.push("auth.json token fingerprint does not match active account".to_string());
    }

    let (activation_state, activation_barrier_clear) = match read_activation_record_for_store(
        store_path,
    ) {
        Ok(Some(record))
            if active_confirmation_account
                .as_ref()
                .zip(store_generation.as_ref())
                .is_some_and(|(active, generation)| {
                    activation_record_confirms_current(
                        &record,
                        active,
                        generation,
                        auth_token_fingerprint.as_deref(),
                    )
                }) =>
        {
            (Some(record.state), true)
        }
        Ok(Some(record)) => {
            let detail = match record.state {
                ActivationState::Confirmed => {
                    "activation journal Confirmed record is stale or does not match current store/auth state"
                        .to_string()
                }
                ActivationState::RolledBack => {
                    "activation journal is rolled back and does not confirm current runtime state"
                        .to_string()
                }
                state if activation_state_is_unresolved_barrier(state) => {
                    format!("activation journal contains unresolved {state:?} barrier")
                }
                state => format!("activation journal state {state:?} is not current confirmation"),
            };
            issues.push(detail);
            (Some(record.state), false)
        }
        Ok(None) => {
            issues.push("activation confirmation record is missing".to_string());
            (None, false)
        }
        Err(error) => {
            issues.push(format!("activation journal unreadable: {error:#}"));
            (None, false)
        }
    };
    let activation_barrier = !activation_barrier_clear;

    let daemon_running = daemon_is_running()?;
    if !daemon_running {
        issues.push(if cfg!(target_os = "macos") {
            "CodexSwitch menu coordinator is not running".to_string()
        } else {
            "codexswitch daemon is not running".to_string()
        });
    }

    let mut binary_marker_cache = HashMap::new();

    let processes = discover_codex_cli_processes()?
        .into_iter()
        .map(|process| {
            let binary_has_markers = hot_swap_runtime_kind(&process).is_some_and(|runtime_kind| {
                cached_binary_has_sighup_support(
                    &mut binary_marker_cache,
                    &process.executable,
                    runtime_kind,
                )
            });
            let ack_ready = process_has_current_hot_swap_ack(&process, auth_path);
            classify_process_readiness(&process, binary_has_markers, ack_ready, false)
        })
        .collect::<Vec<_>>();

    for process in processes.iter().filter(|process| !process.hot_swap_ready) {
        issues.push(format!(
            "pid {} is not hot-swap ready: {}",
            process.pid, process.reason
        ));
    }

    let app_servers = discover_codex_app_server_processes()?
        .into_iter()
        .map(|process| {
            let binary_has_markers = hot_swap_runtime_kind(&process).is_some_and(|runtime_kind| {
                cached_binary_has_sighup_support(
                    &mut binary_marker_cache,
                    &process.executable,
                    runtime_kind,
                )
            });
            let ack_ready = process_has_current_hot_swap_ack(&process, auth_path);
            classify_process_readiness(&process, binary_has_markers, ack_ready, true)
        })
        .collect::<Vec<_>>();

    for process in app_servers.iter().filter(|process| !process.hot_swap_ready) {
        issues.push(format!(
            "Codex app-server pid {} is not hot-swap ready: {}",
            process.pid, process.reason
        ));
    }

    let runtime_discovered = account_bearing_runtime_discovered(&processes, &app_servers);
    if !runtime_discovered {
        issues.push("no account-bearing Codex runtime discovered".to_string());
    }

    let ready = accounts.is_some()
        && account_count > 0
        && active_email.is_some()
        && auth_matches_active
        && active_availability != QuotaAvailability::Unknown
        && !(active_availability == QuotaAvailability::Blocked && ready_candidate_count == 0)
        && auth_writable
        && daemon_running
        && activation_barrier_clear
        && runtime_discovered
        && processes.iter().all(|process| process.hot_swap_ready)
        && app_servers.iter().all(|process| process.hot_swap_ready);

    let summary = if ready {
        format!(
            "Ready: daemon running and {} CLI session(s) + {} app-server(s) can hot-swap",
            processes.len(),
            app_servers.len()
        )
    } else {
        format!("Not ready: {}", issues.join("; "))
    };

    Ok(ReadinessReport {
        ready,
        summary,
        account_store_ok: accounts.is_some(),
        auth_writable,
        daemon_running,
        activation_barrier,
        activation_barrier_clear,
        activation_state,
        account_count,
        active_email,
        ready_candidate_count,
        processes,
        app_servers,
        issues,
    })
}

fn token_fingerprints_match(active: Option<&str>, auth: Option<&str>) -> bool {
    active
        .zip(auth)
        .is_some_and(|(active, auth)| active == auth)
}

fn activation_state_is_unresolved_barrier(state: ActivationState) -> bool {
    matches!(
        state,
        ActivationState::Prepared
            | ActivationState::FileOnly
            | ActivationState::CommittedDegraded
            | ActivationState::ManualReview
    )
}

fn account_bearing_runtime_discovered(
    processes: &[ProcessReadiness],
    app_servers: &[ProcessReadiness],
) -> bool {
    !processes.is_empty() || !app_servers.is_empty()
}

fn cached_binary_has_sighup_support(
    cache: &mut HashMap<(PathBuf, HotSwapRuntimeKind), bool>,
    path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    let key = (path.to_path_buf(), runtime_kind);
    if let Some(has_support) = cache.get(&key) {
        return *has_support;
    }
    let has_support = binary_has_sighup_support_for_runtime(path, runtime_kind);
    cache.insert(key, has_support);
    has_support
}

fn classify_process_readiness(
    process: &CodexProcess,
    binary_has_markers: bool,
    ack_ready: bool,
    is_app_server: bool,
) -> ProcessReadiness {
    let safe_target = if is_app_server {
        binary_has_markers
    } else {
        process_is_sighup_safe_target(process, binary_has_markers)
    };
    let hot_swap_ready = safe_target && ack_ready;
    let reason = if !binary_has_markers {
        if is_app_server {
            "missing app-server SIGHUP hot-swap markers; restart using patched Codex app-server"
                .to_string()
        } else {
            "missing SIGHUP hot-swap markers; restart using patched Codex CLI".to_string()
        }
    } else if !ack_ready {
        "SIGHUP markers present, but live process has not acknowledged a reload; swap is not verified"
            .to_string()
    } else {
        "SIGHUP markers present and live reload acknowledged".to_string()
    };
    ProcessReadiness {
        pid: process.pid,
        executable: process.executable.display().to_string(),
        hot_swap_ready,
        reason,
    }
}

#[cfg(test)]
fn parse_proc_stat_start_ticks(stat: &str) -> Option<u64> {
    let end_comm = stat.rfind(')')?;
    let fields = stat[end_comm + 1..].split_whitespace().collect::<Vec<_>>();
    fields.get(19)?.parse::<u64>().ok()
}

fn path_is_writable(path: &Path) -> bool {
    secure_file::observe(path, 1024 * 1024, true).is_ok()
}

type DaemonDiscoveryFn = fn() -> Result<bool>;

fn daemon_is_running() -> Result<bool> {
    daemon_discovery_dispatch()()
}

fn daemon_discovery_dispatch() -> DaemonDiscoveryFn {
    #[cfg(target_os = "linux")]
    {
        daemon_is_running_via_procfs
    }
    #[cfg(not(target_os = "linux"))]
    {
        daemon_is_running_via_ps
    }
}

#[cfg(target_os = "linux")]
fn daemon_is_running_via_procfs() -> Result<bool> {
    let current_uid = unsafe { libc_geteuid() };
    for entry in fs::read_dir("/proc").context("failed to read /proc")? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Ok(pid) = name.parse::<i32>() else {
            continue;
        };
        if pid == std::process::id() as i32 {
            continue;
        }
        let proc_dir = entry.path();
        let Ok(metadata) = fs::metadata(&proc_dir) else {
            continue;
        };
        if metadata.uid() != current_uid {
            continue;
        }
        let command_line = fs::read(proc_dir.join("cmdline"))
            .map(|data| {
                String::from_utf8_lossy(&data)
                    .split('\0')
                    .filter(|part| !part.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        if is_codexswitch_daemon_command_line(&command_line) {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(not(target_os = "linux"))]
fn daemon_is_running_via_ps() -> Result<bool> {
    let output = bounded_command::output(
        Command::new("/bin/ps").args(["-axo", "pid=,uid=,command=", "-ww"]),
        Duration::from_secs(3),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .context("failed to run ps for CodexSwitch daemon discovery")?;
    if !output.status.success() {
        anyhow::bail!("ps exited with {}", output.status);
    }

    Ok(ps_output_has_codexswitch_daemon(
        &String::from_utf8_lossy(&output.stdout),
        unsafe { libc_geteuid() },
        std::process::id() as i32,
    ))
}

#[cfg(any(test, not(target_os = "linux")))]
fn ps_output_has_codexswitch_daemon(ps_output: &str, current_uid: u32, current_pid: i32) -> bool {
    ps_output.lines().any(|line| {
        let Some((pid_text, rest)) = split_first_ps_field(line) else {
            return false;
        };
        let Ok(pid) = pid_text.parse::<i32>() else {
            return false;
        };
        if pid == current_pid {
            return false;
        }

        let Some((uid_text, command_line)) = split_first_ps_field(rest) else {
            return false;
        };
        uid_text.parse::<u32>().ok() == Some(current_uid)
            && is_codexswitch_coordinator_command_line(command_line)
    })
}

#[cfg(any(test, not(target_os = "linux")))]
fn split_first_ps_field(input: &str) -> Option<(&str, &str)> {
    let trimmed = input.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let end = trimmed
        .find(|character: char| character.is_whitespace())
        .unwrap_or(trimmed.len());
    Some((&trimmed[..end], trimmed[end..].trim_start()))
}

fn is_codexswitch_daemon_command_line(command_line: &str) -> bool {
    command_line.contains("codexswitch-cli") && command_line.contains(" daemon")
}

#[cfg(any(test, not(target_os = "linux")))]
fn is_codexswitch_coordinator_command_line(command_line: &str) -> bool {
    if is_codexswitch_daemon_command_line(command_line) {
        return true;
    }
    command_line
        .split_whitespace()
        .next()
        .map(str::to_ascii_lowercase)
        .is_some_and(|executable| {
            executable.ends_with("/codexswitch.app/contents/macos/codexswitch")
        })
}

unsafe fn libc_geteuid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    geteuid()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::CodexAccount;
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::PathBuf;

    fn create_fifo(path: &Path) -> Result<()> {
        let path = CString::new(path.as_os_str().as_bytes())?;
        let status = unsafe { libc::mkfifo(path.as_ptr(), 0o600) };
        if status == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error()).context("failed to create readiness test FIFO")
        }
    }

    fn process() -> CodexProcess {
        CodexProcess {
            pid: 42,
            owner_uid: 501,
            start_identity: "test-start".to_string(),
            started_at_unix: 1_000,
            command_line: "/home/me/.local/share/codexswitch/patched-codex/codex app-server"
                .to_string(),
            executable: PathBuf::from("/home/me/.local/share/codexswitch/patched-codex/codex"),
        }
    }

    fn account() -> CodexAccount {
        CodexAccount {
            id: uuid::Uuid::new_v4(),
            email: "active@example.com".to_string(),
            access_token: "access".to_string(),
            refresh_token: "refresh".to_string(),
            id_token: "id".to_string(),
            account_id: "provider-active".to_string(),
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
    fn readiness_requires_complete_matching_token_fingerprint() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let auth_path = dir.path().join("auth.json");
        let account = account();
        fs::write(
            &auth_path,
            br#"{"tokens":{"id_token":"id","access_token":"access","refresh_token":"different","account_id":"provider-active"}}"#,
        )?;

        assert!(!token_fingerprints_match(
            account_token_fingerprint(&account).as_deref(),
            auth_file_fingerprint(&auth_path).as_deref(),
        ));
        fs::write(
            &auth_path,
            br#"{"tokens":{"id_token":"id","access_token":"access","account_id":"provider-active"}}"#,
        )?;
        assert!(auth_file_fingerprint(&auth_path).is_none());
        assert!(!token_fingerprints_match(
            account_token_fingerprint(&account).as_deref(),
            auth_file_fingerprint(&auth_path).as_deref(),
        ));
        Ok(())
    }

    #[test]
    fn auth_diagnostic_is_read_only_and_rejects_symlink_and_fifo() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700))?;
        let auth_path = dir.path().join("auth.json");
        let auth_bytes = br#"{"tokens":{"access_token":"access"}}"#;
        fs::write(&auth_path, auth_bytes)?;
        fs::set_permissions(&auth_path, fs::Permissions::from_mode(0o600))?;

        assert!(path_is_writable(&auth_path));
        assert_eq!(fs::read(&auth_path)?, auth_bytes);
        assert!(!dir.path().join("auth.json.lock").exists());

        let outside = dir.path().join("outside.json");
        fs::write(&outside, b"outside")?;
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o600))?;
        let linked = dir.path().join("linked-auth.json");
        symlink(&outside, &linked)?;
        assert!(!path_is_writable(&linked));
        assert_eq!(fs::read(&outside)?, b"outside");

        let fifo = dir.path().join("auth.fifo");
        create_fifo(&fifo)?;
        assert!(!path_is_writable(&fifo));
        Ok(())
    }

    #[test]
    fn readiness_module_has_no_reload_or_signal_path() {
        let source = include_str!("readiness.rs");
        for forbidden in [
            concat!("reload_codex", "_hot_swap_processes"),
            concat!("signal_validated", "_process"),
            concat!("pidfd_send", "_signal"),
            concat!("libc::", "kill"),
        ] {
            assert!(
                !source.contains(forbidden),
                "read-only readiness reintroduced a mutating path through {forbidden}"
            );
        }
    }

    #[test]
    fn markers_without_live_ack_are_not_ready() {
        let readiness = classify_process_readiness(&process(), true, false, true);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("has not acknowledged a reload"));
    }

    #[test]
    fn markers_with_live_ack_are_ready() {
        let readiness = classify_process_readiness(&process(), true, true, true);

        assert!(readiness.hot_swap_ready);
        assert!(readiness.reason.contains("live reload acknowledged"));
    }

    #[test]
    fn fresh_app_server_start_after_auth_is_not_ready_without_ack() {
        let readiness = classify_process_readiness(&process(), true, false, true);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("has not acknowledged a reload"));
    }

    #[test]
    fn readiness_requires_an_account_bearing_runtime() {
        assert!(!account_bearing_runtime_discovered(&[], &[]));
        assert!(account_bearing_runtime_discovered(
            &[classify_process_readiness(&process(), true, true, false)],
            &[],
        ));
    }

    #[test]
    fn readiness_rejects_every_unresolved_activation_barrier() {
        for state in [
            ActivationState::Prepared,
            ActivationState::FileOnly,
            ActivationState::CommittedDegraded,
            ActivationState::ManualReview,
        ] {
            assert!(activation_state_is_unresolved_barrier(state));
        }
        for state in [ActivationState::Confirmed, ActivationState::RolledBack] {
            assert!(!activation_state_is_unresolved_barrier(state));
        }
    }

    #[test]
    fn readiness_json_exposes_explicit_noncurrent_activation_states() -> Result<()> {
        let mut report = ReadinessReport {
            ready: false,
            summary: "not ready".to_string(),
            account_store_ok: true,
            auth_writable: true,
            daemon_running: true,
            activation_barrier: true,
            activation_barrier_clear: false,
            activation_state: None,
            account_count: 1,
            active_email: Some("active@example.com".to_string()),
            ready_candidate_count: 0,
            processes: Vec::new(),
            app_servers: Vec::new(),
            issues: Vec::new(),
        };

        let json = serde_json::to_value(&report)?;
        assert_eq!(json["activationBarrier"], true);
        assert_eq!(json["activationBarrierClear"], false);
        assert!(json["activationState"].is_null());

        report.activation_state = Some(ActivationState::Confirmed);
        let stale_confirmed = serde_json::to_value(&report)?;
        assert_eq!(stale_confirmed["activationBarrier"], true);
        assert_eq!(stale_confirmed["activationBarrierClear"], false);
        assert_eq!(stale_confirmed["activationState"], "confirmed");

        report.activation_state = Some(ActivationState::RolledBack);
        let rolled_back = serde_json::to_value(&report)?;
        assert_eq!(rolled_back["activationBarrier"], true);
        assert_eq!(rolled_back["activationBarrierClear"], false);
        assert_eq!(rolled_back["activationState"], "rolled_back");
        Ok(())
    }

    #[test]
    fn proc_stat_start_ticks_parser_handles_spaces_in_command() {
        let stat =
            "1234 (codex app-server) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20";
        assert_eq!(parse_proc_stat_start_ticks(stat), Some(987654));
    }

    #[test]
    fn ps_daemon_parser_filters_pid_uid_and_command() {
        let ps_output = "\
  410  501 /usr/local/bin/codexswitch-cli doctor --json
  411  502 /usr/local/bin/codexswitch-cli daemon
  412  501 /usr/local/bin/codexswitch-cli daemon --poll-seconds 30
  413  501 /bin/zsh -lc codexswitch-cli doctor --json
invalid row
";

        assert!(ps_output_has_codexswitch_daemon(ps_output, 501, 999));
        assert!(!ps_output_has_codexswitch_daemon(ps_output, 501, 412));
    }

    #[test]
    fn ps_daemon_parser_recognizes_the_macos_menu_coordinator() {
        let ps_output = "\
  510  501 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
  511  501 /Users/me/Developer/CodexSwitch/.build/debug/CodexSwitchTests
";

        assert!(ps_output_has_codexswitch_daemon(ps_output, 501, 999));
        assert!(!ps_output_has_codexswitch_daemon(ps_output, 501, 510));
    }

    #[test]
    fn empty_ps_snapshot_is_a_valid_no_daemon_state() {
        assert!(!ps_output_has_codexswitch_daemon("", 501, 999));
        assert!(!ps_output_has_codexswitch_daemon(
            "  410  501 /usr/local/bin/codexswitch-cli doctor --json\n",
            501,
            999,
        ));
    }

    #[test]
    fn daemon_discovery_dispatch_matches_platform() {
        let selected = daemon_discovery_dispatch() as *const () as usize;

        #[cfg(target_os = "linux")]
        assert_eq!(selected, daemon_is_running_via_procfs as *const () as usize);
        #[cfg(not(target_os = "linux"))]
        assert_eq!(selected, daemon_is_running_via_ps as *const () as usize);
    }
}

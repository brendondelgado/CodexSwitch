use crate::account_store::{
    active_account, load_accounts, quota_availability_at, QuotaAvailability,
};
use crate::auth::{account_token_fingerprint, auth_file_fingerprint};
#[cfg(not(target_os = "linux"))]
use crate::bounded_command;
use crate::reload::{
    binary_has_sighup_support, discover_codex_app_server_processes, discover_codex_cli_processes,
    process_has_current_hot_swap_ack, process_identity_is_current, process_is_sighup_safe_target,
    CodexProcess,
};
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
    let mut ready_candidate_count = 0;
    let mut active_availability = QuotaAvailability::Unknown;

    let accounts = match load_accounts(store_path) {
        Ok(accounts) => {
            account_count = accounts.len();
            if let Some(active) = active_account(&accounts) {
                active_email = Some(active.email.clone());
                active_token_fingerprint = account_token_fingerprint(active);
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

    let daemon_running = daemon_is_running()?;
    if !daemon_running {
        issues.push("codexswitch daemon is not running".to_string());
    }

    let mut binary_marker_cache = HashMap::new();

    let processes = discover_codex_cli_processes()?
        .into_iter()
        .map(|process| {
            let binary_has_markers =
                cached_binary_has_sighup_support(&mut binary_marker_cache, &process.executable);
            let ack_ready = process_has_current_hot_swap_ack(&process, auth_path);
            classify_process_readiness(&process, binary_has_markers, ack_ready, false, false)
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
            let binary_has_markers =
                cached_binary_has_sighup_support(&mut binary_marker_cache, &process.executable);
            let ack_ready = process_has_current_hot_swap_ack(&process, auth_path);
            let fresh_start_ready = app_server_started_after_auth_file(&process, auth_path);
            classify_process_readiness(
                &process,
                binary_has_markers,
                ack_ready,
                true,
                fresh_start_ready,
            )
        })
        .collect::<Vec<_>>();

    for process in app_servers.iter().filter(|process| !process.hot_swap_ready) {
        issues.push(format!(
            "Codex app-server pid {} is not hot-swap ready: {}",
            process.pid, process.reason
        ));
    }

    let ready = accounts.is_some()
        && account_count > 0
        && active_email.is_some()
        && auth_matches_active
        && active_availability != QuotaAvailability::Unknown
        && !(active_availability == QuotaAvailability::Blocked && ready_candidate_count == 0)
        && auth_writable
        && daemon_running
        && processes.iter().all(|process| process.hot_swap_ready)
        && app_servers.iter().all(|process| process.hot_swap_ready);

    let summary = if ready {
        if processes.is_empty() && app_servers.is_empty() {
            "Ready: daemon is running; no live Codex sessions detected".to_string()
        } else {
            format!(
                "Ready: daemon running and {} CLI session(s) + {} app-server(s) can hot-swap",
                processes.len(),
                app_servers.len()
            )
        }
    } else {
        format!("Not ready: {}", issues.join("; "))
    };

    Ok(ReadinessReport {
        ready,
        summary,
        account_store_ok: accounts.is_some(),
        auth_writable,
        daemon_running,
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

fn cached_binary_has_sighup_support(cache: &mut HashMap<PathBuf, bool>, path: &Path) -> bool {
    if let Some(has_support) = cache.get(path) {
        return *has_support;
    }
    let has_support = binary_has_sighup_support(path);
    cache.insert(path.to_path_buf(), has_support);
    has_support
}

fn classify_process_readiness(
    process: &CodexProcess,
    binary_has_markers: bool,
    ack_ready: bool,
    is_app_server: bool,
    fresh_start_ready: bool,
) -> ProcessReadiness {
    let safe_target = if is_app_server {
        binary_has_markers
    } else {
        process_is_sighup_safe_target(process, binary_has_markers)
    };
    let hot_swap_ready = safe_target && (ack_ready || (is_app_server && fresh_start_ready));
    let reason = if !binary_has_markers {
        if is_app_server {
            "missing app-server SIGHUP hot-swap markers; restart using patched Codex app-server"
                .to_string()
        } else {
            "missing SIGHUP hot-swap markers; restart using patched Codex CLI".to_string()
        }
    } else if !(ack_ready || is_app_server && fresh_start_ready) {
        "SIGHUP markers present, but live process has not acknowledged a reload; swap is not verified"
            .to_string()
    } else if is_app_server && fresh_start_ready && !ack_ready {
        "SIGHUP markers present and app-server started after active auth was written".to_string()
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

fn app_server_started_after_auth_file(process: &CodexProcess, auth_path: &Path) -> bool {
    let Some(auth_mtime) = auth_file_mtime_unix(auth_path) else {
        return false;
    };
    process_identity_is_current(process) && process.started_at_unix >= auth_mtime.saturating_sub(1)
}

fn auth_file_mtime_unix(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

#[cfg(test)]
fn parse_proc_stat_start_ticks(stat: &str) -> Option<u64> {
    let end_comm = stat.rfind(')')?;
    let fields = stat[end_comm + 1..].split_whitespace().collect::<Vec<_>>();
    fields.get(19)?.parse::<u64>().ok()
}

fn path_is_writable(path: &Path) -> bool {
    if path.exists() {
        return fs::OpenOptions::new().append(true).open(path).is_ok();
    }
    let Some(parent) = path.parent() else {
        return false;
    };
    if parent.exists() {
        return fs::metadata(parent)
            .map(|metadata| !metadata.permissions().readonly())
            .unwrap_or(false);
    }
    parent
        .parent()
        .and_then(|grandparent| fs::metadata(grandparent).ok())
        .map(|metadata| !metadata.permissions().readonly())
        .unwrap_or(false)
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
            && is_codexswitch_daemon_command_line(command_line)
    })
}

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
    use std::path::PathBuf;

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
    fn markers_without_live_ack_are_not_ready() {
        let readiness = classify_process_readiness(&process(), true, false, true, false);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("has not acknowledged a reload"));
    }

    #[test]
    fn markers_with_live_ack_are_ready() {
        let readiness = classify_process_readiness(&process(), true, true, true, false);

        assert!(readiness.hot_swap_ready);
        assert!(readiness.reason.contains("live reload acknowledged"));
    }

    #[test]
    fn fresh_app_server_start_after_auth_is_ready_without_ack() {
        let readiness = classify_process_readiness(&process(), true, false, true, true);

        assert!(readiness.hot_swap_ready);
        assert!(readiness.reason.contains("started after active auth"));
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

use crate::account_store::{active_account, is_immediately_usable, load_accounts};
use crate::reload::{
    binary_has_sighup_support, discover_codex_app_server_processes, discover_codex_cli_processes,
    process_has_current_hot_swap_ack, process_is_sighup_safe_target, CodexProcess,
};
use anyhow::{Context, Result};
use serde::Serialize;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

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
    let mut active_account_id = None;
    let mut ready_candidate_count = 0;
    let mut active_needs_swap = false;

    let accounts = match load_accounts(store_path) {
        Ok(accounts) => {
            account_count = accounts.len();
            if let Some(active) = active_account(&accounts) {
                active_email = Some(active.email.clone());
                active_account_id = Some(active.account_id.clone());
                active_needs_swap = active.runtime_unusable()
                    || active
                        .quota_snapshot
                        .as_ref()
                        .map(|snapshot| {
                            snapshot.five_hour.should_auto_swap_away()
                                || snapshot.weekly.should_auto_swap_away()
                        })
                        .unwrap_or(true);
            }
            ready_candidate_count = accounts
                .iter()
                .filter(|account| !account.is_active)
                .filter(|account| is_immediately_usable(account))
                .count();
            if accounts.is_empty() {
                issues.push("no accounts imported".to_string());
            }
            if active_email.is_none() {
                issues.push("no active account selected".to_string());
            }
            if active_needs_swap && ready_candidate_count == 0 {
                issues.push("active account needs swap but no ready candidate exists".to_string());
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
    let auth_account_id = read_auth_account_id(auth_path);
    let auth_matches_active = active_account_id
        .as_deref()
        .zip(auth_account_id.as_deref())
        .map(|(active, auth)| active == auth)
        .unwrap_or(false);
    if active_account_id.is_some() && !auth_matches_active {
        issues.push("auth.json does not match active account".to_string());
    }

    let daemon_running = daemon_is_running()?;
    if !daemon_running {
        issues.push("codexswitch daemon is not running".to_string());
    }

    let processes = discover_codex_cli_processes()?
        .into_iter()
        .map(|process| {
            let binary_has_markers = binary_has_sighup_support(&process.executable);
            let ack_ready = process_has_current_hot_swap_ack(process.pid, auth_path);
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
            let binary_has_markers = binary_has_sighup_support(&process.executable);
            let ack_ready = process_has_current_hot_swap_ack(process.pid, auth_path);
            let fresh_start_ready = app_server_started_after_auth_file(process.pid, auth_path);
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
        && !(active_needs_swap && ready_candidate_count == 0)
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

fn read_auth_account_id(path: &Path) -> Option<String> {
    let data = fs::read(path).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&data).ok()?;
    value
        .get("tokens")
        .and_then(|tokens| {
            tokens
                .get("account_id")
                .or_else(|| tokens.get("accountId"))
                .and_then(|account| account.as_str())
        })
        .map(ToString::to_string)
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
    } else if !ack_ready && !(is_app_server && fresh_start_ready) {
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

fn app_server_started_after_auth_file(pid: i32, auth_path: &Path) -> bool {
    let Some(auth_mtime) = auth_file_mtime_unix(auth_path) else {
        return false;
    };
    process_start_time_unix(pid).is_some_and(|started| started >= auth_mtime.saturating_sub(1))
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

fn process_start_time_unix(pid: i32) -> Option<u64> {
    let boot_time = proc_boot_time_unix()?;
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let start_ticks = parse_proc_stat_start_ticks(&stat)?;
    let ticks_per_second = clock_ticks_per_second()?;
    Some(boot_time + start_ticks / ticks_per_second)
}

fn parse_proc_stat_start_ticks(stat: &str) -> Option<u64> {
    let end_comm = stat.rfind(')')?;
    let fields = stat[end_comm + 1..].split_whitespace().collect::<Vec<_>>();
    fields.get(19)?.parse::<u64>().ok()
}

fn proc_boot_time_unix() -> Option<u64> {
    fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))
        .and_then(|value| value.trim().parse::<u64>().ok())
}

fn clock_ticks_per_second() -> Option<u64> {
    let ticks = unsafe { libc_sysconf_clk_tck() };
    (ticks > 0).then_some(ticks as u64)
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

fn daemon_is_running() -> Result<bool> {
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
        if command_line.contains("codexswitch-cli") && command_line.contains(" daemon") {
            return Ok(true);
        }
    }
    Ok(false)
}

unsafe fn libc_geteuid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    geteuid()
}

unsafe fn libc_sysconf_clk_tck() -> i64 {
    unsafe extern "C" {
        fn sysconf(name: i32) -> i64;
    }
    #[cfg(target_os = "linux")]
    const _SC_CLK_TCK: i32 = 2;
    #[cfg(not(target_os = "linux"))]
    const _SC_CLK_TCK: i32 = 3;
    sysconf(_SC_CLK_TCK)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn process() -> CodexProcess {
        CodexProcess {
            pid: 42,
            command_line: "/home/me/.local/share/codexswitch/patched-codex/codex app-server"
                .to_string(),
            executable: PathBuf::from("/home/me/.local/share/codexswitch/patched-codex/codex"),
        }
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
}

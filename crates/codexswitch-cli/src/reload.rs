use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexProcess {
    pub pid: i32,
    pub command_line: String,
    pub executable: PathBuf,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReloadSummary {
    pub signaled: Vec<i32>,
    pub restarted: Vec<i32>,
    pub skipped: Vec<(i32, String)>,
}

pub fn discover_codex_cli_processes() -> Result<Vec<CodexProcess>> {
    discover_codex_processes(false)
}

pub fn discover_codex_restart_targets(include_app_server: bool) -> Result<Vec<CodexProcess>> {
    discover_codex_processes(include_app_server)
}

pub fn discover_codex_app_server_processes() -> Result<Vec<CodexProcess>> {
    discover_codex_processes(true).map(|processes| {
        processes
            .into_iter()
            .filter(|process| is_codex_app_server_command_line(&process.command_line))
            .filter(|process| is_native_codex_runtime(&process.executable))
            .collect()
    })
}

fn discover_codex_processes(include_app_server: bool) -> Result<Vec<CodexProcess>> {
    let current_uid = unsafe { libc_geteuid() };
    let mut processes = Vec::new();
    for entry in fs::read_dir("/proc").context("failed to read /proc")? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
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

        let command_line = read_cmdline(&proc_dir.join("cmdline")).unwrap_or_default();
        if !is_codex_cli_command_line(&command_line)
            && !(include_app_server && is_codex_app_server_command_line(&command_line))
        {
            continue;
        }
        let executable_link = proc_dir.join("exe");
        let Ok(executable_target) = fs::read_link(&executable_link) else {
            continue;
        };
        let executable = if executable_target.to_string_lossy().ends_with(" (deleted)") {
            executable_link
        } else {
            executable_target
        };
        processes.push(CodexProcess {
            pid,
            command_line,
            executable,
        });
    }
    Ok(processes)
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RestartSummary {
    pub terminated: Vec<i32>,
    pub skipped: Vec<(i32, String)>,
}

pub fn restart_codex_processes(include_app_server: bool, yes: bool) -> Result<RestartSummary> {
    let targets = discover_codex_restart_targets(include_app_server)?;
    if !yes {
        let mut summary = RestartSummary::default();
        for process in targets {
            summary
                .skipped
                .push((process.pid, "dry run; pass --yes to terminate".to_string()));
        }
        return Ok(summary);
    }

    let mut summary = RestartSummary::default();
    for process in targets {
        let status = Command::new("kill")
            .arg("-TERM")
            .arg(process.pid.to_string())
            .status()
            .with_context(|| format!("failed to run kill for pid {}", process.pid))?;
        if !status.success() {
            summary
                .skipped
                .push((process.pid, format!("SIGTERM exited with {}", status)));
            continue;
        }

        if wait_for_exit(process.pid, Duration::from_secs(3)) {
            summary.terminated.push(process.pid);
            continue;
        }

        let status = Command::new("kill")
            .arg("-KILL")
            .arg(process.pid.to_string())
            .status()
            .with_context(|| format!("failed to run kill -9 for pid {}", process.pid))?;
        if status.success() && wait_for_exit(process.pid, Duration::from_secs(1)) {
            summary.terminated.push(process.pid);
        } else {
            summary.skipped.push((
                process.pid,
                "process did not exit after SIGKILL".to_string(),
            ));
        }
    }
    Ok(summary)
}

pub fn reload_codex_hot_swap_processes() -> Result<ReloadSummary> {
    reload_codex_processes(true)
}

pub fn reload_codex_cli_hot_swap_processes() -> Result<ReloadSummary> {
    reload_codex_processes(false)
}

pub fn discover_hot_swap_processes_missing_ack(
    include_app_server: bool,
) -> Result<Vec<CodexProcess>> {
    let mut missing = Vec::new();
    for process in discover_codex_restart_targets(include_app_server)? {
        let binary_has_markers = binary_has_sighup_support(&process.executable);
        if process_is_sighup_safe_target(&process, binary_has_markers)
            && !process_has_recent_hot_swap_ack(process.pid)
        {
            missing.push(process);
        }
    }
    Ok(missing)
}

pub fn discover_hot_swap_processes_missing_current_ack(
    include_app_server: bool,
    auth_path: &Path,
) -> Result<Vec<CodexProcess>> {
    let mut missing = Vec::new();
    for process in discover_codex_restart_targets(include_app_server)? {
        let binary_has_markers = binary_has_sighup_support(&process.executable);
        if process_is_sighup_safe_target(&process, binary_has_markers)
            && !process_has_current_hot_swap_ack(process.pid, auth_path)
        {
            missing.push(process);
        }
    }
    Ok(missing)
}

fn reload_codex_processes(include_app_server: bool) -> Result<ReloadSummary> {
    let mut summary = ReloadSummary::default();
    for process in discover_codex_restart_targets(include_app_server)? {
        let binary_has_markers = binary_has_sighup_support(&process.executable);
        if !binary_has_markers {
            summary
                .skipped
                .push((process.pid, "missing SIGHUP hot-swap markers".to_string()));
            continue;
        }
        let sent_at = current_unix_timestamp();
        let status = Command::new("kill")
            .arg("-HUP")
            .arg(process.pid.to_string())
            .status()
            .with_context(|| format!("failed to run kill for pid {}", process.pid))?;
        if status.success() {
            if wait_for_hot_swap_ack(process.pid, sent_at, Duration::from_secs(3)) {
                summary.signaled.push(process.pid);
            } else if should_restart_app_server_after_failed_ack(&process.command_line)
                && restart_managed_app_server_service()
            {
                summary.restarted.push(process.pid);
            } else {
                summary.skipped.push((
                    process.pid,
                    "SIGHUP sent but live reload acknowledgement was not observed".to_string(),
                ));
            }
        } else {
            summary
                .skipped
                .push((process.pid, format!("kill exited with {}", status)));
        }
    }
    Ok(summary)
}

fn should_restart_app_server_after_failed_ack(command_line: &str) -> bool {
    cfg!(target_os = "linux") && is_codex_app_server_command_line(command_line)
}

fn restart_managed_app_server_service() -> bool {
    if !cfg!(target_os = "linux") || !managed_app_server_service_is_active() {
        return false;
    }
    Command::new("systemctl")
        .arg("--user")
        .arg("restart")
        .arg("signul-codex-app-server.service")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
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

pub fn binary_has_sighup_support(path: &Path) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    contains_bytes(&data, b"sighup-verified")
        && contains_bytes(&data, b"SIGHUP: auth reloaded")
        && contains_bytes(&data, b"hotswap-ack")
        && contains_bytes(&data, b"CodexSwitch rotated accounts after a usage limit")
        && contains_bytes(
            &data,
            b"Auth changed, opening new WebSocket with fresh credentials",
        )
        && binary_data_has_goal_support(&data)
}

fn binary_data_has_goal_support(data: &[u8]) -> bool {
    contains_bytes(data, b"Usage: /goal <objective>")
        || (contains_bytes(data, b"Pursuing goal") && contains_bytes(data, b"thread/goal/set"))
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HotSwapAck {
    pub pid: i32,
    pub timestamp_unix: u64,
    #[serde(default)]
    pub loaded_auth_hash: Option<String>,
    #[serde(default)]
    pub active_auth_hash: Option<String>,
}

pub fn process_has_recent_hot_swap_ack(pid: i32) -> bool {
    let Some(path) = hot_swap_ack_path(pid) else {
        return false;
    };
    hot_swap_ack_is_recent_verified_for_pid(
        &path,
        pid,
        current_unix_timestamp(),
        Duration::from_secs(5 * 60),
    )
}

pub fn process_has_current_hot_swap_ack(pid: i32, auth_path: &Path) -> bool {
    let Some(path) = hot_swap_ack_path(pid) else {
        return false;
    };
    let required_since = auth_file_mtime_unix(auth_path)
        .unwrap_or(0)
        .saturating_sub(1);
    hot_swap_ack_is_verified_for_pid(&path, pid, current_unix_timestamp())
        && hot_swap_ack_timestamp(&path).is_some_and(|timestamp| timestamp >= required_since)
}

fn process_has_hot_swap_ack_since(pid: i32, since: u64) -> bool {
    let Some(path) = hot_swap_ack_path(pid) else {
        return false;
    };
    hot_swap_ack_is_recent_verified_for_pid(
        &path,
        pid,
        current_unix_timestamp(),
        Duration::from_secs(5 * 60),
    ) && hot_swap_ack_timestamp(&path).is_some_and(|timestamp| timestamp >= since)
}

fn hot_swap_ack_path(pid: i32) -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".codexswitch")
            .join("hotswap-ack")
            .join(format!("{pid}.json"))
    })
}

fn hot_swap_ack_is_recent_for_pid(path: &Path, pid: i32, now: u64, max_age: Duration) -> bool {
    let Some(ack) = read_hot_swap_ack(path) else {
        return false;
    };
    if ack.pid != pid {
        return false;
    }
    let max_age = max_age.as_secs();
    now >= ack.timestamp_unix && now.saturating_sub(ack.timestamp_unix) <= max_age
}

fn hot_swap_ack_is_recent_verified_for_pid(
    path: &Path,
    pid: i32,
    now: u64,
    max_age: Duration,
) -> bool {
    if !hot_swap_ack_is_recent_for_pid(path, pid, now, max_age) {
        return false;
    }
    hot_swap_ack_is_verified_for_pid(path, pid, now)
}

fn hot_swap_ack_is_verified_for_pid(path: &Path, pid: i32, now: u64) -> bool {
    let Some(ack) = read_hot_swap_ack(path) else {
        return false;
    };
    if ack.pid != pid {
        return false;
    }
    if ack.timestamp_unix > now.saturating_add(60) {
        return false;
    }
    let Some(loaded) = ack.loaded_auth_hash.as_deref() else {
        return false;
    };
    let Some(active) = ack.active_auth_hash.as_deref() else {
        return false;
    };
    !loaded.is_empty() && loaded == active
}

fn hot_swap_ack_timestamp(path: &Path) -> Option<u64> {
    read_hot_swap_ack(path).map(|ack| ack.timestamp_unix)
}

fn auth_file_mtime_unix(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

fn read_hot_swap_ack(path: &Path) -> Option<HotSwapAck> {
    let data = fs::read_to_string(path).ok()?;
    serde_json::from_str::<HotSwapAck>(&data).ok()
}

fn wait_for_hot_swap_ack(pid: i32, since: u64, timeout: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if process_has_hot_swap_ack_since(pid, since) {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    process_has_hot_swap_ack_since(pid, since)
}

pub fn process_is_sighup_safe_target(process: &CodexProcess, binary_has_markers: bool) -> bool {
    if !binary_has_markers {
        return false;
    }
    is_codex_cli_command_line(&process.command_line)
        || is_codex_app_server_command_line(&process.command_line)
}

pub fn is_codex_cli_command_line(command_line: &str) -> bool {
    let lower = command_line.to_ascii_lowercase();
    if !lower.contains("codex") {
        return false;
    }

    let excluded = [
        "codexswitch-cli",
        " app-server",
        "strings ",
        "/strings ",
        "rg ",
        "grep ",
        "git-ai checkpoint codex",
        "headroom wrap codex",
        "chrome_crashpad_handler",
        "codex helper",
        " --remote ",
    ];
    if excluded.iter().any(|fragment| lower.contains(fragment)) {
        return false;
    }

    if first_command_token_is_native_codex(&lower) {
        return true;
    }

    lower.contains("/developer/codex/codex-rs/target/release/codex")
        || lower.contains("/opt/homebrew/bin/codex")
        || lower.contains("/usr/local/bin/codex")
        || lower.contains("/.npm/")
        || lower.contains("/node_modules/@openai/codex/")
        || lower.ends_with("/codex")
        || lower.starts_with("codex ")
        || lower == "codex"
}

pub fn is_codex_app_server_command_line(command_line: &str) -> bool {
    let lower = command_line.to_ascii_lowercase();
    if lower.contains("strings ") || lower.contains("/strings ") {
        return false;
    }
    if !lower.contains("codex")
        || lower.contains("codexswitch-cli")
        || lower.contains("grep ")
        || lower.contains("rg ")
    {
        return false;
    }
    let parts = lower.split_whitespace().collect::<Vec<_>>();
    parts.iter().enumerate().any(|(index, part)| {
        if *part != "app-server" {
            return false;
        }
        parts[index + 1..]
            .windows(2)
            .any(|window| window[0] == "--listen" && !window[1].starts_with("unix://"))
    })
}

fn first_command_token_is_native_codex(command_line: &str) -> bool {
    command_line
        .split_whitespace()
        .next()
        .and_then(|first| first.rsplit('/').next())
        .is_some_and(|name| name == "codex" || name == "exe")
}

fn is_native_codex_runtime(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == "codex" || name == "exe")
}

fn wait_for_exit(pid: i32, timeout: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if !PathBuf::from(format!("/proc/{pid}")).exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    !PathBuf::from(format!("/proc/{pid}")).exists()
}

fn read_cmdline(path: &Path) -> Result<String> {
    let data = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    Ok(String::from_utf8_lossy(&data)
        .split('\0')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" "))
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn current_unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
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

    #[test]
    fn command_line_detection_excludes_helpers() {
        assert!(!is_codex_cli_command_line(
            "/Applications/Codex.app/Contents/Resources/codex app-server"
        ));
        assert!(is_codex_app_server_command_line(
            "/usr/bin/codex app-server --listen ws://127.0.0.1:8390"
        ));
        assert!(is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server --listen ws://127.0.0.1:8390"
        ));
        assert!(is_codex_app_server_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex app-server --remote-control --listen ws://127.0.0.1:8390"
        ));
        assert!(!is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server --listen unix://"
        ));
        assert!(!is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server proxy"
        ));
        assert!(!is_codex_cli_command_line(
            "/usr/bin/x86_64-linux-gnu-strings /home/me/.local/share/codexswitch/patched-codex/codex"
        ));
        assert!(!is_codex_cli_command_line(
            "/Users/me/.git-ai/bin/git-ai checkpoint codex --hook-input stdin"
        ));
        assert!(is_codex_cli_command_line(
            "/home/me/Developer/codex/codex-rs/target/release/codex resume abc"
        ));
        assert!(is_codex_cli_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex --yolo"
        ));
        assert!(is_codex_cli_command_line(
            "/home/me/.npm/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/codex/codex"
        ));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn failed_ack_app_server_is_restart_candidate_on_linux() {
        assert!(should_restart_app_server_after_failed_ack(
            "/home/signul/.local/share/codexswitch/patched-codex/codex app-server --remote-control --listen ws://127.0.0.1:8390"
        ));
        assert!(!should_restart_app_server_after_failed_ack(
            "/home/signul/.local/share/codexswitch/patched-codex/codex --yolo"
        ));
    }

    #[test]
    fn app_server_readiness_ignores_node_launcher_runtime() {
        assert!(!is_native_codex_runtime(Path::new("/usr/bin/node")));
        assert!(is_native_codex_runtime(Path::new(
            "/usr/lib/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/codex/codex"
        )));
        assert!(is_native_codex_runtime(Path::new("/proc/123/exe")));
    }

    #[test]
    fn interactive_terminal_cli_processes_are_sighup_safe() {
        let process = CodexProcess {
            pid: 42,
            command_line: "/home/me/.local/share/codexswitch/patched-codex/codex".to_string(),
            executable: PathBuf::from("/home/me/.local/share/codexswitch/patched-codex/codex"),
        };

        assert!(process_is_sighup_safe_target(&process, true));
    }

    #[test]
    fn shell_wrappers_are_not_codex_cli_processes() {
        assert!(!is_codex_cli_command_line("/bin/zsh -lc codex-vps"));
        assert!(!is_codex_cli_command_line(
            "SIGNUL_CANARY_ACTOR=codex-vps bash -lc codex"
        ));
        assert!(!is_codex_cli_command_line("ssh signul-vps codex"));
        assert!(!is_codex_cli_command_line(
            "/home/me/Developer/codex/codex-rs/target/release/codex --remote ws://127.0.0.1:18390 resume abc"
        ));
    }

    #[test]
    fn hot_swap_ack_requires_matching_pid_and_fresh_timestamp() {
        let dir = tempfile::tempdir().unwrap();
        let ack_path = dir.path().join("42.json");
        fs::write(
            &ack_path,
            r#"{"pid":42,"timestampUnix":1000,"loadedAuthHash":"abc","activeAuthHash":"abc"}"#,
        )
        .unwrap();

        assert!(hot_swap_ack_is_recent_for_pid(
            &ack_path,
            42,
            1100,
            Duration::from_secs(300)
        ));
        assert!(!hot_swap_ack_is_recent_for_pid(
            &ack_path,
            99,
            1100,
            Duration::from_secs(300)
        ));
        assert!(!hot_swap_ack_is_recent_for_pid(
            &ack_path,
            42,
            1401,
            Duration::from_secs(300)
        ));
        assert!(hot_swap_ack_timestamp(&ack_path).is_some_and(|timestamp| timestamp == 1000));
    }

    #[test]
    fn recent_hot_swap_ack_requires_matching_non_null_auth_hashes() {
        let dir = tempfile::tempdir().unwrap();
        let ack_path = dir.path().join("42.json");
        fs::write(
            &ack_path,
            r#"{"pid":42,"timestampUnix":1000,"loadedAuthHash":null,"activeAuthHash":null}"#,
        )
        .unwrap();

        assert!(hot_swap_ack_is_recent_for_pid(
            &ack_path,
            42,
            1001,
            Duration::from_secs(300)
        ));
        assert!(!hot_swap_ack_is_recent_verified_for_pid(
            &ack_path,
            42,
            1001,
            Duration::from_secs(300)
        ));

        fs::write(
            &ack_path,
            r#"{"pid":42,"timestampUnix":1002,"loadedAuthHash":"old","activeAuthHash":"new"}"#,
        )
        .unwrap();
        assert!(!hot_swap_ack_is_recent_verified_for_pid(
            &ack_path,
            42,
            1003,
            Duration::from_secs(300)
        ));

        fs::write(
            &ack_path,
            r#"{"pid":42,"timestampUnix":1004,"loadedAuthHash":"new","activeAuthHash":"new"}"#,
        )
        .unwrap();
        assert!(hot_swap_ack_is_recent_verified_for_pid(
            &ack_path,
            42,
            1005,
            Duration::from_secs(300)
        ));
    }

    #[test]
    fn verified_hot_swap_ack_can_be_old_when_auth_has_not_changed() {
        let dir = tempfile::tempdir().unwrap();
        let ack_path = dir.path().join("42.json");
        fs::write(
            &ack_path,
            r#"{"pid":42,"timestampUnix":1000,"loadedAuthHash":"new","activeAuthHash":"new"}"#,
        )
        .unwrap();

        assert!(!hot_swap_ack_is_recent_verified_for_pid(
            &ack_path,
            42,
            1401,
            Duration::from_secs(300)
        ));
        assert!(hot_swap_ack_is_verified_for_pid(&ack_path, 42, 1401));
        assert!(hot_swap_ack_timestamp(&ack_path).is_some_and(|timestamp| timestamp >= 999));
        assert!(!hot_swap_ack_timestamp(&ack_path).is_some_and(|timestamp| timestamp >= 1001));
    }

    #[test]
    fn sighup_support_requires_usage_limit_retry_marker() {
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("codex");
        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nAuth changed, opening new WebSocket with fresh credentials\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nAuth changed, opening new WebSocket with fresh credentials\nUsage: /goal <objective>\n",
        )
        .unwrap();
        assert!(binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nAuth changed, opening new WebSocket with fresh credentials\nPursuing goal\nthread/goal/set\n",
        )
        .unwrap();
        assert!(binary_has_sighup_support(&binary));
    }
}

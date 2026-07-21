#[cfg(test)]
use crate::auth::auth_file_fingerprint;
#[cfg(not(target_os = "linux"))]
use crate::bounded_command;
use anyhow::{bail, Context, Result};
#[cfg(not(target_os = "linux"))]
use chrono::{Local, NaiveDateTime, TimeZone};
use ring::digest::{Context as DigestContext, SHA256};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::{Read, Write};
#[cfg(target_os = "macos")]
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
#[cfg(not(target_os = "linux"))]
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexProcess {
    pub pid: i32,
    pub owner_uid: u32,
    pub start_identity: String,
    pub started_at_unix: u64,
    pub command_line: String,
    pub executable: PathBuf,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReloadSummary {
    pub sighup_sent: Vec<i32>,
    pub signaled: Vec<i32>,
    pub restarted: Vec<i32>,
    pub skipped: Vec<(i32, String)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReloadConvergence {
    VerifiedHotSwap,
    NoRuntimeTargets,
    Incomplete,
}

impl ReloadSummary {
    pub fn convergence(&self) -> ReloadConvergence {
        if !self.signaled.is_empty() && self.skipped.is_empty() {
            ReloadConvergence::VerifiedHotSwap
        } else if self.signaled.is_empty() && self.restarted.is_empty() && self.skipped.is_empty() {
            ReloadConvergence::NoRuntimeTargets
        } else {
            ReloadConvergence::Incomplete
        }
    }

    pub fn verified_hot_swap(&self) -> bool {
        self.convergence() == ReloadConvergence::VerifiedHotSwap
    }
}

const BINARY_MARKER_SCAN_CHUNK_BYTES: usize = 128 * 1024;
const BINARY_MARKER_SCAN_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const COMMON_SIGHUP_MARKERS: [&[u8]; 8] = [
    b"sighup-verified",
    b"SIGHUP: auth reloaded",
    b"hotswap-ack",
    b"CodexSwitch rotated accounts after a usage limit",
    b"CodexSwitch rotated accounts after an auth failure",
    b"Auth changed, opening new WebSocket with fresh credentials",
    b"codexswitch-runtime-convergence-v3",
    b"codexswitch-runtime-rotation-handoff-v1",
];
const EXTERNAL_APP_SERVER_MARKERS: [&[u8]; 2] = [
    b"CodexSwitch account/updated frontend write acknowledged after auth reload",
    b"codexswitch-hotswap-contract-v3",
];
const HEADLESS_REMOTE_CONTROL_APP_SERVER_MARKERS: [&[u8]; 1] =
    [b"codexswitch-hotswap-headless-idle-v1"];
const LOCAL_INTERACTIVE_CLI_MARKERS: [&[u8]; 1] = [b"codexswitch-hotswap-cli-contract-v3"];
const GOAL_USAGE_MARKER: &[u8] = b"Usage: /goal <objective>";
const GOAL_PURSUING_MARKER: &[u8] = b"Pursuing goal";
const GOAL_SET_MARKER: &[u8] = b"thread/goal/set";
const HOT_SWAP_ARTIFACT_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const HOT_SWAP_ARTIFACT_MAX_SCAN: usize = 20_000;
const HOT_SWAP_ARTIFACT_MAX_REMOVALS: usize = 2_048;
const HOT_SWAP_ARTIFACT_MAX_COUNT: usize = 512;
const HOT_SWAP_ARTIFACT_MAX_TOTAL_BYTES: u64 = 4 * 1024 * 1024;
const HOT_SWAP_ARTIFACT_MAX_SCAN_TIME: Duration = Duration::from_millis(250);
const HOT_SWAP_ARTIFACT_MAX_METADATA_BYTES: usize = 2 * 1024 * 1024;
const HOT_SWAP_ACK_MAX_BYTES: u64 = 64 * 1024;
const HOT_SWAP_REQUEST_MAX_BYTES: usize = 16 * 1024;
pub(crate) const HOT_SWAP_REQUEST_CONTRACT_VERSION: u8 = 3;
const HOT_SWAP_AUTH_PATH_MAX_BYTES: usize = 4_096;
const HOT_SWAP_ACCOUNT_ID_MAX_BYTES: usize = 1_024;
const HOT_SWAP_NONCE_MAX_BYTES: usize = 256;
const HOT_SWAP_AUTH_FILE_MAX_BYTES: u64 = 1024 * 1024;

#[derive(Clone, Copy)]
struct HotSwapArtifactRetention {
    max_age: Duration,
    max_scan: usize,
    max_removals: usize,
    max_count: usize,
    max_total_bytes: u64,
    max_scan_time: Duration,
    max_metadata_bytes: usize,
}

const HOT_SWAP_ARTIFACT_RETENTION: HotSwapArtifactRetention = HotSwapArtifactRetention {
    max_age: HOT_SWAP_ARTIFACT_MAX_AGE,
    max_scan: HOT_SWAP_ARTIFACT_MAX_SCAN,
    max_removals: HOT_SWAP_ARTIFACT_MAX_REMOVALS,
    max_count: HOT_SWAP_ARTIFACT_MAX_COUNT,
    max_total_bytes: HOT_SWAP_ARTIFACT_MAX_TOTAL_BYTES,
    max_scan_time: HOT_SWAP_ARTIFACT_MAX_SCAN_TIME,
    max_metadata_bytes: HOT_SWAP_ARTIFACT_MAX_METADATA_BYTES,
};
#[cfg(not(target_os = "linux"))]
const PS_COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
static HOT_SWAP_REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "kebab-case")]
pub enum HotSwapRuntimeKind {
    ExternalAppServer,
    HeadlessRemoteControlAppServer,
    LocalInteractiveCli,
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
    discover_codex_processes_platform(include_app_server)
}

fn process_matches_discovery_scope(process: &CodexProcess, include_app_server: bool) -> bool {
    is_codex_cli_runtime(&process.command_line, &process.executable)
        || (include_app_server
            && is_native_codex_runtime(&process.executable)
            && is_codex_app_server_command_line(&process.command_line))
}

#[cfg(target_os = "linux")]
fn discover_codex_processes_platform(include_app_server: bool) -> Result<Vec<CodexProcess>> {
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
        let Some(process) = read_linux_process_identity(pid) else {
            continue;
        };
        if process.owner_uid != current_uid {
            continue;
        }
        if !process_matches_discovery_scope(&process, include_app_server) {
            continue;
        }
        processes.push(process);
    }
    Ok(processes)
}

#[cfg(target_os = "linux")]
fn read_linux_process_identity(pid: i32) -> Option<CodexProcess> {
    let proc_dir = PathBuf::from(format!("/proc/{pid}"));
    let owner_uid = fs::metadata(&proc_dir).ok()?.uid();
    let command_line = read_cmdline(&proc_dir.join("cmdline")).ok()?;
    let executable_link = proc_dir.join("exe");
    let executable_target = fs::read_link(&executable_link).ok()?;
    let executable = if executable_target.to_string_lossy().ends_with(" (deleted)") {
        executable_link
    } else {
        executable_target
    };
    let stat = fs::read_to_string(proc_dir.join("stat")).ok()?;
    let after_command = stat.get(stat.rfind(')')? + 1..)?.trim_start();
    let start_ticks = after_command
        .split_whitespace()
        .nth(19)?
        .parse::<u64>()
        .ok()?;
    let boot_time = fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))?
        .parse::<u64>()
        .ok()?;
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks_per_second <= 0 {
        return None;
    }
    Some(CodexProcess {
        pid,
        owner_uid,
        start_identity: format!("linux:{start_ticks}"),
        started_at_unix: boot_time.saturating_add(start_ticks / ticks_per_second as u64),
        command_line,
        executable,
    })
}

#[cfg(not(target_os = "linux"))]
fn discover_codex_processes_platform(include_app_server: bool) -> Result<Vec<CodexProcess>> {
    let current_uid = unsafe { libc_geteuid() };
    let output = bounded_command::output(
        Command::new("/bin/ps").args(["-axo", "pid=,uid=,lstart=,command=", "-ww"]),
        PS_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .context("failed to run ps for Codex process discovery")?;
    if !output.status.success() {
        bail!("ps exited with {}", output.status);
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let processes = parse_ps_processes(
        &stdout,
        include_app_server,
        current_uid,
        std::process::id() as i32,
    );
    #[cfg(target_os = "macos")]
    {
        Ok(processes
            .into_iter()
            .filter_map(enrich_macos_process_identity)
            .filter(|process| process_matches_discovery_scope(process, include_app_server))
            .collect())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(processes)
    }
}

#[cfg(not(target_os = "linux"))]
fn parse_ps_processes(
    ps_output: &str,
    include_app_server: bool,
    current_uid: u32,
    current_pid: i32,
) -> Vec<CodexProcess> {
    let mut processes = Vec::new();
    for line in ps_output.lines() {
        let Some((pid_text, rest)) = split_first_field(line) else {
            continue;
        };
        let Ok(pid) = pid_text.parse::<i32>() else {
            continue;
        };
        if pid == current_pid {
            continue;
        }
        let Some((uid_text, rest)) = split_first_field(rest) else {
            continue;
        };
        let Ok(uid) = uid_text.parse::<u32>() else {
            continue;
        };
        if uid != current_uid {
            continue;
        }
        let Some((start_identity, command_line)) = split_ps_start_and_command(rest) else {
            continue;
        };
        let Some(started_at_unix) = parse_ps_start_unix(&start_identity) else {
            continue;
        };
        let Some(executable) = executable_from_command_line(command_line) else {
            continue;
        };
        let process = CodexProcess {
            pid,
            owner_uid: uid,
            start_identity,
            started_at_unix,
            command_line: command_line.to_string(),
            executable,
        };
        if process_matches_discovery_scope(&process, include_app_server) {
            processes.push(process);
        }
    }
    processes
}

#[cfg(not(target_os = "linux"))]
fn split_ps_start_and_command(input: &str) -> Option<(String, &str)> {
    let mut rest = input;
    let mut parts = Vec::with_capacity(5);
    for _ in 0..5 {
        let (part, next) = split_first_field(rest)?;
        parts.push(part);
        rest = next;
    }
    (!rest.is_empty()).then(|| (parts.join(" "), rest))
}

#[cfg(not(target_os = "linux"))]
fn parse_ps_start_unix(value: &str) -> Option<u64> {
    let naive = NaiveDateTime::parse_from_str(value, "%a %b %e %T %Y").ok()?;
    let timestamp = Local.from_local_datetime(&naive).single()?.timestamp();
    u64::try_from(timestamp).ok()
}

#[cfg(target_os = "linux")]
fn current_process_identity(pid: i32) -> Option<CodexProcess> {
    read_linux_process_identity(pid)
}

#[cfg(not(target_os = "linux"))]
fn current_process_identity(pid: i32) -> Option<CodexProcess> {
    let output = bounded_command::output(
        Command::new("/bin/ps").args([
            "-p",
            &pid.to_string(),
            "-o",
            "pid=,uid=,lstart=,command=",
            "-ww",
        ]),
        PS_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let process = parse_ps_processes(
        &String::from_utf8_lossy(&output.stdout),
        true,
        unsafe { libc_geteuid() },
        std::process::id() as i32,
    )
    .into_iter()
    .find(|process| process.pid == pid)?;
    #[cfg(target_os = "macos")]
    {
        enrich_macos_process_identity(process)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Some(process)
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, PartialEq, Eq)]
struct MacKernelProcessIdentity {
    pid: u32,
    owner_uid: u32,
    start_seconds: u64,
    start_microseconds: u64,
    executable: PathBuf,
}

#[cfg(target_os = "macos")]
fn read_macos_kernel_process_identity(pid: i32) -> Option<MacKernelProcessIdentity> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let expected_size = std::mem::size_of::<libc::proc_bsdinfo>();
    let bytes = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            expected_size as libc::c_int,
        )
    };
    if bytes != expected_size as libc::c_int {
        return None;
    }
    let info = unsafe { info.assume_init() };
    if info.pbi_pid != pid as u32 {
        return None;
    }

    let mut executable = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let executable_bytes =
        unsafe { libc::proc_pidpath(pid, executable.as_mut_ptr().cast(), executable.len() as u32) };
    if executable_bytes <= 0 {
        return None;
    }
    let executable_len = executable
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(executable_bytes as usize)
        .min(executable_bytes as usize)
        .min(executable.len());
    if executable_len == 0 {
        return None;
    }
    let executable = PathBuf::from(std::ffi::OsStr::from_bytes(&executable[..executable_len]));
    Some(MacKernelProcessIdentity {
        pid: info.pbi_pid,
        owner_uid: info.pbi_uid,
        start_seconds: info.pbi_start_tvsec,
        start_microseconds: info.pbi_start_tvusec,
        executable,
    })
}

#[cfg(target_os = "macos")]
fn apply_macos_kernel_process_identity(
    mut process: CodexProcess,
    identity: &MacKernelProcessIdentity,
) -> Option<CodexProcess> {
    if identity.pid != process.pid as u32 || identity.owner_uid != process.owner_uid {
        return None;
    }
    process.start_identity = format!(
        "macos:{}:{:06}",
        identity.start_seconds, identity.start_microseconds
    );
    process.started_at_unix = identity.start_seconds;
    process.executable = identity.executable.clone();
    Some(process)
}

#[cfg(target_os = "macos")]
fn enrich_macos_process_identity(process: CodexProcess) -> Option<CodexProcess> {
    let identity = read_macos_kernel_process_identity(process.pid)?;
    apply_macos_kernel_process_identity(process, &identity)
}

fn process_identity_matches(expected: &CodexProcess, observed: &CodexProcess) -> bool {
    expected.pid == observed.pid
        && expected.owner_uid == observed.owner_uid
        && expected.start_identity == observed.start_identity
        && expected.started_at_unix == observed.started_at_unix
        && expected.executable == observed.executable
        && expected.command_line == observed.command_line
}

pub(crate) fn process_identity_is_current(expected: &CodexProcess) -> bool {
    current_process_identity(expected.pid)
        .as_ref()
        .is_some_and(|observed| process_identity_matches(expected, observed))
}

#[cfg(not(target_os = "linux"))]
fn split_first_field(input: &str) -> Option<(&str, &str)> {
    let trimmed = input.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let end = trimmed
        .find(|character: char| character.is_whitespace())
        .unwrap_or(trimmed.len());
    Some((&trimmed[..end], trimmed[end..].trim_start()))
}

#[cfg(not(target_os = "linux"))]
fn executable_from_command_line(command_line: &str) -> Option<PathBuf> {
    command_line
        .split_whitespace()
        .next()
        .filter(|first| first.starts_with('/'))
        .map(PathBuf::from)
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RestartSummary {
    pub terminated: Vec<i32>,
    pub skipped: Vec<(i32, String)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProcessWaitOutcome {
    Exited,
    IdentityChanged,
    TimedOut,
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

    Ok(restart_discovered_processes_with(
        targets,
        current_process_identity,
        send_signal,
        wait_for_process_exit,
    ))
}

fn restart_discovered_processes_with<I, S, W>(
    targets: Vec<CodexProcess>,
    mut current_identity: I,
    mut signal: S,
    mut wait_for_exit: W,
) -> RestartSummary
where
    I: FnMut(i32) -> Option<CodexProcess>,
    S: FnMut(i32, i32) -> std::io::Result<()>,
    W: FnMut(&CodexProcess, Duration) -> ProcessWaitOutcome,
{
    let mut summary = RestartSummary::default();
    for process in targets {
        let Some(observed) = current_identity(process.pid) else {
            summary.skipped.push((
                process.pid,
                "process disappeared before SIGTERM; no signal was sent".to_string(),
            ));
            continue;
        };
        if !process_identity_matches(&process, &observed) {
            summary.skipped.push((
                process.pid,
                "process identity changed before SIGTERM; refusing to signal reused pid"
                    .to_string(),
            ));
            continue;
        }
        if let Err(error) = signal(process.pid, libc::SIGTERM) {
            summary.skipped.push((
                process.pid,
                format!("SIGTERM failed for validated process identity: {error}"),
            ));
            continue;
        }

        match wait_for_exit(&process, Duration::from_secs(3)) {
            ProcessWaitOutcome::Exited => {
                summary.terminated.push(process.pid);
                continue;
            }
            ProcessWaitOutcome::IdentityChanged => {
                summary.skipped.push((
                    process.pid,
                    "process identity changed after SIGTERM; refusing to signal reused pid"
                        .to_string(),
                ));
                continue;
            }
            ProcessWaitOutcome::TimedOut => {}
        }

        let Some(observed) = current_identity(process.pid) else {
            summary.terminated.push(process.pid);
            continue;
        };
        if !process_identity_matches(&process, &observed) {
            summary.skipped.push((
                process.pid,
                "process identity changed before SIGKILL; refusing to signal reused pid"
                    .to_string(),
            ));
            continue;
        }
        if let Err(error) = signal(process.pid, libc::SIGKILL) {
            summary.skipped.push((
                process.pid,
                format!("SIGKILL failed for validated process identity: {error}"),
            ));
            continue;
        }
        match wait_for_exit(&process, Duration::from_secs(1)) {
            ProcessWaitOutcome::Exited => summary.terminated.push(process.pid),
            ProcessWaitOutcome::IdentityChanged => summary.skipped.push((
                process.pid,
                "pid was reused after SIGKILL; termination could not be attributed".to_string(),
            )),
            ProcessWaitOutcome::TimedOut => summary.skipped.push((
                process.pid,
                "validated process did not exit after SIGKILL".to_string(),
            )),
        }
    }
    summary
}

fn send_signal(pid: i32, signal: i32) -> std::io::Result<()> {
    let status = unsafe { libc::kill(pid, signal) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

pub fn reload_codex_hot_swap_processes(auth_path: &Path) -> Result<ReloadSummary> {
    reload_codex_processes(true, auth_path)
}

pub fn reload_codex_cli_hot_swap_processes(auth_path: &Path) -> Result<ReloadSummary> {
    reload_codex_processes(false, auth_path)
}

pub fn discover_hot_swap_processes_missing_current_ack(
    include_app_server: bool,
    auth_path: &Path,
) -> Result<Vec<CodexProcess>> {
    let mut missing = Vec::new();
    for process in discover_codex_restart_targets(include_app_server)? {
        let Some(runtime_kind) = hot_swap_runtime_kind(&process) else {
            continue;
        };
        let binary_has_markers =
            binary_has_sighup_support_for_runtime(&process.executable, runtime_kind);
        if process_is_sighup_safe_target(&process, binary_has_markers)
            && !process_has_current_hot_swap_ack_for_runtime(&process, auth_path, runtime_kind)
        {
            missing.push(process);
        }
    }
    Ok(missing)
}

fn reload_codex_processes(include_app_server: bool, auth_path: &Path) -> Result<ReloadSummary> {
    let mut summary = ReloadSummary::default();
    let processes = discover_codex_restart_targets(include_app_server)?;
    let protected_pids = processes
        .iter()
        .filter_map(|process| u32::try_from(process.pid).ok())
        .collect::<HashSet<_>>();
    if let Some(root) = default_codexswitch_data_path() {
        prune_hot_swap_artifacts_at(
            &root,
            SystemTime::now(),
            HOT_SWAP_ARTIFACT_RETENTION,
            &protected_pids,
        )?;
    }
    let auth_path = absolute_auth_path(auth_path)?;
    for process in processes {
        let Some(runtime_kind) = hot_swap_runtime_kind(&process) else {
            summary
                .skipped
                .push((process.pid, "unsupported Codex runtime kind".to_string()));
            continue;
        };
        let binary_has_markers =
            binary_has_sighup_support_for_runtime(&process.executable, runtime_kind);
        if !binary_has_markers {
            summary.skipped.push((
                process.pid,
                "missing runtime-specific SIGHUP hot-swap markers".to_string(),
            ));
            continue;
        }
        let request = match write_hot_swap_request(&process, &auth_path, runtime_kind) {
            Ok(request) => request,
            Err(error) => {
                summary.skipped.push((
                    process.pid,
                    format!("failed to create convergence-v3 SIGHUP request: {error}"),
                ));
                continue;
            }
        };
        if let Some(ack_path) = hot_swap_ack_path(process.pid) {
            let _ = fs::remove_file(ack_path);
        }
        if !process_identity_is_current(&process) {
            summary.skipped.push((
                process.pid,
                "process identity changed before SIGHUP; refusing to signal reused pid".to_string(),
            ));
            continue;
        }
        let signal_result = send_signal(process.pid, libc::SIGHUP);
        if signal_result.is_ok() {
            summary.sighup_sent.push(process.pid);
            if wait_for_hot_swap_ack(&process, &request, runtime_kind, Duration::from_secs(5)) {
                summary.signaled.push(process.pid);
            } else {
                summary.skipped.push((
                    process.pid,
                    "SIGHUP sent but live reload acknowledgement was not observed".to_string(),
                ));
            }
        } else {
            summary.skipped.push((
                process.pid,
                format!(
                    "SIGHUP failed after final process identity validation: {}",
                    signal_result.expect_err("checked above")
                ),
            ));
        }
    }
    Ok(summary)
}

#[cfg(test)]
fn binary_has_sighup_support(path: &Path) -> bool {
    binary_has_sighup_support_for_runtime(path, HotSwapRuntimeKind::ExternalAppServer)
        && binary_has_sighup_support_for_runtime(
            path,
            HotSwapRuntimeKind::HeadlessRemoteControlAppServer,
        )
        && binary_has_sighup_support_for_runtime(path, HotSwapRuntimeKind::LocalInteractiveCli)
}

pub fn binary_has_sighup_support_for_runtime(
    path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    if is_deleted_proc_exe_path(path) {
        return false;
    }
    if fs::metadata(path)
        .map(|metadata| metadata.len() > BINARY_MARKER_SCAN_MAX_BYTES)
        .unwrap_or(false)
    {
        return false;
    }
    let Ok(file) = fs::File::open(path) else {
        return false;
    };
    binary_stream_has_sighup_support_for_runtime(
        file,
        BINARY_MARKER_SCAN_MAX_BYTES,
        BINARY_MARKER_SCAN_CHUNK_BYTES,
        runtime_kind,
    )
}

#[derive(Debug, Clone, Default)]
struct BinaryMarkerState {
    common: [bool; COMMON_SIGHUP_MARKERS.len()],
    external_app_server: [bool; EXTERNAL_APP_SERVER_MARKERS.len()],
    headless_remote_control_app_server: [bool; HEADLESS_REMOTE_CONTROL_APP_SERVER_MARKERS.len()],
    local_interactive_cli: [bool; LOCAL_INTERACTIVE_CLI_MARKERS.len()],
    goal_usage: bool,
    goal_pursuing: bool,
    goal_set: bool,
}

impl BinaryMarkerState {
    fn update(&mut self, data: &[u8]) {
        for (index, marker) in COMMON_SIGHUP_MARKERS.iter().enumerate() {
            if !self.common[index] && contains_bytes(data, marker) {
                self.common[index] = true;
            }
        }
        for (index, marker) in EXTERNAL_APP_SERVER_MARKERS.iter().enumerate() {
            if !self.external_app_server[index] && contains_bytes(data, marker) {
                self.external_app_server[index] = true;
            }
        }
        for (index, marker) in HEADLESS_REMOTE_CONTROL_APP_SERVER_MARKERS
            .iter()
            .enumerate()
        {
            if !self.headless_remote_control_app_server[index] && contains_bytes(data, marker) {
                self.headless_remote_control_app_server[index] = true;
            }
        }
        for (index, marker) in LOCAL_INTERACTIVE_CLI_MARKERS.iter().enumerate() {
            if !self.local_interactive_cli[index] && contains_bytes(data, marker) {
                self.local_interactive_cli[index] = true;
            }
        }
        self.goal_usage |= contains_bytes(data, GOAL_USAGE_MARKER);
        self.goal_pursuing |= contains_bytes(data, GOAL_PURSUING_MARKER);
        self.goal_set |= contains_bytes(data, GOAL_SET_MARKER);
    }

    fn has_common_markers(&self) -> bool {
        self.common.iter().all(|found| *found)
    }

    fn has_goal_support(&self) -> bool {
        self.goal_usage || (self.goal_pursuing && self.goal_set)
    }

    fn is_complete_for_runtime(&self, runtime_kind: HotSwapRuntimeKind) -> bool {
        let has_runtime_markers = match runtime_kind {
            HotSwapRuntimeKind::ExternalAppServer => {
                self.external_app_server.iter().all(|found| *found)
            }
            HotSwapRuntimeKind::HeadlessRemoteControlAppServer => {
                self.external_app_server.iter().all(|found| *found)
                    && self
                        .headless_remote_control_app_server
                        .iter()
                        .all(|found| *found)
            }
            HotSwapRuntimeKind::LocalInteractiveCli => {
                self.local_interactive_cli.iter().all(|found| *found)
            }
        };
        self.has_common_markers() && has_runtime_markers && self.has_goal_support()
    }
}

#[cfg(test)]
fn binary_stream_has_sighup_support<R: Read>(reader: R, max_bytes: u64, chunk_size: usize) -> bool {
    binary_stream_has_sighup_support_for_runtime(
        reader,
        max_bytes,
        chunk_size,
        HotSwapRuntimeKind::ExternalAppServer,
    )
}

fn binary_stream_has_sighup_support_for_runtime<R: Read>(
    mut reader: R,
    max_bytes: u64,
    chunk_size: usize,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    let chunk_size = chunk_size.max(max_marker_len());
    let mut buffer = vec![0u8; chunk_size];
    let mut carry = Vec::new();
    let mut total_read = 0u64;
    let mut state = BinaryMarkerState::default();

    loop {
        let Ok(bytes_read) = reader.read(&mut buffer) else {
            return false;
        };
        if bytes_read == 0 {
            return state.is_complete_for_runtime(runtime_kind);
        }
        total_read = total_read.saturating_add(bytes_read as u64);
        if total_read > max_bytes {
            return false;
        }

        let mut scan = Vec::with_capacity(carry.len() + bytes_read);
        scan.extend_from_slice(&carry);
        scan.extend_from_slice(&buffer[..bytes_read]);
        state.update(&scan);
        if state.is_complete_for_runtime(runtime_kind) {
            return true;
        }

        let keep = max_marker_len().saturating_sub(1);
        if scan.len() > keep {
            carry.clear();
            carry.extend_from_slice(&scan[scan.len() - keep..]);
        } else {
            carry = scan;
        }
    }
}

fn max_marker_len() -> usize {
    COMMON_SIGHUP_MARKERS
        .iter()
        .copied()
        .chain(EXTERNAL_APP_SERVER_MARKERS.iter().copied())
        .chain(HEADLESS_REMOTE_CONTROL_APP_SERVER_MARKERS.iter().copied())
        .chain(LOCAL_INTERACTIVE_CLI_MARKERS.iter().copied())
        .chain([GOAL_USAGE_MARKER, GOAL_PURSUING_MARKER, GOAL_SET_MARKER])
        .map(|marker| marker.len())
        .max()
        .unwrap_or(1)
}

fn is_deleted_proc_exe_path(path: &Path) -> bool {
    let components = path
        .components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>();
    components.len() == 4
        && components[0] == "/"
        && components[1] == "proc"
        && components[2].parse::<i32>().is_ok()
        && components[3] == "exe"
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HotSwapProcessIdentity {
    pub(crate) pid: i32,
    #[serde(rename = "ownerUID")]
    pub(crate) owner_uid: u32,
    pub(crate) executable_path: String,
    pub(crate) start_seconds: u64,
    pub(crate) start_microseconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HotSwapKernelExecutableIdentity {
    pub(crate) canonical_path: String,
    pub(crate) device: u64,
    pub(crate) inode: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HotSwapAuthFileIdentity {
    pub(crate) canonical_path: String,
    pub(crate) device: u64,
    pub(crate) inode: u64,
    #[serde(rename = "accountID")]
    pub(crate) account_id: String,
    pub(crate) complete_token_fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HotSwapBinding {
    pub(crate) contract_version: u8,
    pub(crate) process_identity: HotSwapProcessIdentity,
    pub(crate) kernel_executable_identity: HotSwapKernelExecutableIdentity,
    pub(crate) runtime_kind: HotSwapRuntimeKind,
    pub(crate) auth_file_identity: HotSwapAuthFileIdentity,
    pub(crate) request_nonce: String,
    pub(crate) issued_at_unix_milliseconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct HotSwapRequest {
    pub(crate) binding: HotSwapBinding,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HotSwapAck {
    pub(crate) binding: HotSwapBinding,
    pub(crate) acknowledged_at_unix_milliseconds: u64,
    pub(crate) loaded_token_fingerprint: String,
    pub(crate) active_token_fingerprint: String,
    pub(crate) frontend_notified: bool,
    pub(crate) frontend_write_count: usize,
    pub(crate) auth_generation: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    pub(crate) reconnect_ready: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) initialized_frontend_count: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) eligible_frontend_count: Option<usize>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub(crate) idle_listener_ready: bool,
}

fn is_false(value: &bool) -> bool {
    !*value
}

pub fn process_has_current_hot_swap_ack(process: &CodexProcess, auth_path: &Path) -> bool {
    hot_swap_runtime_kind(process).is_some_and(|runtime_kind| {
        process_has_current_hot_swap_ack_for_runtime(process, auth_path, runtime_kind)
    })
}

pub fn process_has_current_hot_swap_ack_for_runtime(
    process: &CodexProcess,
    auth_path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    if !process_identity_is_current(process) {
        return false;
    }
    let (Some(ack_path), Some(request_path)) = (
        hot_swap_ack_path(process.pid),
        hot_swap_request_path(process.pid),
    ) else {
        return false;
    };
    let Some(request) = read_hot_swap_request(&request_path) else {
        return false;
    };
    if !hot_swap_binding_matches_current(&request.binding, process, auth_path, runtime_kind) {
        return false;
    }
    let Some(ack) = read_hot_swap_ack(&ack_path) else {
        return false;
    };
    hot_swap_ack_matches_request(
        &ack,
        &request,
        runtime_kind,
        current_unix_timestamp_milliseconds(),
        HOT_SWAP_ARTIFACT_MAX_AGE,
    ) && process_identity_is_current(process)
}

fn process_has_hot_swap_ack_for_request(
    process: &CodexProcess,
    request: &HotSwapRequest,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    if !process_identity_is_current(process) {
        return false;
    }
    let Some(path) = hot_swap_ack_path(process.pid) else {
        return false;
    };
    let Some(ack) = read_hot_swap_ack(&path) else {
        return false;
    };
    hot_swap_binding_matches_current(
        &request.binding,
        process,
        Path::new(&request.binding.auth_file_identity.canonical_path),
        runtime_kind,
    ) && hot_swap_ack_matches_request(
        &ack,
        request,
        runtime_kind,
        current_unix_timestamp_milliseconds(),
        Duration::from_secs(5 * 60),
    ) && process_identity_is_current(process)
}

fn hot_swap_ack_matches_request(
    ack: &HotSwapAck,
    request: &HotSwapRequest,
    runtime_kind: HotSwapRuntimeKind,
    now_milliseconds: u64,
    max_age: Duration,
) -> bool {
    let expected_fingerprint = request
        .binding
        .auth_file_identity
        .complete_token_fingerprint
        .as_str();
    ack.binding == request.binding
        && ack.binding.contract_version == HOT_SWAP_REQUEST_CONTRACT_VERSION
        && ack.binding.runtime_kind == runtime_kind
        && ack.acknowledged_at_unix_milliseconds >= request.binding.issued_at_unix_milliseconds
        && ack.acknowledged_at_unix_milliseconds <= now_milliseconds.saturating_add(60_000)
        && now_milliseconds.saturating_sub(ack.acknowledged_at_unix_milliseconds)
            <= max_age.as_millis() as u64
        && ack.loaded_token_fingerprint == expected_fingerprint
        && ack.active_token_fingerprint == expected_fingerprint
        && match runtime_kind {
            HotSwapRuntimeKind::ExternalAppServer => {
                external_app_server_ack_is_verified(ack, false, true)
            }
            HotSwapRuntimeKind::HeadlessRemoteControlAppServer => {
                external_app_server_ack_is_verified(ack, true, false)
            }
            HotSwapRuntimeKind::LocalInteractiveCli => {
                !ack.frontend_notified
                    && ack.frontend_write_count == 0
                    && ack.reconnect_ready
                    && ack.initialized_frontend_count.is_none()
                    && ack.eligible_frontend_count.is_none()
                    && !ack.idle_listener_ready
            }
        }
}

fn external_app_server_ack_is_verified(
    ack: &HotSwapAck,
    allow_idle_listener: bool,
    allow_legacy_missing_frontend_counts: bool,
) -> bool {
    let delivered_to_frontend = !ack.idle_listener_ready
        && ack.frontend_notified
        && ack.frontend_write_count > 0
        && match (ack.initialized_frontend_count, ack.eligible_frontend_count) {
            (None, None) => allow_legacy_missing_frontend_counts,
            (Some(initialized), Some(eligible)) => {
                initialized > 0
                    && eligible > 0
                    && eligible <= initialized
                    && ack.frontend_write_count <= eligible
            }
            _ => false,
        };
    let idle_listener = allow_idle_listener
        && ack.idle_listener_ready
        && !ack.frontend_notified
        && ack.frontend_write_count == 0
        && ack.initialized_frontend_count == Some(0)
        && ack.eligible_frontend_count == Some(0);

    !ack.reconnect_ready && (delivered_to_frontend || idle_listener)
}

fn hot_swap_ack_path(pid: i32) -> Option<PathBuf> {
    default_codexswitch_data_path().map(|root| root.join("hotswap-ack").join(format!("{pid}.json")))
}

fn hot_swap_request_path(pid: i32) -> Option<PathBuf> {
    default_codexswitch_data_path()
        .map(|root| root.join("hotswap-request").join(format!("{pid}.json")))
}

fn default_codexswitch_data_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codexswitch"))
}

fn prune_hot_swap_artifacts_at(
    root: &Path,
    now: SystemTime,
    retention: HotSwapArtifactRetention,
    protected_pids: &HashSet<u32>,
) -> Result<usize> {
    let HotSwapArtifactRetention {
        max_age,
        max_scan,
        max_removals,
        max_count,
        max_total_bytes,
        max_scan_time,
        max_metadata_bytes,
    } = retention;
    if max_scan == 0
        || max_removals == 0
        || max_count == 0
        || max_total_bytes == 0
        || max_metadata_bytes == 0
    {
        bail!("hot-swap artifact retention limits must be nonzero");
    }

    let scan_started = Instant::now();
    let mut scanned = 0;
    let mut removed = 0;
    let mut retained_metadata_bytes = 0_usize;
    for (directory_name, extension) in [("hotswap-ack", "json"), ("hotswap-request", "json")] {
        let directory = root.join(directory_name);
        let Ok(mut entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut artifacts = Vec::new();
        loop {
            if scan_started.elapsed() >= max_scan_time {
                bail!(
                    "hot-swap artifact scan exceeded its {} ms time budget",
                    max_scan_time.as_millis()
                );
            }
            if scanned >= max_scan {
                bail!("hot-swap artifact scan exceeded the {max_scan} entry limit");
            }
            let Some(entry) = entries.next() else { break };
            scanned += 1;
            let Ok(entry) = entry else { continue };
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_file() || file_type.is_symlink() {
                continue;
            }
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some(extension) {
                continue;
            }
            let Some(pid) = path
                .file_stem()
                .and_then(|value| value.to_str())
                .and_then(|value| value.parse::<u32>().ok())
            else {
                continue;
            };
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            let Ok(modified) = metadata.modified() else {
                continue;
            };
            retained_metadata_bytes = retained_metadata_bytes
                .saturating_add(path.as_os_str().as_encoded_bytes().len())
                .saturating_add(std::mem::size_of::<(PathBuf, SystemTime, u64, bool)>());
            if retained_metadata_bytes > max_metadata_bytes {
                bail!(
                    "hot-swap artifact scan exceeded the {max_metadata_bytes} byte metadata budget"
                );
            }
            artifacts.push((
                path,
                modified,
                metadata.len(),
                protected_pids.contains(&pid),
            ));
        }

        artifacts.sort_by_key(|(_, modified, _, _)| *modified);
        let mut retained_count = artifacts.len();
        let mut retained_bytes = artifacts.iter().fold(0_u64, |total, (_, _, bytes, _)| {
            total.saturating_add(*bytes)
        });
        for (path, modified, bytes, protected) in &artifacts {
            let expired = now.duration_since(*modified).unwrap_or_default() >= max_age;
            let over_limit = retained_count > max_count || retained_bytes > max_total_bytes;
            if !*protected && (expired || over_limit) {
                if removed >= max_removals {
                    bail!("hot-swap artifact retention required more than {max_removals} removals");
                }
                fs::remove_file(path)
                    .with_context(|| format!("failed to prune {}", path.display()))?;
                removed += 1;
                retained_count = retained_count.saturating_sub(1);
                retained_bytes = retained_bytes.saturating_sub(*bytes);
            }
        }
        if retained_count > max_count || retained_bytes > max_total_bytes {
            bail!(
                "protected hot-swap artifacts exceed retention limits in {}",
                directory.display()
            );
        }
    }
    Ok(removed)
}

fn absolute_auth_path(path: &Path) -> Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .context("failed to resolve current directory for auth path")?
            .join(path)
    };
    let encoded = absolute
        .to_str()
        .context("auth path must be valid UTF-8 for the SIGHUP request contract")?;
    if encoded.len() > HOT_SWAP_AUTH_PATH_MAX_BYTES {
        bail!(
            "auth path exceeds the {} byte SIGHUP request limit",
            HOT_SWAP_AUTH_PATH_MAX_BYTES
        );
    }
    Ok(absolute)
}

fn hot_swap_process_binding(
    process: &CodexProcess,
) -> Result<(HotSwapProcessIdentity, HotSwapKernelExecutableIdentity)> {
    let (start_seconds, start_microseconds) = process_start_components(process)
        .context("runtime process start identity cannot be represented by convergence v3")?;
    let canonical_executable = fs::canonicalize(&process.executable).with_context(|| {
        format!(
            "failed to resolve runtime executable {}",
            process.executable.display()
        )
    })?;
    let metadata = fs::symlink_metadata(&canonical_executable).with_context(|| {
        format!(
            "failed to inspect runtime executable {}",
            canonical_executable.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!(
            "runtime executable must resolve to a regular non-symlink file: {}",
            canonical_executable.display()
        );
    }
    let executable_path = canonical_executable
        .to_str()
        .context("runtime executable path must be valid UTF-8")?
        .to_string();
    Ok((
        HotSwapProcessIdentity {
            pid: process.pid,
            owner_uid: process.owner_uid,
            executable_path: executable_path.clone(),
            start_seconds,
            start_microseconds,
        },
        HotSwapKernelExecutableIdentity {
            canonical_path: executable_path,
            device: metadata.dev(),
            inode: metadata.ino(),
        },
    ))
}

fn process_start_components(process: &CodexProcess) -> Option<(u64, u64)> {
    if let Some(ticks) = process
        .start_identity
        .strip_prefix("linux:")
        .and_then(|value| value.parse::<u64>().ok())
    {
        let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if ticks_per_second <= 0 {
            return None;
        }
        let ticks_per_second = ticks_per_second as u64;
        return Some((
            process.started_at_unix,
            (ticks % ticks_per_second).saturating_mul(1_000_000) / ticks_per_second,
        ));
    }
    let mut macos = process.start_identity.split(':');
    if macos.next() == Some("macos") {
        let seconds = macos.next()?.parse::<u64>().ok()?;
        let microseconds = macos.next()?.parse::<u64>().ok()?;
        if macos.next().is_none() && microseconds < 1_000_000 {
            return Some((seconds, microseconds));
        }
    }
    None
}

fn hot_swap_auth_file_identity(path: &Path) -> Result<HotSwapAuthFileIdentity> {
    let absolute = absolute_auth_path(path)?;
    let canonical = fs::canonicalize(&absolute)
        .with_context(|| format!("failed to resolve auth file {}", absolute.display()))?;
    let canonical_text = canonical
        .to_str()
        .context("auth path must be valid UTF-8")?;
    if canonical_text.len() > HOT_SWAP_AUTH_PATH_MAX_BYTES {
        bail!(
            "auth path exceeds the {} byte SIGHUP request limit",
            HOT_SWAP_AUTH_PATH_MAX_BYTES
        );
    }
    let metadata = fs::symlink_metadata(&canonical)
        .with_context(|| format!("failed to inspect auth file {}", canonical.display()))?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != unsafe { libc_geteuid() }
        || metadata.len() > HOT_SWAP_AUTH_FILE_MAX_BYTES
    {
        bail!(
            "auth file must be a bounded regular file owned by the current user: {}",
            canonical.display()
        );
    }
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&canonical)
        .with_context(|| format!("failed to open auth file {}", canonical.display()))?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        bail!("auth file changed identity while opened");
    }
    let mut data = Vec::with_capacity(metadata.len() as usize);
    std::io::Read::by_ref(&mut file)
        .take(HOT_SWAP_AUTH_FILE_MAX_BYTES + 1)
        .read_to_end(&mut data)?;
    if data.len() as u64 > HOT_SWAP_AUTH_FILE_MAX_BYTES {
        bail!("auth file exceeded its bounded read limit");
    }
    let current = fs::symlink_metadata(&canonical)?;
    if current.file_type().is_symlink()
        || current.dev() != metadata.dev()
        || current.ino() != metadata.ino()
    {
        bail!("auth file changed identity while read");
    }
    let value: serde_json::Value =
        serde_json::from_slice(&data).context("auth file is malformed")?;
    let tokens = value
        .get("tokens")
        .context("auth file has no token object")?;
    let id_token = tokens
        .get("id_token")
        .and_then(serde_json::Value::as_str)
        .context("auth file has no identity token")?;
    let access_token = tokens
        .get("access_token")
        .and_then(serde_json::Value::as_str)
        .context("auth file has no access token")?;
    let refresh_token = tokens
        .get("refresh_token")
        .and_then(serde_json::Value::as_str)
        .context("auth file has no refresh token")?;
    let account_id = tokens
        .get("account_id")
        .and_then(serde_json::Value::as_str)
        .context("auth file has no stable provider account ID")?;
    if account_id.is_empty()
        || account_id.len() > HOT_SWAP_ACCOUNT_ID_MAX_BYTES
        || !account_id
            .bytes()
            .all(|byte| (0x21_u8..=0x7e_u8).contains(&byte))
    {
        bail!("auth file provider account ID is invalid");
    }
    let complete_token_fingerprint =
        complete_token_fingerprint(id_token, access_token, refresh_token, account_id)
            .context("auth file has incomplete token material")?;
    Ok(HotSwapAuthFileIdentity {
        canonical_path: canonical_text.to_string(),
        device: metadata.dev(),
        inode: metadata.ino(),
        account_id: account_id.to_string(),
        complete_token_fingerprint,
    })
}

fn complete_token_fingerprint(
    id_token: &str,
    access_token: &str,
    refresh_token: &str,
    account_id: &str,
) -> Option<String> {
    let parts = [id_token, access_token, refresh_token, account_id];
    if parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    let mut digest = DigestContext::new(&SHA256);
    for part in parts {
        digest.update(&(part.len() as u64).to_be_bytes());
        digest.update(part.as_bytes());
    }
    Some(hex_digest(digest.finish().as_ref()))
}

fn hot_swap_binding(
    process: &CodexProcess,
    auth_path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> Result<HotSwapBinding> {
    let (process_identity, kernel_executable_identity) = hot_swap_process_binding(process)?;
    Ok(HotSwapBinding {
        contract_version: HOT_SWAP_REQUEST_CONTRACT_VERSION,
        process_identity,
        kernel_executable_identity,
        runtime_kind,
        auth_file_identity: hot_swap_auth_file_identity(auth_path)?,
        request_nonce: next_hot_swap_request_nonce(process),
        issued_at_unix_milliseconds: current_unix_timestamp_milliseconds(),
    })
}

fn hot_swap_binding_matches_current(
    binding: &HotSwapBinding,
    process: &CodexProcess,
    auth_path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> bool {
    if binding.contract_version != HOT_SWAP_REQUEST_CONTRACT_VERSION
        || binding.runtime_kind != runtime_kind
        || !hot_swap_request_nonce_is_valid(&binding.request_nonce)
        || binding.issued_at_unix_milliseconds
            > current_unix_timestamp_milliseconds().saturating_add(60_000)
    {
        return false;
    }
    let Ok((process_identity, kernel_executable_identity)) = hot_swap_process_binding(process)
    else {
        return false;
    };
    let process_started_at = process_identity
        .start_seconds
        .saturating_mul(1_000)
        .saturating_add(process_identity.start_microseconds / 1_000);
    if binding.issued_at_unix_milliseconds < process_started_at {
        return false;
    }
    let Ok(auth_file_identity) = hot_swap_auth_file_identity(auth_path) else {
        return false;
    };
    binding.process_identity == process_identity
        && binding.kernel_executable_identity == kernel_executable_identity
        && binding.auth_file_identity == auth_file_identity
}

fn hot_swap_request_nonce_is_valid(nonce: &str) -> bool {
    !nonce.is_empty()
        && nonce.len() <= HOT_SWAP_NONCE_MAX_BYTES
        && nonce.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
}

fn next_hot_swap_request_nonce(process: &CodexProcess) -> String {
    let sequence = HOT_SWAP_REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let identity_token = process_start_identity_token(process);
    format!(
        "{}-{}-{identity_token}-{nanos}-{sequence}",
        std::process::id(),
        process.pid,
    )
}

fn process_start_identity_token(process: &CodexProcess) -> String {
    let mut digest = DigestContext::new(&SHA256);
    digest.update(process.start_identity.as_bytes());
    let identity_hash = hex_digest(digest.finish().as_ref());
    identity_hash[..16].to_string()
}

fn write_hot_swap_request(
    process: &CodexProcess,
    auth_path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> Result<HotSwapRequest> {
    let path = hot_swap_request_path(process.pid).context("HOME is unavailable")?;
    write_hot_swap_request_at(&path, process, auth_path, runtime_kind)
}

fn write_hot_swap_request_at(
    path: &Path,
    process: &CodexProcess,
    auth_path: &Path,
    runtime_kind: HotSwapRuntimeKind,
) -> Result<HotSwapRequest> {
    let parent = path.parent().context("SIGHUP request path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    let request = HotSwapRequest {
        binding: hot_swap_binding(process, auth_path, runtime_kind)?,
    };
    let encoded = serde_json::to_vec(&request).context("failed to encode SIGHUP request")?;
    if encoded.len() > HOT_SWAP_REQUEST_MAX_BYTES {
        bail!(
            "SIGHUP request exceeds the {} byte limit",
            HOT_SWAP_REQUEST_MAX_BYTES
        );
    }
    let temporary = parent.join(format!(
        ".{}.json.tmp-{}-{}",
        process.pid,
        std::process::id(),
        HOT_SWAP_REQUEST_SEQUENCE.load(Ordering::Relaxed)
    ));
    let mut file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&temporary)
        .with_context(|| format!("failed to create {}", temporary.display()))?;
    file.write_all(&encoded)
        .with_context(|| format!("failed to write {}", temporary.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync {}", temporary.display()))?;
    fs::rename(&temporary, path)
        .with_context(|| format!("failed to promote {}", path.display()))?;
    fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("failed to sync {}", parent.display()))?;
    Ok(request)
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn read_hot_swap_request(path: &Path) -> Option<HotSwapRequest> {
    read_hot_swap_artifact(path, HOT_SWAP_REQUEST_MAX_BYTES as u64)
}

fn read_hot_swap_ack(path: &Path) -> Option<HotSwapAck> {
    read_hot_swap_artifact(path, HOT_SWAP_ACK_MAX_BYTES)
}

fn read_hot_swap_artifact<T>(path: &Path, max_bytes: u64) -> Option<T>
where
    T: for<'de> Deserialize<'de>,
{
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > max_bytes {
        return None;
    }
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let mut data = Vec::with_capacity(metadata.len() as usize);
    std::io::Read::by_ref(&mut file)
        .take(max_bytes + 1)
        .read_to_end(&mut data)
        .ok()?;
    if data.len() as u64 > max_bytes {
        return None;
    }
    let opened = file.metadata().ok()?;
    if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        return None;
    }
    serde_json::from_slice::<T>(&data).ok()
}

fn wait_for_hot_swap_ack(
    process: &CodexProcess,
    request: &HotSwapRequest,
    runtime_kind: HotSwapRuntimeKind,
    timeout: Duration,
) -> bool {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if process_has_hot_swap_ack_for_request(process, request, runtime_kind) {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    process_has_hot_swap_ack_for_request(process, request, runtime_kind)
}

pub fn process_is_sighup_safe_target(process: &CodexProcess, binary_has_markers: bool) -> bool {
    binary_has_markers && hot_swap_runtime_kind(process).is_some()
}

pub fn hot_swap_runtime_kind(process: &CodexProcess) -> Option<HotSwapRuntimeKind> {
    if is_native_codex_runtime(&process.executable)
        && is_codex_app_server_command_line(&process.command_line)
    {
        if is_headless_remote_control_app_server_command_line(&process.command_line) {
            return Some(HotSwapRuntimeKind::HeadlessRemoteControlAppServer);
        }
        return Some(HotSwapRuntimeKind::ExternalAppServer);
    }
    if is_codex_cli_runtime(&process.command_line, &process.executable) {
        return Some(HotSwapRuntimeKind::LocalInteractiveCli);
    }
    None
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
        "/applications/chatgpt.app/contents/macos/chatgpt",
        "/applications/codex.app/contents/macos/codex",
        " --remote ",
        " --ephemeral",
        " exec ",
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

fn is_codex_cli_runtime(command_line: &str, executable: &Path) -> bool {
    is_codex_cli_command_line(command_line)
        && !is_shell_wrapper_runtime(executable)
        && !is_macos_application_bundle_executable(executable)
}

fn is_macos_application_bundle_executable(executable: &Path) -> bool {
    let path = executable.to_string_lossy().to_ascii_lowercase();
    path.contains(".app/contents/")
}

pub fn is_codex_app_server_command_line(command_line: &str) -> bool {
    let lower = command_line.to_ascii_lowercase();
    if lower.contains("strings ")
        || lower.contains("/strings ")
        || lower.contains("codex-code-mode-host")
    {
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
    let Some(index) = parts.iter().position(|part| *part == "app-server") else {
        return false;
    };
    let app_server_args = &parts[index + 1..];
    if app_server_args.first().is_some_and(|arg| *arg == "proxy") {
        return false;
    }
    true
}

fn is_headless_remote_control_app_server_command_line(command_line: &str) -> bool {
    if !is_codex_app_server_command_line(command_line) {
        return false;
    }
    let parts = command_line
        .split_whitespace()
        .map(|part| part.to_ascii_lowercase())
        .collect::<Vec<_>>();
    let Some(app_server_index) = parts.iter().position(|part| part == "app-server") else {
        return false;
    };
    let arguments = &parts[app_server_index + 1..];
    let has_remote_control = arguments
        .iter()
        .any(|argument| argument == "--remote-control");
    let has_websocket_listener = arguments.iter().enumerate().any(|(index, argument)| {
        argument
            .strip_prefix("--listen=")
            .is_some_and(|value| value.starts_with("ws://"))
            || (argument == "--listen"
                && arguments
                    .get(index + 1)
                    .is_some_and(|value| value.starts_with("ws://")))
    });
    has_remote_control && has_websocket_listener
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

fn is_shell_wrapper_runtime(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_ascii_lowercase())
        .is_some_and(|name| matches!(name.as_str(), "sh" | "dash" | "bash" | "zsh" | "fish"))
}

fn wait_for_process_exit(expected: &CodexProcess, timeout: Duration) -> ProcessWaitOutcome {
    let started = Instant::now();
    while started.elapsed() < timeout {
        match current_process_identity(expected.pid) {
            None => return ProcessWaitOutcome::Exited,
            Some(observed) if !process_identity_matches(expected, &observed) => {
                return ProcessWaitOutcome::IdentityChanged;
            }
            Some(_) => {}
        }
        thread::sleep(Duration::from_millis(100));
    }
    match current_process_identity(expected.pid) {
        None => ProcessWaitOutcome::Exited,
        Some(observed) if !process_identity_matches(expected, &observed) => {
            ProcessWaitOutcome::IdentityChanged
        }
        Some(_) => ProcessWaitOutcome::TimedOut,
    }
}

#[cfg(target_os = "linux")]
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

fn current_unix_timestamp_milliseconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
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
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn restart_test_process() -> CodexProcess {
        CodexProcess {
            pid: 42,
            owner_uid: 501,
            start_identity: "first-start".to_string(),
            started_at_unix: 2_000,
            command_line: "/usr/local/bin/codex".to_string(),
            executable: PathBuf::from("/usr/local/bin/codex"),
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_kernel_identity_replaces_untrusted_argv_executable() {
        let process = CodexProcess {
            executable: PathBuf::from("/tmp/argv-spoofed-codex"),
            ..restart_test_process()
        };
        let kernel = MacKernelProcessIdentity {
            pid: 42,
            owner_uid: 501,
            start_seconds: 2_000,
            start_microseconds: 77,
            executable: PathBuf::from("/usr/local/bin/codex"),
        };

        let enriched = apply_macos_kernel_process_identity(process, &kernel).unwrap();

        assert_eq!(enriched.executable, kernel.executable);
        assert_eq!(enriched.start_identity, "macos:2000:000077");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_kernel_executable_change_breaks_signal_identity() {
        let kernel = MacKernelProcessIdentity {
            pid: 42,
            owner_uid: 501,
            start_seconds: 2_000,
            start_microseconds: 77,
            executable: PathBuf::from("/usr/local/bin/codex"),
        };
        let expected =
            apply_macos_kernel_process_identity(restart_test_process(), &kernel).unwrap();
        let replacement = MacKernelProcessIdentity {
            executable: PathBuf::from("/tmp/reused-pid-binary"),
            ..kernel
        };
        let observed =
            apply_macos_kernel_process_identity(restart_test_process(), &replacement).unwrap();

        assert!(!process_identity_matches(&expected, &observed));
    }

    #[test]
    fn explicit_restart_refuses_identity_change_before_sigterm() {
        let expected = restart_test_process();
        let changed = CodexProcess {
            start_identity: "replacement-start".to_string(),
            ..expected.clone()
        };
        let mut signals = Vec::new();

        let summary = restart_discovered_processes_with(
            vec![expected],
            |_pid| Some(changed.clone()),
            |pid, signal| {
                signals.push((pid, signal));
                Ok(())
            },
            |_process, _timeout| panic!("an un-signaled process must not be waited on"),
        );

        assert!(signals.is_empty());
        assert_eq!(summary.terminated, Vec::<i32>::new());
        assert_eq!(summary.skipped.len(), 1);
        assert!(summary.skipped[0].1.contains("before SIGTERM"));
    }

    #[test]
    fn explicit_restart_does_not_signal_process_missing_before_sigterm() {
        let mut signals = Vec::new();

        let summary = restart_discovered_processes_with(
            vec![restart_test_process()],
            |_pid| None,
            |pid, signal| {
                signals.push((pid, signal));
                Ok(())
            },
            |_process, _timeout| panic!("an un-signaled process must not be waited on"),
        );

        assert!(signals.is_empty());
        assert!(summary.terminated.is_empty());
        assert_eq!(summary.skipped.len(), 1);
        assert!(summary.skipped[0].1.contains("disappeared before SIGTERM"));
    }

    #[test]
    fn explicit_restart_refuses_pid_reuse_before_sigkill() {
        let expected = restart_test_process();
        let reused = CodexProcess {
            start_identity: "replacement-start".to_string(),
            started_at_unix: 2_001,
            ..expected.clone()
        };
        let identity_checks = std::cell::Cell::new(0usize);
        let mut signals = Vec::new();

        let summary = restart_discovered_processes_with(
            vec![expected.clone()],
            |_pid| {
                let check = identity_checks.get();
                identity_checks.set(check + 1);
                if check == 0 {
                    Some(expected.clone())
                } else {
                    Some(reused.clone())
                }
            },
            |pid, signal| {
                signals.push((pid, signal));
                Ok(())
            },
            |_process, _timeout| ProcessWaitOutcome::TimedOut,
        );

        assert_eq!(signals, vec![(42, libc::SIGTERM)]);
        assert_eq!(summary.terminated, Vec::<i32>::new());
        assert_eq!(summary.skipped.len(), 1);
        assert!(summary.skipped[0].1.contains("before SIGKILL"));
    }

    #[test]
    fn explicit_restart_does_not_sigkill_process_missing_after_sigterm_timeout() {
        let expected = restart_test_process();
        let identity_checks = std::cell::Cell::new(0usize);
        let mut signals = Vec::new();

        let summary = restart_discovered_processes_with(
            vec![expected.clone()],
            |_pid| {
                let check = identity_checks.get();
                identity_checks.set(check + 1);
                (check == 0).then(|| expected.clone())
            },
            |pid, signal| {
                signals.push((pid, signal));
                Ok(())
            },
            |_process, _timeout| ProcessWaitOutcome::TimedOut,
        );

        assert_eq!(signals, vec![(42, libc::SIGTERM)]);
        assert_eq!(summary.terminated, vec![42]);
        assert!(summary.skipped.is_empty());
    }

    #[test]
    fn command_line_detection_excludes_helpers() {
        assert!(!is_codex_cli_command_line(
            "/Applications/Codex.app/Contents/Resources/codex app-server"
        ));
        assert!(!is_codex_cli_command_line(
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        ));
        assert!(!is_codex_cli_runtime(
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/browser_crashpad_handler --database=/Library/Application Support/Codex",
            Path::new(
                "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/browser_crashpad_handler"
            )
        ));
        assert!(!is_codex_cli_runtime(
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
            Path::new(
                "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"
            )
        ));
        let computer_use = CodexProcess {
            pid: 42,
            owner_uid: 501,
            start_identity: "macos:computer-use".to_string(),
            started_at_unix: 1,
            command_line: "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService".to_string(),
            executable: PathBuf::from(
                "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
            ),
        };
        assert!(!process_matches_discovery_scope(&computer_use, true));
        assert!(is_codex_app_server_command_line(
            "/usr/bin/codex app-server --listen ws://127.0.0.1:8390"
        ));
        assert!(is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server --listen ws://127.0.0.1:8390"
        ));
        assert!(is_codex_app_server_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex app-server --remote-control --listen ws://127.0.0.1:8390"
        ));
        assert!(is_codex_app_server_command_line(
            "/Users/me/.local/share/codexswitch/prepared-codex/0.143.0/codex app-server --analytics-default-enabled"
        ));
        assert!(is_codex_app_server_command_line(
            "/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled"
        ));
        assert!(is_codex_app_server_command_line(
            "/Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled"
        ));
        assert!(is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server --listen unix://"
        ));
        assert!(!is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex app-server proxy"
        ));
        assert!(!is_codex_app_server_command_line(
            "/home/me/.local/share/codexswitch/patched-codex/codex-code-mode-host app-server"
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

    #[test]
    fn built_in_ssh_daemon_is_a_reload_target_but_its_proxy_is_not() {
        let command_line = "/home/signul/.local/share/codexswitch/patched-codex/codex -c features.code_mode_host=true app-server --listen unix://";
        assert!(is_codex_app_server_command_line(command_line));
        assert_eq!(
            hot_swap_runtime_kind(&CodexProcess {
                pid: 42,
                owner_uid: 1001,
                start_identity: "linux:123".to_string(),
                started_at_unix: 1,
                command_line: command_line.to_string(),
                executable: PathBuf::from(
                    "/home/signul/.local/share/codexswitch/patched-codex/codex",
                ),
            }),
            Some(HotSwapRuntimeKind::ExternalAppServer)
        );
        assert!(!is_codex_app_server_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex app-server proxy"
        ));
        assert!(!is_codex_app_server_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex app-server proxy --sock /tmp/control.sock"
        ));
    }

    #[test]
    fn remote_control_websocket_listener_uses_headless_runtime_contract() {
        let command_line = "/home/signul/.local/share/codexswitch/patched-codex/codex -c features.code_mode_host=true app-server --remote-control --listen ws://127.0.0.1:8390";
        let process = CodexProcess {
            pid: 42,
            owner_uid: 1001,
            start_identity: "linux:123".to_string(),
            started_at_unix: 1,
            command_line: command_line.to_string(),
            executable: PathBuf::from("/home/signul/.local/share/codexswitch/patched-codex/codex"),
        };

        assert!(is_headless_remote_control_app_server_command_line(
            command_line
        ));
        assert_eq!(
            hot_swap_runtime_kind(&process),
            Some(HotSwapRuntimeKind::HeadlessRemoteControlAppServer)
        );
        assert!(!is_headless_remote_control_app_server_command_line(
            "/home/signul/codex app-server --listen ws://127.0.0.1:8390"
        ));
        assert!(!is_headless_remote_control_app_server_command_line(
            "/home/signul/codex app-server --remote-control --listen unix://"
        ));
    }

    #[test]
    fn hot_swap_artifact_pruning_is_bounded_and_rejects_unowned_names() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("hotswap-ack");
        let request = temp.path().join("hotswap-request");
        fs::create_dir_all(&ack)?;
        fs::create_dir_all(&request)?;
        fs::write(ack.join("123.json"), b"ack")?;
        fs::write(request.join("123.json"), b"request")?;
        fs::write(ack.join("keep.json"), b"not a pid")?;
        let outside = temp.path().join("outside");
        fs::write(&outside, b"outside")?;
        symlink(&outside, ack.join("999.json"))?;

        let future = SystemTime::now() + Duration::from_secs(2);
        let removed = prune_hot_swap_artifacts_at(
            temp.path(),
            future,
            HotSwapArtifactRetention {
                max_age: Duration::from_secs(1),
                max_scan: 100,
                max_removals: 2,
                max_count: 100,
                max_total_bytes: 1024,
                max_scan_time: Duration::from_secs(1),
                max_metadata_bytes: 1024,
            },
            &HashSet::new(),
        )?;

        assert_eq!(removed, 2);
        assert!(ack.join("keep.json").exists());
        assert!(ack.join("999.json").is_symlink());
        assert!(outside.exists());
        Ok(())
    }

    #[test]
    fn hot_swap_artifact_guard_prunes_at_exact_twenty_four_hours() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("hotswap-ack");
        fs::create_dir_all(&ack)?;
        let artifact = ack.join("123.json");
        fs::write(&artifact, b"ack")?;
        let modified = fs::metadata(&artifact)?.modified()?;
        let just_before = modified + HOT_SWAP_ARTIFACT_MAX_AGE - Duration::from_nanos(1);

        assert_eq!(
            prune_hot_swap_artifacts_at(
                temp.path(),
                just_before,
                HotSwapArtifactRetention {
                    max_age: HOT_SWAP_ARTIFACT_MAX_AGE,
                    max_scan: 10,
                    max_removals: 10,
                    max_count: 10,
                    max_total_bytes: 1024,
                    max_scan_time: Duration::from_secs(1),
                    max_metadata_bytes: 1024,
                },
                &HashSet::new(),
            )?,
            0
        );
        assert!(artifact.exists());
        assert_eq!(
            prune_hot_swap_artifacts_at(
                temp.path(),
                modified + HOT_SWAP_ARTIFACT_MAX_AGE,
                HotSwapArtifactRetention {
                    max_age: HOT_SWAP_ARTIFACT_MAX_AGE,
                    max_scan: 10,
                    max_removals: 10,
                    max_count: 10,
                    max_total_bytes: 1024,
                    max_scan_time: Duration::from_secs(1),
                    max_metadata_bytes: 1024,
                },
                &HashSet::new(),
            )?,
            1
        );
        assert!(!artifact.exists());
        Ok(())
    }

    #[test]
    fn hot_swap_retention_enforces_count_and_bytes_but_protects_live_pid() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("hotswap-ack");
        fs::create_dir_all(&ack)?;
        for pid in 1..=4 {
            fs::write(ack.join(format!("{pid}.json")), vec![b'x'; 8])?;
            std::thread::sleep(Duration::from_millis(2));
        }
        let protected = HashSet::from([1_u32]);

        let removed = prune_hot_swap_artifacts_at(
            temp.path(),
            SystemTime::now(),
            HotSwapArtifactRetention {
                max_age: Duration::from_secs(60),
                max_scan: 100,
                max_removals: 10,
                max_count: 2,
                max_total_bytes: 16,
                max_scan_time: Duration::from_secs(1),
                max_metadata_bytes: 1024,
            },
            &protected,
        )?;

        assert_eq!(removed, 2);
        assert!(ack.join("1.json").exists());
        assert_eq!(
            fs::read_dir(&ack)?
                .filter_map(std::result::Result::ok)
                .count(),
            2
        );
        Ok(())
    }

    #[test]
    fn hot_swap_artifact_scan_stops_before_an_exhausted_deadline() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("hotswap-ack");
        fs::create_dir_all(&ack)?;
        let artifact = ack.join("42.json");
        fs::write(&artifact, b"ack")?;

        let error = prune_hot_swap_artifacts_at(
            temp.path(),
            SystemTime::now() + Duration::from_secs(2),
            HotSwapArtifactRetention {
                max_age: Duration::from_secs(1),
                max_scan: 10,
                max_removals: 10,
                max_count: 10,
                max_total_bytes: 1024,
                max_scan_time: Duration::ZERO,
                max_metadata_bytes: 1024,
            },
            &HashSet::new(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("time budget"));
        assert!(artifact.exists());
        Ok(())
    }

    #[test]
    fn hot_swap_artifact_scan_rejects_metadata_growth_while_iterating() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("hotswap-ack");
        fs::create_dir_all(&ack)?;
        let artifact = ack.join("42.json");
        fs::write(&artifact, b"ack")?;

        let error = prune_hot_swap_artifacts_at(
            temp.path(),
            SystemTime::now(),
            HotSwapArtifactRetention {
                max_age: Duration::from_secs(60),
                max_scan: 10,
                max_removals: 10,
                max_count: 10,
                max_total_bytes: 1024,
                max_scan_time: Duration::from_secs(1),
                max_metadata_bytes: 1,
            },
            &HashSet::new(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("metadata budget"));
        assert!(artifact.exists());
        Ok(())
    }

    #[test]
    fn oversized_hot_swap_ack_is_rejected_before_json_allocation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let ack = temp.path().join("42.json");
        let file = fs::File::create(&ack)?;
        file.set_len(HOT_SWAP_ACK_MAX_BYTES + 1)?;

        assert!(read_hot_swap_ack(&ack).is_none());
        Ok(())
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn ps_discovery_finds_macos_desktop_app_server() {
        let ps_output = "\
90221   501 Mon Jul  1 12:00:00 2024 /Applications/Codex.app/Contents/MacOS/Codex
90299   501 Mon Jul  1 12:00:01 2024 /Users/me/.local/share/codexswitch/prepared-codex/0.143.0/codex app-server --analytics-default-enabled
90300   502 Mon Jul  1 12:00:02 2024 /Users/other/.local/share/codexswitch/prepared-codex/0.143.0/codex app-server --analytics-default-enabled
90301   501 Mon Jul  1 12:00:03 2024 /bin/zsh -c rg prepared-codex
90302   501 Mon Jul  1 12:00:04 2024 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/browser_crashpad_handler --database=/Library/Application Support/Codex
90303   501 Mon Jul  1 12:00:05 2024 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)
";

        let processes = parse_ps_processes(ps_output, true, 501, 1);

        assert_eq!(
            processes,
            vec![CodexProcess {
                pid: 90299,
                owner_uid: 501,
                start_identity: "Mon Jul 1 12:00:01 2024".to_string(),
                started_at_unix: parse_ps_start_unix("Mon Jul 1 12:00:01 2024").unwrap(),
                command_line: "/Users/me/.local/share/codexswitch/prepared-codex/0.143.0/codex app-server --analytics-default-enabled".to_string(),
                executable: PathBuf::from(
                    "/Users/me/.local/share/codexswitch/prepared-codex/0.143.0/codex"
                ),
            }]
        );

        assert!(parse_ps_processes(ps_output, false, 501, 1).is_empty());
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
            owner_uid: 501,
            start_identity: "test-start-42".to_string(),
            started_at_unix: 1_000,
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
        assert!(!is_codex_cli_command_line(
            "/home/signul/.local/share/codexswitch/patched-codex/codex exec --ephemeral --json -"
        ));
        assert!(!is_codex_cli_command_line("ssh signul-vps codex"));
        assert!(!is_codex_cli_command_line(
            "/home/me/Developer/codex/codex-rs/target/release/codex --remote ws://127.0.0.1:18390 resume abc"
        ));
        assert!(!is_codex_cli_runtime(
            "/usr/bin/dash -c /home/signul/.local/share/codexswitch/patched-codex/codex --yolo",
            Path::new("/usr/bin/dash")
        ));
        assert!(is_codex_cli_runtime(
            "/home/signul/.local/share/codexswitch/patched-codex/codex --yolo",
            Path::new("/home/signul/.local/share/codexswitch/patched-codex/codex")
        ));

        let wrapper_app_server = CodexProcess {
            pid: 43,
            owner_uid: 501,
            start_identity: "test-start-43".to_string(),
            started_at_unix: 1_000,
            command_line: "/bin/zsh -lc 'codex app-server --listen ws://127.0.0.1:8390'"
                .to_string(),
            executable: PathBuf::from("/bin/zsh"),
        };
        assert_eq!(hot_swap_runtime_kind(&wrapper_app_server), None);

        let code_mode_host = CodexProcess {
            pid: 44,
            owner_uid: 501,
            start_identity: "test-start-44".to_string(),
            started_at_unix: 1_000,
            command_line: "/opt/codex/codex-code-mode-host app-server".to_string(),
            executable: PathBuf::from("/opt/codex/codex-code-mode-host"),
        };
        assert_eq!(hot_swap_runtime_kind(&code_mode_host), None);
    }

    fn shared_v3_fixture() -> Result<(HotSwapRequest, HotSwapAck)> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json"
        ))?;
        Ok((
            serde_json::from_value(fixture["requestArtifact"].clone())?,
            serde_json::from_value(fixture["acknowledgement"].clone())?,
        ))
    }

    #[test]
    fn shared_fixture_and_generated_runtime_are_one_v3_contract() -> Result<()> {
        let (request, ack) = shared_v3_fixture()?;
        assert_eq!(request.binding.contract_version, 3);
        assert_eq!(ack.binding, request.binding);
        assert!(hot_swap_ack_matches_request(
            &ack,
            &request,
            HotSwapRuntimeKind::ExternalAppServer,
            ack.acknowledged_at_unix_milliseconds,
            Duration::from_secs(300),
        ));

        let generated_runtime = include_str!("codex_update/source_app_server_template.rs");
        for required in [
            "format!(\"{pid}.json\")",
            "request_object.get(\"binding\")",
            "binding.as_object()?.len() != 7",
            "binding.get(\"contractVersion\")?.as_u64()? != 3",
            "binding.get(\"processIdentity\")",
            "process.as_object()?.len() != 5",
            "binding.get(\"kernelExecutableIdentity\")",
            "kernel.as_object()?.len() != 3",
            "binding.get(\"authFileIdentity\")",
            "auth_identity.as_object()?.len() != 5",
            "binding.get(\"requestNonce\")",
            "binding.get(\"issuedAtUnixMilliseconds\")",
            "\"binding\": binding",
            "codexswitch-runtime-convergence-v3",
            "codexswitch-hotswap-contract-v3",
            "codexswitch-hotswap-headless-idle-v1",
            "codexswitch-hotswap-cli-contract-v3",
        ] {
            assert!(generated_runtime.contains(required), "missing {required}");
        }
        assert!(!generated_runtime.contains("format!(\"{pid}.nonce\")"));
        Ok(())
    }

    #[test]
    fn v3_ack_rejects_any_binding_or_runtime_evidence_mismatch() -> Result<()> {
        let (request, ack) = shared_v3_fixture()?;
        let now = ack.acknowledged_at_unix_milliseconds;
        let matches = |candidate: &HotSwapAck| {
            hot_swap_ack_matches_request(
                candidate,
                &request,
                HotSwapRuntimeKind::ExternalAppServer,
                now,
                Duration::from_secs(300),
            )
        };
        assert!(matches(&ack));

        let mut wrong_nonce = ack.clone();
        wrong_nonce.binding.request_nonce.push_str("-other");
        assert!(!matches(&wrong_nonce));
        let mut wrong_path = ack.clone();
        wrong_path.binding.auth_file_identity.canonical_path = "/tmp/auth.json".to_string();
        assert!(!matches(&wrong_path));
        let mut wrong_fingerprint = ack.clone();
        wrong_fingerprint.loaded_token_fingerprint = "b".repeat(64);
        assert!(!matches(&wrong_fingerprint));
        let mut wrong_start = ack.clone();
        wrong_start.binding.process_identity.start_microseconds += 1;
        assert!(!matches(&wrong_start));
        let mut no_frontend_write = ack.clone();
        no_frontend_write.frontend_write_count = 0;
        assert!(!matches(&no_frontend_write));
        let mut stale = ack;
        stale.acknowledged_at_unix_milliseconds = now.saturating_sub(301_000);
        assert!(!matches(&stale));
        Ok(())
    }

    #[test]
    fn external_v3_ack_distinguishes_idle_listener_from_failed_delivery() -> Result<()> {
        let (mut request, mut idle) = shared_v3_fixture()?;
        request.binding.runtime_kind = HotSwapRuntimeKind::HeadlessRemoteControlAppServer;
        idle.binding = request.binding.clone();
        let now = idle.acknowledged_at_unix_milliseconds;
        let matches = |candidate: &HotSwapAck| {
            hot_swap_ack_matches_request(
                candidate,
                &request,
                HotSwapRuntimeKind::HeadlessRemoteControlAppServer,
                now,
                Duration::from_secs(300),
            )
        };

        let mut delivered = idle.clone();
        assert!(!matches(&delivered));
        delivered.initialized_frontend_count = Some(2);
        delivered.eligible_frontend_count = Some(2);
        assert!(matches(&delivered));

        let mut missing_initialized_count = delivered.clone();
        missing_initialized_count.initialized_frontend_count = None;
        assert!(!matches(&missing_initialized_count));

        let mut missing_eligible_count = delivered.clone();
        missing_eligible_count.eligible_frontend_count = None;
        assert!(!matches(&missing_eligible_count));

        let mut inconsistent_delivery_counts = delivered.clone();
        inconsistent_delivery_counts.initialized_frontend_count = Some(1);
        inconsistent_delivery_counts.eligible_frontend_count = Some(2);
        assert!(!matches(&inconsistent_delivery_counts));

        let mut writes_exceed_eligible_count = delivered;
        writes_exceed_eligible_count.frontend_write_count = 3;
        assert!(!matches(&writes_exceed_eligible_count));

        idle.frontend_notified = false;
        idle.frontend_write_count = 0;
        idle.initialized_frontend_count = Some(0);
        idle.eligible_frontend_count = Some(0);
        idle.idle_listener_ready = true;
        assert!(matches(&idle));

        let mut missing_idle_counts = idle.clone();
        missing_idle_counts.initialized_frontend_count = None;
        missing_idle_counts.eligible_frontend_count = None;
        assert!(!matches(&missing_idle_counts));

        let mut initialized_without_delivery = idle.clone();
        initialized_without_delivery.initialized_frontend_count = Some(1);
        assert!(!matches(&initialized_without_delivery));

        let mut contradictory_counts = idle.clone();
        contradictory_counts.eligible_frontend_count = Some(1);
        assert!(!matches(&contradictory_counts));

        let mut missing_idle_marker = idle.clone();
        missing_idle_marker.idle_listener_ready = false;
        assert!(!matches(&missing_idle_marker));

        let mut false_notification = idle;
        false_notification.frontend_notified = true;
        assert!(!matches(&false_notification));

        let (strict_request, mut strict_idle) = shared_v3_fixture()?;
        assert!(hot_swap_ack_matches_request(
            &strict_idle,
            &strict_request,
            HotSwapRuntimeKind::ExternalAppServer,
            strict_idle.acknowledged_at_unix_milliseconds,
            Duration::from_secs(300),
        ));
        strict_idle.frontend_notified = false;
        strict_idle.frontend_write_count = 0;
        strict_idle.initialized_frontend_count = Some(0);
        strict_idle.eligible_frontend_count = Some(0);
        strict_idle.idle_listener_ready = true;
        assert!(!hot_swap_ack_matches_request(
            &strict_idle,
            &strict_request,
            HotSwapRuntimeKind::ExternalAppServer,
            strict_idle.acknowledged_at_unix_milliseconds,
            Duration::from_secs(300),
        ));
        Ok(())
    }

    #[test]
    fn local_v3_ack_requires_reconnect_readiness_without_frontend_writer() -> Result<()> {
        let (mut request, mut ack) = shared_v3_fixture()?;
        request.binding.runtime_kind = HotSwapRuntimeKind::LocalInteractiveCli;
        ack.binding = request.binding.clone();
        ack.frontend_notified = false;
        ack.frontend_write_count = 0;
        ack.reconnect_ready = true;
        assert!(hot_swap_ack_matches_request(
            &ack,
            &request,
            HotSwapRuntimeKind::LocalInteractiveCli,
            ack.acknowledged_at_unix_milliseconds,
            Duration::from_secs(300),
        ));
        ack.reconnect_ready = false;
        assert!(!hot_swap_ack_matches_request(
            &ack,
            &request,
            HotSwapRuntimeKind::LocalInteractiveCli,
            ack.acknowledged_at_unix_milliseconds,
            Duration::from_secs(300),
        ));
        Ok(())
    }

    #[test]
    fn legacy_flat_request_and_ack_shapes_are_rejected() {
        let flat_request = r#"{"contractVersion":1,"requestNonce":"old","processStartIdentity":"linux:1","authPath":"/tmp/auth.json","expectedAuthHash":"hash"}"#;
        let flat_ack = r#"{"contractVersion":2,"runtimeKind":"external-app-server","pid":42,"timestampUnix":1000,"loadedAuthHash":"hash","activeAuthHash":"hash"}"#;
        assert!(serde_json::from_str::<HotSwapRequest>(flat_request).is_err());
        assert!(serde_json::from_str::<HotSwapAck>(flat_ack).is_err());
    }

    #[test]
    fn auth_file_fingerprint_covers_access_refresh_identity_and_account() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let auth_path = dir.path().join("auth.json");
        fs::write(
            &auth_path,
            r#"{"tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh","account_id":"account"}}"#,
        )
        .unwrap();
        fs::set_permissions(&auth_path, fs::Permissions::from_mode(0o600)).unwrap();
        let original = auth_file_fingerprint(&auth_path).unwrap();
        assert_eq!(
            original,
            "1cd8461676fd77670d88d5e9f3b38ef9d135d152873d905ccc8cdc621faae91c"
        );
        fs::write(
            &auth_path,
            r#"{"tokens":{"id_token":"id","access_token":"access","refresh_token":"different","account_id":"account"}}"#,
        )
        .unwrap();
        assert_ne!(auth_file_fingerprint(&auth_path).unwrap(), original);
    }

    #[test]
    fn request_nonces_are_unique_even_within_one_second() {
        let process = CodexProcess {
            pid: 42,
            owner_uid: 501,
            start_identity: "test-start".to_string(),
            started_at_unix: 1_000,
            command_line: "codex".to_string(),
            executable: PathBuf::from("/usr/local/bin/codex"),
        };
        assert_ne!(
            next_hot_swap_request_nonce(&process),
            next_hot_swap_request_nonce(&process)
        );
    }

    #[test]
    fn request_nonce_validation_accepts_swift_and_rust_writers() {
        assert!(hot_swap_request_nonce_is_valid(
            "3FCC58C4-D0C8-4AC9-BD5B-47BE404BBC33"
        ));
        assert!(hot_swap_request_nonce_is_valid(
            "123-42-macos_1000_000001-1784581742553000000-7"
        ));
        assert!(!hot_swap_request_nonce_is_valid(""));
        assert!(!hot_swap_request_nonce_is_valid("contains whitespace"));
        assert!(!hot_swap_request_nonce_is_valid("contains\ncontrol"));
        assert!(!hot_swap_request_nonce_is_valid(
            &"x".repeat(HOT_SWAP_NONCE_MAX_BYTES + 1)
        ));
    }

    #[test]
    fn sighup_request_writes_nested_v3_binding_to_pid_json() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700))?;
        let request_path = dir.path().join("hotswap-request/42.json");
        let auth_path = dir.path().join("custom/auth.json");
        let executable = dir.path().join("runtime/codex");
        fs::create_dir_all(auth_path.parent().unwrap())?;
        fs::create_dir_all(executable.parent().unwrap())?;
        fs::set_permissions(
            auth_path.parent().unwrap(),
            fs::Permissions::from_mode(0o700),
        )?;
        fs::write(
            &auth_path,
            r#"{"tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh","account_id":"provider-account"}}"#,
        )?;
        fs::set_permissions(&auth_path, fs::Permissions::from_mode(0o600))?;
        fs::write(&executable, b"runtime")?;
        let process = CodexProcess {
            pid: 42,
            owner_uid: unsafe { libc_geteuid() },
            start_identity: "linux:123".to_string(),
            started_at_unix: 1_000,
            command_line: "codex".to_string(),
            executable,
        };

        let request = write_hot_swap_request_at(
            &request_path,
            &process,
            &auth_path,
            HotSwapRuntimeKind::LocalInteractiveCli,
        )?;
        let persisted: HotSwapRequest = serde_json::from_slice(&fs::read(&request_path)?)?;

        assert_eq!(persisted, request);
        assert_eq!(persisted.binding.contract_version, 3);
        assert_eq!(
            persisted.binding.runtime_kind,
            HotSwapRuntimeKind::LocalInteractiveCli
        );
        assert_eq!(
            persisted.binding.auth_file_identity.canonical_path,
            fs::canonicalize(&auth_path)?.display().to_string()
        );
        assert_eq!(
            persisted.binding.auth_file_identity.account_id,
            "provider-account"
        );
        assert_eq!(
            persisted
                .binding
                .auth_file_identity
                .complete_token_fingerprint,
            auth_file_fingerprint(&auth_path).unwrap()
        );
        assert!(hot_swap_request_nonce_is_valid(
            &persisted.binding.request_nonce
        ));
        let value = serde_json::to_value(&persisted)?;
        assert_eq!(value.as_object().unwrap().len(), 1);
        assert!(value.get("binding").is_some());
        Ok(())
    }

    #[test]
    fn pid_reuse_cannot_satisfy_process_identity_proof() {
        let expected = CodexProcess {
            pid: 42,
            owner_uid: 501,
            start_identity: "first-start".to_string(),
            started_at_unix: 2_000,
            command_line: "/usr/local/bin/codex".to_string(),
            executable: PathBuf::from("/usr/local/bin/codex"),
        };
        let reused = CodexProcess {
            start_identity: "second-start".to_string(),
            started_at_unix: 3_000,
            ..expected.clone()
        };

        assert!(!process_identity_matches(&expected, &reused));
    }

    #[test]
    fn sighup_support_requires_rotation_retry_markers() {
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
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\nUsage: /goal <objective>\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\nCodexSwitch account/updated frontend write acknowledged after auth reload\ncodexswitch-hotswap-contract-v2\nUsage: /goal <objective>\n",
        )
        .unwrap();
        assert!(!binary_has_sighup_support_for_runtime(
            &binary,
            HotSwapRuntimeKind::ExternalAppServer,
        ));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\ncodexswitch-runtime-convergence-v3\ncodexswitch-runtime-rotation-handoff-v1\nCodexSwitch account/updated frontend write acknowledged after auth reload\ncodexswitch-hotswap-contract-v3\nUsage: /goal <objective>\n",
        )
        .unwrap();
        assert!(binary_has_sighup_support_for_runtime(
            &binary,
            HotSwapRuntimeKind::ExternalAppServer,
        ));
        assert!(!binary_has_sighup_support_for_runtime(
            &binary,
            HotSwapRuntimeKind::HeadlessRemoteControlAppServer,
        ));
        assert!(!binary_has_sighup_support_for_runtime(
            &binary,
            HotSwapRuntimeKind::LocalInteractiveCli,
        ));
        assert!(!binary_has_sighup_support(&binary));

        fs::write(
            &binary,
            b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\ncodexswitch-runtime-convergence-v3\ncodexswitch-runtime-rotation-handoff-v1\nCodexSwitch account/updated frontend write acknowledged after auth reload\ncodexswitch-hotswap-contract-v3\ncodexswitch-hotswap-headless-idle-v1\ncodexswitch-hotswap-cli-contract-v3\nPursuing goal\nthread/goal/set\n",
        )
        .unwrap();
        assert!(binary_has_sighup_support_for_runtime(
            &binary,
            HotSwapRuntimeKind::HeadlessRemoteControlAppServer,
        ));
        assert!(binary_has_sighup_support(&binary));
    }

    #[test]
    fn sighup_support_marker_scan_streams_across_chunk_boundaries() {
        let mut data = Vec::new();
        for marker in COMMON_SIGHUP_MARKERS
            .into_iter()
            .chain(EXTERNAL_APP_SERVER_MARKERS)
        {
            data.extend_from_slice(marker);
            data.extend_from_slice(b"\nxxxxxx\n");
        }
        data.extend_from_slice(b"Pursuing goal\nxxxxxx\nthread/goal/set\n");

        assert!(binary_stream_has_sighup_support(data.as_slice(), 4096, 8));
        assert!(!binary_stream_has_sighup_support(data.as_slice(), 16, 8));

        let mut cli_data = Vec::new();
        for marker in COMMON_SIGHUP_MARKERS
            .into_iter()
            .chain(LOCAL_INTERACTIVE_CLI_MARKERS)
        {
            cli_data.extend_from_slice(marker);
            cli_data.extend_from_slice(b"\nxxxxxx\n");
        }
        cli_data.extend_from_slice(b"Usage: /goal <objective>\n");
        assert!(binary_stream_has_sighup_support_for_runtime(
            cli_data.as_slice(),
            4096,
            8,
            HotSwapRuntimeKind::LocalInteractiveCli,
        ));
    }

    #[test]
    fn deleted_proc_exe_paths_are_not_scanned_for_markers() {
        assert!(is_deleted_proc_exe_path(Path::new("/proc/123/exe")));
        assert!(!is_deleted_proc_exe_path(Path::new(
            "/home/signul/.local/share/codexswitch/patched-codex/codex"
        )));
    }
}

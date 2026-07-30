use crate::account_store::{
    active_account, load_account_store_snapshot, quota_availability_at,
    ready_automatic_rotation_candidate_count, QuotaAvailability,
};
use crate::activation::{
    activation_record_confirms_current, read_activation_record_for_store, ActivationState,
};
use crate::auth::{account_token_fingerprint, auth_file_fingerprint};
use crate::bounded_command;
use crate::codex_update;
use crate::reload::{
    binary_has_sighup_support_for_runtime, discover_codex_app_server_processes,
    discover_codex_cli_processes, hot_swap_runtime_kind,
    is_official_desktop_stdio_child_command_line, process_has_current_hot_swap_ack,
    process_is_sighup_safe_target, process_matches_managed_headless_app_server, CodexProcess,
    HotSwapRuntimeKind,
};
use crate::secure_file;
use anyhow::{Context, Result};
use chrono::Utc;
use serde::Serialize;
use std::collections::HashMap;
#[cfg(any(test, target_os = "linux"))]
use std::fs;
#[cfg(target_os = "linux")]
use std::os::unix::ffi::OsStrExt;
#[cfg(target_os = "linux")]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
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
    pub computer_use_lineage: ComputerUseLineageReadiness,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ComputerUseLineageReadiness {
    pub applicable: bool,
    pub ready: bool,
    pub state: String,
    pub official_chatgpt: bool,
    pub native_child_observed: bool,
    pub native_child_pids: Vec<i32>,
    pub helper_observed: bool,
    pub helper_pids: Vec<i32>,
    pub legacy_bridge_loaded: bool,
    pub legacy_environment_present: bool,
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
                let now = Utc::now();
                active_email = Some(active.email.clone());
                active_token_fingerprint = account_token_fingerprint(active);
                active_confirmation_account = Some(active.clone());
                if active_token_fingerprint.is_none() {
                    issues.push("active account has incomplete token material".to_string());
                }
                if !active.has_usable_inference_token_at(now) {
                    issues.push(
                        "active inference token is expired or inside the safety window".to_string(),
                    );
                }
                active_availability = quota_availability_at(active, now);
            }
            ready_candidate_count = ready_automatic_rotation_candidate_count(&accounts, Utc::now());
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

    let daemon_running = match daemon_is_running() {
        Ok(running) => running,
        Err(error) => {
            issues.push(format!(
                "managed CodexSwitch coordinator ownership could not be verified: {error:#}"
            ));
            false
        }
    };
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
            classify_process_readiness(&process, binary_has_markers, ack_ready, false, true)
        })
        .collect::<Vec<_>>();

    for process in processes.iter().filter(|process| !process.hot_swap_ready) {
        issues.push(format!(
            "pid {} is not hot-swap ready: {}",
            process.pid, process.reason
        ));
    }

    let discovered_app_servers = discover_codex_app_server_processes()?;
    let has_headless_app_server = discovered_app_servers.iter().any(|process| {
        hot_swap_runtime_kind(process) == Some(HotSwapRuntimeKind::HeadlessRemoteControlAppServer)
    });
    let verify_managed_headless = cfg!(target_os = "linux") && has_headless_app_server;
    let managed_headless_identity = if verify_managed_headless {
        match codex_update::managed_headless_app_server_identity() {
            Ok(Some(identity)) => Some(identity),
            Ok(None) => {
                issues.push(
                    "headless app-server is running, but the managed systemd unit is inactive"
                        .to_string(),
                );
                None
            }
            Err(error) => {
                issues.push(format!(
                    "managed headless app-server ownership is unverified: {error:#}"
                ));
                None
            }
        }
    } else {
        None
    };
    let app_servers = discovered_app_servers
        .into_iter()
        .map(|process| {
            let runtime_kind = hot_swap_runtime_kind(&process);
            let binary_has_markers = runtime_kind.is_some_and(|runtime_kind| {
                cached_binary_has_sighup_support(
                    &mut binary_marker_cache,
                    &process.executable,
                    runtime_kind,
                )
            });
            let ack_ready = process_has_current_hot_swap_ack(&process, auth_path);
            let managed_target_verified = !verify_managed_headless
                || runtime_kind != Some(HotSwapRuntimeKind::HeadlessRemoteControlAppServer)
                || managed_headless_identity.as_ref().is_some_and(|identity| {
                    process_matches_managed_headless_app_server(identity, &process)
                });
            classify_process_readiness(
                &process,
                binary_has_markers,
                ack_ready,
                true,
                managed_target_verified,
            )
        })
        .collect::<Vec<_>>();

    for process in app_servers.iter().filter(|process| !process.hot_swap_ready) {
        issues.push(format!(
            "Codex app-server pid {} is not hot-swap ready: {}",
            process.pid, process.reason
        ));
    }

    let computer_use_lineage = computer_use_lineage_readiness();
    if computer_use_lineage.applicable && !computer_use_lineage.ready {
        issues.extend(
            computer_use_lineage
                .issues
                .iter()
                .map(|issue| format!("Computer Use lineage: {issue}")),
        );
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
    let ready = ready && (!computer_use_lineage.applicable || computer_use_lineage.ready);

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
        computer_use_lineage,
        issues,
    })
}

#[derive(Debug, Clone)]
struct LineageProcess {
    pid: i32,
    parent_pid: i32,
    owner_uid: u32,
    command_line: String,
}

#[cfg(target_os = "macos")]
fn computer_use_lineage_readiness() -> ComputerUseLineageReadiness {
    const CHATGPT: &str = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";
    let mut issues = Vec::new();
    let official_chatgpt = official_chatgpt_signature_is_valid();
    if !official_chatgpt {
        issues.push("/Applications/ChatGPT.app is not signed by OpenAI Team ID 2DC432GLL2".into());
    }

    let snapshot = bounded_command::output(
        Command::new("/bin/ps").args(["-axo", "pid=,ppid=,uid=,command=", "-ww"]),
        Duration::from_secs(3),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .ok()
    .filter(|output| output.status.success())
    .map(|output| parse_lineage_processes(&String::from_utf8_lossy(&output.stdout)))
    .unwrap_or_default();
    let by_pid = snapshot
        .iter()
        .map(|process| (process.pid, process))
        .collect::<HashMap<_, _>>();
    let chatgpt_pids = snapshot
        .iter()
        .filter(|process| first_command_path(&process.command_line) == Some(CHATGPT))
        .map(|process| process.pid)
        .collect::<std::collections::HashSet<_>>();

    let native_child_pids = snapshot
        .iter()
        .filter(|process| {
            process.owner_uid == unsafe { libc::geteuid() }
                && is_official_desktop_stdio_child_command_line(&process.command_line)
        })
        .filter(|process| ancestry_reaches_official_chatgpt(process, &by_pid, &chatgpt_pids))
        .map(|process| process.pid)
        .collect::<Vec<_>>();
    let observed_native_count = snapshot
        .iter()
        .filter(|process| is_official_desktop_stdio_child_command_line(&process.command_line))
        .count();
    if observed_native_count > native_child_pids.len() {
        issues.push("a native stdio app-server does not descend from canonical ChatGPT".into());
    }
    if native_child_pids.is_empty() {
        issues.push("no canonical ChatGPT-owned native stdio app-server is running".into());
    }

    let helper_candidates = snapshot
        .iter()
        .filter(|process| {
            process.command_line.contains("/.codex/computer-use/")
                && process.command_line.contains("SkyComputerUseService")
        })
        .collect::<Vec<_>>();
    let helper_pids = helper_candidates
        .iter()
        .filter(|process| ancestry_reaches_official_chatgpt(process, &by_pid, &chatgpt_pids))
        .map(|process| process.pid)
        .collect::<Vec<_>>();
    if helper_candidates.len() > helper_pids.len() {
        issues.push("a Computer Use helper does not descend from canonical ChatGPT".into());
    }

    let legacy_bridge_loaded = launchctl_job_is_loaded("com.codexswitch.desktop-app-server-9223");
    if legacy_bridge_loaded {
        issues.push("legacy 9223 launch agent is loaded".into());
    }
    let legacy_environment_present = launchctl_environment_is_present("CODEX_APP_SERVER_WS_URL");
    if legacy_environment_present {
        issues.push("CODEX_APP_SERVER_WS_URL is still published".into());
    }

    let ready = issues.is_empty();
    ComputerUseLineageReadiness {
        applicable: true,
        ready,
        state: if ready { "ready" } else { "blocked" }.into(),
        official_chatgpt,
        native_child_observed: !native_child_pids.is_empty(),
        native_child_pids,
        helper_observed: !helper_pids.is_empty(),
        helper_pids,
        legacy_bridge_loaded,
        legacy_environment_present,
        issues,
    }
}

#[cfg(not(target_os = "macos"))]
fn computer_use_lineage_readiness() -> ComputerUseLineageReadiness {
    ComputerUseLineageReadiness {
        applicable: false,
        ready: true,
        state: "not-applicable".into(),
        official_chatgpt: false,
        native_child_observed: false,
        native_child_pids: Vec::new(),
        helper_observed: false,
        helper_pids: Vec::new(),
        legacy_bridge_loaded: false,
        legacy_environment_present: false,
        issues: Vec::new(),
    }
}

#[cfg(target_os = "macos")]
fn official_chatgpt_signature_is_valid() -> bool {
    bounded_command::output(
        Command::new("/usr/bin/codesign").args(["-dvvv", "/Applications/ChatGPT.app"]),
        Duration::from_secs(5),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .ok()
    .filter(|output| output.status.success())
    .is_some_and(|output| {
        let detail = format!(
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        detail.contains("TeamIdentifier=2DC432GLL2") && !detail.contains("Signature=adhoc")
    })
}

#[cfg(target_os = "macos")]
fn launchctl_job_is_loaded(label: &str) -> bool {
    let target = format!("gui/{}/{label}", unsafe { libc::geteuid() });
    bounded_command::output(
        Command::new("/bin/launchctl").args(["print", target.as_str()]),
        Duration::from_secs(3),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .is_ok_and(|output| output.status.success())
}

#[cfg(target_os = "macos")]
fn launchctl_environment_is_present(name: &str) -> bool {
    bounded_command::output(
        Command::new("/bin/launchctl").args(["getenv", name]),
        Duration::from_secs(3),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .is_ok_and(|output| output.status.success() && !output.stdout.is_empty())
}

fn parse_lineage_processes(output: &str) -> Vec<LineageProcess> {
    output
        .lines()
        .filter_map(|line| {
            let (pid, rest) = take_lineage_field(line)?;
            let (parent_pid, rest) = take_lineage_field(rest)?;
            let (owner_uid, command_line) = take_lineage_field(rest)?;
            let pid = pid.parse().ok()?;
            let parent_pid = parent_pid.parse().ok()?;
            let owner_uid = owner_uid.parse().ok()?;
            let command_line = command_line.trim().to_string();
            (!command_line.is_empty()).then_some(LineageProcess {
                pid,
                parent_pid,
                owner_uid,
                command_line,
            })
        })
        .collect()
}

fn take_lineage_field(input: &str) -> Option<(&str, &str)> {
    let input = input.trim_start();
    let boundary = input.find(char::is_whitespace).unwrap_or(input.len());
    let field = &input[..boundary];
    (!field.is_empty()).then_some((field, &input[boundary..]))
}

fn first_command_path(command_line: &str) -> Option<&str> {
    command_line.split_whitespace().next()
}

fn ancestry_reaches_official_chatgpt(
    process: &LineageProcess,
    by_pid: &HashMap<i32, &LineageProcess>,
    chatgpt_pids: &std::collections::HashSet<i32>,
) -> bool {
    let mut current = process.parent_pid;
    let mut visited = std::collections::HashSet::new();
    for _ in 0..12 {
        if chatgpt_pids.contains(&current) {
            return true;
        }
        if current <= 1 || !visited.insert(current) {
            return false;
        }
        let Some(parent) = by_pid.get(&current) else {
            return false;
        };
        let Some(path) = first_command_path(&parent.command_line) else {
            return false;
        };
        if !path.starts_with("/Applications/ChatGPT.app/Contents/") {
            return false;
        }
        current = parent.parent_pid;
    }
    false
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
    managed_target_verified: bool,
) -> ProcessReadiness {
    let safe_target = if is_app_server {
        binary_has_markers && managed_target_verified
    } else {
        process_is_sighup_safe_target(process, binary_has_markers)
    };
    let hot_swap_ready = safe_target && ack_ready;
    let reason = if !managed_target_verified {
        "headless app-server is not the exact verified systemd-owned runtime".to_string()
    } else if !binary_has_markers {
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
        daemon_is_running_via_systemd
    }
    #[cfg(not(target_os = "linux"))]
    {
        daemon_is_running_via_ps
    }
}

#[cfg(target_os = "linux")]
fn daemon_is_running_via_systemd() -> Result<bool> {
    let home = std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .context("HOME is unavailable for managed daemon verification")?;
    let expected_fragment = home.join(".config/systemd/user/codexswitch.service");
    let current_executable = fs::canonicalize(std::env::current_exe()?)
        .context("failed to resolve the current CodexSwitch executable")?;
    let output = bounded_command::output(
        Command::new("systemctl")
            .arg("--user")
            .arg("show")
            .arg("codexswitch.service")
            .args([
                "--property=LoadState",
                "--property=ActiveState",
                "--property=FragmentPath",
                "--property=MainPID",
            ]),
        Duration::from_secs(3),
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .context("failed to inspect the exact managed codexswitch.service unit")?;
    if !output.status.success() {
        anyhow::bail!("systemctl exited with {}", output.status);
    }
    if !output.stderr.is_empty() {
        anyhow::bail!("systemctl emitted stderr while verifying codexswitch.service");
    }
    managed_daemon_is_running_from_systemd_output(&output.stdout, &expected_fragment, |pid| {
        linux_process_matches_managed_daemon(pid, &current_executable)
    })
}

#[cfg(any(test, target_os = "linux"))]
fn managed_daemon_is_running_from_systemd_output<Verify>(
    output: &[u8],
    expected_fragment: &Path,
    verify_process: Verify,
) -> Result<bool>
where
    Verify: FnOnce(i32) -> Result<bool>,
{
    let output = std::str::from_utf8(output).context("systemctl output was not UTF-8")?;
    let mut properties = HashMap::new();
    for line in output.lines() {
        let (key, value) = line
            .split_once('=')
            .context("systemctl returned malformed property output")?;
        if properties.insert(key, value).is_some() {
            anyhow::bail!("systemctl returned duplicate property {key}");
        }
    }
    for property in ["LoadState", "ActiveState", "FragmentPath", "MainPID"] {
        if !properties.contains_key(property) {
            anyhow::bail!("systemctl omitted {property}");
        }
    }
    if properties.len() != 4 {
        anyhow::bail!("systemctl returned unexpected properties");
    }
    if properties["LoadState"] != "loaded" {
        return Ok(false);
    }
    if Path::new(properties["FragmentPath"]) != expected_fragment {
        anyhow::bail!("codexswitch.service fragment provenance drifted");
    }
    let metadata = fs::symlink_metadata(expected_fragment).with_context(|| {
        format!(
            "failed to inspect managed service fragment {}",
            expected_fragment.display()
        )
    })?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        anyhow::bail!("managed service fragment is not a regular non-symlink file");
    }
    let pid = properties["MainPID"]
        .parse::<i32>()
        .context("systemd MainPID was invalid")?;
    match properties["ActiveState"] {
        "inactive" if pid == 0 => Ok(false),
        "active" | "activating" | "reloading" if pid > 0 => {
            if verify_process(pid)? {
                Ok(true)
            } else {
                anyhow::bail!("codexswitch.service MainPID does not match the managed executable")
            }
        }
        state => anyhow::bail!(
            "codexswitch.service reported inconsistent state {state:?} with MainPID {pid}"
        ),
    }
}

#[cfg(target_os = "linux")]
fn linux_process_matches_managed_daemon(pid: i32, expected_executable: &Path) -> Result<bool> {
    let proc_dir = PathBuf::from(format!("/proc/{pid}"));
    let metadata = fs::metadata(&proc_dir)
        .with_context(|| format!("failed to inspect codexswitch.service MainPID {pid}"))?;
    if metadata.uid() != unsafe { libc_geteuid() } {
        return Ok(false);
    }
    let executable = fs::canonicalize(proc_dir.join("exe"))
        .with_context(|| format!("failed to resolve codexswitch.service MainPID {pid}"))?;
    if executable != expected_executable {
        return Ok(false);
    }
    let command_line = fs::read(proc_dir.join("cmdline"))
        .with_context(|| format!("failed to read codexswitch.service MainPID {pid}"))?;
    let arguments = command_line
        .split(|byte| *byte == 0)
        .filter(|argument| !argument.is_empty())
        .collect::<Vec<_>>();
    let argv0_matches = arguments.first().is_some_and(|argument| {
        fs::canonicalize(Path::new(std::ffi::OsStr::from_bytes(argument)))
            .is_ok_and(|path| path == expected_executable)
    });
    Ok(arguments.len() == 2 && argv0_matches && arguments[1] == b"daemon")
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

    #[test]
    fn computer_use_lineage_parser_and_ancestry_are_fail_closed() {
        let snapshot = parse_lineage_processes(
            "100 1 501 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n\
             101 100 501 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl\n\
             102 101 501 /Users/me/.local/share/codexswitch/prepared/codex app-server --listen stdio://\n\
             200 1 501 /bin/zsh\n\
             201 200 501 /Users/me/.local/share/codexswitch/prepared/codex app-server --listen stdio://\n",
        );
        let by_pid = snapshot
            .iter()
            .map(|process| (process.pid, process))
            .collect::<HashMap<_, _>>();
        let chatgpt = [100].into_iter().collect::<std::collections::HashSet<_>>();
        let native = snapshot.iter().find(|process| process.pid == 102).unwrap();
        let wrapper = snapshot.iter().find(|process| process.pid == 201).unwrap();
        assert!(ancestry_reaches_official_chatgpt(native, &by_pid, &chatgpt));
        assert!(!ancestry_reaches_official_chatgpt(
            wrapper, &by_pid, &chatgpt
        ));
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
        let readiness = classify_process_readiness(&process(), true, false, true, true);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("has not acknowledged a reload"));
    }

    #[test]
    fn markers_with_live_ack_are_ready() {
        let readiness = classify_process_readiness(&process(), true, true, true, true);

        assert!(readiness.hot_swap_ready);
        assert!(readiness.reason.contains("live reload acknowledged"));
    }

    #[test]
    fn fresh_app_server_start_after_auth_is_not_ready_without_ack() {
        let readiness = classify_process_readiness(&process(), true, false, true, true);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("has not acknowledged a reload"));
    }

    #[test]
    fn readiness_requires_an_account_bearing_runtime() {
        assert!(!account_bearing_runtime_discovered(&[], &[]));
        assert!(account_bearing_runtime_discovered(
            &[classify_process_readiness(
                &process(),
                true,
                true,
                false,
                true
            )],
            &[],
        ));
    }

    #[test]
    fn headless_readiness_rejects_an_unverified_external_runtime() {
        let readiness = classify_process_readiness(&process(), true, true, true, false);

        assert!(!readiness.hot_swap_ready);
        assert!(readiness.reason.contains("exact verified systemd-owned"));
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
            computer_use_lineage: ComputerUseLineageReadiness {
                applicable: false,
                ready: true,
                state: "not-applicable".to_string(),
                official_chatgpt: false,
                native_child_observed: false,
                native_child_pids: Vec::new(),
                helper_observed: false,
                helper_pids: Vec::new(),
                legacy_bridge_loaded: false,
                legacy_environment_present: false,
                issues: Vec::new(),
            },
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
    fn linux_readiness_requires_the_exact_managed_systemd_unit() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let fragment = dir.path().join("codexswitch.service");
        fs::write(
            &fragment,
            b"[Service]\nExecStart=/managed/codexswitch-cli daemon\n",
        )?;
        let active = format!(
            "LoadState=loaded\nActiveState=active\nFragmentPath={}\nMainPID=4242\n",
            fragment.display()
        );
        assert!(managed_daemon_is_running_from_systemd_output(
            active.as_bytes(),
            &fragment,
            |pid| Ok(pid == 4242),
        )?);

        let inactive = format!(
            "LoadState=loaded\nActiveState=inactive\nFragmentPath={}\nMainPID=0\n",
            fragment.display()
        );
        let mut inspected_unmanaged_process = false;
        assert!(!managed_daemon_is_running_from_systemd_output(
            inactive.as_bytes(),
            &fragment,
            |_| {
                inspected_unmanaged_process = true;
                Ok(true)
            },
        )?);
        assert!(!inspected_unmanaged_process);
        Ok(())
    }

    #[test]
    fn linux_readiness_rejects_fragment_or_main_pid_identity_drift() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let fragment = dir.path().join("codexswitch.service");
        fs::write(&fragment, b"[Service]\n")?;
        let wrong_fragment = dir.path().join("codexswitch-emergency.service");
        fs::write(&wrong_fragment, b"[Service]\n")?;

        let drifted_fragment = format!(
            "LoadState=loaded\nActiveState=active\nFragmentPath={}\nMainPID=4242\n",
            wrong_fragment.display()
        );
        assert!(managed_daemon_is_running_from_systemd_output(
            drifted_fragment.as_bytes(),
            &fragment,
            |_| Ok(true),
        )
        .is_err());

        let drifted_pid = format!(
            "LoadState=loaded\nActiveState=active\nFragmentPath={}\nMainPID=4242\n",
            fragment.display()
        );
        assert!(managed_daemon_is_running_from_systemd_output(
            drifted_pid.as_bytes(),
            &fragment,
            |_| Ok(false),
        )
        .is_err());
        Ok(())
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
        assert_eq!(
            selected,
            daemon_is_running_via_systemd as *const () as usize
        );
        #[cfg(not(target_os = "linux"))]
        assert_eq!(selected, daemon_is_running_via_ps as *const () as usize);
    }
}

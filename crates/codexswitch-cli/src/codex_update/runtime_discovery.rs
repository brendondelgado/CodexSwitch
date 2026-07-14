#[cfg(test)]
fn install_offline_if_inactive<F>(
    activity: &ManagedRuntimeActivity,
    replace: F,
) -> Result<OfflineInstallOutcome>
where
    F: FnOnce() -> Result<()>,
{
    if let Some(reason) = managed_runtime_block_reason(activity) {
        return Ok(OfflineInstallOutcome::Staged(reason));
    }

    replace()?;
    Ok(OfflineInstallOutcome::Installed)
}

fn install_staged_if_still_inactive<S, G, Stage, Acquire, Observe, Commit>(
    initial_activity: &ManagedRuntimeActivity,
    stage: Stage,
    acquire: Acquire,
    final_observe: Observe,
    commit: Commit,
) -> Result<OfflineInstallOutcome>
where
    Stage: FnOnce() -> Result<S>,
    Acquire: FnOnce() -> GuardAcquire<G>,
    Observe: FnOnce(&G) -> ManagedRuntimeActivity,
    Commit: FnOnce(S, &G) -> Result<()>,
{
    if let Some(reason) = managed_runtime_block_reason(initial_activity) {
        return Ok(OfflineInstallOutcome::Staged(reason));
    }
    let staged = stage()?;
    let guards = match acquire() {
        GuardAcquire::Acquired(guards) => guards,
        GuardAcquire::Blocked(reason) => return Ok(OfflineInstallOutcome::Staged(reason)),
    };
    let final_activity = final_observe(&guards);
    if let Some(reason) = managed_runtime_block_reason(&final_activity) {
        return Ok(OfflineInstallOutcome::Staged(format!(
            "runtime activity changed before commit: {reason}"
        )));
    }
    commit(staged, &guards)?;
    Ok(OfflineInstallOutcome::Installed)
}

fn managed_runtime_block_reason(activity: &ManagedRuntimeActivity) -> Option<String> {
    let mut blockers = Vec::new();
    match &activity.systemd_unit {
        RuntimeActivityObservation::Inactive => {}
        RuntimeActivityObservation::Active => blockers.push(format!(
            "systemd unit {MANAGED_APP_SERVER_UNIT} is active (stop it with `systemctl --user stop {MANAGED_APP_SERVER_UNIT}` during the idle window)"
        )),
        RuntimeActivityObservation::Unknown(error) => blockers.push(format!(
            "systemd unit {MANAGED_APP_SERVER_UNIT} activity could not be verified ({error})"
        )),
    }
    match &activity.app_server_daemon {
        RuntimeActivityObservation::Inactive => {}
        RuntimeActivityObservation::Active => blockers.push(
            "the managed app-server daemon is active (stop it with the currently installed Codex `app-server daemon stop` command during the idle window)"
                .to_string(),
        ),
        RuntimeActivityObservation::Unknown(error) => blockers.push(format!(
            "managed app-server daemon activity could not be verified ({error})"
        )),
    }

    (!blockers.is_empty()).then(|| blockers.join("; "))
}

fn observe_managed_runtime_activity(
    platform: HostPlatform,
    current_runtime: &Path,
) -> ManagedRuntimeActivity {
    observe_managed_runtime_activity_with_reservation(platform, current_runtime, false)
}

fn observe_managed_runtime_activity_with_reservation(
    platform: HostPlatform,
    current_runtime: &Path,
    daemon_reservation_held_by_installer: bool,
) -> ManagedRuntimeActivity {
    let systemd_unit = if platform == HostPlatform::Linux {
        observe_managed_systemd_unit_activity()
    } else {
        RuntimeActivityObservation::Inactive
    };
    let app_server_daemon = observe_managed_app_server_daemon_activity_with_reservation(
        platform,
        current_runtime,
        daemon_reservation_held_by_installer,
    );
    ManagedRuntimeActivity {
        systemd_unit,
        app_server_daemon,
    }
}

include!("generated_systemd.rs");
#[cfg(test)]
fn observe_managed_app_server_daemon_activity(
    platform: HostPlatform,
    current_runtime: &Path,
) -> RuntimeActivityObservation {
    observe_managed_app_server_daemon_activity_with_reservation(platform, current_runtime, false)
}

fn observe_managed_app_server_daemon_activity_with_reservation(
    platform: HostPlatform,
    current_runtime: &Path,
    daemon_reservation_held_by_installer: bool,
) -> RuntimeActivityObservation {
    let codex_home = match managed_daemon_codex_home() {
        Ok(path) => path,
        Err(error) => return RuntimeActivityObservation::Unknown(format!("{error:#}")),
    };
    observe_managed_app_server_daemon_activity_at_with_reservation(
        platform,
        current_runtime,
        &codex_home,
        daemon_reservation_held_by_installer,
    )
}

#[cfg(test)]
fn observe_managed_app_server_daemon_activity_at(
    platform: HostPlatform,
    current_runtime: &Path,
    codex_home: &Path,
) -> RuntimeActivityObservation {
    observe_managed_app_server_daemon_activity_at_with_reservation(
        platform,
        current_runtime,
        codex_home,
        false,
    )
}

fn observe_managed_app_server_daemon_activity_at_with_reservation(
    platform: HostPlatform,
    current_runtime: &Path,
    codex_home: &Path,
    daemon_reservation_held_by_installer: bool,
) -> RuntimeActivityObservation {
    observe_managed_app_server_daemon_activity_at_with_probe(
        platform,
        current_runtime,
        codex_home,
        daemon_reservation_held_by_installer,
        |runtime| {
            let output = bounded_command::output(
                Command::new(runtime).args(["app-server", "daemon", "version"]),
                PROBE_COMMAND_TIMEOUT,
                bounded_command::SMALL_OUTPUT_LIMIT,
            )?;
            Ok(CommandProbeOutput {
                success: output.status.success(),
                exit_code: output.status.code(),
                stdout: output.stdout,
                stderr: output.stderr,
            })
        },
    )
}

fn observe_managed_app_server_daemon_activity_at_with_probe<Probe>(
    platform: HostPlatform,
    current_runtime: &Path,
    codex_home: &Path,
    daemon_reservation_held_by_installer: bool,
    daemon_version_probe: Probe,
) -> RuntimeActivityObservation
where
    Probe: FnOnce(&Path) -> Result<CommandProbeOutput>,
{
    let executable_available = match fs::symlink_metadata(current_runtime) {
        Ok(metadata) if metadata.file_type().is_file() => true,
        Ok(_) => false,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "failed to inspect installed runtime {}: {error}",
                current_runtime.display()
            ));
        }
    };

    if !executable_available {
        return match observe_managed_daemon_artifacts(
            platform,
            None,
            codex_home,
            daemon_reservation_held_by_installer,
        ) {
            RuntimeActivityObservation::Active => RuntimeActivityObservation::Active,
            RuntimeActivityObservation::Inactive | RuntimeActivityObservation::Unknown(_) => {
                RuntimeActivityObservation::Unknown(format!(
                    "installed runtime {} is unavailable, so daemon process identity cannot be proven inactive",
                    current_runtime.display()
                ))
            }
        };
    }

    if daemon_reservation_held_by_installer {
        return observe_managed_daemon_artifacts(platform, Some(current_runtime), codex_home, true);
    }

    let output = match daemon_version_probe(current_runtime) {
        Ok(output) => output,
        Err(error) => {
            return combine_failed_daemon_probe_with_artifacts(
                platform,
                current_runtime,
                codex_home,
                daemon_reservation_held_by_installer,
                format!("daemon version probe failed: {error:#}"),
            );
        }
    };
    if !output.success || output.exit_code != Some(0) {
        return combine_failed_daemon_probe_with_artifacts(
            platform,
            current_runtime,
            codex_home,
            daemon_reservation_held_by_installer,
            format!(
                "daemon version probe exited with code {:?}",
                output.exit_code
            ),
        );
    }
    if !output.stderr.is_empty() {
        return combine_failed_daemon_probe_with_artifacts(
            platform,
            current_runtime,
            codex_home,
            daemon_reservation_held_by_installer,
            "daemon version probe emitted stderr".to_string(),
        );
    }

    match daemon_version_claim_from_output(&output.stdout) {
        DaemonVersionClaim::Active => RuntimeActivityObservation::Active,
        DaemonVersionClaim::ClaimsInactive => observe_managed_daemon_artifacts(
            platform,
            Some(current_runtime),
            codex_home,
            daemon_reservation_held_by_installer,
        ),
        DaemonVersionClaim::Unknown(error) => combine_failed_daemon_probe_with_artifacts(
            platform,
            current_runtime,
            codex_home,
            daemon_reservation_held_by_installer,
            error,
        ),
    }
}

fn managed_daemon_codex_home() -> Result<PathBuf> {
    match std::env::var_os("CODEX_HOME") {
        Some(path) => {
            let path = PathBuf::from(path);
            if !path.is_absolute() {
                bail!("CODEX_HOME must be absolute for daemon activity observation");
            }
            Ok(path)
        }
        None => Ok(home_dir()?.join(".codex")),
    }
}

fn combine_failed_daemon_probe_with_artifacts(
    platform: HostPlatform,
    current_runtime: &Path,
    codex_home: &Path,
    daemon_reservation_held_by_installer: bool,
    probe_error: String,
) -> RuntimeActivityObservation {
    match observe_managed_daemon_artifacts(
        platform,
        Some(current_runtime),
        codex_home,
        daemon_reservation_held_by_installer,
    ) {
        RuntimeActivityObservation::Active => RuntimeActivityObservation::Active,
        RuntimeActivityObservation::Inactive => RuntimeActivityObservation::Unknown(format!(
            "{probe_error}; exact daemon artifacts and process identity found no active process, but the failed daemon probe prevents positive inactivity"
        )),
        RuntimeActivityObservation::Unknown(error) => {
            RuntimeActivityObservation::Unknown(format!("{probe_error}; {error}"))
        }
    }
}

fn observe_managed_daemon_artifacts(
    platform: HostPlatform,
    current_runtime: Option<&Path>,
    codex_home: &Path,
    daemon_reservation_held_by_installer: bool,
) -> RuntimeActivityObservation {
    let mut probe = FilesystemDaemonArtifactProbe {
        platform,
        current_runtime,
        codex_home,
        daemon_reservation_held_by_installer,
    };
    observe_managed_daemon_artifacts_with(&mut probe)
}

trait DaemonArtifactProbe {
    fn reservation(&mut self) -> RuntimeActivityObservation;
    fn pid_record(&mut self) -> RuntimeActivityObservation;
    fn exact_process_scan(&mut self) -> RuntimeActivityObservation;
    fn socket(&mut self) -> RuntimeActivityObservation;
}

struct FilesystemDaemonArtifactProbe<'a> {
    platform: HostPlatform,
    current_runtime: Option<&'a Path>,
    codex_home: &'a Path,
    daemon_reservation_held_by_installer: bool,
}

impl DaemonArtifactProbe for FilesystemDaemonArtifactProbe<'_> {
    fn reservation(&mut self) -> RuntimeActivityObservation {
        if self.daemon_reservation_held_by_installer {
            return RuntimeActivityObservation::Inactive;
        }
        let path = managed_daemon_reservation_path(self.codex_home);
        match managed_daemon_reservation_lock_is_held(&path) {
            Ok(true) => RuntimeActivityObservation::Active,
            Ok(false) => RuntimeActivityObservation::Inactive,
            Err(error) => RuntimeActivityObservation::Unknown(format!("{error:#}")),
        }
    }

    fn pid_record(&mut self) -> RuntimeActivityObservation {
        let path = self.codex_home.join("app-server-daemon/app-server.pid");
        match read_managed_daemon_pid_record(&path) {
            Ok(Some(record)) => {
                observe_managed_daemon_pid_record(self.platform, &record, self.current_runtime)
            }
            Ok(None) => RuntimeActivityObservation::Inactive,
            Err(error) => RuntimeActivityObservation::Unknown(format!("{error:#}")),
        }
    }

    fn exact_process_scan(&mut self) -> RuntimeActivityObservation {
        match (self.platform, self.current_runtime) {
            (HostPlatform::Linux, Some(runtime)) => {
                scan_linux_exact_managed_daemon_processes(runtime)
            }
            (_, None) => RuntimeActivityObservation::Unknown(
                "installed runtime is unavailable for a complete daemon process identity scan"
                    .to_string(),
            ),
            _ => RuntimeActivityObservation::Unknown(
                "complete managed daemon process identity scan is unavailable on this platform"
                    .to_string(),
            ),
        }
    }

    fn socket(&mut self) -> RuntimeActivityObservation {
        let path = self
            .codex_home
            .join("app-server-control/app-server-control.sock");
        match fs::symlink_metadata(&path) {
            Ok(_) => RuntimeActivityObservation::Unknown(format!(
                "managed daemon socket {} still exists, so inactivity is not proven",
                path.display()
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                RuntimeActivityObservation::Inactive
            }
            Err(error) => RuntimeActivityObservation::Unknown(format!(
                "failed to inspect managed daemon socket {}: {error}",
                path.display()
            )),
        }
    }
}

fn observe_managed_daemon_artifacts_with<Probe>(probe: &mut Probe) -> RuntimeActivityObservation
where
    Probe: DaemonArtifactProbe,
{
    for step in 0..4 {
        let observation = match step {
            0 => probe.reservation(),
            1 => probe.pid_record(),
            2 => probe.exact_process_scan(),
            _ => probe.socket(),
        };
        match observation {
            RuntimeActivityObservation::Inactive => {}
            RuntimeActivityObservation::Active => return RuntimeActivityObservation::Active,
            RuntimeActivityObservation::Unknown(error) => {
                return RuntimeActivityObservation::Unknown(error);
            }
        }
    }
    RuntimeActivityObservation::Inactive
}

fn managed_daemon_reservation_lock_is_held(path: &Path) -> Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect daemon lock {}", path.display()));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("managed daemon lock must be a regular non-symlink file");
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open daemon lock {}", path.display()))?;
    use std::os::fd::AsRawFd;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
        return Ok(false);
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        return Ok(true);
    }
    Err(error).with_context(|| format!("failed to query daemon lock {}", path.display()))
}

fn read_managed_daemon_pid_record(path: &Path) -> Result<Option<ManagedDaemonPidRecord>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect daemon pid file {}", path.display()));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("managed daemon pid record must be a regular non-symlink file");
    }
    if metadata.len() > MANAGED_DAEMON_PID_RECORD_MAX_BYTES {
        bail!("managed daemon pid record exceeds its bounded read limit");
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("failed to open daemon pid file {}", path.display()))?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MANAGED_DAEMON_PID_RECORD_MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MANAGED_DAEMON_PID_RECORD_MAX_BYTES {
        bail!("managed daemon pid record exceeded its bounded read limit");
    }
    if bytes.iter().all(|byte| byte.is_ascii_whitespace()) {
        bail!("managed daemon pid record is empty");
    }
    let record = serde_json::from_slice::<ManagedDaemonPidRecord>(&bytes)
        .context("managed daemon pid record is invalid")?;
    if record.pid == 0 || record.process_start_time.trim().is_empty() {
        bail!("managed daemon pid record has an invalid process identity");
    }
    Ok(Some(record))
}

fn observe_managed_daemon_pid_record(
    platform: HostPlatform,
    record: &ManagedDaemonPidRecord,
    current_runtime: Option<&Path>,
) -> RuntimeActivityObservation {
    if platform != HostPlatform::Linux {
        return RuntimeActivityObservation::Unknown(
            "managed daemon pid identity verification is unavailable on this platform".to_string(),
        );
    }
    let proc_dir = PathBuf::from(format!("/proc/{}", record.pid));
    let process_metadata = match fs::metadata(&proc_dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return RuntimeActivityObservation::Inactive;
        }
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "failed to inspect managed daemon pid {}: {error}",
                record.pid
            ));
        }
    };
    if process_metadata.uid() != unsafe { libc::geteuid() } {
        return RuntimeActivityObservation::Unknown(format!(
            "managed daemon pid {} is owned by another uid",
            record.pid
        ));
    }

    let pid = record.pid.to_string();
    let output = bounded_command::output(
        Command::new("/bin/ps").args(["-p", pid.as_str(), "-o", "lstart="]),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    );
    let output = match output {
        Ok(output) => output,
        Err(error) => return RuntimeActivityObservation::Unknown(format!("{error:#}")),
    };
    if !output.status.success() || output.status.code() != Some(0) || !output.stderr.is_empty() {
        return if proc_dir.exists() {
            RuntimeActivityObservation::Unknown(format!(
                "failed to verify start identity for managed daemon pid {}",
                record.pid
            ))
        } else {
            RuntimeActivityObservation::Inactive
        };
    }
    let observed_start = match std::str::from_utf8(&output.stdout) {
        Ok(start) => start.trim().to_string(),
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "managed daemon pid {} start probe returned non-UTF-8 output: {error}",
                record.pid
            ));
        }
    };
    if observed_start != record.process_start_time {
        return RuntimeActivityObservation::Unknown(format!(
            "managed daemon pid {} start identity changed from {:?} to {:?}",
            record.pid, record.process_start_time, observed_start
        ));
    }

    let Some(current_runtime) = current_runtime else {
        return RuntimeActivityObservation::Unknown(format!(
            "managed daemon pid {} is live, but the installed runtime is unavailable for exact process identity verification",
            record.pid
        ));
    };
    match linux_process_matches_exact_managed_daemon(record.pid, current_runtime) {
        Ok(ExactManagedProcessObservation::Active) => RuntimeActivityObservation::Active,
        Ok(ExactManagedProcessObservation::Unrelated) => {
            RuntimeActivityObservation::Unknown(format!(
                "managed daemon pid {} is live but does not match the installed runtime inode",
                record.pid
            ))
        }
        Ok(ExactManagedProcessObservation::IdentityDrift(error)) => {
            RuntimeActivityObservation::Unknown(error)
        }
        Err(error) => RuntimeActivityObservation::Unknown(format!("{error:#}")),
    }
}

fn scan_linux_exact_managed_daemon_processes(current_runtime: &Path) -> RuntimeActivityObservation {
    let expected_metadata = match fs::metadata(current_runtime) {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => {
            return RuntimeActivityObservation::Unknown(format!(
                "installed runtime {} is not a regular file",
                current_runtime.display()
            ));
        }
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "failed to inspect installed runtime {}: {error}",
                current_runtime.display()
            ));
        }
    };
    let expected_canonical = match fs::canonicalize(current_runtime) {
        Ok(path) => path,
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "failed to resolve installed runtime {}: {error}",
                current_runtime.display()
            ));
        }
    };
    let entries = match fs::read_dir("/proc") {
        Ok(entries) => entries,
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "failed to enumerate /proc for exact daemon identity: {error}"
            ));
        }
    };
    let started = Instant::now();
    let current_uid = unsafe { libc::geteuid() };
    let mut scanned = 0_usize;
    for entry in entries {
        scanned += 1;
        if scanned > MANAGED_DAEMON_PROC_SCAN_MAX_ENTRIES
            || started.elapsed() > MANAGED_DAEMON_PROC_SCAN_TIMEOUT
        {
            return RuntimeActivityObservation::Unknown(
                "exact managed daemon process scan exceeded its bound".to_string(),
            );
        }
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                return RuntimeActivityObservation::Unknown(format!(
                    "failed during exact managed daemon process scan: {error}"
                ));
            }
        };
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u32>().ok())
        else {
            continue;
        };
        let metadata = match fs::metadata(entry.path()) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return RuntimeActivityObservation::Unknown(format!(
                    "failed to inspect /proc/{pid}: {error}"
                ));
            }
        };
        if metadata.uid() != current_uid {
            continue;
        }
        match linux_process_matches_exact_managed_daemon_with_metadata(
            Path::new("/proc"),
            pid,
            current_runtime,
            &expected_canonical,
            &expected_metadata,
        ) {
            Ok(ExactManagedProcessObservation::Active) => {
                return RuntimeActivityObservation::Active;
            }
            Ok(ExactManagedProcessObservation::Unrelated) => {}
            Ok(ExactManagedProcessObservation::IdentityDrift(error)) => {
                return RuntimeActivityObservation::Unknown(error);
            }
            Err(error) => return RuntimeActivityObservation::Unknown(format!("{error:#}")),
        }
    }
    RuntimeActivityObservation::Inactive
}

fn linux_process_matches_exact_managed_daemon(
    pid: u32,
    current_runtime: &Path,
) -> Result<ExactManagedProcessObservation> {
    let expected_metadata = fs::metadata(current_runtime).with_context(|| {
        format!(
            "failed to inspect installed runtime {}",
            current_runtime.display()
        )
    })?;
    let expected_canonical = fs::canonicalize(current_runtime).with_context(|| {
        format!(
            "failed to resolve installed runtime {}",
            current_runtime.display()
        )
    })?;
    linux_process_matches_exact_managed_daemon_with_metadata(
        Path::new("/proc"),
        pid,
        current_runtime,
        &expected_canonical,
        &expected_metadata,
    )
}

fn linux_process_matches_exact_managed_daemon_with_metadata(
    proc_root: &Path,
    pid: u32,
    expected_argv0: &Path,
    expected_canonical: &Path,
    expected_metadata: &fs::Metadata,
) -> Result<ExactManagedProcessObservation> {
    let proc_dir = proc_root.join(pid.to_string());
    let Some(start_before) = read_linux_process_start_ticks(&proc_dir)? else {
        return Ok(ExactManagedProcessObservation::Unrelated);
    };
    let executable_path = proc_dir.join("exe");
    let process_executable = match fs::metadata(&executable_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ExactManagedProcessObservation::Unrelated);
        }
        Err(error) => {
            return Err(error).with_context(|| {
                format!("failed to inspect exact executable identity for pid {pid}")
            });
        }
    };
    let Some(command_line) =
        read_linux_proc_file_bounded(&proc_dir.join("cmdline"), MANAGED_DAEMON_CMDLINE_MAX_BYTES)?
    else {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} command line disappeared during identity verification"
        )));
    };
    let exact_managed_argv =
        command_line_is_exact_managed_app_server_daemon(&command_line, expected_argv0);
    if process_executable.dev() != expected_metadata.dev()
        || process_executable.ino() != expected_metadata.ino()
    {
        if exact_managed_argv {
            return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
                "managed daemon pid {pid} has the exact managed argv on a replaced executable inode; ownership is ambiguous"
            )));
        }
        return Ok(ExactManagedProcessObservation::Unrelated);
    }
    let observed_canonical = fs::canonicalize(&executable_path).with_context(|| {
        format!("failed to resolve exact executable path identity for pid {pid}")
    })?;
    if observed_canonical != expected_canonical {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} executable path drifted to {} despite matching the runtime inode",
            observed_canonical.display()
        )));
    }
    if !exact_managed_argv {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} argv did not match the exact managed daemon command"
        )));
    }
    let Some(start_after) = read_linux_process_start_ticks(&proc_dir)? else {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} start identity disappeared during verification"
        )));
    };
    if !exact_managed_daemon_identity_matches(
        expected_metadata.dev(),
        expected_metadata.ino(),
        process_executable.dev(),
        process_executable.ino(),
        expected_argv0,
        &command_line,
        start_before,
        start_after,
    ) {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} identity changed during verification"
        )));
    }
    Ok(ExactManagedProcessObservation::Active)
}

fn exact_managed_daemon_identity_matches(
    expected_dev: u64,
    expected_ino: u64,
    observed_dev: u64,
    observed_ino: u64,
    expected_argv0: &Path,
    command_line: &[u8],
    start_before: u64,
    start_after: u64,
) -> bool {
    expected_dev == observed_dev
        && expected_ino == observed_ino
        && command_line_is_exact_managed_app_server_daemon(command_line, expected_argv0)
        && start_before == start_after
}

fn read_linux_process_start_ticks(proc_dir: &Path) -> Result<Option<u64>> {
    let Some(bytes) = read_linux_proc_file_bounded(&proc_dir.join("stat"), 8 * 1024)? else {
        return Ok(None);
    };
    let stat = std::str::from_utf8(&bytes).context("process stat was not UTF-8")?;
    let end_comm = stat
        .rfind(')')
        .context("process stat omitted command terminator")?;
    let fields = stat[end_comm + 1..].split_whitespace().collect::<Vec<_>>();
    let start_ticks = fields
        .get(19)
        .context("process stat omitted start identity")?
        .parse::<u64>()
        .context("process start identity was invalid")?;
    Ok(Some(start_ticks))
}

fn read_linux_proc_file_bounded(path: &Path, max_bytes: u64) -> Result<Option<Vec<u8>>> {
    let file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to open {}", path.display()));
        }
    };
    let mut bytes = Vec::new();
    file.take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        bail!("{} exceeded its bounded read limit", path.display());
    }
    Ok(Some(bytes))
}

fn command_line_is_exact_managed_app_server_daemon(
    command_line: &[u8],
    expected_argv0: &Path,
) -> bool {
    use std::os::unix::ffi::OsStrExt;

    let args = command_line
        .split(|byte| *byte == 0)
        .filter(|arg| !arg.is_empty())
        .collect::<Vec<_>>();
    args == [
        expected_argv0.as_os_str().as_bytes(),
        b"app-server",
        b"--listen",
        b"unix://",
    ]
}

enum DaemonVersionClaim {
    Active,
    ClaimsInactive,
    Unknown(String),
}

fn daemon_version_claim_from_output(stdout: &[u8]) -> DaemonVersionClaim {
    let value = match serde_json::from_slice::<serde_json::Value>(stdout) {
        Ok(value) => value,
        Err(error) => {
            return DaemonVersionClaim::Unknown(format!(
                "daemon probe returned invalid JSON: {error}"
            ));
        }
    };
    let Some(status) = value.get("status").and_then(serde_json::Value::as_str) else {
        return DaemonVersionClaim::Unknown("daemon probe omitted status".to_string());
    };
    match status {
        "running" => DaemonVersionClaim::Active,
        "stopped" | "inactive" | "notRunning" | "not_running" | "not-running" | "not running" => {
            DaemonVersionClaim::ClaimsInactive
        }
        status => {
            DaemonVersionClaim::Unknown(format!("daemon probe returned unknown status {status:?}"))
        }
    }
}

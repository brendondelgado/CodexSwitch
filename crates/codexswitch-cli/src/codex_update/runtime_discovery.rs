#[cfg(target_os = "linux")]
pub(crate) fn managed_app_server_identities() -> Result<Vec<ManagedAppServerIdentity>> {
    combine_managed_app_server_identities(
        managed_headless_app_server_identity()?,
        managed_unix_app_server_identity()?,
    )
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn managed_app_server_identities() -> Result<Vec<ManagedAppServerIdentity>> {
    Ok(Vec::new())
}

fn combine_managed_app_server_identities(
    systemd: Option<ManagedAppServerIdentity>,
    unix_daemon: Option<ManagedAppServerIdentity>,
) -> Result<Vec<ManagedAppServerIdentity>> {
    let identities = [systemd, unix_daemon]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    validate_managed_app_server_identities(&identities)?;
    Ok(identities)
}

#[cfg(target_os = "linux")]
fn managed_unix_app_server_identity() -> Result<Option<ManagedAppServerIdentity>> {
    let current_route = codexswitch_data_dir()?.join("current/patched-codex/codex");
    let current_runtime = fs::canonicalize(&current_route)
        .context("failed to resolve the current immutable Codex runtime")?;
    let codex_home = managed_daemon_codex_home()?;
    managed_unix_app_server_identity_at(&current_route, &current_runtime, &codex_home)
}

#[cfg(target_os = "linux")]
fn managed_unix_app_server_identity_at(
    current_route: &Path,
    current_runtime: &Path,
    codex_home: &Path,
) -> Result<Option<ManagedAppServerIdentity>> {
    let record_path = codex_home.join("app-server-daemon/app-server.pid");
    managed_unix_app_server_identity_with(
        &record_path,
        || scan_linux_exact_managed_unix_daemon_pids(current_route, current_runtime),
        |record| {
            bind_managed_daemon_pid_record(
                HostPlatform::Linux,
                record,
                current_route,
                current_runtime,
            )
        },
        |pid| bind_exact_managed_unix_daemon(pid, current_route, current_runtime, codex_home),
    )
}

#[cfg(any(target_os = "linux", test))]
fn managed_unix_app_server_identity_with<Scan, Recorded, Unrecorded>(
    record_path: &Path,
    scan: Scan,
    bind_record: Recorded,
    bind_unrecorded: Unrecorded,
) -> Result<Option<ManagedAppServerIdentity>>
where
    Scan: Fn() -> Result<Vec<u32>>,
    Recorded: FnOnce(&ManagedDaemonPidRecord) -> Result<Option<ManagedAppServerIdentity>>,
    Unrecorded: Fn(u32) -> Result<ManagedAppServerIdentity>,
{
    let record = read_managed_daemon_pid_record(record_path)?;
    let exact_pids = scan()?;
    let Some(record) = record else {
        let identity =
            bind_unrecorded_managed_unix_daemon_with(&exact_pids, scan, bind_unrecorded)?;
        if read_managed_daemon_pid_record(record_path)?.is_some() {
            bail!("managed Unix app-server PID record appeared during discovery");
        }
        return Ok(identity);
    };
    let record_pid = i32::try_from(record.pid).context("managed daemon PID exceeds i32")?;
    if exact_pids.as_slice() != [record.pid] {
        bail!(
            "managed Unix app-server ownership is ambiguous: PID record names {record_pid}, exact current-release processes are {:?}",
            exact_pids
        );
    }
    let identity = bind_record(&record)?
        .context("managed Unix app-server PID record does not name a live exact owner")?;
    Ok(Some(identity))
}

#[cfg(any(target_os = "linux", test))]
fn bind_unrecorded_managed_unix_daemon_with<Scan, Bind>(
    exact_pids: &[u32],
    scan: Scan,
    bind: Bind,
) -> Result<Option<ManagedAppServerIdentity>>
where
    Scan: FnOnce() -> Result<Vec<u32>>,
    Bind: Fn(u32) -> Result<ManagedAppServerIdentity>,
{
    let pid = match exact_pids {
        [] => return Ok(None),
        [pid] => *pid,
        _ => {
            bail!("managed Unix app-server ownership is ambiguous: exact processes {exact_pids:?}")
        }
    };
    let identity = bind(pid)?;
    if scan()?.as_slice() != [pid] || bind(pid)? != identity {
        bail!("managed Unix app-server identity changed during unrecorded discovery");
    }
    Ok(Some(identity))
}

#[cfg(target_os = "linux")]
fn bind_exact_managed_unix_daemon(
    pid: u32,
    current_route: &Path,
    current_runtime: &Path,
    codex_home: &Path,
) -> Result<ManagedAppServerIdentity> {
    let executable = fs::canonicalize(current_runtime)?;
    let metadata = fs::metadata(&executable)?;
    let identity = bind_managed_unix_app_server_identity(
        i32::try_from(pid).context("managed daemon PID exceeds i32")?,
        unsafe { libc::geteuid() },
        executable.clone(),
    )?;
    validate_managed_unix_daemon_codex_home_at(Path::new("/proc"), pid, codex_home)?;
    if identity.kernel_executable_identity.device != metadata.dev()
        || identity.kernel_executable_identity.inode != metadata.ino()
        || linux_process_matches_exact_managed_daemon_with_metadata(
            Path::new("/proc"),
            pid,
            current_route,
            &executable,
            &metadata,
        )? != ExactManagedProcessObservation::Active
        || !crate::reload::process_identity_is_current(&identity.process)
    {
        bail!("managed Unix app-server pid {pid} lost its exact kernel identity");
    }
    Ok(identity)
}

#[cfg(any(target_os = "linux", test))]
fn validate_managed_unix_daemon_codex_home_at(
    proc_root: &Path,
    pid: u32,
    expected_home: &Path,
) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;

    let environment = read_linux_proc_file_bounded(
        &proc_root.join(pid.to_string()).join("environ"),
        MANAGED_DAEMON_CMDLINE_MAX_BYTES,
    )?
    .context("managed Unix daemon environment is unavailable")?;
    let value = |prefix: &[u8]| -> Result<Option<&[u8]>> {
        let mut values = environment
            .split(|byte| *byte == 0)
            .filter_map(|entry| entry.strip_prefix(prefix));
        let first = values.next();
        if values.next().is_some() {
            bail!("managed Unix daemon environment has duplicate home keys");
        }
        Ok(first)
    };
    let codex_home = value(b"CODEX_HOME=")?;
    let home = value(b"HOME=")?;
    let observed_home = match codex_home {
        Some(path) => PathBuf::from(std::ffi::OsStr::from_bytes(path)),
        None => {
            let home = home.context("managed Unix daemon environment has no home identity")?;
            let home = Path::new(std::ffi::OsStr::from_bytes(home));
            if !home.is_absolute() {
                bail!("managed Unix daemon HOME is not absolute");
            }
            home.join(".codex")
        }
    };
    if !observed_home.is_absolute() || !expected_home.is_absolute() {
        bail!("managed Unix daemon CODEX_HOME is not absolute");
    }
    let observed_home = fs::canonicalize(observed_home)
        .context("managed Unix daemon home could not be resolved")?;
    let expected_home =
        fs::canonicalize(expected_home).context("coordinator Codex home could not be resolved")?;
    if observed_home != expected_home || !fs::metadata(&observed_home)?.is_dir() {
        bail!("managed Unix daemon belongs to a different Codex home");
    }
    Ok(())
}

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
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!("managed daemon pid record is owned by another uid");
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
    let Some(current_runtime) = current_runtime else {
        return RuntimeActivityObservation::Unknown(format!(
            "managed daemon pid {} is live, but the installed runtime is unavailable for exact process identity verification",
            record.pid
        ));
    };
    match bind_managed_daemon_pid_record(platform, record, current_runtime, current_runtime) {
        Ok(Some(_)) => RuntimeActivityObservation::Active,
        Ok(None) => RuntimeActivityObservation::Inactive,
        Err(error) => RuntimeActivityObservation::Unknown(format!("{error:#}")),
    }
}

fn bind_managed_daemon_pid_record(
    platform: HostPlatform,
    record: &ManagedDaemonPidRecord,
    expected_argv0: &Path,
    current_runtime: &Path,
) -> Result<Option<ManagedAppServerIdentity>> {
    if platform != HostPlatform::Linux {
        bail!("managed daemon pid identity verification is unavailable on this platform");
    }
    let proc_dir = PathBuf::from(format!("/proc/{}", record.pid));
    let process_metadata = match fs::metadata(&proc_dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => bail!(
            "failed to inspect managed daemon pid {}: {error}",
            record.pid
        ),
    };
    if process_metadata.uid() != unsafe { libc::geteuid() } {
        bail!("managed daemon pid {} is owned by another uid", record.pid);
    }

    let pid = record.pid.to_string();
    let output = bounded_command::output(
        Command::new("/bin/ps").args(["-p", pid.as_str(), "-o", "lstart="]),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    );
    let output = output?;
    if !output.status.success() || output.status.code() != Some(0) || !output.stderr.is_empty() {
        return if fs::metadata(&proc_dir).is_ok() {
            Err(anyhow::anyhow!(
                "failed to verify start identity for managed daemon pid {}",
                record.pid
            ))
        } else {
            Ok(None)
        };
    }
    let observed_start = std::str::from_utf8(&output.stdout)
        .with_context(|| {
            format!(
                "managed daemon pid {} start probe returned non-UTF-8 output",
                record.pid
            )
        })?
        .trim()
        .to_string();
    if observed_start != record.process_start_time {
        bail!(
            "managed daemon pid {} start identity changed from {:?} to {:?}",
            record.pid,
            record.process_start_time,
            observed_start
        );
    }
    match linux_process_matches_exact_managed_daemon_with_argv0(
        record.pid,
        expected_argv0,
        current_runtime,
    ) {
        Ok(ExactManagedProcessObservation::Active) => {
            let pid = i32::try_from(record.pid).context("managed daemon PID exceeds i32")?;
            let executable = fs::canonicalize(current_runtime).with_context(|| {
                format!(
                    "failed to resolve managed Unix runtime {}",
                    current_runtime.display()
                )
            })?;
            bind_managed_unix_app_server_identity(pid, unsafe { libc::geteuid() }, executable)
                .map(Some)
        }
        Ok(ExactManagedProcessObservation::Unrelated) => {
            bail!(
                "managed daemon pid {} is live but does not match the installed runtime inode",
                record.pid
            )
        }
        Ok(ExactManagedProcessObservation::IdentityDrift(error)) => bail!(error),
        Err(error) => Err(error),
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

#[cfg(any(target_os = "linux", test))]
fn scan_linux_exact_managed_unix_daemon_pids(
    expected_argv0: &Path,
    current_runtime: &Path,
) -> Result<Vec<u32>> {
    scan_linux_exact_managed_unix_daemon_pids_at(
        Path::new("/proc"),
        expected_argv0,
        current_runtime,
    )
}

#[cfg(any(target_os = "linux", test))]
fn scan_linux_exact_managed_unix_daemon_pids_at(
    proc_root: &Path,
    expected_argv0: &Path,
    current_runtime: &Path,
) -> Result<Vec<u32>> {
    let expected_metadata = fs::metadata(current_runtime).with_context(|| {
        format!(
            "failed to inspect current managed runtime {}",
            current_runtime.display()
        )
    })?;
    let expected_canonical = fs::canonicalize(current_runtime).with_context(|| {
        format!(
            "failed to resolve current managed runtime {}",
            current_runtime.display()
        )
    })?;
    let entries = fs::read_dir(proc_root)
        .with_context(|| format!("failed to enumerate {}", proc_root.display()))?;
    let started = Instant::now();
    let current_uid = unsafe { libc::geteuid() };
    let mut scanned = 0_usize;
    let mut pids = Vec::new();
    for entry in entries {
        scanned += 1;
        if scanned > MANAGED_DAEMON_PROC_SCAN_MAX_ENTRIES
            || started.elapsed() > MANAGED_DAEMON_PROC_SCAN_TIMEOUT
        {
            bail!("exact managed Unix daemon process scan exceeded its bound");
        }
        let entry = entry
            .with_context(|| format!("failed during exact scan of {}", proc_root.display()))?;
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
            Err(error) => return Err(error).context("failed to inspect process during exact scan"),
        };
        if metadata.uid() != current_uid {
            continue;
        }
        let Some(command_line) = read_linux_proc_file_bounded(
            &entry.path().join("cmdline"),
            MANAGED_DAEMON_CMDLINE_MAX_BYTES,
        )?
        else {
            continue;
        };
        let Some(matched_argv0) =
            exact_managed_daemon_argv0(&command_line, expected_argv0, &expected_canonical)
        else {
            if command_line_is_separate_managed_app_server(&command_line, expected_argv0)
                || command_line_is_separate_managed_app_server(&command_line, &expected_canonical)
            {
                continue;
            }
            // A current-runtime listener with unknown argv is a blocker, not absence.
            let args = managed_process_arguments(&command_line);
            if arguments_have_app_server_subcommand(&args) {
                let process_executable =
                    fs::metadata(entry.path().join("exe")).with_context(|| {
                        format!("failed to inspect app-server pid {pid} executable")
                    })?;
                use std::os::unix::ffi::OsStrExt;
                let claims_route = args.first().copied()
                    == Some(expected_argv0.as_os_str().as_bytes())
                    || args.first().copied() == Some(expected_canonical.as_os_str().as_bytes());
                let uses_current_inode = process_executable.dev() == expected_metadata.dev()
                    && process_executable.ino() == expected_metadata.ino();
                if claims_route || uses_current_inode {
                    bail!("current managed app-server pid {pid} has unsupported argv; Unix ownership is unknown");
                }
            }
            continue;
        };
        match linux_process_matches_exact_managed_daemon_with_metadata(
            proc_root,
            pid,
            matched_argv0,
            &expected_canonical,
            &expected_metadata,
        )? {
            ExactManagedProcessObservation::Active => pids.push(pid),
            ExactManagedProcessObservation::Unrelated => {
                bail!("exact managed Unix daemon pid {pid} lost its runtime identity")
            }
            ExactManagedProcessObservation::IdentityDrift(error) => bail!(error),
        }
    }
    pids.sort_unstable();
    Ok(pids)
}

fn linux_process_matches_exact_managed_daemon(
    pid: u32,
    current_runtime: &Path,
) -> Result<ExactManagedProcessObservation> {
    linux_process_matches_exact_managed_daemon_with_argv0(pid, current_runtime, current_runtime)
}

fn linux_process_matches_exact_managed_daemon_with_argv0(
    pid: u32,
    expected_argv0: &Path,
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
        expected_argv0,
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
    let owner = match fs::metadata(&proc_dir) {
        Ok(metadata) => metadata.uid(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ExactManagedProcessObservation::Unrelated);
        }
        Err(error) => return Err(error).context("failed to inspect managed daemon owner"),
    };
    if owner != unsafe { libc::geteuid() } {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} is owned by another uid"
        )));
    }
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
    let matched_argv0 =
        exact_managed_daemon_argv0(&command_line, expected_argv0, expected_canonical);
    if process_executable.dev() != expected_metadata.dev()
        || process_executable.ino() != expected_metadata.ino()
    {
        if matched_argv0.is_some() {
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
    let Some(matched_argv0) = matched_argv0 else {
        return Ok(ExactManagedProcessObservation::IdentityDrift(format!(
            "managed daemon pid {pid} argv did not match the exact managed daemon command"
        )));
    };
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
        matched_argv0,
        &command_line,
        start_before,
        start_after,
    ) || fs::metadata(&proc_dir)?.uid() != owner
    {
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

fn exact_managed_daemon_argv0<'a>(
    command_line: &[u8],
    current_route: &'a Path,
    current_canonical: &'a Path,
) -> Option<&'a Path> {
    [current_route, current_canonical]
        .into_iter()
        .find(|path| command_line_is_exact_managed_app_server_daemon(command_line, path))
}

fn arguments_have_app_server_subcommand(arguments: &[&[u8]]) -> bool {
    let mut arguments = arguments.iter().skip(1).copied();
    while let Some(argument) = arguments.next() {
        match argument {
            b"app-server" => return true,
            b"-c"
            | b"--config"
            | b"--enable"
            | b"--disable"
            | b"-p"
            | b"--profile"
            | b"-m"
            | b"--model"
            | b"-C"
            | b"--cd"
            | b"-s"
            | b"--sandbox"
            | b"-a"
            | b"--ask-for-approval"
            | b"-i"
            | b"--image"
            | b"--add-dir"
            | b"--local-provider" => {
                arguments.next();
            }
            b"--oss"
            | b"--search"
            | b"--full-auto"
            | b"--no-alt-screen"
            | b"--dangerously-bypass-approvals-and-sandbox" => {}
            _ if argument.len() > 2
                && [b"-c", b"-p", b"-m", b"-C", b"-s", b"-a", b"-i"]
                    .iter()
                    .any(|prefix| argument.starts_with(*prefix)) => {}
            _ if [
                b"--config=".as_slice(),
                b"--enable=",
                b"--disable=",
                b"--profile=",
                b"--model=",
                b"--cd=",
                b"--sandbox=",
                b"--ask-for-approval=",
                b"--image=",
                b"--add-dir=",
                b"--local-provider=",
            ]
            .iter()
            .any(|prefix| argument.starts_with(prefix)) => {}
            _ => return false,
        }
    }
    false
}

fn command_line_is_exact_managed_app_server_daemon(
    command_line: &[u8],
    expected_argv0: &Path,
) -> bool {
    let Some(args) = managed_app_server_arguments(command_line, expected_argv0) else {
        return false;
    };
    args == [b"app-server".as_slice(), b"--listen", b"unix://"]
        || args
            == [
                b"app-server".as_slice(),
                b"--remote-control",
                b"--listen",
                b"unix://",
            ]
}

fn managed_process_arguments(command_line: &[u8]) -> Vec<&[u8]> {
    command_line
        .strip_suffix(&[0])
        .unwrap_or(command_line)
        .split(|byte| *byte == 0)
        .collect()
}

fn managed_app_server_arguments<'a>(
    command_line: &'a [u8],
    expected_argv0: &Path,
) -> Option<Vec<&'a [u8]>> {
    use std::os::unix::ffi::OsStrExt;

    let args = managed_process_arguments(command_line);
    if args.first().copied() != Some(expected_argv0.as_os_str().as_bytes()) {
        return None;
    }
    let tail = &args[1..];
    let tail = tail
        .strip_prefix(&[b"-c".as_slice(), b"features.code_mode_host=true"])
        .unwrap_or(tail);
    Some(tail.to_vec())
}

fn command_line_is_separate_managed_app_server(command_line: &[u8], expected_argv0: &Path) -> bool {
    let Some(args) = managed_app_server_arguments(command_line, expected_argv0) else {
        return false;
    };
    args.starts_with(&[b"app-server".as_slice(), b"proxy"])
        || (args.starts_with(&[b"app-server".as_slice(), b"daemon"])
            && args.get(2).is_some_and(|command| {
                matches!(
                    *command,
                    b"start" | b"stop" | b"restart" | b"status" | b"version" | b"proxy"
                )
            }))
        || args
            == [
                b"app-server".as_slice(),
                b"--remote-control",
                b"--listen",
                b"ws://127.0.0.1:8390",
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

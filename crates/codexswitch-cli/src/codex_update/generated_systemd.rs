fn observe_managed_systemd_unit_activity() -> RuntimeActivityObservation {
    let expectation = match managed_systemd_owner_expectation() {
        Ok(expectation) => expectation,
        Err(error) => return RuntimeActivityObservation::Unknown(format!("{error:#}")),
    };
    if let Err(error) = verify_managed_systemd_fragment(&expectation) {
        return RuntimeActivityObservation::Unknown(format!("{error:#}"));
    }
    observe_managed_systemd_unit_activity_with(&expectation, || probe_managed_systemd_unit())
}

fn verify_managed_systemd_fragment(expectation: &SystemdOwnerExpectation) -> Result<()> {
    let fragment_metadata = match fs::symlink_metadata(&expectation.fragment_path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => metadata,
        Ok(_) => bail!(
            "managed systemd fragment {} is not a regular non-symlink file",
            expectation.fragment_path.display()
        ),
        Err(error) => bail!(
            "failed to inspect managed systemd fragment {}: {error}",
            expectation.fragment_path.display()
        ),
    };
    if fs::canonicalize(&expectation.fragment_path).ok().as_deref()
        != Some(expectation.fragment_path.as_path())
        || fragment_metadata.len() == 0
    {
        bail!(
            "managed systemd fragment {} has drifted provenance",
            expectation.fragment_path.display()
        );
    }
    Ok(())
}

fn probe_managed_systemd_unit() -> Result<CommandProbeOutput> {
    let output = bounded_command::output(
        Command::new("systemctl")
            .arg("--user")
            .arg("show")
            .arg(MANAGED_APP_SERVER_UNIT)
            .args([
                "--property=LoadState",
                "--property=ActiveState",
                "--property=FragmentPath",
                "--property=ExecStart",
                "--property=MainPID",
            ]),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )?;
    Ok(CommandProbeOutput {
        success: output.status.success(),
        exit_code: output.status.code(),
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

#[cfg(target_os = "linux")]
pub(crate) fn managed_headless_app_server_identity(
) -> Result<Option<ManagedHeadlessAppServerIdentity>> {
    let expectation = managed_systemd_owner_expectation()?;
    verify_managed_systemd_fragment(&expectation)?;
    let output = probe_managed_systemd_unit()?;
    match systemd_activity_from_probe(
        output.success,
        output.exit_code,
        &output.stdout,
        &output.stderr,
        &expectation,
    ) {
        RuntimeActivityObservation::Inactive => return Ok(None),
        RuntimeActivityObservation::Unknown(error) => bail!(error),
        RuntimeActivityObservation::Active => {}
    }
    let output = std::str::from_utf8(&output.stdout).context("systemctl output was not UTF-8")?;
    let pid = output
        .lines()
        .find_map(|line| line.strip_prefix("MainPID="))
        .context("verified systemd observation omitted MainPID")?
        .parse::<i32>()
        .context("verified systemd MainPID was invalid")?;
    if pid <= 0 {
        bail!("verified active systemd unit reported a non-positive MainPID");
    }
    let executable = expectation
        .exec_argv
        .windows(2)
        .find_map(|pair| (pair[1] == "app-server").then(|| PathBuf::from(&pair[0])))
        .context("managed systemd ExecStart omitted the Codex runtime executable")?;
    let executable = fs::canonicalize(&executable).with_context(|| {
        format!(
            "failed to resolve managed systemd runtime {}",
            executable.display()
        )
    })?;
    bind_managed_headless_app_server_identity(pid, unsafe { libc::geteuid() }, executable).map(Some)
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn managed_headless_app_server_identity(
) -> Result<Option<ManagedHeadlessAppServerIdentity>> {
    Ok(None)
}

fn observe_managed_systemd_unit_activity_with<Probe>(
    expectation: &SystemdOwnerExpectation,
    probe: Probe,
) -> RuntimeActivityObservation
where
    Probe: FnOnce() -> Result<CommandProbeOutput>,
{
    let output = match probe() {
        Ok(output) => output,
        Err(error) => return RuntimeActivityObservation::Unknown(format!("{error:#}")),
    };
    systemd_activity_from_probe(
        output.success,
        output.exit_code,
        &output.stdout,
        &output.stderr,
        expectation,
    )
}

fn systemd_activity_from_probe(
    success: bool,
    exit_code: Option<i32>,
    stdout: &[u8],
    stderr: &[u8],
    expectation: &SystemdOwnerExpectation,
) -> RuntimeActivityObservation {
    if !success || exit_code != Some(0) {
        return RuntimeActivityObservation::Unknown(format!(
            "systemctl returned exit code {exit_code:?} while observing exact unit ownership"
        ));
    }
    if !stderr.is_empty() {
        return RuntimeActivityObservation::Unknown(
            "systemctl emitted stderr while observing exact unit ownership".to_string(),
        );
    }
    let output = match std::str::from_utf8(stdout) {
        Ok(output) => output,
        Err(error) => {
            return RuntimeActivityObservation::Unknown(format!(
                "systemctl returned non-UTF-8 output: {error}"
            ));
        }
    };
    let mut properties = HashMap::new();
    for line in output.lines() {
        let Some((key, value)) = line.split_once('=') else {
            return RuntimeActivityObservation::Unknown(
                "systemctl returned malformed property output".to_string(),
            );
        };
        if properties.insert(key, value).is_some() {
            return RuntimeActivityObservation::Unknown(format!(
                "systemctl returned duplicate property {key}"
            ));
        }
    }
    for property in [
        "LoadState",
        "ActiveState",
        "FragmentPath",
        "ExecStart",
        "MainPID",
    ] {
        if !properties.contains_key(property) {
            return RuntimeActivityObservation::Unknown(format!("systemctl omitted {property}"));
        }
    }
    if properties.len() != 5 || properties["LoadState"] != "loaded" {
        return RuntimeActivityObservation::Unknown(format!(
            "systemd unit load state was {:?}",
            properties.get("LoadState")
        ));
    }
    if properties["FragmentPath"] != expectation.fragment_path.to_string_lossy() {
        return RuntimeActivityObservation::Unknown(format!(
            "systemd fragment provenance drifted to {:?}",
            properties["FragmentPath"]
        ));
    }
    let observed_argv = match systemd_exec_start_argv(properties["ExecStart"]) {
        Some(argv) => argv,
        None => {
            return RuntimeActivityObservation::Unknown(
                "systemd ExecStart provenance was malformed".to_string(),
            );
        }
    };
    if observed_argv != expectation.exec_argv {
        return RuntimeActivityObservation::Unknown(format!(
            "systemd ExecStart provenance drifted: {observed_argv:?}"
        ));
    }
    let main_pid = properties["MainPID"];
    if main_pid.is_empty() || !main_pid.bytes().all(|byte| byte.is_ascii_digit()) {
        return RuntimeActivityObservation::Unknown(format!(
            "systemd MainPID {main_pid:?} was malformed"
        ));
    }
    match properties["ActiveState"] {
        "active" | "activating" | "reloading" | "deactivating" => {
            RuntimeActivityObservation::Active
        }
        "inactive" if main_pid == "0" => RuntimeActivityObservation::Inactive,
        "inactive" => RuntimeActivityObservation::Unknown(format!(
            "systemd reported inactive with stale MainPID {main_pid}"
        )),
        state => RuntimeActivityObservation::Unknown(format!(
            "systemd active state {state:?} is not positive inactive evidence"
        )),
    }
}

fn managed_systemd_owner_expectation() -> Result<SystemdOwnerExpectation> {
    let home = home_dir()?;
    let data_dir = codexswitch_data_dir()?;
    let codex_home = managed_daemon_codex_home()?;
    let systemd_root = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(path) => {
            let path = PathBuf::from(path);
            if !path.is_absolute() {
                bail!("XDG_CONFIG_HOME must be absolute for systemd ownership observation");
            }
            path.join("systemd/user")
        }
        None => home.join(".config/systemd/user"),
    };
    Ok(SystemdOwnerExpectation {
        fragment_path: systemd_root.join(MANAGED_APP_SERVER_UNIT),
        exec_argv: vec![
            "/usr/bin/flock".to_string(),
            "--shared".to_string(),
            "--no-fork".to_string(),
            runtime_start_install_guard_path(&data_dir)
                .display()
                .to_string(),
            "/usr/bin/flock".to_string(),
            "--exclusive".to_string(),
            "--nonblock".to_string(),
            "--no-fork".to_string(),
            codex_home
                .join("app-server-daemon/app-server.pid.lock")
                .display()
                .to_string(),
            data_dir
                .join("current/patched-codex/codex")
                .display()
                .to_string(),
            "app-server".to_string(),
            "--remote-control".to_string(),
            "--listen".to_string(),
            "ws://127.0.0.1:8390".to_string(),
        ],
    })
}

fn systemd_exec_start_argv(value: &str) -> Option<Vec<String>> {
    let path = value
        .split(" ; ")
        .find_map(|field| field.trim().strip_prefix("{ path="))
        .or_else(|| {
            value
                .split(" ; ")
                .find_map(|field| field.trim().strip_prefix("path="))
        })?;
    if path != "/usr/bin/flock" {
        return None;
    }
    let argv = value.split("argv[]=").nth(1)?.split(" ; ").next()?.trim();
    if argv.is_empty()
        || argv
            .chars()
            .any(|character| matches!(character, '\'' | '"' | '\\'))
    {
        return None;
    }
    Some(argv.split_whitespace().map(str::to_string).collect())
}

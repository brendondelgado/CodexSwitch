fn patch_turn_rotation_templates(path: &Path) -> Result<()> {
    patch_file_before_any(
        path,
        &[
            "/// Takes a user message as input and runs a loop where, at each sampling request, the model",
            "/// Takes initial turn input and runs a loop where, at each sampling request,",
        ],
        r#"#[cfg(unix)]
fn codexswitch_rotation_timeout() -> std::time::Duration {
    const DEFAULT_SECONDS: u64 = 120;
    const MAX_SECONDS: u64 = 600;
    let seconds = std::env::var("CODEXSWITCH_ROTATE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .unwrap_or(DEFAULT_SECONDS)
        .min(MAX_SECONDS);
    std::time::Duration::from_secs(seconds)
}

#[cfg(unix)]
fn codexswitch_read_bounded_json(
    path: &std::path::Path,
    max_bytes: u64,
) -> Option<serde_json::Value> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() > max_bytes {
        return None;
    }
    let mut data = Vec::with_capacity(metadata.len() as usize);
    let mut limited = std::io::Read::take(&mut file, max_bytes + 1);
    std::io::Read::read_to_end(&mut limited, &mut data).ok()?;
    if data.len() as u64 > max_bytes {
        return None;
    }
    serde_json::from_slice(&data).ok()
}

#[cfg(target_os = "linux")]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let after_command = stat.get(stat.rfind(')')? + 1..)?.trim_start();
    let start_ticks = after_command.split_whitespace().nth(19)?.parse::<u64>().ok()?;
    let boot_time = std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))?
        .parse::<u64>()
        .ok()?;
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks_per_second <= 0 {
        return None;
    }
    let ticks_per_second = ticks_per_second as u64;
    Some((
        boot_time.saturating_add(start_ticks / ticks_per_second),
        (start_ticks % ticks_per_second).saturating_mul(1_000_000) / ticks_per_second,
    ))
}

#[cfg(target_os = "macos")]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let expected_size = std::mem::size_of::<libc::proc_bsdinfo>();
    let pid = std::process::id() as i32;
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
    (info.pbi_pid == std::process::id())
        .then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    None
}

#[cfg(unix)]
fn codexswitch_bound_auth_path_v3() -> Option<(std::path::PathBuf, String, String)> {
    use std::os::unix::fs::MetadataExt;
    const ACK_MAX_BYTES: u64 = 64 * 1024;
    const REQUEST_MAX_BYTES: u64 = 16 * 1024;
    const ACK_MAX_AGE_MILLISECONDS: u64 = 5 * 60 * 1_000;
    let home = std::env::var_os("HOME")?;
    let pid = std::process::id();
    let root = std::path::PathBuf::from(home).join(".codexswitch");
    let ack_path = root.join("hotswap-ack").join(format!("{pid}.json"));
    let request_path = root.join("hotswap-request").join(format!("{pid}.json"));
    let ack = codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES)?;
    let request = codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES)?;
    if request.as_object()?.len() != 1 {
        return None;
    }
    let binding = request.get("binding")?;
    if ack.get("binding")? != binding
        || binding.get("contractVersion")?.as_u64()? != 3
        || binding.get("runtimeKind")?.as_str()? != "local-interactive-cli"
    {
        return None;
    }

    let process = binding.get("processIdentity")?;
    let (start_seconds, start_microseconds) = codexswitch_current_start_identity()?;
    let executable = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    let executable_text = executable.to_str()?;
    let executable_metadata = std::fs::metadata(&executable).ok()?;
    if process.get("pid")?.as_u64()? != u64::from(pid)
        || process.get("ownerUID")?.as_u64()? != u64::from(unsafe { libc::geteuid() })
        || process.get("executablePath")?.as_str()? != executable_text
        || process.get("startSeconds")?.as_u64()? != start_seconds
        || process.get("startMicroseconds")?.as_u64()? != start_microseconds
    {
        return None;
    }
    let kernel = binding.get("kernelExecutableIdentity")?;
    if kernel.get("canonicalPath")?.as_str()? != executable_text
        || kernel.get("device")?.as_u64()? != executable_metadata.dev()
        || kernel.get("inode")?.as_u64()? != executable_metadata.ino()
    {
        return None;
    }

    let auth = binding.get("authFileIdentity")?;
    let auth_path = std::path::PathBuf::from(auth.get("canonicalPath")?.as_str()?);
    let auth_metadata = std::fs::symlink_metadata(&auth_path).ok()?;
    let provider_account_id = auth.get("accountID")?.as_str()?;
    let fingerprint = auth.get("completeTokenFingerprint")?.as_str()?;
    if !auth_path.is_absolute()
        || auth_metadata.file_type().is_symlink()
        || !auth_metadata.is_file()
        || auth_metadata.uid() != unsafe { libc::geteuid() }
        || std::fs::canonicalize(&auth_path).ok()? != auth_path
        || auth.get("device")?.as_u64()? != auth_metadata.dev()
        || auth.get("inode")?.as_u64()? != auth_metadata.ino()
        || provider_account_id.is_empty()
        || provider_account_id.len() > 1024
        || !provider_account_id
            .bytes()
            .all(|byte| (0x21..=0x7e).contains(&byte))
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }

    let nonce = binding.get("requestNonce")?.as_str()?;
    let issued_at = binding.get("issuedAtUnixMilliseconds")?.as_u64()?;
    let acknowledged_at = ack.get("acknowledgedAtUnixMilliseconds")?.as_u64()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_millis() as u64;
    let started_at = start_seconds
        .saturating_mul(1_000)
        .saturating_add(start_microseconds / 1_000);
    if nonce.is_empty()
        || nonce.len() > 256
        || issued_at < started_at
        || acknowledged_at < issued_at
        || acknowledged_at > now.saturating_add(60_000)
        || now.saturating_sub(acknowledged_at) > ACK_MAX_AGE_MILLISECONDS
        || ack.get("loadedTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("activeTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("frontendNotified")?.as_bool()? != false
        || ack.get("frontendWriteCount")?.as_u64()? != 0
        || ack.get("authGeneration")?.as_u64().is_none()
        || ack.get("reconnectReady")?.as_bool()? != true
    {
        return None;
    }
    Some((
        auth_path,
        fingerprint.to_string(),
        provider_account_id.to_string(),
    ))
}

#[cfg(unix)]
async fn codexswitch_capture_bounded_stream<R>(
    mut stream: R,
    max_bytes: usize,
) -> std::io::Result<(Vec<u8>, bool)>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut captured = Vec::with_capacity(max_bytes.min(16 * 1024));
    let mut exceeded = false;
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let count = tokio::io::AsyncReadExt::read(&mut stream, &mut chunk).await?;
        if count == 0 {
            break;
        }
        let remaining = max_bytes.saturating_sub(captured.len());
        let keep = remaining.min(count);
        captured.extend_from_slice(&chunk[..keep]);
        exceeded |= keep < count;
    }
    Ok((captured, exceeded))
}

#[cfg(unix)]
async fn codexswitch_run_bounded_rotation(
    mut command: tokio::process::Command,
) -> Option<std::process::Output> {
    const OUTPUT_MAX_BYTES: usize = 64 * 1024;
    command
        .kill_on_drop(true)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = command.spawn().ok()?;
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill().await;
        let _ = child.wait().await;
        return None;
    };
    let joined = tokio::time::timeout(codexswitch_rotation_timeout(), async {
        tokio::join!(
            codexswitch_capture_bounded_stream(stdout, OUTPUT_MAX_BYTES),
            codexswitch_capture_bounded_stream(stderr, OUTPUT_MAX_BYTES),
            child.wait(),
        )
    })
    .await;
    let (stdout, stderr, status) = match joined {
        Ok((Ok(stdout), Ok(stderr), Ok(status))) => (stdout, stderr, status),
        _ => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return None;
        }
    };
    if stdout.1 || stderr.1 {
        return None;
    }
    Some(std::process::Output {
        status,
        stdout: stdout.0,
        stderr: stderr.0,
    })
}

#[cfg(unix)]
fn codexswitch_verified_rotation_result(
    output: &std::process::Output,
    auth_path: &std::path::Path,
) -> Option<String> {
    let report = serde_json::from_slice::<serde_json::Value>(&output.stdout).ok()?;
    if report.get("authPath")?.as_str()? != auth_path.to_str()?
        || report.get("activationState")?.as_str()? != "confirmed"
        || report.get("runtimeConverged")?.as_bool()? != true
        || report.get("signaledProcesses")?.as_u64()? == 0
        || report.get("skippedProcesses")?.as_u64()? != 0
    {
        return None;
    }
    let fingerprint = report.get("nextTokenFingerprint")?.as_str()?;
    (!fingerprint.is_empty()).then(|| fingerprint.to_string())
}

#[cfg(unix)]
async fn codexswitch_rotate_after_usage_limit(sess: &Session, turn_context: &TurnContext) -> bool {
    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {
        warn!("CodexSwitch usage-limit rotation cannot bind auth without the turn AuthManager");
        return false;
    };
    let Some((auth_path, bound_fingerprint, bound_provider_account_id)) =
        codexswitch_bound_auth_path_v3()
    else {
        warn!("codexswitch-runtime-rotation-handoff-v1: no verified runtime auth path binding");
        return false;
    };
    let observed_identity = auth_manager.codexswitch_auth_file_identity(&auth_path).ok();
    if observed_identity
        .as_ref()
        .map(|(fingerprint, account_id)| (fingerprint.as_str(), account_id.as_str()))
        != Some((bound_fingerprint.as_str(), bound_provider_account_id.as_str()))
    {
        warn!("CodexSwitch usage-limit rotation rejected changed on-disk auth evidence");
        return false;
    }
    let cli = std::env::var("CODEXSWITCH_CLI").unwrap_or_else(|_| "codexswitch-cli".to_string());
    let mut command = tokio::process::Command::new(cli);
    command
        .arg("--auth")
        .arg(&auth_path)
        .arg("rotate-now")
        .arg("--reason")
        .arg("usage_limit")
        .arg("--cooldown-seconds")
        .arg("18000")
        .arg("--json");
    let Some(output) = codexswitch_run_bounded_rotation(command).await else {
        warn!("CodexSwitch usage-limit rotation failed or timed out");
        return false;
    };
    if !output.status.success() {
        warn!(
            "CodexSwitch usage-limit rotation exited with status {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        return false;
    }
    let Some(expected_fingerprint) = codexswitch_verified_rotation_result(&output, &auth_path) else {
        warn!("CodexSwitch usage-limit rotation did not prove the runtime handoff contract");
        return false;
    };

    let Ok((_changed, loaded_hash, active_hash)) = auth_manager
        .codexswitch_reload_auth_json_verified(&auth_path)
        .await
    else {
        warn!("CodexSwitch usage-limit rotation could not verify the turn AuthManager reload");
        return false;
    };
    if loaded_hash != expected_fingerprint || active_hash != expected_fingerprint {
        warn!("CodexSwitch usage-limit rotation fingerprint convergence failed");
        return false;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: "CodexSwitch rotated accounts after a usage limit and is retrying this turn.".to_string(),
        }),
    )
    .await;
    true
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_usage_limit(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

"#,
        "codexswitch_rotate_after_usage_limit",
    )?;
    patch_file_after(
        path,
        "async fn codexswitch_rotate_after_usage_limit(_sess: &Session, _turn_context: &TurnContext) -> bool {\n    false\n}\n",
        r#"

#[cfg(unix)]
async fn codexswitch_rotate_after_auth_failure(sess: &Session, turn_context: &TurnContext) -> bool {
    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {
        warn!("CodexSwitch auth-failure rotation cannot bind auth without the turn AuthManager");
        return false;
    };
    let Some((auth_path, bound_fingerprint, bound_provider_account_id)) =
        codexswitch_bound_auth_path_v3()
    else {
        warn!("codexswitch-runtime-rotation-handoff-v1: no verified runtime auth path binding");
        return false;
    };
    let observed_identity = auth_manager.codexswitch_auth_file_identity(&auth_path).ok();
    if observed_identity
        .as_ref()
        .map(|(fingerprint, account_id)| (fingerprint.as_str(), account_id.as_str()))
        != Some((bound_fingerprint.as_str(), bound_provider_account_id.as_str()))
    {
        warn!("CodexSwitch auth-failure rotation rejected changed on-disk auth evidence");
        return false;
    }
    let cli = std::env::var("CODEXSWITCH_CLI").unwrap_or_else(|_| "codexswitch-cli".to_string());
    let mut command = tokio::process::Command::new(cli);
    command
        .arg("--auth")
        .arg(&auth_path)
        .arg("rotate-now")
        .arg("--reason")
        .arg("token_expired")
        .arg("--cooldown-seconds")
        .arg("2592000")
        .arg("--json");
    let Some(output) = codexswitch_run_bounded_rotation(command).await else {
        warn!("CodexSwitch auth-failure rotation failed or timed out");
        return false;
    };
    if !output.status.success() {
        warn!(
            "CodexSwitch auth-failure rotation exited with status {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        return false;
    }
    let Some(expected_fingerprint) = codexswitch_verified_rotation_result(&output, &auth_path) else {
        warn!("CodexSwitch auth-failure rotation did not prove the runtime handoff contract");
        return false;
    };

    let Ok((_changed, loaded_hash, active_hash)) = auth_manager
        .codexswitch_reload_auth_json_verified(&auth_path)
        .await
    else {
        warn!("CodexSwitch auth-failure rotation could not verify the turn AuthManager reload");
        return false;
    };
    if loaded_hash != expected_fingerprint || active_hash != expected_fingerprint {
        warn!("CodexSwitch auth-failure rotation fingerprint convergence failed");
        return false;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: "CodexSwitch rotated accounts after an auth failure and is retrying this turn.".to_string(),
        }),
    )
    .await;
    true
}

#[cfg(unix)]
fn codexswitch_is_auth_invalidated_error(error: &CodexErr) -> bool {
    if matches!(error, CodexErr::RefreshTokenFailed(_)) {
        return true;
    }
    let message = error.to_string().to_ascii_lowercase();
    message.contains("token_invalidated")
        || message.contains("authentication token has been invalidated")
        || message.contains("access token could not be refreshed")
        || message.contains("signed in to another account")
        || (message.contains("401") && message.contains("unauthorized"))
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_auth_failure(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

#[cfg(not(unix))]
fn codexswitch_is_auth_invalidated_error(_error: &CodexErr) -> bool {
    false
}
"#,
        "codexswitch_rotate_after_auth_failure",
    )?;
    patch_file_before(
        path,
        "#[cfg(unix)]\nasync fn codexswitch_rotate_after_usage_limit",
        r#"#[cfg(unix)]
fn codexswitch_rotation_timeout() -> std::time::Duration {
    const DEFAULT_SECONDS: u64 = 120;
    const MAX_SECONDS: u64 = 600;
    let seconds = std::env::var("CODEXSWITCH_ROTATE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .unwrap_or(DEFAULT_SECONDS)
        .min(MAX_SECONDS);
    std::time::Duration::from_secs(seconds)
}

"#,
        "CODEXSWITCH_ROTATE_TIMEOUT_SECONDS",
    )?;
    patch_file_before(
        path,
        "#[cfg(unix)]\nasync fn codexswitch_rotate_after_usage_limit",
        r#"#[cfg(unix)]
fn codexswitch_read_bounded_json(
    path: &std::path::Path,
    max_bytes: u64,
) -> Option<serde_json::Value> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() > max_bytes {
        return None;
    }
    let mut data = Vec::with_capacity(metadata.len() as usize);
    let mut limited = std::io::Read::take(&mut file, max_bytes + 1);
    std::io::Read::read_to_end(&mut limited, &mut data).ok()?;
    if data.len() as u64 > max_bytes {
        return None;
    }
    serde_json::from_slice(&data).ok()
}

#[cfg(target_os = "linux")]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let after_command = stat.get(stat.rfind(')')? + 1..)?.trim_start();
    let start_ticks = after_command.split_whitespace().nth(19)?.parse::<u64>().ok()?;
    let boot_time = std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))?
        .parse::<u64>()
        .ok()?;
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks_per_second <= 0 {
        return None;
    }
    let ticks_per_second = ticks_per_second as u64;
    Some((
        boot_time.saturating_add(start_ticks / ticks_per_second),
        (start_ticks % ticks_per_second).saturating_mul(1_000_000) / ticks_per_second,
    ))
}

#[cfg(target_os = "macos")]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let expected_size = std::mem::size_of::<libc::proc_bsdinfo>();
    let pid = std::process::id() as i32;
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
    (info.pbi_pid == std::process::id())
        .then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn codexswitch_current_start_identity() -> Option<(u64, u64)> {
    None
}

#[cfg(unix)]
fn codexswitch_bound_auth_path_v3() -> Option<(std::path::PathBuf, String, String)> {
    use std::os::unix::fs::MetadataExt;
    const ACK_MAX_BYTES: u64 = 64 * 1024;
    const REQUEST_MAX_BYTES: u64 = 16 * 1024;
    const ACK_MAX_AGE_MILLISECONDS: u64 = 5 * 60 * 1_000;
    let home = std::env::var_os("HOME")?;
    let pid = std::process::id();
    let root = std::path::PathBuf::from(home).join(".codexswitch");
    let ack_path = root.join("hotswap-ack").join(format!("{pid}.json"));
    let request_path = root.join("hotswap-request").join(format!("{pid}.json"));
    let ack = codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES)?;
    let request = codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES)?;
    if request.as_object()?.len() != 1 {
        return None;
    }
    let binding = request.get("binding")?;
    if ack.get("binding")? != binding
        || binding.get("contractVersion")?.as_u64()? != 3
        || binding.get("runtimeKind")?.as_str()? != "local-interactive-cli"
    {
        return None;
    }

    let process = binding.get("processIdentity")?;
    let (start_seconds, start_microseconds) = codexswitch_current_start_identity()?;
    let executable = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    let executable_text = executable.to_str()?;
    let executable_metadata = std::fs::metadata(&executable).ok()?;
    if process.get("pid")?.as_u64()? != u64::from(pid)
        || process.get("ownerUID")?.as_u64()? != u64::from(unsafe { libc::geteuid() })
        || process.get("executablePath")?.as_str()? != executable_text
        || process.get("startSeconds")?.as_u64()? != start_seconds
        || process.get("startMicroseconds")?.as_u64()? != start_microseconds
    {
        return None;
    }
    let kernel = binding.get("kernelExecutableIdentity")?;
    if kernel.get("canonicalPath")?.as_str()? != executable_text
        || kernel.get("device")?.as_u64()? != executable_metadata.dev()
        || kernel.get("inode")?.as_u64()? != executable_metadata.ino()
    {
        return None;
    }

    let auth = binding.get("authFileIdentity")?;
    let auth_path = std::path::PathBuf::from(auth.get("canonicalPath")?.as_str()?);
    let auth_metadata = std::fs::symlink_metadata(&auth_path).ok()?;
    let provider_account_id = auth.get("accountID")?.as_str()?;
    let fingerprint = auth.get("completeTokenFingerprint")?.as_str()?;
    if !auth_path.is_absolute()
        || auth_metadata.file_type().is_symlink()
        || !auth_metadata.is_file()
        || auth_metadata.uid() != unsafe { libc::geteuid() }
        || std::fs::canonicalize(&auth_path).ok()? != auth_path
        || auth.get("device")?.as_u64()? != auth_metadata.dev()
        || auth.get("inode")?.as_u64()? != auth_metadata.ino()
        || provider_account_id.is_empty()
        || provider_account_id.len() > 1024
        || !provider_account_id
            .bytes()
            .all(|byte| (0x21..=0x7e).contains(&byte))
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }

    let nonce = binding.get("requestNonce")?.as_str()?;
    let issued_at = binding.get("issuedAtUnixMilliseconds")?.as_u64()?;
    let acknowledged_at = ack.get("acknowledgedAtUnixMilliseconds")?.as_u64()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_millis() as u64;
    let started_at = start_seconds
        .saturating_mul(1_000)
        .saturating_add(start_microseconds / 1_000);
    if nonce.is_empty()
        || nonce.len() > 256
        || issued_at < started_at
        || acknowledged_at < issued_at
        || acknowledged_at > now.saturating_add(60_000)
        || now.saturating_sub(acknowledged_at) > ACK_MAX_AGE_MILLISECONDS
        || ack.get("loadedTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("activeTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("frontendNotified")?.as_bool()? != false
        || ack.get("frontendWriteCount")?.as_u64()? != 0
        || ack.get("authGeneration")?.as_u64().is_none()
        || ack.get("reconnectReady")?.as_bool()? != true
    {
        return None;
    }
    Some((
        auth_path,
        fingerprint.to_string(),
        provider_account_id.to_string(),
    ))
}

#[cfg(unix)]
async fn codexswitch_capture_bounded_stream<R>(
    mut stream: R,
    max_bytes: usize,
) -> std::io::Result<(Vec<u8>, bool)>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut captured = Vec::with_capacity(max_bytes.min(16 * 1024));
    let mut exceeded = false;
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let count = tokio::io::AsyncReadExt::read(&mut stream, &mut chunk).await?;
        if count == 0 {
            break;
        }
        let remaining = max_bytes.saturating_sub(captured.len());
        let keep = remaining.min(count);
        captured.extend_from_slice(&chunk[..keep]);
        exceeded |= keep < count;
    }
    Ok((captured, exceeded))
}

#[cfg(unix)]
async fn codexswitch_run_bounded_rotation(
    mut command: tokio::process::Command,
) -> Option<std::process::Output> {
    const OUTPUT_MAX_BYTES: usize = 64 * 1024;
    command
        .kill_on_drop(true)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = command.spawn().ok()?;
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill().await;
        let _ = child.wait().await;
        return None;
    };
    let joined = tokio::time::timeout(codexswitch_rotation_timeout(), async {
        tokio::join!(
            codexswitch_capture_bounded_stream(stdout, OUTPUT_MAX_BYTES),
            codexswitch_capture_bounded_stream(stderr, OUTPUT_MAX_BYTES),
            child.wait(),
        )
    })
    .await;
    let (stdout, stderr, status) = match joined {
        Ok((Ok(stdout), Ok(stderr), Ok(status))) => (stdout, stderr, status),
        _ => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return None;
        }
    };
    if stdout.1 || stderr.1 {
        return None;
    }
    Some(std::process::Output {
        status,
        stdout: stdout.0,
        stderr: stderr.0,
    })
}

#[cfg(unix)]
fn codexswitch_verified_rotation_result(
    output: &std::process::Output,
    auth_path: &std::path::Path,
) -> Option<String> {
    const OUTPUT_MAX_BYTES: usize = 64 * 1024;
    if output.stdout.len() > OUTPUT_MAX_BYTES || output.stderr.len() > OUTPUT_MAX_BYTES {
        return None;
    }
    let report = serde_json::from_slice::<serde_json::Value>(&output.stdout).ok()?;
    if report.get("authPath")?.as_str()? != auth_path.to_str()?
        || report.get("activationState")?.as_str()? != "confirmed"
        || report.get("runtimeConverged")?.as_bool()? != true
        || report.get("signaledProcesses")?.as_u64()? == 0
        || report.get("skippedProcesses")?.as_u64()? != 0
    {
        return None;
    }
    let fingerprint = report.get("nextTokenFingerprint")?.as_str()?;
    (!fingerprint.is_empty()).then(|| fingerprint.to_string())
}

// codexswitch-runtime-rotation-handoff-v1
"#,
        "fn codexswitch_run_bounded_rotation(",
    )?;
    patch_file_after(
        path,
        "async fn codexswitch_rotate_after_usage_limit(sess: &Session, turn_context: &TurnContext) -> bool {",
        r#"
    let Some((auth_path, bound_fingerprint, bound_provider_account_id)) =
        codexswitch_bound_auth_path_v3()
    else {
        warn!("codexswitch-runtime-rotation-handoff-v1: no verified runtime auth path binding");
        return false;
    };
    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {
        warn!("CodexSwitch rotation cannot bind auth without the turn AuthManager");
        return false;
    };
    let observed_identity = auth_manager.codexswitch_auth_file_identity(&auth_path).ok();
    if observed_identity
        .as_ref()
        .map(|(fingerprint, account_id)| (fingerprint.as_str(), account_id.as_str()))
        != Some((bound_fingerprint.as_str(), bound_provider_account_id.as_str()))
    {
        warn!("CodexSwitch rotation rejected changed on-disk auth evidence");
        return false;
    }"#,
        "codexswitch-runtime-rotation-handoff-v1: no verified runtime auth path binding",
    )?;
    patch_all(
        path,
        "        std::time::Duration::from_secs(10),\n        tokio::process::Command::new(cli)",
        "        codexswitch_rotation_timeout(),\n        tokio::process::Command::new(cli)",
    )?;
    patch_all(
        path,
        "        tokio::process::Command::new(cli)\n            .arg(\"rotate-now\")\n            .arg(\"--no-reload\")\n            .arg(\"--reason\")",
        "        tokio::process::Command::new(cli)\n            .arg(\"--auth\")\n            .arg(&auth_path)\n            .arg(\"rotate-now\")\n            .arg(\"--reason\")",
    )?;
    patch_all(
        path,
        "        tokio::process::Command::new(cli)\n            .arg(\"rotate-now\")\n            .arg(\"--reason\")",
        "        tokio::process::Command::new(cli)\n            .arg(\"--auth\")\n            .arg(&auth_path)\n            .arg(\"rotate-now\")\n            .arg(\"--reason\")",
    )?;
    patch_all(
        path,
        "        tokio::process::Command::new(cli)\n            .arg(\"--auth\")",
        "        tokio::process::Command::new(cli)\n            .kill_on_drop(true)\n            .arg(\"--auth\")",
    )?;
    patch_all(
        path,
        "    let rotate = tokio::time::timeout(\n        codexswitch_rotation_timeout(),\n        tokio::process::Command::new(cli)\n            .kill_on_drop(true)\n            .arg(\"--auth\")\n            .arg(&auth_path)\n            .arg(\"rotate-now\")\n            .arg(\"--reason\")\n            .arg(\"usage_limit\")\n            .arg(\"--cooldown-seconds\")\n            .arg(\"18000\")\n            .arg(\"--json\")\n            .output(),\n    )\n    .await;\n\n    let Ok(Ok(output)) = rotate else {",
        "    let mut command = tokio::process::Command::new(cli);\n    command\n        .arg(\"--auth\")\n        .arg(&auth_path)\n        .arg(\"rotate-now\")\n        .arg(\"--reason\")\n        .arg(\"usage_limit\")\n        .arg(\"--cooldown-seconds\")\n        .arg(\"18000\")\n        .arg(\"--json\");\n    let Some(output) = codexswitch_run_bounded_rotation(command).await else {",
    )?;
    patch_all(
        path,
        "    let rotate = tokio::time::timeout(\n        codexswitch_rotation_timeout(),\n        tokio::process::Command::new(cli)\n            .kill_on_drop(true)\n            .arg(\"--auth\")\n            .arg(&auth_path)\n            .arg(\"rotate-now\")\n            .arg(\"--reason\")\n            .arg(\"token_expired\")\n            .arg(\"--cooldown-seconds\")\n            .arg(\"2592000\")\n            .arg(\"--json\")\n            .output(),\n    )\n    .await;\n\n    let Ok(Ok(output)) = rotate else {",
        "    let mut command = tokio::process::Command::new(cli);\n    command\n        .arg(\"--auth\")\n        .arg(&auth_path)\n        .arg(\"rotate-now\")\n        .arg(\"--reason\")\n        .arg(\"token_expired\")\n        .arg(\"--cooldown-seconds\")\n        .arg(\"2592000\")\n        .arg(\"--json\");\n    let Some(output) = codexswitch_run_bounded_rotation(command).await else {",
    )?;
    patch_all(
        path,
        "    if let Some(auth_manager) = turn_context.auth_manager.as_ref() {\n        auth_manager.reload().await;\n    }",
        "    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {\n        warn!(\"CodexSwitch rotation succeeded but the turn AuthManager is unavailable\");\n        return false;\n    };\n    let Some(expected_fingerprint) = codexswitch_verified_rotation_result(&output, &auth_path) else {\n        warn!(\"CodexSwitch rotation did not prove the runtime handoff contract\");\n        return false;\n    };\n    let Ok((_changed, loaded_hash, active_hash)) = auth_manager\n        .codexswitch_reload_auth_json_verified(&auth_path)\n        .await\n    else {\n        warn!(\"CodexSwitch rotation could not verify the turn AuthManager reload\");\n        return false;\n    };\n    if loaded_hash != expected_fingerprint || active_hash != expected_fingerprint {\n        warn!(\"CodexSwitch rotation fingerprint convergence failed\");\n        return false;\n    }",
    )?;
    patch_file_after(
        path,
        "    let mut retries = 0;",
        r#"
    let mut codexswitch_usage_limit_retry_attempted = false;
    let mut codexswitch_auth_failure_retry_attempted = false;"#,
        "codexswitch_usage_limit_retry_attempted",
    )?;
    patch_file_after(
        path,
        "    let mut retries = 0;",
        r#"
    let mut codexswitch_auth_failure_retry_attempted = false;"#,
        "codexswitch_auth_failure_retry_attempted",
    )?;
    patch_file_after(
        path,
        "                if let Some(rate_limits) = rate_limits {\n                    sess.update_rate_limits(&turn_context, *rate_limits).await;\n                }",
        r#"
                if !codexswitch_usage_limit_retry_attempted
                    && codexswitch_rotate_after_usage_limit(&sess, &turn_context).await
        {
            codexswitch_usage_limit_retry_attempted = true;
            continue;
        }"#,
        "&& codexswitch_rotate_after_usage_limit",
    )?;
    patch_all(
        path,
        "            Err(err) => err,",
        r#"            Err(err) => {
                if !codexswitch_auth_failure_retry_attempted
                    && codexswitch_is_auth_invalidated_error(&err)
                    && codexswitch_rotate_after_auth_failure(&sess, &turn_context).await
                {
                    codexswitch_auth_failure_retry_attempted = true;
                    continue;
                }
                err
            },"#,
    )?;
    Ok(())
}

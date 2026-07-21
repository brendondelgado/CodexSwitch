const INTERRUPTED_TURN_TEMPLATE_MARKER: &str = "codexswitch-runtime-interrupted-turn-v2";

fn patch_turn_rotation_templates(path: &Path) -> Result<()> {
    patch_turn_rotation_dependencies(path)?;
    install_interrupted_turn_template(path)?;
    normalize_interrupted_turn_retry_loop(path)?;
    Ok(())
}

fn patch_turn_rotation_dependencies(path: &Path) -> Result<()> {
    let core_dir = path
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .context("turn source is outside the Codex core crate")?;
    let workspace_dir = core_dir
        .parent()
        .context("Codex core crate is outside its workspace")?;
    patch_workspace_dependency_if_present(&core_dir.join("Cargo.toml"), "sha2")?;
    patch_lockfile_dependency_if_present(&workspace_dir.join("Cargo.lock"), "codex-core", "sha2")?;
    Ok(())
}

fn install_interrupted_turn_template(path: &Path) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(INTERRUPTED_TURN_TEMPLATE_MARKER) {
        return Ok(());
    }
    let anchors = [
        "/// Takes a user message as input and runs a loop where, at each sampling request, the model",
        "/// Takes initial turn input and runs a loop where, at each sampling request,",
    ];
    let anchor = anchors
        .iter()
        .filter_map(|anchor| content.find(anchor))
        .min()
        .context("turn loop documentation anchor was not found")?;
    let existing_start = [
        "#[cfg(unix)]\nfn codexswitch_rotation_timeout()",
        "#[cfg(unix)]\nasync fn codexswitch_rotate_after_usage_limit",
    ]
    .iter()
    .filter_map(|needle| content[..anchor].find(needle))
    .min()
    .unwrap_or(anchor);
    let interrupted_turn_template = interrupted_turn_template();
    let updated = format!(
        "{}{}{}",
        &content[..existing_start],
        interrupted_turn_template,
        &content[anchor..]
    );
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn interrupted_turn_template() -> String {
    const CONTROL_SOURCE_PLACEHOLDER: &str = "/* CODEXSWITCH_CONTROL_SOURCE */";
    let template = INTERRUPTED_TURN_TEMPLATE.replace(
        CONTROL_SOURCE_PLACEHOLDER,
        include_str!("source_turn_control.rs"),
    );
    debug_assert!(!template.contains(CONTROL_SOURCE_PLACEHOLDER));
    template
}

fn normalize_interrupted_turn_retry_loop(path: &Path) -> Result<()> {
    patch_all(
        path,
        "codexswitch_auth_failure_retry_attempted",
        "codexswitch_auth_rotation_retry_attempted",
    )?;
    patch_file_after(
        path,
        "    let mut retries = 0;",
        "\n    let mut codexswitch_usage_limit_retry_attempted = false;",
        "let mut codexswitch_usage_limit_retry_attempted = false;",
    )?;
    patch_file_after(
        path,
        "    let mut retries = 0;",
        "\n    let mut codexswitch_auth_reload_retry_attempted = false;",
        "let mut codexswitch_auth_reload_retry_attempted = false;",
    )?;
    patch_file_after(
        path,
        "    let mut retries = 0;",
        "\n    let mut codexswitch_auth_rotation_retry_attempted = false;",
        "let mut codexswitch_auth_rotation_retry_attempted = false;",
    )?;
    patch_file_before_any(
        path,
        &[
            "        let prompt_input = if let Some(input) = initial_input.take() {",
            "        match try_run_sampling_request().await {",
        ],
        r#"        let codexswitch_request_auth_generation = turn_context
            .auth_manager
            .as_ref()
            .map(|auth_manager| auth_manager.auth_generation());
"#,
        "let codexswitch_request_auth_generation = turn_context",
    )?;
    patch_all(
        path,
        r#"                if !codexswitch_usage_limit_retry_attempted
                    && codexswitch_rotate_after_usage_limit(&sess, &turn_context).await
                {
                    codexswitch_usage_limit_retry_attempted = true;
                    continue;
                }"#,
        r#"                if !codexswitch_usage_limit_retry_attempted {
                    codexswitch_usage_limit_retry_attempted = true;
                    if codexswitch_rotate_after_usage_limit(&sess, &turn_context).await {
                        continue;
                    }
                }"#,
    )?;
    patch_file_after(
        path,
        "                if let Some(rate_limits) = rate_limits {\n                    sess.update_rate_limits(&turn_context, *rate_limits).await;\n                }",
        r#"
                if !codexswitch_usage_limit_retry_attempted {
                    codexswitch_usage_limit_retry_attempted = true;
                    if codexswitch_rotate_after_usage_limit(&sess, &turn_context).await {
                        continue;
                    }
                }"#,
        "if codexswitch_rotate_after_usage_limit(&sess, &turn_context).await",
    )?;
    let auth_retry = r#"            Err(err) => {
                if codexswitch_is_auth_invalidated_error(&err) {
                    if !codexswitch_auth_reload_retry_attempted {
                        codexswitch_auth_reload_retry_attempted = true;
                        if codexswitch_reload_changed_external_auth(
                            &sess,
                            &turn_context,
                            codexswitch_request_auth_generation,
                        )
                        .await
                        {
                            continue;
                        }
                    }
                    if !codexswitch_auth_rotation_retry_attempted {
                        codexswitch_auth_rotation_retry_attempted = true;
                        if codexswitch_rotate_after_auth_failure(&sess, &turn_context).await {
                            continue;
                        }
                    }
                }
                err
            },"#;
    patch_all(
        path,
        "if codexswitch_reload_changed_external_auth(&sess, &turn_context).await {",
        r#"if codexswitch_reload_changed_external_auth(
                            &sess,
                            &turn_context,
                            codexswitch_request_auth_generation,
                        )
                        .await
                        {"#,
    )?;
    patch_all(path, "            Err(err) => err,", auth_retry)?;
    patch_all(
        path,
        r#"            Err(err) => {
                if !codexswitch_auth_rotation_retry_attempted
                    && codexswitch_is_auth_invalidated_error(&err)
                    && codexswitch_rotate_after_auth_failure(&sess, &turn_context).await
                {
                    codexswitch_auth_rotation_retry_attempted = true;
                    continue;
                }
                err
            },"#,
        auth_retry,
    )?;
    Ok(())
}

const INTERRUPTED_TURN_TEMPLATE: &str = r#"#[cfg(unix)]
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
fn codexswitch_now_milliseconds() -> Option<u64> {
    Some(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_millis() as u64,
    )
}

#[cfg(unix)]
fn codexswitch_is_canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
}

#[cfg(unix)]
fn codexswitch_new_receipt_nonce() -> Option<String> {
    let mut bytes = [0_u8; 16];
    let mut random = std::fs::File::open("/dev/urandom").ok()?;
    std::io::Read::read_exact(&mut random, &mut bytes).ok()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Some(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    ))
}

#[cfg(unix)]
fn codexswitch_request_nonce_matches_receipt(request_nonce: &str, receipt_nonce: &str) -> bool {
    let Some((receipt, request)) = request_nonce.split_once(':') else {
        return false;
    };
    receipt == receipt_nonce
        && codexswitch_is_canonical_uuid(receipt)
        && codexswitch_is_canonical_uuid(request)
}

/* CODEXSWITCH_CONTROL_SOURCE */

#[cfg(unix)]
fn codexswitch_read_bounded_json(
    path: &std::path::Path,
    max_bytes: u64,
) -> Option<serde_json::Value> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let before = std::fs::symlink_metadata(path).ok()?;
    if before.file_type().is_symlink()
        || !before.is_file()
        || before.uid() != unsafe { libc::geteuid() }
        || before.len() > max_bytes
    {
        return None;
    }
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let opened = file.metadata().ok()?;
    if opened.dev() != before.dev() || opened.ino() != before.ino() {
        return None;
    }
    let mut data = Vec::with_capacity(before.len() as usize);
    let mut limited = std::io::Read::take(&mut file, max_bytes + 1);
    std::io::Read::read_to_end(&mut limited, &mut data).ok()?;
    if data.len() as u64 > max_bytes {
        return None;
    }
    let after = std::fs::symlink_metadata(path).ok()?;
    if after.file_type().is_symlink()
        || after.dev() != before.dev()
        || after.ino() != before.ino()
    {
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
struct CodexSwitchOwnHandoff {
    auth_path: std::path::PathBuf,
    fingerprint: String,
    provider_account_id: String,
    request_nonce: String,
    auth_generation: u64,
}

#[cfg(unix)]
fn codexswitch_verified_own_handoff_v3(
    expected_auth_path: Option<&std::path::Path>,
    expected_receipt_nonce: Option<&str>,
    expected_fingerprint: Option<&str>,
    issued_not_before: Option<u64>,
    allow_auth_file_identity_drift: bool,
) -> Option<CodexSwitchOwnHandoff> {
    use std::os::unix::fs::MetadataExt;
    const ACK_MAX_BYTES: u64 = 64 * 1024;
    const REQUEST_MAX_BYTES: u64 = 16 * 1024;
    const ACK_MAX_AGE_MILLISECONDS: u64 = 5 * 60 * 1_000;
    let home = std::env::var_os("HOME")?;
    let pid = std::process::id();
    let root = std::path::PathBuf::from(home).join(".codexswitch");
    let ack_path = root.join("hotswap-ack").join(format!("{pid}.json"));
    let request_path = root.join("hotswap-request").join(format!("{pid}.json"));
    let request = codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES)?;
    let ack = codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES)?;
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
        || expected_auth_path.is_some_and(|expected| expected != auth_path)
        || auth_metadata.file_type().is_symlink()
        || !auth_metadata.is_file()
        || auth_metadata.uid() != unsafe { libc::geteuid() }
        || std::fs::canonicalize(&auth_path).ok()? != auth_path
        || (!allow_auth_file_identity_drift
            && (auth.get("device")?.as_u64()? != auth_metadata.dev()
                || auth.get("inode")?.as_u64()? != auth_metadata.ino()))
        || provider_account_id.is_empty()
        || provider_account_id.len() > 1024
        || !provider_account_id
            .bytes()
            .all(|byte| (0x21..=0x7e).contains(&byte))
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || expected_fingerprint.is_some_and(|expected| expected != fingerprint)
    {
        return None;
    }

    let request_nonce = binding.get("requestNonce")?.as_str()?;
    let issued_at = binding.get("issuedAtUnixMilliseconds")?.as_u64()?;
    let acknowledged_at = ack.get("acknowledgedAtUnixMilliseconds")?.as_u64()?;
    let now = codexswitch_now_milliseconds()?;
    let started_at = start_seconds
        .saturating_mul(1_000)
        .saturating_add(start_microseconds / 1_000);
    if request_nonce.is_empty()
        || request_nonce.len() > 256
        || expected_receipt_nonce.is_some_and(|receipt| {
            !codexswitch_request_nonce_matches_receipt(request_nonce, receipt)
        })
        || issued_at < started_at
        || issued_not_before.is_some_and(|not_before| issued_at < not_before)
        || acknowledged_at < issued_at
        || acknowledged_at > now.saturating_add(60_000)
        || now.saturating_sub(acknowledged_at) > ACK_MAX_AGE_MILLISECONDS
        || ack.get("loadedTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("activeTokenFingerprint")?.as_str()? != fingerprint
        || ack.get("frontendNotified")?.as_bool()? != false
        || ack.get("frontendWriteCount")?.as_u64()? != 0
        || ack.get("authGeneration")?.as_u64().is_none()
        || ack.get("reconnectReady")?.as_bool()? != true
        || ack.get("initializedFrontendCount").is_some()
        || ack.get("skippedFrontendCount").is_some()
        || ack.get("eligibleFrontendCount").is_some()
        || ack.get("rejectedFrontendCount").is_some()
        || ack
            .get("idleListenerReady")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
    {
        return None;
    }
    if codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES).as_ref() != Some(&request)
        || codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES).as_ref() != Some(&ack)
    {
        return None;
    }
    Some(CodexSwitchOwnHandoff {
        auth_path,
        fingerprint: fingerprint.to_string(),
        provider_account_id: provider_account_id.to_string(),
        request_nonce: request_nonce.to_string(),
        auth_generation: ack.get("authGeneration")?.as_u64()?,
    })
}

#[cfg(unix)]
fn codexswitch_bound_auth_path_v3() -> Option<(std::path::PathBuf, String, String)> {
    let handoff = codexswitch_verified_own_handoff_v3(None, None, None, None, false)?;
    Some((
        handoff.auth_path,
        handoff.fingerprint,
        handoff.provider_account_id,
    ))
}

#[cfg(unix)]
fn codexswitch_bound_auth_path_for_external_change_v3(
) -> Option<(std::path::PathBuf, String, String)> {
    let handoff = codexswitch_verified_own_handoff_v3(None, None, None, None, true)?;
    Some((
        handoff.auth_path,
        handoff.fingerprint,
        handoff.provider_account_id,
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
    control_cli: &CodexSwitchControlCli,
) -> Option<std::process::Output> {
    const OUTPUT_MAX_BYTES: usize = 64 * 1024;
    command
        .kill_on_drop(true)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    if !control_cli.is_still_current() {
        return None;
    }
    let mut child = command.spawn().ok()?;
    if !control_cli.is_still_current() {
        let _ = child.kill().await;
        let _ = child.wait().await;
        return None;
    }
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
    if stdout.1 || stderr.1 || !control_cli.is_still_current() {
        return None;
    }
    Some(std::process::Output {
        status,
        stdout: stdout.0,
        stderr: stderr.0,
    })
}

#[cfg(unix)]
struct CodexSwitchRotationProof {
    fingerprint: String,
    acknowledged_request_nonces: Vec<String>,
}

#[cfg(unix)]
fn codexswitch_verified_rotation_result(
    output: &std::process::Output,
    auth_path: &std::path::Path,
    receipt_nonce: &str,
) -> Option<CodexSwitchRotationProof> {
    const OUTPUT_MAX_BYTES: usize = 64 * 1024;
    const MAX_RUNTIME_TARGETS: usize = 4_096;
    if output.stdout.len() > OUTPUT_MAX_BYTES || output.stderr.len() > OUTPUT_MAX_BYTES {
        return None;
    }
    let report = serde_json::from_slice::<serde_json::Value>(&output.stdout).ok()?;
    if !codexswitch_is_canonical_uuid(receipt_nonce)
        || report.get("receiptNonce")?.as_str()? != receipt_nonce
        || report.get("authPath")?.as_str()? != auth_path.to_str()?
        || report.get("activationState")?.as_str()? != "confirmed"
        || report.get("runtimeConverged")?.as_bool()? != true
        || report.get("reloadAttempted")?.as_bool()? != true
        || report.get("topologyVerified")?.as_bool()? != true
        || report.get("restartedProcesses")?.as_u64()? != 0
        || report.get("skippedProcesses")?.as_u64()? != 0
    {
        return None;
    }
    let request_count = usize::try_from(report.get("requestCount")?.as_u64()?).ok()?;
    if request_count == 0
        || request_count > MAX_RUNTIME_TARGETS
        || usize::try_from(report.get("sighupSentProcesses")?.as_u64()?).ok()? != request_count
        || usize::try_from(report.get("signaledProcesses")?.as_u64()?).ok()? != request_count
    {
        return None;
    }
    let acknowledged = report.get("acknowledgedRequestNonces")?.as_array()?;
    if acknowledged.len() != request_count {
        return None;
    }
    let mut unique = std::collections::HashSet::with_capacity(acknowledged.len());
    let mut acknowledged_request_nonces = Vec::with_capacity(acknowledged.len());
    for value in acknowledged {
        let nonce = value.as_str()?;
        if nonce.len() > 256
            || !codexswitch_request_nonce_matches_receipt(nonce, receipt_nonce)
            || !unique.insert(nonce)
        {
            return None;
        }
        acknowledged_request_nonces.push(nonce.to_string());
    }
    let fingerprint = report.get("nextTokenFingerprint")?.as_str()?;
    if fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }
    Some(CodexSwitchRotationProof {
        fingerprint: fingerprint.to_string(),
        acknowledged_request_nonces,
    })
}

#[cfg(unix)]
async fn codexswitch_reload_changed_external_auth(
    sess: &Session,
    turn_context: &TurnContext,
    request_auth_generation: Option<u64>,
) -> bool {
    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {
        return false;
    };
    let Some(request_auth_generation) = request_auth_generation else {
        return false;
    };

    if let Some(current_handoff) =
        codexswitch_verified_own_handoff_v3(None, None, None, None, false)
    {
        let disk_identity = auth_manager
            .codexswitch_auth_file_identity(&current_handoff.auth_path)
            .ok();
        if codexswitch_external_auth_handoff_matches(
            auth_manager.codexswitch_auth_fingerprint().as_deref(),
            auth_manager.codexswitch_provider_account_id().as_deref(),
            auth_manager.auth_generation(),
            disk_identity.as_ref().map(|identity| identity.0.as_str()),
            disk_identity.as_ref().map(|identity| identity.1.as_str()),
            &current_handoff.fingerprint,
            &current_handoff.provider_account_id,
            current_handoff.auth_generation,
            request_auth_generation,
        )
        {
            sess.send_event(
                turn_context,
                EventMsg::Warning(WarningEvent {
                    message: "CodexSwitch observed a receipt-bound external auth reload and is retrying this turn before rotating accounts.".to_string(),
                }),
            )
            .await;
            return true;
        }
    }

    let Some(bound_handoff) =
        codexswitch_verified_own_handoff_v3(None, None, None, None, true)
    else {
        return false;
    };
    let auth_path = bound_handoff.auth_path.clone();
    let Ok((observed_fingerprint, observed_provider_account_id)) =
        auth_manager.codexswitch_auth_file_identity(&auth_path)
    else {
        return false;
    };
    if observed_fingerprint == bound_handoff.fingerprint
        && observed_provider_account_id == bound_handoff.provider_account_id
    {
        return false;
    }
    let generation_before_fallback = auth_manager.auth_generation();
    let Ok((_changed, loaded_fingerprint, active_fingerprint)) = auth_manager
        .codexswitch_reload_auth_json_verified(&auth_path)
        .await
    else {
        return false;
    };
    let post_reload_generation = auth_manager.auth_generation();
    let bound_handoff_is_still_current = codexswitch_verified_own_handoff_v3(
        Some(&auth_path),
        None,
        Some(&bound_handoff.fingerprint),
        None,
        true,
    )
    .is_some_and(|revalidated| {
        revalidated.request_nonce == bound_handoff.request_nonce
            && revalidated.auth_generation == bound_handoff.auth_generation
            && revalidated.provider_account_id == bound_handoff.provider_account_id
    });
    if loaded_fingerprint != observed_fingerprint
        || active_fingerprint != observed_fingerprint
        || post_reload_generation <= request_auth_generation
        || post_reload_generation <= generation_before_fallback
        || auth_manager.codexswitch_auth_fingerprint().as_deref()
            != Some(observed_fingerprint.as_str())
        || auth_manager.codexswitch_provider_account_id().as_deref()
            != Some(observed_provider_account_id.as_str())
        || auth_manager.codexswitch_auth_file_identity(&auth_path).ok()
            != Some((
                observed_fingerprint.clone(),
                observed_provider_account_id.clone(),
            ))
        || !bound_handoff_is_still_current
    {
        return false;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: "CodexSwitch verified one fallback external auth reload and is retrying this turn before rotating accounts.".to_string(),
        }),
    )
    .await;
    true
}

#[cfg(unix)]
async fn codexswitch_rotate_after_failure(
    sess: &Session,
    turn_context: &TurnContext,
    reason: &str,
    cooldown_seconds: &str,
    require_unchanged_bound_auth: bool,
    success_message: &str,
) -> bool {
    let Some(auth_manager) = turn_context.auth_manager.as_ref() else {
        warn!("CodexSwitch interrupted-turn rotation cannot bind the turn AuthManager");
        return false;
    };
    let pre_rotation_auth_generation = auth_manager.auth_generation();
    let bound_auth = if require_unchanged_bound_auth {
        codexswitch_bound_auth_path_v3()
    } else {
        codexswitch_bound_auth_path_for_external_change_v3()
    };
    let Some((auth_path, bound_fingerprint, bound_provider_account_id)) = bound_auth
    else {
        warn!("codexswitch-runtime-rotation-handoff-v1: no verified runtime auth path binding");
        return false;
    };
    let Ok((observed_fingerprint, observed_provider_account_id)) =
        auth_manager.codexswitch_auth_file_identity(&auth_path)
    else {
        warn!("CodexSwitch interrupted-turn rotation could not read bounded auth evidence");
        return false;
    };
    if require_unchanged_bound_auth
        && (observed_fingerprint != bound_fingerprint
            || observed_provider_account_id != bound_provider_account_id)
    {
        warn!("CodexSwitch interrupted-turn rotation rejected changed on-disk auth evidence");
        return false;
    }
    let Some(control_cli) = codexswitch_control_cli() else {
        warn!("CodexSwitch interrupted-turn rotation rejected the canonical control executable");
        return false;
    };
    let Some(receipt_nonce) = codexswitch_new_receipt_nonce() else {
        warn!("CodexSwitch interrupted-turn rotation could not generate a receipt UUID");
        return false;
    };
    let Some(rotation_started_at) = codexswitch_now_milliseconds() else {
        return false;
    };
    let Some(control_execution_path) = control_cli.execution_path() else {
        warn!("CodexSwitch interrupted-turn rotation could not bind the opened control executable");
        return false;
    };
    let mut command = tokio::process::Command::new(control_execution_path);
    command
        .arg("--auth")
        .arg(&auth_path)
        .arg("rotate-now")
        .arg("--receipt-nonce")
        .arg(&receipt_nonce)
        .arg("--reason")
        .arg(reason)
        .arg("--cooldown-seconds")
        .arg(cooldown_seconds)
        .arg("--json");
    let Some(output) = codexswitch_run_bounded_rotation(command, &control_cli).await else {
        warn!("CodexSwitch interrupted-turn rotation failed or timed out");
        return false;
    };
    if !output.status.success() {
        warn!(
            "CodexSwitch interrupted-turn rotation exited with status {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        return false;
    }
    let Some(proof) =
        codexswitch_verified_rotation_result(&output, &auth_path, &receipt_nonce)
    else {
        warn!("CodexSwitch interrupted-turn rotation report did not prove the receipt contract");
        return false;
    };
    if proof.fingerprint == observed_fingerprint {
        warn!("CodexSwitch interrupted-turn rotation did not change the token fingerprint");
        return false;
    }
    let Some(own_handoff) = codexswitch_verified_own_handoff_v3(
        Some(&auth_path),
        Some(&receipt_nonce),
        Some(&proof.fingerprint),
        Some(rotation_started_at),
        false,
    ) else {
        warn!("CodexSwitch interrupted turn could not verify its exact post-rotation request and ACK");
        return false;
    };
    if !proof
        .acknowledged_request_nonces
        .iter()
        .any(|nonce| nonce == &own_handoff.request_nonce)
    {
        warn!("CodexSwitch interrupted turn own ACK nonce was absent from the rotation report");
        return false;
    }
    let manager_already_matches_handoff = codexswitch_auth_handoff_matches(
        auth_manager.codexswitch_auth_fingerprint().as_deref(),
        auth_manager.codexswitch_provider_account_id().as_deref(),
        auth_manager.auth_generation(),
        &own_handoff.fingerprint,
        &own_handoff.provider_account_id,
        own_handoff.auth_generation,
        pre_rotation_auth_generation,
    );
    if !manager_already_matches_handoff {
        let Ok((_changed, loaded_fingerprint, active_fingerprint)) = auth_manager
            .codexswitch_reload_auth_json_verified(&auth_path)
            .await
        else {
            warn!("CodexSwitch interrupted-turn rotation could not reload the turn AuthManager");
            return false;
        };
        if loaded_fingerprint != own_handoff.fingerprint
            || active_fingerprint != own_handoff.fingerprint
            || !codexswitch_auth_handoff_matches(
                auth_manager.codexswitch_auth_fingerprint().as_deref(),
                auth_manager.codexswitch_provider_account_id().as_deref(),
                auth_manager.auth_generation(),
                &own_handoff.fingerprint,
                &own_handoff.provider_account_id,
                own_handoff.auth_generation,
                pre_rotation_auth_generation,
            )
        {
            warn!("CodexSwitch interrupted-turn AuthManager convergence reload failed");
            return false;
        }
    }
    if auth_manager.codexswitch_auth_file_identity(&auth_path).ok()
        != Some((
            own_handoff.fingerprint.clone(),
            own_handoff.provider_account_id.clone(),
        ))
    {
        warn!("CodexSwitch interrupted-turn AuthManager fingerprint convergence failed");
        return false;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: success_message.to_string(),
        }),
    )
    .await;
    true
}

#[cfg(unix)]
async fn codexswitch_rotate_after_usage_limit(sess: &Session, turn_context: &TurnContext) -> bool {
    codexswitch_rotate_after_failure(
        sess,
        turn_context,
        "usage_limit",
        "18000",
        true,
        "CodexSwitch rotated accounts after a usage limit and is retrying this turn.",
    )
    .await
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_usage_limit(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

#[cfg(unix)]
async fn codexswitch_rotate_after_auth_failure(sess: &Session, turn_context: &TurnContext) -> bool {
    codexswitch_rotate_after_failure(
        sess,
        turn_context,
        "token_expired",
        "2592000",
        false,
        "CodexSwitch rotated accounts after an auth failure and is retrying this turn.",
    )
    .await
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
async fn codexswitch_reload_changed_external_auth(
    _sess: &Session,
    _turn_context: &TurnContext,
    _request_auth_generation: Option<u64>,
) -> bool {
    false
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_auth_failure(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

#[cfg(not(unix))]
fn codexswitch_is_auth_invalidated_error(_error: &CodexErr) -> bool {
    false
}

// codexswitch-runtime-interrupted-turn-v2

"#;

#[cfg(test)]
mod sha2 {
    pub trait Digest: Sized {
        type Output: std::fmt::LowerHex;

        fn new() -> Self;
        fn update(&mut self, bytes: &[u8]);
        fn finalize(self) -> Self::Output;
    }

    pub struct Sha256(ring::digest::Context);

    pub struct Sha256Output([u8; 32]);

    impl Digest for Sha256 {
        type Output = Sha256Output;

        fn new() -> Self {
            Self(ring::digest::Context::new(&ring::digest::SHA256))
        }

        fn update(&mut self, bytes: &[u8]) {
            self.0.update(bytes);
        }

        fn finalize(self) -> Self::Output {
            let digest = self.0.finish();
            let mut bytes = [0_u8; 32];
            bytes.copy_from_slice(digest.as_ref());
            Sha256Output(bytes)
        }
    }

    impl std::fmt::LowerHex for Sha256Output {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            for byte in self.0 {
                write!(formatter, "{byte:02x}")?;
            }
            Ok(())
        }
    }
}

#[cfg(test)]
include!("source_turn_control.rs");

#[cfg(test)]
fn interrupted_turn_receipt_ack_is_current(
    receipt_nonce: &str,
    request_nonce: &str,
    issued_at: u64,
    acknowledged_at: u64,
    failure_at: u64,
) -> bool {
    let Some((receipt, request)) = request_nonce.split_once(':') else {
        return false;
    };
    receipt == receipt_nonce
        && test_canonical_uuid(receipt)
        && test_canonical_uuid(request)
        && issued_at >= failure_at
        && acknowledged_at >= issued_at
}

#[cfg(test)]
fn interrupted_turn_report_counts_are_complete(
    request_count: usize,
    sighup_sent: usize,
    signaled: usize,
    acknowledged: usize,
    restarted: usize,
    skipped: usize,
    topology_verified: bool,
) -> bool {
    request_count > 0
        && request_count == sighup_sent
        && request_count == signaled
        && request_count == acknowledged
        && restarted == 0
        && skipped == 0
        && topology_verified
}

#[cfg(test)]
fn test_canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InterruptedTurnRetryAction {
    ExternalAuthRetry,
    RotationRetry,
}

#[cfg(test)]
#[derive(Default)]
struct InterruptedTurnRetryBudget {
    usage_rotation_attempted: bool,
    auth_reload_attempted: bool,
    auth_rotation_attempted: bool,
}

#[cfg(test)]
impl InterruptedTurnRetryBudget {
    fn usage_failure(&mut self) -> Option<InterruptedTurnRetryAction> {
        if self.usage_rotation_attempted {
            return None;
        }
        self.usage_rotation_attempted = true;
        Some(InterruptedTurnRetryAction::RotationRetry)
    }

    fn auth_failure(
        &mut self,
        on_disk_auth_changed: bool,
        external_reload_succeeded: bool,
    ) -> Option<InterruptedTurnRetryAction> {
        if !self.auth_reload_attempted {
            self.auth_reload_attempted = true;
            if on_disk_auth_changed && external_reload_succeeded {
                return Some(InterruptedTurnRetryAction::ExternalAuthRetry);
            }
        }
        if self.auth_rotation_attempted {
            return None;
        }
        self.auth_rotation_attempted = true;
        Some(InterruptedTurnRetryAction::RotationRetry)
    }
}

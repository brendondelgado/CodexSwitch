fn patch_app_server_reload_template(path: &Path, in_process_app_server: &Path) -> Result<()> {
    patch_file_after_any(
        path,
        &[
            "let processor_handle = tokio::spawn({\n        let auth_manager =\n            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;",
            "let auth_manager =\n        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;",
        ],
        r#"
        #[cfg(unix)]
        {
            fn codexswitch_read_bounded_request(
                path: &std::path::Path,
            ) -> Option<serde_json::Value> {
                const REQUEST_MAX_BYTES: u64 = 16 * 1024;
                use std::os::unix::fs::OpenOptionsExt;
                let mut file = std::fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(path)
                    .ok()?;
                let metadata = file.metadata().ok()?;
                if !metadata.file_type().is_file() || metadata.len() > REQUEST_MAX_BYTES {
                    return None;
                }
                let mut data = Vec::with_capacity(metadata.len() as usize);
                let mut limited = std::io::Read::take(&mut file, REQUEST_MAX_BYTES + 1);
                std::io::Read::read_to_end(&mut limited, &mut data).ok()?;
                if data.len() as u64 > REQUEST_MAX_BYTES {
                    return None;
                }
                serde_json::from_slice(&data).ok()
            }

            #[cfg(target_os = "linux")]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
                let fields = stat.get(stat.rfind(')')? + 1..)?.split_whitespace();
                let start_ticks = fields.skip(19).next()?.parse::<u64>().ok()?;
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
                    (start_ticks % ticks_per_second).saturating_mul(1_000_000)
                        / ticks_per_second,
                ))
            }

            #[cfg(target_os = "macos")]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
                let size = std::mem::size_of::<libc::proc_bsdinfo>();
                let bytes = unsafe {
                    libc::proc_pidinfo(
                        std::process::id() as i32,
                        libc::PROC_PIDTBSDINFO,
                        0,
                        info.as_mut_ptr().cast(),
                        size as libc::c_int,
                    )
                };
                if bytes != size as libc::c_int {
                    return None;
                }
                let info = unsafe { info.assume_init() };
                (info.pbi_pid == std::process::id()).then_some((
                    info.pbi_start_tvsec,
                    info.pbi_start_tvusec,
                ))
            }

            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                None
            }

            fn codexswitch_validate_v3_binding(
                request: &serde_json::Value,
                expected_runtime_kind: &str,
            ) -> Option<(serde_json::Value, std::path::PathBuf, String, String)> {
                use std::os::unix::fs::MetadataExt;
                let request_object = request.as_object()?;
                if request_object.len() != 1 {
                    return None;
                }
                let binding = request_object.get("binding")?;
                if binding.as_object()?.len() != 7
                    || binding.get("contractVersion")?.as_u64()? != 3
                    || binding.get("runtimeKind")?.as_str()? != expected_runtime_kind
                {
                    return None;
                }

                let process = binding.get("processIdentity")?;
                let pid = std::process::id();
                let (start_seconds, start_microseconds) =
                    codexswitch_current_process_start()?;
                let executable = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
                let executable_text = executable.to_str()?;
                let executable_metadata = std::fs::metadata(&executable).ok()?;
                if process.as_object()?.len() != 5
                    || process.get("pid")?.as_u64()? != u64::from(pid)
                    || process.get("ownerUID")?.as_u64()? != u64::from(unsafe { libc::geteuid() })
                    || process.get("executablePath")?.as_str()? != executable_text
                    || process.get("startSeconds")?.as_u64()? != start_seconds
                    || process.get("startMicroseconds")?.as_u64()? != start_microseconds
                {
                    return None;
                }
                let kernel = binding.get("kernelExecutableIdentity")?;
                if kernel.as_object()?.len() != 3
                    || kernel.get("canonicalPath")?.as_str()? != executable_text
                    || kernel.get("device")?.as_u64()? != executable_metadata.dev()
                    || kernel.get("inode")?.as_u64()? != executable_metadata.ino()
                {
                    return None;
                }

                let auth_identity = binding.get("authFileIdentity")?;
                let auth_path = std::path::PathBuf::from(
                    auth_identity.get("canonicalPath")?.as_str()?,
                );
                let auth_metadata = std::fs::symlink_metadata(&auth_path).ok()?;
                if auth_identity.as_object()?.len() != 5
                    || !auth_path.is_absolute()
                    || auth_metadata.file_type().is_symlink()
                    || !auth_metadata.is_file()
                    || auth_metadata.uid() != unsafe { libc::geteuid() }
                    || std::fs::canonicalize(&auth_path).ok()? != auth_path
                    || auth_identity.get("device")?.as_u64()? != auth_metadata.dev()
                    || auth_identity.get("inode")?.as_u64()? != auth_metadata.ino()
                {
                    return None;
                }
                let account_id = auth_identity.get("accountID")?.as_str()?;
                let fingerprint = auth_identity
                    .get("completeTokenFingerprint")?
                    .as_str()?;
                let nonce = binding.get("requestNonce")?.as_str()?;
                if account_id.is_empty()
                    || account_id.len() > 1024
                    || !account_id.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
                    || fingerprint.len() != 64
                    || !fingerprint
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                    || nonce.is_empty()
                    || nonce.len() > 256
                    || binding.get("issuedAtUnixMilliseconds")?.as_u64()? == 0
                {
                    return None;
                }
                Some((
                    binding.clone(),
                    auth_path,
                    account_id.to_string(),
                    fingerprint.to_string(),
                ))
            }

            let codexswitch_marker_dir = std::env::var_os("HOME").map(|home| {
                let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
                let _ = std::fs::create_dir_all(&marker_dir);
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-ack"));
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-request"));
                let _ = std::fs::write(
                    marker_dir.join("sighup-verified"),
                    "app-server codexswitch-hotswap-contract-v3 codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1\n",
                );
                marker_dir
            });

            let auth_for_signal = auth_manager.clone();
            let outgoing_for_signal = outgoing_tx.clone();
            tokio::spawn(async move {
                use tokio::signal::unix::{signal, SignalKind};
                let mut sighup = match signal(SignalKind::hangup()) {
                    Ok(s) => s,
                    Err(err) => {
                        tracing::error!("Failed to register SIGHUP handler: {err}");
                        return;
                    }
                };
                loop {
                    if sighup.recv().await.is_none() {
                        break;
                    }
                    tracing::info!("SIGHUP: auth reload signal received");
                    let pid = std::process::id();
                    let Some(marker_dir) = codexswitch_marker_dir.as_ref() else {
                        tracing::error!("CodexSwitch SIGHUP marker directory is unavailable");
                        continue;
                    };
                    let request_path =
                        marker_dir.join("hotswap-request").join(format!("{pid}.json"));
                    let Some(request) = codexswitch_read_bounded_request(&request_path)
                    else {
                        tracing::error!("CodexSwitch SIGHUP request is missing or invalid");
                        continue;
                    };
                    let Some((binding, auth_path, expected_account_id, expected_auth_hash)) =
                        codexswitch_validate_v3_binding(&request, "external-app-server")
                    else {
                        tracing::error!(
                            "CodexSwitch SIGHUP request does not match the canonical v3 runtime binding"
                        );
                        continue;
                    };
                    let (observed_auth_hash, observed_account_id) = match auth_for_signal
                        .codexswitch_auth_file_identity(&auth_path)
                    {
                        Ok(identity) => identity,
                        Err(err) => {
                            tracing::error!(
                                "CodexSwitch auth identity read failed; acknowledgement suppressed: {err}"
                            );
                            continue;
                        }
                    };
                    if observed_auth_hash != expected_auth_hash
                        || observed_account_id != expected_account_id
                    {
                        tracing::error!(
                            "CodexSwitch auth file does not match the v3 fingerprint/account binding"
                        );
                        continue;
                    }
                    let (changed, loaded_auth_hash, active_auth_hash) = match auth_for_signal
                        .codexswitch_reload_auth_json_verified(&auth_path)
                        .await
                    {
                        Ok(proof) => proof,
                        Err(err) => {
                            tracing::error!(
                                "CodexSwitch auth reload failed; acknowledgement suppressed: {err}"
                            );
                            continue;
                        }
                    };
                    if loaded_auth_hash != expected_auth_hash {
                        tracing::error!(
                            "CodexSwitch loaded auth fingerprint does not match the SIGHUP request"
                        );
                        continue;
                    }
                    let Some(auth) = auth_for_signal.auth_cached() else {
                        tracing::error!("CodexSwitch auth cache is empty after reload");
                        continue;
                    };
                    if auth.codexswitch_auth_fingerprint().as_deref()
                        != Some(active_auth_hash.as_str())
                        || auth.codexswitch_provider_account_id().as_deref()
                            != Some(expected_account_id.as_str())
                    {
                        tracing::error!(
                            "CodexSwitch cached auth identity does not match the v3 binding"
                        );
                        continue;
                    }
                    let auth_generation = auth_for_signal.auth_generation();
                    let (frontend_write_tx, frontend_write_rx) = tokio::sync::oneshot::channel();
                    if outgoing_for_signal
                        .send(OutgoingEnvelope::BroadcastWithWriteAck {
                            message: crate::outgoing_message::OutgoingMessage::AppServerNotification(
                                ServerNotification::AccountUpdated(
                                    codex_app_server_protocol::AccountUpdatedNotification {
                                        auth_mode: Some(crate::auth_mode::auth_mode_to_api(
                                            auth.api_auth_mode(),
                                        )),
                                        plan_type: auth.account_plan_type(),
                                    },
                                ),
                            ),
                            write_complete_tx: frontend_write_tx,
                        })
                        .await
                        .is_err()
                    {
                        tracing::error!("CodexSwitch failed to queue account/updated after auth reload");
                        continue;
                    }
                    let frontend_write_count = match tokio::time::timeout(
                        std::time::Duration::from_secs(3),
                        frontend_write_rx,
                    )
                    .await
                    {
                        Ok(Ok(count)) => count,
                        _ => 0,
                    };
                    if frontend_write_count == 0 {
                        tracing::error!(
                            "CodexSwitch account/updated reached no initialized frontend writer"
                        );
                        continue;
                    }
                    tracing::info!(
                        "CodexSwitch account/updated frontend write acknowledged after auth reload"
                    );
                    let acknowledged_at = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|duration| duration.as_millis() as u64)
                        .unwrap_or(0);
                    let _ = std::fs::write(
                        marker_dir.join("sighup-last-received"),
                        acknowledged_at.to_string(),
                    );
                    let ack = serde_json::json!({
                        "binding": binding,
                        "acknowledgedAtUnixMilliseconds": acknowledged_at,
                        "loadedTokenFingerprint": loaded_auth_hash,
                        "activeTokenFingerprint": active_auth_hash,
                        "frontendNotified": true,
                        "frontendWriteCount": frontend_write_count,
                        "authGeneration": auth_generation,
                    });
                    let ack_path = marker_dir.join("hotswap-ack").join(format!("{pid}.json"));
                    let temporary_ack_path = ack_path.with_extension("json.tmp");
                    if let Ok(encoded) = serde_json::to_vec(&ack)
                        && std::fs::write(&temporary_ack_path, encoded).is_ok()
                    {
                        use std::os::unix::fs::PermissionsExt;
                        let _ = std::fs::set_permissions(
                            &temporary_ack_path,
                            std::fs::Permissions::from_mode(0o600),
                        );
                        let _ = std::fs::rename(&temporary_ack_path, &ack_path);
                    }
                    if changed {
                        tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                    } else {
                        tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                    }
                }
            });
        }
"#,
        "CodexSwitch account/updated frontend write acknowledged after auth reload",
    )?;
    if in_process_app_server.exists() {
        patch_file_after(
            &in_process_app_server,
            "let auth_manager =\n            AuthManager::shared_from_config(args.config.as_ref(), args.enable_codex_api_key_env)\n                .await;",
            r#"
        #[cfg(unix)]
        {
            fn codexswitch_read_bounded_request(
                path: &std::path::Path,
            ) -> Option<serde_json::Value> {
                const REQUEST_MAX_BYTES: u64 = 16 * 1024;
                use std::os::unix::fs::OpenOptionsExt;
                let mut file = std::fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(path)
                    .ok()?;
                let metadata = file.metadata().ok()?;
                if !metadata.file_type().is_file() || metadata.len() > REQUEST_MAX_BYTES {
                    return None;
                }
                let mut data = Vec::with_capacity(metadata.len() as usize);
                let mut limited = std::io::Read::take(&mut file, REQUEST_MAX_BYTES + 1);
                std::io::Read::read_to_end(&mut limited, &mut data).ok()?;
                if data.len() as u64 > REQUEST_MAX_BYTES {
                    return None;
                }
                serde_json::from_slice(&data).ok()
            }

            #[cfg(target_os = "linux")]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
                let fields = stat.get(stat.rfind(')')? + 1..)?.split_whitespace();
                let start_ticks = fields.skip(19).next()?.parse::<u64>().ok()?;
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
                    (start_ticks % ticks_per_second).saturating_mul(1_000_000)
                        / ticks_per_second,
                ))
            }

            #[cfg(target_os = "macos")]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
                let size = std::mem::size_of::<libc::proc_bsdinfo>();
                let bytes = unsafe {
                    libc::proc_pidinfo(
                        std::process::id() as i32,
                        libc::PROC_PIDTBSDINFO,
                        0,
                        info.as_mut_ptr().cast(),
                        size as libc::c_int,
                    )
                };
                if bytes != size as libc::c_int {
                    return None;
                }
                let info = unsafe { info.assume_init() };
                (info.pbi_pid == std::process::id()).then_some((
                    info.pbi_start_tvsec,
                    info.pbi_start_tvusec,
                ))
            }

            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            fn codexswitch_current_process_start() -> Option<(u64, u64)> {
                None
            }

            fn codexswitch_validate_v3_binding(
                request: &serde_json::Value,
                expected_runtime_kind: &str,
            ) -> Option<(serde_json::Value, std::path::PathBuf, String, String)> {
                use std::os::unix::fs::MetadataExt;
                let request_object = request.as_object()?;
                if request_object.len() != 1 {
                    return None;
                }
                let binding = request_object.get("binding")?;
                if binding.as_object()?.len() != 7
                    || binding.get("contractVersion")?.as_u64()? != 3
                    || binding.get("runtimeKind")?.as_str()? != expected_runtime_kind
                {
                    return None;
                }

                let process = binding.get("processIdentity")?;
                let pid = std::process::id();
                let (start_seconds, start_microseconds) =
                    codexswitch_current_process_start()?;
                let executable = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
                let executable_text = executable.to_str()?;
                let executable_metadata = std::fs::metadata(&executable).ok()?;
                if process.as_object()?.len() != 5
                    || process.get("pid")?.as_u64()? != u64::from(pid)
                    || process.get("ownerUID")?.as_u64()? != u64::from(unsafe { libc::geteuid() })
                    || process.get("executablePath")?.as_str()? != executable_text
                    || process.get("startSeconds")?.as_u64()? != start_seconds
                    || process.get("startMicroseconds")?.as_u64()? != start_microseconds
                {
                    return None;
                }
                let kernel = binding.get("kernelExecutableIdentity")?;
                if kernel.as_object()?.len() != 3
                    || kernel.get("canonicalPath")?.as_str()? != executable_text
                    || kernel.get("device")?.as_u64()? != executable_metadata.dev()
                    || kernel.get("inode")?.as_u64()? != executable_metadata.ino()
                {
                    return None;
                }

                let auth_identity = binding.get("authFileIdentity")?;
                let auth_path = std::path::PathBuf::from(
                    auth_identity.get("canonicalPath")?.as_str()?,
                );
                let auth_metadata = std::fs::symlink_metadata(&auth_path).ok()?;
                if auth_identity.as_object()?.len() != 5
                    || !auth_path.is_absolute()
                    || auth_metadata.file_type().is_symlink()
                    || !auth_metadata.is_file()
                    || auth_metadata.uid() != unsafe { libc::geteuid() }
                    || std::fs::canonicalize(&auth_path).ok()? != auth_path
                    || auth_identity.get("device")?.as_u64()? != auth_metadata.dev()
                    || auth_identity.get("inode")?.as_u64()? != auth_metadata.ino()
                {
                    return None;
                }
                let account_id = auth_identity.get("accountID")?.as_str()?;
                let fingerprint = auth_identity
                    .get("completeTokenFingerprint")?
                    .as_str()?;
                let nonce = binding.get("requestNonce")?.as_str()?;
                if account_id.is_empty()
                    || account_id.len() > 1024
                    || !account_id.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
                    || fingerprint.len() != 64
                    || !fingerprint
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                    || nonce.is_empty()
                    || nonce.len() > 256
                    || binding.get("issuedAtUnixMilliseconds")?.as_u64()? == 0
                {
                    return None;
                }
                Some((
                    binding.clone(),
                    auth_path,
                    account_id.to_string(),
                    fingerprint.to_string(),
                ))
            }

            let codexswitch_marker_dir = std::env::var_os("HOME").map(|home| {
                let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
                let _ = std::fs::create_dir_all(&marker_dir);
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-ack"));
                let _ = std::fs::create_dir_all(marker_dir.join("hotswap-request"));
                let _ = std::fs::write(
                    marker_dir.join("sighup-verified"),
                    "in-process codexswitch-hotswap-cli-contract-v3 codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1\n",
                );
                marker_dir
            });

            let auth_for_signal = auth_manager.clone();
            let outgoing_for_signal = outgoing_tx.clone();
            tokio::spawn(async move {
                use tokio::signal::unix::{signal, SignalKind};
                let mut sighup = match signal(SignalKind::hangup()) {
                    Ok(s) => s,
                    Err(err) => {
                        tracing::error!("Failed to register in-process SIGHUP handler: {err}");
                        return;
                    }
                };
                loop {
                    if sighup.recv().await.is_none() {
                        break;
                    }
                    tracing::info!("SIGHUP: auth reload signal received by in-process app-server");
                    if outgoing_for_signal.is_closed() {
                        tracing::debug!(
                            "CodexSwitch stale in-process SIGHUP handler exiting before nonce consumption"
                        );
                        break;
                    }
                    let pid = std::process::id();
                    let Some(marker_dir) = codexswitch_marker_dir.as_ref() else {
                        tracing::error!("CodexSwitch SIGHUP marker directory is unavailable");
                        continue;
                    };
                    let request_path =
                        marker_dir.join("hotswap-request").join(format!("{pid}.json"));
                    let Some(request) = codexswitch_read_bounded_request(&request_path)
                    else {
                        tracing::error!("CodexSwitch SIGHUP request is missing or invalid");
                        continue;
                    };
                    let Some((binding, auth_path, expected_account_id, expected_auth_hash)) =
                        codexswitch_validate_v3_binding(&request, "local-interactive-cli")
                    else {
                        tracing::error!(
                            "CodexSwitch SIGHUP request does not match the canonical v3 runtime binding"
                        );
                        continue;
                    };
                    let (observed_auth_hash, observed_account_id) = match auth_for_signal
                        .codexswitch_auth_file_identity(&auth_path)
                    {
                        Ok(identity) => identity,
                        Err(err) => {
                            tracing::error!(
                                "CodexSwitch auth identity read failed; acknowledgement suppressed: {err}"
                            );
                            continue;
                        }
                    };
                    if observed_auth_hash != expected_auth_hash
                        || observed_account_id != expected_account_id
                    {
                        tracing::error!(
                            "CodexSwitch auth file does not match the v3 fingerprint/account binding"
                        );
                        continue;
                    }
                    let (changed, loaded_auth_hash, active_auth_hash) = match auth_for_signal
                        .codexswitch_reload_auth_json_verified(&auth_path)
                        .await
                    {
                        Ok(proof) => proof,
                        Err(err) => {
                            tracing::error!(
                                "CodexSwitch auth reload failed; acknowledgement suppressed: {err}"
                            );
                            continue;
                        }
                    };
                    if loaded_auth_hash != expected_auth_hash {
                        tracing::error!(
                            "CodexSwitch loaded auth fingerprint does not match the SIGHUP request"
                        );
                        continue;
                    }
                    let Some(auth) = auth_for_signal.auth_cached() else {
                        tracing::error!("CodexSwitch auth cache is empty after reload");
                        continue;
                    };
                    if auth.codexswitch_auth_fingerprint().as_deref()
                        != Some(active_auth_hash.as_str())
                        || auth.codexswitch_provider_account_id().as_deref()
                            != Some(expected_account_id.as_str())
                    {
                        tracing::error!(
                            "CodexSwitch cached auth identity does not match the v3 binding"
                        );
                        continue;
                    }
                    let auth_generation = auth_for_signal.auth_generation();
                    if outgoing_for_signal
                        .send(OutgoingEnvelope::Broadcast {
                            message: OutgoingMessage::AppServerNotification(
                                ServerNotification::AccountUpdated(
                                    codex_app_server_protocol::AccountUpdatedNotification {
                                        auth_mode: Some(crate::auth_mode::auth_mode_to_api(
                                            auth.api_auth_mode(),
                                        )),
                                        plan_type: auth.account_plan_type(),
                                    },
                                ),
                            ),
                        })
                        .await
                        .is_err()
                    {
                        tracing::debug!(
                            "CodexSwitch could not deliver best-effort account/updated to the local TUI"
                        );
                    }
                    tracing::info!(
                        "CodexSwitch local CLI auth generation is ready for reconnect after auth reload"
                    );
                    let acknowledged_at = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|duration| duration.as_millis() as u64)
                        .unwrap_or(0);
                    let _ = std::fs::write(
                        marker_dir.join("sighup-last-received"),
                        acknowledged_at.to_string(),
                    );
                    let ack = serde_json::json!({
                        "binding": binding,
                        "acknowledgedAtUnixMilliseconds": acknowledged_at,
                        "loadedTokenFingerprint": loaded_auth_hash,
                        "activeTokenFingerprint": active_auth_hash,
                        "frontendNotified": false,
                        "frontendWriteCount": 0,
                        "authGeneration": auth_generation,
                        "reconnectReady": true,
                    });
                    let ack_path = marker_dir.join("hotswap-ack").join(format!("{pid}.json"));
                    let temporary_ack_path = ack_path.with_extension("json.tmp");
                    if let Ok(encoded) = serde_json::to_vec(&ack)
                        && std::fs::write(&temporary_ack_path, encoded).is_ok()
                    {
                        use std::os::unix::fs::PermissionsExt;
                        let _ = std::fs::set_permissions(
                            &temporary_ack_path,
                            std::fs::Permissions::from_mode(0o600),
                        );
                        let _ = std::fs::rename(&temporary_ack_path, &ack_path);
                    }
                    if changed {
                        tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                    } else {
                        tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                    }
                }
            });
        }
"#,
            "codexswitch-hotswap-cli-contract-v3",
        )?;
    }
    Ok(())
}

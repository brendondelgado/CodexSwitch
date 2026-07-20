fn remove_foreground_tui_sighup_handler(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let marker = "sighup-verified-tui";
    let legacy_log = "foreground session ignores signal; app-server reloads auth";
    let Some(marker_index) = content.find(marker).or_else(|| content.find(legacy_log)) else {
        return Ok(());
    };
    let block_start = content[..marker_index]
        .rfind("    #[cfg(unix)]\n    {")
        .with_context(|| {
            format!(
                "legacy foreground SIGHUP block start not found in {}",
                path.display()
            )
        })?;
    let anchor = "    // Initialize high-fidelity session event logging if enabled.";
    let block_end = content[marker_index..]
        .find(anchor)
        .map(|offset| marker_index + offset)
        .with_context(|| {
            format!(
                "legacy foreground SIGHUP block end not found in {}",
                path.display()
            )
        })?;
    let updated = format!("{}{}", &content[..block_start], &content[block_end..]);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_app_server_shutdown_signal_source(path: &Path) -> Result<()> {
    const MARKER: &str = "CODEXSWITCH_SIGHUP_RELOAD_ONLY";
    const GRACEFUL_VARIANT: &str = "    Forceable,\n    #[cfg(unix)]\n    GracefulOnly,\n";
    const HANGUP_REGISTRATION: &str = "        let mut hangup = signal(SignalKind::hangup())?;\n";
    const HANGUP_SHUTDOWN_BRANCH: &str =
        "            _ = hangup.recv() => Ok(ShutdownSignal::GracefulOnly),\n";

    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(MARKER) {
        return Ok(());
    }
    if !content.contains(HANGUP_REGISTRATION) && !content.contains(HANGUP_SHUTDOWN_BRANCH) {
        return Ok(());
    }
    if !content.contains(GRACEFUL_VARIANT)
        || !content.contains(HANGUP_REGISTRATION)
        || !content.contains(HANGUP_SHUTDOWN_BRANCH)
    {
        bail!(
            "app-server SIGHUP shutdown shape changed in {}; refusing an unsafe partial patch",
            path.display()
        );
    }

    let updated = content
        .replace(GRACEFUL_VARIANT, "    Forceable,\n")
        .replace(
            HANGUP_REGISTRATION,
            "        // CODEXSWITCH_SIGHUP_RELOAD_ONLY: the auth reload task owns SIGHUP.\n",
        )
        .replace(HANGUP_SHUTDOWN_BRANCH, "");
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn patch_app_server_frontend_write_ack_source(
    outgoing_message_path: &Path,
    transport_path: &Path,
) -> Result<()> {
    if !outgoing_message_path.exists() || !transport_path.exists() {
        return Ok(());
    }

    patch_file_after(
        outgoing_message_path,
        r#"    Broadcast {
        message: OutgoingMessage,
    },"#,
        r#"
    /// Broadcasts a notification and reports how many initialized frontend
    /// writers were eligible and completed the underlying transport write.
    BroadcastWithWriteAck {
        message: OutgoingMessage,
        write_complete_tx: oneshot::Sender<(usize, usize, usize)>,
    },"#,
        "BroadcastWithWriteAck",
    )?;

    patch_file_before(
        transport_path,
        "        OutgoingEnvelope::Broadcast { message } => {",
        r#"        OutgoingEnvelope::BroadcastWithWriteAck {
            message,
            write_complete_tx,
        } => {
            let initialized_frontend_count = connections
                .iter()
                .filter(|(_, connection_state)| {
                    connection_state.initialized.load(Ordering::Acquire)
                })
                .count();
            let target_connections: Vec<ConnectionId> = connections
                .iter()
                .filter_map(|(connection_id, connection_state)| {
                    if connection_state.initialized.load(Ordering::Acquire)
                        && !should_skip_notification_for_connection(connection_state, &message)
                    {
                        Some(*connection_id)
                    } else {
                        None
                    }
                })
                .collect();
            let eligible_frontend_count = target_connections.len();
            let mut write_receivers = Vec::with_capacity(target_connections.len());

            for connection_id in target_connections {
                let (connection_write_tx, connection_write_rx) = tokio::sync::oneshot::channel();
                let _ = send_message_to_connection(
                    connections,
                    connection_id,
                    message.clone(),
                    Some(connection_write_tx),
                )
                .await;
                write_receivers.push(connection_write_rx);
            }

            tokio::spawn(async move {
                let results = futures::future::join_all(write_receivers.into_iter().map(|receiver| {
                    tokio::time::timeout(std::time::Duration::from_secs(2), receiver)
                }))
                .await;
                let completed_writes = results
                    .into_iter()
                    .filter(|result| matches!(result, Ok(Ok(()))))
                    .count();
                let _ = write_complete_tx.send((
                    initialized_frontend_count,
                    eligible_frontend_count,
                    completed_writes,
                ));
            });
        }
"#,
        "OutgoingEnvelope::BroadcastWithWriteAck",
    )?;
    Ok(())
}

fn patch_in_process_account_updated_delivery_source(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    patch_file_after(
        path,
        "        ServerNotification::TurnCompleted(_)",
        "\n            | ServerNotification::AccountUpdated(_)",
        "ServerNotification::AccountUpdated(_)",
    )
}

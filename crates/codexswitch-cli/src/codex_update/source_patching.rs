include!("source_checkout.rs");
include!("source_app_server_template.rs");
include!("source_turn_template.rs");
include!("source_app_server_patching.rs");
include!("source_auth_patching.rs");
include!("source_cargo_patching.rs");
include!("source_websocket_patching.rs");
include!("source_patch_helpers.rs");

fn patch_codex_source(source_dir: &Path) -> Result<()> {
    let workspace_manifest = source_dir.join("codex-rs/Cargo.toml");
    let lockfile = source_dir.join("codex-rs/Cargo.lock");
    let app_server = source_dir.join("codex-rs/app-server/src/lib.rs");
    let app_server_manifest = source_dir.join("codex-rs/app-server/Cargo.toml");
    let in_process_app_server = source_dir.join("codex-rs/app-server/src/in_process.rs");
    let app_server_outgoing = source_dir.join("codex-rs/app-server/src/outgoing_message.rs");
    let app_server_transport = source_dir.join("codex-rs/app-server/src/transport.rs");
    let auth_manager = source_dir.join("codex-rs/login/src/auth/manager.rs");
    let login_manifest = source_dir.join("codex-rs/login/Cargo.toml");
    let client = source_dir.join("codex-rs/core/src/client.rs");
    let turn = source_dir.join("codex-rs/core/src/session/turn.rs");
    let tui = source_dir.join("codex-rs/tui/src/lib.rs");
    patch_placeholder_workspace_lock_versions_if_present(&workspace_manifest, &lockfile)?;
    patch_workspace_dependency_if_present(&app_server_manifest, "libc")?;
    patch_lockfile_dependency_if_present(&lockfile, "codex-app-server", "libc")?;
    patch_app_server_shutdown_signal_source(&app_server)?;
    patch_workspace_dependency_if_present(&login_manifest, "libc")?;
    patch_lockfile_dependency_if_present(&lockfile, "codex-login", "libc")?;
    patch_auth_manager_source(&auth_manager)?;
    let uses_timestamped_server_notifications =
        patch_timestamped_server_notification_visibility(&app_server_outgoing)?;
    patch_app_server_frontend_write_ack_source(&app_server_outgoing, &app_server_transport)?;
    patch_in_process_account_updated_delivery_source(&in_process_app_server)?;
    patch_client_websocket_source(&client)?;
    patch_app_server_reload_template(
        &app_server,
        &in_process_app_server,
        uses_timestamped_server_notifications,
    )?;
    patch_turn_rotation_templates(&turn)?;
    remove_foreground_tui_sighup_handler(&tui)?;
    Ok(())
}

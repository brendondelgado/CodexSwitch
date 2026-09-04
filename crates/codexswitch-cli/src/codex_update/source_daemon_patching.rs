const MANAGED_DAEMON_RUNTIME_MARKER: &str = "codexswitch-managed-daemon-current-v1";
const MANAGED_DAEMON_UPDATE_MARKER: &str = "codexswitch-managed-daemon-no-standalone-update-v1";

fn patch_app_server_daemon_source(managed_install: &Path, update_loop: &Path) -> Result<()> {
    if !managed_install.exists() && !update_loop.exists() {
        return Ok(());
    }
    if !managed_install.exists() || !update_loop.exists() {
        bail!(
            "app-server daemon source is incomplete: {} and {} must both exist",
            managed_install.display(),
            update_loop.display()
        );
    }

    replace_source_anchor_once(
        managed_install,
        r#"pub(crate) fn managed_codex_bin(codex_home: &Path) -> PathBuf {
    codex_home
        .join("packages")
        .join("standalone")
        .join("current")
        .join(managed_codex_file_name())
}"#,
        r#"#[cfg(target_os = "linux")]
pub(crate) fn managed_codex_bin(codex_home: &Path) -> PathBuf {
    // codexswitch-managed-daemon-current-v1
    let Some(home) = std::env::var_os("HOME") else {
        return codex_home.join("codexswitch-managed-runtime-home-unavailable");
    };
    PathBuf::from(home)
        .join(".local")
        .join("share")
        .join("codexswitch")
        .join("current")
        .join("patched-codex")
        .join("codex")
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn managed_codex_bin(codex_home: &Path) -> PathBuf {
    codex_home
        .join("packages")
        .join("standalone")
        .join("current")
        .join(managed_codex_file_name())
}"#,
        MANAGED_DAEMON_RUNTIME_MARKER,
    )?;
    replace_source_anchor_once(
        update_loop,
        "    install_latest_standalone(http).await?;",
        r#"    // codexswitch-managed-daemon-no-standalone-update-v1
    // CodexSwitch owns reviewed runtime installation. The daemon loop only
    // observes the immutable current generation and restarts on identity drift.
    let _ = http;"#,
        MANAGED_DAEMON_UPDATE_MARKER,
    )
}

fn replace_source_anchor_once(
    path: &Path,
    anchor: &str,
    replacement: &str,
    marker: &str,
) -> Result<()> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if content.contains(marker) {
        return Ok(());
    }
    let occurrences = content.matches(anchor).count();
    if occurrences != 1 {
        bail!(
            "expected exactly one source anchor in {}, found {occurrences}",
            path.display()
        );
    }
    let updated = content.replacen(anchor, replacement, 1);
    fs::write(path, updated).with_context(|| format!("failed to write {}", path.display()))
}

#[cfg(test)]
mod daemon_source_patch_tests {
    use super::*;

    const MANAGED_INSTALL_FIXTURE: &str = r#"use std::path::Path;
use std::path::PathBuf;

pub(crate) fn managed_codex_bin(codex_home: &Path) -> PathBuf {
    codex_home
        .join("packages")
        .join("standalone")
        .join("current")
        .join(managed_codex_file_name())
}
"#;
    const UPDATE_LOOP_FIXTURE: &str = r#"async fn update_once(http: &RouteAwareClientPool) -> Result<()> {
    install_latest_standalone(http).await?;
    observe_current().await
}
"#;

    #[test]
    fn daemon_patch_routes_linux_to_current_and_disables_stock_install() {
        let temp = tempfile::tempdir().unwrap();
        let managed_install = temp.path().join("managed_install.rs");
        let update_loop = temp.path().join("update_loop.rs");
        fs::write(&managed_install, MANAGED_INSTALL_FIXTURE).unwrap();
        fs::write(&update_loop, UPDATE_LOOP_FIXTURE).unwrap();

        patch_app_server_daemon_source(&managed_install, &update_loop).unwrap();
        let first_managed = fs::read_to_string(&managed_install).unwrap();
        let first_update = fs::read_to_string(&update_loop).unwrap();
        patch_app_server_daemon_source(&managed_install, &update_loop).unwrap();

        assert_eq!(fs::read_to_string(&managed_install).unwrap(), first_managed);
        assert_eq!(fs::read_to_string(&update_loop).unwrap(), first_update);
        assert!(first_managed.contains(MANAGED_DAEMON_RUNTIME_MARKER));
        assert!(first_managed.contains(".join(\"current\")"));
        assert!(first_managed.contains(".join(\"patched-codex\")"));
        assert!(first_managed.contains("codexswitch-managed-runtime-home-unavailable"));
        assert!(first_update.contains(MANAGED_DAEMON_UPDATE_MARKER));
        assert!(!first_update.contains("    install_latest_standalone(http).await?;"));
    }

    #[test]
    fn daemon_patch_fails_closed_on_partial_or_drifted_source() {
        let temp = tempfile::tempdir().unwrap();
        let managed_install = temp.path().join("managed_install.rs");
        let update_loop = temp.path().join("update_loop.rs");
        fs::write(&managed_install, MANAGED_INSTALL_FIXTURE).unwrap();

        let partial = patch_app_server_daemon_source(&managed_install, &update_loop).unwrap_err();
        assert!(partial.to_string().contains("source is incomplete"));

        fs::write(&update_loop, "async fn update_once() {}\n").unwrap();
        let drifted = patch_app_server_daemon_source(&managed_install, &update_loop).unwrap_err();
        assert!(drifted.to_string().contains("found 0"));
    }
}

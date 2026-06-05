use anyhow::{bail, Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone)]
pub struct InstallPatchedCodexOptions {
    pub source: PathBuf,
    pub yes: bool,
    pub replace_system_entry: bool,
    pub replace_npm_vendor: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InstallPatchedCodexReport {
    pub built_binary: PathBuf,
    pub installed_binary: PathBuf,
    pub user_launcher: PathBuf,
    pub system_launcher_replaced: bool,
    pub npm_vendor_replaced: bool,
    pub dry_run: bool,
}

pub fn install(options: InstallPatchedCodexOptions) -> Result<InstallPatchedCodexReport> {
    let source = options.source.expand_home();
    let workspace = if source.file_name().is_some_and(|name| name == "codex-rs") {
        source
    } else {
        source.join("codex-rs")
    };
    let built_binary = workspace.join("target/release/codex");
    let install_dir = home_dir()?.join(".local/share/codexswitch/patched-codex");
    let installed_binary = install_dir.join("codex");
    let user_launcher = home_dir()?.join(".local/bin/codex");

    let report = InstallPatchedCodexReport {
        built_binary: built_binary.clone(),
        installed_binary: installed_binary.clone(),
        user_launcher: user_launcher.clone(),
        system_launcher_replaced: options.replace_system_entry,
        npm_vendor_replaced: options.replace_npm_vendor,
        dry_run: !options.yes,
    };

    if !options.yes {
        return Ok(report);
    }

    if !workspace.join("Cargo.toml").exists() {
        bail!("Codex Rust workspace not found at {}", workspace.display());
    }

    ensure_linux_build_prerequisites()?;

    let build_status = Command::new("bash")
        .arg("-lc")
        .arg(
            ". \"$HOME/.cargo/env\" 2>/dev/null || true; \
             CARGO_PROFILE_RELEASE_LTO=false \
             CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
             cargo build --release -p codex-cli",
        )
        .current_dir(&workspace)
        .status()
        .with_context(|| format!("failed to build Codex at {}", workspace.display()))?;
    if !build_status.success() {
        bail!("Codex build failed with {build_status}");
    }
    if !binary_has_hot_swap_markers(&built_binary) {
        bail!(
            "built Codex binary is missing SIGHUP hot-swap markers: {}",
            built_binary.display()
        );
    }

    install_prepared_binary(&built_binary, &installed_binary, &user_launcher)?;

    if options.replace_system_entry {
        let system_launcher = "/usr/bin/codex";
        let backup = "/usr/bin/codex.codexswitch-backup";
        let script_path = install_dir.join("codex-launcher");
        fs::write(
            &script_path,
            launcher_script(&installed_binary.display().to_string()),
        )?;
        set_executable(&script_path)?;
        let command = format!(
            "if [ ! -e {backup} ]; then cp -P {system} {backup}; fi; install -m 755 {script} {system}",
            backup = shell_quote(backup),
            system = shell_quote(system_launcher),
            script = shell_quote(&script_path.display().to_string())
        );
        let status = Command::new("bash")
            .arg("-lc")
            .arg(format!("sudo -n bash -lc {}", shell_quote(&command)))
            .status()
            .context("failed to replace /usr/bin/codex with patched launcher")?;
        if !status.success() {
            bail!("failed to replace /usr/bin/codex with patched launcher: {status}");
        }
    }

    if options.replace_npm_vendor {
        replace_npm_vendor_binary(&installed_binary)?;
    }

    Ok(report)
}

fn replace_npm_vendor_binary(installed_binary: &Path) -> Result<()> {
    let vendor_binary = "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex";
    let backup = "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex.codexswitch-backup";
    if !Path::new(vendor_binary).exists() {
        return Ok(());
    }
    let command = format!(
        "if [ ! -e {backup} ]; then cp -P {vendor} {backup}; fi; install -m 755 {source} {vendor}",
        backup = shell_quote(backup),
        vendor = shell_quote(vendor_binary),
        source = shell_quote(&installed_binary.display().to_string())
    );
    let status = Command::new("bash")
        .arg("-lc")
        .arg(format!("sudo -n bash -lc {}", shell_quote(&command)))
        .status()
        .context("failed to replace npm Codex vendor binary")?;
    if !status.success() {
        bail!("failed to replace npm Codex vendor binary: {status}");
    }
    Ok(())
}

pub fn install_prepared_binary(
    prepared_binary: &Path,
    installed_binary: &Path,
    user_launcher: &Path,
) -> Result<()> {
    if !binary_has_hot_swap_markers(prepared_binary) {
        bail!(
            "prepared Codex binary is missing SIGHUP hot-swap markers: {}",
            prepared_binary.display()
        );
    }
    let launcher_target = if cfg!(target_os = "macos") {
        if let Some(parent) = installed_binary.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(
            installed_binary,
            launcher_script(&prepared_binary.display().to_string()),
        )?;
        set_executable(installed_binary)?;
        prepared_binary
    } else {
        if let Some(parent) = installed_binary.parent() {
            fs::create_dir_all(parent)?;
        }
        atomic_install_binary(prepared_binary, installed_binary)?;
        installed_binary
    };

    if let Some(parent) = user_launcher.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(
        user_launcher,
        launcher_script(&launcher_target.display().to_string()),
    )?;
    set_executable(user_launcher)?;
    Ok(())
}

fn atomic_install_binary(source: &Path, destination: &Path) -> Result<()> {
    let parent = destination
        .parent()
        .with_context(|| format!("{} has no parent directory", destination.display()))?;
    fs::create_dir_all(parent)?;
    let pid = std::process::id();
    let temp_destination = parent.join(format!(
        ".{}.tmp-{pid}",
        destination
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("codex")
    ));
    if temp_destination.exists() {
        fs::remove_file(&temp_destination).with_context(|| {
            format!(
                "failed to remove stale temporary install file {}",
                temp_destination.display()
            )
        })?;
    }
    fs::copy(source, &temp_destination).with_context(|| {
        format!(
            "failed to copy {} to temporary install file {}",
            source.display(),
            temp_destination.display()
        )
    })?;
    set_executable(&temp_destination)?;
    fs::rename(&temp_destination, destination).with_context(|| {
        format!(
            "failed to atomically replace {} with {}",
            destination.display(),
            source.display()
        )
    })?;
    Ok(())
}

pub fn default_installed_binary() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/share/codexswitch/patched-codex/codex"))
}

pub fn default_user_launcher() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/bin/codex"))
}

pub fn binary_has_hot_swap_markers(path: &Path) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    contains_bytes(&data, b"sighup-verified")
        && contains_bytes(&data, b"SIGHUP: auth reloaded")
        && contains_bytes(&data, b"hotswap-ack")
        && contains_bytes(&data, b"CodexSwitch rotated accounts after a usage limit")
        && contains_bytes(
            &data,
            b"Auth changed, opening new WebSocket with fresh credentials",
        )
        && binary_data_has_goal_support(&data)
}

pub fn binary_data_has_goal_support(data: &[u8]) -> bool {
    contains_bytes(data, b"Usage: /goal <objective>")
        || (contains_bytes(data, b"Pursuing goal") && contains_bytes(data, b"thread/goal/set"))
}

pub fn codex_version(binary: &Path) -> Option<String> {
    let output = Command::new(binary).arg("--version").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    parse_codex_version(&text)
}

pub fn parse_codex_version(text: &str) -> Option<String> {
    text.split_whitespace()
        .find(|part| part.chars().next().is_some_and(|ch| ch.is_ascii_digit()))
        .map(|part| part.trim().to_string())
}

pub fn build_codex(workspace: &Path) -> Result<PathBuf> {
    if !workspace.join("Cargo.toml").exists() {
        bail!("Codex Rust workspace not found at {}", workspace.display());
    }
    ensure_linux_build_prerequisites()?;
    let build_status = Command::new("bash")
        .arg("-lc")
        .arg(
            ". \"$HOME/.cargo/env\" 2>/dev/null || true; \
             CARGO_PROFILE_RELEASE_LTO=false \
             CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
             cargo build --release -p codex-cli",
        )
        .current_dir(workspace)
        .status()
        .with_context(|| format!("failed to build Codex at {}", workspace.display()))?;
    if !build_status.success() {
        bail!("Codex build failed with {build_status}");
    }
    let built_binary = workspace.join("target/release/codex");
    if !binary_has_hot_swap_markers(&built_binary) {
        bail!(
            "built Codex binary is missing SIGHUP hot-swap markers: {}",
            built_binary.display()
        );
    }
    Ok(built_binary)
}

fn launcher_script(patched_binary: &str) -> String {
    let quoted = shell_quote(patched_binary);
    r#"#!/usr/bin/env bash
set -euo pipefail
PATCHED_CODEX=__PATCHED_CODEX__

has_patch() {
  local candidate="$1"
  [[ -r "$candidate" ]] || return 1
  strings "$candidate" 2>/dev/null | awk '
            /sighup-verified/ { has_marker = 1 }
            /SIGHUP: auth reloaded/ { has_reload = 1 }
            /hotswap-ack/ { has_ack = 1 }
            /CodexSwitch rotated accounts after a usage limit/ { has_usage_retry = 1 }
            /Auth changed, opening new WebSocket with fresh credentials/ { has_auth_ws = 1 }
            END { exit !(has_marker && has_reload && has_ack && has_usage_retry && has_auth_ws) }
          '
}

codex_version_base() {
  local candidate="$1"
  "$candidate" --version 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {
          sub(/-.*/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

version_at_least_0128() {
  local version major minor patch
  version="$(codex_version_base "$1")"
  IFS=. read -r major minor patch <<< "$version"
  [[ "${major:-0}" =~ ^[0-9]+$ && "${minor:-0}" =~ ^[0-9]+$ && "${patch:-0}" =~ ^[0-9]+$ ]] || return 1
  (( major > 0 || minor > 128 || (minor == 128 && patch >= 0) ))
}

has_goal_support() {
  local candidate="$1"
  [[ -r "$candidate" ]] || return 1
  strings "$candidate" 2>/dev/null | awk '
            /Usage: \/goal <objective>/ { has_goal_usage = 1 }
            /Pursuing goal/ { has_goal_status = 1 }
            /thread\/goal\/set/ { has_goal_rpc = 1 }
            END { exit !(has_goal_usage || (has_goal_status && has_goal_rpc)) }
          '
}

if [[ -x "$PATCHED_CODEX" ]] \
  && "$PATCHED_CODEX" --version >/dev/null 2>&1 \
  && version_at_least_0128 "$PATCHED_CODEX" \
  && has_patch "$PATCHED_CODEX" \
  && has_goal_support "$PATCHED_CODEX"; then
  exec "$PATCHED_CODEX" "$@"
fi

echo "codex: patched goal-capable Codex binary unavailable; run codexswitch-cli install-prepared-codex" >&2
exit 1
"#
    .replace("__PATCHED_CODEX__", &quoted)
}

fn ensure_linux_build_prerequisites() -> Result<()> {
    if !cfg!(target_os = "linux") {
        return Ok(());
    }
    let has_libcap = Command::new("bash")
        .arg("-lc")
        .arg("pkg-config --exists libcap")
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    if has_libcap {
        return Ok(());
    }

    let status = Command::new("bash")
        .arg("-lc")
        .arg("sudo -n apt-get update && sudo -n apt-get install -y pkg-config libcap-dev build-essential")
        .status()
        .context("failed to install Linux Codex build prerequisites")?;
    if !status.success() {
        bail!("failed to install Linux Codex build prerequisites: {status}");
    }
    Ok(())
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn set_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}

trait ExpandHome {
    fn expand_home(&self) -> PathBuf;
}

impl ExpandHome for PathBuf {
    fn expand_home(&self) -> PathBuf {
        let Some(path) = self.to_str() else {
            return self.clone();
        };
        if path == "~" {
            return home_dir().unwrap_or_else(|_| self.clone());
        }
        if let Some(rest) = path.strip_prefix("~/") {
            return home_dir()
                .map(|home| home.join(rest))
                .unwrap_or_else(|_| self.clone());
        }
        self.clone()
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_routes_app_server_to_patched_binary() {
        let script = launcher_script("/home/signul/.local/share/codexswitch/patched-codex/codex");

        assert!(script
            .contains("PATCHED_CODEX='/home/signul/.local/share/codexswitch/patched-codex/codex'"));
        assert!(script.contains("exec \"$PATCHED_CODEX\" \"$@\""));
        assert!(script.contains("sighup-verified"));
        assert!(script.contains("SIGHUP: auth reloaded"));
        assert!(script.contains("hotswap-ack"));
        assert!(script.contains("CodexSwitch rotated accounts after a usage limit"));
        assert!(script.contains("Auth changed, opening new WebSocket with fresh credentials"));
        assert!(script.contains("Usage: \\/goal <objective>"));
        assert!(!script.contains("/usr/lib/node_modules/@openai/codex/bin/codex.js"));
    }

    #[test]
    fn install_prepared_binary_uses_versioned_prepared_path_on_macos() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let prepared_binary = temp.path().join("prepared-codex/0.128.0/codex");
        let installed_binary = temp.path().join("patched-codex/codex");
        let user_launcher = temp.path().join("bin/codex");
        fs::create_dir_all(prepared_binary.parent().unwrap())?;
        fs::write(
            &prepared_binary,
            "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit Auth changed, opening new WebSocket with fresh credentials Usage: /goal <objective>\necho codex-cli 0.128.0\n",
        )?;
        set_executable(&prepared_binary)?;

        install_prepared_binary(&prepared_binary, &installed_binary, &user_launcher)?;

        let script = fs::read_to_string(&user_launcher)?;
        if cfg!(target_os = "macos") {
            assert!(script.contains(&format!(
                "PATCHED_CODEX={}",
                shell_quote(&prepared_binary.display().to_string())
            )));
            assert!(installed_binary.exists());
            let installed_script = fs::read_to_string(&installed_binary)?;
            assert!(installed_script.contains(&format!(
                "PATCHED_CODEX={}",
                shell_quote(&prepared_binary.display().to_string())
            )));
        } else {
            assert!(script.contains(&format!(
                "PATCHED_CODEX={}",
                shell_quote(&installed_binary.display().to_string())
            )));
            assert!(installed_binary.exists());
        }
        Ok(())
    }

    #[test]
    fn atomic_install_binary_replaces_destination_without_copying_over_it() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("source-codex");
        let destination = temp.path().join("bin/codex");
        fs::create_dir_all(destination.parent().unwrap())?;
        fs::write(&source, "#!/bin/sh\necho new\n")?;
        fs::write(&destination, "#!/bin/sh\necho old\n")?;

        atomic_install_binary(&source, &destination)?;

        assert_eq!(fs::read_to_string(&destination)?, "#!/bin/sh\necho new\n");
        let temp_files = fs::read_dir(destination.parent().unwrap())?
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".codex.tmp-")
            })
            .count();
        assert_eq!(temp_files, 0);
        Ok(())
    }
}

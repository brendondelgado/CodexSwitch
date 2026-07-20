use crate::bounded_command;
use anyhow::{bail, Context, Result};
use std::fs::{self, OpenOptions};
use std::io::{BufReader, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

// Single-job release builds have exceeded one hour on a contended 8-core host.
pub(crate) const BUILD_COMMAND_TIMEOUT: Duration = Duration::from_secs(3 * 60 * 60);
const INSTALL_COMMAND_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const PROBE_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);
const LAUNCHER_MAX_BYTES: u64 = 1024 * 1024;

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
    let InstallPatchedCodexOptions {
        source,
        yes,
        replace_system_entry,
        replace_npm_vendor,
    } = options;
    bail!(
        "direct install-patched-codex is disabled for source {} (yes={yes}, replace-system-entry={replace_system_entry}, replace-npm-vendor={replace_npm_vendor}); prepare a reviewed generation and install it only through the guarded journaled updater transaction",
        source.display()
    )
}

pub fn validate_code_mode_host_for_runtime(codex_binary: &Path) -> Result<()> {
    let helper = codex_binary.with_file_name("codex-code-mode-host");
    let metadata = fs::metadata(&helper).with_context(|| {
        format!(
            "prepared Codex runtime is missing codex-code-mode-host: {}",
            helper.display()
        )
    })?;
    if !metadata.is_file() || metadata.len() == 0 {
        bail!(
            "prepared codex-code-mode-host is empty or not a file: {}",
            helper.display()
        );
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o111 == 0 {
            bail!(
                "prepared codex-code-mode-host is not executable: {}",
                helper.display()
            );
        }
    }
    #[cfg(target_os = "macos")]
    if path_is_macho(&helper)? {
        let status = bounded_command::status(
            Command::new("/usr/bin/codesign")
                .args(["--verify", "--strict"])
                .arg(&helper),
            PROBE_COMMAND_TIMEOUT,
        )
        .with_context(|| format!("failed to verify staged helper {}", helper.display()))?;
        if !status.success() {
            bail!(
                "staged codex-code-mode-host signature is invalid: {}",
                helper.display()
            );
        }
    }
    Ok(())
}

pub fn runtime_has_valid_code_mode_host(codex_binary: &Path) -> bool {
    validate_code_mode_host_for_runtime(codex_binary).is_ok()
}

#[cfg(target_os = "macos")]
fn path_is_macho(path: &Path) -> Result<bool> {
    let mut file = fs::File::open(path)?;
    let mut magic = [0_u8; 4];
    if file.read_exact(&mut magic).is_err() {
        return Ok(false);
    }
    Ok(matches!(
        magic,
        [0xcf, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xcf]
            | [0xce, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xce]
            | [0xca, 0xfe, 0xba, 0xbe]
            | [0xbe, 0xba, 0xfe, 0xca]
            | [0xca, 0xfe, 0xba, 0xbf]
            | [0xbf, 0xba, 0xfe, 0xca]
    ))
}

pub fn default_installed_binary() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/share/codexswitch/patched-codex/codex"))
}

pub fn default_user_launcher() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/bin/codex"))
}

pub fn default_homebrew_launcher() -> PathBuf {
    PathBuf::from("/opt/homebrew/bin/codex")
}

pub fn binary_has_hot_swap_markers(path: &Path) -> bool {
    binary_has_marker_contract(path, RequiredMarkerContract::Full)
}

#[cfg(test)]
pub fn binary_has_external_app_server_hot_swap_markers(path: &Path) -> bool {
    binary_has_marker_contract(path, RequiredMarkerContract::ExternalAppServer)
}

#[cfg(test)]
pub fn binary_has_local_cli_hot_swap_markers(path: &Path) -> bool {
    binary_has_marker_contract(path, RequiredMarkerContract::LocalCli)
}

#[cfg(test)]
pub fn binary_has_headless_remote_control_hot_swap_markers(path: &Path) -> bool {
    binary_has_marker_contract(path, RequiredMarkerContract::HeadlessRemoteControl)
}

const BINARY_MARKER_SCAN_CHUNK_BYTES: usize = 128 * 1024;
const COMMON_HOT_SWAP_MARKERS: [&[u8]; 8] = [
    b"sighup-verified",
    b"SIGHUP: auth reloaded",
    b"hotswap-ack",
    b"CodexSwitch rotated accounts after a usage limit",
    b"CodexSwitch rotated accounts after an auth failure",
    b"Auth changed, opening new WebSocket with fresh credentials",
    b"codexswitch-runtime-convergence-v3",
    b"codexswitch-runtime-rotation-handoff-v1",
];
const EXTERNAL_APP_SERVER_HOT_SWAP_MARKERS: [&[u8]; 2] = [
    b"CodexSwitch account/updated frontend write acknowledged after auth reload",
    b"codexswitch-hotswap-contract-v3",
];
const HEADLESS_REMOTE_CONTROL_HOT_SWAP_MARKERS: [&[u8]; 1] =
    [b"codexswitch-hotswap-headless-idle-v1"];
const LOCAL_CLI_HOT_SWAP_MARKERS: [&[u8]; 1] = [b"codexswitch-hotswap-cli-contract-v3"];
const GOAL_USAGE_MARKER: &[u8] = b"Usage: /goal <objective>";
const GOAL_PURSUING_MARKER: &[u8] = b"Pursuing goal";
const GOAL_SET_MARKER: &[u8] = b"thread/goal/set";

#[derive(Default)]
struct BinaryMarkerState {
    common: [bool; COMMON_HOT_SWAP_MARKERS.len()],
    external: [bool; EXTERNAL_APP_SERVER_HOT_SWAP_MARKERS.len()],
    headless_remote_control: [bool; HEADLESS_REMOTE_CONTROL_HOT_SWAP_MARKERS.len()],
    local: [bool; LOCAL_CLI_HOT_SWAP_MARKERS.len()],
    goal_usage: bool,
    goal_pursuing: bool,
    goal_set: bool,
}

#[derive(Clone, Copy)]
enum RequiredMarkerContract {
    Full,
    #[cfg(test)]
    ExternalAppServer,
    #[cfg(test)]
    HeadlessRemoteControl,
    #[cfg(test)]
    LocalCli,
}

impl BinaryMarkerState {
    fn update(&mut self, data: &[u8]) {
        update_marker_flags(&mut self.common, &COMMON_HOT_SWAP_MARKERS, data);
        update_marker_flags(
            &mut self.external,
            &EXTERNAL_APP_SERVER_HOT_SWAP_MARKERS,
            data,
        );
        update_marker_flags(
            &mut self.headless_remote_control,
            &HEADLESS_REMOTE_CONTROL_HOT_SWAP_MARKERS,
            data,
        );
        update_marker_flags(&mut self.local, &LOCAL_CLI_HOT_SWAP_MARKERS, data);
        self.goal_usage |= contains_bytes(data, GOAL_USAGE_MARKER);
        self.goal_pursuing |= contains_bytes(data, GOAL_PURSUING_MARKER);
        self.goal_set |= contains_bytes(data, GOAL_SET_MARKER);
    }

    fn has_common_contract(&self) -> bool {
        self.common.iter().all(|present| *present)
            && (self.goal_usage || (self.goal_pursuing && self.goal_set))
    }

    fn has_external_app_server_contract(&self) -> bool {
        self.external.iter().all(|present| *present)
    }

    fn has_local_cli_contract(&self) -> bool {
        self.local.iter().all(|present| *present)
    }

    fn has_headless_remote_control_contract(&self) -> bool {
        self.headless_remote_control.iter().all(|present| *present)
    }

    fn satisfies(&self, required: RequiredMarkerContract) -> bool {
        self.has_common_contract()
            && match required {
                RequiredMarkerContract::Full => {
                    self.has_external_app_server_contract()
                        && self.has_headless_remote_control_contract()
                        && self.has_local_cli_contract()
                }
                #[cfg(test)]
                RequiredMarkerContract::ExternalAppServer => {
                    self.has_external_app_server_contract()
                }
                #[cfg(test)]
                RequiredMarkerContract::HeadlessRemoteControl => {
                    self.has_external_app_server_contract()
                        && self.has_headless_remote_control_contract()
                }
                #[cfg(test)]
                RequiredMarkerContract::LocalCli => self.has_local_cli_contract(),
            }
    }
}

fn update_marker_flags<const N: usize>(flags: &mut [bool; N], markers: &[&[u8]; N], data: &[u8]) {
    for (index, marker) in markers.iter().enumerate() {
        if !flags[index] {
            flags[index] = contains_bytes(data, marker);
        }
    }
}

fn binary_has_marker_contract(path: &Path, required: RequiredMarkerContract) -> bool {
    let Ok(file) = fs::File::open(path) else {
        return false;
    };
    let mut reader = BufReader::with_capacity(BINARY_MARKER_SCAN_CHUNK_BYTES, file);
    let overlap_bytes = maximum_marker_length().saturating_sub(1);
    let mut chunk = vec![0_u8; BINARY_MARKER_SCAN_CHUNK_BYTES];
    let mut overlap = Vec::with_capacity(overlap_bytes);
    let mut scan = Vec::with_capacity(BINARY_MARKER_SCAN_CHUNK_BYTES + overlap_bytes);
    let mut state = BinaryMarkerState::default();

    loop {
        let Ok(count) = reader.read(&mut chunk) else {
            return false;
        };
        if count == 0 {
            break;
        }
        scan.clear();
        scan.extend_from_slice(&overlap);
        scan.extend_from_slice(&chunk[..count]);
        state.update(&scan);
        if state.satisfies(required) {
            return true;
        }

        let keep = overlap_bytes.min(scan.len());
        overlap.clear();
        overlap.extend_from_slice(&scan[scan.len() - keep..]);
    }
    state.satisfies(required)
}

fn maximum_marker_length() -> usize {
    COMMON_HOT_SWAP_MARKERS
        .iter()
        .chain(EXTERNAL_APP_SERVER_HOT_SWAP_MARKERS.iter())
        .chain(HEADLESS_REMOTE_CONTROL_HOT_SWAP_MARKERS.iter())
        .chain(LOCAL_CLI_HOT_SWAP_MARKERS.iter())
        .copied()
        .chain([GOAL_USAGE_MARKER, GOAL_PURSUING_MARKER, GOAL_SET_MARKER])
        .map(<[u8]>::len)
        .max()
        .unwrap_or(1)
}

pub fn codex_version(binary: &Path) -> Option<String> {
    let output = bounded_command::output(
        Command::new(binary).arg("--version"),
        PROBE_COMMAND_TIMEOUT,
        bounded_command::SMALL_OUTPUT_LIMIT,
    )
    .ok()?;
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
    run_codex_build_command(workspace, codex_build_command(), BUILD_COMMAND_TIMEOUT)
        .with_context(|| format!("failed to build Codex at {}", workspace.display()))?;
    let built_binary = workspace.join("target/release/codex");
    let built_code_mode_host = workspace.join("target/release/codex-code-mode-host");
    if !built_code_mode_host.is_file() {
        bail!(
            "Codex build did not produce codex-code-mode-host: {}",
            built_code_mode_host.display()
        );
    }
    if !binary_has_hot_swap_markers(&built_binary) {
        bail!(
            "built Codex binary is missing SIGHUP hot-swap markers: {}",
            built_binary.display()
        );
    }
    Ok(built_binary)
}

fn run_codex_build_command(workspace: &Path, script: &str, timeout: Duration) -> Result<()> {
    let build_status = bounded_command::status_inherited(
        Command::new("bash")
            .arg("-lc")
            .arg(script)
            .current_dir(workspace),
        timeout,
    )?;
    if !build_status.success() {
        bail!("Codex build failed with {build_status}");
    }
    Ok(())
}

fn codex_build_command() -> &'static str {
    ". \"$HOME/.cargo/env\" 2>/dev/null || true; \
     CARGO_BUILD_JOBS=1; \
     CODEXSWITCH_BUILD_NICE=\"${CODEXSWITCH_BUILD_NICE:-10}\"; \
     export CARGO_BUILD_JOBS; \
     build_codex_with_limits() { \
       if command -v ionice >/dev/null 2>&1; then \
         exec ionice -c 3 nice -n \"$CODEXSWITCH_BUILD_NICE\" cargo build --release --jobs \"$CARGO_BUILD_JOBS\" -p codex-cli -p codex-code-mode-host; \
       else \
         exec nice -n \"$CODEXSWITCH_BUILD_NICE\" cargo build --release --jobs \"$CARGO_BUILD_JOBS\" -p codex-cli -p codex-code-mode-host; \
       fi; \
     }; \
     CARGO_TARGET_DIR=\"$PWD/target\" \
     CARGO_PROFILE_RELEASE_LTO=false \
     CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
     build_codex_with_limits"
}

pub(crate) fn build_recipe_fingerprint() -> String {
    ring::digest::digest(&ring::digest::SHA256, codex_build_command().as_bytes())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(crate) fn launcher_script_for_runtime(patched_binary: &Path) -> Result<String> {
    let helper = patched_binary.with_file_name("codex-code-mode-host");
    for path in [patched_binary, helper.as_path()] {
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("failed to inspect launcher provenance {}", path.display()))?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            bail!(
                "launcher provenance must be a regular non-symlink file: {}",
                path.display()
            );
        }
    }
    if !binary_has_hot_swap_markers(patched_binary) {
        bail!(
            "launcher target is missing the complete CodexSwitch hot-swap contract: {}",
            patched_binary.display()
        );
    }
    validate_code_mode_host_for_runtime(patched_binary)?;
    let canonical = fs::canonicalize(patched_binary).with_context(|| {
        format!(
            "failed to resolve launcher runtime provenance {}",
            patched_binary.display()
        )
    })?;
    Ok(launcher_script(
        &canonical.display().to_string(),
        &sha256_file(patched_binary)?,
        &sha256_file(&helper)?,
    ))
}

pub(crate) fn bridge_script_for_managed_launcher(managed_launcher: &Path) -> Result<String> {
    if !managed_launcher.is_absolute() {
        bail!("managed Codex launcher path must be absolute");
    }
    Ok(format!(
        "#!/usr/bin/env bash\nset -euo pipefail\nMANAGED_CODEX={}\nif [[ ! -x \"$MANAGED_CODEX\" || -L \"$MANAGED_CODEX\" ]]; then\n  echo \"codex: managed CodexSwitch launcher is unavailable at $MANAGED_CODEX; run 'codexswitch-cli codex-update-status'\" >&2\n  exit 1\nfi\nexec \"$MANAGED_CODEX\" \"$@\"\n",
        shell_quote(&managed_launcher.display().to_string())
    ))
}

pub fn resolve_installed_runtime(installed_binary: &Path) -> Result<PathBuf> {
    let metadata = fs::symlink_metadata(installed_binary).with_context(|| {
        format!(
            "failed to inspect installed Codex entry {}",
            installed_binary.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!(
            "installed Codex entry must be a regular non-symlink file: {}",
            installed_binary.display()
        );
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(installed_binary)
        .with_context(|| format!("failed to open {}", installed_binary.display()))?;
    let opened = file.metadata()?;
    if opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
        || opened.mode() != metadata.mode()
    {
        bail!("installed Codex entry changed identity while it was opened");
    }
    let mut prefix = [0_u8; 2];
    let prefix_len = file
        .read(&mut prefix)
        .with_context(|| format!("failed to read {}", installed_binary.display()))?;
    if prefix_len != prefix.len() || prefix != *b"#!" {
        return Ok(installed_binary.to_path_buf());
    }

    let mut bytes = prefix.to_vec();
    file.take(LAUNCHER_MAX_BYTES - prefix.len() as u64 + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("failed to read {}", installed_binary.display()))?;
    if bytes.len() as u64 > LAUNCHER_MAX_BYTES {
        bail!("installed Codex launcher exceeded its bounded read limit");
    }
    if !bytes
        .windows(b"PATCHED_CODEX=".len())
        .any(|value| value == b"PATCHED_CODEX=")
    {
        return Ok(installed_binary.to_path_buf());
    }

    let launcher = std::str::from_utf8(&bytes).context("installed Codex launcher is not UTF-8")?;
    let runtime = launcher_assignment(launcher, "PATCHED_CODEX")?;
    let helper = launcher_assignment(launcher, "PATCHED_HELPER")?;
    let expected_runtime_hash = launcher_assignment(launcher, "EXPECTED_CODEX_SHA256")?;
    let expected_helper_hash = launcher_assignment(launcher, "EXPECTED_HELPER_SHA256")?;
    for (label, hash) in [
        ("runtime", expected_runtime_hash.as_str()),
        ("helper", expected_helper_hash.as_str()),
    ] {
        if hash.len() != 64
            || !hash
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            bail!("installed Codex launcher has an invalid pinned {label} SHA-256");
        }
    }

    let runtime = PathBuf::from(runtime);
    let expected_helper = runtime.with_file_name("codex-code-mode-host");
    if Path::new(&helper) != expected_helper {
        bail!("installed Codex launcher helper provenance does not match its runtime");
    }
    let canonical_runtime = fs::canonicalize(&runtime)
        .with_context(|| format!("failed to resolve pinned runtime {}", runtime.display()))?;
    if canonical_runtime != runtime {
        bail!("installed Codex launcher runtime path is not canonical");
    }
    for path in [&runtime, &expected_helper] {
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("failed to inspect pinned runtime file {}", path.display()))?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            bail!(
                "pinned runtime provenance must be a regular non-symlink file: {}",
                path.display()
            );
        }
    }
    if sha256_file(&runtime)? != expected_runtime_hash
        || sha256_file(&expected_helper)? != expected_helper_hash
    {
        bail!("installed Codex launcher pinned runtime hash verification failed");
    }
    if !binary_has_hot_swap_markers(&runtime) {
        bail!("installed Codex launcher target lacks the complete hot-swap contract");
    }
    validate_code_mode_host_for_runtime(&runtime)?;
    Ok(runtime)
}

fn launcher_assignment(launcher: &str, key: &str) -> Result<String> {
    let prefix = format!("{key}='");
    let mut matches = launcher.lines().filter_map(|line| {
        line.trim()
            .strip_prefix(&prefix)
            .and_then(|value| value.strip_suffix('\''))
    });
    let value = matches
        .next()
        .with_context(|| format!("installed Codex launcher omitted {key}"))?;
    if matches.next().is_some() || value.contains('\'') || value.contains('\n') {
        bail!("installed Codex launcher has ambiguous {key} provenance");
    }
    Ok(value.to_string())
}

pub(crate) fn sha256_file(path: &Path) -> Result<String> {
    let file = fs::File::open(path)
        .with_context(|| format!("failed to open launcher provenance file {}", path.display()))?;
    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    loop {
        let count = reader.read(&mut buffer).with_context(|| {
            format!("failed to hash launcher provenance file {}", path.display())
        })?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(digest
        .finish()
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn launcher_script(patched_binary: &str, runtime_sha256: &str, helper_sha256: &str) -> String {
    let quoted = shell_quote(patched_binary);
    let helper = shell_quote(
        &Path::new(patched_binary)
            .with_file_name("codex-code-mode-host")
            .display()
            .to_string(),
    );
    r#"#!/usr/bin/env bash
	set -euo pipefail
	PATCHED_CODEX=__PATCHED_CODEX__
	PATCHED_HELPER=__PATCHED_HELPER__
	EXPECTED_CODEX_SHA256=__EXPECTED_CODEX_SHA256__
	EXPECTED_HELPER_SHA256=__EXPECTED_HELPER_SHA256__
	CODEX_VPS="${CODEXSWITCH_CODEX_VPS:-$HOME/.local/bin/codex-vps}"

	if [[ "${1:-}" == "--remote" ]]; then
	  shift
	  if [[ ! -x "$CODEX_VPS" ]]; then
	    echo "codex: --remote requires the provenance-checked codex-vps synced client: $CODEX_VPS" >&2
	    exit 1
	  fi
	  exec "$CODEX_VPS" --remote-client "$@"
	fi

	if [[ -x "$PATCHED_CODEX" && -x "$PATCHED_HELPER" ]] \
	  && [[ ! -L "$PATCHED_CODEX" && ! -L "$PATCHED_HELPER" ]]; then
	  exec "$PATCHED_CODEX" "$@"
	fi

echo "codex: local runtime failed complete provenance/hot-swap validation at $PATCHED_CODEX; run 'codexswitch-cli codex-update-status' and explicitly prepare/install a verified runtime" >&2
exit 1
"#
    .replace("__PATCHED_CODEX__", &quoted)
    .replace("__PATCHED_HELPER__", &helper)
    .replace("__EXPECTED_CODEX_SHA256__", &shell_quote(runtime_sha256))
    .replace("__EXPECTED_HELPER_SHA256__", &shell_quote(helper_sha256))
}

fn ensure_linux_build_prerequisites() -> Result<()> {
    if !cfg!(target_os = "linux") {
        return Ok(());
    }
    let has_libcap = bounded_command::status(
        Command::new("bash")
            .arg("-lc")
            .arg("pkg-config --exists libcap"),
        PROBE_COMMAND_TIMEOUT,
    )
    .map(|status| status.success())
    .unwrap_or(false);
    if has_libcap {
        return Ok(());
    }

    let status = bounded_command::status_inherited(
        Command::new("bash")
            .arg("-lc")
            .arg("sudo -n apt-get update && sudo -n apt-get install -y pkg-config libcap-dev build-essential"),
        INSTALL_COMMAND_TIMEOUT,
    )
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

#[cfg(test)]
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

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};

    #[test]
    fn marker_scans_distinguish_cli_and_strict_external_app_server_contracts() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let strict = temp.path().join("strict-codex");
        let cli = temp.path().join("cli-codex");
        let full = temp.path().join("full-codex");
        let headless = temp.path().join("headless-codex");
        let common = "sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\ncodexswitch-runtime-convergence-v3\ncodexswitch-runtime-rotation-handoff-v1\nUsage: /goal <objective>\n";
        let strict_markers = "CodexSwitch account/updated frontend write acknowledged after auth reload\ncodexswitch-hotswap-contract-v3\n";
        let headless_markers = "codexswitch-hotswap-headless-idle-v1\n";
        let cli_markers = "codexswitch-hotswap-cli-contract-v3\n";
        fs::write(&strict, format!("{common}{strict_markers}"))?;
        fs::write(
            &headless,
            format!("{common}{strict_markers}{headless_markers}"),
        )?;
        fs::write(&cli, format!("{common}{cli_markers}"))?;
        fs::write(
            &full,
            format!("{common}{strict_markers}{headless_markers}{cli_markers}"),
        )?;

        assert!(binary_has_external_app_server_hot_swap_markers(&strict));
        assert!(!binary_has_local_cli_hot_swap_markers(&strict));
        assert!(!binary_has_hot_swap_markers(&strict));
        assert!(binary_has_headless_remote_control_hot_swap_markers(
            &headless
        ));
        assert!(!binary_has_hot_swap_markers(&headless));
        assert!(binary_has_local_cli_hot_swap_markers(&cli));
        assert!(!binary_has_external_app_server_hot_swap_markers(&cli));
        assert!(!binary_has_hot_swap_markers(&cli));
        assert!(binary_has_hot_swap_markers(&full));
        Ok(())
    }

    #[test]
    fn marker_scan_handles_large_sparse_binaries_without_whole_file_reads() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let binary = temp.path().join("large-codex");
        let markers = b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\ncodexswitch-runtime-convergence-v3\ncodexswitch-runtime-rotation-handoff-v1\nUsage: /goal <objective>\nCodexSwitch account/updated frontend write acknowledged after auth reload\ncodexswitch-hotswap-contract-v3\ncodexswitch-hotswap-headless-idle-v1\ncodexswitch-hotswap-cli-contract-v3\n";
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&binary)?;
        file.set_len(64 * 1024 * 1024)?;
        file.seek(SeekFrom::End(-(markers.len() as i64)))?;
        file.write_all(markers)?;
        drop(file);

        assert!(binary_has_hot_swap_markers(&binary));
        Ok(())
    }

    #[test]
    fn marker_scan_detects_markers_split_across_chunk_boundaries() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let binary = temp.path().join("boundary-codex");
        let markers = b"sighup-verified\nSIGHUP: auth reloaded\nhotswap-ack\nCodexSwitch rotated accounts after a usage limit\nCodexSwitch rotated accounts after an auth failure\nAuth changed, opening new WebSocket with fresh credentials\ncodexswitch-runtime-convergence-v3\ncodexswitch-runtime-rotation-handoff-v1\nUsage: /goal <objective>\ncodexswitch-hotswap-cli-contract-v3\n";
        let mut contents = vec![0_u8; BINARY_MARKER_SCAN_CHUNK_BYTES - 5];
        contents.extend_from_slice(markers);
        fs::write(&binary, contents)?;

        assert!(binary_has_local_cli_hot_swap_markers(&binary));
        Ok(())
    }

    #[test]
    fn launcher_routes_local_sessions_only_to_the_pinned_runtime() {
        let script = launcher_script(
            "/home/signul/.local/share/codexswitch/patched-codex/codex",
            "runtime-sha256",
            "helper-sha256",
        );

        assert!(script
            .contains("PATCHED_CODEX='/home/signul/.local/share/codexswitch/patched-codex/codex'"));
        assert!(script.contains("exec \"$PATCHED_CODEX\" \"$@\""));
        assert!(script.contains("EXPECTED_CODEX_SHA256='runtime-sha256'"));
        assert!(script.contains("EXPECTED_HELPER_SHA256='helper-sha256'"));
        assert!(script.contains("codex-update-status"));
        assert!(!script.contains("sha256_file()"));
        assert!(!script.contains("codex_version_base()"));
        assert!(!script.contains("version_at_least_0128"));
        assert!(!script.contains("--version"));
        assert!(!script.contains("strings \"$candidate\""));
        assert!(!script.contains("has_patch()"));
        assert!(!script.contains("has_goal_support()"));
        assert!(!script.contains("/usr/lib/node_modules/@openai/codex/bin/codex.js"));
        assert!(!script.contains("remote-client/.../codex"));
    }

    #[cfg(unix)]
    #[test]
    fn launcher_executes_one_prevalidated_runtime_and_status_detects_drift() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let runtime = temp.path().join("runtime/codex");
        let helper = temp.path().join("runtime/codex-code-mode-host");
        let launcher = temp.path().join("bin/codex");
        let trace = temp.path().join("trace");
        fs::create_dir_all(runtime.parent().unwrap())?;
        fs::create_dir_all(launcher.parent().unwrap())?;
        fs::write(
            &runtime,
            "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-headless-idle-v1 codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective>\nif [ \"${1:-}\" = --version ]; then echo 'codex-cli 0.144.1'; exit 0; fi\nprintf 'local:%s\\n' \"$*\" >> \"$TRACE\"\n",
        )?;
        fs::write(&helper, "#!/bin/sh\nexit 0\n")?;
        set_executable(&runtime)?;
        set_executable(&helper)?;
        fs::write(&launcher, launcher_script_for_runtime(&runtime)?)?;
        set_executable(&launcher)?;
        assert_eq!(
            resolve_installed_runtime(&launcher)?,
            fs::canonicalize(&runtime)?
        );

        let first = Command::new(&launcher)
            .arg("local-session")
            .env("TRACE", &trace)
            .output()?;
        assert!(first.status.success());
        assert_eq!(fs::read_to_string(&trace)?, "local:local-session\n");

        fs::write(
            &runtime,
            "#!/bin/sh\nif [ \"${1:-}\" = --version ]; then echo 'codex-cli 0.144.1'; exit 0; fi\nprintf 'unverified:%s\\n' \"$*\" >> \"$TRACE\"\n",
        )?;
        set_executable(&runtime)?;
        assert!(resolve_installed_runtime(&launcher).is_err());
        assert_eq!(fs::read_to_string(&trace)?, "local:local-session\n");
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn bridge_executes_only_the_managed_launcher() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let managed = temp.path().join("managed/codex");
        let bridge = temp.path().join("bin/codex");
        let trace = temp.path().join("trace");
        fs::create_dir_all(managed.parent().unwrap())?;
        fs::create_dir_all(bridge.parent().unwrap())?;
        fs::write(&managed, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$TRACE\"\n")?;
        set_executable(&managed)?;
        fs::write(&bridge, bridge_script_for_managed_launcher(&managed)?)?;
        set_executable(&bridge)?;

        let result = Command::new(&bridge)
            .args(["resume", "thread-1"])
            .env("TRACE", &trace)
            .output()?;

        assert!(result.status.success());
        assert_eq!(fs::read_to_string(trace)?, "resume thread-1\n");
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn launcher_remote_mode_uses_only_the_synced_remote_client_entrypoint() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let launcher = temp.path().join("codex");
        let remote = temp.path().join("codex-vps");
        let trace = temp.path().join("trace");
        fs::write(
            &launcher,
            launcher_script("/missing/local/codex", "missing", "missing"),
        )?;
        fs::write(&remote, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$TRACE\"\n")?;
        set_executable(&launcher)?;
        set_executable(&remote)?;

        let result = Command::new(&launcher)
            .args(["--remote", "resume", "thread-1"])
            .env("CODEXSWITCH_CODEX_VPS", &remote)
            .env("TRACE", &trace)
            .output()?;

        assert!(result.status.success());
        assert_eq!(
            fs::read_to_string(trace)?,
            "--remote-client resume thread-1\n"
        );
        Ok(())
    }

    #[test]
    fn legacy_fallback_launcher_is_rejected_without_executing_it() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let launcher = temp.path().join("codex");
        let trace = temp.path().join("must-not-exist");
        fs::write(
            &launcher,
            format!(
                "#!/bin/sh\nPATCHED_CODEX='/missing/incomplete-runtime'\nprintf executed > '{}'\nexec /missing/synced-remote-client\n",
                trace.display()
            ),
        )?;
        set_executable(&launcher)?;

        let error = resolve_installed_runtime(&launcher)
            .expect_err("legacy fallback launchers must not be accepted as local provenance");

        assert!(error.to_string().contains("omitted PATCHED_HELPER"));
        assert!(!trace.exists());
        Ok(())
    }

    #[test]
    fn native_binary_resolution_does_not_apply_the_launcher_size_limit() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let binary = temp.path().join("codex");
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&binary)?;
        file.write_all(b"\x7fELF")?;
        file.set_len(LAUNCHER_MAX_BYTES + 1)?;
        drop(file);

        assert_eq!(resolve_installed_runtime(&binary)?, binary);
        Ok(())
    }

    #[test]
    fn direct_install_command_is_hard_disabled_without_writing_files() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let installed_binary = temp.path().join("patched-codex/codex");
        let user_launcher = temp.path().join("bin/codex");
        let command_error = install(InstallPatchedCodexOptions {
            source: temp.path().join("source"),
            yes: true,
            replace_system_entry: true,
            replace_npm_vendor: true,
        })
        .expect_err("legacy public install command must stay disabled");
        assert!(command_error.to_string().contains("guarded journaled"));
        assert!(!installed_binary.exists());
        assert!(!user_launcher.exists());
        Ok(())
    }

    #[test]
    fn codex_build_command_is_single_job_bounded_and_timeout_owns_the_writer() {
        let command = codex_build_command();

        assert_eq!(BUILD_COMMAND_TIMEOUT, Duration::from_secs(3 * 60 * 60));
        assert!(command.contains("CARGO_BUILD_JOBS=1"));
        assert!(!command.contains("CARGO_BUILD_JOBS:-"));
        assert!(command.contains("CODEXSWITCH_BUILD_NICE=\"${CODEXSWITCH_BUILD_NICE:-10}\""));
        assert!(command.contains("export CARGO_BUILD_JOBS"));
        assert!(command.contains("CARGO_TARGET_DIR=\"$PWD/target\""));
        assert!(command.contains("cargo build --release --jobs \"$CARGO_BUILD_JOBS\""));
        assert!(command.contains("-p codex-cli"));
        assert!(command.contains("-p codex-code-mode-host"));
        assert!(command.contains("exec ionice -c 3 nice -n \"$CODEXSWITCH_BUILD_NICE\""));
        assert!(command.contains("exec nice -n \"$CODEXSWITCH_BUILD_NICE\""));
        assert_eq!(build_recipe_fingerprint().len(), 64);
    }

    #[test]
    fn timed_out_build_reaps_descendant_writer_before_retry_starts() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let marker = temp.path().join("writer");
        let first_writer = format!(
            "(sleep 0.25; printf old > {}) & wait",
            shell_quote(&marker.display().to_string())
        );

        let error = run_codex_build_command(temp.path(), &first_writer, Duration::from_millis(50))
            .expect_err("the first writer must hit its bounded deadline");
        assert!(format!("{error:#}").contains("deadline"));

        run_codex_build_command(
            temp.path(),
            &format!(
                "printf new > {}",
                shell_quote(&marker.display().to_string())
            ),
            Duration::from_secs(1),
        )?;
        std::thread::sleep(Duration::from_millis(350));
        assert_eq!(fs::read(&marker)?, b"new");
        Ok(())
    }
}

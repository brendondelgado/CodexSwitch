#!/usr/bin/env python3
"""Compile and execute critical behavior from the generated upstream turn source."""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
TURN_TEMPLATE = (
    ROOT
    / "crates"
    / "codexswitch-cli"
    / "src"
    / "codex_update"
    / "source_turn_template.rs"
)
TURN_CONTROL = TURN_TEMPLATE.with_name("source_turn_control.rs")
TEMPLATE_PREFIX = 'const INTERRUPTED_TURN_TEMPLATE: &str = r#"'
TEMPLATE_SUFFIX = '\n"#;'
CONTROL_PLACEHOLDER = "/* CODEXSWITCH_CONTROL_SOURCE */"
ROTATION_START = "#[cfg(unix)]\nasync fn codexswitch_rotate_after_failure("
ROTATION_END = "\n#[cfg(unix)]\nasync fn codexswitch_rotate_after_usage_limit("


PRELUDE = r'''
#![allow(dead_code)]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

macro_rules! warn {
    ($($argument:tt)*) => {{
        eprintln!($($argument)*);
    }};
}

mod libc {
    pub const O_NOFOLLOW: i32 = 0x20000;
    pub const O_CLOEXEC: i32 = 0x80000;

    unsafe extern "C" {
        #[link_name = "geteuid"]
        fn system_geteuid() -> u32;
    }

    pub unsafe fn geteuid() -> u32 {
        unsafe { system_geteuid() }
    }
}

mod sha2 {
    use std::fmt;
    use std::io::Write;
    use std::process::{Command, Stdio};

    pub trait Digest: Sized {
        fn new() -> Self;
        fn update(&mut self, bytes: &[u8]);
        fn finalize(self) -> DigestBytes;
    }

    pub struct Sha256 {
        bytes: Vec<u8>,
    }

    pub struct DigestBytes([u8; 32]);

    impl fmt::LowerHex for DigestBytes {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            for byte in self.0 {
                write!(formatter, "{byte:02x}")?;
            }
            Ok(())
        }
    }

    impl Digest for Sha256 {
        fn new() -> Self {
            Self { bytes: Vec::new() }
        }

        fn update(&mut self, bytes: &[u8]) {
            self.bytes.extend_from_slice(bytes);
        }

        fn finalize(self) -> DigestBytes {
            let mut child = Command::new("sha256sum")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .expect("sha256sum must be available on the Linux runner");
            {
                let mut stdin = child.stdin.take().expect("sha256sum stdin");
                stdin.write_all(&self.bytes).expect("write sha256sum input");
            }
            let output = child.wait_with_output().expect("wait for sha256sum");
            assert!(output.status.success(), "sha256sum failed");
            let text = std::str::from_utf8(&output.stdout).expect("sha256sum UTF-8");
            let hex = text.get(..64).expect("sha256sum digest");
            let mut bytes = [0_u8; 32];
            for (index, output_byte) in bytes.iter_mut().enumerate() {
                *output_byte = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16)
                    .expect("sha256sum hex");
            }
            DigestBytes(bytes)
        }
    }
}

mod tokio {
    pub mod process {
        #[derive(Debug)]
        pub struct Command {
            pub program: std::path::PathBuf,
            pub arguments: Vec<std::ffi::OsString>,
        }

        impl Command {
            pub fn new(program: impl AsRef<std::ffi::OsStr>) -> Self {
                Self {
                    program: std::path::PathBuf::from(program.as_ref()),
                    arguments: Vec::new(),
                }
            }

            pub fn arg(&mut self, argument: impl AsRef<std::ffi::OsStr>) -> &mut Self {
                self.arguments.push(argument.as_ref().to_os_string());
                self
            }
        }
    }
}

const OLD_FINGERPRINT: &str =
    "1111111111111111111111111111111111111111111111111111111111111111";
const NEW_FINGERPRINT: &str =
    "2222222222222222222222222222222222222222222222222222222222222222";
const OLD_ACCOUNT: &str = "old-account";
const NEW_ACCOUNT: &str = "new-account";
const RECEIPT_NONCE: &str = "37f84870-9b39-45ae-aee9-3e0a63e1f989";
const REQUEST_NONCE: &str = "1a7c3ffb-bfd8-4719-9b45-c2e350469d9c";

#[derive(Clone)]
struct AuthState {
    fingerprint: String,
    provider_account_id: String,
    generation: u64,
}

struct AuthManager {
    state: Mutex<AuthState>,
    reload_count: AtomicUsize,
}

impl AuthManager {
    fn new() -> Self {
        Self {
            state: Mutex::new(AuthState {
                fingerprint: OLD_FINGERPRINT.to_string(),
                provider_account_id: OLD_ACCOUNT.to_string(),
                generation: 11,
            }),
            reload_count: AtomicUsize::new(0),
        }
    }

    fn auth_generation(&self) -> u64 {
        self.state.lock().expect("auth state").generation
    }

    fn codexswitch_auth_fingerprint(&self) -> Option<String> {
        Some(self.state.lock().expect("auth state").fingerprint.clone())
    }

    fn codexswitch_provider_account_id(&self) -> Option<String> {
        Some(
            self.state
                .lock()
                .expect("auth state")
                .provider_account_id
                .clone(),
        )
    }

    fn codexswitch_auth_file_identity(
        &self,
        path: &std::path::Path,
    ) -> Result<(String, String), ()> {
        assert_eq!(Some(path), AUTH_PATH.get().map(std::path::PathBuf::as_path));
        let state = self.state.lock().expect("auth state");
        Ok((state.fingerprint.clone(), state.provider_account_id.clone()))
    }

    async fn codexswitch_reload_auth_json_verified(
        &self,
        path: &std::path::Path,
    ) -> Result<(bool, String, String), ()> {
        assert_eq!(Some(path), AUTH_PATH.get().map(std::path::PathBuf::as_path));
        self.reload_count.fetch_add(1, Ordering::SeqCst);
        let state = self.state.lock().expect("auth state");
        Ok((
            false,
            state.fingerprint.clone(),
            state.fingerprint.clone(),
        ))
    }
}

struct TurnContext {
    auth_manager: Option<Arc<AuthManager>>,
}

struct Session;

struct WarningEvent {
    message: String,
}

enum EventMsg {
    Warning(WarningEvent),
}

static AUTH_PATH: OnceLock<std::path::PathBuf> = OnceLock::new();
static AUTH_MANAGER: OnceLock<Arc<AuthManager>> = OnceLock::new();
static EVENT_COUNT: AtomicUsize = AtomicUsize::new(0);

impl Session {
    async fn send_event(&self, _turn_context: &TurnContext, event: EventMsg) {
        let EventMsg::Warning(warning) = event;
        assert_eq!(warning.message, "already converged");
        EVENT_COUNT.fetch_add(1, Ordering::SeqCst);
    }
}

fn codexswitch_bound_auth_path_v3() -> Option<(std::path::PathBuf, String, String)> {
    Some((
        AUTH_PATH.get()?.clone(),
        OLD_FINGERPRINT.to_string(),
        OLD_ACCOUNT.to_string(),
    ))
}

fn codexswitch_bound_auth_path_for_external_change_v3(
) -> Option<(std::path::PathBuf, String, String)> {
    codexswitch_bound_auth_path_v3()
}

fn codexswitch_new_receipt_nonce() -> Option<String> {
    Some(RECEIPT_NONCE.to_string())
}

fn codexswitch_now_milliseconds() -> Option<u64> {
    Some(1_000)
}

struct CodexSwitchOwnHandoff {
    fingerprint: String,
    provider_account_id: String,
    request_nonce: String,
    auth_generation: u64,
}

fn codexswitch_verified_own_handoff_v3(
    expected_auth_path: Option<&std::path::Path>,
    expected_receipt_nonce: Option<&str>,
    expected_fingerprint: Option<&str>,
    issued_not_before: Option<u64>,
    allow_auth_file_identity_drift: bool,
) -> Option<CodexSwitchOwnHandoff> {
    assert_eq!(expected_auth_path, AUTH_PATH.get().map(std::path::PathBuf::as_path));
    assert_eq!(expected_receipt_nonce, Some(RECEIPT_NONCE));
    assert_eq!(expected_fingerprint, Some(NEW_FINGERPRINT));
    assert_eq!(issued_not_before, Some(1_000));
    assert!(!allow_auth_file_identity_drift);
    Some(CodexSwitchOwnHandoff {
        fingerprint: NEW_FINGERPRINT.to_string(),
        provider_account_id: NEW_ACCOUNT.to_string(),
        request_nonce: format!("{RECEIPT_NONCE}:{REQUEST_NONCE}"),
        auth_generation: 12,
    })
}

struct CodexSwitchRotationProof {
    fingerprint: String,
    acknowledged_request_nonces: Vec<String>,
}

fn codexswitch_verified_rotation_result(
    output: &std::process::Output,
    auth_path: &std::path::Path,
    receipt_nonce: &str,
) -> Option<CodexSwitchRotationProof> {
    assert!(output.status.success());
    assert_eq!(Some(auth_path), AUTH_PATH.get().map(std::path::PathBuf::as_path));
    assert_eq!(receipt_nonce, RECEIPT_NONCE);
    Some(CodexSwitchRotationProof {
        fingerprint: NEW_FINGERPRINT.to_string(),
        acknowledged_request_nonces: vec![format!("{RECEIPT_NONCE}:{REQUEST_NONCE}")],
    })
}

async fn codexswitch_run_bounded_rotation(
    command: tokio::process::Command,
    control_cli: &CodexSwitchControlCli,
) -> Option<std::process::Output> {
    use std::os::unix::process::ExitStatusExt;

    assert!(control_cli.is_still_current());
    assert!(command.program.starts_with("/proc/self/fd/"));
    let arguments = command
        .arguments
        .iter()
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    let expected_arguments = vec![
        "--auth",
        AUTH_PATH.get().expect("auth path").to_str().expect("auth UTF-8"),
        "rotate-now",
        "--receipt-nonce",
        RECEIPT_NONCE,
        "--reason",
        "usage_limit",
        "--cooldown-seconds",
        "18000",
        "--json",
    ]
    .into_iter()
    .map(str::to_string)
    .collect::<Vec<_>>();
    assert_eq!(
        arguments,
        expected_arguments,
    );

    let manager = AUTH_MANAGER.get().expect("auth manager");
    *manager.state.lock().expect("auth state") = AuthState {
        fingerprint: NEW_FINGERPRINT.to_string(),
        provider_account_id: NEW_ACCOUNT.to_string(),
        generation: 12,
    };
    Some(std::process::Output {
        status: std::process::ExitStatus::from_raw(0),
        stdout: b"{}".to_vec(),
        stderr: Vec::new(),
    })
}
'''


POSTLUDE = r'''
fn harness_sha256(bytes: &[u8]) -> String {
    use sha2::Digest;
    let mut digest = sha2::Sha256::new();
    digest.update(bytes);
    format!("{:x}", digest.finalize())
}

struct ManagedFixture {
    root: std::path::PathBuf,
    home: std::path::PathBuf,
    release_dir: std::path::PathBuf,
    cli: std::path::PathBuf,
    manifest: std::path::PathBuf,
    current: std::path::PathBuf,
    cli_sha256: String,
}

impl ManagedFixture {
    fn new() -> Self {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "codexswitch-generated-runtime-contract-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir(&root).expect("create fixture root");
        let root = std::fs::canonicalize(root).expect("canonical fixture root");
        let home = root.join("home");
        let local = home.join(".local");
        let bin = local.join("bin");
        let share = local.join("share");
        let install_root = share.join("codexswitch");
        let releases = install_root.join("releases");
        let release_id = format!("0.1.0-{}", "a".repeat(40));
        let release_dir = releases.join(&release_id);
        std::fs::create_dir_all(&release_dir).expect("create managed release");
        for directory in [&home, &local, &bin, &share, &install_root, &releases] {
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755))
                .expect("secure managed directory");
        }

        let cli = release_dir.join("codexswitch-cli");
        let cli_bytes = b"deterministic generated control executable\n";
        std::fs::write(&cli, cli_bytes).expect("write control executable");
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o555))
            .expect("make control executable immutable");
        let cli_sha256 = harness_sha256(cli_bytes);
        let hash = "3".repeat(64);
        let manifest = release_dir.join("release-manifest.tsv");
        let manifest_contents = format!(
            "format\tcodexswitch-release-v3\n\
             release_id\t{release_id}\n\
             git_sha\t{}\n\
             package_version\t0.1.0\n\
             build_epoch\t1783915200\n\
             cli_version\tcodexswitch-cli 0.1.0\n\
             cli_sha256\t{cli_sha256}\n\
             codex_source_sha\t{}\n\
             upstream_codex_git_sha\t{}\n\
             source_patch_sha256\t{hash}\n\
             sourcePatchSha256\t{hash}\n\
             artifact_manifest_sha256\t{hash}\n\
             artifact_total_bytes\t4096\n\
             codex_version\t0.144.6\n\
             codex_sha256\t{hash}\n\
             codex_code_mode_host_sha256\t{hash}\n\
             codex_marker_contract\tcodexswitch-hotswap-full-v3\n\
             systemd_payload\tcodexswitch.service\n\
             codexswitch_unit_sha256\t{hash}\n\
             codexswitch_dropin_sha256\t{hash}\n\
             app_server_unit_sha256\t{hash}\n\
             app_server_dropin_sha256\t{hash}\n",
            "b".repeat(40),
            "c".repeat(40),
            "c".repeat(40),
        );
        std::fs::write(&manifest, manifest_contents).expect("write release manifest");
        std::fs::set_permissions(&manifest, std::fs::Permissions::from_mode(0o444))
            .expect("make manifest immutable");
        std::fs::set_permissions(&release_dir, std::fs::Permissions::from_mode(0o555))
            .expect("make release immutable");

        let current = install_root.join("current");
        symlink(std::path::Path::new("releases").join(&release_id), &current)
            .expect("create current link");
        symlink(current.join("codexswitch-cli"), bin.join("codexswitch-cli"))
            .expect("create public managed link");

        Self {
            root,
            home,
            release_dir,
            cli,
            manifest,
            current,
            cli_sha256,
        }
    }
}

impl Drop for ManagedFixture {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(
            &self.release_dir,
            std::fs::Permissions::from_mode(0o755),
        );
        let _ = std::fs::set_permissions(&self.cli, std::fs::Permissions::from_mode(0o755));
        let _ = std::fs::set_permissions(
            &self.manifest,
            std::fs::Permissions::from_mode(0o644),
        );
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn block_on<F: std::future::Future>(future: F) -> F::Output {
    use std::future::Future;
    use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

    unsafe fn clone(_: *const ()) -> RawWaker {
        raw_waker()
    }
    unsafe fn no_op(_: *const ()) {}
    fn raw_waker() -> RawWaker {
        RawWaker::new(
            std::ptr::null(),
            &RawWakerVTable::new(clone, no_op, no_op, no_op),
        )
    }

    let waker = unsafe { Waker::from_raw(raw_waker()) };
    let mut context = Context::from_waker(&waker);
    let mut future = Box::pin(future);
    loop {
        match Future::poll(future.as_mut(), &mut context) {
            Poll::Ready(output) => return output,
            Poll::Pending => std::thread::yield_now(),
        }
    }
}

fn main() {
    use std::os::unix::fs::symlink;

    let fixture = ManagedFixture::new();
    unsafe { std::env::set_var("HOME", &fixture.home) };
    let owner_uid = unsafe { libc::geteuid() };
    let resolved = codexswitch_resolve_linux_managed_control_cli_at(&fixture.home, owner_uid)
        .expect("the generated production managed-symlink layout must resolve");
    assert_eq!(resolved.canonical_path(), fixture.cli);
    assert_eq!(resolved.expected_sha256, fixture.cli_sha256);
    assert!(resolved.execution_path().is_some());
    assert!(resolved.is_still_current());

    let auth_path = fixture.root.join("auth.json");
    std::fs::write(&auth_path, b"old auth\n").expect("write auth fixture");
    AUTH_PATH.set(auth_path).expect("set auth path once");
    let auth_manager = Arc::new(AuthManager::new());
    AUTH_MANAGER
        .set(Arc::clone(&auth_manager))
        .map_err(|_| ())
        .expect("set auth manager once");
    let turn_context = TurnContext {
        auth_manager: Some(Arc::clone(&auth_manager)),
    };
    let session = Session;
    let converged = block_on(codexswitch_rotate_after_failure(
        &session,
        &turn_context,
        "usage_limit",
        "18000",
        true,
        "already converged",
    ));
    assert!(converged, "generated interrupted-turn rotation must converge");
    assert_eq!(
        auth_manager.reload_count.load(Ordering::SeqCst),
        0,
        "an AuthManager already converged by runtime reload must not be reloaded again",
    );
    assert_eq!(EVENT_COUNT.load(Ordering::SeqCst), 1);

    std::fs::remove_file(&fixture.current).expect("remove current link");
    symlink("releases/replaced-release", &fixture.current).expect("replace current link");
    assert!(
        !resolved.is_still_current(),
        "the generated resolver must bind the original managed symlink identity",
    );

    println!(
        "generated runtime contract passed: managed resolver and already-converged AuthManager"
    );
}
'''


def generated_contract_source():
    source = TURN_TEMPLATE.read_text()
    if source.count(TEMPLATE_PREFIX) != 1:
        raise AssertionError("interrupted-turn template declaration is ambiguous")
    start = source.index(TEMPLATE_PREFIX) + len(TEMPLATE_PREFIX)
    end = source.index(TEMPLATE_SUFFIX, start)
    template = source[start:end]
    control = TURN_CONTROL.read_text().rstrip()
    if template.count(CONTROL_PLACEHOLDER) != 1:
        raise AssertionError("generated control-source placeholder is ambiguous")
    rendered = template.replace(CONTROL_PLACEHOLDER, control)
    if CONTROL_PLACEHOLDER in rendered or rendered.count(control) != 1:
        raise AssertionError("generated control source was not consumed exactly once")

    rotation_start = rendered.index(ROTATION_START)
    rotation_end = rendered.index(ROTATION_END, rotation_start)
    rotation = rendered[rotation_start:rotation_end]
    required_fragments = (
        "codexswitch_control_cli()",
        "codexswitch_auth_handoff_matches(",
        "codexswitch_reload_auth_json_verified(&auth_path)",
    )
    for fragment in required_fragments:
        if fragment not in rotation:
            raise AssertionError(f"generated rotation contract is missing {fragment!r}")
    return PRELUDE + "\n" + control + "\n\n" + rotation + "\n" + POSTLUDE


def run_linux_contract(source):
    rustc = shutil.which("rustc")
    if not rustc:
        raise SystemExit("rustc is required for the generated runtime contract")
    with tempfile.TemporaryDirectory(prefix="codexswitch-generated-runtime-") as temp:
        temp_dir = pathlib.Path(temp)
        source_path = temp_dir / "generated_turn_contract.rs"
        binary_path = temp_dir / "generated-turn-contract"
        source_path.write_text(source)
        compile_result = subprocess.run(
            [
                rustc,
                "--edition=2021",
                "-C",
                "debuginfo=0",
                "-C",
                "opt-level=0",
                "-o",
                str(binary_path),
                str(source_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=120,
        )
        if compile_result.returncode != 0:
            sys.stderr.write(compile_result.stdout)
            sys.stderr.write(compile_result.stderr)
            raise SystemExit("generated upstream turn contract did not compile")
        run_result = subprocess.run(
            [str(binary_path)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=30,
        )
        if run_result.returncode != 0:
            sys.stderr.write(run_result.stdout)
            sys.stderr.write(run_result.stderr)
            raise SystemExit("generated upstream turn contract failed")
        print(run_result.stdout.strip())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-execution",
        action="store_true",
        help="fail unless the generated Rust contract is compiled and run on Linux",
    )
    args = parser.parse_args()
    source = generated_contract_source()
    if sys.platform != "linux":
        if args.require_execution:
            raise SystemExit("generated runtime execution is restricted to Linux")
        print("generated runtime source contract rendered; Linux execution skipped")
        return
    run_linux_contract(source)


if __name__ == "__main__":
    main()

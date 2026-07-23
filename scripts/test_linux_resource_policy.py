#!/usr/bin/env python3
import hashlib
import fcntl
import hmac
import json
import os
import pathlib
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install-linux.sh"
INSTALLER_LIB = ROOT / "scripts" / "lib"
IMPORT_TRANSACTION = INSTALLER_LIB / "install-linux-import-transaction.sh"
SYSTEMD = ROOT / "crates" / "codexswitch-cli" / "systemd"
RUNBOOK = ROOT / "docs" / "runbooks" / "linux-repository-deployment.md"
STORAGE_RUNBOOK = (
    ROOT / "docs" / "runbooks" / "runtime-storage-hardening-deployment.md"
)
RESILIENCE_RUNBOOK = ROOT / "docs" / "runbooks" / "vps-connection-resilience.md"
LINUX_CLI_DOC = ROOT / "docs" / "linux-cli-only.md"
PACKAGE_VERSION = "0.1.0"
CODEX_VERSION = "0.144.1"
CODEX_SOURCE_SHA = "c" * 40

HOT_SWAP_MARKERS = [
    "sighup-verified",
    "SIGHUP: auth reloaded",
    "hotswap-ack",
    "CodexSwitch rotated accounts after a usage limit",
    "CodexSwitch rotated accounts after an auth failure",
    "Auth changed, opening new WebSocket with fresh credentials",
    "codexswitch-runtime-convergence-v3",
    "codexswitch-runtime-rotation-handoff-v1",
    "CodexSwitch account/updated frontend write acknowledged after auth reload",
    "codexswitch-hotswap-contract-v3",
    "codexswitch-hotswap-cli-contract-v3",
    "Usage: /goal <objective>",
]


def installer_source() -> str:
    modules = sorted(INSTALLER_LIB.glob("install-linux-*.sh"))
    observers = sorted(INSTALLER_LIB.glob("observe-managed-*.py"))
    return "\n".join(
        path.read_text() for path in [*modules, *observers, INSTALLER]
    )


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip())
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class LinuxDeploymentContractTests(unittest.TestCase):
    def test_installer_entrypoint_is_thin_and_repository_modular(self):
        entrypoint = INSTALLER.read_text()

        self.assertLessEqual(len(entrypoint.splitlines()), 250)
        for module in sorted(INSTALLER_LIB.glob("install-linux-*.sh")):
            self.assertIn(
                f'source "$INSTALLER_SCRIPT_DIR/lib/{module.name}"', entrypoint
            )
        self.assertGreaterEqual(
            len(list(INSTALLER_LIB.glob("install-linux-*.sh"))), 8
        )

    def test_app_server_uses_immutable_current_runtime(self):
        text = (SYSTEMD / "signul-codex-app-server.service").read_text()

        self.assertIn("WorkingDirectory=/home/signul/SIGNUL", text)
        self.assertIn("Environment=CODEX_HOME=/home/signul/.codex", text)
        self.assertIn(
            "EnvironmentFile=-/home/signul/SIGNUL/.env.vps.pipeline", text
        )
        self.assertIn(
            "ExecStart=/usr/bin/flock --shared --no-fork "
            "%h/.local/share/codexswitch/runtime-start-install.lock "
            "/usr/bin/flock --exclusive --nonblock --no-fork "
            "%h/.codex/app-server-daemon/app-server.pid.lock "
            "%h/.local/share/codexswitch/current/patched-codex/codex "
            "app-server --remote-control --listen ws://127.0.0.1:8390",
            text,
        )
        for directive in (
            "KillSignal=SIGINT",
            "KillMode=mixed",
            "TimeoutStopSec=120",
            "SendSIGKILL=no",
        ):
            self.assertIn(directive, text)

    def test_runtime_and_maintenance_resource_policies_are_complete(self):
        runtime = (
            SYSTEMD
            / "signul-codex-app-server.service.d"
            / "10-runtime-resources.conf"
        ).read_text()
        maintenance = (
            SYSTEMD / "codexswitch.service.d" / "10-maintenance-resources.conf"
        ).read_text()

        for directive in (
            "Nice=0",
            "CPUWeight=10000",
            "IOWeight=10000",
            "IOSchedulingClass=best-effort",
            "IOSchedulingPriority=0",
            "MemoryLow=512M",
            "MemoryHigh=12G",
            "MemoryMax=14G",
            "MemorySwapMax=2G",
            "LimitNOFILE=1048576",
            "Restart=always",
        ):
            self.assertIn(directive, runtime)
        for directive in (
            "Nice=10",
            "CPUWeight=25",
            "IOWeight=25",
            "IOSchedulingClass=idle",
            "MemoryHigh=4G",
            "MemoryMax=6G",
            "MemorySwapMax=2G",
        ):
            self.assertIn(directive, maintenance)

    def test_installer_encodes_stage_activation_and_provenance_contracts(self):
        text = installer_source()

        self.assertIn('ACTIVATE="${CODEXSWITCH_ACTIVATE:-0}"', text)
        self.assertIn("worktree add --detach", text)
        self.assertIn("merge-base --is-ancestor", text)
        self.assertIn('SOURCE_DATE_EPOCH="$BUILD_EPOCH"', text)
        self.assertIn('CODEXSWITCH_BUILD_GIT_SHA="$TARGET_SHA"', text)
        self.assertIn("cargo build --locked --release --jobs 1", text)
        self.assertIn("BUILD_TIMEOUT_SECONDS=600", text)
        self.assertIn("start_new_session=True", text)
        self.assertIn("os.killpg(process_group, signal.SIGKILL)", text)
        self.assertIn('"--kill-whom=all"', text)
        self.assertIn("os.waitpid(-1, os.WNOHANG)", text)
        self.assertIn("class ScopeState(Enum):", text)
        self.assertIn('if active_state == "inactive":', text)
        self.assertIn("scope_state is ScopeState.INACTIVE", text)
        self.assertNotIn("def scope_is_active():", text)
        self.assertIn("codexswitch-build-reaped-v1", text)
        self.assertIn('RELEASE_ID="$PACKAGE_VERSION-$TARGET_SHA"', text)
        self.assertIn("codexswitch-release-v3", text)
        self.assertIn("sourcePatchSha256", text)
        self.assertIn("codexswitch-activation-v4", text)
        self.assertIn('"systemd-run", "--user", "--scope", "--quiet"', text)
        self.assertIn("systemd_payload", text)
        self.assertNotIn('"$systemd_source"/*.service', text)
        self.assertIn("Memory*|ManagedOOM*|OOM*", text)
        self.assertIn("Timeout*|Restart*|StartLimit*", text)
        self.assertIn("Requires*|Wants*|Requisite*", text)
        self.assertIn("OnFailure*|OnSuccess*|Propagates*", text)
        self.assertIn("RequiredBy|RequisiteOf|WantedBy|UpheldBy", text)
        self.assertIn("Alias|Also|DefaultInstance|Sockets|Service|Unit", text)
        self.assertIn('atomic_symlink "$new_target" "$CURRENT_LINK"', text)
        self.assertIn('$CURRENT_LINK/codexswitch-cli', text)
        self.assertIn('PATCHED_CODEX="\\$CURRENT_ROOT/patched-codex/codex"', text)
        self.assertIn("/usr/bin/flock --shared 9", text)
        self.assertIn('exec "\\$PUBLIC_LAUNCHER" "\\$@"', text)
        self.assertIn("codexswitch-current-launcher-v1", text)
        self.assertIn("EXPECTED_MANIFEST_SHA256=", text)
        self.assertIn("EXPECTED_CODEX_IDENTITY=", text)
        self.assertIn('validate_release "$(canonicalize_path "$CURRENT_LINK")"', text)
        self.assertIn("install_public_codex_launcher", text)
        self.assertIn("systemctl --user daemon-reload", text)
        self.assertIn("systemctl --user show", text)
        self.assertIn("codexswitch-activation-lock-v1", text)
        self.assertIn("import --offline-file-only", text)
        self.assertIn("codexswitch-import-state-v3", text)
        self.assertIn('ACCOUNT_STORE_PATH="$SYSTEMD_TRANSACTION_DIR/import-work/accounts.json"', text)
        self.assertIn("import compare-and-swap lost", text)
        self.assertIn("codexswitch-import-owned-v2", text)
        self.assertIn("observe_import_activation_barrier", text)
        self.assertIn(
            "post-start activation record does not identify the prepared Import/FileOnly barrier",
            text,
        )
        self.assertIn('ln -- "$candidate" "$ACTIVATION_LOCK_FILE"', text)
        self.assertIn("fcntl.flock", text)
        self.assertIn("uuid.UUID", text)
        self.assertIn("uuid.RFC_4122", text)
        self.assertNotIn("[1-5][0-9a-f]{3}", text)
        self.assertIn("default.target.wants/codexswitch-knowledge-sync.timer", text)
        self.assertLess(
            text.rfind("run_transaction_actions"),
            text.rfind("commit_activation_transaction"),
        )
        self.assertLess(
            text.rfind("commit_activation_transaction"),
            text.rfind("run_requested_starts"),
        )
        self.assertNotIn("systemctl --user restart", text)
        self.assertNotIn("systemctl --user stop", text)
        self.assertNotIn("systemctl --user daemon-reload || true", text)

    def test_python_observer_treats_exact_managed_argv_on_replaced_inode_as_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            proc_root = root / "proc"
            process = proc_root / "42"
            codex_home = root / "codex-home"
            runtime = root / "runtime" / "codex"
            replacement = root / "runtime" / "replacement-codex"
            process.mkdir(parents=True)
            runtime.parent.mkdir(parents=True)
            codex_home.mkdir()
            runtime.write_bytes(b"reviewed runtime")
            replacement.write_bytes(b"replacement runtime")
            (process / "stat").write_text(
                f"42 (codex) {' '.join(['1'] * 20)}\n"
            )
            (process / "cmdline").write_bytes(
                os.fsencode(runtime) + b"\0app-server\0--listen\0unix://\0"
            )
            (process / "exe").symlink_to(replacement)

            observed = subprocess.run(
                [
                    sys.executable,
                    str(INSTALLER_LIB / "observe-managed-daemon.py"),
                    str(proc_root),
                    str(codex_home),
                    str(runtime),
                    str(codex_home / "app-server-daemon/app-server.pid.lock"),
                    "0",
                    "2",
                    "100",
                    str(1024 * 1024),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

            self.assertEqual(
                observed.stdout.strip(),
                "unknown\tprocess-exact-managed-argv-replaced-inode:42",
            )

    def test_python_daemon_observer_allows_only_explicit_idle_first_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            proc_root = root / "proc"
            codex_home = root / "codex-home"
            runtime = root / "current" / "patched-codex" / "codex"
            reservation = codex_home / "app-server-daemon/app-server.pid.lock"
            proc_root.mkdir()
            codex_home.mkdir()
            command = [
                sys.executable,
                str(INSTALLER_LIB / "observe-managed-daemon.py"),
                str(proc_root),
                str(codex_home),
                str(runtime),
                str(reservation),
                "0",
                "2",
                "100",
                str(1024 * 1024),
            ]

            strict = subprocess.run(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            self.assertEqual(
                strict.stdout.strip(),
                "unknown\truntime-unavailable:FileNotFoundError",
            )

            first_install = subprocess.run(
                [*command, "1"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            self.assertEqual(
                first_install.stdout.strip(),
                "inactive\tabsent-runtime-and-artifacts-inactive",
            )

            process = proc_root / "42"
            process.mkdir()
            (process / "stat").write_text(
                f"42 (codex) {' '.join(['1'] * 20)}\n"
            )
            (process / "cmdline").write_bytes(
                os.fsencode(runtime) + b"\0app-server\0--listen\0unix://\0"
            )
            claimed = subprocess.run(
                [*command, "1"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            self.assertEqual(
                claimed.stdout.strip(),
                "active\texact-process-active",
            )

            (process / "cmdline").write_bytes(
                os.fsencode(runtime)
                + b"\0-c\0feature=true\0app-server\0--remote-control\0"
            )
            drifted = subprocess.run(
                [*command, "1"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            self.assertEqual(
                drifted.stdout.strip(),
                "unknown\tprocess-managed-path-argv-drift:42",
            )

    def test_knowledge_sync_is_omitted_and_cleanup_is_part_of_exact_target(self):
        text = installer_source()

        self.assertEqual(list(SYSTEMD.glob("*knowledge*")), [])
        self.assertNotIn("CODEXSWITCH_REMOVE_OBSOLETE_KNOWLEDGE_SYNC", text)
        self.assertIn("codexswitch-knowledge-sync.service", text)
        self.assertIn("codexswitch-knowledge-sync.timer", text)

    def test_runtime_storage_policy_is_bounded_and_activation_remains_explicit(self):
        text = STORAGE_RUNBOOK.read_text()
        unit = (SYSTEMD / "signul-codex-app-server.service").read_text()

        self.assertNotIn("PAUSED_BY_OPERATOR", text)
        self.assertNotIn("lossless / indefinite", text)
        self.assertIn("14 days / 32 GiB", text)
        self.assertIn("1 GiB / 250,000 rows", text)
        self.assertIn("100,000 files / 3,650 days / 64 GiB", text)
        self.assertIn("active lease", text)
        self.assertIn("fails closed", text)
        self.assertNotIn("local_thread_store_compression", unit)
        self.assertIn("deferred, frozen, unimplemented, and disabled", text)

    def test_linux_setup_uses_only_immutable_full_sha_installer_flow(self):
        text = LINUX_CLI_DOC.read_text()

        self.assertNotIn("cargo build --release -p codexswitch-cli", text)
        self.assertNotIn("install -Dm755 target/release", text)
        self.assertNotIn("curl -fsSL", text)
        self.assertIn("<full-40-character-git-sha>", text)
        self.assertIn("stage-linux-runtime-artifact.sh", text)
        self.assertIn("CODEXSWITCH_DRY_RUN=1 scripts/install-linux.sh", text)
        self.assertIn("CODEXSWITCH_ACTIVATE=1 scripts/install-linux.sh", text)
        self.assertIn("CODEXSWITCH_IMPORT_BUNDLE=", text)
        self.assertIn("CODEXSWITCH_IMPORT_BUNDLE_SHA256=", text)
        self.assertNotIn("codexswitch-cli import <", text)
        self.assertNotIn("codexswitch-cli install-patched-codex", text)

    def test_runbook_has_frontmatter_and_all_review_gates(self):
        text = RUNBOOK.read_text()

        self.assertTrue(text.startswith("---\n"))
        frontmatter = text.split("---\n", 2)[1]
        for key in ("toc:", "cross_dependencies:", "version_control:"):
            self.assertIn(key, frontmatter)
        for heading in (
            "## Build Provenance",
            "## Path And Storage Bounds",
            "## Runtime Artifact",
            "## Stage",
            "## Exact Systemd Payload",
            "## Systemd Conflict Gate",
            "## Activate",
            "## Activation Recovery",
            "## Rollback",
        ):
            self.assertIn(heading, text)
        self.assertIn("Reader-First Quota Migration", text)

    def test_resilience_runbook_matches_immutable_resource_manifest(self):
        text = RESILIENCE_RUNBOOK.read_text()
        frontmatter = text.split("---\n", 2)[1]

        self.assertIn("MemoryMax=6G", text)
        self.assertIn(
            "~/.local/share/codexswitch/current/patched-codex/codex "
            "app-server daemon version",
            text,
        )
        self.assertNotIn("without imposing a hard memory cap", text)
        self.assertNotIn(
            "~/.local/share/codexswitch/patched-codex/codex "
            "app-server daemon version",
            text,
        )
        self.assertIn(
            "crates/codexswitch-cli/systemd/signul-codex-app-server.service",
            frontmatter,
        )
        self.assertIn("docs/runbooks/linux-repository-deployment.md", frontmatter)
        self.assertIn("last_updated: 2026-07-13", frontmatter)

    def test_installer_declares_closed_world_readiness_and_scan_contracts(self):
        installer = installer_source()
        storage = STORAGE_RUNBOOK.read_text()
        resilience = RESILIENCE_RUNBOOK.read_text()
        test_source = pathlib.Path(__file__).read_text()
        fake_mv = test_source.rsplit('self.fake_bin / "mv"', 1)[1].split(
            'self.fake_bin / "sleep"', 1
        )[0]

        for token in (
            "FragmentPath",
            "DropInPaths",
            "BindsTo",
            "Upholds",
            "PropagatesStopTo",
            "MainPID",
            "CODEXSWITCH_RUNTIME_OBSERVATION_TIMEOUT_SECONDS",
            "runtime-start-install.lock",
            "CODEXSWITCH_SCAN_MAX_ENTRIES",
            "CODEXSWITCH_STATE_FILE_MAX_BYTES",
            "codexswitch-systemd-transaction-v2",
        ):
            self.assertIn(token, installer)
        self.assertIn("lowercase canonical", storage)
        self.assertIn("device/inode/type", storage)
        self.assertIn("activation journal remains live", resilience)
        self.assertIn("os.replace(sys.argv[1], sys.argv[2])", fake_mv)
        self.assertNotIn('rm -f -- "$destination"', fake_mv)


class LinuxImportTransactionFixtureTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="codexswitch-linux-import-"
        )
        self.root = pathlib.Path(self.tempdir.name)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.transaction = (
            self.root / "systemd-user" / ".codexswitch-activation.1"
        )
        self.transaction.mkdir(parents=True, mode=0o700)
        self.account_store = self.home / ".codexswitch" / "accounts.json"
        self.auth_path = self.home / ".codex" / "auth.json"
        self.bundle = self.root / "accounts.csbundle"
        self.bundle.write_bytes(b"reviewed import bundle\n")

    def tearDown(self):
        self.tempdir.cleanup()

    def _environment(self, extra=None):
        environment = os.environ.copy()
        environment.update(
            {
                "IMPORT_TEST_TRANSACTION": str(self.transaction),
                "IMPORT_TEST_HOME": str(self.home),
                "IMPORT_TEST_ACCOUNT_STORE": str(self.account_store),
                "IMPORT_TEST_AUTH": str(self.auth_path),
                "IMPORT_TEST_BUNDLE": str(self.bundle),
                "IMPORT_TEST_BUNDLE_SHA256": hashlib.sha256(
                    self.bundle.read_bytes()
                ).hexdigest(),
            }
        )
        if extra:
            environment.update(extra)
        return environment

    def _harness(self, restore=False, import_status=0):
        restore_command = "restore_import_transaction" if restore else ":"
        return textwrap.dedent(
            f"""
            set -euo pipefail
            source {str(IMPORT_TRANSACTION)!r}
            SYSTEMD_TRANSACTION_DIR="$IMPORT_TEST_TRANSACTION"
            HOME_ROOT="$IMPORT_TEST_HOME"
            ACCOUNT_STORE_PATH="$IMPORT_TEST_ACCOUNT_STORE"
            AUTH_PATH="$IMPORT_TEST_AUTH"
            IMPORT_BUNDLE="$IMPORT_TEST_BUNDLE"
            IMPORT_BUNDLE_SHA256="$IMPORT_TEST_BUNDLE_SHA256"
            IMPORT_BUNDLE_STAGED=""
            SCAN_MAX_BYTES=1048576
            STATE_FILE_MAX_BYTES=1048576
            TEST_MODE=1

            snapshot_import_transaction
            printf 'isolated imported accounts\n' > "$ACCOUNT_STORE_PATH"
            printf 'isolated imported auth\n' > "$AUTH_PATH"
            printf '{{"version":3,"state":"file_only","kind":"import"}}\n' \
              > "$SYSTEMD_TRANSACTION_DIR/import-work/accounts.activation.json"
            chmod 0600 \
              "$ACCOUNT_STORE_PATH" \
              "$AUTH_PATH" \
              "$SYSTEMD_TRANSACTION_DIR/import-work/accounts.activation.json"
            import_status={import_status}
            record_import_owned_generation
            {restore_command}
            """
        )

    def _start_harness(self, extra=None, restore=False, import_status=0):
        return subprocess.Popen(
            [
                "/bin/bash",
                "-c",
                self._harness(restore=restore, import_status=import_status),
            ],
            cwd=ROOT,
            env=self._environment(extra),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _wait_for_barrier(self, process, ready_path):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if ready_path.is_file():
                return
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail(
                    "import transaction exited before its test barrier: "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
            time.sleep(0.01)
        process.kill()
        stdout, stderr = process.communicate()
        self.fail(
            "timed out waiting for import transaction barrier: "
            f"stdout={stdout!r} stderr={stderr!r}"
        )

    def test_rollback_restores_a_previously_absent_lock_and_parent_state(self):
        result = subprocess.run(
            ["/bin/bash", "-c", self._harness(restore=True)],
            cwd=ROOT,
            env=self._environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.account_store.exists())
        self.assertFalse(self.auth_path.exists())
        self.assertFalse(self.account_store.with_suffix(".activation.json").exists())
        self.assertFalse(self.account_store.with_suffix(".json.lock").exists())
        self.assertFalse(self.account_store.parent.exists())
        self.assertFalse(self.auth_path.parent.exists())

    def test_failed_isolated_import_never_publishes_partial_output(self):
        self.account_store.parent.mkdir(parents=True)
        self.auth_path.parent.mkdir(parents=True)
        self.account_store.write_text("before accounts\n")
        self.auth_path.write_text("before auth\n")
        self.account_store.chmod(0o600)
        self.auth_path.chmod(0o640)

        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                self._harness(restore=True, import_status=44),
            ],
            cwd=ROOT,
            env=self._environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.account_store.read_text(), "before accounts\n")
        self.assertEqual(self.auth_path.read_text(), "before auth\n")
        self.assertEqual(stat.S_IMODE(self.account_store.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.auth_path.stat().st_mode), 0o640)
        self.assertFalse(self.account_store.with_suffix(".activation.json").exists())
        self.assertFalse(self.account_store.with_suffix(".json.lock").exists())

    def test_precommit_concurrent_writer_is_preserved_without_import_overwrite(self):
        self.account_store.parent.mkdir(parents=True)
        self.auth_path.parent.mkdir(parents=True)
        self.account_store.write_text("before accounts\n")
        self.auth_path.write_text("before auth\n")
        self.account_store.chmod(0o600)
        self.auth_path.chmod(0o600)
        ready = self.root / "before-commit.ready"
        resume = self.root / "before-commit.continue"
        process = self._start_harness(
            {
                "CODEXSWITCH_TEST_IMPORT_BEFORE_COMMIT_READY": str(ready),
                "CODEXSWITCH_TEST_IMPORT_BEFORE_COMMIT_CONTINUE": str(resume),
            }
        )
        self._wait_for_barrier(process, ready)

        lock_path = self.account_store.with_suffix(".json.lock")
        with lock_path.open("r+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            self.account_store.write_text("concurrent writer accounts\n")
            self.auth_path.write_text("concurrent writer auth\n")
            self.account_store.chmod(0o600)
            self.auth_path.chmod(0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        resume.write_text("continue\n")
        stdout, stderr = process.communicate(timeout=10)

        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertIn("later writer preserved", stderr)
        self.assertEqual(self.account_store.read_text(), "concurrent writer accounts\n")
        self.assertEqual(self.auth_path.read_text(), "concurrent writer auth\n")
        self.assertFalse(self.account_store.with_suffix(".activation.json").exists())

    def test_parent_replacement_before_publish_cannot_redirect_canonical_writes(self):
        self.account_store.parent.mkdir(parents=True)
        self.auth_path.parent.mkdir(parents=True)
        self.account_store.write_text("before accounts\n")
        self.auth_path.write_text("before auth\n")
        self.account_store.chmod(0o600)
        self.auth_path.chmod(0o600)
        external = self.root / "external-parent"
        external.mkdir()
        external_store = external / "accounts.json"
        external_activation = external / "accounts.activation.json"
        external_store.write_text("external sentinel\n")
        external_activation.write_text("external activation sentinel\n")
        moved_parent = self.root / "moved-original-parent"
        ready = self.root / "before-publish.ready"
        resume = self.root / "before-publish.continue"
        process = self._start_harness(
            {
                "CODEXSWITCH_TEST_IMPORT_BEFORE_PUBLISH_READY": str(ready),
                "CODEXSWITCH_TEST_IMPORT_BEFORE_PUBLISH_CONTINUE": str(resume),
            }
        )
        self._wait_for_barrier(process, ready)

        self.account_store.parent.rename(moved_parent)
        self.account_store.parent.symlink_to(external, target_is_directory=True)
        resume.write_text("continue\n")
        stdout, stderr = process.communicate(timeout=10)

        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertRegex(stderr, r"linked or special|changed identity")
        self.assertEqual(external_store.read_text(), "external sentinel\n")
        self.assertEqual(
            external_activation.read_text(), "external activation sentinel\n"
        )
        self.assertEqual((moved_parent / "accounts.json").read_text(), "before accounts\n")
        self.assertFalse(
            any("codexswitch-import" in path.name for path in moved_parent.iterdir())
        )


class LinuxInstallerFixtureTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="csi-", dir=str(pathlib.Path("/tmp").resolve())
        )
        self.root = pathlib.Path(self.tempdir.name)
        self.home = self.root / "home"
        self.install_root = self.root / "install"
        self.build_root = self.root / "build"
        self.bin_dir = self.home / ".local" / "bin"
        self.service_dir = self.root / "systemd-user"
        self.runtime_dir = self.root / "runtime-input"
        self.fixture_repo = self.root / "fixture-repo"
        self.fake_bin = self.root / "fake-bin"
        self.tool_log = self.root / "tools.log"
        self.systemd_state_dir = self.root / "systemd-state"
        self.xdg_runtime_dir = self.root / "xdg-runtime"
        self.proc_root = self.root / "proc"
        self.real_git = shutil.which("git")
        self.real_mv = shutil.which("mv")
        if not self.real_git or not self.real_mv:
            self.skipTest("git and mv are required for the local fixture")

        self.home.mkdir()
        self.xdg_runtime_dir.mkdir(mode=0o700)
        self.proc_root.mkdir()
        self._create_fake_tools()
        self.first_sha, self.unapproved_sha = self._create_fixture_repository()
        self._create_runtime(self.runtime_dir)

    def tearDown(self):
        for path in self.root.rglob("*"):
            if path.is_symlink():
                continue
            try:
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
            except (FileNotFoundError, NotImplementedError):
                pass
        self.tempdir.cleanup()

    def _create_fake_tools(self):
        self.fake_bin.mkdir()
        write_executable(
            self.fake_bin / "uname",
            """
            #!/bin/sh
            echo Linux
            """,
        )
        write_executable(
            self.fake_bin / "nice",
            """
            #!/bin/sh
            printf 'nice\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            test "$1" = -n
            shift 2
            exec "$@"
            """,
        )
        write_executable(
            self.fake_bin / "ionice",
            """
            #!/bin/sh
            printf 'ionice\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            test "$1" = -c
            test "$2" = 3
            shift 2
            exec "$@"
            """,
        )
        write_executable(
            self.fake_bin / "flock",
            """
            #!/usr/bin/env python3
            import fcntl
            import sys

            operation = fcntl.LOCK_EX
            nonblocking = False
            descriptor = None

            for argument in sys.argv[1:]:
                if argument in ("--exclusive", "-x"):
                    operation = fcntl.LOCK_EX
                elif argument in ("--shared", "-s"):
                    operation = fcntl.LOCK_SH
                elif argument in ("--unlock", "-u"):
                    operation = fcntl.LOCK_UN
                elif argument in ("--nonblock", "--nonblocking", "-n"):
                    nonblocking = True
                elif argument.isdecimal():
                    descriptor = int(argument)
                else:
                    raise SystemExit(f"unsupported fixture flock argument: {argument}")

            if descriptor is None:
                raise SystemExit("fixture flock requires an inherited descriptor")
            if nonblocking:
                operation |= fcntl.LOCK_NB

            try:
                fcntl.flock(descriptor, operation)
            except BlockingIOError:
                raise SystemExit(1)
            """,
        )
        write_executable(
            self.fake_bin / "cargo",
            f"""
            #!/bin/sh
            set -eu
            printf 'cargo\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            if [ "$1" = metadata ]; then
              printf '%s\n' '{{"packages":[{{"name":"codexswitch-cli","version":"{PACKAGE_VERSION}"}}]}}'
              exit 0
            fi
            if [ "${{FAKE_CARGO_HANG:-0}}" = 1 ]; then
              mkdir -p "$CARGO_TARGET_DIR"
              if [ "${{FAKE_CARGO_ESCAPE_PROCESS_GROUP:-0}}" = 1 ]; then
                python3 - \
                  "$FAKE_CARGO_DESCENDANT_TRACE" \
                  "$CARGO_TARGET_DIR/descendant-write" \
                  "$FAKE_CARGO_DESCENDANT_PID" <<'PY' >/dev/null 2>&1 &
import os
import sys
import time
from pathlib import Path

trace_path, target_path, pid_path = map(Path, sys.argv[1:])
os.setsid()
pid_path.write_text(f"{{os.getpid()}}\\n")
while True:
    for path in (trace_path, target_path):
        with path.open("a", encoding="utf-8") as handle:
            handle.write("x")
    time.sleep(0.05)
PY
                escaped_pid=$!
                attempts=0
                while [ ! -s "$FAKE_CARGO_DESCENDANT_PID" ]; do
                  kill -0 "$escaped_pid"
                  attempts=$((attempts + 1))
                  [ "$attempts" -lt 100 ]
                  /bin/sleep 0.01
                done
                wait "$escaped_pid"
              else
                (
                  trap '' TERM
                  while :; do
                    printf x >> "$FAKE_CARGO_DESCENDANT_TRACE"
                    printf x >> "$CARGO_TARGET_DIR/descendant-write"
                    /bin/sleep 0.05
                  done
                ) &
                printf '%s\n' "$!" > "$FAKE_CARGO_DESCENDANT_PID"
                wait
              fi
            fi
            printf 'build-env\tsha=%s\tpackage=%s\tepoch=%s\ttarget=%s\tjobs=%s\n' \
              "$CODEXSWITCH_BUILD_GIT_SHA" "$CODEXSWITCH_BUILD_PACKAGE_VERSION" \
              "$SOURCE_DATE_EPOCH" "$CARGO_TARGET_DIR" "$CARGO_BUILD_JOBS" \
              >> "$FAKE_TOOL_LOG"
            if [ "${{FAKE_BAD_CLI_VERSION:-0}}" = 1 ]; then
              version='codexswitch-cli 0.0.0 (git unknown-dirty, built unknown)'
            else
              version="codexswitch-cli $CODEXSWITCH_BUILD_PACKAGE_VERSION (git $CODEXSWITCH_BUILD_GIT_SHA, built $SOURCE_DATE_EPOCH)"
            fi
            mkdir -p "$CARGO_TARGET_DIR/release"
            binary="$CARGO_TARGET_DIR/release/codexswitch-cli"
            {{
              printf '#!/bin/sh\n'
              printf "version='%s'\n" "$version"
              cat <<'CLI'
            set -eu
            if [ "${{1:-}}" = --version ]; then
              printf '%s\n' "$version"
              exit 0
            fi
            store="$HOME/.codexswitch/accounts.json"
            auth="$HOME/.codex/auth.json"
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --store) store=$2; shift 2 ;;
                --auth) auth=$2; shift 2 ;;
                *) break ;;
              esac
            done
            command=${{1:-}}
            [ "$#" -eq 0 ] || shift
            case "$command" in
              import)
                offline_file_only=0
                bundle=
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --offline-file-only) offline_file_only=1 ;;
                    *) [ -z "$bundle" ] || exit 64; bundle=$1 ;;
                  esac
                  shift
                done
                [ "$offline_file_only" = 1 ] || exit 65
                printf 'cli\timport --offline-file-only %s\n' "$bundle" >> "$FAKE_TOOL_LOG"
                if [ -n "${{FAKE_REPLACE_ORIGINAL_BUNDLE:-}}" ]; then
                  printf 'replacement bytes\n' > "$FAKE_REPLACE_ORIGINAL_BUNDLE"
                fi
                mkdir -p "$(dirname "$store")" "$(dirname "$auth")"
                lock="${{store%.*}}.json.lock"
                [ -e "$lock" ] || : > "$lock"
                digest=$(python3 - "$lock" "$store" "$auth" "$bundle" <<'PY'
import fcntl
import hashlib
import json
import os
import sys
from pathlib import Path

lock_path, store, auth, bundle = sys.argv[1:]
with open(lock_path, "r+b") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    with open(bundle, "rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    with open(store, "w", encoding="utf-8") as handle:
        handle.write(f"imported:{{bundle}}:{{digest}}\\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(store, 0o600)
    with open(auth, "w", encoding="utf-8") as handle:
        handle.write(f"imported-auth:{{bundle}}:{{digest}}\\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(auth, 0o600)
    record_path = Path(store).with_suffix(".activation.json")
    temporary = record_path.with_name(f".{{record_path.name}}.tmp.{{os.getpid()}}")
    record = {{
        "version": 3,
        "state": "file_only",
        "kind": "import",
        "previousAccountId": "fixture-previous",
        "targetAccountId": f"fixture-target-{{digest[:12]}}",
        "storeGeneration": digest,
        "authFingerprint": digest,
        "detail": "fixture offline import",
        "updatedAt": "2026-01-01T00:00:00Z",
    }}
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, record_path)
    directory = os.open(record_path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    print(digest)
PY
                )
                printf 'cli-import-sha256\t%s\n' "$digest" >> "$FAKE_TOOL_LOG"
                [ "${{FAKE_IMPORT_FAIL:-0}}" != 1 ] || exit 44
                ;;
              doctor)
                [ "${{FAKE_DOCTOR_FAIL:-0}}" != 1 ] || exit 45
                ;;
            esac
            exit 0
CLI
            }} > "$binary"
            chmod 755 "$binary"
            """,
        )
        write_executable(
            self.fake_bin / "systemctl",
            """
            #!/bin/sh
            set -eu
            printf 'systemctl\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            state_dir=$FAKE_SYSTEMD_STATE_DIR
            service_dir=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CODEXSWITCH_SYSTEMD_USER_DIR")
            install_root=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CODEXSWITCH_INSTALL_ROOT")
            runtime_storage_root=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CODEXSWITCH_RUNTIME_STORAGE_ROOT")
            runtime_control_dir=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$XDG_RUNTIME_DIR/systemd/user.control")
            mkdir -p "$state_dir/active"

            property_override() {
              unit=$1
              property=$2
              [ -n "${FAKE_SYSTEMD_SHOW_OVERRIDES:-}" ] || return 1
              awk -F '\t' -v unit="$unit" -v property="$property" \
                '$1 == unit && $2 == property { print $3; found=1; exit } END { if (!found) exit 1 }' \
                "$FAKE_SYSTEMD_SHOW_OVERRIDES"
            }

            should_fail() {
              action=$1
              unit=$2
              [ "${FAKE_SYSTEMD_FAIL_ACTION:-}" = "$action" ] || return 1
              [ -z "${FAKE_SYSTEMD_FAIL_UNIT:-}" ] || [ "$FAKE_SYSTEMD_FAIL_UNIT" = "$unit" ]
            }

            emit_missing_unit_observation() {
              observation=$1
              load_state=not-found
              active_state=$observation
              fragment=
              exec_start=
              main_pid=0
              case "$observation" in
                inactive) ;;
                active|activating|reloading|deactivating) main_pid=4242 ;;
                stale-main-pid) active_state=inactive; main_pid=4242 ;;
                drifted-fragment) active_state=inactive; fragment="$service_dir/drifted.service" ;;
                drifted-exec) active_state=inactive; exec_start='{ path=/bin/false ; argv[]=/bin/false ; }' ;;
                missing-loaded) active_state=inactive; load_state=loaded ;;
                *) active_state=$observation ;;
              esac
              printf 'LoadState=%s\nActiveState=%s\nFragmentPath=%s\nExecStart=%s\nMainPID=%s\n' \
                "$load_state" "$active_state" "$fragment" "$exec_start" "$main_pid"
            }

            if [ "$*" = "--user daemon-reload" ]; then
              [ "${FAKE_DAEMON_RELOAD_FAIL:-0}" != 1 ] || exit 42
              if [ -n "${FAKE_DAEMON_RELOAD_FAIL_AFTER:-}" ]; then
                reload_count_file="$state_dir/daemon-reload-fail-count"
                reload_count=0
                [ ! -f "$reload_count_file" ] || reload_count=$(cat "$reload_count_file")
                reload_count=$((reload_count + 1))
                printf '%s\n' "$reload_count" > "$reload_count_file"
                [ "$reload_count" != "$FAKE_DAEMON_RELOAD_FAIL_AFTER" ] || exit 42
              fi
              if [ "${FAKE_CONCURRENT_MAINTENANCE_START:-0}" = 1 ] && \
                 [ ! -e "$state_dir/concurrent-maintenance-attempted" ]; then
                : > "$state_dir/concurrent-maintenance-attempted"
                barrier="$runtime_control_dir/codexswitch.service.d/00-codexswitch-activation-guard.conf"
                if [ -f "$barrier" ] && [ -e "$install_root/.activation.lock" ]; then
                  printf 'systemd-start-blocked\tcodexswitch.service\n' >> "$FAKE_TOOL_LOG"
                else
                  : > "$state_dir/active/codexswitch.service"
                fi
              fi
              exit 0
            fi
            if [ "$1" = --user ] && [ "$2" = is-active ]; then
              shift 2
              quiet=0
              if [ "${1:-}" = --quiet ]; then
                quiet=1
                shift
              fi
              status=3
              for unit in "$@"; do
                if [ "${FAKE_SYSTEMD_IS_ACTIVE_FAILURE_UNIT:-}" = "$unit" ]; then
                  case "${FAKE_SYSTEMD_IS_ACTIVE_FAILURE_MODE:-error}" in
                    error) printf '%s\n' 'manager query failed' >&2; exit 1 ;;
                    unknown) [ "$quiet" = 1 ] || printf '%s\n' unknown; exit 4 ;;
                    failed) [ "$quiet" = 1 ] || printf '%s\n' failed; exit 3 ;;
                    malformed) [ "$quiet" = 1 ] || printf 'inactive\nextra\n'; exit 3 ;;
                    *) exit 98 ;;
                  esac
                fi
                if [ "${FAKE_FAIL_AFTER_CONCURRENT_BARRIER:-0}" = 1 ] && \
                   [ "$unit" = codexswitch.service ] && \
                   [ -e "$state_dir/concurrent-maintenance-attempted" ]; then
                  [ "$quiet" = 1 ] || printf '%s\n' unknown
                  exit 4
                fi
                if [ -e "$state_dir/active/$unit" ]; then
                  [ "$quiet" = 1 ] || printf '%s\n' active
                  status=0
                  continue
                fi
                case ",${FAKE_ACTIVE_UNITS:-}," in
                  *,"$unit",*) [ "$quiet" = 1 ] || printf '%s\n' active; status=0 ;;
                  *) [ "$quiet" = 1 ] || printf '%s\n' inactive ;;
                esac
              done
              exit "$status"
            fi
            if [ "$1" = --user ] && [ "$2" = enable ]; then
              unit=$3
              wants="$service_dir/default.target.wants"
              mkdir -p "$wants"
              ln -sfn "../$unit" "$wants/$unit"
              should_fail enable "$unit" && exit 43
              exit 0
            fi
            if [ "$1" = --user ] && { [ "$2" = restart ] || [ "$2" = stop ]; }; then
              exit 97
            fi
            if [ "$1" = --user ] && [ "$2" = start ]; then
              unit=$3
              : > "$state_dir/active/$unit"
              should_fail start "$unit" && exit 46
              if [ "$unit" = codexswitch.service ] && \
                 [ -e "$state_dir/active/signul-codex-app-server.service" ]; then
                account_store=${CODEXSWITCH_ACCOUNT_STORE_PATH:-$HOME/.codexswitch/accounts.json}
                python3 - "$account_store" "${FAKE_IMPORT_CONVERGENCE:-confirmed}" <<'PY'
import json
import os
import sys
from pathlib import Path

record_path = Path(sys.argv[1]).with_suffix(".activation.json")
mode = sys.argv[2]
if record_path.is_file() and mode != "pending":
    record = json.loads(record_path.read_text())
    if mode == "mismatch":
        record["targetAccountId"] = record["targetAccountId"] + "-different"
    record["state"] = "confirmed"
    record["detail"] = None
    temporary = record_path.with_name(f".{record_path.name}.tmp.{os.getpid()}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, record_path)
    directory = os.open(record_path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
PY
              fi
              exit 0
            fi
            if [ "$1" = --user ] && [ "$2" = cat ]; then
              unit=$3
              printf '# %s/%s\n' "$service_dir" "$unit"
              cat "$service_dir/$unit"
              dropins="$service_dir/$unit.d"
              if [ -d "$dropins" ]; then
                find "$dropins" -type f -name '*.conf' -print | sort | while IFS= read -r file; do
                  printf '# %s\n' "$file"
                  cat "$file"
                done
              fi
              runtime_dropins="$runtime_control_dir/$unit.d"
              if [ -d "$runtime_dropins" ]; then
                find "$runtime_dropins" -type f -name '*.conf' -print | sort | while IFS= read -r file; do
                  printf '# %s\n' "$file"
                  cat "$file"
                done
              fi
              if [ "${FAKE_SYSTEMD_EXTERNAL_DROPIN_UNIT:-}" = "$unit" ]; then
                printf '# %s\n' "${FAKE_SYSTEMD_EXTERNAL_DROPIN_PATH:-/etc/systemd/user/99-external.conf}"
                [ -z "${FAKE_SYSTEMD_EXTERNAL_DROPIN_LINE:-}" ] || \
                  printf '%s\n' "$FAKE_SYSTEMD_EXTERNAL_DROPIN_LINE"
              fi
              if [ "${FAKE_SYSTEMD_CONFLICT_UNIT:-}" = "$unit" ]; then
                printf '%s\n' "$FAKE_SYSTEMD_CONFLICT_LINE"
              fi
              exit 0
            fi
            if [ "$1" = --user ] && [ "$2" = show ]; then
              unit=$3
              case "$unit" in
                codexswitch-build-*.scope)
                  [ "${4:-}" = "--property=ActiveState" ]
                  [ "${5:-}" = "--value" ]
                  observation=${FAKE_BUILD_SCOPE_OBSERVATION:-inactive}
                  case "$observation" in
                    error) exit 4 ;;
                    timeout)
                      /bin/sleep "${FAKE_BUILD_SCOPE_TIMEOUT_SECONDS:-6}"
                      exit 0
                      ;;
                    malformed) printf '%s\n' 'not-an-active-state' ;;
                    *) printf '%s\n' "$observation" ;;
                  esac
                  exit 0
                  ;;
              esac
              if [ "$unit" = codexswitch.service ] && \
                 [ "${4#--property=}" != "$4" ]; then
                observation=${FAKE_DAEMON_SYSTEMD_OBSERVATION:-inactive}
                case "$observation" in
                  exit4) exit 4 ;;
                  error) exit 1 ;;
                  timeout)
                    /bin/sleep "${FAKE_RUNTIME_SYSTEMD_TIMEOUT_SECONDS:-3}"
                    exit 0
                    ;;
                  malformed)
                    printf '%s\n' 'not-property-output'
                    exit 0
                    ;;
                  stderr)
                    printf '%s\n' 'ambiguous observer warning' >&2
                    observation=inactive
                    ;;
                esac
                active_state=$observation
                main_pid=0
                fragment="$service_dir/codexswitch.service"
                if [ ! -e "$fragment" ]; then
                  emit_missing_unit_observation "$observation"
                  exit 0
                fi
                case "$observation" in
                  inactive|failed) ;;
                  active|activating|reloading|deactivating) main_pid=4242 ;;
                  stale-main-pid) active_state=inactive; main_pid=4242 ;;
                  drifted-fragment) active_state=inactive; fragment="$service_dir/drifted.service" ;;
                  drifted-exec) active_state=inactive ;;
                  *) active_state="$observation" ;;
                esac
                exec_start="{ path=$CODEXSWITCH_BIN_DIR/codexswitch-cli ; argv[]=$CODEXSWITCH_BIN_DIR/codexswitch-cli daemon ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
                if [ "$observation" = drifted-exec ]; then
                  exec_start="{ path=$CODEXSWITCH_BIN_DIR/codexswitch-cli ; argv[]=$CODEXSWITCH_BIN_DIR/codexswitch-cli daemon --spoofed ; ignore_errors=no ; }"
                fi
                printf 'LoadState=loaded\nActiveState=%s\nFragmentPath=%s\nExecStart=%s\nMainPID=%s\n' \
                  "$active_state" "$fragment" "$exec_start" "$main_pid"
                exit 0
              fi
              if [ "$unit" = signul-codex-app-server.service ] && \
                 [ "${4#--property=}" != "$4" ]; then
                observation=${FAKE_RUNTIME_SYSTEMD_OBSERVATION:-inactive}
                case "$observation" in
                  exit4) exit 4 ;;
                  error) exit 1 ;;
                  timeout)
                    /bin/sleep "${FAKE_RUNTIME_SYSTEMD_TIMEOUT_SECONDS:-3}"
                    exit 0
                    ;;
                  malformed)
                    printf '%s\n' 'not-property-output'
                    exit 0
                    ;;
                  stderr)
                    printf '%s\n' 'ambiguous observer warning' >&2
                    observation=inactive
                    ;;
                esac
                active_state=$observation
                main_pid=0
                fragment="$service_dir/signul-codex-app-server.service"
                if [ ! -e "$fragment" ]; then
                  emit_missing_unit_observation "$observation"
                  exit 0
                fi
                case "$observation" in
                  inactive|failed) ;;
                  active|activating|reloading|deactivating) main_pid=4242 ;;
                  stale-main-pid) active_state=inactive; main_pid=4242 ;;
                  drifted-fragment) active_state=inactive; fragment="$service_dir/drifted.service" ;;
                  drifted-exec) active_state=inactive ;;
                  *) active_state="$observation" ;;
                esac
                exec_start="{ path=/usr/bin/flock ; argv[]=/usr/bin/flock --shared --no-fork $install_root/runtime-start-install.lock /usr/bin/flock --exclusive --nonblock --no-fork $runtime_storage_root/app-server-daemon/app-server.pid.lock $install_root/current/patched-codex/codex app-server --remote-control --listen ws://127.0.0.1:8390 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
                if [ "$observation" = drifted-exec ]; then
                  exec_start="{ path=/usr/bin/flock ; argv[]=/usr/bin/flock --shared --no-fork $CODEXSWITCH_INSTALL_ROOT/other.lock $CODEXSWITCH_INSTALL_ROOT/current/patched-codex/codex app-server ; ignore_errors=no ; }"
                fi
                printf 'LoadState=loaded\nActiveState=%s\nFragmentPath=%s\nExecStart=%s\nMainPID=%s\n' \
                  "$active_state" "$fragment" "$exec_start" "$main_pid"
                exit 0
              fi
              property=$5
              if property_override "$unit" "$property"; then
                exit 0
              fi
              if [ "${FAKE_SYSTEMD_SHOW_UNIT:-}" = "$unit" ] && \
                 [ "${FAKE_SYSTEMD_SHOW_PROPERTY:-}" = "$property" ]; then
                printf '%s\n' "$FAKE_SYSTEMD_SHOW_VALUE"
                exit 0
              fi
              case "$unit:$property" in
                codexswitch.service:FragmentPath|signul-codex-app-server.service:FragmentPath)
                  printf '%s/%s\n' "$service_dir" "$unit" ;;
                codexswitch.service:DropInPaths)
                  printf '%s' "$service_dir/codexswitch.service.d/10-maintenance-resources.conf"
                  barrier="$runtime_control_dir/codexswitch.service.d/00-codexswitch-activation-guard.conf"
                  [ ! -f "$barrier" ] || printf ' %s' "$barrier"
                  printf '\n' ;;
                signul-codex-app-server.service:DropInPaths)
                  printf '%s' "$service_dir/signul-codex-app-server.service.d/10-runtime-resources.conf"
                  barrier="$runtime_control_dir/signul-codex-app-server.service.d/00-codexswitch-activation-guard.conf"
                  [ ! -f "$barrier" ] || printf ' %s' "$barrier"
                  printf '\n' ;;
                *:DropInPaths)
                  barrier="$runtime_control_dir/$unit.d/00-codexswitch-activation-guard.conf"
                  [ ! -f "$barrier" ] || printf '%s\n' "$barrier" ;;
                codexswitch.service:Requires|signul-codex-app-server.service:Requires) echo sysinit.target ;;
                codexswitch.service:Conflicts|signul-codex-app-server.service:Conflicts) echo shutdown.target ;;
                codexswitch.service:Before|signul-codex-app-server.service:Before) echo shutdown.target ;;
                codexswitch.service:After) echo 'basic.target sysinit.target' ;;
                signul-codex-app-server.service:Wants) echo network-online.target ;;
                signul-codex-app-server.service:After) echo 'basic.target network-online.target sysinit.target' ;;
                codexswitch.service:MainPID|signul-codex-app-server.service:MainPID) echo 4242 ;;
                *:Wants|*:Requisite|*:BindsTo|*:PartOf|*:Upholds|*:OnFailure|*:OnSuccess|*:PropagatesStopTo|*:StopPropagatedFrom|*:JoinsNamespaceOf|*:RequiredBy|*:RequisiteOf|*:WantedBy|*:BoundBy|*:ConsistsOf|*:UpheldBy|*:ConflictedBy|*:Triggers|*:TriggeredBy|*:PropagatedFrom|*:References|*:ReferencedBy) echo '' ;;
                codexswitch.service:MemoryMax) echo 6442450944 ;;
                codexswitch.service:MemorySwapMax) echo 2147483648 ;;
                signul-codex-app-server.service:MemoryMax) echo 15032385536 ;;
                signul-codex-app-server.service:MemorySwapMax) echo 2147483648 ;;
                *) exit 1 ;;
              esac
              exit 0
            fi
            exit 0
            """,
        )
        write_executable(
            self.fake_bin / "systemd-run",
            """
            #!/bin/sh
            set -eu
            printf 'systemd-run\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --user|--scope|--quiet|--collect|--unit=*) shift ;;
                -p) shift 2 ;;
                --) shift; break ;;
                *) break ;;
              esac
            done
            exec "$@"
            """,
        )
        write_executable(
            self.fake_bin / "mv",
            f"""
            #!/bin/sh
            set -eu
            real_mv={self.real_mv!s}
            case "$1" in
              -T)
                shift
                [ "$1" != -- ] || shift
                source=$1
                destination=$2
                [ ! -e "$destination" ] && [ ! -L "$destination" ] || exit 1
                exec "$real_mv" "$source" "$destination"
                ;;
              -Tf)
                shift
                [ "$1" != -- ] || shift
                source=$1
                destination=$2
                exec python3 - "$source" "$destination" <<'PY'
            import os
            import sys

            os.replace(sys.argv[1], sys.argv[2])
            PY
                ;;
              *) exec "$real_mv" "$@" ;;
            esac
            """,
        )
        write_executable(
            self.fake_bin / "sleep",
            """
            #!/bin/sh
            printf 'sleep\t%s\n' "$*" >> "$FAKE_TOOL_LOG"
            exit 0
            """,
        )

    def _create_runtime(self, runtime_dir: pathlib.Path, markers=None):
        runtime_dir.mkdir(parents=True)
        markers = HOT_SWAP_MARKERS if markers is None else markers
        marker_text = "\n".join(f"# {marker}" for marker in markers)
        write_executable(
            runtime_dir / "codex",
            f"""
            #!/bin/sh
            {marker_text}
            if [ "${{1:-}}" = --version ]; then
              echo 'codex-cli {CODEX_VERSION}'
              exit 0
            fi
            if [ "${{1:-}}" = app-server ] && [ "${{2:-}}" = --help ]; then
              echo 'fixture app-server help'
              exit 0
            fi
            exit 0
            """,
        )
        write_executable(
            runtime_dir / "codex-code-mode-host",
            """
            #!/bin/sh
            exit 0
            """,
        )
        self._refresh_runtime_artifact(runtime_dir, self.first_sha)

    def _refresh_runtime_artifact(self, runtime_dir: pathlib.Path, source_sha: str):
        runtime_dir.chmod(0o700)
        for path in runtime_dir.iterdir():
            if not path.is_symlink():
                path.chmod(0o600)
        build_epoch = self._git(
            "show", "-s", "--format=%ct", source_sha, cwd=self.fixture_repo
        )
        build_version = (
            f"codexswitch-cli {PACKAGE_VERSION} "
            f"(git {source_sha}, built {build_epoch})"
        )
        write_executable(
            runtime_dir / "codexswitch-cli",
            f"""
            #!/bin/sh
            if [ "${{1:-}}" = --version ]; then
              printf '%s\n' '{build_version}'
              exit 0
            fi
            exit 0
            """,
        )
        files = []
        for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
            payload = (runtime_dir / name).read_bytes()
            files.append(
                {
                    "name": name,
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
        manifest = {
            "format": "codexswitch-linux-runtime-artifact-v1",
            "codexSwitchGitSha": source_sha,
            "codexSwitchBuildVersion": build_version,
            "upstreamCodexVersion": CODEX_VERSION,
            "upstreamCodexGitSha": CODEX_SOURCE_SHA,
            "sourcePatchSha256": "d" * 64,
            "targetTriple": "x86_64-unknown-linux-gnu",
            "architecture": "x86_64",
            "buildEpoch": int(build_epoch),
            "files": files,
        }
        (runtime_dir / "manifest.json").write_text(
            json.dumps(manifest, sort_keys=True), encoding="utf-8"
        )
        (runtime_dir / "manifest.json").chmod(0o400)
        for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
            (runtime_dir / name).chmod(0o500)
        runtime_dir.chmod(0o500)

    def _git(self, *args, cwd=None, extra_env=None):
        env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00",
        }
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(
            [self.real_git, *args],
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return result.stdout.strip()

    def _create_fixture_repository(self):
        self.fixture_repo.mkdir()
        (self.fixture_repo / "Cargo.toml").write_text(
            "[workspace]\nresolver = \"2\"\nmembers = []\n"
        )
        (self.fixture_repo / "Cargo.lock").write_text("# fixture lock\n")
        fixture_systemd = (
            self.fixture_repo / "crates" / "codexswitch-cli" / "systemd"
        )
        shutil.copytree(SYSTEMD, fixture_systemd)
        (fixture_systemd / "codexswitch-knowledge-sync.service").write_text(
            "[Service]\nExecStart=/bin/repository-no-op\n"
        )
        self._git("init", cwd=self.fixture_repo)
        self._git("config", "user.email", "fixture@example.test", cwd=self.fixture_repo)
        self._git("config", "user.name", "Fixture", cwd=self.fixture_repo)
        self._git("checkout", "-b", "main", cwd=self.fixture_repo)
        self._git("add", ".", cwd=self.fixture_repo)
        self._git(
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "fixture one",
            cwd=self.fixture_repo,
        )
        first_sha = self._git("rev-parse", "HEAD", cwd=self.fixture_repo)

        self._git("checkout", "-b", "unapproved", cwd=self.fixture_repo)
        (self.fixture_repo / "unapproved.txt").write_text("not on main\n")
        self._git("add", "unapproved.txt", cwd=self.fixture_repo)
        self._git(
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "unapproved commit",
            cwd=self.fixture_repo,
            extra_env={
                "GIT_AUTHOR_DATE": "2026-01-02T00:00:00+00:00",
                "GIT_COMMITTER_DATE": "2026-01-02T00:00:00+00:00",
            },
        )
        unapproved_sha = self._git("rev-parse", "HEAD", cwd=self.fixture_repo)
        self._git("checkout", "main", cwd=self.fixture_repo)
        return first_sha, unapproved_sha

    def _commit_main_release(self, number: int):
        self._git("checkout", "main", cwd=self.fixture_repo)
        marker = self.fixture_repo / "release-sequence.txt"
        marker.write_text(f"release {number}\n")
        self._git("add", "release-sequence.txt", cwd=self.fixture_repo)
        self._git(
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            f"fixture release {number}",
            cwd=self.fixture_repo,
            extra_env={
                "GIT_AUTHOR_DATE": f"2026-01-{number + 2:02d}T00:00:00+00:00",
                "GIT_COMMITTER_DATE": f"2026-01-{number + 2:02d}T00:00:00+00:00",
            },
        )
        return self._git("rev-parse", "HEAD", cwd=self.fixture_repo)

    def _environment(self, sha=None):
        return {
            **os.environ,
            "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.xdg_runtime_dir),
            "PATH": f"{self.fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "FAKE_TOOL_LOG": str(self.tool_log),
            "FAKE_SYSTEMD_STATE_DIR": str(self.systemd_state_dir),
            "FAKE_PROC_ROOT": str(self.proc_root),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "CODEXSWITCH_REPO_URL": str(self.fixture_repo),
            "CODEXSWITCH_GIT_SHA": sha or self.first_sha,
            "CODEXSWITCH_APPROVED_ORIGIN_REF": "refs/remotes/origin/main",
            "CODEXSWITCH_INSTALL_ROOT": str(self.install_root),
            "CODEXSWITCH_SOURCE_DIR": str(self.install_root / "source"),
            "CODEXSWITCH_BUILD_ROOT": str(self.build_root),
            "CODEXSWITCH_BIN_DIR": str(self.bin_dir),
            "CODEXSWITCH_SYSTEMD_USER_DIR": str(self.service_dir),
            "CODEXSWITCH_LINUX_ARTIFACT_DIR": str(self.runtime_dir),
            "CODEXSWITCH_RUNTIME_STORAGE_ROOT": str(self.home / ".codex"),
            "CODEXSWITCH_PROC_ROOT": str(self.proc_root),
            "CODEXSWITCH_CODEX_VERSION": CODEX_VERSION,
            "CODEXSWITCH_CODEX_SOURCE_SHA": CODEX_SOURCE_SHA,
            "CODEXSWITCH_BUILD_MIN_FREE_BYTES": "1",
            "CODEXSWITCH_BUILD_MAX_BYTES": str(128 * 1024 * 1024),
            "CODEXSWITCH_RELEASE_MAX_BYTES": str(16 * 1024 * 1024),
            "CODEXSWITCH_RELEASE_RETENTION_MAX_BYTES": str(64 * 1024 * 1024),
            "CODEXSWITCH_RUNTIME_OBSERVATION_TIMEOUT_SECONDS": "1",
            "CODEXSWITCH_SCAN_MAX_ENTRIES": "10000",
            "CODEXSWITCH_SCAN_MAX_DEPTH": "32",
            "CODEXSWITCH_SCAN_MAX_BYTES": str(128 * 1024 * 1024),
            "CODEXSWITCH_STATE_FILE_MAX_BYTES": str(1024 * 1024),
        }

    def _run_installer(self, env, check=True):
        if env.get("CODEXSWITCH_TEST_MODE") == "1":
            env = {
                **env,
                "CODEXSWITCH_TEST_PROCESS_START_IDENTITY": "123456",
            }
        return subprocess.run(
            [str(INSTALLER)],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def _terminate_fixture_process(self, pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return

        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        self.fail(f"fixture process {pid} survived SIGKILL")

    def _release(self, sha):
        return self.install_root / "releases" / f"{PACKAGE_VERSION}-{sha}"

    def _stage(self, sha=None, extra_env=None, check=True):
        target_sha = sha or self.first_sha
        artifact_override = (extra_env or {}).get("CODEXSWITCH_LINUX_ARTIFACT_DIR")
        if artifact_override is None:
            self._refresh_runtime_artifact(self.runtime_dir, target_sha)
        env = self._environment(sha)
        if extra_env:
            env.update(extra_env)
        return self._run_installer(env, check=check)

    def _activate(self, sha=None, extra_env=None, check=True):
        target_sha = sha or self.first_sha
        artifact_override = (extra_env or {}).get("CODEXSWITCH_LINUX_ARTIFACT_DIR")
        if artifact_override is None:
            self._refresh_runtime_artifact(self.runtime_dir, target_sha)
        env = self._environment(sha)
        env["CODEXSWITCH_ACTIVATE"] = "1"
        if extra_env:
            env.update(extra_env)
        return self._run_installer(env, check=check)

    def _seed_trusted_inactive_runtime(self):
        self._stage()
        current_release = self._release(self.first_sha)
        shutil.copytree(current_release / "systemd", self.service_dir)
        for path in (self.service_dir, *self.service_dir.rglob("*")):
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
        (self.install_root / "current").symlink_to(
            pathlib.Path("releases") / current_release.name
        )
        self.bin_dir.mkdir(parents=True)
        (self.bin_dir / "codexswitch-cli").symlink_to(
            self.install_root / "current" / "codexswitch-cli"
        )
        next_sha = self._commit_main_release(2)
        self._stage(next_sha)
        return next_sha

    def _activation_surface_state(self):
        pointers = {}
        for path in (
            self.install_root / "current",
            self.install_root / "previous",
            self.bin_dir / "codexswitch-cli",
        ):
            pointers[str(path)] = os.readlink(path) if path.is_symlink() else None
        return pointers, self._systemd_artifact_state()

    def _assert_no_runtime_action(self):
        log = self.tool_log.read_text()
        for action in ("start", "stop", "restart"):
            self.assertNotRegex(
                log,
                rf"(?m)^systemctl\t--user {action}(?:\s|$)",
            )

    def _seed_systemd_state(self, include_target_enablement=True):
        if self.service_dir.exists():
            for path in (self.service_dir, *self.service_dir.rglob("*")):
                if not path.is_symlink():
                    path.chmod(path.stat().st_mode | stat.S_IWUSR)
        dropin = self.service_dir / "signul-codex-app-server.service.d"
        dropin.mkdir(parents=True, exist_ok=True)
        for name in ("env.conf", "limits.conf", "oom.conf", "remote-control.conf"):
            (dropin / name).write_text("[Service]\nEnvironment=STALE=1\n")
        (self.service_dir / "codexswitch-knowledge-sync.service").write_text(
            "[Service]\nExecStart=/bin/false\n"
        )
        (self.service_dir / "codexswitch-knowledge-sync.timer").write_text(
            "[Timer]\nOnUnitActiveSec=15\n"
        )
        (self.service_dir / "unrelated-knowledge-sync.timer").write_text(
            "[Timer]\nOnUnitActiveSec=1h\n"
        )
        wants = self.service_dir / "default.target.wants"
        timers = self.service_dir / "timers.target.wants"
        wants.mkdir(exist_ok=True)
        timers.mkdir(exist_ok=True)
        (wants / "codexswitch-knowledge-sync.timer").symlink_to(
            "../codexswitch-knowledge-sync.timer"
        )
        if include_target_enablement:
            (wants / "codexswitch.service").symlink_to("../codexswitch.service")
            (wants / "signul-codex-app-server.service").symlink_to(
                "../signul-codex-app-server.service"
            )
        (timers / "codexswitch-knowledge-sync.timer").symlink_to(
            "../codexswitch-knowledge-sync.timer"
        )

    def _systemd_artifact_state(self):
        if not self.service_dir.exists():
            return {}
        state = {}
        for path in sorted(self.service_dir.rglob("*")):
            relative = str(path.relative_to(self.service_dir))
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                state[relative] = ("symlink", os.readlink(path))
            elif stat.S_ISDIR(mode):
                state[relative] = ("directory", stat.S_IMODE(mode))
            elif stat.S_ISREG(mode):
                state[relative] = (
                    "file",
                    stat.S_IMODE(mode),
                    path.read_bytes(),
                )
            else:
                state[relative] = ("special", stat.S_IFMT(mode))
        return state

    def _manifest(self, release):
        return dict(
            line.split("\t", 1)
            for line in (release / "release-manifest.tsv").read_text().splitlines()
        )

    def _systemd_show_overrides(self, *rows):
        path = self.root / "systemd-show-overrides.tsv"
        path.write_text("".join("\t".join(row) + "\n" for row in rows))
        return path

    def _create_owned_transaction(self, pid: int, payload_size: int, mtime: int):
        transaction = self.service_dir / f".codexswitch-activation.{pid}"
        transaction.mkdir(mode=0o700)
        token = f"{pid:064x}"[-64:]
        generation = hashlib.sha256(f"generation:{pid}".encode()).hexdigest()
        lock_token = hashlib.md5(f"lock:{pid}".encode()).hexdigest()
        metadata = transaction.stat()
        fields = (
            ("format", "codexswitch-systemd-transaction-v2"),
            ("pid", str(pid)),
            ("start", "123456"),
            ("lock_token", lock_token),
            ("token", token),
            ("generation", generation),
            ("directory_dev", str(metadata.st_dev)),
            ("directory_ino", str(metadata.st_ino)),
        )
        key_path = self.install_root / ".transaction-owner.key"
        key = bytes.fromhex(key_path.read_text().strip())
        payload = "".join(f"{key}\t{value}\n" for key, value in fields).encode()
        signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
        (transaction / "owner.tsv").write_text(
            payload.decode() + f"signature\t{signature}\n"
        )
        (transaction / "owner.tsv").chmod(0o600)
        (transaction / "payload.bin").write_bytes(b"x" * payload_size)
        os.utime(transaction, (mtime, mtime))
        return transaction

    def _create_owned_release_stub(self, version: str, sha: str, payload="stub"):
        release = self.install_root / "releases" / f"{version}-{sha}"
        release.mkdir(parents=True)
        (release / "payload.bin").write_text(payload)
        (release / "release-manifest.tsv").write_text(
            "format\tcodexswitch-release-v3\n"
            f"release_id\t{version}-{sha}\n"
        )
        return release

    def test_dry_run_is_non_mutating_and_non_git_source_is_rejected(self):
        env = self._environment()
        env["CODEXSWITCH_DRY_RUN"] = "1"

        result = self._run_installer(env)
        self.assertIn("Stage-only default", result.stdout)
        self.assertFalse(self.install_root.exists())
        self.assertFalse(self.tool_log.exists())

        source = self.install_root / "source"
        source.mkdir(parents=True)
        (source / "owned.txt").write_text("preserve\n")
        result = self._run_installer(env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonempty non-Git directory", result.stderr)
        self.assertEqual((source / "owned.txt").read_text(), "preserve\n")

    def test_source_sha_must_be_reachable_from_approved_origin_ref(self):
        result = self._stage(self.unapproved_sha, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not reachable from approved origin ref", result.stderr)
        self.assertFalse(self._release(self.unapproved_sha).exists())
        self.assertFalse((self.install_root / "current").exists())

    def test_sha_lengths_case_and_build_lock_identity_are_strict(self):
        invalid_shas = (
            "A" * 40,
            "a" * 41,
            "a" * 63,
        )
        for value in invalid_shas:
            with self.subTest(target_sha=value[:8], length=len(value)):
                env = self._environment()
                env["CODEXSWITCH_DRY_RUN"] = "1"
                env["CODEXSWITCH_GIT_SHA"] = value
                result = self._run_installer(env, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("full lowercase 40- or 64-character", result.stderr)

        env = self._environment()
        env["CODEXSWITCH_DRY_RUN"] = "1"
        env["CODEXSWITCH_CODEX_SOURCE_SHA"] = "C" * 40
        result = self._run_installer(env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full lowercase 40-character", result.stderr)

        lock = self.build_root / ".build.lock"
        lock.mkdir(parents=True)
        (lock / "pid").write_text("999999\n")
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build lock owner record is invalid", result.stderr)
        self.assertTrue((lock / "pid").is_file())

    def test_build_root_rejects_nesting_parent_components_and_symlink_aliases(self):
        base_env = self._environment()
        base_env["CODEXSWITCH_DRY_RUN"] = "1"
        cases = {
            "nested": str(self.install_root / "build"),
            "parent": f"{self.root}/scratch/../build-alias",
        }
        for name, build_root in cases.items():
            with self.subTest(name=name):
                env = {**base_env, "CODEXSWITCH_BUILD_ROOT": build_root}
                result = self._run_installer(env, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, "overlaps live path|must not contain")

        self.install_root.mkdir(exist_ok=True)
        alias = self.root / "install-alias"
        alias.symlink_to(self.install_root, target_is_directory=True)
        env = {
            **base_env,
            "CODEXSWITCH_BUILD_ROOT": str(alias / "through-symlink"),
        }
        result = self._run_installer(env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical build root overlaps live path", result.stderr)

    def test_derived_release_and_build_roots_reject_symlink_aliases(self):
        alias_target = self.root / "alias-target"
        alias_target.mkdir()
        self.install_root.mkdir()
        (self.install_root / "releases").symlink_to(alias_target, target_is_directory=True)
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RELEASES_DIR resolves through a symlink or alias", result.stderr)
        (self.install_root / "releases").unlink()

        self.build_root.mkdir()
        for child in ("cargo-target", "worktrees", "stage"):
            with self.subTest(child=child):
                link = self.build_root / child
                link.symlink_to(alias_target, target_is_directory=True)
                result = self._stage(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("resolves through a symlink or alias", result.stderr)
                link.unlink()

        cargo_root = self.build_root / "cargo-target"
        cargo_root.mkdir()
        (cargo_root / "shared").symlink_to(alias_target, target_is_directory=True)
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CARGO_TARGET_DIR resolves through a symlink or alias", result.stderr)
        (cargo_root / "shared").unlink()

        releases = self.install_root / "releases"
        releases.mkdir()
        candidate = releases / f"{PACKAGE_VERSION}-{self.first_sha}"
        candidate.symlink_to(alias_target, target_is_directory=True)
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RELEASE_DIR resolves through a symlink or alias", result.stderr)

    def test_runtime_input_directory_itself_must_not_be_a_symlink(self):
        runtime_link = self.root / "runtime-input-link"
        runtime_link.symlink_to(self.runtime_dir, target_is_directory=True)
        result = self._stage(
            extra_env={"CODEXSWITCH_LINUX_ARTIFACT_DIR": str(runtime_link)},
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Linux artifact must be a regular directory", result.stderr)

    def test_runtime_input_rejects_arbitrary_nested_symlinks_without_touching_targets(self):
        external_file = self.root / "external-runtime-data"
        external_file.write_text("preserve\n")
        external_file.chmod(0o400)
        self.runtime_dir.chmod(0o700)
        nested = self.runtime_dir / "unused" / "nested"
        nested.mkdir(parents=True)
        file_link = nested / "metadata.json"
        file_link.symlink_to(external_file)

        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("artifact must contain exactly", result.stderr)
        self.assertEqual(external_file.read_text(), "preserve\n")
        self.assertEqual(stat.S_IMODE(external_file.stat().st_mode), 0o400)
        self.runtime_dir.chmod(0o700)
        (self.runtime_dir / "unused").chmod(0o700)
        nested.chmod(0o700)
        file_link.unlink()

        external_dir = self.root / "external-runtime-dir"
        external_dir.mkdir()
        (external_dir / "sentinel").write_text("untouched\n")
        directory_link = nested / "cache"
        directory_link.symlink_to(external_dir, target_is_directory=True)

        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("artifact must contain exactly", result.stderr)
        self.assertEqual((external_dir / "sentinel").read_text(), "untouched\n")
        self.runtime_dir.chmod(0o700)
        (self.runtime_dir / "unused").chmod(0o700)
        nested.chmod(0o700)

    def test_runtime_and_archive_bounds_preserve_active_leased_sessions(self):
        runtime_storage = self.home / ".codex"
        sessions = runtime_storage / "sessions"
        archive = runtime_storage / "archived_sessions"
        leases = runtime_storage / ".tmp" / "rollout-leases"
        sessions.mkdir(parents=True)
        archive.mkdir()
        leases.mkdir(parents=True)
        thread_id = "123e4567-e89b-42d3-a456-426614174000"
        active_session = sessions / f"rollout-{thread_id}.jsonl"
        archived = archive / "archived.jsonl.zst"
        active_session.write_bytes(b"active-session")
        archived.write_bytes(b"archived-session")

        base = self._environment()
        base["CODEXSWITCH_DRY_RUN"] = "1"
        base.update(
            {
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_COUNT": "100",
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_AGE_DAYS": "3650",
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES": "1000000",
            }
        )
        cases = (
            ("count", {"CODEXSWITCH_RUNTIME_STORAGE_MAX_COUNT": "1"}, "count="),
            ("bytes", {"CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES": "1"}, "bytes="),
        )
        for name, override, expected in cases:
            with self.subTest(bound=name):
                result = self._run_installer({**base, **override}, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertTrue(active_session.exists())
                self.assertTrue(archived.exists())

        old_time = 1_600_000_000
        os.utime(active_session, (old_time, old_time))
        result = self._run_installer(
            {**base, "CODEXSWITCH_RUNTIME_STORAGE_MAX_AGE_DAYS": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("oldest_age_seconds=", result.stderr)

        lease = leases / f"{thread_id}.lock"
        with lease.open("w") as lease_handle:
            fcntl.flock(lease_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self._run_installer(
                {**base, "CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES": "1"},
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active_leased=1", result.stderr)
        self.assertIn("no files removed", result.stderr)
        self.assertTrue(active_session.exists())

    def test_runtime_lease_identifiers_accept_v4_v7_and_reject_malformed(self):
        runtime_storage = self.home / ".codex"
        sessions = runtime_storage / "sessions"
        leases = runtime_storage / ".tmp" / "rollout-leases"
        sessions.mkdir(parents=True)
        leases.mkdir(parents=True)
        uuid_v4 = "123e4567-e89b-42d3-a456-426614174000"
        uuid_v7 = "0190b2d8-3f00-7a5b-8c1d-123456789abc"
        malformed = "0190b2d8-3f00-7a5b-8c1d-123456789abz"
        uppercase = uuid_v4.upper()
        session_paths = []
        for identifier in (uuid_v4, uuid_v7, malformed):
            session = sessions / f"rollout-{identifier}.jsonl"
            session.write_bytes(identifier.encode("ascii"))
            session_paths.append(session)

        base = self._environment()
        base["CODEXSWITCH_DRY_RUN"] = "1"
        base.update(
            {
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_COUNT": "100",
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_AGE_DAYS": "3650",
                "CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES": "1000000",
            }
        )
        lease_handles = []
        try:
            for identifier in (uuid_v4, uuid_v7):
                handle = (leases / f"{identifier}.lock").open("w")
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                lease_handles.append(handle)
            result = self._run_installer(
                {**base, "CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES": "1"},
                check=False,
            )
        finally:
            for handle in lease_handles:
                handle.close()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active_leased=2", result.stderr)
        self.assertIn("no files removed", result.stderr)
        for session in session_paths:
            self.assertTrue(session.exists())

        malformed_lease = leases / f"{malformed}.lock"
        with malformed_lease.open("w") as lease_handle:
            fcntl.flock(lease_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            malformed_result = self._run_installer(base, check=False)

        self.assertNotEqual(malformed_result.returncode, 0)
        self.assertIn(
            f"invalid runtime lease identifier: {malformed}.lock",
            malformed_result.stderr,
        )
        self.assertTrue(malformed_lease.exists())
        for session in session_paths:
            self.assertTrue(session.exists())
        malformed_lease.unlink()
        for identifier in (uuid_v4, uuid_v7):
            (leases / f"{identifier}.lock").unlink()

        uppercase_lease = leases / f"{uppercase}.lock"
        uppercase_lease.write_text("uppercase must not alias an active lease\n")
        uppercase_result = self._run_installer(base, check=False)
        self.assertNotEqual(uppercase_result.returncode, 0)
        self.assertIn(
            f"invalid runtime lease identifier: {uppercase}.lock",
            uppercase_result.stderr,
        )
        self.assertTrue(uppercase_lease.is_file())

    def test_runtime_lease_identifier_rejects_canonical_non_rfc_variant(self):
        runtime_storage = self.home / ".codex"
        sessions = runtime_storage / "sessions"
        leases = runtime_storage / ".tmp" / "rollout-leases"
        sessions.mkdir(parents=True)
        leases.mkdir(parents=True)
        non_rfc = "0190b2d8-3f00-7a5b-7c1d-123456789abc"
        session = sessions / f"rollout-{non_rfc}.jsonl"
        lease = leases / f"{non_rfc}.lock"
        session.write_text("preserve non-RFC session\n")
        base = self._environment()
        base["CODEXSWITCH_DRY_RUN"] = "1"

        with lease.open("w") as lease_handle:
            fcntl.flock(lease_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self._run_installer(base, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            f"invalid runtime lease identifier: {non_rfc}.lock", result.stderr
        )
        self.assertEqual(session.read_text(), "preserve non-RFC session\n")
        self.assertTrue(lease.is_file())

    def test_runtime_lease_entries_reject_symlink_and_fifo_without_following(self):
        runtime_storage = self.home / ".codex"
        sessions = runtime_storage / "sessions"
        leases = runtime_storage / ".tmp" / "rollout-leases"
        sessions.mkdir(parents=True)
        leases.mkdir(parents=True)
        uuid_v4 = "123e4567-e89b-42d3-a456-426614174000"
        uuid_v7 = "0190b2d8-3f00-7a5b-8c1d-123456789abc"
        sessions_by_id = {}
        for identifier in (uuid_v4, uuid_v7):
            session = sessions / f"rollout-{identifier}.jsonl"
            session.write_text(f"preserve {identifier}\n")
            sessions_by_id[identifier] = session
        base = self._environment()
        base["CODEXSWITCH_DRY_RUN"] = "1"

        external = self.root / "external-lease-target"
        external.write_text("external lease target\n")
        external.chmod(0o400)
        symlink_lease = leases / f"{uuid_v4}.lock"
        symlink_lease.symlink_to(external)
        symlink_result = self._run_installer(base, check=False)

        self.assertNotEqual(symlink_result.returncode, 0)
        self.assertIn("runtime lease entry is linked or special", symlink_result.stderr)
        self.assertTrue(symlink_lease.is_symlink())
        self.assertEqual(external.read_text(), "external lease target\n")
        self.assertEqual(stat.S_IMODE(external.stat().st_mode), 0o400)
        self.assertTrue(sessions_by_id[uuid_v4].is_file())
        symlink_lease.unlink()

        fifo_lease = leases / f"{uuid_v7}.lock"
        os.mkfifo(fifo_lease, 0o600)
        fifo_result = self._run_installer(base, check=False)

        self.assertNotEqual(fifo_result.returncode, 0)
        self.assertIn("runtime lease entry is linked or special", fifo_result.stderr)
        self.assertTrue(stat.S_ISFIFO(fifo_lease.lstat().st_mode))
        self.assertTrue(sessions_by_id[uuid_v7].is_file())

    def test_runtime_lease_ancestors_and_inode_replacement_fail_closed(self):
        runtime_storage = self.home / ".codex"
        sessions = runtime_storage / "sessions"
        sessions.mkdir(parents=True)
        identifier = "123e4567-e89b-42d3-a456-426614174000"
        session = sessions / f"rollout-{identifier}.jsonl"
        session.write_text("preserve session\n")
        base = self._environment()
        base["CODEXSWITCH_DRY_RUN"] = "1"

        external_tmp = self.root / "external-tmp"
        external_leases = external_tmp / "rollout-leases"
        external_leases.mkdir(parents=True)
        external_marker = external_tmp / "marker"
        external_marker.write_text("untouched\n")
        (runtime_storage / ".tmp").symlink_to(external_tmp, target_is_directory=True)
        linked_result = self._run_installer(base, check=False)
        self.assertNotEqual(linked_result.returncode, 0)
        self.assertIn("runtime lease ancestor is linked or special", linked_result.stderr)
        self.assertEqual(external_marker.read_text(), "untouched\n")
        (runtime_storage / ".tmp").unlink()

        tmp = runtime_storage / ".tmp"
        tmp.mkdir()
        special_leases = tmp / "rollout-leases"
        os.mkfifo(special_leases, 0o600)
        special_result = self._run_installer(base, check=False)
        self.assertNotEqual(special_result.returncode, 0)
        self.assertIn("runtime lease ancestor is linked or special", special_result.stderr)
        self.assertTrue(stat.S_ISFIFO(special_leases.lstat().st_mode))
        special_leases.unlink()

        special_leases.mkdir()
        lease = special_leases / f"{identifier}.lock"
        lease.write_text("original inode\n")
        replaced_result = self._run_installer(
            {
                **base,
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_LEASE_INODE_REPLACEMENT": str(lease.resolve()),
            },
            check=False,
        )
        self.assertNotEqual(replaced_result.returncode, 0)
        self.assertIn("runtime lease entry changed identity", replaced_result.stderr)
        self.assertEqual(session.read_text(), "preserve session\n")
        self.assertTrue((special_leases / f".{identifier}.lock.replaced").is_file())

    def test_runtime_inventory_scan_overflow_fails_before_materialization(self):
        sessions = self.home / ".codex" / "sessions"
        sessions.mkdir(parents=True)
        for index in range(4):
            (sessions / f"fixture-{index}.jsonl").write_text(f"{index}\n")
        result = self._stage(
            extra_env={"CODEXSWITCH_SCAN_MAX_ENTRIES": "3"}, check=False
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scan entry bound exceeded", result.stderr)
        self.assertEqual(len(list(sessions.iterdir())), 4)
        self.assertFalse(self.install_root.exists())

    def test_nested_release_directories_reject_symlinks_and_traversal(self):
        self._stage()
        release = self._release(self.first_sha)
        release.chmod(0o755)
        runtime = release / "patched-codex"
        runtime.chmod(0o755)
        for path in runtime.rglob("*"):
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
        shutil.rmtree(runtime)
        runtime.symlink_to(self.runtime_dir, target_is_directory=True)

        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "RELEASE_RUNTIME_DIR resolves through a symlink or alias",
            result.stderr,
        )

        env = self._environment()
        env["CODEXSWITCH_DRY_RUN"] = "1"
        env["CODEXSWITCH_INSTALL_ROOT"] = f"{self.root}/safe/../escaped"
        result = self._run_installer(env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a .. path component", result.stderr)

    def test_stage_publishes_versioned_release_without_advancing_live_state(self):
        self._seed_systemd_state()
        self.bin_dir.mkdir(parents=True)
        public_cli = self.bin_dir / "codexswitch-cli"
        public_cli.write_text("legacy-public-cli\n")
        public_codex = self.bin_dir / "codex"
        public_codex.write_text("legacy-public-codex\n")
        service_snapshot = {
            path.relative_to(self.service_dir): path.read_bytes()
            for path in self.service_dir.rglob("*")
            if path.is_file()
        }

        result = self._stage()
        release = self._release(self.first_sha)
        manifest = self._manifest(release)
        epoch = self._git("show", "-s", "--format=%ct", self.first_sha, cwd=self.fixture_repo)
        expected_version = (
            f"codexswitch-cli {PACKAGE_VERSION} "
            f"(git {self.first_sha}, built {epoch})"
        )

        self.assertIn("staged and validated without activation", result.stdout)
        self.assertTrue(release.is_dir())
        self.assertEqual(manifest["release_id"], f"{PACKAGE_VERSION}-{self.first_sha}")
        self.assertEqual(manifest["cli_version"], expected_version)
        self.assertEqual(manifest["codex_source_sha"], CODEX_SOURCE_SHA)
        self.assertEqual(manifest["upstream_codex_git_sha"], CODEX_SOURCE_SHA)
        self.assertEqual(manifest["sourcePatchSha256"], "d" * 64)
        self.assertEqual(manifest["source_patch_sha256"], "d" * 64)
        self.assertEqual(manifest["codex_version"], CODEX_VERSION)
        self.assertEqual(
            manifest["systemd_payload"],
            "codexswitch.service,"
            "codexswitch.service.d/10-maintenance-resources.conf,"
            "signul-codex-app-server.service,"
            "signul-codex-app-server.service.d/10-runtime-resources.conf",
        )
        self.assertEqual(
            manifest["cli_sha256"],
            hashlib.sha256((release / "codexswitch-cli").read_bytes()).hexdigest(),
        )
        self.assertEqual(
            manifest["codex_sha256"],
            hashlib.sha256((release / "patched-codex" / "codex").read_bytes()).hexdigest(),
        )
        self.assertFalse((self.install_root / "current").exists())
        self.assertFalse((self.install_root / "previous").exists())
        self.assertFalse(public_cli.is_symlink())
        self.assertEqual(public_cli.read_text(), "legacy-public-cli\n")
        self.assertFalse(public_codex.is_symlink())
        self.assertEqual(public_codex.read_text(), "legacy-public-codex\n")
        self.assertEqual(
            service_snapshot,
            {
                path.relative_to(self.service_dir): path.read_bytes()
                for path in self.service_dir.rglob("*")
                if path.is_file()
            },
        )
        log = self.tool_log.read_text()
        systemctl_lines = [
            line for line in log.splitlines() if line.startswith("systemctl\t")
        ]
        self.assertGreater(len(systemctl_lines), 0)
        for line in systemctl_lines:
            self.assertRegex(
                line,
                r"^systemctl\t--user show codexswitch-build-[^ ]+\.scope "
                r"--property=ActiveState --value$",
            )
        self.assertIn(f"sha={self.first_sha}", log)
        self.assertIn(f"package={PACKAGE_VERSION}", log)
        self.assertIn(f"epoch={epoch}", log)
        self.assertIn(
            f"target={self.build_root.resolve()}/cargo-target/shared",
            log,
        )
        self.assertIn("jobs=1", log)
        self.assertIn("systemd-run\t--user --scope --quiet", log)
        self.assertIn("MemoryHigh=4G", log)
        self.assertIn("MemoryMax=6G", log)
        self.assertIn("MemorySwapMax=2G", log)
        self.assertFalse((self.build_root / "cargo-target" / "shared").exists())
        self.assertEqual(list((self.build_root / "worktrees").glob("*")), [])
        self.assertEqual(list((self.build_root / "stage").glob("*")), [])

    def test_repository_build_timeout_kills_and_reaps_descendants_before_cleanup(self):
        trace = self.root / "cargo-descendant.trace"
        pid_file = self.root / "cargo-descendant.pid"
        started = time.monotonic()
        result = self._stage(
            extra_env={
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS": "1",
                "FAKE_CARGO_HANG": "1",
                "FAKE_CARGO_DESCENDANT_TRACE": str(trace),
                "FAKE_CARGO_DESCENDANT_PID": str(pid_file),
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 15)
        self.assertTrue(pid_file.is_file())
        descendant_pid = int(pid_file.read_text().strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(descendant_pid, 0)
        trace_size = trace.stat().st_size
        time.sleep(0.2)
        self.assertEqual(trace.stat().st_size, trace_size)
        self.assertFalse((self.build_root / "cargo-target" / "shared").exists())
        self.assertEqual(list((self.build_root / "worktrees").glob("*")), [])
        self.assertNotIn("not proven reaped", result.stderr)

    def test_failed_scope_query_blocks_reap_proof_for_escaped_descendant(self):
        trace = self.root / "escaped-cargo-descendant.trace"
        pid_file = self.root / "escaped-cargo-descendant.pid"
        started = time.monotonic()
        result = self._stage(
            extra_env={
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS": "1",
                "FAKE_BUILD_SCOPE_OBSERVATION": "error",
                "FAKE_CARGO_HANG": "1",
                "FAKE_CARGO_ESCAPE_PROCESS_GROUP": "1",
                "FAKE_CARGO_DESCENDANT_TRACE": str(trace),
                "FAKE_CARGO_DESCENDANT_PID": str(pid_file),
            },
            check=False,
        )

        descendant_pid = None
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertLess(time.monotonic() - started, 8)
            self.assertTrue(pid_file.is_file())
            descendant_pid = int(pid_file.read_text().strip())
            os.kill(descendant_pid, 0)
            self.assertIn(
                "systemd scope was not positively inactive "
                "(last scope state: unknown)",
                result.stderr,
            )
            self.assertIn("build descendants were not proven reaped", result.stderr)
            self.assertEqual(
                list(self.build_root.glob(".codexswitch-build-*.reaped")), []
            )
            self.assertTrue((self.build_root / "cargo-target" / "shared").is_dir())
        finally:
            if descendant_pid is not None:
                self._terminate_fixture_process(descendant_pid)

    def test_malformed_scope_state_blocks_reap_proof(self):
        result = self._stage(
            extra_env={
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS": "1",
                "FAKE_BUILD_SCOPE_OBSERVATION": "malformed",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "systemd scope was not positively inactive "
            "(last scope state: unknown)",
            result.stderr,
        )
        self.assertIn("build descendants were not proven reaped", result.stderr)
        self.assertEqual(
            list(self.build_root.glob(".codexswitch-build-*.reaped")), []
        )
        self.assertTrue((self.build_root / "cargo-target" / "shared").is_dir())

    def test_cli_version_mismatch_and_missing_runtime_marker_reject_publication(self):
        result = self._stage(extra_env={"FAKE_BAD_CLI_VERSION": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("built CLI --version did not match", result.stderr)
        self.assertFalse(self._release(self.first_sha).exists())

        bad_runtime = self.root / "bad-runtime"
        self._create_runtime(bad_runtime, HOT_SWAP_MARKERS[:-1])
        result = self._stage(
            extra_env={"CODEXSWITCH_LINUX_ARTIFACT_DIR": str(bad_runtime)},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing goal markers", result.stderr)
        self.assertFalse(self._release(self.first_sha).exists())

    def test_incompatible_release_reuse_is_rejected(self):
        self._stage()
        release = self._release(self.first_sha)

        result = self._stage(
            extra_env={"CODEXSWITCH_CODEX_VERSION": "0.145.0"}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the verified artifact manifest", result.stderr)

        manifest = release / "release-manifest.tsv"
        manifest.chmod(0o644)
        manifest.write_text(
            manifest.read_text().replace(
                f"package_version\t{PACKAGE_VERSION}", "package_version\t9.9.9"
            )
        )

        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, "release ID|directory name")
        self.assertFalse((self.install_root / "current").exists())

    def test_manifest_is_authoritative_and_optional_expectations_must_match(self):
        self._stage()

        for missing_name in (
            "CODEXSWITCH_CODEX_VERSION",
            "CODEXSWITCH_CODEX_SOURCE_SHA",
        ):
            result = self._stage(extra_env={missing_name: ""})
            self.assertIn("Using verified existing release", result.stdout)

        result = self._activate(
            extra_env={"CODEXSWITCH_CODEX_SOURCE_SHA": "d" * 40}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the verified artifact manifest", result.stderr)
        self.assertFalse((self.install_root / "current").exists())

        result = self._stage(
            extra_env={"CODEXSWITCH_LINUX_ARTIFACT_DIR": ""}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CODEXSWITCH_LINUX_ARTIFACT_DIR is required", result.stderr)

    def test_systemd_payload_is_exact_and_rejects_extra_or_missing_entries(self):
        self._stage()
        release = self._release(self.first_sha)
        systemd_dir = release / "systemd"
        actual_files = {
            str(path.relative_to(systemd_dir))
            for path in systemd_dir.rglob("*")
            if path.is_file()
        }
        self.assertEqual(
            actual_files,
            {
                "codexswitch.service",
                "codexswitch.service.d/10-maintenance-resources.conf",
                "signul-codex-app-server.service",
                "signul-codex-app-server.service.d/10-runtime-resources.conf",
            },
        )
        self.assertNotIn("codexswitch-knowledge-sync.service", actual_files)

        systemd_dir.chmod(0o755)
        extra = systemd_dir / "rogue.service"
        extra.write_text("[Service]\nExecStart=/bin/false\n")
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unmanifested entries", result.stderr)
        extra.unlink()

        missing = systemd_dir / "codexswitch.service"
        missing.unlink()
        result = self._stage(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or unmanifested entries", result.stderr)

    def test_disk_preflight_release_max_and_build_cleanup_are_enforced(self):
        self.build_root.mkdir()
        (self.build_root / "preexisting.bin").write_bytes(b"x" * 4096)
        result = self._stage(
            extra_env={"CODEXSWITCH_BUILD_MAX_BYTES": "1024"}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build root uses", result.stderr)

        shutil.rmtree(self.build_root)
        result = self._stage(
            extra_env={"CODEXSWITCH_BUILD_MIN_FREE_BYTES": str(10**30)},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("below required", result.stderr)

        result = self._stage(
            extra_env={"CODEXSWITCH_RELEASE_MAX_BYTES": "1"}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staged release exceeds", result.stderr)
        self.assertFalse(self._release(self.first_sha).exists())
        self.assertFalse((self.build_root / "cargo-target" / "shared").exists())

    def test_retention_preserves_current_previous_candidate_and_prunes_owned_stale(self):
        self._stage()
        self._activate()
        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        self._activate(second_sha)
        current_release = self._release(second_sha)
        previous_release = self._release(self.first_sha)
        old_release_one = self._create_owned_release_stub("8.0.0", "d" * 40)
        old_release_two = self._create_owned_release_stub("7.0.0", "e" * 40)
        old_time = 1_600_000_000
        for release in (old_release_one, old_release_two):
            os.utime(release, (old_time, old_time))

        old_worktree = self.build_root / "worktrees" / f"{'f' * 40}-123"
        old_stage = self.build_root / "stage" / f"0.0.1-{'1' * 40}-456"
        old_worktree.mkdir(parents=True)
        old_stage.mkdir(parents=True)
        (old_worktree / "owned.bin").write_text("old\n")
        (old_stage / "owned.bin").write_text("old\n")
        for path in (old_worktree, old_stage):
            os.utime(path, (old_time, old_time))

        third_sha = self._commit_main_release(3)
        self._stage(
            third_sha,
            extra_env={
                "CODEXSWITCH_RELEASE_RETENTION_MAX_COUNT": "3",
                "CODEXSWITCH_RELEASE_RETENTION_MAX_AGE_DAYS": "1",
                "CODEXSWITCH_BUILD_RETENTION_MAX_AGE_HOURS": "1",
            }
        )
        self.assertTrue(current_release.exists())
        self.assertTrue(previous_release.exists())
        self.assertTrue(self._release(third_sha).exists())
        self.assertFalse(old_release_one.exists())
        self.assertFalse(old_release_two.exists())
        self.assertFalse(old_worktree.exists())
        self.assertFalse(old_stage.exists())

    def test_malformed_or_aliased_pointers_fail_before_retention_and_never_prune(self):
        self._stage()
        self._activate()
        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        self._activate(second_sha)
        current_release = self._release(second_sha)
        previous_release = self._release(self.first_sha)
        third_sha = self._commit_main_release(3)

        current = self.install_root / "current"
        current.unlink()
        current.symlink_to(current_release.resolve())
        result = self._stage(third_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current symlink has an unmanaged target", result.stderr)
        self.assertTrue(current_release.exists())
        self.assertTrue(previous_release.exists())
        self.assertFalse(self._release(third_sha).exists())

        current.unlink()
        current.symlink_to(f"releases/{current_release.name}")
        alias = self.install_root / "releases" / "rollback-alias"
        alias.symlink_to(previous_release.name, target_is_directory=True)
        previous = self.install_root / "previous"
        previous.unlink()
        previous.symlink_to("releases/rollback-alias")
        result = self._stage(third_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves through a symlink or alias", result.stderr)
        self.assertTrue(current_release.exists())
        self.assertTrue(previous_release.exists())
        self.assertFalse(self._release(third_sha).exists())

    def test_release_retention_rejects_nested_symlinks_without_chmodding_target(self):
        self._stage()
        release = self._release(self.first_sha)
        release.chmod(0o755)
        external = self.root / "external-release-target"
        external.write_text("do not touch\n")
        external.chmod(0o400)
        linked = release / "nested-external"
        linked.symlink_to(external)
        second_sha = self._commit_main_release(2)

        result = self._stage(second_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned release contains a linked", result.stderr)
        self.assertEqual(external.read_text(), "do not touch\n")
        self.assertEqual(stat.S_IMODE(external.stat().st_mode), 0o400)
        self.assertTrue(linked.is_symlink())
        self.assertFalse(self._release(second_sha).exists())

    def test_transaction_snapshot_retention_enforces_count_age_and_bytes(self):
        self._stage()
        self._activate()

        now = int(time.time())
        old = self._create_owned_transaction(910001, 32, 1_600_000_000)
        oversized = self._create_owned_transaction(910002, 200_000, now - 10)
        recent_one = self._create_owned_transaction(910003, 32, now - 5)
        recent_two = self._create_owned_transaction(910004, 32, now)

        self._activate(
            extra_env={
                "CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_COUNT": "2",
                "CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_AGE_HOURS": "1",
                "CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_BYTES": "100000",
            }
        )

        retained = list(self.service_dir.glob(".codexswitch-activation.*"))
        self.assertLessEqual(len(retained), 1)
        self.assertFalse(old.exists())
        self.assertFalse(oversized.exists())
        self.assertFalse(recent_one.exists() and recent_two.exists())

        result = self._activate(
            extra_env={"CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_BYTES": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("systemd transaction storage exceeds bounds", result.stderr)
        self.assertFalse((self.install_root / ".activation.lock").exists())
        self.assertFalse(
            (self.install_root / ".activation-transaction.tsv").exists()
        )

    def test_activation_installs_validated_systemd_and_permanent_public_link(self):
        self._seed_systemd_state()
        self._stage()
        self.tool_log.write_text("")

        self._activate(extra_env={"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"})
        release = self._release(self.first_sha)
        expected_target = f"releases/{PACKAGE_VERSION}-{self.first_sha}"
        public_cli = self.bin_dir / "codexswitch-cli"
        public_codex = self.bin_dir / "codex"

        self.assertEqual(os.readlink(self.install_root / "current"), expected_target)
        self.assertFalse((self.install_root / "previous").exists())
        self.assertEqual(
            os.readlink(public_cli),
            str(self.install_root.resolve() / "current" / "codexswitch-cli"),
        )
        self.assertEqual(public_cli.resolve(), (release / "codexswitch-cli").resolve())
        self.assertTrue(public_codex.is_file())
        self.assertFalse(public_codex.is_symlink())
        self.assertEqual(stat.S_IMODE(public_codex.stat().st_mode), 0o555)
        launcher = public_codex.read_text()
        self.assertIn(
            f"CURRENT_ROOT={self.install_root.resolve()}/current",
            launcher,
        )
        self.assertIn('CURRENT_TARGET="$(readlink "$CURRENT_ROOT")"', launcher)
        self.assertIn("codexswitch-hotswap-full-v3", launcher)
        self.assertIn('PATCHED_CODEX="$CURRENT_ROOT/patched-codex/codex"', launcher)
        self.assertIn("/usr/bin/flock --shared 9", launcher)
        self.assertIn(
            "CODEXSWITCH_LAUNCHER_FORMAT=codexswitch-current-launcher-v1",
            launcher,
        )
        self.assertIn("EXPECTED_MANIFEST_SHA256=", launcher)
        self.assertIn("EXPECTED_CODEX_IDENTITY=", launcher)
        self.assertIn("EXPECTED_HELPER_IDENTITY=", launcher)
        self.assertNotIn(
            f"{self.install_root.resolve()}/patched-codex/codex",
            launcher,
        )
        portable_launcher = self.root / "codex-launcher-fixture"
        write_executable(
            portable_launcher,
            launcher.replace("/usr/bin/flock", str(self.fake_bin / "flock")),
        )
        version = subprocess.run(
            [str(portable_launcher), "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertEqual(version.stdout.strip(), f"codex-cli {CODEX_VERSION}")
        release_manifest = release / "release-manifest.tsv"
        original_manifest = release_manifest.read_bytes()
        manifest_mode = stat.S_IMODE(release_manifest.stat().st_mode)
        release_manifest.chmod(manifest_mode | stat.S_IWUSR)
        release_manifest.write_bytes(original_manifest + b"\n")
        release_manifest.chmod(manifest_mode)
        rejected = subprocess.run(
            [str(portable_launcher), "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "manifest does not match the activated release",
            rejected.stderr,
        )
        release_manifest.chmod(manifest_mode | stat.S_IWUSR)
        release_manifest.write_bytes(original_manifest)
        release_manifest.chmod(manifest_mode)

        codex_runtime = release / "patched-codex" / "codex"
        original_runtime = codex_runtime.read_bytes()
        original_mode = stat.S_IMODE(codex_runtime.stat().st_mode)
        codex_runtime.chmod(original_mode | stat.S_IWUSR)
        codex_runtime.write_bytes(original_runtime + b"\n")
        codex_runtime.chmod(original_mode)
        rejected = subprocess.run(
            [str(portable_launcher), "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "runtime does not match the activated release",
            rejected.stderr,
        )
        codex_runtime.chmod(original_mode | stat.S_IWUSR)
        codex_runtime.write_bytes(original_runtime)
        codex_runtime.chmod(original_mode)
        app_unit = self.service_dir / "signul-codex-app-server.service"
        self.assertIn("current/patched-codex/codex", app_unit.read_text())
        dropin = self.service_dir / "signul-codex-app-server.service.d"
        for stale in ("env.conf", "limits.conf", "oom.conf", "remote-control.conf"):
            self.assertFalse((dropin / stale).exists())
        self.assertEqual(
            {path.name for path in dropin.iterdir()},
            {"10-runtime-resources.conf"},
        )
        self.assertFalse((self.service_dir / "codexswitch-knowledge-sync.service").exists())
        self.assertFalse((self.service_dir / "codexswitch-knowledge-sync.timer").exists())
        self.assertFalse(
            (
                self.service_dir
                / "default.target.wants"
                / "codexswitch-knowledge-sync.timer"
            ).is_symlink()
        )
        self.assertFalse(
            (
                self.service_dir
                / "timers.target.wants"
                / "codexswitch-knowledge-sync.timer"
            ).is_symlink()
        )
        self.assertFalse(
            (self.service_dir / "default.target.wants" / "codexswitch.service").is_symlink()
        )
        self.assertFalse(
            (
                self.service_dir
                / "default.target.wants"
                / "signul-codex-app-server.service"
            ).is_symlink()
        )
        managed_files = {
            str(path.relative_to(self.service_dir))
            for path in self.service_dir.rglob("*")
            if path.is_file()
        }
        self.assertEqual(
            managed_files,
            {
                "codexswitch.service",
                "codexswitch.service.d/10-maintenance-resources.conf",
                "signul-codex-app-server.service",
                "signul-codex-app-server.service.d/10-runtime-resources.conf",
                "unrelated-knowledge-sync.timer",
            },
        )
        log = self.tool_log.read_text()
        self.assertIn("systemctl\t--user daemon-reload", log)
        self.assertIn("systemctl\t--user cat codexswitch.service", log)
        self.assertIn("systemctl\t--user cat signul-codex-app-server.service", log)
        self.assertIn(
            "systemctl\t--user show codexswitch.service -p MemoryMax --value",
            log,
        )
        self.assertIn(
            "systemctl\t--user show signul-codex-app-server.service "
            "-p MemorySwapMax --value",
            log,
        )
        self.assertNotIn("systemctl\t--user restart", log)
        self.assertNotIn("systemctl\t--user enable", log)

    def test_activation_migrates_only_the_known_legacy_codex_launcher(self):
        self._stage()
        self.bin_dir.mkdir(parents=True)
        public_codex = self.bin_dir / "codex"
        legacy_runtime = self.install_root / "patched-codex" / "codex"
        write_executable(
            public_codex,
            f"""
            #!/usr/bin/env bash
            PATCHED_CODEX='{legacy_runtime}'
            echo "run codexswitch-cli install-prepared-codex" >&2
            exec "$PATCHED_CODEX" "$@"
            """,
        )

        self._activate()

        self.assertFalse(public_codex.is_symlink())
        self.assertNotIn(str(legacy_runtime), public_codex.read_text())
        self.assertIn(
            'PATCHED_CODEX="$CURRENT_ROOT/patched-codex/codex"',
            public_codex.read_text(),
        )

        public_codex.chmod(0o755)
        public_codex.write_text("#!/bin/sh\necho unrelated\n")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public Codex launcher is not a recognized CodexSwitch route",
            result.stderr,
        )
        self.assertEqual(public_codex.read_text(), "#!/bin/sh\necho unrelated\n")

        write_executable(
            public_codex,
            f"""
            #!/usr/bin/env bash
            echo "PATCHED_CODEX='{legacy_runtime}'"
            echo "run codexswitch-cli install-prepared-codex"
            echo 'exec "$PATCHED_CODEX" "$@"'
            """,
        )
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public Codex launcher is not a recognized CodexSwitch route",
            result.stderr,
        )

    def test_committed_activation_repairs_a_stale_generated_codex_launcher(self):
        self._stage()
        self._activate()
        public_codex = self.bin_dir / "codex"
        first_launcher = public_codex.read_bytes()
        stale_launcher = self.root / "stale-codex-launcher"

        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        result = self._activate(
            second_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_commit_before_codex_launcher",
                "CODEXSWITCH_TEST_FAULT_MODE": "crash",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            os.readlink(self.install_root / "current"),
            f"releases/{PACKAGE_VERSION}-{second_sha}",
        )
        self.assertEqual(public_codex.read_bytes(), first_launcher)
        self.assertTrue((self.install_root / ".activation-transaction.tsv").is_file())

        self._activate(second_sha)

        self.assertNotEqual(public_codex.read_bytes(), first_launcher)
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())
        self.assertIn(
            "CODEXSWITCH_LAUNCHER_FORMAT=codexswitch-current-launcher-v1",
            public_codex.read_text(),
        )
        portable_current = self.root / "current-codex-launcher"
        write_executable(
            portable_current,
            public_codex.read_text().replace(
                "/usr/bin/flock",
                str(self.fake_bin / "flock"),
            ),
        )
        stale_contents = first_launcher.decode().replace(
            "/usr/bin/flock",
            str(self.fake_bin / "flock"),
        )
        stale_contents = stale_contents.replace(
            f"PUBLIC_LAUNCHER={public_codex}",
            f"PUBLIC_LAUNCHER={portable_current}",
        )
        write_executable(stale_launcher, stale_contents)
        version = subprocess.run(
            [str(stale_launcher), "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertEqual(version.stdout.strip(), f"codex-cli {CODEX_VERSION}")

    def test_unowned_abandoned_transaction_is_preserved_for_manual_review(self):
        self._stage()
        self.service_dir.mkdir()
        abandoned = self.service_dir / ".codexswitch-activation.999999"
        abandoned.mkdir()
        (abandoned / "state.tsv").write_text("forged\tfixture\n")

        result = self._activate(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unowned abandoned systemd transaction", result.stderr)
        self.assertTrue(abandoned.is_dir())
        self.assertEqual((abandoned / "state.tsv").read_text(), "forged\tfixture\n")
        self.assertFalse((self.install_root / "current").exists())

    def test_first_activation_requires_exact_not_found_systemd_evidence(self):
        before = self._activation_surface_state()
        cases = (
            ("missing-loaded", "missing-fragment-load-state-loaded"),
            ("failed", "missing-fragment-active-state-failed"),
            ("drifted-fragment", "missing-fragment-provenance-present"),
            ("drifted-exec", "missing-fragment-execstart-present"),
            ("stale-main-pid", "missing-fragment-main-pid"),
        )

        for observation, reason in cases:
            with self.subTest(observation=observation):
                self.tool_log.write_text("")
                result = self._activate(
                    extra_env={"FAKE_RUNTIME_SYSTEMD_OBSERVATION": observation},
                    check=False,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)
                self.assertEqual(self._activation_surface_state(), before)
                self.assertFalse(
                    (self.install_root / ".activation-transaction.tsv").exists()
                )
                self._assert_no_runtime_action()

    def test_typed_systemd_observation_blocks_before_any_activation_mutation(self):
        next_sha = self._seed_trusted_inactive_runtime()
        before = self._activation_surface_state()
        cases = (
            "exit4",
            "error",
            "failed",
            "timeout",
            "malformed",
            "stderr",
            "drifted-fragment",
            "drifted-exec",
            "stale-main-pid",
            "active",
        )

        for observation in cases:
            with self.subTest(observation=observation):
                self.tool_log.write_text("")
                result = self._activate(
                    next_sha,
                    {"FAKE_RUNTIME_SYSTEMD_OBSERVATION": observation},
                    check=False,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("systemd runtime observation is", result.stderr)
                self.assertEqual(self._activation_surface_state(), before)
                self.assertFalse(
                    (self.install_root / ".activation-transaction.tsv").exists()
                )
                self._assert_no_runtime_action()

    def test_active_daemon_reservation_blocks_before_any_activation_mutation(self):
        next_sha = self._seed_trusted_inactive_runtime()
        before = self._activation_surface_state()
        reservation = (
            self.home / ".codex" / "app-server-daemon" / "app-server.pid.lock"
        )
        reservation.parent.mkdir(parents=True)

        with reservation.open("w+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.tool_log.write_text("")
            result = self._activate(next_sha, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemon runtime observation is active", result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_daemon_pid_and_socket_artifacts_block_before_any_activation_mutation(self):
        next_sha = self._seed_trusted_inactive_runtime()
        before = self._activation_surface_state()
        daemon_dir = self.home / ".codex" / "app-server-daemon"
        daemon_dir.mkdir(parents=True)
        pid = 424242
        process_dir = self.proc_root / str(pid)
        process_dir.mkdir()
        (daemon_dir / "app-server.pid").write_text(
            '{"pid":424242,"processStartTime":"Mon Jul 13 21:10:34 2026"}\n'
        )

        self.tool_log.write_text("")
        pid_result = self._activate(next_sha, check=False)

        self.assertNotEqual(pid_result.returncode, 0)
        self.assertIn("daemon runtime observation is unknown", pid_result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

        (daemon_dir / "app-server.pid").unlink()
        process_dir.rmdir()
        socket_path = (
            self.home
            / ".codex"
            / "app-server-control"
            / "app-server-control.sock"
        )
        socket_path.parent.mkdir(parents=True)
        self.tool_log.write_text("")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            socket_result = self._activate(next_sha, check=False)

        self.assertNotEqual(socket_result.returncode, 0)
        self.assertIn("daemon runtime observation is unknown", socket_result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_concurrent_guard_bearing_start_blocks_before_rename_or_unit_write(self):
        self._stage()
        before = self._activation_surface_state()
        guard = self.install_root / "runtime-start-install.lock"
        self.tool_log.write_text("")

        with guard.open("w+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
            result = self._activate(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime guard holder refused activation", result.stderr)
        self.assertIn("guard-held", result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_concurrent_managed_daemon_start_blocks_before_rename_or_unit_write(self):
        self._stage()
        before = self._activation_surface_state()
        reservation = (
            self.home / ".codex" / "app-server-daemon" / "app-server.pid.lock"
        )
        reservation.parent.mkdir(parents=True)
        self.tool_log.write_text("")

        with reservation.open("w+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self._activate(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemon runtime observation is active", result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_systemd_activity_query_failures_are_never_inactive(self):
        self._stage()
        before = self._activation_surface_state()

        for mode in ("error", "unknown", "failed", "malformed"):
            with self.subTest(mode=mode):
                self.tool_log.write_text("")
                result = self._activate(
                    extra_env={
                        "FAKE_SYSTEMD_IS_ACTIVE_FAILURE_UNIT": "codexswitch.service",
                        "FAKE_SYSTEMD_IS_ACTIVE_FAILURE_MODE": mode,
                    },
                    check=False,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("systemd activity is not positively inactive", result.stderr)
                self.assertEqual(self._activation_surface_state(), before)
                self._assert_no_runtime_action()

    def test_concurrent_maintenance_start_is_blocked_by_loaded_barrier(self):
        self._stage()
        before = self._activation_surface_state()
        self.tool_log.write_text("")

        result = self._activate(
            extra_env={
                "FAKE_CONCURRENT_MAINTENANCE_START": "1",
                "FAKE_FAIL_AFTER_CONCURRENT_BARRIER": "1",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("final systemd activity is not positively inactive", result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        log = self.tool_log.read_text()
        self.assertIn("systemd-start-blocked\tcodexswitch.service", log)
        barrier = (
            self.xdg_runtime_dir.resolve()
            / "systemd"
            / "user.control"
            / "codexswitch.service.d"
            / "00-codexswitch-activation-guard.conf"
        )
        self.assertFalse(barrier.exists())
        self._assert_no_runtime_action()

    def test_runtime_guard_symlink_is_rejected_without_following_it(self):
        self._stage()
        before = self._activation_surface_state()
        outside = self.root / "outside-guard-target"
        outside.write_text("outside\n")
        guard = self.install_root / "runtime-start-install.lock"
        guard.symlink_to(outside)
        self.tool_log.write_text("")

        result = self._activate(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime guard holder refused activation", result.stderr)
        self.assertIn("guard-open", result.stderr)
        self.assertEqual(outside.read_text(), "outside\n")
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_runtime_guard_inode_replacement_is_detected_before_commit(self):
        self.service_dir = self.home / ".config" / "systemd" / "user"
        self._stage()
        before = self._activation_surface_state()
        self.tool_log.write_text("")

        result = self._activate(
            extra_env={
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_REPLACE_RUNTIME_GUARD_BEFORE_COMMIT": "1",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime guard path identity changed", result.stderr)
        self.assertEqual(self._activation_surface_state(), before)
        self._assert_no_runtime_action()

    def test_systemd_start_barriers_span_commit_and_are_removed_before_unlock(self):
        self.service_dir = self.home / ".config" / "systemd" / "user"
        self._stage()
        self.tool_log.write_text("")

        self._activate()

        barrier_root = (
            self.xdg_runtime_dir.resolve() / "systemd" / "user.control"
        )
        for unit in (
            "codexswitch.service",
            "signul-codex-app-server.service",
            "codexswitch-daemon.service",
        ):
            barrier = (
                barrier_root
                / f"{unit}.d"
                / "00-codexswitch-activation-guard.conf"
            )
            self.assertFalse(barrier.exists())
        log = self.tool_log.read_text()
        self.assertIn("systemctl\t--user cat codexswitch.service", log)
        self.assertGreaterEqual(log.count("systemctl\t--user daemon-reload"), 2)
        self.assertTrue((self.install_root / "current").is_symlink())

    def test_explicit_start_occurs_only_after_positive_inactive_commit(self):
        next_sha = self._seed_trusted_inactive_runtime()
        self.tool_log.write_text("")

        result = self._activate(
            next_sha,
            {"CODEXSWITCH_START_APP_SERVER": "1"},
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            os.readlink(self.install_root / "current"),
            f"releases/{PACKAGE_VERSION}-{next_sha}",
        )
        log = self.tool_log.read_text()
        self.assertEqual(
            log.count("systemctl\t--user start signul-codex-app-server.service"),
            1,
        )
        self.assertNotRegex(log, r"(?m)^systemctl\t--user (?:stop|restart)(?:\s|$)")

    def test_import_digest_and_failure_roll_back_the_complete_transaction(self):
        self._seed_systemd_state(include_target_enablement=False)
        self._stage()
        bundle = self.root / "accounts.bundle"
        bundle.write_bytes(b"fixture import bundle\n")
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
        account_store = self.home / ".codexswitch" / "accounts.json"
        auth_path = self.home / ".codex" / "auth.json"
        account_lock = account_store.with_suffix(".json.lock")
        account_store.parent.mkdir(parents=True)
        auth_path.parent.mkdir(parents=True)
        account_store.write_bytes(b"old accounts\n")
        auth_path.write_bytes(b"old auth\n")
        account_store.chmod(0o600)
        auth_path.chmod(0o640)
        original_systemd = self._systemd_artifact_state()

        bad_digest = self._activate(
            extra_env={
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": "0" * 64,
            },
            check=False,
        )
        self.assertNotEqual(bad_digest.returncode, 0)
        self.assertIn("CODEXSWITCH_IMPORT_BUNDLE SHA-256 mismatch", bad_digest.stderr)
        self.assertEqual(account_store.read_bytes(), b"old accounts\n")
        self.assertEqual(auth_path.read_bytes(), b"old auth\n")
        self.assertFalse(account_lock.exists())
        self.assertEqual(self._systemd_artifact_state(), original_systemd)

        self.tool_log.write_text("")
        failed_import = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
                "CODEXSWITCH_ENABLE_DAEMON": "1",
                "FAKE_IMPORT_FAIL": "1",
            },
            check=False,
        )

        self.assertEqual(failed_import.returncode, 44)
        self.assertEqual(account_store.read_bytes(), b"old accounts\n")
        self.assertEqual(auth_path.read_bytes(), b"old auth\n")
        self.assertEqual(stat.S_IMODE(account_store.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(auth_path.stat().st_mode), 0o640)
        self.assertFalse(account_lock.exists())
        self.assertEqual(self._systemd_artifact_state(), original_systemd)
        self.assertFalse((self.install_root / "current").exists())
        self.assertFalse((self.install_root / "previous").exists())
        self.assertFalse((self.bin_dir / "codexswitch-cli").exists())
        self.assertFalse(
            (self.install_root / ".activation-transaction.tsv").exists()
        )
        self.assertFalse((self.install_root / ".activation.lock").exists())
        self.assertFalse(
            (
                self.systemd_state_dir
                / "active"
                / "signul-codex-app-server.service"
            ).exists()
        )
        log = self.tool_log.read_text()
        self.assertIn("systemctl\t--user enable codexswitch.service", log)
        self.assertNotIn(
            "systemctl\t--user restart signul-codex-app-server.service", log
        )
        self.assertRegex(
            log,
            r"(?m)^cli\timport --offline-file-only .*/\.codexswitch-activation\.[0-9]+/import-bundle\.csbundle$",
        )
        self.assertIn(f"cli-import-sha256\t{digest}", log)
        self.assertNotIn(
            "systemctl\t--user stop signul-codex-app-server.service", log
        )

        self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
            }
        )
        self.assertIn(f":{digest}\n", account_store.read_text())
        self.assertIn(f":{digest}\n", auth_path.read_text())
        self.assertTrue(account_lock.is_file())
        self.assertTrue((self.install_root / "current").is_symlink())
        self.assertTrue((self.bin_dir / "codexswitch-cli").is_symlink())
        self.assertFalse(
            (self.install_root / ".activation-transaction.tsv").exists()
        )

    def test_post_start_import_requires_exact_barrier_convergence(self):
        self._stage()
        bundle = self.root / "accounts.bundle"
        bundle.write_bytes(b"fixture import bundle\n")
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()

        result = self._activate(
            extra_env={
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
                "CODEXSWITCH_START_APP_SERVER": "1",
                "CODEXSWITCH_START_DAEMON": "1",
            }
        )

        self.assertIn("confirmed import convergence", result.stdout)
        activation_record = (
            self.home / ".codexswitch" / "accounts.activation.json"
        )
        self.assertEqual(
            json.loads(activation_record.read_text())["state"],
            "confirmed",
        )
        log = self.tool_log.read_text()
        app_start = log.index(
            "systemctl\t--user start signul-codex-app-server.service"
        )
        daemon_start = log.index("systemctl\t--user start codexswitch.service")
        self.assertLess(app_start, daemon_start)
        self.assertIn("cli\timport --offline-file-only ", log)

    def test_post_start_import_rejects_a_different_confirmed_barrier(self):
        self._stage()
        bundle = self.root / "accounts.bundle"
        bundle.write_bytes(b"fixture import bundle\n")
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()

        result = self._activate(
            extra_env={
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
                "CODEXSWITCH_START_APP_SERVER": "1",
                "CODEXSWITCH_START_DAEMON": "1",
                "FAKE_IMPORT_CONVERGENCE": "mismatch",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "does not identify the prepared Import/FileOnly barrier",
            result.stderr,
        )
        self.assertNotIn("confirmed import convergence", result.stdout)

    def test_import_anchors_bundle_bytes_and_preserves_a_later_writer(self):
        self._stage()
        bundle = self.root / "replaceable.bundle"
        original = b"exact reviewed bundle bytes\n"
        bundle.write_bytes(original)
        digest = hashlib.sha256(original).hexdigest()
        account_store = self.home / ".codexswitch" / "accounts.json"
        auth_path = self.home / ".codex" / "auth.json"

        anchored = self._activate(
            extra_env={
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
                "FAKE_REPLACE_ORIGINAL_BUNDLE": str(bundle),
            }
        )
        self.assertEqual(anchored.returncode, 0)
        self.assertEqual(bundle.read_bytes(), b"replacement bytes\n")
        self.assertIn(f"cli-import-sha256\t{digest}", self.tool_log.read_text())
        self.assertIn(f":{digest}\n", account_store.read_text())

        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        bundle.write_bytes(original)
        later_store = "later writer store\n"
        later_auth = "later writer auth\n"
        failed = self._activate(
            second_sha,
            {
                "CODEXSWITCH_IMPORT_BUNDLE": str(bundle),
                "CODEXSWITCH_IMPORT_BUNDLE_SHA256": digest,
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_actions",
                "CODEXSWITCH_TEST_CONCURRENT_ACCOUNT_STORE": later_store,
                "CODEXSWITCH_TEST_CONCURRENT_AUTH": later_auth,
            },
            check=False,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("import rollback ownership changed", failed.stderr)
        self.assertEqual(account_store.read_text(), later_store)
        self.assertEqual(auth_path.read_text(), later_auth)
        self.assertTrue((self.install_root / ".activation-transaction.tsv").is_file())

    def test_daemon_reload_lock_and_merged_conflicts_block_pointer_changes(self):
        self._stage()

        result = self._activate(
            extra_env={"FAKE_DAEMON_RELOAD_FAIL_AFTER": "1"}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed to load systemd start barriers", result.stderr)
        self.assertFalse((self.install_root / "current").exists())

        lock = self.install_root / ".activation.lock"
        lock.write_text("")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation lock has no durable owner record", result.stderr)
        self.assertFalse((self.install_root / "current").exists())
        lock.unlink()

        lock.write_text(
            "format\tcodexswitch-activation-lock-v1\n"
            f"pid\t{os.getpid()}\n"
            "start\tUNKNOWN\n"
            f"token\t{'a' * 32}\n"
        )
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another activation holds", result.stderr)
        self.assertTrue(lock.exists())
        lock.unlink()
        self._activate()

        unknown_dropin = (
            self.service_dir
            / "signul-codex-app-server.service.d"
            / "99-unknown-policy.conf"
        )
        unknown_dropin.parent.mkdir(parents=True, exist_ok=True)
        unknown_dropin.write_text(
            "[Unit]\nStartLimitBurst=9\n"
            "[Service]\nMemoryMax=1G\nCPUQuota=50%\n"
        )
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not approval-removable", result.stderr)
        self.assertTrue((self.install_root / "current").is_symlink())

        result = self._activate(
            extra_env={"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not approval-removable", result.stderr)
        self.assertTrue(unknown_dropin.exists())
        unknown_dropin.unlink()

        known_dropin = unknown_dropin.parent / "env.conf"
        known_dropin.write_text("[Service]\nEnvironment=STALE=1\n")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("removable_dropin=env.conf", result.stderr)
        self._activate(extra_env={"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"})
        self.assertTrue((self.install_root / "current").is_symlink())
        self.assertFalse(known_dropin.exists())

    def test_active_legacy_units_and_dependency_conflicts_block_activation(self):
        self._stage()
        for active_unit in (
            "codexswitch-knowledge-sync.service",
            "signul-codex-app-server.service",
        ):
            with self.subTest(active_unit=active_unit):
                result = self._activate(
                    extra_env={"FAKE_ACTIVE_UNITS": active_unit}, check=False
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "systemd activity is not positively inactive", result.stderr
                )
                self.assertIn(active_unit, result.stderr)
                self.assertFalse((self.install_root / "current").exists())

        self.service_dir.mkdir(exist_ok=True)
        rogue_unit = self.service_dir / "codexswitch-old-worker.service"
        rogue_unit.write_text("[Service]\nExecStart=/bin/false\n")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected conflicting CodexSwitch unit file", result.stderr)
        rogue_unit.unlink()

        rogue_dropin = self.service_dir / "codexswitch-old-worker.service.d"
        rogue_dropin.mkdir()
        (rogue_dropin / "override.conf").write_text("[Service]\nNice=5\n")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected conflicting CodexSwitch unit file", result.stderr)
        shutil.rmtree(rogue_dropin)

        requires = self.service_dir / "multi-user.target.requires"
        requires.mkdir()
        rogue_enablement = requires / "codexswitch-old-worker.service"
        rogue_enablement.symlink_to("../codexswitch-old-worker.service")
        result = self._activate(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "unexpected conflicting CodexSwitch enablement artifact", result.stderr
        )
        rogue_enablement.unlink()

        dependency_conflicts = (
            "Requires=legacy-agent.service",
            "RequiresMountsFor=/srv/legacy-agent",
            "BindsTo=legacy-agent.service",
            "Requisite=legacy-agent.service",
            "PartOf=legacy-agent.service",
            "Upholds=legacy-agent.service",
            "PropagatesStopTo=legacy-agent.service",
            "StopPropagatedFrom=legacy-agent.service",
            "JoinsNamespaceOf=legacy-agent.service",
            "TriggeredBy=legacy-agent.socket",
            "WantedBy=legacy.target",
            "Also=legacy-agent.service",
            "Sockets=legacy-agent.socket",
            "After=",
            "DefaultDependencies=no",
        )
        result = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "FAKE_SYSTEMD_CONFLICT_UNIT": "codexswitch.service",
                "FAKE_SYSTEMD_CONFLICT_LINE": "\n".join(dependency_conflicts),
            },
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        for directive in dependency_conflicts:
            with self.subTest(directive=directive):
                self.assertIn(directive, result.stderr)
        self.assertIn("approval only permits removal", result.stderr)
        self.assertFalse((self.install_root / "current").exists())
        self.assertFalse((self.service_dir / "codexswitch.service").exists())
        self.assertFalse(
            (self.install_root / ".activation-transaction.tsv").exists()
        )

    def test_effective_systemd_state_is_exact_and_repository_sourced(self):
        self._stage()

        filesystem_cases = (
            ("codexswitch.socket", "[Socket]\nListenStream=1234\n"),
            ("signul-codex-app-server.path", "[Path]\nPathExists=/tmp/nope\n"),
        )
        self.service_dir.mkdir(exist_ok=True)
        for name, content in filesystem_cases:
            with self.subTest(artifact=name):
                artifact = self.service_dir / name
                artifact.write_text(content)
                result = self._activate(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected conflicting CodexSwitch unit file", result.stderr)
                self.assertTrue(artifact.is_file())
                artifact.unlink()

        relation_dir = self.service_dir / "legacy.target.upholds"
        relation_dir.mkdir()
        relation = relation_dir / "codexswitch.service"
        relation.symlink_to("../codexswitch.service")
        relation_result = self._activate(check=False)
        self.assertNotEqual(relation_result.returncode, 0)
        self.assertIn("unexpected conflicting CodexSwitch relationship artifact", relation_result.stderr)
        relation.unlink()
        relation_dir.rmdir()

        external_result = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "FAKE_SYSTEMD_EXTERNAL_DROPIN_UNIT": "codexswitch.service",
                "FAKE_SYSTEMD_EXTERNAL_DROPIN_PATH": "/etc/systemd/user/99-empty.conf",
            },
            check=False,
        )
        self.assertNotEqual(external_result.returncode, 0)
        self.assertIn("systemd source provenance mismatch", external_result.stderr)

        directive_result = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "FAKE_SYSTEMD_CONFLICT_UNIT": "codexswitch.service",
                "FAKE_SYSTEMD_CONFLICT_LINE": "[Service]\nCollectMode=inactive",
            },
            check=False,
        )
        self.assertNotEqual(directive_result.returncode, 0)
        self.assertIn("CollectMode=inactive", directive_result.stderr)

        overrides = self._systemd_show_overrides(
            ("codexswitch.service", "Upholds", "legacy-agent.service")
        )
        property_result = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "FAKE_SYSTEMD_SHOW_OVERRIDES": str(overrides),
            },
            check=False,
        )
        self.assertNotEqual(property_result.returncode, 0)
        self.assertIn("effective systemd dependency mismatch", property_result.stderr)
        self.assertIn("property=Upholds", property_result.stderr)
        self.assertFalse((self.install_root / "current").exists())

    def test_fault_injection_preserves_non_tearing_public_resolution(self):
        self._stage()
        self._activate()
        first_target = f"releases/{PACKAGE_VERSION}-{self.first_sha}"
        public_cli = self.bin_dir / "codexswitch-cli"
        public_codex = self.bin_dir / "codex"

        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        result = self._activate(
            second_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_previous",
            },
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(self.install_root / "current"), first_target)
        self.assertEqual(public_cli.resolve(), (self._release(self.first_sha) / "codexswitch-cli").resolve())
        self.assertIn(
            f"CURRENT_ROOT={self.install_root.resolve()}/current",
            public_codex.read_text(),
        )
        self.assertFalse((self.install_root / "previous").exists())
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())
        self.assertFalse((self.install_root / ".activation.lock").exists())

        self._activate(second_sha)
        second_target = f"releases/{PACKAGE_VERSION}-{second_sha}"
        self.assertEqual(os.readlink(self.install_root / "current"), second_target)
        self.assertEqual(os.readlink(self.install_root / "previous"), first_target)

        third_sha = self._commit_main_release(3)
        self._stage(third_sha)
        result = self._activate(
            third_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_current",
            },
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            os.readlink(self.install_root / "current"),
            second_target,
        )
        self.assertEqual(os.readlink(self.install_root / "previous"), first_target)
        self.assertEqual(public_cli.resolve(), (self._release(second_sha) / "codexswitch-cli").resolve())
        self.assertIn(
            'PATCHED_CODEX="$CURRENT_ROOT/patched-codex/codex"',
            public_codex.read_text(),
        )
        self.assertEqual(
            os.readlink(public_cli),
            str(self.install_root.resolve() / "current" / "codexswitch-cli"),
        )
        self.assertFalse((self.install_root / ".activation.lock").exists())
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())

    def test_effective_memory_ceiling_mismatch_rolls_back_activation(self):
        self._stage()
        result = self._activate(
            extra_env={
                "FAKE_SYSTEMD_SHOW_UNIT": "signul-codex-app-server.service",
                "FAKE_SYSTEMD_SHOW_PROPERTY": "MemoryMax",
                "FAKE_SYSTEMD_SHOW_VALUE": "1073741824",
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("effective systemd resource mismatch", result.stderr)
        self.assertIn("property=MemoryMax", result.stderr)
        self.assertFalse((self.install_root / "current").exists())
        self.assertFalse((self.service_dir / "codexswitch.service").exists())
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())
        self.assertFalse((self.install_root / ".activation.lock").exists())

    def test_first_activation_and_rollback_faults_restore_all_pointer_state(self):
        self._stage()
        result = self._activate(
            extra_env={
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "first_activation",
            },
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install_root / "current").exists())
        self.assertFalse((self.install_root / "previous").exists())
        self.assertFalse((self.bin_dir / "codexswitch-cli").exists())
        self.assertFalse((self.bin_dir / "codex").exists())
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())

        self._activate()
        first_target = f"releases/{PACKAGE_VERSION}-{self.first_sha}"
        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        self._activate(second_sha)
        second_target = f"releases/{PACKAGE_VERSION}-{second_sha}"

        result = self._activate(
            self.first_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "rollback",
            },
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(self.install_root / "current"), second_target)
        self.assertEqual(os.readlink(self.install_root / "previous"), first_target)
        self.assertEqual(
            (self.bin_dir / "codexswitch-cli").resolve(),
            (self._release(second_sha) / "codexswitch-cli").resolve(),
        )
        self.assertIn(
            'PATCHED_CODEX="$CURRENT_ROOT/patched-codex/codex"',
            (self.bin_dir / "codex").read_text(),
        )
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())

    def test_crash_recovery_is_restartable_and_preserves_historical_previous(self):
        self._stage()
        self._activate()
        first_target = f"releases/{PACKAGE_VERSION}-{self.first_sha}"
        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        second_target = f"releases/{PACKAGE_VERSION}-{second_sha}"

        crashed = self._activate(
            second_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_current",
                "CODEXSWITCH_TEST_FAULT_MODE": "crash",
            },
            check=False,
        )
        self.assertLess(crashed.returncode, 0)
        self.assertEqual(os.readlink(self.install_root / "current"), second_target)
        self.assertFalse((self.install_root / "previous").exists())
        self.assertTrue((self.install_root / ".activation-transaction.tsv").exists())
        self.assertTrue((self.install_root / ".activation.lock").exists())

        recovery_fault = self._activate(
            self.first_sha,
            {
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "rollback_recovery",
            },
            check=False,
        )
        self.assertNotEqual(recovery_fault.returncode, 0)
        self.assertTrue((self.install_root / ".activation-transaction.tsv").exists())
        self.assertEqual(os.readlink(self.install_root / "current"), second_target)

        recovered = self._activate(self.first_sha)
        self.assertIn("Recovered incomplete activation transaction", recovered.stderr)
        self.assertEqual(os.readlink(self.install_root / "current"), first_target)
        self.assertFalse((self.install_root / "previous").exists())
        self.assertEqual(
            (self.bin_dir / "codexswitch-cli").resolve(),
            (self._release(self.first_sha) / "codexswitch-cli").resolve(),
        )
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())
        self.assertFalse((self.install_root / ".activation.lock").exists())

    def test_pre_journal_lock_and_partial_snapshot_crashes_are_recoverable(self):
        self._stage()
        for point in ("after_lock", "partial_snapshot", "before_journal"):
            with self.subTest(point=point):
                crashed = self._activate(
                    extra_env={
                        "CODEXSWITCH_TEST_MODE": "1",
                        "CODEXSWITCH_TEST_FAULT_POINT": point,
                        "CODEXSWITCH_TEST_FAULT_MODE": "crash",
                    },
                    check=False,
                )
                self.assertLess(crashed.returncode, 0)
                lock = self.install_root / ".activation.lock"
                self.assertTrue(lock.is_file())
                lock_state = lock.read_text()
                self.assertIn("format\tcodexswitch-activation-lock-v1", lock_state)
                self.assertRegex(lock_state, r"token\t[0-9a-f]{32}\n")
                self.assertFalse(
                    (self.install_root / ".activation-transaction.tsv").exists()
                )
                transactions = list(
                    self.service_dir.glob(".codexswitch-activation.*")
                )
                if point == "after_lock":
                    self.assertEqual(transactions, [])
                else:
                    self.assertEqual(len(transactions), 1)
                    transaction = transactions[0]
                    self.assertTrue((transaction / "owner.tsv").is_file())
                    if point == "partial_snapshot":
                        state_lines = (transaction / "state.tsv").read_text().splitlines()
                        self.assertEqual(len(state_lines), 1)
                        self.assertFalse((transaction / "staged").exists())
                    else:
                        self.assertTrue((transaction / "staged").is_dir())

                recovered = self._activate()
                self.assertIn("CodexSwitch release activated", recovered.stdout)
                self.assertFalse((self.install_root / ".activation.lock").exists())
                self.assertFalse(
                    (self.install_root / ".activation-transaction.tsv").exists()
                )
                self.assertEqual(
                    list(self.service_dir.glob(".codexswitch-activation.*")), []
                )

    def test_crash_recovery_restores_exact_previous_systemd_state(self):
        self._stage()
        daemon_unit = self.service_dir / "codexswitch.service"
        app_dropins = self.service_dir / "signul-codex-app-server.service.d"
        self.service_dir.mkdir()
        daemon_unit.write_text("[Service]\nExecStart=/legacy/daemon\n")
        app_dropins.mkdir()
        operator_dropin = app_dropins / "env.conf"
        operator_dropin.write_text("[Unit]\nAfter=legacy.target\n")
        wants = self.service_dir / "default.target.wants"
        wants.mkdir()
        legacy_enablement = wants / "codexswitch-knowledge-sync.timer"
        legacy_enablement.symlink_to("../codexswitch-knowledge-sync.timer")

        crashed = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_systemd",
                "CODEXSWITCH_TEST_FAULT_MODE": "crash",
            },
            check=False,
        )
        self.assertLess(crashed.returncode, 0)
        self.assertNotIn("/legacy/daemon", daemon_unit.read_text())
        self.assertFalse(operator_dropin.exists())
        self.assertFalse(legacy_enablement.is_symlink())

        interrupted_recovery = self._activate(
            extra_env={"FAKE_DAEMON_RELOAD_FAIL_AFTER": "3"}, check=False
        )
        self.assertNotEqual(interrupted_recovery.returncode, 0)
        self.assertEqual(
            daemon_unit.read_text(), "[Service]\nExecStart=/legacy/daemon\n"
        )
        self.assertEqual(
            operator_dropin.read_text(), "[Unit]\nAfter=legacy.target\n"
        )
        self.assertTrue(legacy_enablement.is_symlink())
        self.assertEqual(
            os.readlink(legacy_enablement), "../codexswitch-knowledge-sync.timer"
        )
        self.assertFalse(
            (self.service_dir / "signul-codex-app-server.service").exists()
        )
        self.assertTrue((self.install_root / ".activation-transaction.tsv").exists())

        self._activate(
            extra_env={"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"}
        )
        self.assertFalse((self.install_root / ".activation-transaction.tsv").exists())
        self.assertFalse(operator_dropin.exists())
        self.assertFalse(legacy_enablement.is_symlink())

    def test_recovery_validates_every_snapshot_before_first_mutation(self):
        self._stage()
        self.service_dir.mkdir()
        daemon = self.service_dir / "codexswitch.service"
        daemon.write_text("[Service]\nExecStart=/legacy/daemon\n")
        external = self.root / "external-recovery-target"
        external.write_text("do not touch\n")

        crashed = self._activate(
            extra_env={
                "CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1",
                "CODEXSWITCH_TEST_MODE": "1",
                "CODEXSWITCH_TEST_FAULT_POINT": "after_systemd",
                "CODEXSWITCH_TEST_FAULT_MODE": "crash",
            },
            check=False,
        )
        self.assertLess(crashed.returncode, 0)
        transaction = next(self.service_dir.glob(".codexswitch-activation.*"))
        snapshot = transaction / "before" / "codexswitch.service"
        snapshot.unlink()
        snapshot.symlink_to(external)
        state_before = self._systemd_artifact_state()

        recovery = self._activate(
            extra_env={"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"},
            check=False,
        )

        self.assertNotEqual(recovery.returncode, 0)
        self.assertIn("recovery snapshot is linked or special", recovery.stderr)
        self.assertEqual(self._systemd_artifact_state(), state_before)
        self.assertEqual(external.read_text(), "do not touch\n")
        self.assertTrue((self.install_root / ".activation-transaction.tsv").is_file())

    def test_current_and_previous_are_validated_before_retention_and_activation(self):
        self._stage()
        self._activate()
        second_sha = self._commit_main_release(2)
        self._stage(second_sha)
        self._activate(second_sha)

        previous_release = self._release(self.first_sha)
        previous_cli = previous_release / "codexswitch-cli"
        previous_cli.chmod(0o755)
        previous_cli.write_bytes(previous_cli.read_bytes() + b"# tampered\n")

        third_sha = self._commit_main_release(3)
        result = self._stage(third_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release CLI SHA-256 mismatch", result.stderr)
        self.assertFalse(self._release(third_sha).exists())
        self.assertEqual(
            os.readlink(self.install_root / "current"),
            f"releases/{PACKAGE_VERSION}-{second_sha}",
        )

    def test_runtime_is_revalidated_without_restart_and_knowledge_cleanup_is_exact(self):
        next_sha = self._seed_trusted_inactive_runtime()
        self._seed_systemd_state()
        self.tool_log.write_text("")
        self._activate(
            next_sha,
            {"CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS": "1"},
        )
        self.assertFalse((self.service_dir / "codexswitch-knowledge-sync.service").exists())
        self.assertFalse((self.service_dir / "codexswitch-knowledge-sync.timer").exists())
        self.assertTrue((self.service_dir / "unrelated-knowledge-sync.timer").exists())
        self.assertNotIn("disable --now", self.tool_log.read_text())
        self._assert_no_runtime_action()

        active_codex = self._release(next_sha) / "patched-codex" / "codex"
        active_codex.chmod(0o755)
        active_codex.write_bytes(active_codex.read_bytes() + b"# tampered\n")
        self.tool_log.write_text("")
        result = self._activate(next_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release Codex SHA-256 mismatch", result.stderr)
        self._assert_no_runtime_action()


if __name__ == "__main__":
    unittest.main()

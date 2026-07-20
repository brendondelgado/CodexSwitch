import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-macos-app.yml"
INSTALLER = ROOT / "scripts/install-macos-app-artifact.sh"
ARCHITECTURE_DOC = ROOT / "docs/architecture/macos-runtime-artifact.md"
RUNBOOK = ROOT / "docs/runbooks/remote-macos-runtime-build.md"


class MacOsAppArtifactContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.installer = INSTALLER.read_text(encoding="utf-8")

    def test_workflow_is_manual_exact_sha_native_arm64_and_app_only(self) -> None:
        workflow = self.workflow
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("codexswitch_git_sha:", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn('runner_arch="$(uname -m)"', workflow)
        self.assertIn('[[ "$GITHUB_REF" != "refs/heads/main" ]]', workflow)
        self.assertIn('actual_sha="$(git rev-parse HEAD)"', workflow)
        self.assertIn('actual_sha" == "$GITHUB_SHA', workflow)
        self.assertIn('actual_sha" == "$EXPECTED_CODEXSWITCH_SHA', workflow)
        self.assertIn("git status --porcelain --untracked-files=normal", workflow)
        for runtime_member in ("codex-code-mode-host", "codexswitch-cli"):
            self.assertNotIn(runtime_member, workflow)
        self.assertNotIn("cargo build", workflow)

    def test_swift_gate_precedes_deterministic_release_build(self) -> None:
        workflow = self.workflow
        tests = workflow.index("Verify the Swift app and test suite")
        build = workflow.index("Build the deterministic release app")
        package = workflow.index("Validate, package, and round-trip the app")
        self.assertLess(tests, build)
        self.assertLess(build, package)
        swift_gate = workflow[tests:build]
        self.assertIn("swift test --jobs 1 --no-parallel", swift_gate)
        self.assertIn('CODEXSWITCH_TEST_TMPDIR="$test_tmp"', swift_gate)
        self.assertIn('TMPDIR="$test_tmp"', swift_gate)
        self.assertIn('rm -rf -- .build "$test_tmp"', swift_gate)
        build_step = workflow[build:package]
        for setting in (
            "CODEXSWITCH_BUILD_CONFIGURATION=release",
            "CODEXSWITCH_SWIFTPM_JOBS=1",
            'CODEXSWITCH_SOURCE_REVISION="$CODEXSWITCH_SOURCE_SHA"',
            'CODEXSWITCH_BUILD_NUMBER="$SOURCE_DATE_EPOCH"',
            'CODEXSWITCH_VERSION="$APP_VERSION"',
            "CODEXSWITCH_CODESIGN_IDENTITY=-",
            "./scripts/build-app.sh",
        ):
            self.assertIn(setting, build_step)
        self.assertNotIn("--install", build_step)

    def test_bundle_validation_runs_before_and_after_ditto_round_trip(self) -> None:
        workflow = self.workflow
        package = workflow.index("Validate, package, and round-trip the app")
        clean = workflow.index("Revalidate the clean source checkout")
        contract = workflow[package:clean]
        first_validation = contract.index('validate_bundle "$app_bundle"')
        archive = contract.index("/usr/bin/ditto \\")
        extraction = contract.index("-x -k", archive)
        second_validation = contract.index(
            'validate_bundle "$APP_ROUNDTRIP_DIR/CodexSwitch.app"'
        )
        self.assertLess(first_validation, archive)
        self.assertLess(archive, extraction)
        self.assertLess(extraction, second_validation)
        for validation in (
            "CFBundleSourceRevision",
            "CFBundleVersion",
            "CFBundleShortVersionString",
            '"Mach-O 64-bit executable arm64"',
            "codesign --verify --deep --strict",
            '"Signature=adhoc"',
            "cmp -s scripts/patch-asar.py",
            "LINUX_DEVBOX_ACTIVE_PUSH",
            "pendingLinuxDevboxActive",
            "pushLinuxDevboxActiveAccount",
        ):
            self.assertIn(validation, contract)
        self.assertIn("len(entries) > 4096", contract)
        self.assertIn("total > 1073741824", contract)
        self.assertIn("linked or special app archive entry", contract)

    def test_manifest_and_uploaded_member_set_are_exact_and_bounded(self) -> None:
        workflow = self.workflow
        self.assertIn("codexswitch-macos-app-artifact-v1", workflow)
        for field in (
            "codexSwitchGitSha",
            "appVersion",
            "buildEpoch",
            "bundleIdentifier",
            "bundleName",
            "architecture",
            "signing",
            "archive",
            "bundleFiles",
        ):
            self.assertIn(field, workflow)
        for bound in ("65536", "536870912", "268435456", "4194304"):
            self.assertIn(bound, workflow)
        expected_members = (
            "printf '%s\\n' CodexSwitch.app.zip manifest.json",
            "codexswitch-macos-app-artifact/CodexSwitch.app.zip",
            "codexswitch-macos-app-artifact/manifest.json",
        )
        for member_contract in expected_members:
            self.assertIn(member_contract, workflow)
        upload = workflow.index("Upload the verified app artifact")
        self.assertNotIn("codex-code-mode-host", workflow[upload:])
        self.assertNotIn("codexswitch-cli", workflow[upload:])

    def test_every_uploaded_member_is_attested_before_upload_with_pins(self) -> None:
        workflow = self.workflow
        attest = workflow.index("Attest every exact app artifact member")
        upload = workflow.index("Upload the verified app artifact")
        self.assertLess(attest, upload)
        self.assertIn(
            "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
            workflow,
        )
        self.assertIn(
            "actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be",
            workflow[attest:upload],
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            workflow[upload:],
        )
        attestation_block = workflow[attest:upload]
        for name in ("CodexSwitch.app.zip", "manifest.json"):
            self.assertIn(
                f"${{{{ runner.temp }}}}/codexswitch-macos-app-artifact/{name}",
                attestation_block,
            )
        action_uses = re.findall(r"uses:\s+([^\s]+)", workflow)
        self.assertTrue(action_uses)
        for action in action_uses:
            pin = action.rsplit("@", 1)[-1]
            self.assertRegex(pin, r"^[0-9a-f]{40}$")

    def test_installer_completes_all_preactivation_checks_before_quit(self) -> None:
        installer = self.installer
        snapshot = installer.index('> "$snapshot_report"')
        manifest = installer.index('> "$manifest_values"')
        attestation = installer.index('attestation verify "$artifact_dir/$name"')
        preflight = installer.index('import zipfile', attestation)
        extraction = installer.index("/usr/bin/ditto \\", preflight)
        extracted_validation = installer.index('verify_bundle "$validated_bundle"')
        applications_stage = installer.index(
            'mktemp -d /Applications/.codexswitch-app-install.'
        )
        staged_validation = installer.index('verify_bundle "$staged_path"')
        quit_app = installer.index('tell application id "com.codexswitch" to quit')
        self.assertLess(snapshot, manifest)
        self.assertLess(manifest, attestation)
        self.assertLess(attestation, preflight)
        self.assertLess(preflight, extraction)
        self.assertLess(extraction, extracted_validation)
        self.assertLess(extracted_validation, applications_stage)
        self.assertLess(applications_stage, staged_validation)
        self.assertLess(staged_validation, quit_app)
        self.assertGreaterEqual(
            installer[:quit_app].count("verify_frozen_snapshot"), 3
        )

    def test_installer_retires_every_codexswitch_bundle_copy_before_activation(self) -> None:
        installer = self.installer
        self.assertIn("codexswitch_process_pattern=", installer)
        self.assertIn("/CodexSwitch\\.app/Contents/MacOS/CodexSwitch", installer)
        self.assertIn("codexswitch_app_is_running()", installer)
        self.assertIn('tell application id "com.codexswitch" to quit', installer)
        self.assertGreaterEqual(installer.count("codexswitch_app_is_running"), 4)
        self.assertIn("refusing to activate a second bundle copy", installer)

    def test_installer_enforces_snapshot_attestation_and_no_build_or_resign(self) -> None:
        installer = self.installer
        self.assertIn(
            'set(actual) != set(expected)',
            installer,
        )
        self.assertIn("os.O_NOFOLLOW", installer)
        self.assertIn("linked or special app archive entry", installer)
        self.assertIn("duplicate app archive path", installer)
        for policy in (
            '--repo "$trusted_repository"',
            '--signer-workflow "$trusted_workflow"',
            '--signer-digest "$source_sha"',
            "--source-ref refs/heads/main",
            '--source-digest "$source_sha"',
            "--deny-self-hosted-runners",
        ):
            self.assertIn(policy, installer)
        self.assertIn("brendondelgado/CodexSwitch/.github/workflows/build-macos-app.yml", installer)
        self.assertNotIn("swift build", installer)
        self.assertNotIn("cargo build", installer)
        self.assertNotIn("build-app.sh", installer)
        self.assertNotIn("codesign --force", installer)
        self.assertNotIn("codesign --sign", installer)

    def test_installer_has_atomic_swap_and_both_rollback_paths(self) -> None:
        installer = self.installer
        rollback = installer[installer.index("rollback_activation() {") :]
        self.assertIn("local exit_status=$?", installer)
        self.assertIn('return "$exit_status"', installer)
        self.assertNotIn("local status=$?", installer)
        self.assertIn("RENAME_SWAP = 0x00000002", installer)
        self.assertIn('atomic_swap_paths "$install_path" "$staged_path"', rollback)
        self.assertIn('/bin/mv "$install_path" "$failed_path"', rollback)
        self.assertIn('[[ "$activated" != "1" && "$swapped" == "1" ]]', installer)
        swap_commit = installer.rindex("swapped=1")
        installed_validation = installer.index(
            'verify_bundle "$install_path"', swap_commit
        )
        success = installer.index("activated=1", installed_validation)
        self.assertLess(swap_commit, installed_validation)
        self.assertLess(installed_validation, success)
        post_swap = installer[swap_commit:success]
        self.assertGreaterEqual(post_swap.count("rollback_activation || exit 1"), 3)
        self.assertIn("preserve_install_workdir=1", rollback)

    def test_docs_route_the_separate_artifact_and_transactional_installer(self) -> None:
        architecture = ARCHITECTURE_DOC.read_text(encoding="utf-8")
        runbook = RUNBOOK.read_text(encoding="utf-8")
        for document in (architecture, runbook):
            self.assertTrue(document.startswith("---\n"))
            self.assertIn("toc:", document)
            self.assertIn("cross_dependencies:", document)
            self.assertIn("version_control:", document)
            self.assertIn("last_updated: 2026-07-20", document)
        self.assertIn("## App Artifact Boundary", architecture)
        self.assertIn("codexswitch-macos-app-artifact-v1", architecture)
        self.assertIn("## App Installation", architecture)
        self.assertIn("## App-Only Artifact", runbook)
        self.assertIn("## Download And Install The App", runbook)


if __name__ == "__main__":
    unittest.main()

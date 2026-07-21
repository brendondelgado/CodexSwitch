import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-linux-runtime.yml"


class LinuxRuntimeWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def block(self, start: str, end: str) -> str:
        start_index = self.workflow.index(start)
        end_index = self.workflow.index(end, start_index)
        return self.workflow[start_index:end_index]

    def test_dispatch_is_main_only_and_binds_exact_inputs(self) -> None:
        gate = self.block(
            "Require a main-branch dispatch with exact inputs",
            "Require the native Ubuntu x86_64 runner",
        )
        self.assertIn('"refs/heads/main"', gate)
        self.assertIn('"branch"', gate)
        self.assertIn("github.ref_type", gate)
        self.assertIn("^[0-9a-f]{40}$", gate)
        self.assertIn("^[0-9]+\\.[0-9]+\\.[0-9]+$", gate)
        self.assertIn('"$EXPECTED_CODEXSWITCH_SHA" != "$GITHUB_SHA"', gate)

        checkout = self.block(
            "Check out the exact dispatched CodexSwitch commit",
            "Lock CodexSwitch provenance",
        )
        self.assertIn(
            "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
            checkout,
        )
        self.assertIn("ref: ${{ inputs.codexswitch_git_sha }}", checkout)
        self.assertIn("persist-credentials: false", checkout)

    def test_builds_both_exact_sources_for_native_linux_x86_64_with_one_job(self) -> None:
        self.assertIn("runs-on: ubuntu-24.04", self.workflow)
        self.assertIn("TARGET_TRIPLE: x86_64-unknown-linux-gnu", self.workflow)
        self.assertIn('CARGO_BUILD_JOBS: "1"', self.workflow)
        self.assertIn('runner_arch" != "x86_64"', self.workflow)
        self.assertEqual(self.workflow.count("cargo build \\\n"), 2)
        self.assertEqual(
            self.workflow.count('--jobs "$CARGO_BUILD_JOBS"'),
            2,
        )
        for package in ("-p codexswitch-cli", "-p codex-cli", "-p codex-code-mode-host"):
            self.assertIn(package, self.workflow)
        self.assertIn(
            "Tests/Fixtures/BuildFork/patch_codex_source.rs",
            self.workflow,
        )
        self.assertIn('"${tag_ref}^{commit}"', self.workflow)
        self.assertIn('"$peeled_upstream_sha" != "$EXPECTED_UPSTREAM_CODEX_SHA"', self.workflow)
        self.assertIn("Revalidate both source trees after compilation", self.workflow)

    def test_provenance_and_cache_identity_bind_all_effective_sources(self) -> None:
        self.assertIn('SOURCE_DATE_EPOCH=%s\\n', self.workflow)
        self.assertIn(
            'expected_version="codexswitch-cli ${package_version} '
            '(git ${CODEXSWITCH_SOURCE_SHA}, built ${SOURCE_DATE_EPOCH})"',
            self.workflow,
        )
        self.assertIn("diff --binary --full-index --no-ext-diff HEAD", self.workflow)
        self.assertIn("Normalize patched upstream source mtimes", self.workflow)
        abi = self.block(
            "Derive exact upstream target cache ABI",
            "Restore exact upstream Cargo target cache",
        )
        for value in (
            "rustc -Vv",
            "cargo -V",
            "cat /etc/os-release",
            "cc --version",
            "ld --version",
            "ldd --version",
            "TARGET_TRIPLE",
            "UPSTREAM_SHA",
            "PATCH_SHA256",
            "CODEXSWITCH_SOURCE_SHA",
            "SOURCE_DATE_EPOCH",
            "CARGO_BUILD_JOBS",
        ):
            self.assertIn(value, abi)

    def test_validates_elf_version_install_commands_and_current_markers(self) -> None:
        validation = self.block(
            "Validate Linux architecture and runtime contracts",
            "Generate and verify the canonical SHA-256 manifest",
        )
        for value in (
            "ELF 64-bit LSB",
            "Advanced Micro Devices X86-64",
            '"codex-cli $UPSTREAM_CODEX_VERSION"',
            'timeout 10 "$ARTIFACT_DIR/codex" app-server --help',
            "import --help",
            "daemon --help",
            "resolve-activation --help",
        ):
            self.assertIn(value, validation)

        required_markers = (
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
            "codexswitch-hotswap-headless-idle-v1",
            "codexswitch-hotswap-cli-contract-v3",
        )
        for marker in required_markers:
            self.assertIn(f'"{marker}"', validation)
        self.assertIn('"Usage: /goal <objective>"', validation)
        self.assertIn('"Pursuing goal"', validation)
        self.assertIn('"thread/goal/set"', validation)

    def test_manifest_and_upload_are_an_exact_bounded_four_file_artifact(self) -> None:
        manifest = self.block(
            "Generate and verify the canonical SHA-256 manifest",
            "Attest all exact Linux runtime artifact members",
        )
        for value in (
            "codexswitch-linux-runtime-artifact-v1",
            "codexSwitchGitSha",
            "codexSwitchBuildVersion",
            "upstreamCodexVersion",
            "upstreamCodexGitSha",
            "sourcePatchSha256",
            'targetTriple == "x86_64-unknown-linux-gnu"',
            'architecture == "x86_64"',
            "sha256sum",
            "2147483648",
            "65536",
            "artifact_bytes=$((codex_bytes + helper_bytes + control_bytes + manifest_bytes))",
            "complete artifact exceeds the 2 GiB release limit",
            "find -P",
            "-printf '%f\\t%y\\n'",
        ):
            self.assertIn(value, manifest)

        names = ("codex", "codex-code-mode-host", "codexswitch-cli", "manifest.json")
        attestation = self.block(
            "Attest all exact Linux runtime artifact members",
            "Upload only the verified four-file Linux runtime artifact",
        )
        upload = self.block(
            "Upload only the verified four-file Linux runtime artifact",
            "Record build evidence",
        )
        self.assertIn(
            "actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be",
            attestation,
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            upload,
        )
        attestation_lines = [line.strip() for line in attestation.splitlines()]
        upload_lines = [line.strip() for line in upload.splitlines()]
        for name in names:
            path = f"${{{{ runner.temp }}}}/codexswitch-linux-runtime-artifact/{name}"
            self.assertEqual(attestation_lines.count(path), 1)
            self.assertEqual(upload_lines.count(path), 1)
        self.assertNotIn("codexswitch-linux-runtime-artifact/\n", upload)

    def test_permissions_actions_and_non_deployment_boundary_are_narrow(self) -> None:
        permissions = self.block("permissions:", "concurrency:")
        self.assertEqual(
            {
                line.strip()
                for line in permissions.splitlines()
                if ":" in line and line.strip() != "permissions:"
            },
            {"attestations: write", "contents: read", "id-token: write"},
        )
        uses = re.findall(
            r"(?m)^\s*uses:\s*([^\s#]+)(?:\s+#.*)?$",
            self.workflow,
        )
        self.assertGreater(len(uses), 0)
        for action in uses:
            self.assertRegex(action, r"^[^@]+@[0-9a-f]{40}$")
        for forbidden in ("ssh ", "scp ", "rsync ", "systemctl ", "install-linux.sh"):
            self.assertNotIn(forbidden, self.workflow)


if __name__ == "__main__":
    unittest.main()

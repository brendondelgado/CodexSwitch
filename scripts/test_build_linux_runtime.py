import copy
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-linux-runtime.yml"
REUSE_STEP = "Reuse an attested unchanged upstream Linux codex"


def workflow_step(name: str) -> str:
    return WORKFLOW.read_text(encoding="utf-8").split(
        f"      - name: {name}\n", 1
    )[1].split("      - name:", 1)[0]


def step_script(name: str) -> str:
    return textwrap.dedent(workflow_step(name).split("        run: |\n", 1)[1])


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

    def test_builds_patched_cli_and_fetches_exact_official_helper(self) -> None:
        self.assertIn("runs-on: ubuntu-24.04", self.workflow)
        self.assertIn("TARGET_TRIPLE: x86_64-unknown-linux-gnu", self.workflow)
        self.assertIn('CARGO_BUILD_JOBS: "1"', self.workflow)
        self.assertIn('runner_arch" != "x86_64"', self.workflow)
        self.assertEqual(self.workflow.count("cargo build \\\n"), 2)
        self.assertEqual(
            self.workflow.count('--jobs "$CARGO_BUILD_JOBS"'),
            2,
        )
        for package in ("-p codexswitch-cli", "-p codex-cli"):
            self.assertIn(package, self.workflow)
        self.assertNotIn("-p codex-code-mode-host", self.workflow)
        self.assertIn(
            "Tests/Fixtures/BuildFork/patch_codex_source.rs",
            self.workflow,
        )
        self.assertIn('"${tag_ref}^{commit}"', self.workflow)
        self.assertIn('"$peeled_upstream_sha" != "$EXPECTED_UPSTREAM_CODEX_SHA"', self.workflow)
        self.assertIn("Revalidate both source trees after compilation", self.workflow)

        helper = self.block(
            "Fetch the exact official Linux code-mode host",
            "Revalidate both source trees after compilation",
        )
        for value in (
            'helper_triple="x86_64-unknown-linux-musl"',
            'release_tag="rust-v${UPSTREAM_CODEX_VERSION}"',
            "/repos/openai/codex/releases/tags/${release_tag}",
            ".draft == false",
            ".prerelease == false",
            'test("^sha256:[0-9a-f]{64}$")',
            'if [[ "$helper_url" != "$expected_url" ]]',
            'stat -c \'%s\' "$helper_archive"',
            'sha256sum "$helper_archive"',
            'tar -tzf "$helper_archive"',
            '"codex-code-mode-host-${helper_triple}"',
        ):
            self.assertIn(value, helper)

    def test_provenance_and_cache_identity_bind_all_effective_sources(self) -> None:
        self.assertIn('SOURCE_DATE_EPOCH=%s\\n', self.workflow)
        self.assertIn(
            'expected_version="codexswitch-cli ${package_version} '
            '(git ${CODEXSWITCH_SOURCE_SHA}, built ${SOURCE_DATE_EPOCH})"',
            self.workflow,
        )
        self.assertIn("diff --binary --full-index --no-ext-diff HEAD", self.workflow)
        self.assertIn("Normalize patched upstream source mtimes", self.workflow)
        checkout = self.block(
            "Check out the exact peeled upstream Codex tag",
            "Apply the exact-commit source patches",
        )
        self.assertIn(
            'upstream_epoch="$(git -C "$UPSTREAM_SOURCE_DIR" show -s '
            '--format=%ct "$peeled_upstream_sha")"',
            checkout,
        )
        self.assertIn('"$upstream_epoch" == "0"', checkout)
        self.assertIn("printf 'epoch=%s\\n' \"$upstream_epoch\"", checkout)

        normalize = self.block(
            "Normalize patched upstream source mtimes",
            "Derive exact upstream target cache ABI",
        )
        self.assertIn(
            "UPSTREAM_SOURCE_DATE_EPOCH: ${{ steps.upstream.outputs.epoch }}",
            normalize,
        )
        self.assertIn('--date="@$UPSTREAM_SOURCE_DATE_EPOCH"', normalize)

        abi = self.block(
            "Derive exact upstream target cache ABI",
            "Restore exact upstream Cargo target cache",
        )
        self.assertIn(
            "format=codexswitch-linux-upstream-target-cache-abi-v2",
            abi,
        )
        self.assertIn(
            "UPSTREAM_SOURCE_DATE_EPOCH: ${{ steps.upstream.outputs.epoch }}",
            abi,
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
            "UPSTREAM_SOURCE_DATE_EPOCH",
            "upstreamSourceDateEpoch",
            "CARGO_BUILD_JOBS",
        ):
            self.assertIn(value, abi)
        self.assertNotIn("codexSwitchSha", abi)
        self.assertNotIn(
            'printf \'sourceDateEpoch=%s\\n\' "$SOURCE_DATE_EPOCH"',
            abi,
        )

        upstream_build = self.block(
            "Build the patched Codex CLI runtime",
            "Revalidate both source trees after compilation",
        )
        self.assertIn(
            "SOURCE_DATE_EPOCH: ${{ steps.upstream.outputs.epoch }}",
            upstream_build,
        )
        self.assertEqual(
            self.workflow.count("${{ steps.upstream.outputs.epoch }}"),
            3,
        )
        self.assertIn('--argjson buildEpoch "$SOURCE_DATE_EPOCH"', self.workflow)

    def test_target_cache_restore_is_exact_and_save_is_validation_gated(self) -> None:
        target_key = (
            "linux-runtime-target-v2-${{ runner.arch }}-"
            "${{ steps.target_cache_abi.outputs.sha256 }}-"
            "${{ steps.upstream.outputs.sha }}-"
            "${{ steps.patches.outputs.sha256 }}"
        )
        restore = self.block(
            "Restore exact upstream Cargo target cache",
            "Build the patched Codex CLI runtime",
        )
        self.assertIn("continue-on-error: true", restore)
        self.assertIn("${{ runner.temp }}/codex-linux-target/", restore)
        self.assertIn(target_key, restore)
        self.assertNotIn("${{ steps.provenance.outputs.source_sha }}", restore)
        self.assertNotIn("restore-keys:", restore)

        source_validation = self.workflow.index(
            "Revalidate both source trees after compilation"
        )
        binary_validation = self.workflow.index(
            "Validate Linux architecture and runtime contracts"
        )
        manifest = self.workflow.index(
            "Generate and verify the canonical SHA-256 manifest"
        )
        attestation = self.workflow.index(
            "Attest all exact Linux runtime artifact members"
        )
        upload = self.workflow.index(
            "Upload only the verified four-file Linux runtime artifact"
        )
        evidence = self.workflow.index("Record build evidence")
        target_save = self.workflow.index(
            "Save verified upstream Cargo target cache"
        )
        target_cleanup = self.workflow.index(
            "Remove ephemeral upstream Cargo target"
        )
        self.assertLess(source_validation, binary_validation)
        self.assertLess(binary_validation, manifest)
        self.assertLess(manifest, attestation)
        self.assertLess(attestation, upload)
        self.assertLess(upload, evidence)
        self.assertLess(evidence, target_save)
        self.assertLess(target_save, target_cleanup)

        save = self.workflow[target_save:target_cleanup]
        self.assertIn(
            "if: ${{ success() && inputs.base_runtime_run_id == '' && steps.upstream_target_cache.outputs.cache-hit != 'true' }}",
            save,
        )
        self.assertIn("continue-on-error: true", save)
        self.assertIn("${{ runner.temp }}/codex-linux-target/", save)
        self.assertIn(target_key, save)
        self.assertNotIn("${{ steps.provenance.outputs.source_sha }}", save)
        self.assertNotIn("restore-keys:", save)
        self.assertEqual(self.workflow.count(target_key), 2)

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
            {"actions: read", "attestations: write", "contents: read", "id-token: write"},
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

    def test_reuse_skips_only_upstream_build_and_target_cache(self) -> None:
        for name in (
            "Derive exact upstream target cache ABI",
            "Restore exact upstream Cargo target cache",
            "Build the patched Codex CLI runtime",
        ):
            self.assertIn("if: ${{ inputs.base_runtime_run_id == '' }}", workflow_step(name))
        self.assertIn("if: ${{ inputs.base_runtime_run_id != '' }}", workflow_step(REUSE_STEP))
        self.assertNotIn("continue-on-error", workflow_step(REUSE_STEP))
        for name in (
            "Build the exact CodexSwitch control plane",
            "Compile the exact-commit source patch driver",
            "Check out the exact peeled upstream Codex tag",
            "Apply the exact-commit source patches",
            "Fetch the exact official Linux code-mode host",
            "Revalidate both source trees after compilation",
            "Stage the exact runtime executables",
            "Validate Linux architecture and runtime contracts",
            "Generate and verify the canonical SHA-256 manifest",
            "Attest all exact Linux runtime artifact members",
            "Upload only the verified four-file Linux runtime artifact",
        ):
            self.assertNotIn("        if:", workflow_step(name), name)
        self.assertLess(self.workflow.index("Apply the exact-commit source patches"), self.workflow.index(REUSE_STEP))
        self.assertLess(self.workflow.index(REUSE_STEP), self.workflow.index("Validate Linux architecture and runtime contracts"))
        for binding in (
            "EXPECTED_UPSTREAM_SHA: ${{ steps.upstream.outputs.sha }}",
            "EXPECTED_PATCH_SHA256: ${{ steps.patches.outputs.sha256 }}",
        ):
            self.assertIn(binding, workflow_step(REUSE_STEP))
        manifest = workflow_step("Generate and verify the canonical SHA-256 manifest")
        self.assertIn('--arg sourceSha "$CODEXSWITCH_SOURCE_SHA"', manifest)
        self.assertIn('--arg buildVersion "$CONTROL_BUILD_VERSION"', manifest)
        self.assertNotIn("base_runtime", manifest)
        evidence = workflow_step("Record build evidence")
        self.assertIn("${{ steps.reuse.outputs.source_sha }}", evidence)
        self.assertIn("${{ steps.reuse.outputs.artifact_name }}", evidence)


@unittest.skipUnless(shutil.which("jq"), "jq is required for workflow shell fixtures")
class LinuxRuntimeReuseFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="linux-runtime-reuse-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.base = self.root / "base"
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        self.output = self.root / "output"
        self.output.mkdir()
        self.controller = self.output / "codexswitch-cli"
        self.controller.write_bytes(b"new exact-SHA controller, never replaced")
        self.source_sha = "b" * 40
        self.repository = "brendondelgado/CodexSwitch"
        self.run = {
            "id": 33913698437,
            "run_attempt": 2,
            "repository": {"full_name": self.repository},
            "head_repository": {"full_name": self.repository},
            "path": ".github/workflows/build-linux-runtime.yml",
            "event": "workflow_dispatch",
            "head_branch": "main",
            "status": "completed",
            "conclusion": "success",
            "head_sha": self.source_sha,
        }
        self.comparison = {
            "status": "ahead",
            "base_commit": {"sha": self.source_sha},
            "merge_base_commit": {"sha": self.source_sha},
        }
        self.manifest = {
            "format": "codexswitch-linux-runtime-artifact-v1",
            "codexSwitchGitSha": self.source_sha,
            "codexSwitchBuildVersion": f"codexswitch-cli 1.0.0 (git {self.source_sha}, built 123)",
            "upstreamCodexVersion": "0.144.4",
            "upstreamCodexGitSha": "c" * 40,
            "sourcePatchSha256": "d" * 64,
            "targetTriple": "x86_64-unknown-linux-gnu",
            "architecture": "x86_64",
            "buildEpoch": 123,
            "files": [],
        }
        for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
            payload = f"old {name}: fixture data, not executable\n".encode()
            (self.artifact / name).write_bytes(payload)
            self.manifest["files"].append({
                "name": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()
            })
        self.env = {
            **os.environ,
            "RUNNER_TEMP": str(self.root),
            "BASE_ARTIFACT_DIR": str(self.base),
            "ARTIFACT_DIR": str(self.output),
            "GITHUB_OUTPUT": str(self.root / "github-output"),
            "GITHUB_RUN_ID": "33913698438",
            "BASE_RUNTIME_RUN_ID": str(self.run["id"]),
            "CODEXSWITCH_SOURCE_SHA": "a" * 40,
            "EXPECTED_UPSTREAM_SHA": self.manifest["upstreamCodexGitSha"],
            "EXPECTED_PATCH_SHA256": self.manifest["sourcePatchSha256"],
            "UPSTREAM_CODEX_VERSION": self.manifest["upstreamCodexVersion"],
            "FAIL_GH": "",
            "FAIL_ATTESTATION": "",
        }
        # Intercept only GitHub; execute the real workflow shell, jq, and artifact verifier.
        self.gh_stub = r'''
        gh() {
          printf '%s\n' "$*" >> "$RUNNER_TEMP/gh-calls"
          case "$1 $2" in
            "api /repos/brendondelgado/CodexSwitch/actions/runs/$BASE_RUNTIME_RUN_ID")
              [[ "$FAIL_GH" != "run" ]] || return 1
              cat "$RUNNER_TEMP/run.json" ;;
            "api /repos/brendondelgado/CodexSwitch/compare/"*)
              [[ "$FAIL_GH" != "compare" ]] || return 1
              cat "$RUNNER_TEMP/comparison.json" ;;
            "run download")
              [[ "$FAIL_GH" != "download" ]] || return 1
              cp -R "$RUNNER_TEMP/artifact/." "$BASE_ARTIFACT_DIR/" ;;
            "attestation verify")
              [[ "${3##*/}" != "$FAIL_ATTESTATION" ]] ;;
            *) return 99 ;;
          esac
        }
        '''

    def run_reuse(self) -> subprocess.CompletedProcess:
        for name, value in (("run.json", self.run), ("comparison.json", self.comparison)):
            (self.root / name).write_text(json.dumps(value), encoding="utf-8")
        (self.artifact / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")
        if self.base.exists():
            shutil.rmtree(self.base)
        return subprocess.run(
            ["bash", "-c", textwrap.dedent(self.gh_stub) + step_script(REUSE_STEP)],
            cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=15,
        )

    def assert_rejected(self, message: str = "") -> None:
        result = self.run_reuse()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        self.assertFalse((self.output / "codex").exists())
        self.assertEqual(self.controller.read_bytes(), b"new exact-SHA controller, never replaced")
        self.assertFalse((self.root / "github-output").exists())

    def test_valid_reuse_pins_attestations_and_copies_only_codex(self) -> None:
        result = self.run_reuse()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.output / "codex").read_bytes(), (self.artifact / "codex").read_bytes())
        self.assertEqual((self.output / "codex").stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.controller.read_bytes(), b"new exact-SHA controller, never replaced")
        self.assertEqual({p.name for p in self.output.iterdir()}, {"codex", "codexswitch-cli"})
        calls = (self.root / "gh-calls").read_text().splitlines()
        expected_name = f"codexswitch-linux-x86_64-runtime-{self.source_sha[:12]}-codex-0.144.4-run-33913698437-2"
        self.assertIn(f"api /repos/{self.repository}/compare/{self.source_sha}...{'a' * 40}", calls)
        self.assertIn(f"run download 33913698437 --repo {self.repository} --name {expected_name} --dir {self.base}", calls)
        self.assertEqual(calls[3:], [
            f"attestation verify {self.base / name} --repo {self.repository} "
            f"--signer-workflow {self.repository}/.github/workflows/build-linux-runtime.yml "
            f"--signer-digest {self.source_sha} --source-ref refs/heads/main "
            f"--source-digest {self.source_sha} --deny-self-hosted-runners"
            for name in ("manifest.json", "codex", "codex-code-mode-host", "codexswitch-cli")
        ])
        self.assertIn(f"artifact_name={expected_name}", (self.root / "github-output").read_text())

    def test_full_build_and_reuse_stage_fresh_helper_and_preserve_new_controller(self) -> None:
        target = self.root / "target"
        compiled_codex = target / "x86_64-unknown-linux-gnu/release/codex"
        compiled_codex.parent.mkdir(parents=True)
        compiled_codex.write_bytes(b"newly compiled upstream fixture")
        compiled_codex.chmod(0o755)
        helper_dir = self.root / "official-helper"
        helper_dir.mkdir()
        helper = helper_dir / "codex-code-mode-host-x86_64-unknown-linux-musl"
        helper.write_bytes(b"freshly verified official helper fixture")
        for run_id in ("", "33913698437"):
            with self.subTest(run_id=run_id):
                if run_id:
                    reused = self.run_reuse()
                    self.assertEqual(reused.returncode, 0, reused.stdout + reused.stderr)
                result = subprocess.run(
                    ["bash", "-c", step_script("Stage the exact runtime executables")],
                    env={
                        **self.env, "BASE_RUNTIME_RUN_ID": run_id,
                        "UPSTREAM_TARGET_DIR": str(target),
                        "TARGET_TRIPLE": "x86_64-unknown-linux-gnu",
                        "OFFICIAL_HELPER_DIR": str(helper_dir),
                    },
                    text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                expected_codex = self.artifact / "codex" if run_id else compiled_codex
                self.assertEqual((self.output / "codex").read_bytes(), expected_codex.read_bytes())
                self.assertEqual((self.output / "codex-code-mode-host").read_bytes(), helper.read_bytes())
                self.assertEqual(self.controller.read_bytes(), b"new exact-SHA controller, never replaced")
                self.assertFalse((self.output / "manifest.json").exists())

    def test_rejects_failed_foreign_or_non_main_runs(self) -> None:
        original = copy.deepcopy(self.run)
        for key, value in (
            ("id", 33913698436), ("status", "in_progress"), ("conclusion", "failure"),
            ("event", "pull_request"), ("head_branch", "feature"),
            ("repository", {"full_name": "untrusted/CodexSwitch"}),
            ("head_repository", {"full_name": "untrusted/CodexSwitch"}),
            ("path", ".github/workflows/build-fork.yml"), ("head_sha", "b14cca5"),
            ("run_attempt", 0), ("run_attempt", 1.5),
        ):
            with self.subTest(key=key, value=value):
                self.run = {**original, key: value}
                self.assert_rejected("earlier successful main dispatch")
        self.run = original
        self.env["GITHUB_RUN_ID"] = str(self.run["id"])
        self.assert_rejected("earlier successful main dispatch")

    def test_rejects_unreviewed_source_ancestry(self) -> None:
        original = copy.deepcopy(self.comparison)
        for key, value in (
            ("status", "diverged"), ("status", "behind"),
            ("base_commit", {"sha": "e" * 40}),
            ("merge_base_commit", {"sha": "e" * 40}),
        ):
            with self.subTest(key=key, value=value):
                self.comparison = {**original, key: value}
                self.assert_rejected("not an ancestor")

    def test_rejects_prior_manifest_provenance_and_source_identity_mismatch(self) -> None:
        original = copy.deepcopy(self.manifest)
        for key, value in (
            ("codexSwitchGitSha", "e" * 40), ("upstreamCodexVersion", "0.144.5"),
            ("upstreamCodexGitSha", "e" * 40), ("sourcePatchSha256", "e" * 64),
            ("targetTriple", "x86_64-unknown-linux-musl"), ("architecture", "arm64"),
            ("format", "codexswitch-macos-runtime-artifact-v1"),
        ):
            with self.subTest(key=key):
                self.manifest = {**original, key: value}
                if key == "codexSwitchGitSha":
                    self.manifest["codexSwitchBuildVersion"] = f"codexswitch-cli 1.0.0 (git {value}, built 123)"
                self.assert_rejected()

    def test_rejects_tampered_members_and_inventory(self) -> None:
        for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
            with self.subTest(member=name):
                path = self.artifact / name
                original = path.read_bytes()
                path.write_bytes(original + b"tampered")
                self.assert_rejected("identity mismatch")
                path.write_bytes(original)
        (self.artifact / "extra").write_bytes(b"unexpected")
        self.assert_rejected("exactly three executables")
        (self.artifact / "extra").unlink()
        (self.artifact / "codex").unlink()
        (self.artifact / "codex").symlink_to(self.controller)
        self.assert_rejected()

    def test_attestation_or_github_failure_never_falls_back(self) -> None:
        for member in ("manifest.json", "codex", "codex-code-mode-host", "codexswitch-cli"):
            with self.subTest(attestation=member):
                self.env["FAIL_ATTESTATION"] = member
                self.assert_rejected()
        self.env["FAIL_ATTESTATION"] = ""
        for operation in ("run", "compare", "download"):
            with self.subTest(github=operation):
                self.env["FAIL_GH"] = operation
                self.assert_rejected()

    def test_dispatch_accepts_empty_or_exact_run_id_only(self) -> None:
        env = {
            **self.env, "DISPATCH_REF": "refs/heads/main", "DISPATCH_REF_TYPE": "branch",
            "EXPECTED_CODEXSWITCH_SHA": "a" * 40, "GITHUB_SHA": "a" * 40,
            "EXPECTED_UPSTREAM_CODEX_SHA": "c" * 40,
        }
        for run_id in ("", "33913698437", "0", "-1", "1.5", " 33913698437", "01", "b14cca5", "1; true"):
            with self.subTest(run_id=run_id):
                result = subprocess.run(
                    ["bash", "-c", step_script("Require a main-branch dispatch with exact inputs")],
                    env={**env, "BASE_RUNTIME_RUN_ID": run_id}, text=True,
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode == 0, run_id in ("", "33913698437"))


if __name__ == "__main__":
    unittest.main()

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-fork.yml"
INSTALLER = ROOT / "scripts/install-macos-cli-artifact.sh"
BUILD_RS = ROOT / "crates/codexswitch-cli/build.rs"
ACTIVATION = ROOT / "crates/codexswitch-cli/src/codex_update/macos_activation.rs"
SOURCE_PATCHING = ROOT / "crates/codexswitch-cli/src/codex_update/source_patching.rs"
SOURCE_CARGO_PATCHING = (
    ROOT / "crates/codexswitch-cli/src/codex_update/source_cargo_patching.rs"
)
VERIFIER = ROOT / "scripts/verify_macos_runtime_artifact.py"


class MacOsRuntimeArtifactContractTests(unittest.TestCase):
    def write_artifact(self, directory: pathlib.Path) -> None:
        payloads = {
            "codex": b"codex-runtime\n",
            "codex-code-mode-host": b"code-mode-host\n",
            "codexswitch-cli": b"control-plane\n",
        }
        files = []
        for name, payload in payloads.items():
            (directory / name).write_bytes(payload)
            files.append(
                {
                    "name": name,
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
        manifest = {
            "format": "codexswitch-macos-runtime-artifact-v1",
            "codexSwitchGitSha": "1" * 40,
            "codexSwitchBuildVersion": (
                "codexswitch-cli 0.1.0 (git " + "1" * 40 + ", built 1783915200)"
            ),
            "upstreamCodexVersion": "0.144.3",
            "upstreamCodexGitSha": "2" * 40,
            "sourcePatchSha256": "3" * 64,
            "targetTriple": "aarch64-apple-darwin",
            "architecture": "arm64",
            "buildEpoch": 1_783_915_200,
            "files": files,
        }
        (directory / "manifest.json").write_text(
            json.dumps(manifest, sort_keys=True), encoding="utf-8"
        )

    def test_workflow_attests_every_exact_member_with_narrow_permissions(self) -> None:
        workflow = WORKFLOW.read_text()
        self.assertIn("attestations: write", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn(
            "actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be",
            workflow,
        )
        attestation = workflow.index("Attest all exact runtime artifact members")
        upload = workflow.index("Upload the verified runtime artifact")
        self.assertLess(attestation, upload)
        for name in ("codex", "codex-code-mode-host", "codexswitch-cli", "manifest.json"):
            self.assertIn(
                f"${{{{ runner.temp }}}}/codexswitch-macos-runtime-artifact/{name}",
                workflow[attestation:upload],
            )

    def test_workflow_serializes_swift_tests_in_a_private_temp_root(self) -> None:
        workflow = WORKFLOW.read_text()
        verify_step = workflow.index("Verify the Swift app and test suite")
        build_step = workflow.index("Build the CodexSwitch control plane")
        swift_gate = workflow[verify_step:build_step]

        self.assertIn(
            'test_tmp="$RUNNER_TEMP/codexswitch-swift-tests-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"',
            swift_gate,
        )
        self.assertIn('install -d -m 0700 "$test_tmp"', swift_gate)
        self.assertIn(
            'CODEXSWITCH_TEST_TMPDIR="$test_tmp"',
            swift_gate,
        )
        self.assertIn(
            'TMPDIR="$test_tmp"',
            swift_gate,
        )
        self.assertIn(
            'swift test --jobs 1 --no-parallel',
            swift_gate,
        )
        self.assertIn('rm -rf -- .build "$test_tmp"', swift_gate)

    def test_workflow_uses_failure_safe_remote_cargo_cache(self) -> None:
        workflow = WORKFLOW.read_text()
        restore = workflow.index("Restore remote Cargo cache")
        build = workflow.index("Build the patched Codex runtime pair")
        save = workflow.index("Save remote Cargo cache")

        self.assertLess(restore, build)
        self.assertLess(build, save)
        self.assertIn(
            "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            workflow[restore:build],
        )
        self.assertIn(
            "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            workflow[save:],
        )
        self.assertIn("${{ runner.temp }}/codex-target/", workflow[restore:build])
        self.assertIn("${{ inputs.upstream_codex_git_sha }}", workflow[restore:build])
        self.assertIn("${{ github.sha }}", workflow[restore:build])
        self.assertIn(
            "if: ${{ always() && steps.cargo_cache.outputs.cache-hit != 'true' }}",
            workflow[save:],
        )
        self.assertGreaterEqual(workflow.count("continue-on-error: true"), 2)

    def test_manifest_binds_full_source_upstream_and_patch_provenance(self) -> None:
        workflow = WORKFLOW.read_text()
        activation = ACTIVATION.read_text()
        self.assertIn('expected_provenance="git ${CODEXSWITCH_SOURCE_SHA}, built', workflow)
        self.assertNotIn('expected_provenance="git ${CODEXSWITCH_SOURCE_SHA:0:12}', workflow)
        for field in ("upstreamCodexGitSha", "sourcePatchSha256"):
            self.assertIn(field, workflow)
        self.assertIn('git_output(&repository, &["rev-parse", "HEAD"])', BUILD_RS.read_text())
        self.assertIn("upstream_codex_git_sha", activation)
        self.assertIn("source_patch_sha256", activation)
        post_build = workflow.index("Revalidate both source trees after compilation")
        manifest = workflow.index("Generate and verify the canonical manifest")
        self.assertLess(post_build, manifest)
        self.assertIn('git diff --quiet --exit-code', workflow[post_build:manifest])
        self.assertIn('diff --cached --quiet --exit-code', workflow[post_build:manifest])
        self.assertIn('diff --binary HEAD', workflow[post_build:manifest])
        self.assertIn('observed_patch_sha256=', workflow[post_build:manifest])
        self.assertIn('!= "$EXPECTED_PATCH_SHA256"', workflow[post_build:manifest])

    def test_source_patch_updates_direct_dependencies_and_lockfile_together(self) -> None:
        workflow = WORKFLOW.read_text()
        build_step = workflow.index("Build the patched Codex runtime pair")
        revalidation_step = workflow.index("Revalidate both source trees after compilation")
        build_contract = workflow[build_step:revalidation_step]
        source_patching = SOURCE_PATCHING.read_text()
        source_cargo_patching = SOURCE_CARGO_PATCHING.read_text()

        self.assertIn('source_dir.join("codex-rs/Cargo.toml")', source_patching)
        self.assertIn('source_dir.join("codex-rs/Cargo.lock")', source_patching)
        self.assertIn(
            "patch_placeholder_workspace_lock_versions_if_present",
            source_patching,
        )
        for package in ("codex-app-server", "codex-login"):
            self.assertIn(
                f'patch_lockfile_dependency_if_present(&lockfile, "{package}", "libc")',
                source_patching,
            )
        self.assertIn("[workspace.package]", source_cargo_patching)
        self.assertIn('placeholder = "\\nversion = \\"0.0.0\\"\\n"', source_cargo_patching)
        self.assertIn('!package.contains("\\nsource = ")', source_cargo_patching)
        self.assertIn("dependencies.sort();", source_cargo_patching)
        self.assertIn("dependencies.dedup();", source_cargo_patching)
        self.assertIn("--locked", build_contract)

    def test_installer_verifies_attestations_before_one_activation(self) -> None:
        installer = INSTALLER.read_text()
        snapshot = installer.index('"$artifact_verifier" snapshot')
        attestation = installer.index('attestation verify "$artifact_dir/$name"')
        version_probe = installer.index('[[ "$("$control_cli" --version)"')
        activation = installer.index('"$control_cli" activate-macos-runtime-artifact')
        self.assertLess(snapshot, attestation)
        self.assertLess(attestation, version_probe)
        self.assertLess(version_probe, activation)
        self.assertIn("verify_frozen_snapshot", installer[attestation:activation])
        self.assertIn('cmp -s "$installed_cli" "$control_cli"', installer)
        self.assertIn('report.get("installedArtifactManifestSha256")', installer)
        self.assertNotIn('report.get("preparedArtifactManifestSha256")', installer)
        self.assertNotIn('attestation verify "$download_dir/', installer)
        self.assertNotIn('--directory "$download_dir"', installer)
        self.assertEqual(installer.count('"$control_cli" activate-macos-runtime-artifact'), 1)
        self.assertNotIn('"$control_cli" stage-macos-runtime-artifact', installer)
        self.assertNotIn('"$control_cli" install-prepared-codex', installer)
        for policy in (
            '--repo "$trusted_repository"',
            '--signer-workflow "$trusted_workflow"',
            '--signer-digest "$source_sha"',
            "--source-ref refs/heads/main",
            '--source-digest "$source_sha"',
            "--deny-self-hosted-runners",
        ):
            self.assertIn(policy, installer)

    def test_private_snapshot_is_frozen_and_independent_of_download_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            destination = root / "snapshot"
            source.mkdir()
            self.write_artifact(source)

            snapshot_report = subprocess.run(
                [
                    sys.executable,
                    os.fspath(VERIFIER),
                    "snapshot",
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(destination),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            (source / "codexswitch-cli").write_bytes(b"changed after snapshot\n")
            verify_report = subprocess.run(
                [
                    sys.executable,
                    os.fspath(VERIFIER),
                    "verify",
                    "--directory",
                    os.fspath(destination),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout

            self.assertEqual(snapshot_report, verify_report)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o500)
            self.assertEqual((destination / "manifest.json").stat().st_mode & 0o777, 0o400)
            for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
                self.assertEqual((destination / name).stat().st_mode & 0o777, 0o500)

    def test_private_snapshot_rejects_linked_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            destination = root / "snapshot"
            source.mkdir()
            self.write_artifact(source)
            (source / "codex").unlink()
            (source / "codex").symlink_to(source / "codex-code-mode-host")

            result = subprocess.run(
                [
                    sys.executable,
                    os.fspath(VERIFIER),
                    "snapshot",
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(destination),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("linked, special", result.stderr)

    def test_rust_transaction_keeps_manifest_and_publishes_target_first(self) -> None:
        activation = ACTIVATION.read_text()
        self.assertIn("prepared_artifact_manifest_sha256", activation)
        self.assertIn('generation.join("manifest.json")', activation)
        managed_stage = activation.index(
            "stage_macos_launcher(managed_launcher, &managed_contents, &transaction_id)"
        )
        public_bridge_loop = activation.index(
            "(user_launcher, bridge_contents.as_str())", managed_stage
        )
        self.assertLess(managed_stage, public_bridge_loop)


if __name__ == "__main__":
    unittest.main()

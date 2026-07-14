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

    def test_workflow_keeps_download_cache_free_of_compiled_targets(self) -> None:
        workflow = WORKFLOW.read_text()
        restore = workflow.index("Restore remote Cargo downloads")
        restore_end = workflow.index("Verify the Swift app and test suite", restore)
        save = workflow.index("Save remote Cargo downloads")
        restore_block = workflow[restore:restore_end]
        save_block = workflow[save:]

        self.assertIn(
            "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            restore_block,
        )
        self.assertIn(
            "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            save_block,
        )
        for block in (restore_block, save_block):
            self.assertIn("~/.cargo/registry/index/", block)
            self.assertIn("~/.cargo/registry/cache/", block)
            self.assertIn("~/.cargo/git/db/", block)
            self.assertNotIn("codexswitch-target", block)
            self.assertNotIn("codex-target", block)
            self.assertIn("continue-on-error: true", block)
        self.assertIn("restore-keys:", restore_block)
        self.assertIn("macos-runtime-downloads-v2-", restore_block)
        self.assertIn(
            "if: ${{ always() && steps.cargo_download_cache.outputs.cache-hit != 'true' }}",
            save_block,
        )

    def test_workflow_normalizes_mtimes_before_exact_target_restore(self) -> None:
        workflow = WORKFLOW.read_text()
        patches = workflow.index("Apply the dispatched v3 source patches")
        normalize = workflow.index("Normalize patched upstream source mtimes")
        abi = workflow.index("Derive exact upstream target cache ABI")
        restore = workflow.index("Restore exact upstream Cargo target cache")
        build = workflow.index("Build the patched Codex runtime pair")

        self.assertLess(patches, normalize)
        self.assertLess(normalize, abi)
        self.assertLess(abi, restore)
        self.assertLess(restore, build)

        normalize_block = workflow[normalize:abi]
        self.assertIn(
            'date -u -r "$SOURCE_DATE_EPOCH"',
            normalize_block,
        )
        self.assertIn("export TZ=UTC", normalize_block)
        self.assertIn(
            "git ls-files -z | xargs -0 touch -h -t",
            normalize_block,
        )
        self.assertIn("EXPECTED_PATCH_SHA256", normalize_block)
        self.assertIn("mtime normalization changed the patched-source identity", normalize_block)

        restore_block = workflow[restore:build]
        target_key = (
            "macos-runtime-target-v2-${{ runner.arch }}-"
            "${{ steps.target_cache_abi.outputs.sha256 }}-"
            "${{ steps.upstream.outputs.sha }}-"
            "${{ steps.patches.outputs.sha256 }}-"
            "${{ steps.provenance.outputs.source_sha }}"
        )
        self.assertIn("${{ runner.temp }}/codex-target/", restore_block)
        self.assertIn(target_key, restore_block)
        self.assertNotIn("restore-keys:", restore_block)
        self.assertIn("continue-on-error: true", restore_block)

    def test_workflow_target_cache_abi_binds_effective_build_inputs(self) -> None:
        workflow = WORKFLOW.read_text()
        abi = workflow.index("Derive exact upstream target cache ABI")
        restore = workflow.index("Restore exact upstream Cargo target cache")
        abi_block = workflow[abi:restore]

        self.assertIn(
            "working-directory: ${{ runner.temp }}/codex-upstream/codex-rs",
            abi_block,
        )
        self.assertIn(
            "PATCH_SHA256: ${{ steps.patches.outputs.sha256 }}",
            abi_block,
        )
        self.assertIn(
            "UPSTREAM_SHA: ${{ steps.upstream.outputs.sha }}",
            abi_block,
        )
        for command in (
            "rustc -Vv",
            "cargo -V",
            "sw_vers",
            "xcodebuild -version",
            "xcrun --sdk macosx --show-sdk-version",
            "xcrun --sdk macosx --show-sdk-path",
            "xcrun clang --version",
        ):
            self.assertIn(command, abi_block)
        for value in (
            "TARGET_TRIPLE",
            "UPSTREAM_SHA",
            "PATCH_SHA256",
            "CODEXSWITCH_SOURCE_SHA",
            "SOURCE_DATE_EPOCH",
            "--locked --release --target",
            "CARGO_BUILD_JOBS",
            "CARGO_PROFILE_RELEASE_LTO",
            "CARGO_PROFILE_RELEASE_CODEGEN_UNITS",
            "CARGO_INCREMENTAL",
        ):
            self.assertIn(value, abi_block)
        self.assertIn('shasum -a 256 "$abi_input"', abi_block)

    def test_workflow_saves_target_only_after_all_release_evidence(self) -> None:
        workflow = WORKFLOW.read_text()
        source_validation = workflow.index("Revalidate both source trees after compilation")
        binary_validation = workflow.index("Validate architecture and runtime contracts")
        manifest = workflow.index("Generate and verify the canonical manifest")
        attestation = workflow.index("Attest all exact runtime artifact members")
        upload = workflow.index("Upload the verified runtime artifact")
        evidence = workflow.index("Record build evidence")
        target_save = workflow.index("Save verified upstream Cargo target cache")
        target_cleanup = workflow.index("Remove ephemeral upstream Cargo target")

        self.assertLess(source_validation, binary_validation)
        self.assertLess(binary_validation, manifest)
        self.assertLess(manifest, attestation)
        self.assertLess(attestation, upload)
        self.assertLess(upload, evidence)
        self.assertLess(evidence, target_save)
        self.assertLess(target_save, target_cleanup)

        save_block = workflow[target_save:target_cleanup]
        self.assertIn(
            "if: ${{ success() && steps.upstream_target_cache.outputs.cache-hit != 'true' }}",
            save_block,
        )
        self.assertIn("continue-on-error: true", save_block)
        self.assertIn("${{ runner.temp }}/codex-target/", save_block)
        target_key = (
            "macos-runtime-target-v2-${{ runner.arch }}-"
            "${{ steps.target_cache_abi.outputs.sha256 }}-"
            "${{ steps.upstream.outputs.sha }}-"
            "${{ steps.patches.outputs.sha256 }}-"
            "${{ steps.provenance.outputs.source_sha }}"
        )
        self.assertIn(target_key, save_block)
        self.assertEqual(workflow.count(target_key), 2)
        self.assertNotIn("restore-keys:", save_block)
        pre_save_target_deletions = [
            line
            for line in workflow[:target_save].splitlines()
            if "rm -rf" in line
            and ("UPSTREAM_TARGET_DIR" in line or "codex-target" in line)
        ]
        self.assertEqual(pre_save_target_deletions, [])
        self.assertIn(
            'run: rm -rf -- "$RUNNER_TEMP/codex-target"',
            workflow[target_cleanup:],
        )

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
        self.assertIn('"$control_cli" macos-runtime-contract', installer)
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

    def test_installer_preserves_path_for_final_launcher_probe(self) -> None:
        installer = INSTALLER.read_text()

        self.assertIn('member_path="$artifact_dir/$name"', installer)
        self.assertIn(
            'for route_path in "$installed_cli" "$local_launcher" '
            '"$homebrew_launcher" "$managed_launcher"; do',
            installer,
        )
        self.assertNotRegex(installer, r"(?m)^\s*(?:local\s+)?path=")
        self.assertLess(
            installer.index("for route_path in"),
            installer.index('"$local_launcher" --version'),
        )

    def test_control_plane_contract_is_executable_and_optimizer_independent(self) -> None:
        workflow = WORKFLOW.read_text()
        installer = INSTALLER.read_text()
        activation = ACTIVATION.read_text()

        self.assertIn(
            '"$ARTIFACT_DIR/codexswitch-cli" macos-runtime-contract', workflow
        )
        self.assertIn('"$control_cli" macos-runtime-contract', installer)
        self.assertIn(
            'Command::new(control_cli).arg("macos-runtime-contract")', activation
        )
        self.assertIn("codexswitch-macos-runtime-contract-v1", workflow)
        self.assertIn("codexswitch-macos-runtime-contract-v1", installer)
        self.assertNotIn("codexswitch-cli.strings", workflow)
        self.assertNotIn("control-markers", installer)

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

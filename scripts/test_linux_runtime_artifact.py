import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/verify_linux_runtime_artifact.py"
STAGER = ROOT / "scripts/stage-linux-runtime-artifact.sh"
INSTALLER = ROOT / "scripts/install-linux.sh"
RELEASE_LIBRARY = ROOT / "scripts/lib/install-linux-release.sh"

SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567"
UPSTREAM_SHA = "89abcdef0123456789abcdef0123456789abcdef"
PATCH_SHA = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
BUILD_EPOCH = 1_783_915_200
BUILD_VERSION = f"codexswitch-cli 0.1.0 (git {SOURCE_SHA}, built {BUILD_EPOCH})"


class LinuxRuntimeArtifactTests(unittest.TestCase):
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
            "format": "codexswitch-linux-runtime-artifact-v1",
            "codexSwitchGitSha": SOURCE_SHA,
            "codexSwitchBuildVersion": BUILD_VERSION,
            "upstreamCodexVersion": "0.144.3",
            "upstreamCodexGitSha": UPSTREAM_SHA,
            "sourcePatchSha256": PATCH_SHA,
            "targetTriple": "x86_64-unknown-linux-gnu",
            "architecture": "x86_64",
            "buildEpoch": BUILD_EPOCH,
            "files": files,
        }
        (directory / "manifest.json").write_text(
            json.dumps(manifest, sort_keys=True), encoding="utf-8"
        )

    def run_verifier(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(VERIFIER), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_snapshot_is_nonexecutable_until_promoted_after_review(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            quarantine = root / "quarantine"
            staged = root / "staged"
            source.mkdir()
            self.write_artifact(source)
            for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
                (source / name).chmod(0o644)

            snapshot = self.run_verifier(
                "snapshot",
                "--source",
                str(source),
                "--destination",
                str(quarantine),
            ).stdout
            self.assertEqual(quarantine.stat().st_mode & 0o777, 0o500)
            for name in ("manifest.json", "codex", "codex-code-mode-host", "codexswitch-cli"):
                self.assertEqual((quarantine / name).stat().st_mode & 0o777, 0o400)

            promoted = self.run_verifier(
                "promote",
                "--source",
                str(quarantine),
                "--destination",
                str(staged),
            ).stdout
            self.assertEqual(snapshot, promoted)
            self.assertEqual((staged / "manifest.json").stat().st_mode & 0o777, 0o400)
            for name in ("codex", "codex-code-mode-host", "codexswitch-cli"):
                self.assertEqual((staged / name).stat().st_mode & 0o777, 0o500)

    def test_manifest_binds_full_provenance_and_member_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            source.mkdir()
            self.write_artifact(source)

            report = json.loads(
                self.run_verifier(
                    "verify", "--directory", str(source), "--mode", "source"
                ).stdout
            )
            self.assertEqual(report["sourceSha"], SOURCE_SHA)
            self.assertEqual(report["upstreamSha"], UPSTREAM_SHA)
            self.assertEqual(report["sourcePatchSha256"], PATCH_SHA)
            self.assertEqual(report["buildVersion"], BUILD_VERSION)

            (source / "codex").write_bytes(b"tampered\n")
            rejected = self.run_verifier(
                "verify",
                "--directory",
                str(source),
                "--mode",
                "source",
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("artifact identity mismatch: codex", rejected.stderr)

    def test_rejects_short_build_sha_and_aggregate_oversize(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            source.mkdir()
            self.write_artifact(source)
            manifest_path = source / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["codexSwitchBuildVersion"] = (
                f"codexswitch-cli 0.1.0 (git {SOURCE_SHA[:12]}, built {BUILD_EPOCH})"
            )
            manifest_path.write_text(json.dumps(manifest, sort_keys=True))
            short_sha = self.run_verifier(
                "verify",
                "--directory",
                str(source),
                "--mode",
                "source",
                check=False,
            )
            self.assertNotEqual(short_sha.returncode, 0)
            self.assertIn("control-plane provenance is invalid", short_sha.stderr)

            manifest["codexSwitchBuildVersion"] = BUILD_VERSION
            manifest["files"][0]["bytes"] = 2 * 1024 * 1024 * 1024
            manifest_path.write_text(json.dumps(manifest, sort_keys=True))
            oversized = self.run_verifier(
                "verify",
                "--directory",
                str(source),
                "--mode",
                "source",
                check=False,
            )
            self.assertNotEqual(oversized.returncode, 0)
            self.assertIn("complete artifact exceeds the 2 GiB release limit", oversized.stderr)

    def test_rejects_linked_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source = root / "download"
            source.mkdir()
            self.write_artifact(source)
            (source / "codex").unlink()
            (source / "codex").symlink_to(source / "codex-code-mode-host")
            rejected = self.run_verifier(
                "snapshot",
                "--source",
                str(source),
                "--destination",
                str(root / "quarantine"),
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertRegex(rejected.stderr, "failed to open|linked")

    def test_operator_stager_attests_before_mode_restoration(self) -> None:
        text = STAGER.read_text(encoding="utf-8")
        snapshot = text.index('"$artifact_verifier" snapshot')
        attestation = text.index('attestation verify "$quarantine_dir/$name"')
        reverify = text.index('"$artifact_verifier" verify', attestation)
        promote = text.index('"$artifact_verifier" promote')
        staged_verify = text.index('"$artifact_verifier" verify', promote)
        self.assertLess(snapshot, attestation)
        self.assertLess(attestation, reverify)
        self.assertLess(reverify, promote)
        self.assertLess(promote, staged_verify)
        for policy in (
            '--repo "$trusted_repository"',
            '--signer-workflow "$trusted_workflow"',
            '--signer-digest "$source_sha"',
            "--source-ref refs/heads/main",
            '--source-digest "$source_sha"',
            "--deny-self-hosted-runners",
        ):
            self.assertIn(policy, text)

    def test_installer_uses_manifest_authority_and_full_sha_version(self) -> None:
        installer = INSTALLER.read_text(encoding="utf-8")
        release = RELEASE_LIBRARY.read_text(encoding="utf-8")
        self.assertLess(
            installer.index("load_linux_artifact_provenance"),
            installer.index("validate_configuration"),
        )
        self.assertIn("verify --directory", release)
        self.assertIn('EXPECTED_CLI_VERSION="codexswitch-cli $PACKAGE_VERSION (git $TARGET_SHA, built $BUILD_EPOCH)"', release)
        self.assertNotIn("${TARGET_SHA:0:12}, built", release)
        self.assertIn("sourcePatchSha256", release)
        self.assertIn("artifact_manifest_sha256", release)
        self.assertIn("upstream_codex_git_sha", release)


if __name__ == "__main__":
    unittest.main()

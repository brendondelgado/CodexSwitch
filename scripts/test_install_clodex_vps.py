#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "install-clodex-vps.sh"


class ClodexVPSInstallerTests(unittest.TestCase):
    def make_subject(self, root: pathlib.Path, version: str = "2.1.3") -> dict:
        prefix = root / "prefix"
        package = prefix / "lib" / "node_modules" / "@bman654" / "clodex"
        dist = package / "dist"
        bin_dir = prefix / "bin"
        dist.mkdir(parents=True)
        bin_dir.mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"version": version}))
        cli = dist / "cli.js"
        wrapper = dist / "claude-wrapper.js"
        cli.write_text(
            """#!/usr/bin/env bash
if [ "${1:-}" = "claude" ]; then
  printf 'clodex:openai-oauth:gpt-synthetic\\n'
elif [ "${1:-}" = "patch" ]; then
  printf 'patched isolated claude\\n'
else
  printf '2.1.3\\n'
fi
"""
        )
        wrapper.write_text("#!/usr/bin/env bash\nexit 0\n")
        cli.chmod(0o755)
        wrapper.chmod(0o755)
        (bin_dir / "clodex").symlink_to(cli)
        (bin_dir / "clodex-claude").symlink_to(wrapper)
        for name in (
            "clodex-credential-helper",
            "clodex-ccs-runtime-helper",
            "patch-clodex-codexswitch",
            "configure-clodex-codexswitch",
        ):
            support = bin_dir / name
            support.write_text("#!/usr/bin/env bash\nexit 0\n")
            support.chmod(0o700)

        native = root / "native-claude"
        native.write_text("#!/usr/bin/env bash\nprintf '2.1.220 (Claude Code)\\n'\n")
        native.chmod(0o755)
        isolated_root = root / "isolated"
        isolated_bin = isolated_root / "bin"
        isolated_versions = isolated_root / "versions"
        isolated_bin.mkdir(parents=True)
        isolated_versions.mkdir()
        isolated = isolated_versions / "2.1.220"
        isolated.write_text("#!/usr/bin/env bash\nprintf '2.1.220 (Claude Code)\\n'\n")
        isolated.chmod(0o755)
        (isolated_bin / "claude").symlink_to(isolated)

        tools = root / "tools"
        tools.mkdir()
        node = tools / "node"
        node.write_text(
            """#!/usr/bin/env python3
import json
import sys
if sys.argv[1:3] == ["-p", 'process.versions.node.split(".")[0]']:
    print("24")
elif sys.argv[1] == "-p":
    print(json.load(open(sys.argv[3]))["version"])
elif sys.argv[1] == "--version":
    print("v24.17.0")
else:
    raise SystemExit(2)
"""
        )
        node.chmod(0o755)
        npm = tools / "npm"
        npm.write_text(
            f"""#!/usr/bin/env bash
if [ "$1 $2 $3" = "config get prefix" ]; then
  printf '%s\\n' {str(prefix)!r}
  exit 0
fi
exit 2
"""
        )
        npm.chmod(0o755)
        return {
            "prefix": prefix,
            "node": node,
            "npm": npm,
            "package": package,
            "native": native,
            "isolated_root": isolated_root,
        }

    def run_check(self, subject: dict) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(SCRIPT), "--check"],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "CLODEX_VPS_PREFIX": str(subject["prefix"]),
                "CLODEX_VPS_NODE_BIN": str(subject["node"]),
                "CLODEX_VPS_NPM_BIN": str(subject["npm"]),
                "CLODEX_NATIVE_CLAUDE_BIN": str(subject["native"]),
                "CLODEX_ISOLATED_ROOT": str(subject["isolated_root"]),
            },
        )

    def test_check_accepts_exact_version_and_binary_targets(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            subject = self.make_subject(pathlib.Path(raw_temp))
            result = self.run_check(subject)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("@bman654/clodex@2.1.3", result.stdout)

    def test_check_refuses_wrong_version(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            subject = self.make_subject(pathlib.Path(raw_temp), version="2.1.4")
            result = self.run_check(subject)
            self.assertEqual(result.returncode, 78)
            self.assertIn("expected @bman654/clodex@2.1.3", result.stderr)

    def test_check_refuses_retargeted_binary(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            subject = self.make_subject(pathlib.Path(raw_temp))
            wrong = pathlib.Path(raw_temp) / "wrong"
            wrong.write_text("#!/usr/bin/env bash\nexit 0\n")
            wrong.chmod(0o755)
            link = subject["prefix"] / "bin" / "clodex"
            link.unlink()
            link.symlink_to(wrong)
            result = self.run_check(subject)
            self.assertEqual(result.returncode, 78)
            self.assertIn("binary target mismatch", result.stderr)

    def test_check_refuses_missing_managed_bridge_support(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            subject = self.make_subject(pathlib.Path(raw_temp))
            (subject["prefix"] / "bin" / "clodex-credential-helper").unlink()
            result = self.run_check(subject)
            self.assertEqual(result.returncode, 78)
            self.assertIn("support executable missing or unsafe", result.stderr)

    def test_check_refuses_isolated_link_to_shared_native_binary(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            subject = self.make_subject(pathlib.Path(raw_temp))
            link = subject["isolated_root"] / "bin" / "claude"
            link.unlink()
            link.symlink_to(subject["native"])
            result = self.run_check(subject)
            self.assertEqual(result.returncode, 78)
            self.assertIn("resolves to the shared native binary", result.stderr)


if __name__ == "__main__":
    unittest.main()

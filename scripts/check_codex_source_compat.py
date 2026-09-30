#!/usr/bin/env python3
"""Apply production patches twice to exact upstream Git bytes, without network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISIONS = {
    "0.153.2": "657a993cbee87acf52d14b758ce49dbd46d1b8eb",
    "0.159.2": "ff6aec96948b70d94983af2641a6b67c94faeff5",
}
FILES = [
    "Cargo.toml", "Cargo.lock", "core/Cargo.toml", "login/Cargo.toml",
    "app-server/Cargo.toml", "app-server/src/lib.rs", "app-server/src/in_process.rs",
    "app-server/src/outgoing_message.rs", "app-server/src/transport.rs",
    "login/src/auth/manager.rs", "core/src/client.rs", "core/src/session/turn.rs",
    "tui/src/lib.rs",
    "app-server-daemon/src/managed_install.rs",
    "app-server-daemon/src/update_loop.rs",
]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, timeout=120, **kwargs)


def files_for(version):
    return FILES + (["model-provider/src/workspace_routing.rs"] if version == "0.159.2" else [])


def hashes(directory, files):
    return {p: hashlib.sha256((directory / "codex-rs" / p).read_bytes()).hexdigest()
            for p in files}


def verify(upstream, versions):
    results = []
    with tempfile.TemporaryDirectory(prefix="codex-source-compat-") as scratch:
        scratch = Path(scratch)
        driver = scratch / "patch-driver"
        run("rustc", "--edition=2021", str(ROOT / "Tests/Fixtures/BuildFork/patch_codex_source.rs"),
            "-o", str(driver), env={**os.environ, "CODEXSWITCH_REPOSITORY_ROOT": str(ROOT)})
        for version in versions:
            revision = REVISIONS[version]
            resolved = run("git", "-C", str(upstream), "rev-parse", revision + "^{commit}").stdout.decode().strip()
            assert resolved == revision
            source = scratch / version
            files = files_for(version)
            for path in files:
                dest = source / "codex-rs" / path
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(run("git", "-C", str(upstream), "show", revision + ":codex-rs/" + path).stdout)
            pristine = hashes(source, files)
            run(str(driver), str(source))
            patched = hashes(source, files)
            run(str(driver), str(source))
            assert hashes(source, files) == patched, f"{version}: patching is not idempotent"
            manager = (source / "codex-rs/login/src/auth/manager.rs").read_text()
            assert "guard.auth = new_auth;\n            if auth_changed_for_refresh {\n                self.auth_generation.fetch_add" in manager
            if version == "0.159.2":
                client_bytes = (source / "codex-rs/core/src/client.rs").read_text()
                marker_log = '\n            if owner_changed {\n                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");\n            }'
                assert client_bytes.count(marker_log) == 1
                assert hashlib.sha256(client_bytes.replace(marker_log, "", 1).encode()).hexdigest() == pristine["core/src/client.rs"], "native revision handling must remain intact"
                verified = manager.split("pub async fn codexswitch_reload_auth_json_verified", 1)[1].split("/// Reloads auth", 1)[0]
                assert verified.index("validate_auth_restrictions(") < verified.index("cached.auth = Some(new_auth)")
                assert "state.owner_generation += 1;" in verified
                assert "state.generation += 1;" in verified
                assert "network_policy().invalidate();" in verified
                update = (source / "codex-rs/app-server-daemon/src/update_loop.rs").read_text()
                fetch = update.split("async fn fetch_installer_script(", 1)[1].split("\n}", 1)[0]
                assert "CodexSwitch owns runtime updates" in fetch
                assert "http.get(" not in fetch
                # A partial native invalidation contract must be refused, not silently accepted.
                client_path = source / "codex-rs/core/src/client.rs"
                client = client_path.read_text()
                client_path.write_text(client.replace("if needs_new || owner_changed {", "if needs_new {", 1))
                refusal = subprocess.run([str(driver), str(source)], capture_output=True, text=True, timeout=120)
                assert refusal.returncode != 0 and "native WebSocket auth invalidation contract missing" in refusal.stderr
                client_path.write_text(client)
                key_path = source / "codex-rs/model-provider/src/workspace_routing.rs"
                key = key_path.read_text()
                key_path.write_text(key.replace("            auth_revision,", "            auth_revision: None,", 1))
                refusal = subprocess.run([str(driver), str(source)], capture_output=True, text=True, timeout=120)
                assert refusal.returncode != 0 and "dependency contract drift" in refusal.stderr
                key_path.write_text(key)
                client_path.write_text(client.replace("                .owner_generation", "                .generation", 1))
                refusal = subprocess.run([str(driver), str(source)], capture_output=True, text=True, timeout=120)
                assert refusal.returncode != 0 and "dependency contract drift" in refusal.stderr

            results.append({"version": version, "revision": revision, "status": "passed",
                            "pristine_sha256": pristine, "patched_sha256": patched})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-repo", required=True, type=Path)
    parser.add_argument("--version", action="append", choices=REVISIONS)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = verify(args.upstream_repo, args.version or list(REVISIONS))
    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(payload)
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()

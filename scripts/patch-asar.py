#!/usr/bin/env python3
"""Apply the minimal Codex desktop hot-swap patch used by CodexSwitch.

The desktop app keeps auth in renderer/app-server memory, so writing
~/.codex/auth.json is not enough for in-place account swaps. This patch adds a
small renderer-side bridge that watches the local auth file and asks Codex.app's
own app-server to load changed ChatGPT tokens. It also removes the older query
invalidation-only patch when present.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
APP_PATH = Path(os.environ.get("CODEX_APP", "/Applications/Codex.app"))
APP_RESOURCES = APP_PATH / "Contents" / "Resources"
INFO_PLIST_PATH = APP_PATH / "Contents" / "Info.plist"
ASAR_PATH = APP_RESOURCES / "app.asar"
ASAR_UNPACKED = APP_RESOURCES / "app.asar.unpacked"
ASAR_BACKUP = APP_RESOURCES / "app.asar.bak"
AUTH_JSON_PATH = Path.home() / ".codex" / "auth.json"

# Patch markers
LEGACY_AUTH_PATCH_MARKER = "_invalidateAccountQueries"
DESKTOP_AUTH_SYNC_MARKER = "_codexSwitchEnsureDesktopAuthSync"
DESKTOP_AUTH_REQUEST_MARKER = "codexSwitchLoginWithChatGptAuthTokens"

BUNDLE_CODE_SUFFIXES = {".app", ".framework", ".xpc"}
FILE_CODE_SUFFIXES = {".dylib", ".so", ".node"}
RESOURCE_EXECUTABLE_NAMES = {
    "codex",
    "node",
    "node_repl",
    "rg",
    "launch-services-helper",
    "spawn-helper",
}

LEGACY_PATCH_MARKERS = (
    LEGACY_AUTH_PATCH_MARKER,
)


def resolve_asar_cmd() -> list[str]:
    """Use a cached asar CLI when `npx` resolution is flaky."""
    node = shutil.which("node")
    if node:
        npm_dir = Path.home() / ".npm" / "_npx"
        for asar_js in sorted(
            npm_dir.glob("*/node_modules/asar/bin/asar.js"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        ):
            return [node, str(asar_js)]
    return ["npx", "--no-install", "asar"]


ASAR_CMD = resolve_asar_cmd()


# ---------------------------------------------------------------------------
# Temp-dir management
# ---------------------------------------------------------------------------
_cleanup_dirs: list[Path] = []


def _cleanup():
    for d in _cleanup_dirs:
        shutil.rmtree(d, ignore_errors=True)


atexit.register(_cleanup)


def make_workdir() -> Path:
    d = Path(tempfile.mkdtemp(prefix="codex-asar-patch-"))
    _cleanup_dirs.append(d)
    return d


# ---------------------------------------------------------------------------
# asar extract / pack
# ---------------------------------------------------------------------------
def extract_asar(asar_path: Path, dest: Path) -> bool:
    result = subprocess.run(
        [*ASAR_CMD, "extract", str(asar_path), str(dest)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        print(f"asar extract stderr: {result.stderr.strip()}")
    return result.returncode == 0


def collect_unpack_specs(unpacked_root: Path) -> tuple[list[str], list[str]]:
    """Preserve the exact live .unpacked file list as pack arguments."""
    if not unpacked_root.exists():
        return [], []

    unpack_files = sorted(
        str(path.relative_to(unpacked_root)).replace("\\", "/")
        for path in unpacked_root.rglob("*")
        if path.is_file()
    )
    return [], unpack_files


def build_pack_command(
    src: Path,
    dest_asar: Path,
    unpack_dirs: list[str],
    unpack_files: list[str],
) -> list[str]:
    command = [*ASAR_CMD, "pack", str(src), str(dest_asar)]
    for unpack_dir in unpack_dirs:
        command.extend(["--unpack-dir", unpack_dir])
    for unpack_file in unpack_files:
        command.extend(["--unpack", unpack_file])
    return command


def pack_asar(src: Path, dest_asar: Path, unpacked_root: Path) -> bool:
    unpack_dirs, unpack_files = collect_unpack_specs(unpacked_root)
    command = build_pack_command(src, dest_asar, unpack_dirs, unpack_files)
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        print(f"asar pack stderr: {result.stderr.strip()}")
    return result.returncode == 0


def validate_asar(asar_path: Path) -> bool:
    result = subprocess.run(
        [*ASAR_CMD, "list", str(asar_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        print(f"asar list stderr: {result.stderr.strip()}")
        return False
    entries = result.stdout.strip().splitlines()
    has_package = any("/package.json" in e for e in entries)
    has_webview = any("/webview/" in e for e in entries)
    has_native = any(".node" in e for e in entries)
    if not (has_package and has_webview and has_native):
        print("ERROR: Repacked asar missing expected entries")
        print(f"  package.json: {has_package}, webview: {has_webview}, native: {has_native}")
        return False
    return True


def sha256_asar_header_json(file_path: Path) -> str:
    blob = file_path.read_bytes()
    json_len = struct.unpack_from("<I", blob, 12)[0]
    header_json = blob[16 : 16 + json_len]
    return hashlib.sha256(header_json).hexdigest()


def update_info_plist_asar_hash(
    info_plist_path: Path,
    asar_relative_path: str,
    new_hash: str,
) -> None:
    with info_plist_path.open("rb") as fh:
        plist = plistlib.load(fh)

    integrity = plist.setdefault("ElectronAsarIntegrity", {})
    asar_entry = integrity.setdefault(asar_relative_path, {})
    asar_entry["algorithm"] = asar_entry.get("algorithm", "SHA256")
    asar_entry["hash"] = new_hash

    with info_plist_path.open("wb") as fh:
        plistlib.dump(plist, fh)


# ---------------------------------------------------------------------------
# Find patch targets
# ---------------------------------------------------------------------------
def find_auth_file(assets_dir: Path) -> Path | None:
    if not assets_dir.exists():
        return None

    content_markers = (
        "addAuthStatusCallback",
        "getAccount",
        "useAuth must be used within AuthProvider",
    )

    for pattern in (
        "use-auth-*.js",
        "app-server-manager-hooks-*.js",
        "invalidate-queries-and-broadcast-*.js",
    ):
        for f in assets_dir.glob(pattern):
            content = f.read_text()
            if all(m in content for m in content_markers):
                return f

    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if all(m in content for m in content_markers):
            return f
    return None


def find_request_file(assets_dir: Path) -> Path | None:
    if not assets_dir.exists():
        return None

    content_markers = (
        "loginWithChatGptDeviceCode",
        "writeSkillConfig",
        "account/read",
    )

    for pattern in ("send-app-server-request-*.js",):
        for f in assets_dir.glob(pattern):
            content = f.read_text()
            if all(m in content for m in content_markers):
                return f

    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if all(m in content for m in content_markers):
            return f
    return None


# ---------------------------------------------------------------------------
# Patch logic
# ---------------------------------------------------------------------------
def migrate_legacy_auth_patch(file_path: Path) -> bool:
    content = file_path.read_text()

    if LEGACY_AUTH_PATCH_MARKER not in content:
        print(f"  No legacy auth patch found: {file_path.name}")
        return True

    patched = content
    module_patch_re = re.compile(
        r"var _qcHook=[A-Za-z_$][\w$]*(?:,_qkBuild=[A-Za-z_$][\w$]*)?,_qcRef=null;"
        r"function _invalidateAccountQueries\(\)\{if\(_qcRef\)\{"
        r"_qcRef\.invalidateQueries\(\{queryKey:\[`accounts`,`check`\]\}\);"
        r"(?:_qcRef\.invalidateQueries\(\{queryKey:_qkBuild\(`account-info`\)\}\))?"
        r"\}\}"
    )
    patched, module_replacements = module_patch_re.subn("", patched, count=1)
    if module_replacements != 1:
        print("ERROR: Cannot find legacy auth module patch to remove")
        return False

    patched, capture_replacements = re.subn(
        r";_qcRef=[A-Za-z_$][\w$]*",
        "",
        patched,
        count=1,
    )
    if capture_replacements != 1:
        print("ERROR: Cannot find legacy QueryClient capture to remove")
        return False

    if ",_invalidateAccountQueries()," not in patched:
        print("ERROR: Cannot find legacy auth callback injection to remove")
        return False
    patched = patched.replace(",_invalidateAccountQueries(),", ",", 1)

    if LEGACY_AUTH_PATCH_MARKER in patched:
        print("ERROR: Legacy auth patch marker still present after migration")
        return False

    file_path.write_text(patched)
    print(f"  Removed legacy auth patch: {file_path.name}")
    return True


def apply_desktop_request_patch(file_path: Path) -> bool:
    content = file_path.read_text()

    if DESKTOP_AUTH_REQUEST_MARKER in content and "codexSwitchReadHostFile" in content:
        print(f"  Desktop request helper patch already present: {file_path.name}")
        return True

    anchor = 'writeSkillConfig(e){return this.sendRequest(`skills/config/write`,e)}'
    injected = (
        anchor
        + 'codexSwitchReadHostFile(e){return this.sendRequest(`fs/readFile`,{path:e})}'
        + 'async codexSwitchLoginWithChatGptAuthTokens(e,t,n=null){return this.sendRequest(`account/login/start`,{type:`chatgptAuthTokens`,accessToken:e,chatgptAccountId:t,chatgptPlanType:n})}'
    )
    if anchor not in content:
        print("ERROR: Cannot find request helper anchor in send-app-server-request bundle")
        return False

    patched = content.replace(anchor, injected, 1)
    if DESKTOP_AUTH_REQUEST_MARKER not in patched or "codexSwitchReadHostFile" not in patched:
        print("ERROR: Desktop request helper patch did not apply cleanly")
        return False

    file_path.write_text(patched)
    print(f"  Added desktop request helpers: {file_path.name}")
    return True


def apply_desktop_auth_sync_patch(file_path: Path, auth_path: str) -> bool:
    content = file_path.read_text()

    if DESKTOP_AUTH_SYNC_MARKER in content:
        print(f"  Desktop auth sync patch already present: {file_path.name}")
        return True

    weak_map_anchor = re.search(
        r"var [^;]*=new WeakMap;(?=function)",
        content,
    )
    if not weak_map_anchor:
        print("ERROR: Cannot find auth module WeakMap anchor")
        return False

    auth_path_literal = json.dumps(auth_path)
    module_patch = (
        f"var _codexSwitchDesktopAuthPath={auth_path_literal},"
        "_codexSwitchDesktopAuthSig=null,"
        "_codexSwitchDesktopAuthInflight=null,"
        "_codexSwitchDesktopAuthPrimed=!1,"
        "_codexSwitchDesktopAuthTimerStarted=!1;"
        "function _codexSwitchDecodeBase64(e){let t=atob(e),n=new Uint8Array(t.length);for(let e=0;e<t.length;e++)n[e]=t.charCodeAt(e);return new TextDecoder().decode(n)}"
        "async function _codexSwitchSyncDesktopAuth(e){let t=await e.codexSwitchReadHostFile(_codexSwitchDesktopAuthPath),n=JSON.parse(_codexSwitchDecodeBase64(t.dataBase64)),r=n?.tokens?.account_id,i=n?.tokens?.access_token;if(!(typeof r==`string`&&r.length>0&&typeof i==`string`&&i.length>0))return;let a=`${r}:${i.slice(-32)}`;if(a===_codexSwitchDesktopAuthSig)return;if(!_codexSwitchDesktopAuthPrimed){_codexSwitchDesktopAuthPrimed=!0,_codexSwitchDesktopAuthSig=a;return}await e.codexSwitchLoginWithChatGptAuthTokens(i,r,null),_codexSwitchDesktopAuthSig=a}"
        "function _codexSwitchEnsureDesktopAuthSync(e){if(_codexSwitchDesktopAuthTimerStarted||typeof e.codexSwitchReadHostFile!=`function`||typeof e.codexSwitchLoginWithChatGptAuthTokens!=`function`)return;_codexSwitchDesktopAuthTimerStarted=!0;let t=()=>{_codexSwitchDesktopAuthInflight??=Promise.resolve().then(()=>_codexSwitchSyncDesktopAuth(e)).catch(()=>{}).finally(()=>{_codexSwitchDesktopAuthInflight=null})};t(),setInterval(t,2e3)}"
    )
    patched = (
        content[: weak_map_anchor.end()]
        + module_patch
        + content[weak_map_anchor.end() :]
    )

    effect_pattern = re.compile(
        r"(\(\)\=>\{if\(([A-Za-z_$][\w$]*)==null\)return;)let ",
        flags=re.M,
    )
    patched, replacements = effect_pattern.subn(
        r"\1_codexSwitchEnsureDesktopAuthSync(\2);let ",
        patched,
        count=1,
    )
    if replacements != 1:
        print("ERROR: Cannot find auth effect anchor for desktop sync patch")
        return False

    if DESKTOP_AUTH_SYNC_MARKER not in patched or "_codexSwitchDesktopAuthPrimed" not in patched:
        print("ERROR: Desktop auth sync patch marker missing after patch")
        return False

    file_path.write_text(patched)
    print(f"  Added desktop auth sync: {file_path.name}")
    return True


def remove_desktop_request_patch(file_path: Path) -> bool:
    content = file_path.read_text()

    injected = (
        'writeSkillConfig(e){return this.sendRequest(`skills/config/write`,e)}'
        'codexSwitchReadHostFile(e){return this.sendRequest(`fs/readFile`,{path:e})}'
        'async codexSwitchLoginWithChatGptAuthTokens(e,t,n=null){return this.sendRequest(`account/login/start`,{type:`chatgptAuthTokens`,accessToken:e,chatgptAccountId:t,chatgptPlanType:n})}'
    )
    anchor = 'writeSkillConfig(e){return this.sendRequest(`skills/config/write`,e)}'

    if DESKTOP_AUTH_REQUEST_MARKER not in content and "codexSwitchReadHostFile" not in content:
        print(f"  No desktop request helper patch found: {file_path.name}")
        return True

    if injected not in content:
        print("ERROR: Desktop request helper patch shape changed; cannot remove cleanly")
        return False

    patched = content.replace(injected, anchor, 1)
    if DESKTOP_AUTH_REQUEST_MARKER in patched or "codexSwitchReadHostFile" in patched:
        print("ERROR: Desktop request helper patch marker still present after removal")
        return False

    file_path.write_text(patched)
    print(f"  Removed desktop request helpers: {file_path.name}")
    return True


def remove_desktop_auth_sync_patch(file_path: Path, auth_path: str) -> bool:
    content = file_path.read_text()

    if DESKTOP_AUTH_SYNC_MARKER not in content:
        print(f"  No desktop auth sync patch found: {file_path.name}")
        return True

    auth_path_literal = json.dumps(auth_path)
    module_patch = (
        f"var _codexSwitchDesktopAuthPath={auth_path_literal},"
        "_codexSwitchDesktopAuthSig=null,"
        "_codexSwitchDesktopAuthInflight=null,"
        "_codexSwitchDesktopAuthPrimed=!1,"
        "_codexSwitchDesktopAuthTimerStarted=!1;"
        "function _codexSwitchDecodeBase64(e){let t=atob(e),n=new Uint8Array(t.length);for(let e=0;e<t.length;e++)n[e]=t.charCodeAt(e);return new TextDecoder().decode(n)}"
        "async function _codexSwitchSyncDesktopAuth(e){let t=await e.codexSwitchReadHostFile(_codexSwitchDesktopAuthPath),n=JSON.parse(_codexSwitchDecodeBase64(t.dataBase64)),r=n?.tokens?.account_id,i=n?.tokens?.access_token;if(!(typeof r==`string`&&r.length>0&&typeof i==`string`&&i.length>0))return;let a=`${r}:${i.slice(-32)}`;if(a===_codexSwitchDesktopAuthSig)return;if(!_codexSwitchDesktopAuthPrimed){_codexSwitchDesktopAuthPrimed=!0,_codexSwitchDesktopAuthSig=a;return}await e.codexSwitchLoginWithChatGptAuthTokens(i,r,null),_codexSwitchDesktopAuthSig=a}"
        "function _codexSwitchEnsureDesktopAuthSync(e){if(_codexSwitchDesktopAuthTimerStarted||typeof e.codexSwitchReadHostFile!=`function`||typeof e.codexSwitchLoginWithChatGptAuthTokens!=`function`)return;_codexSwitchDesktopAuthTimerStarted=!0;let t=()=>{_codexSwitchDesktopAuthInflight??=Promise.resolve().then(()=>_codexSwitchSyncDesktopAuth(e)).catch(()=>{}).finally(()=>{_codexSwitchDesktopAuthInflight=null})};t(),setInterval(t,2e3)}"
    )

    if module_patch not in content:
        print("ERROR: Desktop auth sync patch shape changed; cannot remove cleanly")
        return False

    patched = content.replace(module_patch, "", 1)
    effect_replacement = ")),_codexSwitchEnsureDesktopAuthSync(e),l();let d="
    effect_anchor = ")),l();let d="
    if effect_replacement not in patched:
        print("ERROR: Desktop auth sync effect anchor changed; cannot remove cleanly")
        return False

    patched = patched.replace(effect_replacement, effect_anchor, 1)

    if DESKTOP_AUTH_SYNC_MARKER in patched:
        print("ERROR: Desktop auth sync patch marker still present after removal")
        return False

    file_path.write_text(patched)
    print(f"  Removed desktop auth sync patch: {file_path.name}")
    return True


def bundle_is_valid() -> bool:
    verify = subprocess.run(
        [
            "codesign",
            "--verify",
            "--deep",
            "--strict",
            "--verbose=4",
            str(APP_PATH),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    return verify.returncode == 0


def asar_contains_hot_swap_patch() -> bool:
    data = ASAR_PATH.read_bytes()
    return (
        DESKTOP_AUTH_SYNC_MARKER.encode() in data
        and DESKTOP_AUTH_REQUEST_MARKER.encode() in data
        and b"codexSwitchReadHostFile" in data
        and not any(marker.encode() in data for marker in LEGACY_PATCH_MARKERS)
    )


# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------
def _is_signable_resource_binary(path: Path) -> bool:
    return (
        path.is_file()
        and "Contents/Resources" in path.as_posix()
        and (path.name in RESOURCE_EXECUTABLE_NAMES or os.access(path, os.X_OK))
    )


def _is_signable_framework_binary(path: Path) -> bool:
    return (
        path.is_file()
        and ".framework/" in path.as_posix()
        and os.access(path, os.X_OK)
    )


def list_codesign_targets(app_path: Path) -> list[Path]:
    app_path = app_path.resolve()
    targets: set[Path] = set()

    for path in app_path.rglob("*"):
        if path == app_path:
            continue
        if path.is_dir() and path.suffix in BUNDLE_CODE_SUFFIXES:
            targets.add(path.resolve())
            continue
        if path.is_file() and (
            path.suffix in FILE_CODE_SUFFIXES
            or _is_signable_resource_binary(path)
            or _is_signable_framework_binary(path)
        ):
            targets.add(path.resolve())

    ordered = sorted(
        targets,
        key=lambda path: (
            0 if path.is_file() else 1,
            -len(path.relative_to(app_path).parts),
            str(path),
        ),
    )
    ordered.append(app_path)
    return ordered


def codesign_app() -> bool:
    for target in list_codesign_targets(APP_PATH):
        result = subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                str(target),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            print(f"WARNING: codesign failed for {target}: {result.stderr.strip()}")
            return False

    verify = subprocess.run(
        [
            "codesign",
            "--verify",
            "--deep",
            "--strict",
            "--verbose=4",
            str(APP_PATH),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if verify.returncode != 0:
        print(f"WARNING: codesign verification failed: {verify.stderr.strip()}")
        return False
    return True


def refresh_signature_state() -> bool:
    if not ASAR_PATH.exists():
        print(f"Codex.app not found at {APP_PATH}")
        return False

    new_asar_hash = sha256_asar_header_json(ASAR_PATH)
    update_info_plist_asar_hash(
        INFO_PLIST_PATH,
        asar_relative_path="Resources/app.asar",
        new_hash=new_asar_hash,
    )
    print(f"Updated ElectronAsarIntegrity header hash: {new_asar_hash}")

    print("Re-signing Codex.app...")
    if not codesign_app():
        return False
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not ASAR_PATH.exists():
        print(f"Codex.app not found at {APP_PATH}")
        sys.exit(2)

    if asar_contains_hot_swap_patch():
        if bundle_is_valid():
            print("Codex desktop bundle is already hot-swap patched and signed.")
            sys.exit(0)

        print("Bundle is hot-swap patched, but the signature is invalid; refreshing signatures.")
        if not refresh_signature_state():
            sys.exit(1)
        print("Done! Codex desktop app signatures were refreshed.")
        sys.exit(0)

    if not ASAR_UNPACKED.exists():
        print(f"ERROR: Missing companion unpacked directory: {ASAR_UNPACKED}")
        sys.exit(2)

    workdir = make_workdir()
    asar_copy = workdir / "app.asar"
    extract_dir = workdir / "extracted"

    print("Copying asar to work directory...")
    shutil.copy2(ASAR_PATH, asar_copy)
    shutil.copytree(ASAR_UNPACKED, workdir / "app.asar.unpacked")

    print("Extracting app.asar...")
    if not extract_asar(asar_copy, extract_dir):
        print("ERROR: Failed to extract asar")
        sys.exit(1)

    assets_dir = extract_dir / "webview" / "assets"
    auth_file = find_auth_file(assets_dir)
    request_file = find_request_file(assets_dir)

    if not auth_file:
        print("ERROR: Could not find Codex desktop auth bundle")
        sys.exit(2)
    if not request_file:
        print("ERROR: Could not find Codex desktop app-server request bundle")
        sys.exit(2)

    needs_repack = False

    if auth_file and LEGACY_AUTH_PATCH_MARKER in auth_file.read_text():
        print("Removing legacy auth invalidation patch...")
        if not migrate_legacy_auth_patch(auth_file):
            print("ERROR: Legacy auth patch migration failed")
            sys.exit(1)
        needs_repack = True

    if DESKTOP_AUTH_REQUEST_MARKER not in request_file.read_text() or "codexSwitchReadHostFile" not in request_file.read_text():
        print("Applying desktop request helper patch...")
        if not apply_desktop_request_patch(request_file):
            print("ERROR: Desktop request helper patch failed")
            sys.exit(1)
        needs_repack = True

    if DESKTOP_AUTH_SYNC_MARKER not in auth_file.read_text():
        print("Applying desktop auth hot-swap patch...")
        if not apply_desktop_auth_sync_patch(auth_file, str(AUTH_JSON_PATH)):
            print("ERROR: Desktop auth hot-swap patch failed")
            sys.exit(1)
        needs_repack = True

    if not needs_repack:
        if bundle_is_valid():
            print("Codex desktop bundle is already hot-swap patched and signed.")
            sys.exit(0)

        print("Bundle needs signature refresh; updating integrity and signatures.")
        if not refresh_signature_state():
            sys.exit(1)
        print("Done! Codex desktop app signatures were refreshed.")
        sys.exit(0)

    print("Repacking app.asar (preserving live .unpacked package layout)...")
    repacked_asar = workdir / "repacked.asar"
    if not pack_asar(extract_dir, repacked_asar, ASAR_UNPACKED):
        print("ERROR: Failed to repack asar")
        sys.exit(1)

    print("Validating repacked asar...")
    if not validate_asar(repacked_asar):
        print("ERROR: Repacked asar failed validation")
        sys.exit(1)

    if not ASAR_BACKUP.exists():
        print("Creating backup: app.asar.bak")
        shutil.copy2(ASAR_PATH, ASAR_BACKUP)
    else:
        print("Backup already exists: app.asar.bak")

    print("Installing patched asar...")
    shutil.copy2(repacked_asar, ASAR_PATH)
    print("Preserving existing app.asar.unpacked contents from installed Codex.app")

    if not refresh_signature_state():
        sys.exit(1)

    old_extracted = APP_RESOURCES / "app.asar.extracted"
    if old_extracted.exists():
        print("Cleaning up leftover app.asar.extracted directory...")
        shutil.rmtree(old_extracted, ignore_errors=True)

    print("Done! Codex desktop app will use the safe hot-swap patch on next restart.")
    sys.exit(0)


if __name__ == "__main__":
    main()

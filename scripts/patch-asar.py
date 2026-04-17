#!/usr/bin/env python3
"""Patch the Codex desktop app's asar to enable hot-swap account switching.

When CodexSwitch writes new auth.json and the Rust app-server sends
AccountUpdated/AccountLoginCompleted notifications, the Electron frontend
needs to invalidate its React Query caches to show the new account.

This script:
1. Extracts app.asar to a temp directory (alongside the .unpacked companion)
2. Finds the use-auth JS file (by content pattern, not filename)
3. Patches it to invalidate React Query caches on account/updated
4. Repacks with --unpack to preserve native modules (.node, spawn-helper)
5. Re-signs the app

The patch adds:
- Module-level vars to capture the QueryClient instance from React hooks
- _invalidateAccountQueries() to bust `accounts/check` and `account-info` caches
- A call to _invalidateAccountQueries() in the auth status callback, before
  the getAccount() refresh, so the UI picks up the new account immediately

Exit codes:
  0 = patched successfully (or already patched)
  1 = error
  2 = no patch needed (file not found or structure changed)
"""

from __future__ import annotations
import atexit
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
APP_RESOURCES = Path("/Applications/Codex.app/Contents/Resources")
ASAR_PATH = APP_RESOURCES / "app.asar"
ASAR_UNPACKED = APP_RESOURCES / "app.asar.unpacked"
ASAR_BACKUP = APP_RESOURCES / "app.asar.bak"

# Marker to detect if already patched
PATCH_MARKER = "_invalidateAccountQueries"

# Glob pattern for asar --unpack: native .node modules + node-pty spawn-helper
UNPACK_GLOB = "{*.node,spawn-helper}"


# ---------------------------------------------------------------------------
# Temp-dir management
# ---------------------------------------------------------------------------
_cleanup_dirs: list[Path] = []


def _cleanup():
    for d in _cleanup_dirs:
        shutil.rmtree(d, ignore_errors=True)


atexit.register(_cleanup)


def make_workdir() -> Path:
    """Create a temp directory that will be cleaned up on exit."""
    d = Path(tempfile.mkdtemp(prefix="codex-asar-patch-"))
    _cleanup_dirs.append(d)
    return d


# ---------------------------------------------------------------------------
# asar extract / pack
# ---------------------------------------------------------------------------
def extract_asar(asar_path: Path, dest: Path) -> bool:
    """Extract an asar archive.

    The asar tool looks for a companion `<name>.unpacked` directory next to
    the archive for files marked as external (native modules).  When we
    extract the backup, the companion dir has a different name, so we copy
    the original unpacked dir alongside the archive first.
    """
    result = subprocess.run(
        ["npx", "asar", "extract", str(asar_path), str(dest)],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        print(f"asar extract stderr: {result.stderr.strip()}")
    return result.returncode == 0


def pack_asar(src: Path, dest_asar: Path) -> bool:
    """Repack a directory into an asar archive.

    CRITICAL: --unpack keeps native modules (.node files, spawn-helper)
    external in a companion .unpacked directory.  Without this flag the
    repacked asar tries to embed them as regular files, which breaks
    require() for native addons and crashes the app on launch.
    """
    result = subprocess.run(
        [
            "npx", "asar", "pack",
            str(src), str(dest_asar),
            "--unpack", UNPACK_GLOB,
        ],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        print(f"asar pack stderr: {result.stderr.strip()}")
    return result.returncode == 0


def validate_asar(asar_path: Path) -> bool:
    """Validate the repacked asar by listing its contents."""
    result = subprocess.run(
        ["npx", "asar", "list", str(asar_path)],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        print(f"asar list stderr: {result.stderr.strip()}")
        return False
    entries = result.stdout.strip().splitlines()
    # Sanity: should have webview/assets, package.json, native modules
    has_package = any("/package.json" in e for e in entries)
    has_webview = any("/webview/" in e for e in entries)
    has_native = any(".node" in e for e in entries)
    if not (has_package and has_webview and has_native):
        print("ERROR: Repacked asar missing expected entries")
        print(f"  package.json: {has_package}, webview: {has_webview}, native: {has_native}")
        return False
    return True


# ---------------------------------------------------------------------------
# Find the auth file
# ---------------------------------------------------------------------------
def find_auth_file(assets_dir: Path) -> Path | None:
    """Find the auth-hooks JS file by content pattern (filename changes per version).

    Known naming conventions across Codex versions:
      - use-auth-HASH.js      (v0.117 and earlier)
      - app-server-manager-hooks-HASH.js  (v0.118+)
    Falls back to scanning all JS files if neither matches.
    """
    if not assets_dir.exists():
        return None
    content_markers = ("addAuthStatusCallback", "getAccount")
    # Primary: known filename patterns (fast — avoids reading every JS file)
    for pattern in ("use-auth-*.js", "app-server-manager-hooks-*.js"):
        for f in assets_dir.glob(pattern):
            content = f.read_text()
            if all(m in content for m in content_markers):
                return f
    # Fallback: search all JS files (survives any future rename)
    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if all(m in content for m in content_markers) and "authMethod" in content:
            return f
    return None


# ---------------------------------------------------------------------------
# Patch logic -- uses exact string matching, not fragile regex
# ---------------------------------------------------------------------------
def identify_aliases(content: str) -> tuple[str, str] | None:
    """Identify the useQueryClient and queryKey-builder aliases.

    Scans ALL import statements (not just a specific module) so the patch
    survives Codex updates that rename or reorganize bundled JS chunks.

    We identify aliases by their *usage* patterns:
      - useQueryClient alias: called as `<alias>()` in a function whose body
        contains `.invalidateQueries`
      - queryKey builder alias: used as `queryKey:<alias>(`...`)`
    """
    # Collect local names from ALL import statements — import source is irrelevant
    local_names: set[str] = set()
    for m in re.finditer(r'import\{([^}]+)\}from"[^"]+"', content):
        for spec in m.group(1).split(","):
            parts = spec.strip().split(" as ")
            name = parts[-1].strip()
            if name:
                local_names.add(name)

    if not local_names:
        print("ERROR: No import statements found")
        return None

    uqc_alias = None
    qk_alias = None

    for name in local_names:
        # useQueryClient: <name>() appears before .invalidateQueries in same function
        if not uqc_alias and re.search(
            rf'(?<!\w){re.escape(name)}\(\).*?\.invalidateQueries', content, re.DOTALL
        ):
            uqc_alias = name
        # queryKey builder: queryKey:<name>(` in a React Query call
        if not qk_alias and re.search(rf'queryKey:{re.escape(name)}\(`', content):
            qk_alias = name
        # Early exit once both found
        if uqc_alias and qk_alias:
            break

    if not uqc_alias or not qk_alias:
        print(f"ERROR: Could not identify aliases (uqc={uqc_alias}, qk={qk_alias})")
        print(f"  Scanned {len(local_names)} imported names from all modules")
        return None

    return uqc_alias, qk_alias


def apply_patch(file_path: Path) -> bool:
    """Apply the React Query cache invalidation patch.

    Three modifications to the minified JS:

    1. After the last import statement, insert module-level vars and the
       _invalidateAccountQueries() helper function.

    2. In the function that calls useQueryClient() (function d), capture the
       QueryClient instance into _qcRef so our helper can use it.

    3. In the auth status callback (the arrow function passed to
       addAuthStatusCallback), insert a call to _invalidateAccountQueries()
       before the existing getAccount() call so caches are busted first.
    """
    content = file_path.read_text()

    if PATCH_MARKER in content:
        print(f"  Already patched: {file_path.name}")
        return True

    # --- Identify aliases ---
    aliases = identify_aliases(content)
    if not aliases:
        return False
    uqc_alias, qk_alias = aliases
    print(f"  useQueryClient alias: {uqc_alias}")
    print(f"  queryKey builder alias: {qk_alias}")

    # --- Find the useQueryClient call variable name ---
    # In function d():  let e=(0,u.c)(2),t=<uqc_alias>(),n;
    # We need to know that `t` is the var holding the QueryClient.
    uqc_call_match = re.search(
        rf'(\w)={re.escape(uqc_alias)}\(\)', content
    )
    if not uqc_call_match:
        print("ERROR: Cannot find useQueryClient() call")
        return False
    qc_var = uqc_call_match.group(1)
    print(f"  QueryClient variable: {qc_var}")

    # --- Find the getAccount-wrapper variable name ---
    # In the effect body: l=()=>{e.getAccount()...  then  l()  is called.
    # The auth callback ends with: }),l()
    # We find the local function name by looking for: <var>=()=>{e.getAccount()
    ga_match = re.search(r'(\w)=\(\)=>\{e\.getAccount\(\)', content)
    if not ga_match:
        # Broader: <var>=()=>{ ... .getAccount()
        ga_match = re.search(r'(\w)=\(\)=>\{[^}]*\.getAccount\(\)', content)
    if not ga_match:
        print("ERROR: Cannot find getAccount wrapper function")
        return False
    ga_var = ga_match.group(1)
    print(f"  getAccount wrapper variable: {ga_var}")

    patched = content

    # --- PATCH 1: Insert module vars + invalidation function after last import ---
    # The imports end with: from"./use-global-state-HASH.js";
    # We find the last `from"./` import statement end.
    last_import_match = None
    for m in re.finditer(r'from"\.\/[^"]+\.js";', patched):
        last_import_match = m
    if not last_import_match:
        print("ERROR: Cannot find end of import statements")
        return False

    insert_pos = last_import_match.end()

    module_patch = (
        f'var _qcHook={uqc_alias},_qkBuild={qk_alias},_qcRef=null;'
        f'function {PATCH_MARKER}()'
        '{if(_qcRef){'
        '_qcRef.invalidateQueries({queryKey:[`accounts`,`check`]});'
        '_qcRef.invalidateQueries({queryKey:_qkBuild(`account-info`)})'
        '}}'
    )
    patched = patched[:insert_pos] + module_patch + patched[insert_pos:]

    # --- PATCH 2: Capture QueryClient in function d() ---
    # Original: t=<uqc>(),n;return
    # Patched:  t=<uqc>(),n;_qcRef=t;return
    old_capture = f"{qc_var}={uqc_alias}(),n;return"
    new_capture = f"{qc_var}={uqc_alias}(),n;_qcRef={qc_var};return"
    if old_capture not in patched:
        # The previous patch may have already been partially applied or
        # the variable after the call might differ. Try a regex approach.
        cap_re = re.search(
            rf'({re.escape(qc_var)}={re.escape(uqc_alias)}\(\),\w;)(return)',
            patched,
        )
        if cap_re:
            old_capture = cap_re.group(0)
            new_capture = f"{cap_re.group(1)}_qcRef={qc_var};{cap_re.group(2)}"
        else:
            print(f"WARNING: Cannot find QueryClient capture site (looked for: {old_capture!r})")
            print("  Falling back to broader match...")
            # Broadest: just find `<var>=<uqc>()` and append `;_qcRef=<var>`
            uqc_call_str = f"{qc_var}={uqc_alias}()"
            idx = patched.find(uqc_call_str)
            if idx < 0:
                print("ERROR: Cannot find useQueryClient() call to patch")
                return False
            after = idx + len(uqc_call_str)
            patched = patched[:after] + f";_qcRef={qc_var}" + patched[after:]
            old_capture = None  # skip the replace below

    if old_capture is not None:
        count = patched.count(old_capture)
        if count != 1:
            print(f"WARNING: Expected 1 occurrence of capture site, found {count}")
        patched = patched.replace(old_capture, new_capture, 1)

    # --- PATCH 3: Insert _invalidateAccountQueries() in auth status callback ---
    # The callback pattern is:
    #   let u=e=>{d(t=>...authMethod...)},l();
    # where the `)` closes the d() call, `},` ends the arrow function body,
    # and `l()` is the getAccount wrapper.
    #
    # We want to insert _invalidateAccountQueries() between }),  and l():
    #   }),_invalidateAccountQueries(),l()
    old_callback_tail = "})," + ga_var + "()"
    new_callback_tail = "})," + PATCH_MARKER + "()," + ga_var + "()"

    if old_callback_tail not in patched:
        print(f"ERROR: Cannot find callback tail pattern: {old_callback_tail!r}")
        # Show context around addAuthStatusCallback for debugging
        idx = patched.find("addAuthStatusCallback")
        if idx >= 0:
            context_start = max(0, idx - 200)
            context_end = min(len(patched), idx + 200)
            print(f"  Context: ...{patched[context_start:context_end]}...")
        return False

    count = patched.count(old_callback_tail)
    if count != 1:
        print(f"WARNING: Expected 1 occurrence of callback tail, found {count}")
    patched = patched.replace(old_callback_tail, new_callback_tail, 1)

    # --- Verify the patch looks right ---
    if PATCH_MARKER not in patched:
        print("ERROR: Patch marker not found after patching -- something went wrong")
        return False

    # Sanity: make sure we didn't break the basic structure
    if "addAuthStatusCallback" not in patched:
        print("ERROR: addAuthStatusCallback disappeared after patching")
        return False
    if "export{" not in patched:
        print("ERROR: export statement disappeared after patching")
        return False

    file_path.write_text(patched)
    print(f"  Patched: {file_path.name}")
    return True


# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------
def codesign_app():
    """Ad-hoc re-sign Codex.app after modification."""
    result = subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", "/Applications/Codex.app"],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        print(f"WARNING: codesign failed: {result.stderr.strip()}")
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not ASAR_PATH.exists():
        print("Codex.app not found at /Applications/Codex.app")
        sys.exit(2)

    # ---- Quick idempotency check: extract to temp, look for marker ----
    # We always extract the *current* asar (not the backup) because that is
    # what the app actually loads.  If it is already patched, we exit early.
    workdir = make_workdir()
    asar_copy = workdir / "app.asar"
    extract_dir = workdir / "extracted"

    # Copy the asar + its unpacked companion into the workdir so that the
    # asar tool can resolve external file references.
    print("Copying asar to work directory...")
    shutil.copy2(ASAR_PATH, asar_copy)
    if ASAR_UNPACKED.exists():
        shutil.copytree(ASAR_UNPACKED, workdir / "app.asar.unpacked")

    print("Extracting app.asar...")
    if not extract_asar(asar_copy, extract_dir):
        print("ERROR: Failed to extract asar")
        sys.exit(1)

    assets_dir = extract_dir / "webview" / "assets"
    auth_file = find_auth_file(assets_dir)
    if not auth_file:
        print("WARNING: Could not find use-auth JS file -- app structure may have changed")
        sys.exit(2)

    print(f"Found auth file: {auth_file.name}")

    if PATCH_MARKER in auth_file.read_text():
        print("Already patched, nothing to do.")
        sys.exit(0)

    # ---- Apply patch ----
    print("Applying patch...")
    if not apply_patch(auth_file):
        print("ERROR: Patch failed")
        sys.exit(1)

    # ---- Repack ----
    print("Repacking app.asar (with --unpack for native modules)...")
    repacked_asar = workdir / "repacked.asar"
    if not pack_asar(extract_dir, repacked_asar):
        print("ERROR: Failed to repack asar")
        sys.exit(1)

    # ---- Validate ----
    print("Validating repacked asar...")
    if not validate_asar(repacked_asar):
        print("ERROR: Repacked asar failed validation")
        sys.exit(1)

    # Verify the unpacked companion was created
    repacked_unpacked = workdir / "repacked.asar.unpacked"
    if not repacked_unpacked.exists():
        print("ERROR: No .unpacked directory created -- native modules would be broken")
        sys.exit(1)

    # Count native modules
    node_files = list(repacked_unpacked.rglob("*.node"))
    print(f"  Unpacked native modules: {len(node_files)}")
    for nf in node_files:
        print(f"    {nf.relative_to(repacked_unpacked)}")

    # ---- Backup + install ----
    if not ASAR_BACKUP.exists():
        print("Creating backup: app.asar.bak")
        shutil.copy2(ASAR_PATH, ASAR_BACKUP)
    else:
        print("Backup already exists: app.asar.bak")

    print("Installing patched asar...")
    # Replace the asar
    shutil.copy2(repacked_asar, ASAR_PATH)
    # Replace the unpacked directory
    if ASAR_UNPACKED.exists():
        shutil.rmtree(ASAR_UNPACKED)
    shutil.copytree(repacked_unpacked, ASAR_UNPACKED)

    # ---- Re-sign ----
    print("Re-signing Codex.app...")
    codesign_app()

    # ---- Clean up old extracted dir if left behind by previous runs ----
    old_extracted = APP_RESOURCES / "app.asar.extracted"
    if old_extracted.exists():
        print("Cleaning up leftover app.asar.extracted directory...")
        shutil.rmtree(old_extracted, ignore_errors=True)

    print("Done! Codex desktop app will use the patch on next restart.")
    sys.exit(0)


if __name__ == "__main__":
    main()

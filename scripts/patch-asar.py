#!/usr/bin/env python3
"""Patch the Codex desktop app's asar to enable hot-swap account switching.

When CodexSwitch writes new auth.json and the Rust app-server sends
AccountUpdated/AccountLoginCompleted notifications, the Electron frontend
needs to invalidate its React Query caches to show the new account.

This script:
1. Extracts app.asar to a temp directory (alongside the .unpacked companion)
2. Finds the use-auth JS file (by content pattern, not filename)
3. Patches it to invalidate React Query caches on account/updated
4. Removes CodexSwitch Headroom env bridges from desktop app-server launch paths
5. Removes inherited CODEX_CLI_PATH from desktop app-server launch paths so
   Codex.app cannot be forced onto a stale Homebrew wrapper
6. Repacks with --unpack to preserve native modules (.node, spawn-helper)
7. Re-signs the app

The patch adds:
- Module-level vars to capture the QueryClient instance from React hooks
- _invalidateAccountQueries() to bust `accounts/check` and `account-info` caches
- A call to _invalidateAccountQueries() in the auth status callback, before
  the getAccount() refresh, so the UI picks up the new account immediately
- No Headroom bridge for Codex.app: desktop traffic stays on stock OpenAI
  transport so silent optimizer filtering cannot affect app-server diagnostics

Exit codes:
  0 = patched successfully (or already patched)
  1 = error
  2 = no patch needed (file not found or structure changed)
"""

from __future__ import annotations
import atexit
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path
from typing import NamedTuple

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
UNIFIED_APP_PATH = Path("/Applications/ChatGPT.app")
LEGACY_APP_PATH = Path("/Applications/Codex.app")


def resolve_default_app_path(candidates: list[Path] | None = None) -> Path:
    override = os.environ.get("CODEXSWITCH_CODEX_APP_PATH") or os.environ.get("CODEX_APP")
    if override:
        return Path(override).expanduser()

    ordered = candidates or [UNIFIED_APP_PATH, LEGACY_APP_PATH]
    return next((path for path in ordered if path.exists()), ordered[0])


DEFAULT_APP_PATH = resolve_default_app_path()
APP_PATH = DEFAULT_APP_PATH
INFO_PLIST_PATH = APP_PATH / "Contents" / "Info.plist"
APP_RESOURCES = APP_PATH / "Contents" / "Resources"
ASAR_PATH = APP_RESOURCES / "app.asar"
ASAR_UNPACKED = APP_RESOURCES / "app.asar.unpacked"
BUNDLED_CLI_PATH = APP_RESOURCES / "codex"
COMPUTER_USE_PLUGIN_APP_RELATIVE = Path(
    "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
)
SKY_COMPUTER_USE_CLIENT_APP_RELATIVE = (
    COMPUTER_USE_PLUGIN_APP_RELATIVE
    / "Contents/SharedSupport/SkyComputerUseClient.app"
)
BACKUP_ROOT = Path(
    os.environ.get(
        "CODEXSWITCH_BACKUP_ROOT",
        str(Path.home() / ".codexswitch" / "backups" / APP_PATH.name),
    )
).expanduser()
ASAR_BACKUP = BACKUP_ROOT / "app.asar.bak"

# Marker to detect if already patched
PATCH_MARKER = "_invalidateAccountQueries"
AUTH_CACHE_PATCH_MARKER = "CODEXSWITCH_AUTH_CACHE_INVALIDATION_V2"
FAST_FALLBACK_MARKER = "_bundledFastModels"
HEADROOM_ENV_MARKER = "CODEXSWITCH_HEADROOM_BASE_URL"
HEADROOM_TRANSPORT_PATCH_MARKER = "CODEXSWITCH_HEADROOM_TRANSPORT_PATCH"
HEADROOM_GLOBAL_ENV_MARKER = "CODEXSWITCH_HEADROOM_GLOBAL_ENV_PATCH"
DESKTOP_CLI_PATH_GUARD_MARKER = "CODEXSWITCH_DESKTOP_CLI_PATH_GUARD"
BUNDLED_PLUGIN_SYNC_COMPAT_MARKER = "CODEXSWITCH_BUNDLED_PLUGIN_SYNC_COMPAT"
BUNDLED_PLUGIN_LIST_ROOT_MARKER = "CODEXSWITCH_BUNDLED_PLUGIN_LIST_ROOT_PATCH"
LEGACY_REMOTE_RECENTS_REFRESH_MARKER = "CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH"
REMOTE_RECENTS_REFRESH_MARKER = "CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2"
REMOTE_RECENTS_REFRESH_INTERVAL_MS = 60_000
MODEL_LABEL_FALLBACK_MARKER = "CODEXSWITCH_MODEL_LABEL_FALLBACK"
MODEL_AVAILABILITY_FALLBACK_MARKER = "CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK"
SELECTED_MODEL_LABEL_FALLBACK_MARKER = "CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK"
REMOTE_MODEL_REFRESH_MARKER = "CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH"
GPT56_MAX_EFFORT_FALLBACK_MARKER = "CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK"
BUNDLED_PLUGIN_MARKETPLACE_ROOT = str(
    APP_PATH / "Contents/Resources/plugins/openai-bundled"
)
OPENAI_TEAM_ID = "2DC432GLL2"
OFFICIAL_CODEX_DMG_URL = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
IPHONE_DEVELOPER_PREFIX = "iPhone Developer"
CODESIGN_IDENTITY_PREFIXES = (
    "Developer ID Application",
    "Apple Distribution",
    "Apple Development",
    "Mac Developer",
    IPHONE_DEVELOPER_PREFIX,
)
ILOADER_KEY_ROOT = Path.home() / "Library/Application Support/me.nabdev.iloader/keys"
SIGHUP_CLI_MARKERS = (
    b"sighup-verified",
    b"sighup-verified-tui",
    b"sighup-verified-exec",
)
SIGHUP_RELOAD_MARKER = b"SIGHUP: auth reloaded"
SIGHUP_REQUIRED_MARKERS = (
    b"hotswap-ack",
    b"CodexSwitch rotated accounts after a usage limit",
    b"CodexSwitch rotated accounts after an auth failure",
    b"Auth changed, opening new WebSocket with fresh credentials",
    b"codexswitch-runtime-convergence-v3",
    b"codexswitch-runtime-rotation-handoff-v1",
    b"CodexSwitch account/updated frontend write acknowledged after auth reload",
    b"codexswitch-hotswap-contract-v3",
    b"codexswitch-hotswap-cli-contract-v3",
)
GOAL_USAGE_MARKER = b"Usage: /goal <objective>"
GOAL_STATUS_MARKER = b"Pursuing goal"
GOAL_RPC_MARKER = b"thread/goal/set"
GPT55_MODEL_MARKER = b"gpt-5.5"
MIN_GPT55_VERSION = (0, 125, 0)
CLI_MARKER_SCAN_CHUNK_SIZE = 1024 * 1024
CLI_MARKER_SCAN_CACHE_LIMIT = 64

# Glob pattern for asar --unpack: native .node modules + node-pty spawn-helper
UNPACK_GLOB = "{*.node,spawn-helper}"
BUNDLE_CODE_SUFFIXES = {".app", ".framework", ".xpc"}
FILE_CODE_SUFFIXES = {".dylib", ".so", ".node"}
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
RESOURCE_EXECUTABLE_NAMES = {
    "codex",
    "node",
    "node_repl",
    "rg",
    "launch-services-helper",
    "spawn-helper",
}
LOCAL_DESKTOP_APP_ENTITLEMENTS = {
    "com.apple.security.automation.apple-events": True,
    "com.apple.security.cs.allow-jit": True,
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
    "com.apple.security.cs.disable-library-validation": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.device.camera": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
}


class CLIMarkerScan(NamedTuple):
    has_sighup_contract: bool
    supports_gpt55: bool


_CLI_MARKER_SCAN_CACHE: OrderedDict[
    tuple[int, int, int, int, int], CLIMarkerScan
] = OrderedDict()


def _cli_marker_stat_key(file_stat: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def scan_cli_markers(
    path: Path,
    *,
    chunk_size: int = CLI_MARKER_SCAN_CHUNK_SIZE,
) -> CLIMarkerScan | None:
    """Inspect CLI capabilities with bounded reads and identity-keyed reuse."""
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")

    try:
        before = path.stat()
    except OSError:
        return None
    if not stat.S_ISREG(before.st_mode):
        return None

    cache_key = _cli_marker_stat_key(before)
    cached = _CLI_MARKER_SCAN_CACHE.get(cache_key)
    if cached is not None:
        _CLI_MARKER_SCAN_CACHE.move_to_end(cache_key)
        return cached

    markers = set(SIGHUP_CLI_MARKERS)
    markers.add(SIGHUP_RELOAD_MARKER)
    markers.update(SIGHUP_REQUIRED_MARKERS)
    markers.update(
        (GOAL_USAGE_MARKER, GOAL_STATUS_MARKER, GOAL_RPC_MARKER, GPT55_MODEL_MARKER)
    )
    found: set[bytes] = set()
    overlap_size = max(len(marker) for marker in markers) - 1
    overlap = b""

    try:
        with path.open("rb") as handle:
            while chunk := handle.read(chunk_size):
                window = overlap + chunk
                for marker in markers - found:
                    if marker in window:
                        found.add(marker)
                overlap = window[-overlap_size:] if overlap_size else b""
        after = path.stat()
    except OSError:
        return None

    if _cli_marker_stat_key(after) != cache_key:
        return None

    result = CLIMarkerScan(
        has_sighup_contract=(
            any(marker in found for marker in SIGHUP_CLI_MARKERS)
            and SIGHUP_RELOAD_MARKER in found
            and all(marker in found for marker in SIGHUP_REQUIRED_MARKERS)
            and (
                GOAL_USAGE_MARKER in found
                or (GOAL_STATUS_MARKER in found and GOAL_RPC_MARKER in found)
            )
        ),
        supports_gpt55=GPT55_MODEL_MARKER in found,
    )
    _CLI_MARKER_SCAN_CACHE[cache_key] = result
    _CLI_MARKER_SCAN_CACHE.move_to_end(cache_key)
    while len(_CLI_MARKER_SCAN_CACHE) > CLI_MARKER_SCAN_CACHE_LIMIT:
        _CLI_MARKER_SCAN_CACHE.popitem(last=False)
    return result


def cli_has_sighup_patch(path: Path) -> bool:
    """Return true when a Codex CLI satisfies the patched runtime contract."""
    scan = scan_cli_markers(path)
    return scan is not None and scan.has_sighup_contract


def parse_cli_version(text: str) -> tuple[int, int, int] | None:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def read_cli_version(path: Path) -> tuple[int, int, int] | None:
    try:
        result = subprocess.run(
            [str(path), "--version"],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return parse_cli_version(result.stdout.strip())


def cli_supports_gpt55(path: Path) -> bool:
    scan = scan_cli_markers(path)
    if scan is not None and scan.supports_gpt55:
        return True

    version = read_cli_version(path)
    return version is not None and version >= MIN_GPT55_VERSION


def cli_candidate_priority(path: Path) -> tuple[bool, tuple[int, int, int]]:
    version = read_cli_version(path) or (0, 0, 0)
    return (cli_supports_gpt55(path), version)


def iter_sighup_cli_candidates() -> list[Path]:
    """Return candidate patched CLI binaries, strongest hints first."""
    candidates: list[Path] = []
    for key in ("CODEXSWITCH_SIGHUP_CLI", "CODEX_CLI_PATH"):
        value = os.environ.get(key)
        if value:
            candidates.append(Path(value).expanduser())

    candidates.extend(
        [
            Path.home() / "Developer" / "codex" / "codex-rs" / "target" / "release" / "codex",
            Path.home() / "Developer" / "codex" / "codex-rs" / "target" / "debug" / "codex",
            Path("/opt/homebrew/bin/codex"),
            Path("/usr/local/bin/codex"),
            Path.home() / ".local" / "bin" / "codex",
        ]
    )

    which_codex = shutil.which("codex")
    if which_codex:
        candidates.append(Path(which_codex))

    return candidates


def find_sighup_capable_cli() -> Path | None:
    for key in ("CODEXSWITCH_SIGHUP_CLI", "CODEX_CLI_PATH"):
        value = os.environ.get(key)
        if not value:
            continue
        candidate = Path(value).expanduser()
        if candidate != BUNDLED_CLI_PATH and candidate.exists() and cli_has_sighup_patch(candidate):
            return candidate

    best: Path | None = None
    best_priority = (False, (0, 0, 0))
    seen: set[Path] = set()
    for candidate in iter_sighup_cli_candidates():
        for path in (candidate, candidate.resolve(strict=False)):
            if path in seen:
                continue
            seen.add(path)
            if path == BUNDLED_CLI_PATH:
                continue
            if not path.exists() or not cli_has_sighup_patch(path):
                continue
            priority = cli_candidate_priority(path)
            if best is None or priority > best_priority:
                best = path
                best_priority = priority
    return best


def app_path_for_bundled_cli() -> Path:
    try:
        return BUNDLED_CLI_PATH.parent.parent.parent
    except IndexError:
        return APP_PATH


def ensure_bundled_cli_hot_swap() -> tuple[bool, bool]:
    """Ensure Codex.app's bundled CLI is compatible with patched desktop use.

    Returns (ok, changed). The caller is responsible for signing the app after
    changed=True.
    """
    if not BUNDLED_CLI_PATH.exists():
        print(f"ERROR: Bundled Codex CLI not found: {BUNDLED_CLI_PATH}")
        return False, False

    app_path = app_path_for_bundled_cli()
    if computer_use_plugin_signing_targets(app_path):
        if bundled_cli_preserves_computer_use_parent_requirement():
            print("Bundled Codex CLI preserves OpenAI signature required by Computer Use.")
            return True, False
        print("Restoring official OpenAI-signed bundled CLI required by Computer Use.")
        return restore_official_bundled_cli(app_path)

    bundled_has_patch = cli_has_sighup_patch(BUNDLED_CLI_PATH)
    bundled_supports_gpt55 = cli_supports_gpt55(BUNDLED_CLI_PATH)
    bundled_priority = cli_candidate_priority(BUNDLED_CLI_PATH)

    if bundled_has_patch and bundled_supports_gpt55:
        print("Bundled Codex CLI already has SIGHUP hot-swap support.")
        return True, False

    source = find_sighup_capable_cli()
    if source is None:
        if bundled_has_patch:
            print(
                "ERROR: Bundled Codex CLI has hot-swap markers but is too old for "
                "GPT-5.5 and no newer patched CLI candidate was found"
            )
            return False, False
        print(
            "ERROR: Could not find a SIGHUP-capable Codex CLI to install into "
            f"{BUNDLED_CLI_PATH}"
        )
        return False, False

    source_supports_gpt55 = cli_supports_gpt55(source)
    source_priority = cli_candidate_priority(source)

    if bundled_supports_gpt55 and not source_supports_gpt55:
        print(
            "ERROR: Refusing to replace a GPT-5.5-capable bundled Codex CLI with "
            f"older patched source {source}"
        )
        return False, False

    if bundled_has_patch and bundled_priority >= source_priority:
        if bundled_supports_gpt55:
            print("Bundled Codex CLI already has SIGHUP hot-swap support.")
            return True, False
        print(
            "ERROR: Bundled Codex CLI is patched but still too old for GPT-5.5; "
            f"best candidate {source} is not newer"
        )
        return False, False

    print(f"Installing SIGHUP-capable bundled CLI from {source}")
    try:
        shutil.copy2(source, BUNDLED_CLI_PATH)
        os.chmod(BUNDLED_CLI_PATH, 0o755)
    except OSError as exc:
        print(f"ERROR: Failed to install bundled Codex CLI: {exc}")
        return False, False

    if not cli_has_sighup_patch(BUNDLED_CLI_PATH):
        print("ERROR: Bundled Codex CLI still lacks SIGHUP support after copy")
        return False, False

    return True, True


def select_codesign_identity() -> str:
    """Pick a usable non-ad-hoc signing identity.

    Xcode account login alone is not enough for command-line signing; the
    private key must exist in Keychain and appear in `security find-identity`.
    """
    explicit = os.environ.get("CODEXSWITCH_CODESIGN_IDENTITY") or os.environ.get(
        "CODESIGN_IDENTITY"
    )
    if explicit:
        return explicit

    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        return "-"

    identities: list[str] = []
    for line in result.stdout.splitlines():
        match = re.search(r'"([^"]+)"', line)
        if match:
            identities.append(match.group(1))

    ranked_identities = []
    for prefix in CODESIGN_IDENTITY_PREFIXES:
        for identity in identities:
            if identity.startswith(prefix):
                ranked_identities.append(identity)

    for identity in ranked_identities:
        if codesign_identity_is_apple_issued(identity):
            return identity
    return "-"


def codesign_identity_is_apple_issued(identity: str) -> bool:
    """Return true when Keychain has an Apple-issued certificate for identity."""
    try:
        result = subprocess.run(
            ["security", "find-certificate", "-a", "-p", "-c", identity],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0 or "BEGIN CERTIFICATE" not in result.stdout:
        return False

    certs = re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        result.stdout,
        flags=re.DOTALL,
    )
    for cert in certs:
        try:
            decoded = subprocess.run(
                ["openssl", "x509", "-noout", "-subject", "-issuer"],
                input=cert,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if decoded.returncode != 0:
            continue
        output = decoded.stdout + "\n" + decoded.stderr
        subject = re.search(r"^subject=(.+)$", output, flags=re.MULTILINE)
        issuer = re.search(r"^issuer=(.+)$", output, flags=re.MULTILINE)
        subject_text = subject.group(1).strip() if subject else ""
        issuer_text = issuer.group(1).strip() if issuer else ""
        if "Apple" in issuer_text and issuer_text != subject_text:
            return True
    return False


def certificate_is_apple_issued_iphone_developer(cert_path: Path) -> bool:
    try:
        decoded = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-issuer", "-in", str(cert_path)],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if decoded.returncode != 0:
        return False
    output = decoded.stdout + "\n" + decoded.stderr
    subject = re.search(r"^subject=(.+)$", output, flags=re.MULTILINE)
    issuer = re.search(r"^issuer=(.+)$", output, flags=re.MULTILINE)
    subject_text = subject.group(1).strip() if subject else ""
    issuer_text = issuer.group(1).strip() if issuer else ""
    return (
        IPHONE_DEVELOPER_PREFIX in subject_text
        and "Apple" in issuer_text
        and issuer_text != subject_text
    )


def cached_iphone_developer_keypairs(root: Path = ILOADER_KEY_ROOT) -> list[tuple[Path, Path]]:
    if not root.exists():
        return []
    pairs: list[tuple[Path, Path]] = []
    for cert_path in sorted(root.glob("*/cert.pem")):
        key_path = cert_path.with_name("key.pem")
        if not key_path.exists():
            continue
        if certificate_is_apple_issued_iphone_developer(cert_path):
            pairs.append((cert_path, key_path))
    return pairs


def import_cached_iphone_developer_identity() -> bool:
    """Import the cached Apple-issued iPhone Developer cert/key if Keychain forgot it."""
    keypairs = cached_iphone_developer_keypairs()
    if not keypairs:
        return False

    keychain = Path.home() / "Library/Keychains/login.keychain-db"
    for cert_path, key_path in keypairs:
        with tempfile.TemporaryDirectory(prefix="codexswitch-signing.") as tmp:
            p12_path = Path(tmp) / "iphone-developer.p12"
            # macOS 26's security import can reject empty-password PKCS#12 files
            # with a bogus MAC verification failure. This password only protects
            # the temporary local package, not the underlying cached key file.
            p12_password = "codexswitch-local-import"
            exported = subprocess.run(
                [
                    "openssl",
                    "pkcs12",
                    "-legacy",
                    "-export",
                    "-inkey",
                    str(key_path),
                    "-in",
                    str(cert_path),
                    "-out",
                    str(p12_path),
                    "-passout",
                    f"pass:{p12_password}",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if exported.returncode != 0:
                print(
                    "WARNING: Failed to export cached iPhone Developer signing identity: "
                    + exported.stderr.strip()
                )
                continue

            imported = subprocess.run(
                [
                    "security",
                    "import",
                    str(p12_path),
                    "-k",
                    str(keychain),
                    "-P",
                    p12_password,
                    "-A",
                    "-T",
                    "/usr/bin/codesign",
                    "-T",
                    "/usr/bin/security",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if imported.returncode == 0:
                print(f"Imported cached Apple-issued iPhone Developer identity from {cert_path.parent}")
                return True
            print(
                "WARNING: Failed to import cached iPhone Developer signing identity: "
                + (imported.stderr.strip() or imported.stdout.strip())
            )
    return False


def select_or_repair_codesign_identity() -> str:
    identity = select_codesign_identity()
    if identity != "-":
        return identity
    if import_cached_iphone_developer_identity():
        return select_codesign_identity()
    return "-"


def requested_codesign_identity(argv: list[str]) -> str | None:
    """Return an identity only for an explicit inspection or repair command."""
    if "--print-codesign-identity" in argv:
        return select_codesign_identity()
    if "--repair-codesign-identity" in argv:
        return select_or_repair_codesign_identity()
    return None


def identity_allows_local_execute_assessment_fallback(identity: str) -> bool:
    return identity.startswith(IPHONE_DEVELOPER_PREFIX) and codesign_identity_is_apple_issued(
        identity
    )


def usable_codesign_identity_available() -> bool:
    identity = select_or_repair_codesign_identity()
    if identity == "-":
        print(
            "ERROR: No usable non-ad-hoc code signing identity is available. "
            "Refusing to patch Codex.app because ad-hoc signing makes the app "
            "unopenable on this Mac. Checked Developer ID, Apple Development, "
            "Mac Developer, and cached Apple-issued iPhone Developer fallback identities."
        )
        return False
    return True


def resolve_asar_cmd() -> list[str]:
    """Use a cached asar CLI when disk pressure makes `npx` unreliable."""
    node = shutil.which("node")
    override = os.environ.get("CODEXSWITCH_ASAR_JS")
    if node and override:
        asar_js = Path(override).expanduser()
        if asar_js.is_file():
            return [node, str(asar_js)]
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


def codex_app_is_running() -> bool:
    """Return true when the ChatGPT/Codex desktop host or app-server is live.

    Crashpad, Computer Use, and a standalone CLI launched from the bundle do not
    load the desktop ASAR/app-server runtime and should not block an offline
    desktop patch after the user has quit Codex.app.
    """
    result = subprocess.run(
        ["pgrep", "-fl", str(APP_PATH / "Contents")],
        capture_output=True,
        text=True,
        timeout=3,
    )
    if result.returncode != 0:
        return False
    desktop_hosts = {
        str(APP_PATH / "Contents/MacOS/ChatGPT").lower(),
        str(APP_PATH / "Contents/MacOS/Codex").lower(),
        "/applications/chatgpt.app/contents/macos/chatgpt",
        "/applications/codex.app/contents/macos/codex",
    }
    for line in result.stdout.splitlines():
        lower = line.lower()
        if "pgrep" in lower or "codexswitch" in lower:
            continue
        if any(host in lower for host in desktop_hosts):
            return True
        if " codex app-server" in lower or lower.endswith(" codex app-server"):
            return True
        if "/vendor/aarch64-apple-darwin/codex/codex app-server" in lower:
            return True
    return False


def resolve_asar_module_dir() -> Path | None:
    """Return a require-able `asar` package directory for integrity hashing."""
    if len(ASAR_CMD) >= 2 and ASAR_CMD[0].endswith("node"):
        asar_js = Path(ASAR_CMD[1])
        if asar_js.name == "asar.js":
            package_dir = asar_js.parent.parent
            if (package_dir / "lib" / "asar.js").exists():
                return package_dir
    npm_dir = Path.home() / ".npm" / "_npx"
    for asar_js in sorted(
        npm_dir.glob("*/node_modules/asar/bin/asar.js"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    ):
        package_dir = asar_js.parent.parent
        if (package_dir / "lib" / "asar.js").exists():
            return package_dir
    return None


def compute_electron_asar_header_hash(asar_path: Path) -> str:
    """Compute Electron's ASAR integrity hash for Info.plist.

    Electron validates the SHA-256 of the ASAR header string, not the full
    archive file hash. Using the same `asar.getRawHeader()` package that packs
    the archive keeps this aligned with Electron's own check.
    """
    node = shutil.which("node")
    asar_module_dir = resolve_asar_module_dir()
    if not node or not asar_module_dir:
        raise RuntimeError("node/asar package unavailable for ASAR integrity hashing")

    script = """
const crypto = require('crypto');
const asar = require(process.argv[1]);
const archive = process.argv[2];
const header = asar.getRawHeader(archive).headerString;
console.log(crypto.createHash('sha256').update(header).digest('hex'));
"""
    result = subprocess.run(
        [node, "-e", script, str(asar_module_dir), str(asar_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ASAR integrity hash failed")
    digest = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise RuntimeError(f"Unexpected ASAR integrity hash: {digest!r}")
    return digest


def update_electron_asar_integrity(asar_path: Path) -> bool:
    """Update Info.plist's ElectronAsarIntegrity hash if needed."""
    digest = compute_electron_asar_header_hash(asar_path)
    with INFO_PLIST_PATH.open("rb") as handle:
        plist = plistlib.load(handle)

    integrity = plist.setdefault("ElectronAsarIntegrity", {})
    entry = integrity.setdefault("Resources/app.asar", {})
    old_digest = entry.get("hash")
    entry["algorithm"] = "SHA256"
    entry["hash"] = digest

    if old_digest == digest:
        print(f"ASAR integrity already current: {digest}")
        return False

    with INFO_PLIST_PATH.open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=False)
    print(f"Updated ASAR integrity: {old_digest} -> {digest}")
    return True


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
        [*ASAR_CMD, "extract", str(asar_path), str(dest)],
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
            *ASAR_CMD, "pack",
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
        [*ASAR_CMD, "list", str(asar_path)],
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
      - invalidate-queries-and-broadcast-HASH.js (v0.118+)
      - app-server-manager-hooks-HASH.js  (v0.118+)
    Falls back to scanning all JS files if neither matches.
    """
    if not assets_dir.exists():
        return None
    content_markers = ("addAuthStatusCallback", "getAccount")
    stronger_markers = (".invalidateQueries", "queryKey:")
    auth_hook_markers = (*content_markers, "authMethod")

    def auth_hook_score(path: Path, content: str) -> int:
        if not all(m in content for m in auth_hook_markers):
            return 0
        score = 1
        if path.name.startswith("use-auth"):
            score += 100
        if find_weakmap_account_cache_var(content):
            score += 80
        if re.search(
            r'\}\),[A-Za-z_$][\w$]*\(\)\};return\s*'
            r'[A-Za-z_$][\w$]*\.addAuthStatusCallback\(',
            content,
        ):
            score += 80
        if all(m in content for m in stronger_markers):
            score += 10
        if "account-info" in content or "accounts`,`check`" in content:
            score += 5
        return score

    def best_auth_hook(candidates: list[Path]) -> Path | None:
        scored: list[tuple[int, str, Path]] = []
        for f in candidates:
            content = f.read_text()
            score = auth_hook_score(f, content)
            if score > 0:
                scored.append((score, f.name, f))
        if not scored:
            return None
        scored.sort(key=lambda item: (-item[0], item[1]))
        return scored[0][2]

    # Primary: Codex's auth hook keeps this name even when the bundle shape
    # moves React Query invalidation into sibling chunks.
    primary = best_auth_hook(
        [
            f
            for pattern in ("use-auth-*.js", "use-auth*.js")
            for f in assets_dir.glob(pattern)
        ]
    )
    if primary:
        return primary

    # Secondary: known filename patterns (fast — avoids reading every JS file)
    secondary = best_auth_hook(
        [
            f
            for pattern in (
                "invalidate-queries-and-broadcast*.js",
                "app-server-manager-hooks-*.js",
            )
            for f in assets_dir.glob(pattern)
        ]
    )
    if secondary:
        return secondary

    # Fallback: search all JS files (survives any future rename)
    return best_auth_hook(list(assets_dir.glob("*.js")))


def find_weakmap_account_cache_var(content: str) -> str | None:
    """Return the WeakMap variable that caches getAccount() promises, if present."""
    match = re.search(
        r'let\s+[A-Za-z_$][\w$]*=([A-Za-z_$][\w$]*)\.get\(([A-Za-z_$][\w$]*)\);'
        r'if\([^;]+?!=null\)return\s+[A-Za-z_$][\w$]*;'
        r'let\s+[A-Za-z_$][\w$]*=\2\.getAccount\(\)\.finally\(\(\)=>\{\1\.delete\(\2\)\}\);'
        r'return\s+\1\.set\(\2,',
        content,
    )
    if not match:
        return None

    weakmap_var = match.group(1)
    if not re.search(rf'{re.escape(weakmap_var)}=new WeakMap(?=[,;}}])', content):
        return None
    return weakmap_var


def find_fast_mode_file(assets_dir: Path) -> Path | None:
    """Find either supported renderer layout that gates Fast Mode."""
    if not assets_dir.exists():
        return None

    candidates: list[Path] = []
    for pattern in ("font-settings-*.js", "font-settings*.js"):
        candidates.extend(sorted(assets_dir.glob(pattern)))
    candidates.extend(sorted(assets_dir.glob("*.js")))

    seen: set[Path] = set()
    patched_candidates: list[Path] = []
    for f in candidates:
        if f in seen:
            continue
        seen.add(f)
        content = f.read_text()
        if FAST_FALLBACK_MARKER in content:
            patched_candidates.append(f)
            continue
        if fast_mode_layout(content) is not None:
            return f
    return patched_candidates[0] if len(patched_candidates) == 1 else None


def fast_mode_layout(content: str) -> str | None:
    legacy_markers = ("additionalSpeedTiers", "modelsByType", "function Qe()")
    if find_service_tier_option_mapper(content) is not None:
        return "service_tiers"
    if all(marker in content for marker in legacy_markers):
        return "legacy"
    return None


def find_service_tier_option_mapper(content: str):
    """Return the unique service-tier option source in a renderer chunk."""
    source_pattern = re.compile(
        r"\((?P<model>[A-Za-z_$][\w$]*)\?\.serviceTiers\?\?\[\]\)(?=\.map\()"
    )
    matches = []
    for match in source_pattern.finditer(content):
        mapper = content[match.end() : match.end() + 500]
        if all(marker in mapper for marker in ("iconKind:", "tier:", "value:")):
            matches.append(match)
    return matches[0] if len(matches) == 1 else None


def find_app_server_launcher_file(extract_dir: Path) -> Path | None:
    """Find the Electron main-process chunk that spawns `codex app-server`.

    The filename changes every Codex desktop release, so this searches by
    durable behavior: the sidecar startup log plus the environment builder.
    """
    for f in extract_dir.rglob("*.js"):
        content = f.read_text()
        if (
            "Starting local app-server sidecar" in content
            and "createEnvironment()" in content
            and "getCodexCliBinDirectoryFromExecutablePath" in content
        ):
            return f
    return None


def find_bundled_plugin_sync_file(extract_dir: Path) -> Path | None:
    """Find the Electron main-process chunk that reconciles bundled plugins."""
    for f in extract_dir.rglob("*.js"):
        content = f.read_text()
        if (
            "bundled_plugins_marketplace_sync_started" in content
            and "addMarketplace" in content
            and "installPlugin({marketplacePath" in content
        ):
                return f
    return None


def find_bundled_plugin_list_files(extract_dir: Path) -> list[Path]:
    """Find JS chunks that issue plugin/list requests for UI/runtime plugin state."""
    matches: list[Path] = []
    for f in sorted(extract_dir.rglob("*.js")):
        content = f.read_text()
        if "plugin/list" not in content:
            continue
        if (
            "async listPlugins(" in content
            or "function Im(e,t){return e.sendRequest(`plugin/list`,t)}" in content
            or '"list-plugins":' in content
        ):
                matches.append(f)
    return matches


def find_remote_recents_file(assets_dir: Path) -> Path | None:
    """Find the renderer hook that feeds the sidebar recent-conversations list."""
    if not assets_dir.exists():
        return None
    for pattern in ("app-server-manager-hooks-*.js", "app-server-manager-hooks*.js"):
        for f in assets_dir.glob(pattern):
            content = f.read_text()
            if (
                "recent-conversations" in content
                and "refresh-recent-conversations-for-host" in content
                and "hasFetchedRecentConversations" in content
                and "addAnyConversationCallback" in content
            ):
                return f
    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if (
            "recent-conversations" in content
            and "refresh-recent-conversations-for-host" in content
            and "hasFetchedRecentConversations" in content
            and "addAnyConversationCallback" in content
        ):
            return f
    return None


def find_model_label_file(assets_dir: Path) -> Path | None:
    """Find the unified desktop model picker that renders missing names as Custom."""
    if not assets_dir.exists():
        return None
    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if (
            "supportedReasoningEfforts" in content
            and "gpt-5.6-sol" in content
            and (
                "==null?`Custom`" in content
                or MODEL_LABEL_FALLBACK_MARKER in content
            )
        ):
            return f
    return None


def find_model_filter_file(assets_dir: Path) -> Path | None:
    """Find the renderer chunk that filters app-server model metadata."""
    if not assets_dir.exists():
        return None
    candidates = []
    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if (
            "availableModels:" in content
            and "useHiddenModels:" in content
            and "hasModelSupportingMaxReasoningEffort" in content
            and (
                "supportedReasoningEfforts" in content
                or GPT56_MAX_EFFORT_FALLBACK_MARKER in content
            )
        ):
            candidates.append(f)
    return candidates[0] if len(candidates) == 1 else None


def find_remote_model_refresh_file(assets_dir: Path) -> Path | None:
    """Find the app-server initialization recovery hook for model cache refresh."""
    if not assets_dir.exists():
        return None
    for f in assets_dir.glob("*.js"):
        content = f.read_text()
        if (
            "app_server_restart_recovery_done" in content
            and "codex-app-server-initialized" in content
            and "list-models-for-host" in content
            and (
                "user-saved-config" in content
                or REMOTE_MODEL_REFRESH_MARKER in content
            )
        ):
            return f
    return None


def has_shadowed_bundled_plugin_sync_fallback(content: str) -> bool:
    return (
        BUNDLED_PLUGIN_SYNC_COMPAT_MARKER in content
        and "catch(t){let r=String(t?.message??t);if(r.includes(`marketplace/add`))" in content
    )


def has_safe_bundled_plugin_sync_patch(content: str) -> bool:
    return (
        BUNDLED_PLUGIN_SYNC_COMPAT_MARKER in content
        and not has_shadowed_bundled_plugin_sync_fallback(content)
        and "bundled_plugin_direct_install_requested" in content
    )


def has_bundled_plugin_list_root_patch(content: str) -> bool:
    return (
        BUNDLED_PLUGIN_LIST_ROOT_MARKER in content
        and BUNDLED_PLUGIN_MARKETPLACE_ROOT in content
    )


def has_remote_recents_refresh_patch(content: str) -> bool:
    return REMOTE_RECENTS_REFRESH_MARKER in content


def find_array_cleanup_function(content: str) -> str | None:
    """Find the minified helper that combines multiple unsubscribe callbacks."""
    match = re.search(
        r'function\s+([A-Za-z_$][\w$]*)\(e\)\{return\(\)=>\{for\(let t of e\)t\(\)\}\}',
        content,
    )
    return match.group(1) if match else None


def get_bundled_fast_model_slugs(
    codex_path: Path = APP_RESOURCES / "codex",
) -> set[str]:
    """Read fast-capable model slugs from the bundled model catalog."""
    result = subprocess.run(
        [str(codex_path), "debug", "models", "--bundled"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        print(f"WARNING: bundled model dump failed: {result.stderr.strip()}")
        return set()
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"WARNING: failed to parse bundled model dump: {exc}")
        return set()
    fast_models = set()
    for model in payload.get("models", []):
        speed_tiers = model.get("additional_speed_tiers") or []
        service_tiers = model.get("service_tiers") or []
        has_fast_service_tier = any(
            isinstance(tier, dict)
            and (
                str(tier.get("id", "")).strip().lower() in {"fast", "priority"}
                or str(tier.get("name", "")).strip().lower() == "fast"
            )
            for tier in service_tiers
        )
        if "fast" in speed_tiers or has_fast_service_tier:
            slug = model.get("slug")
            if slug:
                fast_models.add(slug)
    return fast_models


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


def current_auth_patch_present(content: str) -> bool:
    """Return whether the renderer has the scope-safe auth patch generation."""
    return PATCH_MARKER in content and AUTH_CACHE_PATCH_MARKER in content


def module_patch_insert_position(content: str) -> int:
    """Return a module-scope insertion point after imports and strict directives."""
    last_import_match = None
    for match in re.finditer(r'from"\./[^"]+\.js";', content):
        last_import_match = match
    if last_import_match:
        return last_import_match.end()

    strict_directive = re.match(r'(?:(?:"use strict"|\'use strict\');)+', content)
    return strict_directive.end() if strict_directive else 0


def query_client_auth_module_patch(query_key_builder: str, *, include_ref: bool) -> str:
    """Build a no-throw module-scope React Query cache invalidator."""
    ref_declaration = "var _qcRef=null;" if include_ref else ""
    return (
        ref_declaration
        + f'function {PATCH_MARKER}(){{"{AUTH_CACHE_PATCH_MARKER}";try{{'
        + 'if(_qcRef)void Promise.allSettled(['
        + '_qcRef.invalidateQueries({queryKey:[`accounts`,`check`]}),'
        + f'_qcRef.invalidateQueries({{queryKey:{query_key_builder}(`account-info`)}})'
        + '])}catch{}}}'
    )


def upgrade_query_client_auth_patch(file_path: Path, content: str) -> bool:
    """Upgrade the recognized module-scope V1 query-client helper in place."""
    helper_re = re.compile(
        rf'function {PATCH_MARKER}\(\)\{{if\(_qcRef\)\{{'
        r'_qcRef\.invalidateQueries\(\{queryKey:\[`accounts`,`check`\]\}\);'
        r'_qcRef\.invalidateQueries\(\{queryKey:'
        r'(?P<builder>_csQueryKey|_qkBuild)\(`account-info`\)\}\)\}\}'
    )
    match = helper_re.search(content)
    if not match:
        return False

    patched = (
        content[:match.start()]
        + query_client_auth_module_patch(match.group("builder"), include_ref=False)
        + content[match.end():]
    )
    if not current_auth_patch_present(patched):
        return False
    file_path.write_text(patched)
    print(f"  Upgraded module-scope auth patch: {file_path.name}")
    return True


def apply_modern_use_auth_patch(file_path: Path) -> bool:
    """Patch newer `use-auth` chunks that no longer import React Query directly."""
    content = file_path.read_text()

    vscode_import = re.search(
        r'import\{([^}]+)\}from"(\./vscode-api-[^"]+\.js)";',
        content,
    )
    if not vscode_import:
        return apply_weakmap_use_auth_patch(file_path, content)

    spec = vscode_import.group(1)
    source = vscode_import.group(2)
    new_import = f'import{{A as _csUseQueryClient,r as _csQueryKey,{spec}}}from"{source}";'
    patched = (
        content[:vscode_import.start()]
        + new_import
        + content[vscode_import.end():]
    )

    last_import_match = None
    for match in re.finditer(r'from"\.\/[^"]+\.js";', patched):
        last_import_match = match
    if not last_import_match:
        print("ERROR: Cannot find end of import statements")
        return False

    module_patch = query_client_auth_module_patch("_csQueryKey", include_ref=True)
    patched = (
        patched[:last_import_match.end()]
        + module_patch
        + patched[last_import_match.end():]
    )

    hook_start_re = re.compile(
        r'(function\s+[A-Za-z_$][\w$]*\([^)]*\)\{)'
        r'(let\s+[A-Za-z_$][\w$]*=\(0,[A-Za-z_$][\w$]*\.c\)\(\d+\),)'
    )
    patched, hook_count = hook_start_re.subn(
        r'\1_qcRef=_csUseQueryClient();\2',
        patched,
        count=1,
    )
    if hook_count != 1:
        print("ERROR: Cannot find modern use-auth hook entry")
        return False

    callback_tail_re = re.compile(
        r'\}\),([A-Za-z_$][\w$]*)\(\)\};return\s*'
        r'([A-Za-z_$][\w$]*)\.addAuthStatusCallback\('
    )
    patched, callback_count = callback_tail_re.subn(
        rf'}}),{PATCH_MARKER}(),\1()}};return \2.addAuthStatusCallback(',
        patched,
        count=1,
    )
    if callback_count != 1:
        print("ERROR: Cannot find modern auth status callback refresh tail")
        idx = patched.find("addAuthStatusCallback")
        if idx >= 0:
            context_start = max(0, idx - 200)
            context_end = min(len(patched), idx + 200)
            print(f"  Context: ...{patched[context_start:context_end]}...")
        return False

    if not current_auth_patch_present(patched):
        print("ERROR: Patch marker not found after patching -- something went wrong")
        return False
    if "_csUseQueryClient" not in patched or "_csQueryKey" not in patched:
        print("ERROR: Modern query helpers missing after patch")
        return False
    if "addAuthStatusCallback" not in patched:
        print("ERROR: addAuthStatusCallback disappeared after patching")
        return False
    if "export{" not in patched:
        print("ERROR: export statement disappeared after patching")
        return False

    file_path.write_text(patched)
    print(f"  Patched modern use-auth bundle: {file_path.name}")
    return True


def apply_weakmap_use_auth_patch(file_path: Path, content: str | None = None) -> bool:
    """Patch Codex builds where use-auth refreshes getAccount() directly.

    Current desktop builds no longer expose React Query helpers in use-auth.
    They keep only an in-flight getAccount() promise cache in a WeakMap, so the
    durable auth-refresh repair is to clear that cache before the existing
    addAuthStatusCallback refresh function runs.
    """
    content = content if content is not None else file_path.read_text()
    weakmap_var = find_weakmap_account_cache_var(content)
    if not weakmap_var:
        print("ERROR: Cannot find modern use-auth WeakMap account cache")
        return False

    patched = content
    legacy_helper = (
        f'{weakmap_var}=new WeakMap;'
        f'function {PATCH_MARKER}(){{{weakmap_var}=new WeakMap}}'
    )
    if PATCH_MARKER in patched:
        if patched.count(legacy_helper) != 1:
            print("ERROR: Cannot safely upgrade unrecognized WeakMap auth patch")
            return False
        patched = patched.replace(legacy_helper, f'{weakmap_var}=new WeakMap', 1)

    insert_pos = module_patch_insert_position(patched)
    cache_patch = (
        f'function {PATCH_MARKER}(){{"{AUTH_CACHE_PATCH_MARKER}";'
        f'try{{typeof {weakmap_var}!="undefined"&&({weakmap_var}=new WeakMap)}}catch{{}}}}'
    )
    patched = patched[:insert_pos] + cache_patch + patched[insert_pos:]

    callback_tail_re = re.compile(
        r'\}\),([A-Za-z_$][\w$]*)\(\)\};return\s*'
        r'([A-Za-z_$][\w$]*)\.addAuthStatusCallback\('
    )
    patched_callback_re = re.compile(
        rf'\}}\),{PATCH_MARKER}\(\),([A-Za-z_$][\w$]*)\(\)\}};return\s*'
        r'([A-Za-z_$][\w$]*)\.addAuthStatusCallback\('
    )
    if len(patched_callback_re.findall(patched)) != 1:
        patched, callback_count = callback_tail_re.subn(
            rf'}}),{PATCH_MARKER}(),\1()}};return \2.addAuthStatusCallback(',
            patched,
            count=1,
        )
        if callback_count != 1:
            print("ERROR: Cannot find WeakMap auth status callback refresh tail")
            idx = patched.find("addAuthStatusCallback")
            if idx >= 0:
                context_start = max(0, idx - 200)
                context_end = min(len(patched), idx + 200)
                print(f"  Context: ...{patched[context_start:context_end]}...")
            return False

    if not current_auth_patch_present(patched):
        print("ERROR: Patch marker not found after WeakMap patching")
        return False
    if legacy_helper in patched:
        print("ERROR: Legacy nested WeakMap helper survived migration")
        return False
    if "addAuthStatusCallback" not in patched or "getAccount" not in patched:
        print("ERROR: WeakMap auth structure disappeared after patching")
        return False
    if "export{" not in patched:
        print("ERROR: export statement disappeared after patching")
        return False

    file_path.write_text(patched)
    print(f"  Patched WeakMap use-auth bundle: {file_path.name}")
    return True


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

    if current_auth_patch_present(content):
        print(f"  Already patched: {file_path.name}")
        return True

    if PATCH_MARKER in content:
        weakmap_var = find_weakmap_account_cache_var(content)
        legacy_weakmap_helper = (
            f'{weakmap_var}=new WeakMap;function {PATCH_MARKER}()'
            f'{{{weakmap_var}=new WeakMap}}'
            if weakmap_var
            else None
        )
        if legacy_weakmap_helper and legacy_weakmap_helper in content:
            return apply_weakmap_use_auth_patch(file_path, content)
        if upgrade_query_client_auth_patch(file_path, content):
            return True
        print("ERROR: Existing auth patch has an unknown scope; refusing to layer another patch")
        return False

    if (
        "addAuthStatusCallback" in content
        and "getAccount" in content
        and "authMethod" in content
        and (".invalidateQueries" not in content or find_weakmap_account_cache_var(content))
    ):
        return apply_modern_use_auth_patch(file_path)

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
        # Codex build 1799+ wraps getAccount() in a cached helper like:
        #   l=()=>{S(e).then(...)}   where S(e) internally calls e.getAccount()
        ga_match = re.search(r'(\w)=\(\)=>\{S\(e\)\.then', content)
    if not ga_match:
        # Fallback: any local zero-arg wrapper that immediately calls a helper
        # with the account-manager object and chains .then(...)
        ga_match = re.search(r'(\w)=\(\)=>\{[A-Za-z_$][\w$]*\(e\)\.then', content)
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
        f'var _qcHook={uqc_alias},_qkBuild={qk_alias};'
        + query_client_auth_module_patch("_qkBuild", include_ref=True)
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
    if not current_auth_patch_present(patched):
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


def apply_fast_mode_fallback_patch(
    file_path: Path,
    bundled_fast_models: set[str],
) -> bool:
    """Restore Fast Mode when refreshed model metadata omits fast-tier fields.

    Legacy bundles use `additionalSpeedTiers`. Unified ChatGPT bundles use
    `serviceTiers` plus an account entitlement gate. The service-tier fallback
    repairs only an empty model metadata list and leaves that gate untouched.
    """
    content = file_path.read_text()

    if FAST_FALLBACK_MARKER in content:
        print(f"  Already patched: {file_path.name}")
        return True

    if not bundled_fast_models:
        print("WARNING: No bundled fast-tier models found; skipping fast fallback patch")
        return False

    layout = fast_mode_layout(content)
    if layout is None:
        print("ERROR: Cannot identify supported fast-mode layout")
        return False

    last_import_match = None
    for match in re.finditer(r'from"\.\/[^"]+\.js";', content):
        last_import_match = match
    if not last_import_match:
        print("ERROR: Cannot find end of import statements in fast-mode file")
        return False

    models_literal = ",".join(f"`{slug}`" for slug in sorted(bundled_fast_models))
    insert_pos = last_import_match.end()
    patched = (
        content[:insert_pos]
        + f"var {FAST_FALLBACK_MARKER}=new Set([{models_literal}]);"
        + content[insert_pos:]
    )

    if layout == "legacy":
        patched = apply_legacy_fast_mode_fallback(patched)
    else:
        patched = apply_service_tier_fast_mode_fallback(patched)
    if patched is None:
        return False

    if FAST_FALLBACK_MARKER not in patched:
        print("ERROR: Fast fallback marker missing after patch")
        return False

    file_path.write_text(patched)
    print(f"  Patched fast-mode fallback ({layout}): {file_path.name}")
    return True


def apply_legacy_fast_mode_fallback(content: str) -> str | None:
    old_gate = "function G(e){return e.additionalSpeedTiers?.includes(qe)===!0}"
    new_gate = (
        "function G(e){return e.additionalSpeedTiers?.includes(qe)===!0||"
        f"{FAST_FALLBACK_MARKER}.has(e.model)&&"
        "(!(e.additionalSpeedTiers?.length>0))}"
    )
    if content.count(old_gate) != 1:
        print("ERROR: Cannot identify one legacy fast-tier gate to patch")
        return None
    return content.replace(old_gate, new_gate, 1)


def apply_service_tier_fast_mode_fallback(content: str) -> str | None:
    """Synthesize priority/Fast only when a fast-capable model has no tiers.

    Newer bundles split this mapper from the account entitlement gate. The
    patch changes only model metadata and preserves any gate present verbatim.
    """
    prohibition_pattern = re.compile(
        r"featureRequirements\?\.fast_mode!==!1"
    )
    prohibitions = prohibition_pattern.findall(content)
    match = find_service_tier_option_mapper(content)
    if match is None:
        print("ERROR: Cannot identify one service-tier option mapper to patch")
        return None

    model = match.group("model")
    fallback = (
        f"({model}?.serviceTiers?.length?{model}.serviceTiers:"
        f"{FAST_FALLBACK_MARKER}.has({model}?.model)?"
        "[{id:`priority`,name:`Fast`,description:`1.5x speed, increased usage`}]:[])"
    )
    patched = content[: match.start()] + fallback + content[match.end() :]
    if prohibition_pattern.findall(patched) != prohibitions:
        print("ERROR: Fast-mode entitlement gate changed during metadata patch")
        return None
    return patched


def apply_required_fast_mode_patch(file_path: Path) -> bool:
    return apply_fast_mode_fallback_patch(
        file_path,
        get_bundled_fast_model_slugs(),
    )


def required_renderer_patches_present(
    *,
    auth: bool,
    remote_recents: bool,
    fast: bool,
    model_label: bool,
    model_availability: bool,
    selected_model_label: bool,
    gpt56_max_effort: bool,
    remote_model_refresh: bool,
) -> bool:
    return all(
        (
            auth,
            remote_recents,
            fast,
            model_label,
            model_availability,
            selected_model_label,
            gpt56_max_effort,
            remote_model_refresh,
        )
    )


def has_legacy_headroom_env_bridge(content: str) -> bool:
    return f".OPENAI_BASE_URL=process.env.{HEADROOM_ENV_MARKER}" in content


def has_legacy_headroom_global_env_bridge(content: str) -> bool:
    return re.search(
        rf"\w+\.OPENAI_BASE_URL=\w+\.{HEADROOM_ENV_MARKER}",
        content,
    ) is not None


def has_headroom_env_bridge(content: str) -> bool:
    return HEADROOM_TRANSPORT_PATCH_MARKER in content or has_legacy_headroom_env_bridge(content)


def has_headroom_global_env_bridge(content: str) -> bool:
    return HEADROOM_GLOBAL_ENV_MARKER in content or has_legacy_headroom_global_env_bridge(content)


def remove_headroom_env_patch(file_path: Path) -> bool:
    """Remove Codex.app app-server Headroom transport overrides.

    CodexSwitch used to preserve CODEXSWITCH_HEADROOM_BASE_URL for desktop
    app-server processes. Desktop traffic now intentionally stays direct so
    account hot-swap cannot be coupled to silent token optimizers.
    """
    content = file_path.read_text()
    patched = content

    current_pattern = re.compile(
        rf'createEnvironment\(\)\{{let (\w)=\{{\.\.\.F\(process\.env\)\}};'
        rf'process\.env\.{HEADROOM_ENV_MARKER}&&'
        rf'\("{HEADROOM_TRANSPORT_PATCH_MARKER}",'
        rf'\1\.{HEADROOM_ENV_MARKER}=process\.env\.{HEADROOM_ENV_MARKER},'
        rf'delete \1\.OPENAI_BASE_URL\);'
        r'let (\w)='
    )
    legacy_pattern = re.compile(
        rf'createEnvironment\(\)\{{let (\w)=\{{\.\.\.F\(process\.env\)\}};'
        rf'process\.env\.{HEADROOM_ENV_MARKER}&&'
        rf'\(\1\.OPENAI_BASE_URL=process\.env\.{HEADROOM_ENV_MARKER}\);'
        r'let (\w)='
    )

    patched = current_pattern.sub(
        lambda match: (
            f"createEnvironment(){{let {match.group(1)}={{...F(process.env)}},"
            f"{match.group(2)}="
        ),
        patched,
        count=1,
    )
    patched = legacy_pattern.sub(
        lambda match: (
            f"createEnvironment(){{let {match.group(1)}={{...F(process.env)}},"
            f"{match.group(2)}="
        ),
        patched,
        count=1,
    )

    if patched == content:
        print(f"  No desktop Headroom transport bridge found: {file_path.name}")
        return True
    if HEADROOM_TRANSPORT_PATCH_MARKER in patched:
        print("ERROR: Headroom transport marker remained after removal")
        return False
    if has_legacy_headroom_env_bridge(patched):
        print("ERROR: Legacy Headroom transport bridge remained after removal")
        return False
    if "Starting local app-server sidecar" not in patched:
        print("ERROR: app-server launcher marker disappeared after Headroom removal")
        return False

    file_path.write_text(patched)
    print(f"  Removed desktop Headroom env bridge: {file_path.name}")
    return True


def apply_desktop_cli_path_guard_patch(file_path: Path) -> bool:
    """Prevent launchd/shell CODEX_CLI_PATH from hijacking Codex.app.

    Codex desktop resolves the app-server binary before it builds the child env.
    If launchd exposes CODEX_CLI_PATH=/opt/homebrew/bin/codex, the desktop app
    can bypass its bundled hot-swap binary and spawn the stock Homebrew CLI.
    """
    content = file_path.read_text()

    if DESKTOP_CLI_PATH_GUARD_MARKER in content:
        print(f"  Already patched for desktop CODEX_CLI_PATH guard: {file_path.name}")
        return True

    pattern = re.compile(
        r"function ([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\)"
        r"\{if\(process\.platform===`win32`"
    )
    match = pattern.search(content)
    if not match:
        print("ERROR: Cannot find app-server CLI resolver entrypoint")
        idx = content.find("Unable to locate the Codex CLI binary")
        if idx >= 0:
            print(f"  Context: ...{content[max(0, idx - 240):idx + 240]}...")
        return False

    func_name, arg_name = match.groups()
    replacement = (
        f"function {func_name}({arg_name}){{"
        f"delete process.env.CODEX_CLI_PATH;"
        f"\"{DESKTOP_CLI_PATH_GUARD_MARKER}\";"
        "if(process.platform===`win32`"
    )
    patched = pattern.sub(replacement, content, count=1)

    if DESKTOP_CLI_PATH_GUARD_MARKER not in patched:
        print("ERROR: Desktop CODEX_CLI_PATH guard marker missing after patch")
        return False
    if "Unable to locate the Codex CLI binary" not in patched:
        print("ERROR: app-server resolver marker disappeared after CODEX_CLI_PATH guard patch")
        return False

    file_path.write_text(patched)
    print(f"  Patched desktop CODEX_CLI_PATH guard: {file_path.name}")
    return True


def apply_bundled_plugin_sync_compat_patch(file_path: Path) -> bool:
    """Keep bundled plugin sync working across app-server protocol changes.

    Codex app-server 0.125 removed the `marketplace/add` RPC but still accepts
    `plugin/install` with a local marketplace path and `config/batchWrite`.
    Older desktop bundles abort bundled plugin reconciliation when
    `marketplace/add` is rejected, which leaves Browser Use / Computer Use
    unavailable even though the files and mcp config are present.
    """
    content = file_path.read_text()

    broken_shadow_patch = has_shadowed_bundled_plugin_sync_fallback(content)
    if has_safe_bundled_plugin_sync_patch(content):
        print(f"  Already patched for bundled plugin sync compatibility: {file_path.name}")
        return True

    if BUNDLED_PLUGIN_SYNC_COMPAT_MARKER in content and not broken_shadow_patch:
        patched = content
    elif broken_shadow_patch:
        old = (
            "catch(t){let r=String(t?.message??t);if(r.includes(`marketplace/add`)){"
            "t=e.materializedMarketplace.marketplace.name,"
        )
        new = (
            "catch(n){let r=String(n?.message??n);if(r.includes(`marketplace/add`)){"
            "t=e.materializedMarketplace.marketplace.name,"
        )
    else:
        old = (
            "catch(t){return H.warning(`bundled_plugins_marketplace_add_failed`,"
            "{safe:{marketplaceName:e.materializedMarketplace.marketplace.name},"
            "sensitive:{error:t,marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}"
            "H.info(`bundled_plugins_marketplace_added`"
        )
        new = (
            "catch(n){let r=String(n?.message??n);if(r.includes(`marketplace/add`)){"
            "t=e.materializedMarketplace.marketplace.name,"
            f'"{BUNDLED_PLUGIN_SYNC_COMPAT_MARKER}",'
            "H.warning(`bundled_plugins_marketplace_add_compat_fallback`,"
            "{safe:{marketplaceName:t},"
            "sensitive:{error:r,marketplaceRoot:e.materializedMarketplace.marketplaceRoot}});"
            "try{await e.appServerConnection.sendAppServerRequest(`config/batchWrite`,"
            "{edits:[{keyPath:`marketplaces.${t}.source`,mergeStrategy:`upsert`,"
            "value:e.materializedMarketplace.marketplaceRoot.localPath??e.materializedMarketplace.marketplaceRoot}],"
            "reloadUserConfig:!0})}catch(n){H.warning(`bundled_plugins_marketplace_config_fallback_failed`,"
            "{safe:{marketplaceName:e.materializedMarketplace.marketplace.name},"
            "sensitive:{error:n,marketplaceRoot:e.materializedMarketplace.marketplaceRoot}})}}"
            "else return H.warning(`bundled_plugins_marketplace_add_failed`,"
            "{safe:{marketplaceName:e.materializedMarketplace.marketplace.name},"
            "sensitive:{error:n,marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}"
            "H.info(`bundled_plugins_marketplace_added`"
        )

    if "patched" not in locals():
        if old not in content:
            print("ERROR: Cannot find bundled marketplace add failure path")
            idx = content.find("bundled_plugins_marketplace_add_failed")
            if idx >= 0:
                print(f"  Context: ...{content[max(0, idx - 240):idx + 360]}...")
            return False

        patched = content.replace(old, new, 1)

    if "bundled_plugin_direct_install_requested" not in patched:
        old_install_failure = (
            "catch(n){return H.warning(`bundled_plugins_marketplace_install_failed`,"
            "{safe:{marketplaceName:t},sensitive:{error:n,"
            "marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}return!0}"
        )
        new_install_failure = (
            "catch(n){let r=String(n?.message??n);"
            "if(r.includes(`not been initialized`)){try{"
            "await new Promise(e=>setTimeout(e,250));"
            "let r=`${e.materializedMarketplace.marketplaceRoot.localPath??e.materializedMarketplace.marketplaceRoot}/.agents/plugins/marketplace.json`;"
            "for(let n of e.materializedMarketplace.marketplace.plugins)"
            "H.info(`bundled_plugin_direct_install_requested`,"
            "{safe:{marketplaceName:t,pluginName:n.name},sensitive:{marketplacePath:r}}),"
            "await e.appServerConnection.installPlugin({marketplacePath:r,pluginName:n.name});"
            "return!0}catch(t){n=t}}"
            "return H.warning(`bundled_plugins_marketplace_install_failed`,"
            "{safe:{marketplaceName:t},sensitive:{error:n,"
            "marketplaceRoot:e.materializedMarketplace.marketplaceRoot}}),!1}return!0}"
        )
        if old_install_failure not in patched:
            print("ERROR: Cannot find bundled marketplace install failure path")
            idx = patched.find("bundled_plugins_marketplace_install_failed")
            if idx >= 0:
                print(f"  Context: ...{patched[max(0, idx - 240):idx + 360]}...")
            return False
        patched = patched.replace(old_install_failure, new_install_failure, 1)

    if BUNDLED_PLUGIN_SYNC_COMPAT_MARKER not in patched:
        print("ERROR: Bundled plugin sync compatibility marker missing after patch")
        return False
    if "marketplaceName=undefined" in patched or "catch(t){let r=String(t?.message??t)" in patched:
        print("ERROR: Bundled plugin sync fallback still shadows marketplace name")
        return False
    if "bundled_plugins_marketplace_added" not in patched:
        print("ERROR: bundled plugin install flow disappeared after compatibility patch")
        return False
    if "config/batchWrite" not in patched or "marketplaces.${t}.source" not in patched:
        print("ERROR: bundled plugin marketplace config fallback missing after patch")
        return False
    if "bundled_plugin_direct_install_requested" not in patched:
        print("ERROR: bundled plugin direct install fallback missing after patch")
        return False

    file_path.write_text(patched)
    print(f"  Patched bundled plugin sync compatibility: {file_path.name}")
    return True


def _bundled_plugin_list_params_expression(params_name: str) -> str:
    root = BUNDLED_PLUGIN_MARKETPLACE_ROOT
    return (
        "{..."
        f"{params_name}"
        ",cwds:[...new Set([..."
        f"({params_name}?.cwds??[]),`{root}`])]"
        "}"
    )


def apply_bundled_plugin_list_root_patch(file_path: Path) -> bool:
    """Ensure plugin/list includes the bundled marketplace root.

    app-server 0.125 only lists the curated marketplace plus roots passed in
    `PluginListParams.cwds`. The desktop bundle still expects `marketplace/add`
    to make bundled Browser Use / Computer Use globally visible, so after that
    RPC disappeared the settings UI no longer listed the bundled marketplace.
    """
    content = file_path.read_text()
    if has_bundled_plugin_list_root_patch(content):
        print(f"  Already patched bundled plugin list roots: {file_path.name}")
        return True

    patched = content
    replacements = [
        (
            "async listPlugins(e){await this.ensureReady();",
            (
                f"async listPlugins(e){{\"{BUNDLED_PLUGIN_LIST_ROOT_MARKER}\";"
                f"e={_bundled_plugin_list_params_expression('e')};"
                "await this.ensureReady();"
            ),
        ),
        (
            "function Im(e,t){return e.sendRequest(`plugin/list`,t)}",
            (
                f"function Im(e,t){{\"{BUNDLED_PLUGIN_LIST_ROOT_MARKER}\";"
                "return e.sendRequest(`plugin/list`,"
                f"{_bundled_plugin_list_params_expression('t')})}}"
            ),
        ),
        (
            '"list-plugins":i9((e,{hostId:t,...n})=>e.sendRequest(`plugin/list`,n))',
            (
                '"list-plugins":i9((e,{hostId:t,...n})=>('
                f'"{BUNDLED_PLUGIN_LIST_ROOT_MARKER}",'
                "e.sendRequest(`plugin/list`,"
                f"{_bundled_plugin_list_params_expression('n')})))"
            ),
        ),
    ]

    changed = False
    for old, new in replacements:
        if old in patched:
            patched = patched.replace(old, new, 1)
            changed = True

    if not changed:
        print("ERROR: Cannot find plugin/list request path to patch")
        idx = content.find("plugin/list")
        if idx >= 0:
            print(f"  Context: ...{content[max(0, idx - 240):idx + 360]}...")
        return False
    if not has_bundled_plugin_list_root_patch(patched):
        print("ERROR: Bundled plugin list root marker missing after patch")
        return False
    if "plugin/list" not in patched:
        print("ERROR: plugin/list disappeared after bundled root patch")
        return False

    file_path.write_text(patched)
    print(f"  Patched bundled plugin list roots: {file_path.name}")
    return True


def upgrade_remote_recents_refresh_v1(file_path: Path, content: str) -> bool:
    """Migrate the recognized 15-second remote-recents fallback to V2."""
    legacy_literal = f'"{LEGACY_REMOTE_RECENTS_REFRESH_MARKER}";'
    current_literal = f'"{REMOTE_RECENTS_REFRESH_MARKER}";'
    if legacy_literal not in content or current_literal in content:
        return False

    interval_re = re.compile(
        r'window\.setInterval\((?P<refresh>[A-Za-z_$][\w$]*),15000\)'
    )
    matches = list(interval_re.finditer(content))
    if len(matches) != 1:
        print("ERROR: Cannot identify the legacy remote-recents fallback timer")
        return False

    refresh = matches[0].group("refresh")
    patched = content.replace(legacy_literal, current_literal, 1)
    patched = interval_re.sub(
        lambda match: (
            f'window.setInterval({match.group("refresh")},'
            f'{REMOTE_RECENTS_REFRESH_INTERVAL_MS})'
        ),
        patched,
        count=1,
    )
    if refresh == "_csRemoteRecentRefresh":
        injected_mount_refresh = f',{refresh}());'
        if patched.count(injected_mount_refresh) != 1:
            print("ERROR: Cannot remove the legacy remote-recents mount refresh")
            return False
        patched = patched.replace(injected_mount_refresh, ");", 1)

    if not has_remote_recents_refresh_patch(patched):
        return False
    if legacy_literal in patched or interval_re.search(patched):
        print("ERROR: Legacy remote-recents fallback survived migration")
        return False

    file_path.write_text(patched)
    print(f"  Upgraded remote recent conversation refresh: {file_path.name}")
    return True


def apply_remote_recents_refresh_patch(file_path: Path) -> bool:
    """Refresh remote sidebar recents even when the desktop misses a notification.

    Codex.app's sidebar query uses an infinite stale time and normally depends
    on AppServerManager conversation callbacks. Agent-created VPS threads can
    be created by another app-server client while the Mac sidebar is already
    mounted; this timer is a lightweight safety net that re-runs the same
    existing `refreshRecentConversations()` path for enabled remote hosts.
    """
    content = file_path.read_text()
    if has_remote_recents_refresh_patch(content):
        print(f"  Already patched remote recent conversation refresh: {file_path.name}")
        return True
    if f'"{LEGACY_REMOTE_RECENTS_REFRESH_MARKER}";' in content:
        return upgrade_remote_recents_refresh_v1(file_path, content)

    old = (
        "let t=()=>{let t=z(u);"
        "m.setQueryData([e,p,u],I({appServerRegistry:s,enabledRemoteHostIds:t,sortKey:p})),"
        "R({scope:n,appServerRegistry:s,sortKey:p,refreshesInFlightHostIds:g.current})};"
        "return t(),P({appServerRegistry:s,onStoreChange:t,subscribeToManager:(t,n)=>{"
        "switch(e){case`recent-conversations`:return t.addAnyConversationCallback(n);"
        "case`recent-conversations-meta`:return t.addAnyConversationMetaCallback(n)}}})"
    )
    new = (
        "let t=()=>{let t=z(u);"
        "m.setQueryData([e,p,u],I({appServerRegistry:s,enabledRemoteHostIds:t,sortKey:p})),"
        "R({scope:n,appServerRegistry:s,sortKey:p,refreshesInFlightHostIds:g.current})};"
        f'"{REMOTE_RECENTS_REFRESH_MARKER}";'
        f"let _csRemoteRecentRefreshTimer=u!==`[]`?window.setInterval(t,{REMOTE_RECENTS_REFRESH_INTERVAL_MS}):null;"
        "return t(),N([P({appServerRegistry:s,onStoreChange:t,subscribeToManager:(t,n)=>{"
        "switch(e){case`recent-conversations`:return t.addAnyConversationCallback(n);"
        "case`recent-conversations-meta`:return t.addAnyConversationMetaCallback(n)}}}),"
        "()=>{_csRemoteRecentRefreshTimer!=null&&window.clearInterval(_csRemoteRecentRefreshTimer)}])"
    )

    if old not in content:
        signal_effect_re = re.compile(
            r'let\{key:(?P<key>[A-Za-z_$][\w$]*)\}=t,'
            r'(?P<ids>[A-Za-z_$][\w$]*)=\[\],'
            r'(?P<watch>[A-Za-z_$][\w$]*)=t\.watch\(\(\{get:(?P<get>[A-Za-z_$][\w$]*)\}\)=>\{'
            r'let (?P<manager>[A-Za-z_$][\w$]*)=(?P=get)\((?P<manager_atom>[A-Za-z_$][\w$]*),(?P=key)\),'
            r'(?P<update>[A-Za-z_$][\w$]*)=(?P<update_arg>[A-Za-z_$][\w$]*)=>\{'
            r'e\((?P=update_arg)\),(?P<cleanup>[A-Za-z_$][\w$]*)\(t,(?P=key),(?P=ids),(?P=update_arg)\),'
            r'(?P=ids)=(?P=update_arg)\};'
            r'if\((?P=update)\((?P=manager)\?\.getRecentConversations\(\)\.map\(\(\{id:e\}\)=>e\)\?\?\[\]\),'
            r'(?P=manager)!=null\)'
            r'return (?P=manager)\.addAnyConversationMetaCallback\(e=>\{'
            r'(?P=update)\(e\.map\(\(\{id:e\}\)=>e\)\)\}\)\}\);'
            r'return\(\)=>\{(?P=watch)\(\),(?P=cleanup)\(t,(?P=key),(?P=ids),\[\]\)\}'
        )

        def replace_signal_effect(match: re.Match[str]) -> str:
            key = match.group("key")
            ids = match.group("ids")
            watch = match.group("watch")
            get_alias = match.group("get")
            manager = match.group("manager")
            manager_atom = match.group("manager_atom")
            update = match.group("update")
            update_arg = match.group("update_arg")
            cleanup = match.group("cleanup")
            watch_call = (
                f'{watch}=t.watch(({{get:{get_alias}}})=>{{'
                f'let {manager}={get_alias}({manager_atom},{key}),'
                f'{update}={update_arg}=>{{e({update_arg}),'
                f'{cleanup}(t,{key},{ids},{update_arg}),{ids}={update_arg}}};'
                f'if({update}({manager}?.getRecentConversations().map(({{id:e}})=>e)??[]),'
                f'{manager}!=null)return {manager}.addAnyConversationMetaCallback(e=>{{'
                f'{update}(e.map(({{id:e}})=>e))}})}})'
            )
            return (
                f'let{{key:{key}}}=t,{ids}=[],_csRemoteRecentRefreshTimer=null,'
                f'_csRemoteRecentRefresh=()=>{{let e=t.get({manager_atom},{key});'
                'e?.refreshRecentConversations&&'
                'Promise.resolve(e.refreshRecentConversations({})).catch(()=>{})},'
                f'{watch_call};"{REMOTE_RECENTS_REFRESH_MARKER}";'
                f'{key}!==`local`&&(_csRemoteRecentRefreshTimer='
                f'window.setInterval(_csRemoteRecentRefresh,{REMOTE_RECENTS_REFRESH_INTERVAL_MS}));'
                f'return()=>{{{watch}(),_csRemoteRecentRefreshTimer!=null&&'
                'window.clearInterval(_csRemoteRecentRefreshTimer),'
                f'{cleanup}(t,{key},{ids},[])}}'
            )

        patched, replace_count = signal_effect_re.subn(
            replace_signal_effect,
            content,
            count=1,
        )
        if replace_count != 1:
            cleanup_fn = find_array_cleanup_function(content)
            if not cleanup_fn:
                print("ERROR: Cannot find recent-conversations cleanup helper")
                idx = content.find("recent-conversations")
                if idx >= 0:
                    print(f"  Context: ...{content[max(0, idx - 400):idx + 900]}...")
                return False

            effect_re = re.compile(
                r'(?P<prefix>'
                r'(?:let\s+)?[A-Za-z_$][\w$]*=\(\)=>\{let\s+(?P<refresh>[A-Za-z_$][\w$]*)=\(\)=>\{'
                r'let\s+(?P=refresh)=(?P<to_set>[A-Za-z_$][\w$]*)\((?P<enabled>[A-Za-z_$][\w$]*)\);'
                r'(?P<query>[A-Za-z_$][\w$]*)\.setQueryData\(\[e,(?P<sort>[A-Za-z_$][\w$]*),(?P=enabled)\],'
                r'(?P<mapper>[A-Za-z_$][\w$]*)\(\{appServerRegistry:(?P<registry>[A-Za-z_$][\w$]*),'
                r'enabledRemoteHostIds:(?P=refresh),sortKey:(?P=sort)\}\)\),'
                r'(?P<refresh_remote>[A-Za-z_$][\w$]*)\(\{scope:(?P<scope>[A-Za-z_$][\w$]*),'
                r'appServerRegistry:(?P=registry),sortKey:(?P=sort),'
                r'refreshesInFlightHostIds:(?P<inflight>[A-Za-z_$][\w$]*)\.current\}\)\};'
                r')return\s+(?P=refresh)\(\),(?P<subscribe>'
                r'[A-Za-z_$][\w$]*\(\{appServerRegistry:(?P=registry),onStoreChange:(?P=refresh),'
                r'subscribeToManager:\(t,n\)=>\{switch\(e\)\{case`recent-conversations`:'
                r'return t\.addAnyConversationCallback\(n\);case`recent-conversations-meta`:'
                r'return t\.addAnyConversationMetaCallback\(n\)\}\}\}\))'
            )

            def replace_effect(match: re.Match[str]) -> str:
                refresh_fn = match.group("refresh")
                enabled_var = match.group("enabled")
                subscribe_call = match.group("subscribe")
                return (
                    match.group("prefix")
                    + f'"{REMOTE_RECENTS_REFRESH_MARKER}";'
                    + f'let _csRemoteRecentRefreshTimer={enabled_var}!==`[]`?'
                    + f'window.setInterval({refresh_fn},{REMOTE_RECENTS_REFRESH_INTERVAL_MS}):null;'
                    + f'return {refresh_fn}(),{cleanup_fn}([{subscribe_call},'
                    + '()=>{_csRemoteRecentRefreshTimer!=null&&'
                    + 'window.clearInterval(_csRemoteRecentRefreshTimer)}])'
                )

            patched, replace_count = effect_re.subn(replace_effect, content, count=1)
            if replace_count != 1:
                print("ERROR: Cannot find recent-conversations effect to patch")
                idx = content.find("recent-conversations")
                if idx >= 0:
                    print(f"  Context: ...{content[max(0, idx - 400):idx + 900]}...")
                return False
    else:
        patched = content.replace(old, new, 1)
    if not has_remote_recents_refresh_patch(patched):
        print("ERROR: Remote recent conversation refresh marker missing after patch")
        return False
    if not re.search(
        rf'window\.setInterval\([A-Za-z_$][\w$]*,{REMOTE_RECENTS_REFRESH_INTERVAL_MS}\)',
        patched,
    ):
        print("ERROR: Remote recent conversation refresh timer missing after patch")
        return False
    if "window.clearInterval(_csRemoteRecentRefreshTimer)" not in patched:
        print("ERROR: Remote recent conversation refresh cleanup missing after patch")
        return False
    if "recent-conversations" not in patched or "refresh-recent-conversations-for-host" not in patched:
        print("ERROR: recent conversation refresh path disappeared after patch")
        return False

    file_path.write_text(patched)
    print(f"  Patched remote recent conversation refresh: {file_path.name}")
    return True


def apply_model_label_fallback_patch(file_path: Path) -> bool:
    """Derive a readable known-model label while displayName is unavailable."""
    content = file_path.read_text()
    if MODEL_LABEL_FALLBACK_MARKER in content:
        return True

    pattern = re.compile(
        r"let (?P<label>[A-Za-z_$][\w$]*)=(?P<display>[A-Za-z_$][\w$]*)"
        r"==null\?`Custom`:(?P<formatter>[A-Za-z_$][\w$]*)"
        r"\((?P=display)\)\.replace\(/\^GPT-/iu,``\)"
    )
    match = pattern.search(content)
    if not match:
        print(f"ERROR: Could not find model label fallback shape in {file_path.name}")
        return False

    prefix = content[max(0, match.start() - 240) : match.start()]
    model_matches = list(re.finditer(r"model:([A-Za-z_$][\w$]*)", prefix))
    if not model_matches:
        print(f"ERROR: Could not identify model slug variable in {file_path.name}")
        return False

    model_var = model_matches[-1].group(1)
    label_var = match.group("label")
    display_var = match.group("display")
    formatter = match.group("formatter")
    replacement = (
        f"let {label_var}=/*{MODEL_LABEL_FALLBACK_MARKER}*/"
        f"{display_var}==null?{formatter}({model_var}).replace(/^GPT-/iu,``)"
        f".replaceAll(`-`,` `):{formatter}({display_var}).replace(/^GPT-/iu,``)"
    )
    patched, count = pattern.subn(replacement, content, count=1)
    if count != 1 or MODEL_LABEL_FALLBACK_MARKER not in patched:
        print(f"ERROR: Failed to apply model label fallback in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched model label fallback: {file_path.name}")
    return True


def apply_selected_model_label_fallback_patch(file_path: Path) -> bool:
    """Label a selected GPT-5.6 slug while its catalog metadata is unavailable."""
    content = file_path.read_text()
    if SELECTED_MODEL_LABEL_FALLBACK_MARKER in content:
        return True

    pattern = re.compile(
        r"(?P<label>[A-Za-z_$][\w$]*)=(?P<value>[A-Za-z_$][\w$]*)}"
        r"else if\((?P<model>[A-Za-z_$][\w$]*)\)\{let "
        r"(?P<custom>[A-Za-z_$][\w$]*);"
        r"(?P<cache>[A-Za-z_$][\w$]*)\[3\]==="
        r"Symbol\.for\(`react\.memo_cache_sentinel`\)"
    )
    matches = [
        match
        for match in pattern.finditer(content)
        if "composer.mode.local.model.custom"
        in content[match.start() : match.end() + 500]
    ]
    if len(matches) != 1:
        print(
            f"ERROR: Expected one selected model label branch in {file_path.name}, "
            f"found {len(matches)}"
        )
        return False

    match = matches[0]
    prefix = content[max(0, match.start() - 800) : match.start()]
    formatter_matches = list(
        re.finditer(
            r"let [A-Za-z_$][\w$]*=(?P<formatter>[A-Za-z_$][\w$]*)"
            r"\((?P<display>[A-Za-z_$][\w$]*)\);",
            prefix,
        )
    )
    if not formatter_matches:
        print(f"ERROR: Could not identify selected model label formatter in {file_path.name}")
        return False

    formatter = formatter_matches[-1].group("formatter")
    label = match.group("label")
    value = match.group("value")
    model = match.group("model")
    custom = match.group("custom")
    old = f"{label}={value}}}else if({model}){{let {custom};"
    new = (
        f"{label}={value}}}else if({model}.startsWith(`gpt-5.6-`))"
        f"{label}=/*{SELECTED_MODEL_LABEL_FALLBACK_MARKER}*/"
        f"{formatter}({model}).replace(/^GPT-/iu,``).replaceAll(`-`,` `);"
        f"else if({model}){{let {custom};"
    )
    if content.count(old) != 1:
        print(f"ERROR: Selected model label replacement became ambiguous in {file_path.name}")
        return False

    patched = content.replace(old, new, 1)
    if SELECTED_MODEL_LABEL_FALLBACK_MARKER not in patched:
        print(f"ERROR: Failed to apply selected model label fallback in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched selected model label fallback: {file_path.name}")
    return True


def apply_model_availability_fallback_patch(file_path: Path) -> bool:
    """Keep app-server-advertised GPT-5.6 models visible through stale allowlists."""
    content = file_path.read_text()
    if MODEL_AVAILABILITY_FALLBACK_MARKER in content:
        return True

    pattern = re.compile(
        r"if\((?P<gate>[A-Za-z_$][\w$]*)\?"
        r"(?P<allowlist>[A-Za-z_$][\w$]*)\.has\("
        r"(?P<entry>[A-Za-z_$][\w$]*)\.model\):!"
        r"(?P=entry)\.hidden\)\{"
    )
    match = pattern.search(content)
    if not match:
        print(f"ERROR: Could not find model availability filter in {file_path.name}")
        return False

    context = content[max(0, match.start() - 500) : match.start()]
    if "availableModels:" not in context or "useHiddenModels:" not in context:
        print(f"ERROR: Refusing ambiguous model availability patch in {file_path.name}")
        return False

    gate = match.group("gate")
    allowlist = match.group("allowlist")
    entry = match.group("entry")
    replacement = (
        f"if({gate}?/*{MODEL_AVAILABILITY_FALLBACK_MARKER}*/"
        f"({allowlist}.has({entry}.model)||"
        f"{entry}.model.startsWith(`gpt-5.6-`)):!{entry}.hidden){{"
    )
    patched, count = pattern.subn(replacement, content, count=1)
    if count != 1 or MODEL_AVAILABILITY_FALLBACK_MARKER not in patched:
        print(f"ERROR: Failed to apply model availability fallback in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched model availability fallback: {file_path.name}")
    return True


def has_gpt56_max_effort_filter_patch(content: str) -> bool:
    return GPT56_MAX_EFFORT_FALLBACK_MARKER in content


def has_gpt56_max_effort_preset_patch(content: str) -> bool:
    max_preset = "id:`gpt-5.6-sol:max`"
    xhigh_preset = "id:`gpt-5.6-sol:xhigh`"
    ultra_preset = "id:`gpt-5.6-sol:ultra`"
    required = (xhigh_preset, max_preset, ultra_preset)
    if not all(value in content for value in required):
        return False
    return content.index(xhigh_preset) < content.index(max_preset) < content.index(ultra_preset)


def has_gpt56_max_effort_patch(content: str) -> bool:
    return (
        has_gpt56_max_effort_filter_patch(content)
        and has_gpt56_max_effort_preset_patch(content)
    )


def apply_gpt56_max_effort_filter_patch(file_path: Path) -> bool:
    """Preserve server-advertised GPT-5.6 max in the model filter."""
    content = file_path.read_text()
    if has_gpt56_max_effort_filter_patch(content):
        return True

    effort_filter = re.compile(
        r"(?P<validator>[A-Za-z_$][\w$]*)\((?P<effort>[A-Za-z_$][\w$]*)\)"
        r"&&(?P<enabled>[A-Za-z_$][\w$]*)\.has\((?P=effort)\)"
    )
    matches = []
    for match in effort_filter.finditer(content):
        context = content[max(0, match.start() - 1200) : match.end() + 1200]
        if (
            "supportedReasoningEfforts" in context
            and "hasModelSupportingMaxReasoningEffort" in context
        ):
            matches.append(match)
    if len(matches) != 1:
        print(
            f"ERROR: Expected one GPT-5.6 max effort filter in {file_path.name}, "
            f"found {len(matches)}"
        )
        return False

    match = matches[0]
    prefix = content[max(0, match.start() - 1200) : match.start()]
    model_matches = list(
        re.finditer(r"\.forEach\((?P<model>[A-Za-z_$][\w$]*)=>\{", prefix)
    )
    if not model_matches:
        print(f"ERROR: Could not identify max-effort model variable in {file_path.name}")
        return False

    model = model_matches[-1].group("model")
    validator = match.group("validator")
    effort = match.group("effort")
    enabled = match.group("enabled")
    replacement = (
        f"/*{GPT56_MAX_EFFORT_FALLBACK_MARKER}*/{validator}({effort})&&"
        f"({enabled}.has({effort})||"
        f"({model}.model.startsWith(`gpt-5.6-`)&&{effort}===`max`))"
    )
    patched = content[: match.start()] + replacement + content[match.end() :]
    if not has_gpt56_max_effort_filter_patch(patched):
        print(f"ERROR: Failed to apply GPT-5.6 max effort filter in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched GPT-5.6 max effort filter: {file_path.name}")
    return True


def apply_gpt56_max_effort_preset_patch(file_path: Path) -> bool:
    """Place the Sol max power preset between xhigh and ultra."""
    content = file_path.read_text()
    if has_gpt56_max_effort_preset_patch(content):
        return True

    max_preset = (
        "{id:`gpt-5.6-sol:max`,model:`gpt-5.6-sol`,"
        "modelLabel:`5.6 Sol`,reasoningEffort:`max`}"
    )
    xhigh_preset = (
        "{id:`gpt-5.6-sol:xhigh`,model:`gpt-5.6-sol`,"
        "modelLabel:`5.6 Sol`,reasoningEffort:`xhigh`}"
    )
    ultra_preset = (
        "{id:`gpt-5.6-sol:ultra`,model:`gpt-5.6-sol`,"
        "modelLabel:`5.6 Sol`,reasoningEffort:`ultra`}"
    )
    adjacent_presets = f"{xhigh_preset},{ultra_preset}"
    split_ultra_pattern = re.compile(
        re.escape(xhigh_preset)
        + r"\],(?P<ultra_alias>[A-Za-z_$][\w$]*)="
        + re.escape(ultra_preset)
    )
    inline_count = content.count(adjacent_presets)
    split_matches = list(split_ultra_pattern.finditer(content))
    if inline_count + len(split_matches) != 1:
        print(
            f"ERROR: Could not identify one Sol xhigh/ultra preset ordering "
            f"in {file_path.name}"
        )
        return False
    if inline_count == 1:
        patched = content.replace(
            adjacent_presets,
            f"{xhigh_preset},{max_preset},{ultra_preset}",
            1,
        )
    else:
        patched = split_ultra_pattern.sub(
            lambda match: (
                f"{xhigh_preset},{max_preset}],"
                f"{match.group('ultra_alias')}={ultra_preset}"
            ),
            content,
            count=1,
        )

    if not has_gpt56_max_effort_preset_patch(patched):
        print(f"ERROR: Failed to apply GPT-5.6 max effort preset in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched GPT-5.6 max effort preset: {file_path.name}")
    return True


def apply_gpt56_max_effort_patch(file_path: Path) -> bool:
    """Patch a legacy combined model filter and power-preset chunk."""
    return (
        apply_gpt56_max_effort_filter_patch(file_path)
        and apply_gpt56_max_effort_preset_patch(file_path)
    )


def apply_remote_model_refresh_patch(file_path: Path) -> bool:
    """Invalidate the host model catalog whenever an app-server reinitializes."""
    content = file_path.read_text()
    if REMOTE_MODEL_REFRESH_MARKER in content:
        return True

    pattern = re.compile(
        r"(?P<client>[A-Za-z_$][\w$]*)\.invalidateQueries\("
        r"\{queryKey:\[`user-saved-config`\]\}\)"
    )
    matches = []
    for match in pattern.finditer(content):
        context = content[max(0, match.start() - 1200) : match.end() + 2500]
        if "app_server_restart_recovery_done" in context:
            matches.append(match)
    if len(matches) != 1:
        print(
            f"ERROR: Expected one app-server model refresh branch in {file_path.name}, "
            f"found {len(matches)}"
        )
        return False

    match = matches[0]
    prefix = content[max(0, match.start() - 1200) : match.start()]
    host_matches = list(
        re.finditer(
            r"async function [A-Za-z_$][\w$]*\("
            r"(?P<host>[A-Za-z_$][\w$]*)\)",
            prefix,
        )
    )
    if not host_matches:
        print(f"ERROR: Could not identify app-server host variable in {file_path.name}")
        return False

    client = match.group("client")
    host = host_matches[-1].group("host")
    old = match.group(0)
    new = (
        f"{old},/*{REMOTE_MODEL_REFRESH_MARKER}*/"
        f"{client}.invalidateQueries({{queryKey:[`models`,`list`,{host}]}})"
    )
    patched = content[: match.start()] + new + content[match.end() :]
    if (
        REMOTE_MODEL_REFRESH_MARKER not in patched
        or f"{client}.invalidateQueries({{queryKey:[`models`,`list`,{host}]}})"
        not in patched
    ):
        print(f"ERROR: Failed to apply remote model refresh patch in {file_path.name}")
        return False

    file_path.write_text(patched)
    print(f"  Patched remote model refresh: {file_path.name}")
    return True


def remove_headroom_global_env_patch(file_path: Path) -> bool:
    """Remove CodexSwitch Headroom propagation from the shared env sanitizer."""
    content = file_path.read_text()
    patched = content

    current_pattern = re.compile(
        rf"function ([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\)"
        rf"\{{let ([A-Za-z_$][\w$]*)=\{{\.\.\.\2\}};"
        rf"\2&&\2\.{HEADROOM_ENV_MARKER}&&"
        rf'\("{HEADROOM_GLOBAL_ENV_MARKER}",'
        rf"\3\.{HEADROOM_ENV_MARKER}=\2\.{HEADROOM_ENV_MARKER},"
        rf"delete \3\.OPENAI_BASE_URL\);"
        rf"delete \3\.CODEX_CLI_PATH;"
        rf"for\(let ([A-Za-z_$][\w$]*) of Object\.keys\(\3\)\)"
        rf"([A-Za-z_$][\w$]*)\.has\(\4\.toUpperCase\(\)\)&&delete \3\[\4\];"
        rf"return \3\}}"
    )
    legacy_pattern = re.compile(
        rf"function ([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\)"
        rf"\{{let ([A-Za-z_$][\w$]*)=\{{\.\.\.\2\}};"
        rf"\2&&\2\.{HEADROOM_ENV_MARKER}&&"
        rf'\("{HEADROOM_GLOBAL_ENV_MARKER}",'
        rf"\3\.OPENAI_BASE_URL=\2\.{HEADROOM_ENV_MARKER}\);"
        rf"delete \3\.CODEX_CLI_PATH;"
        rf"for\(let ([A-Za-z_$][\w$]*) of Object\.keys\(\3\)\)"
        rf"([A-Za-z_$][\w$]*)\.has\(\4\.toUpperCase\(\)\)&&delete \3\[\4\];"
        rf"return \3\}}"
    )

    def replacement(match: re.Match[str]) -> str:
        func_name, env_var, output_var, loop_var, blocked_var = match.groups()
        return (
            f"function {func_name}({env_var}){{let {output_var}={{...{env_var}}};"
            f"delete {output_var}.CODEX_CLI_PATH;"
            f"for(let {loop_var} of Object.keys({output_var}))"
            f"{blocked_var}.has({loop_var}.toUpperCase())&&delete {output_var}[{loop_var}];"
            f"return {output_var}}}"
        )

    patched = current_pattern.sub(replacement, patched, count=1)
    patched = legacy_pattern.sub(replacement, patched, count=1)

    if patched == content:
        print(f"  No global Headroom env bridge found: {file_path.name}")
        return True
    if HEADROOM_GLOBAL_ENV_MARKER in patched:
        print("ERROR: Global Headroom marker remained after removal")
        return False
    if has_legacy_headroom_global_env_bridge(patched):
        print("ERROR: Legacy global Headroom bridge remained after removal")
        return False
    if "Starting local app-server sidecar" not in patched:
        print("ERROR: app-server launcher marker disappeared after global Headroom removal")
        return False

    file_path.write_text(patched)
    print(f"  Removed global Headroom env bridge: {file_path.name}")
    return True


# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------
def codesign_app():
    """Re-sign Codex.app after modification.

    We intentionally do NOT use `codesign --deep` here. Sparkle explicitly
    warns against it, and on current macOS builds it can leave Electron
    Framework signed with OpenAI's original Team ID while nested frameworks
    like Squirrel become ad-hoc signed. Dyld then refuses to load them due to
    mixed Team IDs inside the same process.

    Instead, sign nested code objects first, then container bundles, then the
    app itself.
    """
    identity = select_or_repair_codesign_identity()
    if identity == "-":
        print(
            "ERROR: No usable non-ad-hoc code signing identity is available. "
            "Refusing to ad-hoc sign Codex.app."
        )
        return False
    print("Code signing identity: " + identity)
    app_path = APP_PATH
    targets = list_codesign_targets(app_path)
    for target in targets[:-1]:
        if not codesign_target(target, identity):
            return False

    if not ensure_computer_use_plugin_signature_compatible(app_path, identity):
        return False

    entitlements_path = write_local_desktop_app_entitlements()
    if not codesign_target(targets[-1], identity, entitlements=entitlements_path):
        return False

    verify = subprocess.run(
        [
            "codesign",
            "--verify",
            "--strict",
            "--verbose=4",
            str(app_path),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if verify.returncode != 0:
        print(f"WARNING: codesign verification failed: {verify.stderr.strip()}")
        return False
    if not executable_and_framework_team_ids_match(app_path):
        return False
    if not spctl_accepts(app_path):
        if identity_allows_local_execute_assessment_fallback(identity):
            print(
                "WARNING: Gatekeeper rejected the iPhone Developer-signed Codex.app, "
                "but codesign verification and Team ID checks passed. Continuing with "
                "the local Apple-issued signing fallback that this Mac uses for patched "
                "Codex.app launches."
            )
        else:
            print(
                "ERROR: Gatekeeper rejected the re-signed Codex.app. "
                "Refusing to leave a locally patched bundle that cannot pass "
                "macOS execute assessment."
            )
            return False
    return True


def write_local_desktop_app_entitlements() -> Path:
    workdir = make_workdir()
    path = workdir / "codex-local-desktop.entitlements.plist"
    with path.open("wb") as handle:
        plistlib.dump(LOCAL_DESKTOP_APP_ENTITLEMENTS, handle, sort_keys=True)
    return path


def codesign_target(
    target: Path,
    identity: str,
    entitlements: Path | None = None,
) -> bool:
    command = [
        "codesign",
        "--force",
        "--sign",
        identity,
    ]
    if entitlements is not None:
        command.extend(
            [
                "--options",
                "runtime",
                "--entitlements",
                str(entitlements),
                "--preserve-metadata=identifier,flags",
            ]
        )
    else:
        command.append("--preserve-metadata=identifier,entitlements,flags")
    command.append(str(target))

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        print(f"WARNING: codesign failed for {target}: {result.stderr.strip()}")
        return False
    return True


def app_signature_repair_needed(app_path: Path) -> bool:
    result = subprocess.run(
        ["codesign", "--verify", "--strict", str(app_path)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    return result.returncode != 0


def codesign_team_identifier(path: Path) -> str | None:
    result = subprocess.run(
        ["codesign", "-dv", str(path)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    output = result.stdout + "\n" + result.stderr
    match = re.search(r"^TeamIdentifier=(.+)$", output, flags=re.MULTILINE)
    if not match:
        return None
    team = match.group(1).strip()
    if team.lower() in {"", "not set", "none"}:
        return None
    return team


def codesign_entitlements_text(path: Path) -> str:
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(path)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        return ""
    return result.stdout + "\n" + result.stderr


def computer_use_plugin_signing_targets(app_path: Path) -> list[Path]:
    app_path = app_path.resolve()
    sky_client_app = app_path / SKY_COMPUTER_USE_CLIENT_APP_RELATIVE
    computer_use_app = app_path / COMPUTER_USE_PLUGIN_APP_RELATIVE
    return [path for path in (sky_client_app, computer_use_app) if path.exists()]


def spctl_assessment(path: Path) -> str:
    result = subprocess.run(
        ["spctl", "--assess", "--type", "execute", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode == 0:
        return "accepted"
    output = f"{result.stdout}\n{result.stderr}".lower()
    if "internal error in code signing subsystem" in output:
        return "unavailable"
    return "rejected"


def spctl_accepts(path: Path) -> bool:
    return spctl_assessment(path) == "accepted"


def codesign_strictly_valid(path: Path) -> bool:
    result = subprocess.run(
        ["codesign", "--verify", "--strict", str(path)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    return result.returncode == 0


def app_framework_executable(app_path: Path) -> Path | None:
    frameworks_dir = app_path.resolve() / "Contents" / "Frameworks"
    for name in ("Codex Framework.framework", "Electron Framework.framework"):
        framework = frameworks_dir / name
        executable_name = Path(name).stem
        candidates = [
            framework / executable_name,
            framework / "Versions" / "Current" / executable_name,
        ]
        candidates.extend(sorted((framework / "Versions").glob(f"*/{executable_name}")))
        for candidate in candidates:
            if candidate.exists():
                return candidate
    return None


def app_main_executable(app_path: Path) -> Path | None:
    app_path = app_path.resolve()
    info_plist = app_path / "Contents/Info.plist"
    try:
        with info_plist.open("rb") as handle:
            executable_name = plistlib.load(handle).get("CFBundleExecutable")
    except (OSError, plistlib.InvalidFileException):
        executable_name = None

    if (
        isinstance(executable_name, str)
        and executable_name
        and Path(executable_name).name == executable_name
    ):
        candidate = app_path / "Contents/MacOS" / executable_name
        if candidate.is_file():
            return candidate

    macos_dir = app_path / "Contents/MacOS"
    for name in ("ChatGPT", "Codex"):
        candidate = macos_dir / name
        if candidate.is_file():
            return candidate
    return next((path for path in sorted(macos_dir.glob("*")) if path.is_file()), None)


def executable_and_framework_team_ids_match(app_path: Path) -> bool:
    app_path = app_path.resolve()
    main_executable = app_main_executable(app_path)
    electron_framework = app_framework_executable(app_path)
    if main_executable is None:
        print(f"ERROR: Could not find the desktop app executable under {app_path}")
        return False
    if electron_framework is None:
        print(f"ERROR: Could not find Codex/Electron framework executable under {app_path}")
        return False
    main_team = codesign_team_identifier(main_executable)
    framework_team = codesign_team_identifier(electron_framework)
    if main_team != framework_team:
        print(
            "ERROR: dyld-signature mismatch: "
            f"{main_executable} TeamIdentifier={main_team or 'not set'}; "
            f"{electron_framework} TeamIdentifier={framework_team or 'not set'}"
        )
        return False
    return True


def bundled_cli_preserves_computer_use_parent_requirement() -> bool:
    return (
        codesign_team_identifier(BUNDLED_CLI_PATH) == OPENAI_TEAM_ID
        and cli_supports_gpt55(BUNDLED_CLI_PATH)
    )


def computer_use_plugin_signature_preserved(app_path: Path) -> bool:
    targets = computer_use_plugin_signing_targets(app_path)
    if len(targets) != 2:
        return False
    plugin_teams = [codesign_team_identifier(target) for target in targets]
    if any(team != OPENAI_TEAM_ID for team in plugin_teams):
        return False
    if any(OPENAI_TEAM_ID not in codesign_entitlements_text(target) for target in targets):
        return False
    if any(not codesign_strictly_valid(target) for target in targets):
        return False
    assessments = [spctl_assessment(target) for target in targets]
    if any(assessment == "rejected" for assessment in assessments):
        return False
    if any(assessment == "unavailable" for assessment in assessments):
        print(
            "WARNING: Gatekeeper assessment is unavailable because macOS returned "
            "an internal Code Signing subsystem error; strict OpenAI signature "
            "verification passed."
        )
    return True


def restore_official_bundled_cli(app_path: Path) -> tuple[bool, bool]:
    """Restore Codex.app's bundled CLI from the official OpenAI DMG.

    The official Computer Use helper embeds an AMFI launch constraint requiring
    its parent process to be signed by OpenAI's Team ID. A locally patched
    bundled CLI breaks that parent requirement even when the helper itself is
    notarized.
    """
    with tempfile.TemporaryDirectory(prefix="codex-bundled-cli-restore.") as tmp:
        tmpdir = Path(tmp)
        dmg = tmpdir / "Codex.dmg"
        mount = tmpdir / "mnt"
        mount.mkdir()

        download = subprocess.run(
            ["curl", "-L", "--fail", "--silent", "--show-error", "-o", str(dmg), OFFICIAL_CODEX_DMG_URL],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if download.returncode != 0:
            print(f"ERROR: failed to download official Codex DMG: {download.stderr.strip()}")
            return False, False

        attached = False
        try:
            attach = subprocess.run(
                ["hdiutil", "attach", str(dmg), "-mountpoint", str(mount), "-nobrowse", "-quiet"],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if attach.returncode != 0:
                print(f"ERROR: failed to mount official Codex DMG: {attach.stderr.strip()}")
                return False, False
            attached = True

            source = mount / "Codex.app/Contents/Resources/codex"
            if not source.exists():
                print(f"ERROR: official bundled Codex CLI not found in DMG: {source}")
                return False, False

            BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
            backup = BACKUP_ROOT / f"codex-before-official-restore-{os.getpid()}"
            if BUNDLED_CLI_PATH.exists() and not backup.exists():
                shutil.copy2(BUNDLED_CLI_PATH, backup)

            shutil.copy2(source, BUNDLED_CLI_PATH)
            os.chmod(BUNDLED_CLI_PATH, 0o755)
        finally:
            if attached:
                subprocess.run(
                    ["hdiutil", "detach", str(mount), "-quiet"],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )

    if not bundled_cli_preserves_computer_use_parent_requirement():
        print("WARNING: official bundled CLI restore did not preserve OpenAI parent signature")
        return False, False
    return True, True


def needs_computer_use_plugin_signature_repair(app_path: Path) -> bool:
    return not computer_use_plugin_signature_preserved(app_path)


def restore_official_computer_use_plugin(app_path: Path) -> bool:
    """Restore the notarized OpenAI Computer Use plugin from the official DMG.

    Computer Use has Apple launch constraints and TCC/Apple Events behavior tied
    to OpenAI's notarized signature. Local re-signing either triggers AMFI
    provisioning failures or breaks Apple Events with teamNotFound, so the only
    safe repair is to put the official nested plugin back.
    """
    with tempfile.TemporaryDirectory(prefix="codex-computer-use-restore.") as tmp:
        tmpdir = Path(tmp)
        dmg = tmpdir / "Codex.dmg"
        mount = tmpdir / "mnt"
        mount.mkdir()

        download = subprocess.run(
            ["curl", "-L", "--fail", "--silent", "--show-error", "-o", str(dmg), OFFICIAL_CODEX_DMG_URL],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if download.returncode != 0:
            print(f"WARNING: failed to download official Codex DMG: {download.stderr.strip()}")
            return False

        attached = False
        try:
            attach = subprocess.run(
                ["hdiutil", "attach", str(dmg), "-mountpoint", str(mount), "-nobrowse", "-quiet"],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if attach.returncode != 0:
                print(f"WARNING: failed to mount official Codex DMG: {attach.stderr.strip()}")
                return False
            attached = True

            source = mount / "Codex.app" / COMPUTER_USE_PLUGIN_APP_RELATIVE.parent
            destination = app_path / COMPUTER_USE_PLUGIN_APP_RELATIVE.parent
            if not source.exists():
                print(f"WARNING: official Computer Use plugin not found at {source}")
                return False

            backup = BACKUP_ROOT / f"computer-use-before-official-restore-{os.getpid()}"
            if destination.exists():
                backup.parent.mkdir(parents=True, exist_ok=True)
                if backup.exists():
                    shutil.rmtree(backup)
                shutil.copytree(destination, backup, symlinks=True)
                shutil.rmtree(destination)
            shutil.copytree(source, destination, symlinks=True)
        finally:
            if attached:
                subprocess.run(
                    ["hdiutil", "detach", str(mount), "-quiet"],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

    if not computer_use_plugin_signature_preserved(app_path):
        print("WARNING: official Computer Use plugin restore did not produce a valid OpenAI signature")
        return False
    return True


def ensure_computer_use_plugin_signature_compatible(
    app_path: Path,
    identity: str,
) -> bool:
    """Verify Computer Use remains the official notarized OpenAI plugin."""
    if not computer_use_plugin_signing_targets(app_path):
        print("WARNING: Computer Use plugin not found; skipping plugin signature compatibility repair")
        return True
    if computer_use_plugin_signature_preserved(app_path):
        return True

    print("ERROR: Computer Use plugin signature is not OpenAI-preserved; refusing to modify plugin files")
    return False


def restore_asar_from_workdir(
    rollback_asar: Path,
    rollback_unpacked: Path,
    rollback_info_plist: Path | None = None,
    rollback_bundled_cli: Path | None = None,
) -> bool:
    """Restore the original app.asar payload if patch installation fails."""
    try:
        if rollback_asar.exists():
            shutil.copyfile(rollback_asar, ASAR_PATH)
        if rollback_unpacked.exists():
            if ASAR_UNPACKED.exists():
                shutil.rmtree(ASAR_UNPACKED)
            shutil.copytree(rollback_unpacked, ASAR_UNPACKED)
        if rollback_info_plist and rollback_info_plist.exists():
            shutil.copyfile(rollback_info_plist, INFO_PLIST_PATH)
        if rollback_bundled_cli and rollback_bundled_cli.exists():
            shutil.copy2(rollback_bundled_cli, BUNDLED_CLI_PATH)
        return True
    except Exception as exc:
        print(f"ERROR: Failed to restore original app payload after patch failure: {exc}")
        return False


def atomic_copy_file(source: Path, destination: Path) -> None:
    """Copy source to destination without ever unlinking destination first."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp_destination = destination.parent / f".{destination.name}.codexswitch-{os.getpid()}.tmp"
    try:
        if temp_destination.exists():
            temp_destination.unlink()
        shutil.copyfile(source, temp_destination)
        shutil.copystat(source, temp_destination, follow_symlinks=True)
        os.replace(temp_destination, destination)
    except Exception:
        try:
            if temp_destination.exists():
                temp_destination.unlink()
        finally:
            raise


def atomic_replace_tree(source: Path, destination: Path) -> None:
    """Replace a directory tree while preserving the old tree until the new tree exists."""
    parent = destination.parent
    temp_destination = parent / f".{destination.name}.codexswitch-{os.getpid()}.tmp"
    old_destination = parent / f".{destination.name}.codexswitch-{os.getpid()}.old"
    try:
        if temp_destination.exists():
            shutil.rmtree(temp_destination)
        if old_destination.exists():
            shutil.rmtree(old_destination)
        shutil.copytree(source, temp_destination, symlinks=True)
        if destination.exists():
            os.replace(destination, old_destination)
        os.replace(temp_destination, destination)
        if old_destination.exists():
            shutil.rmtree(old_destination)
    except Exception:
        if old_destination.exists() and not destination.exists():
            os.replace(old_destination, destination)
        if temp_destination.exists():
            shutil.rmtree(temp_destination, ignore_errors=True)
        if old_destination.exists():
            shutil.rmtree(old_destination, ignore_errors=True)
        raise


def preflight_app_resource_write() -> bool:
    """Fail before extraction if this process cannot create resources in Codex.app."""
    probe = APP_RESOURCES / f".codexswitch-write-test-{os.getpid()}"
    try:
        probe.write_text("ok")
        probe.unlink()
        return True
    except PermissionError as exc:
        print(
            f"ERROR: CodexSwitch cannot write inside {APP_PATH}. "
            "Grant App Management/Full Disk Access to CodexSwitch or run the patcher "
            f"from Terminal. Original app.asar was not touched. ({exc})"
        )
        return False
    except OSError as exc:
        print(
            "ERROR: CodexSwitch resource write preflight failed. "
            f"Original app.asar was not touched. ({exc})"
        )
        return False


def _is_signable_resource_binary(path: Path) -> bool:
    return (
        path.is_file()
        and "Contents/Resources" in path.as_posix()
        and (path.name in RESOURCE_EXECUTABLE_NAMES or os.access(path, os.X_OK))
    )


def _is_signable_macos_binary(path: Path, app_path: Path) -> bool:
    try:
        relative = path.resolve().relative_to(app_path.resolve())
    except ValueError:
        return False
    return (
        path.is_file()
        and len(relative.parts) >= 3
        and relative.parts[0] == "Contents"
        and relative.parts[-2] == "MacOS"
        and os.access(path, os.X_OK)
    )


def _is_bundled_plugin_code(path: Path, app_path: Path) -> bool:
    try:
        relative = path.resolve().relative_to(app_path.resolve())
    except ValueError:
        return False
    return relative.parts[:3] == ("Contents", "Resources", "plugins")


def _is_asar_unpacked_resource(path: Path, app_path: Path) -> bool:
    try:
        relative = path.resolve().relative_to(app_path.resolve())
    except ValueError:
        return False
    return relative.parts[:3] == ("Contents", "Resources", "app.asar.unpacked")


def _is_macho_file(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def list_codesign_targets(app_path: Path) -> list[Path]:
    """Return nested code objects in inside-out signing order.

    Files are signed before their containing bundles. The top-level app is
    always last.
    """
    app_path = app_path.resolve()
    targets: set[Path] = set()

    for path in app_path.rglob("*"):
        if path == app_path:
            continue
        if _is_asar_unpacked_resource(path, app_path):
            continue
        if _is_bundled_plugin_code(path, app_path):
            continue
        if (
            path == app_path / "Contents/Resources/codex"
            and computer_use_plugin_signing_targets(app_path)
        ):
            continue
        if path.is_dir() and path.suffix in BUNDLE_CODE_SUFFIXES:
            targets.add(path)
            continue
        if path.is_file() and _is_macho_file(path) and (
            path.suffix in FILE_CODE_SUFFIXES
            or _is_signable_resource_binary(path)
            or _is_signable_macos_binary(path, app_path)
        ):
            targets.add(path)

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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    requested_identity = requested_codesign_identity(sys.argv)
    if requested_identity is not None:
        print(requested_identity)
        sys.exit(0)

    if not ASAR_PATH.exists():
        print(f"OpenAI desktop app not found at {APP_PATH}")
        sys.exit(3)
    app_path = APP_PATH
    if codex_app_is_running() and os.environ.get("CODEXSWITCH_ALLOW_LIVE_DESKTOP_PATCH") != "1":
        print(
            f"ERROR: {APP_PATH.name} is running. Refusing to patch or re-sign the live "
            "desktop app because that can SIGKILL the app-server and reset macOS "
            "permission trust. Quit Codex.app first, or set "
            "CODEXSWITCH_ALLOW_LIVE_DESKTOP_PATCH=1 for a deliberate emergency override."
        )
        sys.exit(2)
    if not preflight_app_resource_write():
        sys.exit(1)
    if not usable_codesign_identity_available():
        sys.exit(1)

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
    rollback_asar = workdir / "rollback.app.asar"
    rollback_unpacked = workdir / "rollback.app.asar.unpacked"
    rollback_info_plist = workdir / "rollback.Info.plist"
    rollback_bundled_cli = workdir / "rollback.codex"
    shutil.copy2(ASAR_PATH, rollback_asar)
    shutil.copy2(INFO_PLIST_PATH, rollback_info_plist)
    if BUNDLED_CLI_PATH.exists():
        shutil.copy2(BUNDLED_CLI_PATH, rollback_bundled_cli)
    if ASAR_UNPACKED.exists():
        shutil.copytree(ASAR_UNPACKED, rollback_unpacked)

    print("Extracting app.asar...")
    if not extract_asar(asar_copy, extract_dir):
        print("ERROR: Failed to extract asar")
        sys.exit(1)

    assets_dir = extract_dir / "webview" / "assets"
    auth_file = find_auth_file(assets_dir)
    if not auth_file:
        print("WARNING: Could not find use-auth JS file -- app structure may have changed")
        sys.exit(2)
    fast_mode_file = find_fast_mode_file(assets_dir)
    if not fast_mode_file:
        print("WARNING: Could not find fast-mode JS file -- app structure may have changed")
        sys.exit(2)
    remote_recents_file = find_remote_recents_file(assets_dir)
    if not remote_recents_file:
        print("WARNING: Could not find remote recents JS file -- skipping optional remote sidebar refresh patch")
    model_label_file = find_model_label_file(assets_dir)
    if not model_label_file:
        print("WARNING: Could not find model picker JS file -- app structure may have changed")
        sys.exit(2)
    model_filter_file = find_model_filter_file(assets_dir)
    if not model_filter_file:
        print("WARNING: Could not find model filter JS file -- app structure may have changed")
        sys.exit(2)
    remote_model_refresh_file = find_remote_model_refresh_file(assets_dir)
    if not remote_model_refresh_file:
        print("WARNING: Could not find remote model refresh JS file -- app structure may have changed")
        sys.exit(2)
    print(f"Found auth file: {auth_file.name}")
    print(f"Found fast-mode file: {fast_mode_file.name}")
    if remote_recents_file:
        print(f"Found remote recents file: {remote_recents_file.name}")
    print(f"Found model picker file: {model_label_file.name}")
    print(f"Found model filter file: {model_filter_file.name}")
    print(f"Found remote model refresh file: {remote_model_refresh_file.name}")
    print("Desktop patch scope: auth hot-swap, Fast Mode metadata, remote sidebar/model refresh, and known-model availability/labels/efforts; bundled CLI and plugin files are preserved.")

    auth_already_patched = current_auth_patch_present(auth_file.read_text())
    fast_already_patched = FAST_FALLBACK_MARKER in fast_mode_file.read_text()
    remote_recents_already_patched = bool(
        remote_recents_file
        and has_remote_recents_refresh_patch(remote_recents_file.read_text())
    )
    model_file_content = model_label_file.read_text()
    model_filter_content = model_filter_file.read_text()
    model_label_already_patched = MODEL_LABEL_FALLBACK_MARKER in model_file_content
    model_availability_already_patched = (
        MODEL_AVAILABILITY_FALLBACK_MARKER in model_filter_content
    )
    selected_model_label_already_patched = (
        SELECTED_MODEL_LABEL_FALLBACK_MARKER in model_file_content
    )
    gpt56_max_effort_already_patched = (
        has_gpt56_max_effort_filter_patch(model_filter_content)
        and has_gpt56_max_effort_preset_patch(model_file_content)
    )
    remote_model_refresh_already_patched = (
        REMOTE_MODEL_REFRESH_MARKER in remote_model_refresh_file.read_text()
    )
    all_required_patches_present = required_renderer_patches_present(
        auth=auth_already_patched,
        remote_recents=remote_recents_file is None or remote_recents_already_patched,
        fast=fast_already_patched,
        model_label=model_label_already_patched,
        model_availability=model_availability_already_patched,
        selected_model_label=selected_model_label_already_patched,
        gpt56_max_effort=gpt56_max_effort_already_patched,
        remote_model_refresh=remote_model_refresh_already_patched,
    )
    if all_required_patches_present:
        print("Already patched; verifying ASAR integrity metadata...")
        integrity_changed = update_electron_asar_integrity(ASAR_PATH)
        plugin_signature_repair_needed = needs_computer_use_plugin_signature_repair(
            APP_PATH
        )
        app_signature_repair_needed_now = app_signature_repair_needed(
            APP_PATH
        )
        if plugin_signature_repair_needed:
            print("ERROR: Computer Use plugin signature is not OpenAI-preserved; refusing to modify plugin files")
            restore_asar_from_workdir(
                rollback_asar,
                rollback_unpacked,
                rollback_info_plist,
                rollback_bundled_cli,
            )
            sys.exit(1)
        if (
            integrity_changed
            or app_signature_repair_needed_now
        ):
            print("Re-signing Codex.app...")
            if not codesign_app():
                print("ERROR: Re-signing Codex.app failed after integrity repair")
                restore_asar_from_workdir(
                    rollback_asar,
                    rollback_unpacked,
                    rollback_info_plist,
                    rollback_bundled_cli,
                )
                sys.exit(1)
        print("Already patched, nothing else to do.")
        sys.exit(0)

    # ---- Apply patch ----
    print("Applying patch...")
    if not auth_already_patched and not apply_patch(auth_file):
        print("ERROR: Patch failed")
        sys.exit(1)
    if not fast_already_patched:
        if not apply_required_fast_mode_patch(fast_mode_file):
            print("ERROR: Required Fast Mode fallback patch failed")
            sys.exit(1)
    if remote_recents_file and not remote_recents_already_patched:
        if not apply_remote_recents_refresh_patch(remote_recents_file):
            print("ERROR: Remote sidebar refresh patch failed")
            sys.exit(1)
    if not model_label_already_patched:
        if not apply_model_label_fallback_patch(model_label_file):
            print("ERROR: Model label fallback patch failed")
            sys.exit(1)
    if not model_availability_already_patched:
        if not apply_model_availability_fallback_patch(model_filter_file):
            print("ERROR: Model availability fallback patch failed")
            sys.exit(1)
    if not selected_model_label_already_patched:
        if not apply_selected_model_label_fallback_patch(model_label_file):
            print("ERROR: Selected model label fallback patch failed")
            sys.exit(1)
    if not gpt56_max_effort_already_patched:
        if not apply_gpt56_max_effort_filter_patch(model_filter_file):
            print("ERROR: GPT-5.6 max effort filter patch failed")
            sys.exit(1)
        if not apply_gpt56_max_effort_preset_patch(model_label_file):
            print("ERROR: GPT-5.6 max effort preset patch failed")
            sys.exit(1)
    if not remote_model_refresh_already_patched:
        if not apply_remote_model_refresh_patch(remote_model_refresh_file):
            print("ERROR: Remote model refresh patch failed")
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

    # Free the bulky extracted workspace before installation. On low-disk
    # machines, keeping the source tree around here can starve the final copy.
    print("Freeing extraction workspace before install...")
    shutil.rmtree(extract_dir, ignore_errors=True)
    if asar_copy.exists():
        asar_copy.unlink()
    copied_unpacked = workdir / "app.asar.unpacked"
    if copied_unpacked.exists():
        shutil.rmtree(copied_unpacked, ignore_errors=True)

    # ---- Backup + install ----
    BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
    if ASAR_BACKUP.exists() and ASAR_BACKUP.stat().st_size == 0:
        print("Removing incomplete zero-byte backup...")
        ASAR_BACKUP.unlink()

    if not ASAR_BACKUP.exists():
        print(f"Creating backup: {ASAR_BACKUP}")
        # Keep backups outside the signed app bundle. Recent macOS builds can
        # allow direct resource writes while rejecting new sibling backup files
        # inside /Applications/Codex.app with EPERM.
        shutil.copyfile(ASAR_PATH, ASAR_BACKUP)
    else:
        print(f"Backup already exists: {ASAR_BACKUP}")

    print("Installing patched asar...")
    try:
        atomic_copy_file(repacked_asar, ASAR_PATH)
        atomic_replace_tree(repacked_unpacked, ASAR_UNPACKED)
    except Exception as exc:
        print(f"ERROR: Atomic ASAR install failed; restoring original app payload: {exc}")
        restore_asar_from_workdir(
            rollback_asar,
            rollback_unpacked,
            rollback_info_plist,
            rollback_bundled_cli,
        )
        sys.exit(1)

    print("Updating Electron ASAR integrity...")
    update_electron_asar_integrity(ASAR_PATH)

    print("Verifying bundled Codex CLI and Computer Use plugin signatures are preserved...")
    if not bundled_cli_preserves_computer_use_parent_requirement():
        print("ERROR: Bundled Codex CLI signature changed; restoring original app payload")
        restore_asar_from_workdir(
            rollback_asar,
            rollback_unpacked,
            rollback_info_plist,
            rollback_bundled_cli,
        )
        sys.exit(1)
    if needs_computer_use_plugin_signature_repair(APP_PATH):
        print("ERROR: Computer Use plugin signature changed; restoring original app payload")
        restore_asar_from_workdir(
            rollback_asar,
            rollback_unpacked,
            rollback_info_plist,
            rollback_bundled_cli,
        )
        sys.exit(1)

    # ---- Re-sign ----
    print("Re-signing Codex.app...")
    if not codesign_app():
        print("ERROR: Re-signing Codex.app failed; restoring original app payload")
        restore_asar_from_workdir(
            rollback_asar,
            rollback_unpacked,
            rollback_info_plist,
            rollback_bundled_cli,
        )
        sys.exit(1)

    # ---- Clean up old extracted dir if left behind by previous runs ----
    old_extracted = APP_RESOURCES / "app.asar.extracted"
    if old_extracted.exists():
        print("Cleaning up leftover app.asar.extracted directory...")
        shutil.rmtree(old_extracted, ignore_errors=True)

    print("Done! Codex desktop app will use the patch on next restart.")
    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Apply the exact Clodex patch for CodexSwitch-owned OAuth credentials."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import stat
import sys
import uuid


PINNED_VERSION = "2.1.3"
EXPECTED_ORIGINAL_SHA256 = (
    "61f6113b06507533ebe7714ff5ba66df6252332ca1b4f2fe0bd6922ccb4398c9"
)
EXPECTED_LEGACY_PATCHED_SHA256 = (
    "867537210c5f9295ad2e8cbe99dde5f1430f7cb854cd530b734763ebac3dafb1"
)
EXPECTED_PATCHED_SHA256 = (
    "d5c13c2321edd14aec557e79d31a75a1f9efc4b80d43de4f5223403e2b2bf81f"
)
MARKER = b"/* codexswitch-managed-oauth-v1 */"
CCS_PASSTHROUGH_MARKER = b"/* codexswitch-ccs-anthropic-v1 */"
ORIGINAL = b"""      cacheOAuthCredential(stateKey, cred);
      const forceRefresh = cred.access === rejectedAccessToken || cred.accessRejected === true;
      if (!forceRefresh && !oauthCredentialShouldRefresh(cred, providerId)) {
        return cred.access;
      }
"""
PASSTHROUGH_TRANSPORT_ORIGINAL = b"""    const upstream = https.request({
      protocol: "https:",
      hostname: origin.hostname,
      port: origin.port || 443,
      method: req.method,
      path: req.url,
      headers: requestHeadersWithoutProxyHeaders(req),
      servername: net.isIP(origin.hostname) ? void 0 : origin.hostname,
      rejectUnauthorized
    }, (upstreamRes) => {
"""
PASSTHROUGH_TRANSPORT_PATCHED = b"""    /* codexswitch-ccs-anthropic-v1 */
    const upstreamTransport = origin.protocol === "http:" ? http : https;
    const upstream = upstreamTransport.request({
      protocol: origin.protocol,
      hostname: origin.hostname,
      port: origin.port || (origin.protocol === "http:" ? 80 : 443),
      method: req.method,
      path: req.url,
      headers: requestHeadersWithoutProxyHeaders(req),
      servername: origin.protocol === "https:" && !net.isIP(origin.hostname) ? origin.hostname : void 0,
      rejectUnauthorized: origin.protocol === "https:" ? rejectUnauthorized : void 0
    }, (upstreamRes) => {
"""
PASSTHROUGH_OPTIONS_ORIGINAL = b"""function buildConfiguredHttpProxyOptions(loaded, port, debug = false, inferenceLogPath = getInferenceRequestLogPath(), debugLogPath, webSocketDiagnosticsLogPath) {
  return {
    host: "127.0.0.1",
    port,
    routes: loaded.routes,
    modelAliases: loaded.aliases,
    reservedModelIds: loaded.unavailableAliases.map((alias) => alias.name),
    debug,
    debugLogPath,
    inferenceLogPath,
    webSocketDiagnosticsLogPath
  };
}
"""
PASSTHROUGH_OPTIONS_PATCHED = b"""function buildConfiguredHttpProxyOptions(loaded, port, debug = false, inferenceLogPath = getInferenceRequestLogPath(), debugLogPath, webSocketDiagnosticsLogPath) {
  /* codexswitch-ccs-anthropic-v1 */
  const configuredAnthropicOrigin = process.env["CLODEX_ANTHROPIC_PASSTHROUGH_BASE_URL"]?.trim();
  let anthropicOrigin;
  if (configuredAnthropicOrigin) {
    const parsedOrigin = new URL2(configuredAnthropicOrigin);
    if (parsedOrigin.protocol !== "http:" || parsedOrigin.hostname !== "127.0.0.1" || parsedOrigin.username || parsedOrigin.password || parsedOrigin.pathname !== "/" || parsedOrigin.search || parsedOrigin.hash) {
      throw new Error("CodexSwitch CCS passthrough requires an uncredentialed loopback HTTP origin");
    }
    if (!process.env["ANTHROPIC_AUTH_TOKEN"]?.trim()) {
      throw new Error("CodexSwitch CCS passthrough requires the CCS gateway credential");
    }
    anthropicOrigin = parsedOrigin.origin;
  }
  return {
    host: "127.0.0.1",
    port,
    routes: loaded.routes,
    modelAliases: loaded.aliases,
    reservedModelIds: loaded.unavailableAliases.map((alias) => alias.name),
    debug,
    debugLogPath,
    inferenceLogPath,
    webSocketDiagnosticsLogPath,
    ...anthropicOrigin ? { anthropicOrigin } : {}
  };
}
"""
PATCHED = b"""      /* codexswitch-managed-oauth-v1 */
      const codexSwitchManaged = cred.providerData?.credentialOwner === \"codexswitch\" && cred.providerData?.bridgeVersion === 1;
      const forceRefresh = cred.access === rejectedAccessToken || cred.accessRejected === true;
      if (codexSwitchManaged) {
        oauthCredentialCache.delete(stateKey);
        if (forceRefresh) {
          diag?.(\"CodexSwitch-managed OAuth credential was rejected; waiting for CodexSwitch to refresh or swap it\");
          return null;
        }
        if (oauthCredentialShouldRefresh(cred, providerId)) {
          diag?.(\"CodexSwitch-managed OAuth credential is near expiration; waiting for CodexSwitch to refresh or swap it\");
          return null;
        }
        return cred.access;
      }
      cacheOAuthCredential(stateKey, cred);
      if (!forceRefresh && !oauthCredentialShouldRefresh(cred, providerId)) {
        return cred.access;
      }
"""


class PatchError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_regular(path: pathlib.Path) -> tuple[bytes, int]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise PatchError(f"not a regular file: {path}")
        if info.st_uid != os.getuid():
            raise PatchError(f"file is not owned by the current user: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), stat.S_IMODE(info.st_mode)
    finally:
        os.close(descriptor)


def verify_package_root(package_root: pathlib.Path) -> pathlib.Path:
    package_root = package_root.resolve(strict=True)
    package_json = package_root / "package.json"
    raw, _ = read_regular(package_json)
    try:
        metadata = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PatchError("Clodex package metadata is invalid") from error
    if metadata.get("name") != "@bman654/clodex":
        raise PatchError("unexpected Clodex package name")
    if metadata.get("version") != PINNED_VERSION:
        raise PatchError(
            f"unsupported Clodex version {metadata.get('version')!r}; "
            f"expected {PINNED_VERSION}"
        )
    return package_root / "dist" / "cli.js"


def verify_postimage(data: bytes) -> None:
    if digest(data) != EXPECTED_PATCHED_SHA256:
        raise PatchError("Clodex CodexSwitch postimage hash mismatch")
    if (
        data.count(MARKER) != 1
        or data.count(PATCHED) != 1
        or data.count(CCS_PASSTHROUGH_MARKER) != 2
        or data.count(PASSTHROUGH_TRANSPORT_PATCHED) != 1
        or data.count(PASSTHROUGH_OPTIONS_PATCHED) != 1
    ):
        raise PatchError("Clodex CodexSwitch postimage is incomplete")
    if (
        ORIGINAL in data
        or PASSTHROUGH_TRANSPORT_ORIGINAL in data
        or PASSTHROUGH_OPTIONS_ORIGINAL in data
    ):
        raise PatchError("Clodex original paths remain in the postimage")


def verify_legacy_postimage(data: bytes) -> None:
    if digest(data) != EXPECTED_LEGACY_PATCHED_SHA256:
        raise PatchError("Clodex legacy managed-credential hash mismatch")
    if (
        data.count(MARKER) != 1
        or data.count(PATCHED) != 1
        or data.count(CCS_PASSTHROUGH_MARKER) != 0
        or data.count(PASSTHROUGH_TRANSPORT_ORIGINAL) != 1
        or data.count(PASSTHROUGH_OPTIONS_ORIGINAL) != 1
    ):
        raise PatchError("Clodex legacy postimage is inconsistent")


def atomic_replace(path: pathlib.Path, data: bytes, mode: int) -> None:
    temporary = path.parent / f".{path.name}.codexswitch-{os.getpid()}-{uuid.uuid4().hex}"
    descriptor: int | None = None
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            mode,
        )
        os.fchmod(descriptor, mode)
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise PatchError("short write while installing Clodex patch")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        directory = os.open(
            path.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def apply_patch(cli_path: pathlib.Path) -> str:
    data, mode = read_regular(cli_path)
    current = digest(data)
    if current == EXPECTED_PATCHED_SHA256:
        verify_postimage(data)
        return "already-patched"
    if current == EXPECTED_ORIGINAL_SHA256:
        if (
            data.count(ORIGINAL) != 1
            or data.count(PASSTHROUGH_TRANSPORT_ORIGINAL) != 1
            or data.count(PASSTHROUGH_OPTIONS_ORIGINAL) != 1
            or MARKER in data
            or CCS_PASSTHROUGH_MARKER in data
        ):
            raise PatchError("Clodex CodexSwitch anchors are missing or ambiguous")
        patched = (
            data.replace(ORIGINAL, PATCHED)
            .replace(
                PASSTHROUGH_TRANSPORT_ORIGINAL,
                PASSTHROUGH_TRANSPORT_PATCHED,
            )
            .replace(
                PASSTHROUGH_OPTIONS_ORIGINAL,
                PASSTHROUGH_OPTIONS_PATCHED,
            )
        )
        result = "patched"
    elif current == EXPECTED_LEGACY_PATCHED_SHA256:
        verify_legacy_postimage(data)
        patched = data.replace(
            PASSTHROUGH_TRANSPORT_ORIGINAL,
            PASSTHROUGH_TRANSPORT_PATCHED,
        ).replace(
            PASSTHROUGH_OPTIONS_ORIGINAL,
            PASSTHROUGH_OPTIONS_PATCHED,
        )
        result = "upgraded"
    else:
        raise PatchError(f"unknown Clodex cli.js preimage {current}")
    verify_postimage(patched)
    atomic_replace(cli_path, patched, mode)
    readback, _ = read_regular(cli_path)
    verify_postimage(readback)
    return result


def check_patch(cli_path: pathlib.Path) -> str:
    data, _ = read_regular(cli_path)
    verify_postimage(data)
    return "ready"


def restore_patch(cli_path: pathlib.Path) -> str:
    data, mode = read_regular(cli_path)
    current = digest(data)
    if current == EXPECTED_ORIGINAL_SHA256:
        if MARKER in data or data.count(ORIGINAL) != 1:
            raise PatchError("Clodex original postimage is inconsistent")
        return "already-original"
    if current == EXPECTED_LEGACY_PATCHED_SHA256:
        verify_legacy_postimage(data)
        original = data.replace(PATCHED, ORIGINAL)
    else:
        verify_postimage(data)
        original = (
            data.replace(PATCHED, ORIGINAL)
            .replace(
                PASSTHROUGH_TRANSPORT_PATCHED,
                PASSTHROUGH_TRANSPORT_ORIGINAL,
            )
            .replace(
                PASSTHROUGH_OPTIONS_PATCHED,
                PASSTHROUGH_OPTIONS_ORIGINAL,
            )
        )
    if digest(original) != EXPECTED_ORIGINAL_SHA256:
        raise PatchError("Clodex rollback image does not match the pinned original")
    atomic_replace(cli_path, original, mode)
    readback, _ = read_regular(cli_path)
    if digest(readback) != EXPECTED_ORIGINAL_SHA256:
        raise PatchError("Clodex rollback readback failed")
    return "restored"


def main() -> int:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--apply", action="store_true")
    action.add_argument("--check", action="store_true")
    action.add_argument("--restore", action="store_true")
    parser.add_argument("--package-root", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        cli_path = verify_package_root(args.package_root)
        if args.apply:
            result = apply_patch(cli_path)
        elif args.check:
            result = check_patch(cli_path)
        else:
            result = restore_patch(cli_path)
        print(
            f"clodex-codexswitch: {result} "
            f"{PINNED_VERSION} {digest(read_regular(cli_path)[0])}"
        )
        return 0
    except (OSError, PatchError) as error:
        print(f"clodex-codexswitch: refused: {error}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""VPS-local Clodex helper with a read-through CodexSwitch credential."""

from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import uuid


MAX_CREDENTIAL_BYTES = 16 * 1024 * 1024
MAX_ENCRYPTED_BYTES = 32 * 1024 * 1024
TESTING = os.environ.get("CLODEX_CREDENTIAL_HELPER_TESTING") == "1"
STORE_ROOT = pathlib.Path(
    os.environ.get(
        "CLODEX_CREDENTIAL_STORE_ROOT",
        str(pathlib.Path.home() / ".local/share/clodex-credential-helper"),
    )
    if TESTING
    else pathlib.Path.home() / ".local/share/clodex-credential-helper"
)
AGE_BIN = (
    os.environ.get("CLODEX_AGE_BIN", "/usr/bin/age")
    if TESTING
    else "/usr/bin/age"
)
AGE_KEYGEN_BIN = (
    os.environ.get("CLODEX_AGE_KEYGEN_BIN", "/usr/bin/age-keygen")
    if TESTING
    else "/usr/bin/age-keygen"
)
IDENTITY_PATH = STORE_ROOT / "identity.txt"
OBJECT_ROOT = STORE_ROOT / "objects"
LOCK_PATH = STORE_ROOT / "helper.lock"
CODEXSWITCH_HOME = pathlib.Path(
    os.environ.get("CLODEX_CODEXSWITCH_HOME", str(pathlib.Path.home()))
    if TESTING
    else pathlib.Path.home()
)
MANAGED_ACCOUNT_PATTERN = re.compile(
    r"^oauth:provider:openai-oauth::credential::v1:[0-9a-f]{32}$"
)
SUPPORTED_ACTIVATION_VERSION = 3
TERMINAL_ACTIVATION_STATES = {"confirmed", "file_only", "committed_degraded"}
MAX_ACCOUNT_STORE_BYTES = 32 * 1024 * 1024
MAX_AUTH_BYTES = 4 * 1024 * 1024
MAX_ACTIVATION_BYTES = 4 * 1024 * 1024


class HelperError(RuntimeError):
    pass


def is_managed_account(service: str, account: str) -> bool:
    return service == "clodex" and MANAGED_ACCOUNT_PATTERN.fullmatch(account) is not None


def validate_directory_descriptor(
    descriptor: int, label: str, *, require_mode: int | None = None
) -> None:
    info = os.fstat(descriptor)
    if not stat.S_ISDIR(info.st_mode):
        raise HelperError(f"unsafe directory type: {label}")
    if info.st_uid != os.getuid():
        raise HelperError(f"unsafe directory owner: {label}")
    mode = stat.S_IMODE(info.st_mode)
    if require_mode is not None:
        if mode != require_mode:
            raise HelperError(f"unsafe directory mode: {label}")
    elif mode & 0o022:
        raise HelperError(f"writable home directory is unsafe: {label}")


def open_directory_at(parent: int, name: str, label: str) -> int:
    if "/" in name or name in {"", ".", ".."}:
        raise HelperError(f"invalid directory component: {label}")
    descriptor = os.open(
        name,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent,
    )
    try:
        validate_directory_descriptor(descriptor, label, require_mode=0o700)
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def open_private_file_at(
    directory: int, name: str, label: str, maximum: int, *, read_write: bool = False
) -> tuple[int, bytes]:
    if "/" in name or name in {"", ".", ".."}:
        raise HelperError(f"invalid file component: {label}")
    flags = (os.O_RDWR if read_write else os.O_RDONLY) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=directory)
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise HelperError(f"unsafe file identity or mode: {label}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise HelperError(f"file exceeds bound: {label}")
        return descriptor, b"".join(chunks)
    except Exception:
        os.close(descriptor)
        raise


def decode_json_object(raw: bytes, label: str) -> dict:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HelperError(f"invalid JSON: {label}") from error
    if not isinstance(value, dict):
        raise HelperError(f"unexpected JSON type: {label}")
    return value


def jwt_expiration_millis(token: str) -> int:
    parts = token.split(".")
    if len(parts) < 2:
        raise HelperError("managed access token is not a JWT")
    try:
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise HelperError("managed access token JWT is invalid") from error
    expiration = claims.get("exp") if isinstance(claims, dict) else None
    if not isinstance(expiration, (int, float)) or isinstance(expiration, bool):
        raise HelperError("managed access token JWT expiration is missing")
    expiration_millis = int(expiration * 1000)
    if expiration_millis <= 0:
        raise HelperError("managed access token JWT expiration is invalid")
    return expiration_millis


def managed_credential() -> bytes:
    if not CODEXSWITCH_HOME.is_absolute():
        raise HelperError("CodexSwitch home must be absolute")
    home = os.open(
        CODEXSWITCH_HOME,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    codexswitch = codex = lock = None
    try:
        validate_directory_descriptor(home, str(CODEXSWITCH_HOME))
        codexswitch = open_directory_at(
            home, ".codexswitch", str(CODEXSWITCH_HOME / ".codexswitch")
        )
        codex = open_directory_at(home, ".codex", str(CODEXSWITCH_HOME / ".codex"))

        lock, _ = open_private_file_at(
            codexswitch,
            "accounts.json.lock",
            "CodexSwitch account-store lock",
            1024,
            read_write=True,
        )
        fcntl.flock(lock, fcntl.LOCK_SH)

        accounts_fd, accounts_raw = open_private_file_at(
            codexswitch,
            "accounts.json",
            "CodexSwitch account store",
            MAX_ACCOUNT_STORE_BYTES,
        )
        os.close(accounts_fd)
        activation_fd, activation_raw = open_private_file_at(
            codexswitch,
            "accounts.activation.json",
            "CodexSwitch activation record",
            MAX_ACTIVATION_BYTES,
        )
        os.close(activation_fd)
        auth_fd, auth_raw = open_private_file_at(
            codex, "auth.json", "Codex auth file", MAX_AUTH_BYTES
        )
        os.close(auth_fd)

        try:
            accounts = json.loads(accounts_raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise HelperError("invalid CodexSwitch account store") from error
        if not isinstance(accounts, list):
            raise HelperError("unsupported CodexSwitch account-store schema")
        active = [
            account
            for account in accounts
            if isinstance(account, dict) and account.get("isActive") is True
        ]
        if len(active) != 1:
            raise HelperError("CodexSwitch active account is ambiguous")
        account = active[0]
        account_fields = {
            "accessToken": "access_token",
            "refreshToken": "refresh_token",
            "idToken": "id_token",
            "accountId": "account_id",
        }
        for source_name in account_fields:
            if not isinstance(account.get(source_name), str) or not account[source_name]:
                raise HelperError("CodexSwitch active account token set is incomplete")

        activation = decode_json_object(activation_raw, "CodexSwitch activation record")
        if activation.get("version") != SUPPORTED_ACTIVATION_VERSION:
            raise HelperError("unsupported CodexSwitch activation-record version")
        if activation.get("state") not in TERMINAL_ACTIVATION_STATES:
            raise HelperError("CodexSwitch activation state is not terminal")
        if activation.get("targetAccountId") != account["accountId"]:
            raise HelperError("CodexSwitch activation target is not the active account")

        auth = decode_json_object(auth_raw, "Codex auth file")
        tokens = auth.get("tokens")
        if auth.get("auth_mode") != "chatgpt" or not isinstance(tokens, dict):
            raise HelperError("Codex auth mode or token schema is unsupported")
        for auth_name in account_fields.values():
            if not isinstance(tokens.get(auth_name), str) or not tokens[auth_name]:
                raise HelperError("Codex auth token set is incomplete")
        if tokens["account_id"] != account["accountId"]:
            raise HelperError("CodexSwitch active identity and Codex auth identity differ")

        # Codex may refresh its active token generation in auth.json after the
        # CodexSwitch activation commit. The account ID remains the stable
        # selection boundary; auth.json is authoritative for the current token
        # generation of that selected identity.
        expiration = jwt_expiration_millis(tokens["access_token"])
        value = {
            "type": "oauth",
            "access": tokens["access_token"],
            "refresh": tokens["refresh_token"],
            "expires": expiration,
            "accountId": tokens["account_id"],
            "providerData": {
                "credentialOwner": "codexswitch",
                "bridgeVersion": 1,
            },
        }
        return json.dumps(value, separators=(",", ":")).encode("utf-8")
    finally:
        if lock is not None:
            try:
                fcntl.flock(lock, fcntl.LOCK_UN)
            finally:
                os.close(lock)
        if codex is not None:
            os.close(codex)
        if codexswitch is not None:
            os.close(codexswitch)
        os.close(home)


def fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_private_directory(path: pathlib.Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        path.mkdir(mode=0o700, parents=False)
        fsync_directory(path.parent)
        info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise HelperError(f"unsafe credential directory: {path}")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise HelperError(f"credential directory ownership or mode mismatch: {path}")


def initialize_layout() -> None:
    parent = STORE_ROOT.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        STORE_ROOT.mkdir(mode=0o700)
    except FileExistsError:
        ensure_private_directory(STORE_ROOT)
    else:
        fsync_directory(parent)
    try:
        OBJECT_ROOT.mkdir(mode=0o700)
    except FileExistsError:
        ensure_private_directory(OBJECT_ROOT)
    else:
        fsync_directory(STORE_ROOT)


def verify_private_file(path: pathlib.Path, descriptor: int) -> None:
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        raise HelperError(f"credential object is not regular: {path}")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise HelperError(f"credential object ownership or mode mismatch: {path}")


def open_locked() -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(LOCK_PATH, flags, 0o600)
    try:
        verify_private_file(LOCK_PATH, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def ensure_identity() -> str:
    if not IDENTITY_PATH.exists():
        temporary = STORE_ROOT / f".identity.{os.getpid()}.{uuid.uuid4().hex}.tmp"
        try:
            result = subprocess.run(
                [AGE_KEYGEN_BIN, "-o", str(temporary)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            if result.returncode != 0:
                raise HelperError("age identity generation failed")
            descriptor = os.open(
                temporary,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                os.fchmod(descriptor, 0o600)
                verify_private_file(temporary, descriptor)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            os.replace(temporary, IDENTITY_PATH)
            fsync_directory(STORE_ROOT)
        finally:
            temporary.unlink(missing_ok=True)

    descriptor = os.open(
        IDENTITY_PATH,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        verify_private_file(IDENTITY_PATH, descriptor)
    finally:
        os.close(descriptor)

    result = subprocess.run(
        [AGE_KEYGEN_BIN, "-y", str(IDENTITY_PATH)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    recipient = result.stdout.decode("ascii", "strict").strip()
    if result.returncode != 0 or not recipient.startswith("age1"):
        raise HelperError("age recipient derivation failed")
    return recipient


def object_path(service: str, account: str) -> pathlib.Path:
    if service != "clodex" or not account or len(account.encode()) > 1024:
        raise HelperError("invalid credential identifier")
    digest = hashlib.sha256(
        service.encode() + b"\0" + account.encode("utf-8", "strict")
    ).hexdigest()
    return OBJECT_ROOT / f"{digest}.age"


def set_credential(path: pathlib.Path, value: bytes) -> None:
    if not value or len(value) > MAX_CREDENTIAL_BYTES:
        raise HelperError("credential input length is invalid")
    recipient = ensure_identity()
    temporary = OBJECT_ROOT / f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    try:
        result = subprocess.run(
            [
                AGE_BIN,
                "--encrypt",
                "--recipient",
                recipient,
                "--output",
                str(temporary),
                "-",
            ],
            input=value,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if result.returncode != 0:
            raise HelperError("credential encryption failed")
        descriptor = os.open(
            temporary,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            os.fchmod(descriptor, 0o600)
            verify_private_file(temporary, descriptor)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
        fsync_directory(OBJECT_ROOT)
    finally:
        temporary.unlink(missing_ok=True)


def read_encrypted(path: pathlib.Path) -> bytes:
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
    except FileNotFoundError:
        raise
    try:
        verify_private_file(path, descriptor)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ENCRYPTED_BYTES:
                raise HelperError("encrypted credential is too large")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def get_credential(path: pathlib.Path) -> bytes:
    encrypted = read_encrypted(path)
    ensure_identity()
    result = subprocess.run(
        [AGE_BIN, "--decrypt", "--identity", str(IDENTITY_PATH), "-"],
        input=encrypted,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.returncode != 0 or len(result.stdout) > MAX_CREDENTIAL_BYTES:
        raise HelperError("credential decryption failed")
    return result.stdout


def delete_credential(path: pathlib.Path) -> None:
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
    except FileNotFoundError:
        raise
    try:
        verify_private_file(path, descriptor)
    finally:
        os.close(descriptor)
    path.unlink()
    fsync_directory(OBJECT_ROOT)


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in {"get", "set", "delete"}:
        return 64
    operation, service, account = sys.argv[1:]
    try:
        if is_managed_account(service, account):
            if operation != "get":
                raise HelperError("CodexSwitch-managed credentials are read-only")
            sys.stdout.buffer.write(managed_credential())
            sys.stdout.buffer.flush()
            return 0
        initialize_layout()
        path = object_path(service, account)
        lock = open_locked()
        try:
            if operation == "set":
                value = sys.stdin.buffer.read(MAX_CREDENTIAL_BYTES + 1)
                set_credential(path, value)
            elif operation == "get":
                sys.stdout.buffer.write(get_credential(path))
                sys.stdout.buffer.flush()
            else:
                delete_credential(path)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
    except FileNotFoundError:
        return 2
    except (HelperError, OSError, subprocess.SubprocessError, UnicodeError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

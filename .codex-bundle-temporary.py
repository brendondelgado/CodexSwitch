#!/usr/bin/env python3

import argparse
import base64
import hashlib
import json
import os
import secrets
import socket
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(fd)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True)
    parser.add_argument("--expected-active", required=True)
    args = parser.parse_args()

    with open(args.store, "rb") as handle:
        accounts = json.load(handle)
    if not isinstance(accounts, list) or not accounts:
        raise SystemExit("account store is empty or malformed")

    active = [account for account in accounts if account.get("isActive") is True]
    if len(active) != 1:
        raise SystemExit("account store must contain exactly one active account")
    if active[0].get("email") != args.expected_active:
        raise SystemExit("active account changed before bundle creation")

    required = ("id", "email", "accessToken", "refreshToken", "idToken", "accountId")
    for account in accounts:
        if any(not isinstance(account.get(field), str) or not account[field] for field in required):
            raise SystemExit("account store contains an incomplete credential tuple")

    now = datetime.now(timezone.utc).replace(microsecond=0)
    expires = now + timedelta(minutes=10)
    metadata = {
        "schemaVersion": 2,
        "createdAt": now.isoformat().replace("+00:00", "Z"),
        "expiresAt": expires.isoformat().replace("+00:00", "Z"),
        "exportedByHost": socket.gethostname(),
        "accountCount": len(accounts),
        "activeAccountId": active[0]["accountId"],
        "activeEmail": active[0]["email"],
        "emails": [account["email"] for account in accounts],
    }
    plaintext = json.dumps(
        {"metadata": metadata, "accounts": accounts},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    if len(plaintext) > 8 * 1024 * 1024:
        raise SystemExit("bundle payload exceeds the supported size")

    passphrase = secrets.token_urlsafe(48).encode("ascii")
    salt = os.urandom(32)
    nonce = os.urandom(12)
    key = hashlib.pbkdf2_hmac("sha256", passphrase, salt, 600_000, dklen=32)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, None)
    envelope = {
        "format": "codexswitch-linux-devbox-bundle",
        "schemaVersion": 2,
        "kdf": "pbkdf2-hmac-sha256-v2",
        "iterations": 600_000,
        "cipher": "aes-256-gcm",
        "salt": base64.b64encode(salt).decode("ascii"),
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
    }

    stage = Path(tempfile.mkdtemp(prefix="codexswitch-vps-sync.", dir="/private/tmp"))
    os.chmod(stage, 0o700)
    bundle_path = stage / "accounts.csbundle"
    passphrase_path = stage / "passphrase"
    write_private(bundle_path, json.dumps(envelope, sort_keys=True).encode("utf-8"))
    write_private(passphrase_path, passphrase)

    print(stage)
    print(bundle_path)
    print(passphrase_path)
    print(active[0]["email"])
    print(len(accounts))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read-only per-account credential freshness report. Never prints token values.

Usage: credential-freshness-report.py [ACCOUNTS_JSON]  (default ~/.codexswitch/accounts.json)
Columns: email, access-token issued/expiry (UTC), refresh-token SHA-256 prefix,
runtime block reason. Compare the Mac and VPS outputs line by line: equal refresh
prefixes mean both hosts hold the same refresh-token chain.
"""
import base64
import datetime
import hashlib
import json
import os
import sys


def claims(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError, AttributeError):
        return {}


def stamp(value):
    if not isinstance(value, (int, float)):
        return "-"
    return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.codexswitch/accounts.json")
    with open(path, encoding="utf-8") as source:
        accounts = json.load(source)
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    for account in sorted(accounts, key=lambda item: item.get("email", "")):
        access = claims(account.get("accessToken") or "")
        refresh = account.get("refreshToken") or ""
        expiry = access.get("exp")
        state = "EXPIRED" if isinstance(expiry, (int, float)) and expiry <= now else "ok"
        print(
            f"{account.get('email', '?'):32} iat={stamp(access.get('iat'))} exp={stamp(expiry)} {state:7} "
            f"rt={hashlib.sha256(refresh.encode()).hexdigest()[:10] if refresh else '-'} "
            f"active={bool(account.get('isActive'))} block={account.get('runtimeUnusableReason') or '-'}"
        )


if __name__ == "__main__":
    main()

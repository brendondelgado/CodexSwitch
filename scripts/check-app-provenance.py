#!/usr/bin/env python3
"""Reject an accidental app downgrade before the installer performs work."""

import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def check(root: Path, installed: Path) -> None:
    if not installed.exists():
        return
    with (installed / 'Contents/Info.plist').open('rb') as source:
        revision = plistlib.load(source).get('CFBundleSourceRevision', '')
    match = re.fullmatch(r'([0-9a-f]{7,40})(?:-dirty\.[0-9a-f]+)?', revision)
    if not match:
        raise ValueError('Installed app source provenance is missing or unrecognized')
    commit = match.group(1)
    resolved = subprocess.run(['git', '-C', str(root), 'rev-parse', '--verify', commit + '^{commit}'], capture_output=True, text=True)
    if resolved.returncode:
        raise ValueError('Installed app source commit is not available in this checkout')
    ancestry = subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', resolved.stdout.strip(), 'HEAD'], capture_output=True)
    if ancestry.returncode:
        raise ValueError('Build checkout does not include the installed app source commit')


if __name__ == '__main__':
    if os.environ.get('CODEXSWITCH_ALLOW_DOWNGRADE') == '1':
        print('Warning: explicit app downgrade override enabled', file=sys.stderr)
    else:
        try:
            check(Path(sys.argv[1]), Path(sys.argv[2]))
        except Exception as error:
            print(f'error: {error}; installed app unchanged. Use a compatible checkout or an explicitly reviewed downgrade.', file=sys.stderr)
            sys.exit(1)

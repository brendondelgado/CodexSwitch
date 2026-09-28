#!/usr/bin/env bash
# Install the T3 usage hub on the VPS. Touches only the hub: never CodexSwitch, Codex, or T3.
# Usage: integrations/t3-usage-hub/install.sh [ssh-host]   (default: signul-vps)
set -euo pipefail
host="${1:-signul-vps}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

python3 -m py_compile "$here/hub.py"
python3 "$here/test_hub.py" >/dev/null 2>&1 || { echo "hub tests failed; not installing" >&2; exit 1; }

scp -q "$here/hub.py" "$host:.local/share/signul/codex-usage-hub/hub.py.new"
scp -q "$here/codex-usage-hub.service" "$host:.config/systemd/user/codex-usage-hub.service.new"
ssh "$host" STAMP="$stamp" bash -s <<'REMOTE'
set -euo pipefail
dir="$HOME/.local/share/signul/codex-usage-hub"
unit="$HOME/.config/systemd/user/codex-usage-hub.service"
python3 -m py_compile "$dir/hub.py.new"
test -s "$dir/management-key" || { echo "missing management key" >&2; exit 1; }
if pgrep -x codexswitch-cli -a | grep -q redeem-reset; then
  echo "a reset redemption is in flight; retry later" >&2; exit 1
fi
[ -f "$dir/hub.py" ] && cp -p "$dir/hub.py" "$dir/hub.py.bak-$STAMP"
[ -f "$unit" ] && cp -p "$unit" "$unit.bak-$STAMP"
mv "$dir/hub.py.new" "$dir/hub.py"
mv "$unit.new" "$unit"
systemctl --user daemon-reload
systemctl --user enable --now codex-usage-hub.service >/dev/null
systemctl --user restart codex-usage-hub.service
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$dir/management-key")" \
    http://127.0.0.1:8319/v0/management/auth-files || true)"
  [ "$code" = 200 ] && { echo "hub healthy (backup suffix $STAMP)"; exit 0; }
  sleep 0.5
done
echo "hub did not become healthy; restoring backup" >&2
[ -f "$dir/hub.py.bak-$STAMP" ] && cp -p "$dir/hub.py.bak-$STAMP" "$dir/hub.py"
[ -f "$unit.bak-$STAMP" ] && cp -p "$unit.bak-$STAMP" "$unit"
systemctl --user daemon-reload; systemctl --user restart codex-usage-hub.service
exit 1
REMOTE

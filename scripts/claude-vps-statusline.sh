#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude Code'
  exit 0
fi

model="$(jq -r '.model.display_name // .model.name // .model // "Claude"' <<<"$input" 2>/dev/null || printf 'Claude')"
cwd="$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input" 2>/dev/null || true)"
branch="$(jq -r '.workspace.git_branch // .git.branch // empty' <<<"$input" 2>/dev/null || true)"
context_pct="$(jq -r '.context_window.used_percentage // .context_window.current_usage // empty' <<<"$input" 2>/dev/null || true)"
cost="$(jq -r '.cost.total_cost_usd // .total_cost_usd // .session_cost_usd // empty' <<<"$input" 2>/dev/null || true)"
rate_5h="$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input" 2>/dev/null || true)"

if [ -n "$cwd" ]; then
  cwd="${cwd/#$HOME/~}"
else
  cwd="$(pwd 2>/dev/null || true)"
fi

parts=()
parts+=("$model")
[ -n "$cwd" ] && parts+=("$cwd")
[ -n "$branch" ] && parts+=("git:$branch")

if [[ "$context_pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  parts+=("ctx:${context_pct%.*}%")
fi

if [[ "$rate_5h" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  parts+=("5h:${rate_5h%.*}%")
fi

if [[ "$cost" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  parts+=("cost:\$$(printf '%.2f' "$cost")")
fi

printf '%s' "${parts[0]}"
for part in "${parts[@]:1}"; do
  printf ' | %s' "$part"
done

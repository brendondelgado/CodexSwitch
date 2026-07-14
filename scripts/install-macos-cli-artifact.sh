#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 <macos-runtime-artifact-directory>"
  exit 64
}

[[ $# -eq 1 ]] || usage
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
  print -u2 "this installer is only for macOS"
  exit 1
}

download_dir="${1:a}"
repo_root="${0:A:h:h}"
artifact_verifier="$repo_root/scripts/verify_macos_runtime_artifact.py"
installed_cli="$HOME/.local/bin/codexswitch-cli"
local_launcher="$HOME/.local/bin/codex"
homebrew_launcher="/opt/homebrew/bin/codex"
managed_launcher="$HOME/.local/share/codexswitch/patched-codex/codex"
trusted_repository="brendondelgado/CodexSwitch"
trusted_workflow="brendondelgado/CodexSwitch/.github/workflows/build-fork.yml"

[[ -d "$download_dir" && ! -L "$download_dir" ]] || {
  print -u2 "artifact must be a regular directory, not a symlink: $download_dir"
  exit 1
}
[[ -f "$artifact_verifier" && ! -L "$artifact_verifier" ]] || {
  print -u2 "repository artifact verifier is missing or linked: $artifact_verifier"
  exit 1
}

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexswitch-macos-install.XXXXXX")"
work_dir="${work_dir:A}"
cleanup() {
  /bin/chmod -R u+w "$work_dir" 2>/dev/null || true
  /bin/rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM HUP

artifact_dir="$work_dir/artifact"
control_cli="$artifact_dir/codexswitch-cli"
snapshot_report="$work_dir/snapshot-report.json"
/usr/bin/python3 "$artifact_verifier" snapshot \
  --source "$download_dir" \
  --destination "$artifact_dir" > "$snapshot_report"

manifest_values="$work_dir/manifest-values"
/usr/bin/python3 - "$snapshot_report" > "$manifest_values" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as handle:
    report = json.load(handle)
if set(report) != {"sourceSha", "upstreamVersion", "buildVersion", "manifestSha256"}:
    raise SystemExit("snapshot verifier returned an unexpected report")
print(report["sourceSha"])
print(report["upstreamVersion"])
print(report["buildVersion"])
print(report["manifestSha256"])
PY

manifest_lines=()
while IFS= read -r line; do
  manifest_lines+=("$line")
done < "$manifest_values"
[[ ${#manifest_lines[@]} -eq 4 ]] || {
  print -u2 "manifest verifier returned an invalid result"
  exit 1
}
source_sha="${manifest_lines[1]}"
upstream_version="${manifest_lines[2]}"
expected_build_version="${manifest_lines[3]}"
manifest_sha256="${manifest_lines[4]}"

verify_frozen_snapshot() {
  local observed_report="$work_dir/observed-snapshot-report.json"
  /usr/bin/python3 "$artifact_verifier" verify \
    --directory "$artifact_dir" > "$observed_report"
  /usr/bin/cmp -s "$snapshot_report" "$observed_report" || {
    print -u2 "private artifact snapshot changed after trust verification"
    exit 1
  }
}

[[ "$(/usr/bin/git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || {
  print -u2 "installer is not running from the canonical CodexSwitch repository"
  exit 1
}
[[ "$(/usr/bin/git -C "$repo_root" branch --show-current)" == "main" ]] || {
  print -u2 "artifact activation requires the local main branch"
  exit 1
}
[[ "$(/usr/bin/git -C "$repo_root" rev-parse HEAD)" == "$source_sha" ]] || {
  print -u2 "artifact commit does not match the reviewed local checkout"
  exit 1
}
[[ -z "$(/usr/bin/git -C "$repo_root" status --porcelain --untracked-files=normal)" ]] || {
  print -u2 "artifact activation requires a clean local checkout"
  exit 1
}

gh_binary="$(command -v gh)" || {
  print -u2 "GitHub CLI is required to verify artifact attestations"
  exit 1
}
for name in manifest.json codex codex-code-mode-host codexswitch-cli; do
  "$gh_binary" attestation verify "$artifact_dir/$name" \
    --repo "$trusted_repository" \
    --signer-workflow "$trusted_workflow" \
    --signer-digest "$source_sha" \
    --source-ref refs/heads/main \
    --source-digest "$source_sha" \
    --deny-self-hosted-runners >/dev/null
done
verify_frozen_snapshot

for name in codex codex-code-mode-host codexswitch-cli; do
  path="$artifact_dir/$name"
  [[ "$(/usr/bin/lipo -archs "$path")" == "arm64" ]] || {
    print -u2 "artifact member is not a thin arm64 executable: $name"
    exit 1
  }
  /usr/bin/file -b "$path" | /usr/bin/grep -Fq "Mach-O 64-bit executable arm64" || {
    print -u2 "artifact member has the wrong Mach-O shape: $name"
    exit 1
  }
  /usr/bin/codesign --verify --strict "$path"
done

marker_dump="$work_dir/control-markers"
/usr/bin/strings -a "$control_cli" > "$marker_dump"
for marker in \
  codexswitch-macos-runtime-artifact-v1 \
  codexswitch-macos-runtime-activation-v1 \
  activate-macos-runtime-artifact \
  install-prepared-codex; do
  /usr/bin/grep -Fq -- "$marker" "$marker_dump" || {
    print -u2 "artifact control plane is missing required marker: $marker"
    exit 1
  }
done

[[ "$("$control_cli" --version)" == "$expected_build_version" ]] || {
  print -u2 "artifact control-plane version does not match its manifest"
  exit 1
}
verify_frozen_snapshot
activation_report="$work_dir/activation-report.json"
"$control_cli" activate-macos-runtime-artifact \
  --directory "$artifact_dir" \
  --json > "$activation_report"
/usr/bin/python3 - "$activation_report" "$upstream_version" "$manifest_sha256" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as handle:
    report = json.load(handle)
if report.get("status") != "installed":
    raise SystemExit("macOS runtime activation did not report installed")
if report.get("installedVersion") != sys.argv[2]:
    raise SystemExit("macOS runtime activation committed the wrong version")
if report.get("installedArtifactManifestSha256") != sys.argv[3]:
    raise SystemExit("macOS runtime activation committed the wrong artifact manifest")
if report.get("error") is not None:
    raise SystemExit("macOS runtime activation reported an error")
PY

for path in "$installed_cli" "$local_launcher" "$homebrew_launcher" "$managed_launcher"; do
  [[ -f "$path" && -x "$path" && ! -L "$path" ]] || {
    print -u2 "activated CodexSwitch route is missing, linked, or not executable: $path"
    exit 1
  }
done
/usr/bin/cmp -s "$local_launcher" "$homebrew_launcher" || {
  print -u2 "local and Homebrew Codex bridges do not match"
  exit 1
}
/usr/bin/cmp -s "$installed_cli" "$control_cli" || {
  print -u2 "installed CodexSwitch control plane bytes do not match the attested snapshot"
  exit 1
}
[[ "$("$installed_cli" --version)" == "$expected_build_version" ]] || {
  print -u2 "installed CodexSwitch control plane does not match the artifact"
  exit 1
}
"$local_launcher" --version
print "Activated the attested CodexSwitch macOS runtime set."
print "Exit and resume the current Codex CLI thread once to enter the new runtime."

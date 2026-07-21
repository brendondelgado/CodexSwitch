#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <downloaded-linux-runtime-artifact-directory> <new-reviewed-artifact-directory>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
[[ "$(uname -s)" == "Linux" ]] || {
  echo "this staging command is only for Linux" >&2
  exit 1
}

download_dir="$(realpath -e -- "$1")"
destination="$2"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
artifact_verifier="$repo_root/scripts/verify_linux_runtime_artifact.py"
trusted_repository="brendondelgado/CodexSwitch"
trusted_workflow="brendondelgado/CodexSwitch/.github/workflows/build-linux-runtime.yml"

[[ -d "$download_dir" && ! -L "$download_dir" ]] || {
  echo "artifact must be a regular directory, not a symlink: $download_dir" >&2
  exit 1
}
[[ -f "$artifact_verifier" && ! -L "$artifact_verifier" ]] || {
  echo "repository artifact verifier is missing or linked: $artifact_verifier" >&2
  exit 1
}
[[ "$destination" == /* ]] || {
  echo "reviewed artifact destination must be absolute" >&2
  exit 1
}
[[ ! -e "$destination" && ! -L "$destination" ]] || {
  echo "reviewed artifact destination already exists: $destination" >&2
  exit 1
}
destination_parent="$(dirname -- "$destination")"
[[ -d "$destination_parent" && ! -L "$destination_parent" ]] || {
  echo "reviewed artifact destination parent is missing or linked: $destination_parent" >&2
  exit 1
}
destination_parent="$(cd -- "$destination_parent" && pwd -P)"
destination="$destination_parent/$(basename -- "$destination")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexswitch-linux-artifact.XXXXXX")"
work_dir="$(cd -- "$work_dir" && pwd -P)"
cleanup() {
  chmod -R u+w "$work_dir" 2>/dev/null || true
  rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM HUP

quarantine_dir="$work_dir/quarantine"
snapshot_report="$work_dir/snapshot-report.json"
python3 "$artifact_verifier" snapshot \
  --source "$download_dir" \
  --destination "$quarantine_dir" > "$snapshot_report"

source_sha="$(python3 - "$snapshot_report" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as handle:
    report = json.load(handle)
expected = {
    "artifactBytes",
    "buildEpoch",
    "buildVersion",
    "manifestSha256",
    "sourcePatchSha256",
    "sourceSha",
    "upstreamSha",
    "upstreamVersion",
}
if set(report) != expected:
    raise SystemExit("artifact verifier returned an unexpected report")
print(report["sourceSha"])
PY
)"

[[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || {
  echo "staging command is not running from the canonical CodexSwitch repository" >&2
  exit 1
}
[[ "$(git -C "$repo_root" branch --show-current)" == "main" ]] || {
  echo "artifact staging requires the local main branch" >&2
  exit 1
}
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$source_sha" ]] || {
  echo "artifact commit does not match the reviewed local checkout" >&2
  exit 1
}
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]] || {
  echo "artifact staging requires a clean local checkout" >&2
  exit 1
}

gh_binary="$(command -v gh)" || {
  echo "GitHub CLI is required to verify artifact attestations" >&2
  exit 1
}
for name in manifest.json codex codex-code-mode-host codexswitch-cli; do
  "$gh_binary" attestation verify "$quarantine_dir/$name" \
    --repo "$trusted_repository" \
    --signer-workflow "$trusted_workflow" \
    --signer-digest "$source_sha" \
    --source-ref refs/heads/main \
    --source-digest "$source_sha" \
    --deny-self-hosted-runners >/dev/null
done

verified_report="$work_dir/verified-report.json"
python3 "$artifact_verifier" verify \
  --directory "$quarantine_dir" \
  --mode quarantine > "$verified_report"
cmp -s "$snapshot_report" "$verified_report" || {
  echo "quarantined artifact changed after attestation verification" >&2
  exit 1
}

staged_report="$work_dir/staged-report.json"
python3 "$artifact_verifier" promote \
  --source "$quarantine_dir" \
  --destination "$destination" > "$staged_report"
cmp -s "$snapshot_report" "$staged_report" || {
  echo "reviewed artifact changed while executable modes were restored" >&2
  exit 1
}
python3 "$artifact_verifier" verify \
  --directory "$destination" \
  --mode staged >/dev/null

printf 'Reviewed Linux runtime artifact staged at %s\n' "$destination"
printf 'Use CODEXSWITCH_LINUX_ARTIFACT_DIR=%q with scripts/install-linux.sh\n' "$destination"

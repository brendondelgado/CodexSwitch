#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_TAG="v7.2.98"
UPSTREAM_COMMIT="35ebe3f3ed1e74ffb49da399ea371f27db8e926b"
MODELS_PREIMAGE_SHA256="56408aa0eee545d24dd10543b1cbf50b8da82bee3d1b288ee2641fcf9d41cd06"
OUTPUT="${1:-$PWD/cli-proxy-api-v7.2.98-codexswitch-opus5-linux-amd64}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-opus5-build.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

curl -fsSL \
  "https://api.github.com/repos/router-for-me/CLIProxyAPI/tarball/${UPSTREAM_TAG}" \
  | tar -xz -C "$WORKDIR" --strip-components=1

models="$WORKDIR/internal/registry/models/models.json"
definitions="$WORKDIR/internal/registry/model_definitions.go"
actual_preimage="$(shasum -a 256 "$models" | awk '{print $1}')"
if [ "$actual_preimage" != "$MODELS_PREIMAGE_SHA256" ]; then
  printf 'REFUSED: CLIProxy models preimage drifted: %s\n' "$actual_preimage" >&2
  exit 1
fi

python3 - "$models" "$definitions" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
definitions_path = pathlib.Path(sys.argv[2])
payload = json.loads(path.read_text())
models = payload.get("claude")
if not isinstance(models, list):
    raise SystemExit("REFUSED: CLIProxy Claude registry shape is unknown")
if any(model.get("id") == "claude-opus-5" for model in models):
    raise SystemExit("REFUSED: upstream already contains Claude Opus 5")

entry = {
    "id": "claude-opus-5",
    "object": "model",
    "created": 1784851200,
    "owned_by": "anthropic",
    "type": "claude",
    "display_name": "Claude Opus 5",
    "description": "Anthropic's latest Opus model",
    "context_length": 1000000,
    "max_completion_tokens": 128000,
    "thinking": {
        "min": 1024,
        "max": 128000,
        "zero_allowed": True,
        "levels": ["low", "medium", "high", "xhigh", "max"],
    },
}
insert_at = next(
    (index for index, model in enumerate(models) if model.get("id") == "claude-opus-4-8"),
    None,
)
if insert_at is None:
    raise SystemExit("REFUSED: pinned Opus 4.8 registry anchor is missing")
models.insert(insert_at, entry)
path.write_text(json.dumps(payload, indent=2) + "\n")

definitions = definitions_path.read_text()
replacements = {
    """const (
\tcodexBuiltinImage15ModelID      = "gpt-image-1.5"
""": """const (
\tclaudeBuiltinOpus5ModelID       = "claude-opus-5"
\tcodexBuiltinImage15ModelID      = "gpt-image-1.5"
""",
    """func GetClaudeModels() []*ModelInfo {
\treturn cloneModelInfos(getModels().Claude)
}
""": """func GetClaudeModels() []*ModelInfo {
\treturn WithClaudeBuiltins(cloneModelInfos(getModels().Claude))
}
""",
    """// WithCodexBuiltins injects hard-coded Codex-only model definitions that should
""": """// WithClaudeBuiltins keeps newly released Claude models available when the
// upstream remote models catalog has not caught up with the Claude Code client.
func WithClaudeBuiltins(models []*ModelInfo) []*ModelInfo {
\treturn upsertModelInfos(models, claudeBuiltinOpus5ModelInfo())
}

func claudeBuiltinOpus5ModelInfo() *ModelInfo {
\treturn &ModelInfo{
\t\tID:                  claudeBuiltinOpus5ModelID,
\t\tObject:              "model",
\t\tCreated:             1784851200,
\t\tOwnedBy:             "anthropic",
\t\tType:                "claude",
\t\tDisplayName:         "Claude Opus 5",
\t\tDescription:         "Anthropic's latest Opus model",
\t\tContextLength:       1000000,
\t\tMaxCompletionTokens: 128000,
\t\tThinking: &ThinkingSupport{
\t\t\tMin:         1024,
\t\t\tMax:         128000,
\t\t\tZeroAllowed: true,
\t\t\tLevels:      []string{"low", "medium", "high", "xhigh", "max"},
\t\t},
\t}
}

// WithCodexBuiltins injects hard-coded Codex-only model definitions that should
""",
}
for before, after in replacements.items():
    if definitions.count(before) != 1:
        raise SystemExit("REFUSED: CLIProxy Claude built-in patch anchor drifted")
    definitions = definitions.replace(before, after)
definitions_path.write_text(definitions)
PY

if [ "$(jq '[.claude[] | select(.id=="claude-opus-5")] | length' "$models")" != "1" ]; then
  printf 'REFUSED: patched CLIProxy registry failed cardinality verification\n' >&2
  exit 1
fi

gofmt -w "$definitions"
(
  cd "$WORKDIR"
  GOTOOLCHAIN=auto go test ./internal/registry
)

mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$WORKDIR"
  GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -buildvcs=false \
      -ldflags="-s -w -X main.Version=7.2.98-codexswitch-opus5 -X main.Commit=${UPSTREAM_COMMIT}+opus5 -X main.BuildDate=2026-07-24T00:00:00Z" \
      -o "$OUTPUT" \
      ./cmd/server
)

chmod 0755 "$OUTPUT"
if ! file "$OUTPUT" | grep -q 'ELF 64-bit.*x86-64'; then
  printf 'REFUSED: build output is not a Linux amd64 ELF binary\n' >&2
  exit 1
fi

printf 'built=%s\n' "$OUTPUT"
shasum -a 256 "$OUTPUT"

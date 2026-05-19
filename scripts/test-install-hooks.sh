#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

mkdir -p "$TMP_HOME/.claude" "$TMP_HOME/.cursor" "$TMP_HOME/.codex"
printf '{}' > "$TMP_HOME/.claude/settings.json"
printf '{"version":1}' > "$TMP_HOME/.cursor/hooks.json"
: > "$TMP_HOME/.codex/hooks.json"

HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" >/tmp/zellaude-install-hooks-test.log

jq -e '
  .hooks.SessionStart[0].hooks[0].command
  | test("zellaude-hook\\.sh codex$")
' "$TMP_HOME/.codex/hooks.json" >/dev/null

jq -e '
  .hooks.PermissionRequest[0].hooks[0].command
  | test("zellaude-hook\\.sh codex$")
' "$TMP_HOME/.codex/hooks.json" >/dev/null

HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" --uninstall >/tmp/zellaude-install-hooks-test.log

jq -e '
  (.hooks // {})
  | to_entries
  | all(.value[]?.hooks[]?.command? // "" | test("zellaude-hook\\.sh") | not)
' "$TMP_HOME/.codex/hooks.json" >/dev/null

echo "install-hooks tests passed"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

mkdir -p "$TMP_HOME/.claude" "$TMP_HOME/.cursor" "$TMP_HOME/.codex" "$TMP_HOME/.copilot"
printf '{}' > "$TMP_HOME/.claude/settings.json"
printf '{"version":1}' > "$TMP_HOME/.cursor/hooks.json"
cat > "$TMP_HOME/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "/old/path/zellaude-hook.sh codex", "timeout": 5}]},
      {"hooks": [{"type": "command", "command": "/old/path/zellaude-hook.sh", "timeout": 5}]}
    ]
  }
}
JSON

HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" >/tmp/zellaude-install-hooks-test.log
HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" >/tmp/zellaude-install-hooks-test.log

for _ in 1 2 3 4 5; do
  HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" >/tmp/zellaude-install-hooks-test.log &
done
wait

jq -e '
  .hooks.SessionStart[0].hooks[0].command
  | test("zellaude-hook\\.sh codex$")
' "$TMP_HOME/.codex/hooks.json" >/dev/null

jq -e '
  .hooks
  | to_entries
  | all(.value | length == 1)
' "$TMP_HOME/.codex/hooks.json" >/dev/null

jq -e '
  .hooks.PermissionRequest[0].hooks[0].command
  | test("zellaude-hook\\.sh codex$")
' "$TMP_HOME/.codex/hooks.json" >/dev/null

# Copilot: dedicated zellaude.json, camelCase event keys, event echoed as arg.
jq -e '
  .version == 1 and
  (.hooks.preToolUse[0].bash | test("zellaude-hook\\.sh copilot preToolUse$")) and
  (.hooks.userPromptSubmitted[0].bash | test("zellaude-hook\\.sh copilot userPromptSubmitted$")) and
  (.hooks.agentStop[0].bash | test("zellaude-hook\\.sh copilot agentStop$")) and
  (.hooks | has("notification")) and
  (.hooks | has("permissionRequest") | not) and
  (.hooks | has("userPromptSubmit") | not) and
  (.hooks | has("stop") | not) and
  (.hooks.preToolUse[0].type == "command")
' "$TMP_HOME/.copilot/hooks/zellaude.json" >/dev/null

# Hook diagnostics contain event metadata and delivery status, not input data.
mkdir -p "$TMP_HOME/bin"
printf '%s\n' \
  '#!/bin/sh' \
  '[ "${ZELLAUDE_TEST_PIPE_HANG:-}" = 1 ] && exec sleep 10' \
  'printf "%s\n" "$*" >> "$ZELLAUDE_TEST_PIPE_LOG"' \
  > "$TMP_HOME/bin/zellij"
chmod +x "$TMP_HOME/bin/zellij"
printf '%s\n' '{"sessionId":"test-session","toolName":"bash","prompt":"private prompt"}' |
  HOME="$TMP_HOME" \
  XDG_STATE_HOME="$TMP_HOME/state" \
  PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_SESSION_NAME="test-zellij" \
  ZELLIJ_PANE_ID="42" \
  ZELLAUDE_TEST_PIPE_LOG="$TMP_HOME/pipe.log" \
  "$ROOT/scripts/zellaude-hook.sh" copilot preToolUse

grep -q 'agent=copilot event=PreToolUse session=test-zellij pane=42 tool=bash status=received' \
  "$TMP_HOME/state/zellaude/hooks.log"
grep -q 'status=delivered' "$TMP_HOME/state/zellaude/hooks.log"
! grep -q 'private prompt' "$TMP_HOME/state/zellaude/hooks.log"
grep -q '"hook_event":"PreToolUse"' "$TMP_HOME/pipe.log"

# Copilot's permissionRequest runs before auto-allow and must not show waiting.
pipe_lines=$(wc -l < "$TMP_HOME/pipe.log")
printf '%s\n' '{"sessionId":"test-session","toolName":"bash"}' |
  HOME="$TMP_HOME" \
  XDG_STATE_HOME="$TMP_HOME/state" \
  PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_SESSION_NAME="test-zellij" \
  ZELLIJ_PANE_ID="42" \
  ZELLAUDE_TEST_PIPE_LOG="$TMP_HOME/pipe.log" \
  "$ROOT/scripts/zellaude-hook.sh" copilot permissionRequest
[ "$(wc -l < "$TMP_HOME/pipe.log")" -eq "$pipe_lines" ]
grep -q 'event=permissionRequest .*status=ignored_pre_permission_service' \
  "$TMP_HOME/state/zellaude/hooks.log"

# A displayed permission prompt arrives as a notification and does show waiting.
printf '%s\n' \
  '{"sessionId":"test-session","notificationType":"permission_prompt","title":"Permission needed"}' |
  HOME="$TMP_HOME" \
  XDG_STATE_HOME="$TMP_HOME/state" \
  PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_SESSION_NAME="test-zellij" \
  ZELLIJ_PANE_ID="42" \
  ZELLAUDE_TEST_PIPE_LOG="$TMP_HOME/pipe.log" \
  "$ROOT/scripts/zellaude-hook.sh" copilot notification
grep -q '"hook_event":"PermissionRequest"' "$TMP_HOME/pipe.log"

SECONDS=0
printf '%s\n' '{"sessionId":"test-session"}' |
  HOME="$TMP_HOME" \
  XDG_STATE_HOME="$TMP_HOME/state" \
  PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_SESSION_NAME="test-zellij" \
  ZELLIJ_PANE_ID="42" \
  ZELLAUDE_TEST_PIPE_LOG="$TMP_HOME/pipe.log" \
  ZELLAUDE_TEST_PIPE_HANG=1 \
  "$ROOT/scripts/zellaude-hook.sh" copilot agentStop
[ "$SECONDS" -lt 5 ]
grep -q 'event=Stop .*status=delivery_failed' "$TMP_HOME/state/zellaude/hooks.log"

HOME="$TMP_HOME" "$ROOT/scripts/install-hooks.sh" --uninstall >/tmp/zellaude-install-hooks-test.log

jq -e '
  (.hooks // {})
  | to_entries
  | all(.value[]?.hooks[]?.command? // "" | test("zellaude-hook\\.sh") | not)
' "$TMP_HOME/.codex/hooks.json" >/dev/null

# Copilot uninstall removes the zellaude-owned file entirely.
[ ! -f "$TMP_HOME/.copilot/hooks/zellaude.json" ]

echo "install-hooks tests passed"

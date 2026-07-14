#!/usr/bin/env bash
# install-hooks.sh — Register zellaude hooks with Claude Code, cursor-agent,
# Codex CLI, and GitHub Copilot CLI
#
# Usage: ./scripts/install-hooks.sh [--uninstall]
set -euo pipefail

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
COPILOT_HOOKS="$HOME/.copilot/hooks/zellaude.json"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/zellaude-hook.sh"

LOCK_FILE="${TMPDIR:-/tmp}/zellaude-install-hooks.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock 9
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi

if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Error: Hook script not found at $HOOK_SCRIPT" >&2
  exit 1
fi

CLAUDE_EVENTS='["PreToolUse","PostToolUse","PostToolUseFailure","UserPromptSubmit","PermissionRequest","Notification","Stop","SubagentStop","SessionStart","SessionEnd"]'
CURSOR_EVENTS='["sessionStart","sessionEnd","preToolUse","postToolUse","postToolUseFailure","beforeSubmitPrompt","stop","subagentStop"]'
CODEX_EVENTS='["SessionStart","PreToolUse","PostToolUse","UserPromptSubmit","PermissionRequest","Stop"]'
# Copilot omits the event name from the hook payload, so it travels as the
# second argument (matching the config key); the hook script normalizes it.
COPILOT_EVENTS='["sessionStart","sessionEnd","preToolUse","postToolUse","postToolUseFailure","userPromptSubmitted","notification","agentStop"]'

CLAUDE_ENTRY=$(jq -nc --arg cmd "$HOOK_SCRIPT claude" '[{
  "hooks": [{
    "type": "command",
    "command": $cmd,
    "timeout": 5,
    "async": true
  }]
}]')

CURSOR_ENTRY=$(jq -nc --arg cmd "$HOOK_SCRIPT" '[{
  "command": $cmd,
  "timeout": 5
}]')

CODEX_ENTRY=$(jq -nc --arg cmd "$HOOK_SCRIPT codex" '[{
  "hooks": [{
    "type": "command",
    "command": $cmd,
    "timeout": 5
  }]
}]')

backup() {
  local f=$1
  if [ -f "$f" ]; then
    cp "$f" "$f.bak"
    echo "Backed up $f to $f.bak"
  fi
}

ensure_json_object() {
  local f=$1
  if [ ! -s "$f" ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    echo '{}' > "$f"
  fi
}

uninstall_claude() {
  [ -f "$CLAUDE_SETTINGS" ] || return 0
  ensure_json_object "$CLAUDE_SETTINGS"
  backup "$CLAUDE_SETTINGS"
  local tmp
  tmp=$(mktemp)
  # Strip any zellaude hook entry, so re-runs from different install paths
  # (e.g. WASM auto-install vs ./install.sh) don't leave duplicates behind.
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= [
          .[] | . as $group |
          ($group.hooks // []) | map(select((.command // "") | test("(^|/)zellaude-hook\\.sh(\\s+[^;&|]*)?\\s*$") | not)) |
          . as $filtered |
          if length > 0 then ($group | .hooks = $filtered) else empty end
        ]
      ) | .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$CLAUDE_SETTINGS" > "$tmp"
  mv "$tmp" "$CLAUDE_SETTINGS"
  echo "Uninstalled zellaude hooks from $CLAUDE_SETTINGS"
}

uninstall_cursor() {
  [ -f "$CURSOR_HOOKS" ] || return 0
  ensure_json_object "$CURSOR_HOOKS"
  backup "$CURSOR_HOOKS"
  local tmp
  tmp=$(mktemp)
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= map(select((.command // "") | test("(^|/)zellaude-hook\\.sh(\\s+[^;&|]*)?\\s*$") | not))
      ) | .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$CURSOR_HOOKS" > "$tmp"
  mv "$tmp" "$CURSOR_HOOKS"
  echo "Uninstalled zellaude hooks from $CURSOR_HOOKS"
}

uninstall_codex() {
  [ -f "$CODEX_HOOKS" ] || return 0
  ensure_json_object "$CODEX_HOOKS"
  backup "$CODEX_HOOKS"
  local tmp
  tmp=$(mktemp)
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= [
          .[] | . as $group |
          ($group.hooks // []) | map(select((.command // "") | test("(^|/)zellaude-hook\\.sh(\\s+[^;&|]*)?\\s*$") | not)) |
          . as $filtered |
          if length > 0 then ($group | .hooks = $filtered) else empty end
        ]
      ) | .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$CODEX_HOOKS" > "$tmp"
  mv "$tmp" "$CODEX_HOOKS"
  echo "Uninstalled zellaude hooks from $CODEX_HOOKS"
}

# Copilot hooks live in a zellaude-owned file, so uninstall just removes it.
uninstall_copilot() {
  [ -f "$COPILOT_HOOKS" ] || return 0
  rm -f "$COPILOT_HOOKS"
  echo "Uninstalled zellaude hooks from $COPILOT_HOOKS"
}

install_claude() {
  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    echo '{}' > "$CLAUDE_SETTINGS"
  fi
  ensure_json_object "$CLAUDE_SETTINGS"
  backup "$CLAUDE_SETTINGS"
  uninstall_claude 2>/dev/null || true

  local tmp
  tmp=$(mktemp)
  jq --argjson events "$CLAUDE_EVENTS" --argjson entry "$CLAUDE_ENTRY" '
    .hooks //= {} |
    reduce ($events[]) as $event (.; .hooks[$event] = (.hooks[$event] // []) + $entry)
  ' "$CLAUDE_SETTINGS" > "$tmp"
  mv "$tmp" "$CLAUDE_SETTINGS"
  echo "Installed zellaude hooks into $CLAUDE_SETTINGS"
}

install_cursor() {
  if [ ! -f "$CURSOR_HOOKS" ]; then
    mkdir -p "$(dirname "$CURSOR_HOOKS")"
    echo '{"version":1}' > "$CURSOR_HOOKS"
  fi
  ensure_json_object "$CURSOR_HOOKS"
  backup "$CURSOR_HOOKS"
  uninstall_cursor 2>/dev/null || true

  local tmp
  tmp=$(mktemp)
  jq --argjson events "$CURSOR_EVENTS" --argjson entry "$CURSOR_ENTRY" '
    .version //= 1 |
    .hooks //= {} |
    reduce ($events[]) as $event (.; .hooks[$event] = (.hooks[$event] // []) + $entry)
  ' "$CURSOR_HOOKS" > "$tmp"
  mv "$tmp" "$CURSOR_HOOKS"
  echo "Installed zellaude hooks into $CURSOR_HOOKS"
}

install_codex() {
  if [ ! -d "$HOME/.codex" ]; then
    echo "Skipping Codex hooks: $HOME/.codex does not exist"
    return 0
  fi
  if [ ! -f "$CODEX_HOOKS" ]; then
    mkdir -p "$(dirname "$CODEX_HOOKS")"
    echo '{}' > "$CODEX_HOOKS"
  fi
  ensure_json_object "$CODEX_HOOKS"
  backup "$CODEX_HOOKS"
  uninstall_codex 2>/dev/null || true

  local tmp
  tmp=$(mktemp)
  jq --argjson events "$CODEX_EVENTS" --argjson entry "$CODEX_ENTRY" '
    .hooks //= {} |
    reduce ($events[]) as $event (.; .hooks[$event] = (.hooks[$event] // []) + $entry)
  ' "$CODEX_HOOKS" > "$tmp"
  mv "$tmp" "$CODEX_HOOKS"
  echo "Installed zellaude hooks into $CODEX_HOOKS"
}

install_copilot() {
  if [ ! -d "$HOME/.copilot" ]; then
    echo "Skipping Copilot hooks: $HOME/.copilot does not exist"
    return 0
  fi
  # Copilot loads every *.json under ~/.copilot/hooks/, so zellaude owns a
  # dedicated file — no merge needed, just overwrite.
  mkdir -p "$(dirname "$COPILOT_HOOKS")"
  local tmp
  tmp=$(mktemp)
  jq -nc --arg hook "$HOOK_SCRIPT" --argjson events "$COPILOT_EVENTS" '
    {version: 1,
     hooks: (reduce ($events[]) as $e ({};
       .[$e] = [{type: "command", bash: ($hook + " copilot " + $e), timeoutSec: 5}]))}
  ' > "$tmp"
  mv "$tmp" "$COPILOT_HOOKS"
  echo "Installed zellaude hooks into $COPILOT_HOOKS"
}

case "${1:-}" in
  --uninstall)
    uninstall_claude
    uninstall_cursor
    uninstall_codex
    uninstall_copilot
    ;;
  *)
    install_claude
    install_cursor
    install_codex
    install_copilot
    echo "Hook script: $HOOK_SCRIPT"
    ;;
esac

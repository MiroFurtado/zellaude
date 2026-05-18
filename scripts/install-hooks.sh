#!/usr/bin/env bash
# install-hooks.sh — Register zellaude hooks with Claude Code, cursor-agent, and Codex CLI
#
# Usage: ./scripts/install-hooks.sh [--uninstall]
set -euo pipefail

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/zellaude-hook.sh"

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

uninstall_claude() {
  [ -f "$CLAUDE_SETTINGS" ] || return 0
  backup "$CLAUDE_SETTINGS"
  local tmp
  tmp=$(mktemp)
  # Strip any entry whose command ends with zellaude-hook.sh, so re-runs from
  # different install paths (e.g. WASM auto-install vs ./install.sh) don't leave
  # duplicates behind.
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= [
          .[] | . as $group |
          ($group.hooks // []) | map(select((.command // "") | test("zellaude-hook\\.sh(\\s+claude)?\\s*$") | not)) |
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
  backup "$CURSOR_HOOKS"
  local tmp
  tmp=$(mktemp)
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= map(select((.command // "") | endswith("zellaude-hook.sh") | not))
      ) | .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$CURSOR_HOOKS" > "$tmp"
  mv "$tmp" "$CURSOR_HOOKS"
  echo "Uninstalled zellaude hooks from $CURSOR_HOOKS"
}

uninstall_codex() {
  [ -f "$CODEX_HOOKS" ] || return 0
  backup "$CODEX_HOOKS"
  local tmp
  tmp=$(mktemp)
  jq '
    if .hooks and (.hooks | type == "object") then
      .hooks |= with_entries(
        .value |= [
          .[] | . as $group |
          ($group.hooks // []) | map(select((.command // "") | test("zellaude-hook\\.sh\\s+codex\\s*$") | not)) |
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

install_claude() {
  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    echo '{}' > "$CLAUDE_SETTINGS"
  fi
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

case "${1:-}" in
  --uninstall)
    uninstall_claude
    uninstall_cursor
    uninstall_codex
    ;;
  *)
    install_claude
    install_cursor
    install_codex
    echo "Hook script: $HOOK_SCRIPT"
    ;;
esac

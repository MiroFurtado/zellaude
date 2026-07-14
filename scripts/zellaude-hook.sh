#!/usr/bin/env bash
# zellaude-hook.sh — Claude Code / cursor-agent / Codex CLI / GitHub Copilot CLI
# hook → zellij pipe bridge. Forwards hook events to the zellaude Zellij plugin.
#
# Usage in ~/.claude/settings.json hooks:
#   "command": "/path/to/zellaude-hook.sh claude"
# Usage in ~/.codex/hooks.json hooks:
#   "command": "/path/to/zellaude-hook.sh codex"
# Usage in ~/.copilot/hooks/*.json hooks (Copilot omits the event name from the
# stdin payload, so it is passed as a second argument matching the config key):
#   "bash": "/path/to/zellaude-hook.sh copilot preToolUse"

# Agent type (claude|cursor|codex|copilot); empty preserves legacy detection.
AGENT_ARG="${1:-}"
# Event name, supplied by callers whose payload omits it (Copilot). Empty
# otherwise; the event is then read from the stdin JSON.
EVENT_ARG="${2:-}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zellaude"
LOG_FILE="$LOG_DIR/hooks.log"
LOG_MAX_BYTES=$((1024 * 1024))

log_event() {
  mkdir -p -m 700 "$LOG_DIR" 2>/dev/null || return
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null)" -ge "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || return
  fi
  printf '%s agent=%s event=%s session=%s pane=%s tool=%s status=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${AGENT:-${AGENT_ARG:-unknown}}" \
    "${HOOK_EVENT:-${EVENT_ARG:-unknown}}" \
    "${ZELLIJ_SESSION_NAME:-missing}" \
    "${ZELLIJ_PANE_ID:-missing}" \
    "${TOOL_NAME:--}" \
    "$1" >> "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

run_pipe() {
  "$@" >/dev/null 2>&1 &
  local pipe_pid=$!
  (
    sleep 2
    kill "$pipe_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  wait "$pipe_pid"
  local status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

if [ -z "$ZELLIJ_SESSION_NAME" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
  log_event "ignored_missing_zellij_env"
  exit 0
fi

# Capture send-time immediately so the plugin can order events
# that race through parallel hook subprocesses.
TS_MS=$(jq -nc 'now * 1000 | floor')

# Read hook JSON from stdin
INPUT=$(cat)

# Extract fields with jq (required dependency). Field names differ per agent:
#   Claude/Codex use snake_case (session_id, tool_name); cursor-agent uses
#   conversation_id; Copilot command hooks use camelCase (sessionId, toolName)
#   and omit the event name entirely. Fall back across all spellings.
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="$EVENT_ARG"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .conversation_id // .sessionId // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // .workingDirectory // empty')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // .notificationType // empty')

# Identify which agent fired this hook so the plugin can later snapshot the
# right resume command. cursor-agent's payload always includes cursor_version.
if [ -n "$AGENT_ARG" ]; then
  AGENT="$AGENT_ARG"
else
  AGENT=$(echo "$INPUT" | jq -r 'if has("cursor_version") then "cursor" else "claude" end')
fi

[ -z "$HOOK_EVENT" ] && exit 0

# Normalize cursor-agent / Copilot events (camelCase) to the internal PascalCase
# names the plugin already understands. Claude events pass through unchanged.
case "$HOOK_EVENT" in
  sessionStart)        HOOK_EVENT="SessionStart" ;;
  sessionEnd)          HOOK_EVENT="SessionEnd" ;;
  preToolUse)          HOOK_EVENT="PreToolUse" ;;
  postToolUse)         HOOK_EVENT="PostToolUse" ;;
  postToolUseFailure)  HOOK_EVENT="PostToolUseFailure" ;;
  beforeSubmitPrompt)  HOOK_EVENT="UserPromptSubmit" ;;
  userPromptSubmit)    HOOK_EVENT="UserPromptSubmit" ;;
  userPromptSubmitted) HOOK_EVENT="UserPromptSubmit" ;;
  permissionRequest)
    if [ "$AGENT" = "copilot" ]; then
      # Copilot fires this before auto-allow/rules processing, not only when
      # displaying a prompt. Real prompts arrive as notification events.
      log_event "ignored_pre_permission_service"
      exit 0
    fi
    HOOK_EVENT="PermissionRequest"
    ;;
  notification)
    case "$AGENT:$NOTIFICATION_TYPE" in
      copilot:permission_prompt|copilot:elicitation_dialog)
        HOOK_EVENT="PermissionRequest"
        ;;
      *)
        HOOK_EVENT="Notification"
        ;;
    esac
    ;;
  stop)                HOOK_EVENT="Stop" ;;
  agentStop)           HOOK_EVENT="Stop" ;;
  subagentStop)        HOOK_EVENT="SubagentStop" ;;
esac

log_event "received"

# Build compact JSON payload
PAYLOAD=$(jq -nc \
  --arg pane_id "$ZELLIJ_PANE_ID" \
  --arg session_id "$SESSION_ID" \
  --arg hook_event "$HOOK_EVENT" \
  --arg tool_name "$TOOL_NAME" \
  --arg cwd "$CWD" \
  --arg zellij_session "$ZELLIJ_SESSION_NAME" \
  --arg term_program "${TERM_PROGRAM:-}" \
  --arg ts_ms "$TS_MS" \
  --arg agent "$AGENT" \
  '{
    pane_id: ($pane_id | tonumber),
    session_id: $session_id,
    hook_event: $hook_event,
    tool_name: (if $tool_name == "" then null else $tool_name end),
    cwd: (if $cwd == "" then null else $cwd end),
    zellij_session: $zellij_session,
    term_program: (if $term_program == "" then null else $term_program end),
    ts_ms: ($ts_ms | tonumber),
    agent: $agent
  }')

# Permission request: bell + desktop notification
if [ "$HOOK_EVENT" = "PermissionRequest" ]; then
  printf '\a' 2>/dev/null > /dev/tty || true

  # Read notification setting (default: Always)
  SETTINGS_FILE="$HOME/.config/zellij/plugins/zellaude.json"
  NOTIFY_MODE="Always"
  if [ -f "$SETTINGS_FILE" ]; then
    NOTIFY_MODE=$(jq -r '.notifications // "Always"' "$SETTINGS_FILE" 2>/dev/null)
  fi

  # For "Unfocused" mode, check if the terminal app is frontmost
  SHOULD_NOTIFY=false
  case "$NOTIFY_MODE" in
    Always) SHOULD_NOTIFY=true ;;
    Unfocused)
      TERM_FOCUSED=false
      case "$(uname)" in
        Darwin)
          # Map TERM_PROGRAM to macOS process name
          EXPECTED="${TERM_PROGRAM:-}"
          case "$EXPECTED" in
            Apple_Terminal) EXPECTED="Terminal" ;;
            iTerm.app)     EXPECTED="iTerm2" ;;
          esac
          FRONT_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
          [ "$FRONT_APP" = "$EXPECTED" ] && TERM_FOCUSED=true
          ;;
        Linux)
          # X11: check if focused window belongs to our terminal
          if command -v xdotool >/dev/null 2>&1; then
            ACTIVE_PID=$(xdotool getactivewindow getwindowpid 2>/dev/null)
            if [ -n "$ACTIVE_PID" ]; then
              # Walk up the process tree from our shell to see if the
              # focused window's process is an ancestor (i.e. our terminal)
              PID=$$
              while [ "$PID" -gt 1 ] 2>/dev/null; do
                [ "$PID" = "$ACTIVE_PID" ] && { TERM_FOCUSED=true; break; }
                PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
              done
            fi
          fi
          # Wayland: no standard way to check; fall through to not-focused
          ;;
      esac
      [ "$TERM_FOCUSED" = false ] && SHOULD_NOTIFY=true
      ;;
  esac

  if [ "$SHOULD_NOTIFY" = true ]; then
    TOOL_SUFFIX=""
    [ -n "$TOOL_NAME" ] && TOOL_SUFFIX=" — $TOOL_NAME"
    case "$AGENT" in
      codex)   TITLE="⚠ Codex CLI" ;;
      cursor)  TITLE="⚠ Cursor Agent" ;;
      copilot) TITLE="⚠ GitHub Copilot" ;;
      *)       TITLE="⚠ Claude Code" ;;
    esac
    MESSAGE="Permission requested${TOOL_SUFFIX}"

    # Rate-limit: one notification per pane per 10 seconds
    LOCK="/tmp/zellaude-notify-${ZELLIJ_PANE_ID}"
    NOW=$(date +%s)
    LAST=0
    [ -f "$LOCK" ] && LAST=$(cat "$LOCK" 2>/dev/null)
    if [ $((NOW - LAST)) -ge 10 ]; then
      echo "$NOW" > "$LOCK"

      # Click callback: activate terminal + focus the pane
      ZELLIJ_BIN=$(command -v zellij)
      FOCUS_CMD="${ZELLIJ_BIN} -s '${ZELLIJ_SESSION_NAME}' pipe --name zellaude:focus -- ${ZELLIJ_PANE_ID}"

      case "$(uname)" in
        Darwin)
          [ -n "${TERM_PROGRAM:-}" ] && FOCUS_CMD="open -a '${TERM_PROGRAM}' && ${FOCUS_CMD}"
          if command -v terminal-notifier >/dev/null 2>&1; then
            terminal-notifier \
              -title "$TITLE" \
              -message "$MESSAGE" \
              -execute "$FOCUS_CMD" &
          else
            osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" &
          fi
          ;;
        Linux)
          if command -v notify-send >/dev/null 2>&1; then
            notify-send "$TITLE" "$MESSAGE" &
          fi
          ;;
      esac
    fi
  fi
fi

# Send to plugin. Discard stdout/stderr because cursor-agent/Codex read stdout
# as the hook's JSON response and would error on non-JSON output. Try the
# PATH zellij first, then /usr/bin/zellij for sessions still running an older
# distro-packaged server after a user-local zellij upgrade.
DELIVERED=false
ZELLIJ_BIN=$(command -v zellij 2>/dev/null || true)
if [ -n "$ZELLIJ_BIN" ] &&
  run_pipe "$ZELLIJ_BIN" pipe --name "zellaude" -- "$PAYLOAD"; then
  DELIVERED=true
elif [ -x /usr/bin/zellij ] && [ "$ZELLIJ_BIN" != "/usr/bin/zellij" ] &&
  run_pipe /usr/bin/zellij pipe --name "zellaude" -- "$PAYLOAD"; then
  DELIVERED=true
fi

if [ "$DELIVERED" = true ]; then
  log_event "delivered"
else
  log_event "delivery_failed"
fi
exit 0

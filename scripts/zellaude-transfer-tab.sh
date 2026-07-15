#!/usr/bin/env bash
# zellaude-transfer-tab.sh — Open a new tab in the current zellij session that
# resumes a Claude/Cursor/Codex/Copilot session from another Zellij session's
# snapshot.
#
# Reads zellaude's persisted state and uses `zellij action new-tab --layout`
# to spawn a tab with the right resume command in the right cwd.
#
# Usage:
#   zellaude-transfer-tab.sh                                  # list sessions
#   zellaude-transfer-tab.sh <source-session>                 # list tabs
#   zellaude-transfer-tab.sh <source-session> <selector>      # transfer it
#
# selector accepts an exact session ID, exact tab name, or tab-name regex.
# Selecting a tab transfers all captured agent panes in that tab.

set -euo pipefail

STATE_DIR="$HOME/.config/zellij/plugins/zellaude-state"

if [ ! -d "$STATE_DIR" ]; then
  echo "No zellaude state directory at $STATE_DIR" >&2
  exit 1
fi

# No args → list sessions
if [ $# -lt 1 ]; then
  echo "Sessions with persisted state:"
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    count=$(jq 'length' "$f" 2>/dev/null || echo 0)
    echo "  $name  ($count tab(s))"
  done
  echo ""
  echo "Usage: $0 <source-session> [<tab-name-or-session-id>]"
  exit 0
fi

SESSION="$1"
TAB_NAME="${2:-}"

STATE_FILE="$STATE_DIR/$SESSION.json"
# Fall back to the high-water-mark backup if the live file got pruned
if [ -f "$STATE_FILE.bak" ]; then
  LIVE_COUNT=$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)
  BAK_COUNT=$(jq 'length' "$STATE_FILE.bak" 2>/dev/null || echo 0)
  if [ "$BAK_COUNT" -gt "$LIVE_COUNT" ]; then
    STATE_FILE="$STATE_FILE.bak"
  fi
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file for session '$SESSION' under $STATE_DIR" >&2
  exit 1
fi

# No tab name → list tabs in the chosen session
if [ -z "$TAB_NAME" ]; then
  echo "Tabs in $SESSION (from $(basename "$STATE_FILE")):"
  jq -r '
    to_entries
    | sort_by(.value.tab_index // 999)
    | .[]
    | "  \(.value.tab_name // "?")  -- agent: \(.value.agent // "claude"), cwd: \(.value.cwd // "?"), sid: \(.value.session_id // "?")"
  ' "$STATE_FILE"
  exit 0
fi

# Find matching entries. Prefer an exact session ID. Exact tab names select all
# panes at that tab index; regexes must resolve to one tab.
MATCHES=$(jq -c --arg selector "$TAB_NAME" '
  [.[] | select(.session_id == $selector)] as $sid
  | [.[] | select(.tab_name == $selector)] as $exact
  | if ($sid | length) > 0 then $sid
    elif ($exact | length) > 0 then $exact
    else
      [.[] | select((.tab_name // "") | try test($selector) catch false)]
    end
' "$STATE_FILE")

MATCH_COUNT=$(echo "$MATCHES" | jq 'length')
if [ "$MATCH_COUNT" -eq 0 ]; then
  echo "No tab matching '$TAB_NAME' in $SESSION" >&2
  exit 1
fi

TAB_COUNT=$(echo "$MATCHES" | jq '[.[] | [.tab_index, .tab_name]] | unique | length')
if [ "$TAB_COUNT" -gt 1 ]; then
  echo "Ambiguous tab selector '$TAB_NAME' in $SESSION; use an exact tab name or session ID:" >&2
  echo "$MATCHES" | jq -r '
    .[]
    | "  \(.tab_name // "?")  -- agent: \(.agent // "claude"), cwd: \(.cwd // "?"), sid: \(.session_id // "?")"
  ' >&2
  exit 1
fi

# Escape " and \ for kdl string literals.
kdl_escape() { printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g'; }

NAME=$(echo "$MATCHES" | jq -r '.[0].tab_name // ""')
NAME_E=$(kdl_escape "$NAME")

LAYOUT=$(mktemp /tmp/zellaude-transfer-XXXXXX.kdl)
trap 'rm -f "$LAYOUT"' EXIT

{
  cat <<EOF
layout {
    tab name="$NAME_E" {
        pane size=1 borderless=true {
            plugin location="file:~/.config/zellij/plugins/zellaude.wasm"
        }
EOF

  if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "        pane stacked=true {"
  fi

  while IFS= read -r ENTRY; do
    CWD=$(echo "$ENTRY"  | jq -r '.cwd // empty')
    SID=$(echo "$ENTRY"  | jq -r '.session_id // empty')
    AGENT=$(echo "$ENTRY" | jq -r '.agent // "claude"')

    if [ -z "$SID" ]; then
      echo "Tab '$NAME' has a pane with no session_id — refusing to transfer" >&2
      exit 1
    fi

    # Claude binds session_id to the directory it was originally invoked in.
    if [ "$AGENT" = "claude" ]; then
      TRANSCRIPT=$(find "$HOME/.claude/projects" -name "$SID.jsonl" 2>/dev/null | head -1)
      if [ -n "$TRANSCRIPT" ]; then
        ENCODED=$(basename "$(dirname "$TRANSCRIPT")")
        DECODED=$(echo "$ENCODED" | sed -e 's|--|/.|g' -e 's|-|/|g')
        if [ -d "$DECODED" ]; then
          CWD="$DECODED"
        fi
      fi
    fi

    if [ -z "$CWD" ]; then
      echo "Tab '$NAME' has a pane with no cwd captured — refusing to transfer" >&2
      exit 1
    fi

    case "$AGENT" in
      claude) BIN="claude" ;;
      cursor) BIN="cursor-agent" ;;
      codex) BIN="codex" ;;
      copilot) BIN="copilot" ;;
      *)
        echo "Tab '$NAME' uses unsupported agent '$AGENT'" >&2
        exit 1
        ;;
    esac

    CWD_E=$(kdl_escape "$CWD")
    SID_E=$(kdl_escape "$SID")
    if [ "$AGENT" = "codex" ]; then
      INNER="$BIN resume $SID_E; exec bash"
    else
      INNER="$BIN --resume $SID_E; exec bash"
    fi
    INNER_E=$(kdl_escape "$INNER")

    cat <<EOF
            pane command="bash" cwd="$CWD_E" {
                args "-ic" "$INNER_E"
            }
EOF
  done < <(echo "$MATCHES" | jq -c '.[]')

  if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "        }"
  fi

  cat <<EOF
    }
}
EOF
} > "$LAYOUT"

zellij action new-tab --layout "$LAYOUT"
echo "Transferred '$NAME' from $SESSION → current session"
echo "  panes: $MATCH_COUNT"
echo "$MATCHES" | jq -r '.[] | "  \(.agent // "claude"): \(.session_id // "?") (\(.cwd // "?"))"'

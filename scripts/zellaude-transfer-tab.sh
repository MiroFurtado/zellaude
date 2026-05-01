#!/usr/bin/env bash
# zellaude-transfer-tab.sh — Open a new tab in the current zellij session that
# resumes a claude/cursor-agent session from another zellij session's snapshot.
#
# Reads zellaude's persisted state and uses `zellij action new-tab --layout`
# to spawn a tab with the right resume command in the right cwd.
#
# Usage:
#   zellaude-transfer-tab.sh                                  # list sessions
#   zellaude-transfer-tab.sh <source-session>                 # list tabs
#   zellaude-transfer-tab.sh <source-session> <tab-name>      # transfer it
#
# tab-name accepts a substring/regex match; the first matching tab wins.

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
  echo "Usage: $0 <source-session> [<tab-name>]"
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

# Find the entry. Prefer exact tab_name match; fall back to regex/substring.
ENTRY=$(jq -c --arg name "$TAB_NAME" '
  [.[] | select(.tab_name == $name)] as $exact
  | if ($exact | length) > 0 then $exact[0]
    else
      [.[] | select((.tab_name // "") | test($name))] as $fuzzy
      | if ($fuzzy | length) > 0 then $fuzzy[0] else empty end
    end
' "$STATE_FILE")

if [ -z "$ENTRY" ]; then
  echo "No tab matching '$TAB_NAME' in $SESSION" >&2
  exit 1
fi

CWD=$(echo "$ENTRY"  | jq -r '.cwd // empty')
SID=$(echo "$ENTRY"  | jq -r '.session_id // empty')
AGENT=$(echo "$ENTRY" | jq -r '.agent // "claude"')
NAME=$(echo "$ENTRY" | jq -r '.tab_name // ""')

if [ -z "$SID" ]; then
  echo "Tab '$NAME' has no session_id — nothing to resume" >&2
  exit 1
fi

# Claude binds session_id to the dir it was originally invoked in. If the
# captured cwd is a subdir of the original, --resume will say "no conversation
# found". Recover the true project dir from ~/.claude/projects/<encoded>/.
if [ "$AGENT" = "claude" ]; then
  TRANSCRIPT=$(find "$HOME/.claude/projects" -name "$SID.jsonl" 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ]; then
    ENCODED=$(basename "$(dirname "$TRANSCRIPT")")
    # Decode: claude encodes / and . both as -, but writes /. as -- (so the
    # decoder must do -- → /. before remaining - → /).
    DECODED=$(echo "$ENCODED" | sed -e 's|--|/.|g' -e 's|-|/|g')
    if [ -d "$DECODED" ]; then
      CWD="$DECODED"
    fi
  fi
fi

if [ -z "$CWD" ]; then
  echo "Tab '$NAME' has no cwd captured — refusing to spawn" >&2
  exit 1
fi

BIN="claude"
[ "$AGENT" = "cursor" ] && BIN="cursor-agent"

# Escape " and \ for kdl string literals.
kdl_escape() { printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g'; }
NAME_E=$(kdl_escape "$NAME")
CWD_E=$(kdl_escape "$CWD")
SID_E=$(kdl_escape "$SID")

LAYOUT=$(mktemp /tmp/zellaude-transfer-XXXXXX.kdl)
trap 'rm -f "$LAYOUT"' EXIT

# Wrap in `bash -ic` so the user's shell aliases (e.g. claude →
# `claude --dangerously-skip-permissions`) are honored. `exec bash` keeps the
# pane alive after the agent exits so you can restart it without rebuilding
# the tab.
INNER="$BIN --resume $SID_E; exec bash"
INNER_E=$(kdl_escape "$INNER")

cat > "$LAYOUT" <<EOF
layout {
    tab name="$NAME_E" {
        pane command="bash" cwd="$CWD_E" {
            args "-ic" "$INNER_E"
        }
    }
}
EOF

zellij action new-tab --layout "$LAYOUT"
echo "Transferred '$NAME' from $SESSION → current session"
echo "  agent: $AGENT"
echo "  cwd:   $CWD"
echo "  sid:   $SID"

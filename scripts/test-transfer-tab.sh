#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

STATE_DIR="$TMP_HOME/.config/zellij/plugins/zellaude-state"
mkdir -p "$STATE_DIR" "$TMP_HOME/bin" "$TMP_HOME/project-one" "$TMP_HOME/project-two"

SID_ONE="11111111-1111-1111-1111-111111111111"
SID_TWO="22222222-2222-2222-2222-222222222222"
cat > "$STATE_DIR/source.json" <<JSON
{
  "one": {
    "tab_name": "atm",
    "agent": "copilot",
    "cwd": "$TMP_HOME/project-one",
    "session_id": "$SID_ONE",
    "tab_index": 1
  },
  "two": {
    "tab_name": "atm",
    "agent": "copilot",
    "cwd": "$TMP_HOME/project-two",
    "session_id": "$SID_TWO",
    "tab_index": 1
  }
}
JSON

cat > "$TMP_HOME/bin/zellij" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "action" && "$2" == "new-tab" && "$3" == "--layout" ]]
cp "$4" "$ZELLIJ_TEST_LAYOUT"
SH
chmod +x "$TMP_HOME/bin/zellij"

HOME="$TMP_HOME" PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_TEST_LAYOUT="$TMP_HOME/layout.kdl" \
  "$ROOT/scripts/zellaude-transfer-tab.sh" source atm >/dev/null

grep -q 'tab name="atm"' "$TMP_HOME/layout.kdl"
grep -q 'pane size=1 borderless=true' "$TMP_HOME/layout.kdl"
grep -q 'plugin location="file:~/.config/zellij/plugins/zellaude.wasm"' "$TMP_HOME/layout.kdl"
grep -q 'pane stacked=true' "$TMP_HOME/layout.kdl"
grep -q "cwd=\"$TMP_HOME/project-one\"" "$TMP_HOME/layout.kdl"
grep -q "cwd=\"$TMP_HOME/project-two\"" "$TMP_HOME/layout.kdl"
grep -q "copilot --resume $SID_ONE; exec bash" "$TMP_HOME/layout.kdl"
grep -q "copilot --resume $SID_TWO; exec bash" "$TMP_HOME/layout.kdl"

HOME="$TMP_HOME" PATH="$TMP_HOME/bin:$PATH" \
  ZELLIJ_TEST_LAYOUT="$TMP_HOME/single-layout.kdl" \
  "$ROOT/scripts/zellaude-transfer-tab.sh" source "$SID_TWO" >/dev/null

! grep -q 'pane stacked=true' "$TMP_HOME/single-layout.kdl"
grep -q "copilot --resume $SID_TWO; exec bash" "$TMP_HOME/single-layout.kdl"

echo "transfer-tab tests passed"

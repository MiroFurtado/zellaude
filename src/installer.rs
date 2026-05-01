use std::collections::BTreeMap;
use zellij_tile::prelude::run_command;

const HOOK_VERSION_TAG: &str = concat!("# zellaude v", env!("CARGO_PKG_VERSION"));

/// Generate hook script content with version tag inserted after the shebang.
fn hook_script_content() -> String {
    let original = include_str!("../scripts/zellaude-hook.sh");
    // Insert version tag after the shebang line
    if let Some(pos) = original.find('\n') {
        let (shebang, rest) = original.split_at(pos);
        format!("{shebang}\n{HOOK_VERSION_TAG}{rest}")
    } else {
        original.to_string()
    }
}

const INSTALL_TEMPLATE: &str = r##"set -e
HOOK_PATH="$HOME/.config/zellij/plugins/zellaude-hook.sh"
SETTINGS="$HOME/.claude/settings.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"

# Check if already current (Claude + Cursor both registered)
if grep -qF '__VERSION_TAG__' "$HOOK_PATH" 2>/dev/null; then
  if [ -f "$SETTINGS" ] && grep -qF "$HOOK_PATH" "$SETTINGS" 2>/dev/null \
     && [ -f "$CURSOR_HOOKS" ] && grep -qF "$HOOK_PATH" "$CURSOR_HOOKS" 2>/dev/null; then
    echo "current"
    exit 0
  fi
fi

# Write hook script
mkdir -p "$(dirname "$HOOK_PATH")"
cat > "$HOOK_PATH" << 'ZELLAUDE_HOOK_EOF'
__HOOK_SCRIPT__
ZELLAUDE_HOOK_EOF
chmod +x "$HOOK_PATH"

# Register hooks (requires jq)
if ! command -v jq >/dev/null 2>&1; then
  echo "no_jq"
  exit 0
fi

# --- Claude Code: ~/.claude/settings.json ---
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$HOME/.claude"
  echo '{}' > "$SETTINGS"
fi

cp "$SETTINGS" "$SETTINGS.bak"

# Remove ALL existing zellaude hook entries (any path ending in zellaude-hook.sh)
tmp=$(mktemp)
jq '
  if .hooks and (.hooks | type == "object") then
    .hooks |= with_entries(
      .value |= [
        .[] | . as $group |
        ($group.hooks // []) | map(select((.command // "") | endswith("zellaude-hook.sh") | not)) |
        . as $filtered |
        if length > 0 then ($group | .hooks = $filtered) else empty end
      ]
    ) | .hooks |= with_entries(select(.value | length > 0)) |
    if .hooks == {} then del(.hooks) else . end
  else . end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

EVENTS='["PreToolUse","PostToolUse","PostToolUseFailure","UserPromptSubmit","PermissionRequest","Notification","Stop","SubagentStop","SessionStart","SessionEnd"]'
ENTRY=$(jq -nc --arg cmd "$HOOK_PATH" '[{"hooks": [{"type": "command", "command": $cmd, "timeout": 5, "async": true}]}]')
tmp=$(mktemp)
jq --argjson events "$EVENTS" --argjson entry "$ENTRY" '
  .hooks //= {} |
  reduce ($events[]) as $event (.; .hooks[$event] = (.hooks[$event] // []) + $entry)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# --- Cursor Agent: ~/.cursor/hooks.json ---
# Schema differs from Claude: { "version": 1, "hooks": { "<event>": [{"command": "..."}] } }
if [ ! -f "$CURSOR_HOOKS" ]; then
  mkdir -p "$HOME/.cursor"
  echo '{"version":1}' > "$CURSOR_HOOKS"
fi

cp "$CURSOR_HOOKS" "$CURSOR_HOOKS.bak"

# Strip existing zellaude entries
tmp=$(mktemp)
jq '
  if .hooks and (.hooks | type == "object") then
    .hooks |= with_entries(
      .value |= map(select((.command // "") | endswith("zellaude-hook.sh") | not))
    ) | .hooks |= with_entries(select(.value | length > 0)) |
    if .hooks == {} then del(.hooks) else . end
  else . end
' "$CURSOR_HOOKS" > "$tmp" && mv "$tmp" "$CURSOR_HOOKS"

CURSOR_EVENTS='["sessionStart","sessionEnd","preToolUse","postToolUse","postToolUseFailure","beforeSubmitPrompt","stop","subagentStop"]'
CURSOR_ENTRY=$(jq -nc --arg cmd "$HOOK_PATH" '[{"command": $cmd, "timeout": 5}]')
tmp=$(mktemp)
jq --argjson events "$CURSOR_EVENTS" --argjson entry "$CURSOR_ENTRY" '
  .version //= 1 |
  .hooks //= {} |
  reduce ($events[]) as $event (.; .hooks[$event] = (.hooks[$event] // []) + $entry)
' "$CURSOR_HOOKS" > "$tmp" && mv "$tmp" "$CURSOR_HOOKS"

echo "installed"
"##;

/// Run the idempotent hook installation command.
/// Checks if hooks are current, writes the hook script, and registers hooks.
pub fn run_install() {
    let cmd = INSTALL_TEMPLATE
        .replace("__VERSION_TAG__", HOOK_VERSION_TAG)
        .replace("__HOOK_SCRIPT__", &hook_script_content());

    let mut ctx = BTreeMap::new();
    ctx.insert("type".into(), "install_hooks".into());
    run_command(&["sh", "-c", &cmd], ctx);
}

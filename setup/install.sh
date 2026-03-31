#!/usr/bin/env bash
# Install global Claude Code config (~/.claude/).
# Run once after cloning. Safe to re-run — overwrites global settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing global Claude Code config..."

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install it first (brew install jq / apt install jq)."
  exit 1
fi

# Create directories
mkdir -p ~/.claude/scripts

# Copy global guard script
cp "$SCRIPT_DIR/guard-secrets-global.sh" ~/.claude/scripts/guard-secrets-global.sh
chmod +x ~/.claude/scripts/guard-secrets-global.sh
echo "  Copied guard-secrets-global.sh → ~/.claude/scripts/"

# Build the new settings fragment with correct home directory
HOME_DIR="$HOME"
NEW_SETTINGS=$(jq --arg home "$HOME_DIR" '
  del(._comment) |
  .permissions.deny = (.permissions.deny | map(gsub("/home/user"; $home))) |
  .hooks.PreToolUse[0].hooks[0].command = ($home + "/.claude/scripts/guard-secrets-global.sh")
' "$SCRIPT_DIR/settings.json")

# Merge into existing settings.json (or create if missing)
if [ -f ~/.claude/settings.json ]; then
  # Deep merge: existing settings take priority for scalar values,
  # but permissions.deny and hooks.PreToolUse are replaced from template
  jq -s '
    .[0] as $existing |
    .[1] as $new |
    $existing * {
      permissions: { deny: $new.permissions.deny },
      hooks: { PreToolUse: $new.hooks.PreToolUse }
    }
  ' ~/.claude/settings.json <(echo "$NEW_SETTINGS") > ~/.claude/settings.json.tmp \
    && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
  echo "  Merged security settings into existing ~/.claude/settings.json"
else
  echo "$NEW_SETTINGS" > ~/.claude/settings.json
  echo "  Created ~/.claude/settings.json"
fi

echo ""
echo "Done. Review ~/.claude/settings.json — it affects ALL Claude Code sessions."
echo "Next: run ./setup/configure.sh to set up project paths."

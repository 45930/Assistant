#!/usr/bin/env bash
# Install global Claude Code config (~/.claude/).
# Run once after cloning. Safe to re-run — overwrites global settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing global Claude Code config..."

# Create directories
mkdir -p ~/.claude/scripts

# Copy global guard script
cp "$SCRIPT_DIR/guard-secrets-global.sh" ~/.claude/scripts/guard-secrets-global.sh
chmod +x ~/.claude/scripts/guard-secrets-global.sh
echo "  Copied guard-secrets-global.sh → ~/.claude/scripts/"

# Generate global settings.json with correct home directory
HOME_DIR="$HOME"
sed "s|/home/user|$HOME_DIR|g" "$SCRIPT_DIR/settings.json" > ~/.claude/settings.json
echo "  Generated settings.json → ~/.claude/settings.json (home=$HOME_DIR)"

# Remove the _comment field (it was just for the template)
if command -v jq &>/dev/null; then
  jq 'del(._comment)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
    && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
fi

echo ""
echo "Done. Review ~/.claude/settings.json — it affects ALL Claude Code sessions."
echo "Next: run ./setup/configure.sh to set up project paths."

#!/usr/bin/env bash
# Configure project paths after cloning.
# Usage: ./setup/configure.sh [REPO_DIR] [PROJECTS_DIR]
#
# REPO_DIR defaults to the parent of this script's directory.
# PROJECTS_DIR defaults to ~/projects.
#
# Copies templates from setup/templates/claude/ into .claude/,
# then substitutes all paths. Safe to re-run — overwrites .claude/ each time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-$(dirname "$SCRIPT_DIR")}"
PROJECTS_DIR="${2:-$HOME/projects}"

# Resolve to absolute paths
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
PROJECTS_DIR="$(mkdir -p "$PROJECTS_DIR" && cd "$PROJECTS_DIR" && pwd)"

# Derive the memory directory path (Claude Code convention: absolute path with / → -)
MEMORY_PATH="$REPO_DIR"
MEMORY_PATH="${MEMORY_PATH#/}"          # strip leading /
MEMORY_PATH="${MEMORY_PATH//\//-}"      # replace / with -
MEMORY_DIR="$HOME/.claude/projects/-${MEMORY_PATH}/memory"

TEMPLATES="$SCRIPT_DIR/templates/claude"

# Portable sed -i (macOS requires '' arg, Linux does not)
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

echo "Configuring project paths..."
echo "  REPO:     $REPO_DIR"
echo "  PROJECTS: $PROJECTS_DIR"
echo "  MEMORY:   $MEMORY_DIR"
echo ""

# ============================================================
# Copy templates into .claude/
# ============================================================
if [ ! -d "$TEMPLATES" ]; then
  echo "ERROR: Templates not found at $TEMPLATES"
  exit 1
fi

echo "Copying templates to .claude/..."
mkdir -p "$REPO_DIR/.claude"
cp -r "$TEMPLATES"/* "$REPO_DIR/.claude/"
echo "  Copied: setup/templates/claude/ → .claude/"

# ============================================================
# .claude/settings.local.json — substitute paths via jq
# ============================================================
SETTINGS="$REPO_DIR/.claude/settings.local.json"
if [ -f "$SETTINGS" ]; then
  jq --arg repo "$REPO_DIR" \
     --arg projects "$PROJECTS_DIR" \
     --arg memory "$MEMORY_DIR" \
  '
    .permissions.additionalDirectories = [$projects, $memory] |
    .sandbox.filesystem.allowWrite = [$projects, $memory] |
    .hooks.PreToolUse[0].hooks[0].command = ($repo + "/.claude/scripts/guard-secrets.sh") |
    .hooks.PreToolUse[1].hooks[0].command = ($repo + "/.claude/scripts/guard-memory-injection.sh")
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  Patched: .claude/settings.local.json"
fi

# ============================================================
# .claude/scripts/guard-secrets.sh — ALLOWED_PREFIXES + relative path
# ============================================================
GUARD="$REPO_DIR/.claude/scripts/guard-secrets.sh"
if [ -f "$GUARD" ]; then
  sedi \
    -e 's|{{REPO_DIR}}|'"$REPO_DIR"'|g' \
    -e 's|{{PROJECTS_DIR}}|'"$PROJECTS_DIR"'|g' \
    -e 's|{{HOME}}|'"$HOME"'|g' \
    "$GUARD"
  echo "  Patched: .claude/scripts/guard-secrets.sh"
fi

# ============================================================
# .claude/scripts/guard-memory-injection.sh — MEMORY_DIR
# ============================================================
MEMORY_GUARD="$REPO_DIR/.claude/scripts/guard-memory-injection.sh"
if [ -f "$MEMORY_GUARD" ]; then
  sedi 's|{{MEMORY_DIR}}|'"$MEMORY_DIR"'|g' "$MEMORY_GUARD"
  echo "  Patched: .claude/scripts/guard-memory-injection.sh"
fi

# ============================================================
# Job runner uses relative path resolution — no patching needed.
# validate-quarantine.sh also uses relative paths.
# ============================================================

# ============================================================
# Create memory directory if it doesn't exist
# ============================================================
mkdir -p "$MEMORY_DIR/people" "$MEMORY_DIR/projects"
if [ ! -f "$MEMORY_DIR/MEMORY.md" ]; then
  echo "# Memory Index" > "$MEMORY_DIR/MEMORY.md"
  echo "  Created: $MEMORY_DIR/MEMORY.md"
fi

echo ""
echo "Done. All paths configured."
echo ""
echo "Next steps:"
echo "  1. Create .env and .mcp.json (see README)"
echo "  2. Run: gws auth login"
echo "  3. Run: cd jobs/slack-pull/scripts && npm install"
echo "  4. Run: jobs/_runner/run-job.sh --build-base"
echo "  5. Run: ./setup/init-state.sh"

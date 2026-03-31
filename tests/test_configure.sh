#!/usr/bin/env bash
# Tests for setup/configure.sh
# Verifies: template copying, path substitution, memory directory creation.

source "$(dirname "$0")/test_helpers.sh"

# ── Setup: create a fake repo structure in tmp ──────────────

FAKE_REPO="$TEST_TMPDIR/my-repo"
FAKE_PROJECTS="$TEST_TMPDIR/my-projects"

# Copy real repo structure needed for configure.sh
mkdir -p "$FAKE_REPO/setup"
cp -r "$REPO_DIR/setup/templates" "$FAKE_REPO/setup/"
cp "$REPO_DIR/setup/configure.sh" "$FAKE_REPO/setup/"

echo "  Testing configure.sh..."

# ── Run configure.sh ────────────────────────────────────────

OUTPUT=$(bash "$FAKE_REPO/setup/configure.sh" "$FAKE_REPO" "$FAKE_PROJECTS" 2>&1)

# ── Test: .claude/ directory was created ────────────────────

assert_file_exists ".claude/ directory created" "$FAKE_REPO/.claude"
assert_file_exists "scripts/ copied" "$FAKE_REPO/.claude/scripts/guard-secrets.sh"
assert_file_exists "guard-memory-injection copied" "$FAKE_REPO/.claude/scripts/guard-memory-injection.sh"
assert_file_exists "settings.local.json copied" "$FAKE_REPO/.claude/settings.local.json"

# ── Test: skills were copied ────────────────────────────────

assert_file_exists "morning-briefing skill copied" "$FAKE_REPO/.claude/skills/morning-briefing/SKILL.md"
assert_file_exists "email-calendar skill copied" "$FAKE_REPO/.claude/skills/email-calendar/SKILL.md"
assert_file_exists "crontab-manager skill copied" "$FAKE_REPO/.claude/skills/crontab-manager/SKILL.md"

# ── Test: guard-secrets.sh has real paths, not placeholders ─

GUARD="$FAKE_REPO/.claude/scripts/guard-secrets.sh"
assert_file_contains "guard-secrets has REPO_DIR" "$GUARD" "$FAKE_REPO/"
assert_file_contains "guard-secrets has PROJECTS_DIR" "$GUARD" "$FAKE_PROJECTS/"
assert_file_contains "guard-secrets has HOME" "$GUARD" "$HOME/.claude/"
assert_file_not_contains "guard-secrets: no {{REPO_DIR}} placeholder" "$GUARD" "{{REPO_DIR}}"
assert_file_not_contains "guard-secrets: no {{PROJECTS_DIR}} placeholder" "$GUARD" "{{PROJECTS_DIR}}"
assert_file_not_contains "guard-secrets: no {{HOME}} placeholder" "$GUARD" "{{HOME}}"

# ── Test: guard-memory-injection.sh has real memory path ────

MEM_GUARD="$FAKE_REPO/.claude/scripts/guard-memory-injection.sh"
# Compute expected memory dir the same way configure.sh does
SAFE_PATH="${FAKE_REPO#/}"
SAFE_PATH="${SAFE_PATH//\//-}"
EXPECTED_MEMORY="$HOME/.claude/projects/-${SAFE_PATH}/memory"

assert_file_contains "memory guard has real path" "$MEM_GUARD" "$EXPECTED_MEMORY"
assert_file_not_contains "memory guard: no {{MEMORY_DIR}} placeholder" "$MEM_GUARD" "{{MEMORY_DIR}}"

# ── Test: settings.local.json has real paths ────────────────

SETTINGS="$FAKE_REPO/.claude/settings.local.json"
# Parse with jq
ADDITIONAL_DIRS=$(jq -r '.permissions.additionalDirectories[0]' "$SETTINGS")
assert_eq "settings: additionalDirectories[0] is projects dir" "$FAKE_PROJECTS" "$ADDITIONAL_DIRS"

HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SETTINGS")
assert_eq "settings: guard-secrets hook path" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "$HOOK_CMD"

HOOK2_CMD=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$SETTINGS")
assert_eq "settings: guard-memory-injection hook path" "$FAKE_REPO/.claude/scripts/guard-memory-injection.sh" "$HOOK2_CMD"

# ── Test: memory directory was created ──────────────────────

assert_file_exists "memory directory created" "$EXPECTED_MEMORY"
assert_file_exists "memory/people created" "$EXPECTED_MEMORY/people"
assert_file_exists "memory/projects created" "$EXPECTED_MEMORY/projects"
assert_file_exists "MEMORY.md initialized" "$EXPECTED_MEMORY/MEMORY.md"
assert_file_contains "MEMORY.md has header" "$EXPECTED_MEMORY/MEMORY.md" "# Memory Index"

# ── Test: re-running is safe ────────────────────────────────

OUTPUT2=$(bash "$FAKE_REPO/setup/configure.sh" "$FAKE_REPO" "$FAKE_PROJECTS" 2>&1)
assert_file_exists "re-run: .claude/ still exists" "$FAKE_REPO/.claude/scripts/guard-secrets.sh"
assert_file_contains "re-run: paths still correct" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "$FAKE_REPO/"

# Cleanup memory dir
rm -rf "$EXPECTED_MEMORY"

finish

#!/usr/bin/env bash
# Tests for setup/setup.sh
# Verifies: full interactive setup flow — global config, project config,
# CLAUDE.md, org.yaml, .env stub, context dirs, memory directory.
# Uses scripted stdin to simulate user input.

source "$(dirname "$0")/test_helpers.sh"

# ── Setup: fake repo, fake HOME, fake projects dir ───────────

FAKE_REPO="$TEST_TMPDIR/setup-test"
FAKE_HOME="$TEST_TMPDIR/fakehome"
FAKE_PROJECTS="$TEST_TMPDIR/my-projects"

mkdir -p "$FAKE_HOME"
mkdir -p "$FAKE_PROJECTS"
mkdir -p "$FAKE_REPO/setup" "$FAKE_REPO/jobs"

# Copy files setup.sh needs
cp -r "$REPO_DIR/setup/templates" "$FAKE_REPO/setup/"
cp "$REPO_DIR/setup/setup.sh" "$FAKE_REPO/setup/"
cp "$REPO_DIR/setup/settings.json" "$FAKE_REPO/setup/"
cp "$REPO_DIR/setup/guard-secrets-global.sh" "$FAKE_REPO/setup/"
cp "$REPO_DIR/CLAUDE.md.template" "$FAKE_REPO/"

# Create a test job with state file
mkdir -p "$FAKE_REPO/jobs/test-job"
cat > "$FAKE_REPO/jobs/test-job/job.yaml" <<'YAML'
name: test-job
schedule: "0 * * * *"
state:
  - .last_run
YAML

# Ensure docker is in PATH (stub if missing — we decline the build prompt)
if ! command -v docker &>/dev/null; then
  mkdir -p "$TEST_TMPDIR/fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/fakebin/docker"
  chmod +x "$TEST_TMPDIR/fakebin/docker"
  export PATH="$TEST_TMPDIR/fakebin:$PATH"
fi

echo "  Testing setup.sh..."

# ── Build input: one line per read prompt ─────────────────────
# The number of confirm prompts for optional steps varies
# depending on whether gws is installed (adds one extra prompt).
# Extra trailing "n" lines are harmless — they go unconsumed.

INPUT_LINES="$FAKE_PROJECTS
Alice Testuser
Head of Engineering
Acme Corp
acme.com
America/Chicago
TASK_LIST_123
DO_TODAY_456
y
y
y
y
y
y
y
y
y
y
y
n
n
n"

OUTPUT=$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash setup/setup.sh <<< "$INPUT_LINES" 2>&1)

# ── Test: CLAUDE.md was generated ──────────────────────────────

assert_file_exists "CLAUDE.md created" "$FAKE_REPO/CLAUDE.md"
assert_file_contains "CLAUDE.md has user name" "$FAKE_REPO/CLAUDE.md" "Alice Testuser"
assert_file_contains "CLAUDE.md has role" "$FAKE_REPO/CLAUDE.md" "Head of Engineering"
assert_file_contains "CLAUDE.md has company" "$FAKE_REPO/CLAUDE.md" "Acme Corp"
assert_file_contains "CLAUDE.md has email domain" "$FAKE_REPO/CLAUDE.md" "acme.com"
assert_file_contains "CLAUDE.md has timezone" "$FAKE_REPO/CLAUDE.md" "America/Chicago"
assert_file_contains "CLAUDE.md has task list ID" "$FAKE_REPO/CLAUDE.md" "TASK_LIST_123"
assert_file_contains "CLAUDE.md has do-today list ID" "$FAKE_REPO/CLAUDE.md" "DO_TODAY_456"

# Verify no unsubstituted placeholders remain
assert_file_not_contains "no {{USER_NAME}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{USER_NAME}}"
assert_file_not_contains "no {{COMPANY}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{COMPANY}}"
assert_file_not_contains "no {{EMAIL_DOMAIN}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{EMAIL_DOMAIN}}"
assert_file_not_contains "no {{TIMEZONE}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{TIMEZONE}}"
assert_file_not_contains "no {{TASKS_LIST_ID}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{TASKS_LIST_ID}}"

# ── Test: org.yaml was generated ───────────────────────────────

assert_file_exists "org.yaml created" "$FAKE_REPO/jobs/org.yaml"
assert_file_contains "org.yaml has company" "$FAKE_REPO/jobs/org.yaml" "company: Acme Corp"
assert_file_contains "org.yaml has email domain" "$FAKE_REPO/jobs/org.yaml" "email_domain: acme.com"
assert_file_contains "org.yaml has timezone" "$FAKE_REPO/jobs/org.yaml" "timezone: America/Chicago"

# ── Test: .env stub was created ────────────────────────────────

assert_file_exists ".env stub created" "$FAKE_REPO/.env"
assert_file_contains ".env has SLACK_USER_TOKEN" "$FAKE_REPO/.env" "SLACK_USER_TOKEN="
assert_file_contains ".env has ANTHROPIC_API_KEY" "$FAKE_REPO/.env" "ANTHROPIC_API_KEY="
assert_file_contains ".env has GITHUB_TOKEN" "$FAKE_REPO/.env" "GITHUB_TOKEN="

# ── Test: global config was written ────────────────────────────

assert_file_exists "global settings.json created" "$FAKE_HOME/.claude/settings.json"
assert_file_contains "global settings has HOME" "$FAKE_HOME/.claude/settings.json" "$FAKE_HOME"
assert_file_not_contains "global settings: no /home/user" "$FAKE_HOME/.claude/settings.json" "/home/user"

assert_file_exists "global guard script installed" "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh"

# Verify global settings structure
if command -v jq &>/dev/null; then
  DENY_COUNT=$(jq '.permissions.deny | length' "$FAKE_HOME/.claude/settings.json")
  if [ "$DENY_COUNT" -gt 10 ]; then
    echo "    ✓ global settings has $DENY_COUNT deny rules"
    ((ASSERT_PASS++))
  else
    echo "    ✗ global settings has only $DENY_COUNT deny rules (expected >10)"
    ((ASSERT_FAIL++))
  fi

  HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$FAKE_HOME/.claude/settings.json")
  assert_eq "global hook points to guard" "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh" "$HOOK_CMD"
fi

# ── Test: project config was written ───────────────────────────

assert_file_exists "project settings.local.json created" "$FAKE_REPO/.claude/settings.local.json"
assert_file_exists "project guard-secrets.sh created" "$FAKE_REPO/.claude/scripts/guard-secrets.sh"
assert_file_exists "project guard-memory-injection.sh created" "$FAKE_REPO/.claude/scripts/guard-memory-injection.sh"

# Verify paths were substituted
assert_file_contains "guard-secrets has REPO_DIR" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "$FAKE_REPO/"
assert_file_contains "guard-secrets has PROJECTS_DIR" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "$FAKE_PROJECTS/"
assert_file_not_contains "guard-secrets: no {{REPO_DIR}}" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "{{REPO_DIR}}"
assert_file_not_contains "guard-secrets: no {{PROJECTS_DIR}}" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "{{PROJECTS_DIR}}"

# Verify settings.local.json has correct hook paths
if command -v jq &>/dev/null; then
  PROJ_HOOK=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$FAKE_REPO/.claude/settings.local.json")
  assert_eq "project hook: guard-secrets path" "$FAKE_REPO/.claude/scripts/guard-secrets.sh" "$PROJ_HOOK"

  PROJ_HOOK2=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$FAKE_REPO/.claude/settings.local.json")
  assert_eq "project hook: memory-injection path" "$FAKE_REPO/.claude/scripts/guard-memory-injection.sh" "$PROJ_HOOK2"

  ADDITIONAL=$(jq -r '.permissions.additionalDirectories[0]' "$FAKE_REPO/.claude/settings.local.json")
  assert_eq "project settings: additionalDirectories" "$FAKE_PROJECTS" "$ADDITIONAL"
fi

# ── Test: skills were copied ───────────────────────────────────

assert_file_exists "skills directory created" "$FAKE_REPO/.claude/skills"
assert_file_exists "morning-briefing skill" "$FAKE_REPO/.claude/skills/morning-briefing/SKILL.md"
assert_file_exists "email-calendar skill" "$FAKE_REPO/.claude/skills/email-calendar/SKILL.md"

# ── Test: context directories were created ─────────────────────

assert_file_exists "context/ created" "$FAKE_REPO/context"
assert_file_exists "context/inbox/people created" "$FAKE_REPO/context/inbox/people"
assert_file_exists "context/inbox/projects created" "$FAKE_REPO/context/inbox/projects"
assert_file_exists "context/meeting_prep created" "$FAKE_REPO/context/meeting_prep"
assert_file_exists "context/quarantine created" "$FAKE_REPO/context/quarantine"
assert_file_exists "priorities.md created" "$FAKE_REPO/context/priorities.md"
assert_file_exists "todos.md created" "$FAKE_REPO/context/todos.md"
assert_file_exists "docs.md created" "$FAKE_REPO/context/docs.md"

# ── Test: per-job state files ──────────────────────────────────

if python3 -c "import yaml" 2>/dev/null; then
  assert_file_exists "job state: .last_run created" "$FAKE_REPO/jobs/test-job/.last_run"
else
  echo "    ⊘ Skipping job state tests (python3 yaml module not available)"
fi

# ── Test: memory directory was created ─────────────────────────

SAFE_PATH="${FAKE_REPO#/}"
SAFE_PATH="${SAFE_PATH//\//-}"
EXPECTED_MEMORY="$FAKE_HOME/.claude/projects/-${SAFE_PATH}/memory"

assert_file_exists "memory directory created" "$EXPECTED_MEMORY"
assert_file_exists "memory/people created" "$EXPECTED_MEMORY/people"
assert_file_exists "memory/projects created" "$EXPECTED_MEMORY/projects"
assert_file_exists "MEMORY.md initialized" "$EXPECTED_MEMORY/MEMORY.md"

# ── Test: defaults when optional fields are skipped ────────────

FAKE_REPO2="$TEST_TMPDIR/setup-test2"
FAKE_HOME2="$TEST_TMPDIR/fakehome2"
FAKE_PROJECTS2="$TEST_TMPDIR/my-projects2"

mkdir -p "$FAKE_HOME2" "$FAKE_PROJECTS2"
mkdir -p "$FAKE_REPO2/setup" "$FAKE_REPO2/jobs"
cp -r "$REPO_DIR/setup/templates" "$FAKE_REPO2/setup/"
cp "$REPO_DIR/setup/setup.sh" "$FAKE_REPO2/setup/"
cp "$REPO_DIR/setup/settings.json" "$FAKE_REPO2/setup/"
cp "$REPO_DIR/setup/guard-secrets-global.sh" "$FAKE_REPO2/setup/"
cp "$REPO_DIR/CLAUDE.md.template" "$FAKE_REPO2/"

# Empty task list IDs → should get defaults
# Blank lines: timezone (uses default), task list ID (empty), do-today ID (empty)
INPUT_LINES2="$FAKE_PROJECTS2
Bob
Developer
TestCo
testco.io



y
y
y
y
y
y
y
y
y
y
y
n
n
n"

OUTPUT2=$(cd "$FAKE_REPO2" && HOME="$FAKE_HOME2" bash setup/setup.sh <<< "$INPUT_LINES2" 2>&1)

assert_file_exists "CLAUDE.md created (defaults)" "$FAKE_REPO2/CLAUDE.md"
assert_file_contains "default task list ID" "$FAKE_REPO2/CLAUDE.md" "YOUR_TASKS_LIST_ID"
assert_file_contains "default do-today ID" "$FAKE_REPO2/CLAUDE.md" "YOUR_DO_TODAY_LIST_ID"

# Cleanup memory dirs
rm -rf "$EXPECTED_MEMORY"
SAFE_PATH2="${FAKE_REPO2#/}"
SAFE_PATH2="${SAFE_PATH2//\//-}"
rm -rf "$FAKE_HOME2/.claude/projects/-${SAFE_PATH2}"

finish

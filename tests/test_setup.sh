#!/usr/bin/env bash
# Tests for scripts/setup.sh
# Verifies: CLAUDE.md generation, org.yaml creation, .env stub, context dirs.
# Uses non-interactive input via heredoc.

source "$(dirname "$0")/test_helpers.sh"

# ── Setup: create a fake repo with required files ──────────

FAKE_REPO="$TEST_TMPDIR/setup-test"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/jobs"

# Copy the files setup.sh needs
cp "$REPO_DIR/CLAUDE.md.template" "$FAKE_REPO/"
cp "$REPO_DIR/scripts/setup.sh" "$FAKE_REPO/scripts/"

echo "  Testing setup.sh..."

# ── Run setup.sh with scripted input ────────────────────────

# Provide answers: name, role, company, email domain, timezone,
# tasks list ID, do-today list ID, and "n" for Docker build
OUTPUT=$(cd "$FAKE_REPO" && bash scripts/setup.sh <<'INPUT' 2>&1
Alice Testuser
Head of Engineering
Acme Corp
acme.com
America/Chicago
TASK_LIST_123
DO_TODAY_456
n
INPUT
)

# ── Test: CLAUDE.md was generated ───────────────────────────

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
assert_file_not_contains "no {{USER_ROLE}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{USER_ROLE}}"
assert_file_not_contains "no {{COMPANY}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{COMPANY}}"
assert_file_not_contains "no {{EMAIL_DOMAIN}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{EMAIL_DOMAIN}}"
assert_file_not_contains "no {{TIMEZONE}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{TIMEZONE}}"
assert_file_not_contains "no {{TASKS_LIST_ID}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{TASKS_LIST_ID}}"
assert_file_not_contains "no {{DO_TODAY_LIST_ID}} placeholder" "$FAKE_REPO/CLAUDE.md" "{{DO_TODAY_LIST_ID}}"

# ── Test: org.yaml was generated ────────────────────────────

assert_file_exists "org.yaml created" "$FAKE_REPO/jobs/org.yaml"
assert_file_contains "org.yaml has company" "$FAKE_REPO/jobs/org.yaml" "company: Acme Corp"
assert_file_contains "org.yaml has email domain" "$FAKE_REPO/jobs/org.yaml" "email_domain: acme.com"
assert_file_contains "org.yaml has timezone" "$FAKE_REPO/jobs/org.yaml" "timezone: America/Chicago"

# ── Test: .env stub was created ─────────────────────────────

assert_file_exists ".env stub created" "$FAKE_REPO/.env"
assert_file_contains ".env has SLACK_USER_TOKEN" "$FAKE_REPO/.env" "SLACK_USER_TOKEN="
assert_file_contains ".env has ANTHROPIC_API_KEY" "$FAKE_REPO/.env" "ANTHROPIC_API_KEY="
assert_file_contains ".env has GITHUB_TOKEN" "$FAKE_REPO/.env" "GITHUB_TOKEN="

# ── Test: context directories were created ──────────────────

assert_file_exists "context/ created" "$FAKE_REPO/context"
assert_file_exists "context/inbox/people created" "$FAKE_REPO/context/inbox/people"
assert_file_exists "context/inbox/projects created" "$FAKE_REPO/context/inbox/projects"
assert_file_exists "context/meeting_prep created" "$FAKE_REPO/context/meeting_prep"
assert_file_exists "context/quarantine created" "$FAKE_REPO/context/quarantine"

# ── Test: defaults when optional fields are skipped ─────────

FAKE_REPO2="$TEST_TMPDIR/setup-test2"
mkdir -p "$FAKE_REPO2/scripts" "$FAKE_REPO2/jobs"
cp "$REPO_DIR/CLAUDE.md.template" "$FAKE_REPO2/"
cp "$REPO_DIR/scripts/setup.sh" "$FAKE_REPO2/scripts/"

# Skip optional Google Tasks fields (empty input)
OUTPUT2=$(cd "$FAKE_REPO2" && bash scripts/setup.sh <<'INPUT' 2>&1
Bob
Developer
TestCo
testco.io
UTC


n
INPUT
)

assert_file_exists "CLAUDE.md created (defaults)" "$FAKE_REPO2/CLAUDE.md"
assert_file_contains "default task list ID" "$FAKE_REPO2/CLAUDE.md" "YOUR_TASKS_LIST_ID"
assert_file_contains "default do-today ID" "$FAKE_REPO2/CLAUDE.md" "YOUR_DO_TODAY_LIST_ID"

finish

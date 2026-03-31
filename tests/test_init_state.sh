#!/usr/bin/env bash
# Tests for setup/init-state.sh
# Verifies: context directories created, state files touched,
#           per-job state from job.yaml.

source "$(dirname "$0")/test_helpers.sh"

echo "  Testing init-state.sh..."

# ── Setup: create a fake repo with job structure ────────────

FAKE_REPO="$TEST_TMPDIR/init-test"
mkdir -p "$FAKE_REPO/setup" "$FAKE_REPO/jobs/test-job"

# Copy init-state.sh
cp "$REPO_DIR/setup/init-state.sh" "$FAKE_REPO/setup/"

# Create a job.yaml with state files
cat > "$FAKE_REPO/jobs/test-job/job.yaml" <<'EOF'
name: test-job
schedule: "0 * * * *"
state:
  - .last_run
  - .last_run_email
EOF

# ── Run init-state.sh ───────────────────────────────────────

OUTPUT=$(bash "$FAKE_REPO/setup/init-state.sh" 2>&1)

# ── Test: context directories ──────────────────────────────

assert_file_exists "context/ created" "$FAKE_REPO/context"
assert_file_exists "context/meeting_prep created" "$FAKE_REPO/context/meeting_prep"
assert_file_exists "context/inbox/people created" "$FAKE_REPO/context/inbox/people"
assert_file_exists "context/inbox/projects created" "$FAKE_REPO/context/inbox/projects"
assert_file_exists "context/quarantine created" "$FAKE_REPO/context/quarantine"

# ── Test: context data files ───────────────────────────────

assert_file_exists "priorities.md created" "$FAKE_REPO/context/priorities.md"
assert_file_exists "todos.md created" "$FAKE_REPO/context/todos.md"
assert_file_exists "docs.md created" "$FAKE_REPO/context/docs.md"

# ── Test: per-job state files (if python3 + PyYAML available)

if python3 -c "import yaml" 2>/dev/null; then
  assert_file_exists "job state: .last_run created" "$FAKE_REPO/jobs/test-job/.last_run"
  assert_file_exists "job state: .last_run_email created" "$FAKE_REPO/jobs/test-job/.last_run_email"
else
  echo "    ⊘ Skipping job.yaml state tests (python3 yaml module not available)"
fi

# ── Test: jobs without job.yaml are skipped ─────────────────

mkdir -p "$FAKE_REPO/jobs/no-yaml-job"
OUTPUT2=$(bash "$FAKE_REPO/setup/init-state.sh" 2>&1)
assert_not_contains "job without yaml skipped" "$OUTPUT2" "no-yaml-job"

finish

#!/usr/bin/env bash
# Tests for setup/install.sh
# Verifies: global guard script copied, settings.json generated with correct HOME,
#           _comment field removed.
# Uses a fake HOME to avoid clobbering real ~/.claude/.

source "$(dirname "$0")/test_helpers.sh"

echo "  Testing install.sh..."

# ── Setup: fake HOME so we don't touch real ~/.claude/ ──────

FAKE_HOME="$TEST_TMPDIR/fakehome"
mkdir -p "$FAKE_HOME"

# Run install.sh with overridden HOME
HOME="$FAKE_HOME" bash "$REPO_DIR/setup/install.sh" > /dev/null 2>&1

# ── Test: global guard script was copied ────────────────────

assert_file_exists "guard-secrets-global.sh installed" "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh"

# Verify it's executable
if [ -x "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh" ]; then
  echo "    ✓ guard-secrets-global.sh is executable"
  ((ASSERT_PASS++))
else
  echo "    ✗ guard-secrets-global.sh is not executable"
  ((ASSERT_FAIL++))
fi

# ── Test: settings.json was generated ───────────────────────

assert_file_exists "settings.json generated" "$FAKE_HOME/.claude/settings.json"

# Verify HOME was substituted
assert_file_contains "settings.json has real HOME" "$FAKE_HOME/.claude/settings.json" "$FAKE_HOME"
assert_file_not_contains "settings.json: no /home/user" "$FAKE_HOME/.claude/settings.json" "/home/user"

# Verify _comment was removed (if jq available)
if command -v jq &>/dev/null; then
  COMMENT=$(jq -r '._comment // "MISSING"' "$FAKE_HOME/.claude/settings.json")
  assert_eq "_comment field removed" "MISSING" "$COMMENT"
fi

# Verify it's valid JSON
if jq empty "$FAKE_HOME/.claude/settings.json" 2>/dev/null; then
  echo "    ✓ settings.json is valid JSON"
  ((ASSERT_PASS++))
else
  echo "    ✗ settings.json is not valid JSON"
  ((ASSERT_FAIL++))
fi

# ── Test: settings.json has expected structure ──────────────

DENY_COUNT=$(jq '.permissions.deny | length' "$FAKE_HOME/.claude/settings.json")
if [ "$DENY_COUNT" -gt 10 ]; then
  echo "    ✓ settings.json has $DENY_COUNT deny rules"
  ((ASSERT_PASS++))
else
  echo "    ✗ settings.json has only $DENY_COUNT deny rules (expected >10)"
  ((ASSERT_FAIL++))
fi

HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$FAKE_HOME/.claude/settings.json")
assert_eq "hook points to global guard" "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh" "$HOOK_CMD"

# ── Test: re-run is safe ────────────────────────────────────

HOME="$FAKE_HOME" bash "$REPO_DIR/setup/install.sh" > /dev/null 2>&1
assert_file_exists "re-run: settings.json still exists" "$FAKE_HOME/.claude/settings.json"
assert_file_exists "re-run: guard still exists" "$FAKE_HOME/.claude/scripts/guard-secrets-global.sh"

finish

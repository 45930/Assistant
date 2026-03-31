#!/usr/bin/env bash
# Shared test helpers. Source this from test files.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

# Portable sed -i (macOS requires '' arg, Linux does not)
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

ASSERT_PASS=0
ASSERT_FAIL=0

# Create an isolated temp directory for each test run
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ── Assertions ──────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    ((ASSERT_FAIL++))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc"
    echo "      expected to contain: $needle"
    echo "      in: $haystack"
    ((ASSERT_FAIL++))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc"
    echo "      expected NOT to contain: $needle"
    echo "      in: $haystack"
    ((ASSERT_FAIL++))
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  if [ -e "$filepath" ]; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc (file not found: $filepath)"
    ((ASSERT_FAIL++))
  fi
}

assert_file_contains() {
  local desc="$1" filepath="$2" pattern="$3"
  if grep -qF "$pattern" "$filepath" 2>/dev/null; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc (pattern '$pattern' not found in $filepath)"
    ((ASSERT_FAIL++))
  fi
}

assert_file_not_contains() {
  local desc="$1" filepath="$2" pattern="$3"
  if ! grep -qF "$pattern" "$filepath" 2>/dev/null; then
    echo "    ✓ $desc"
    ((ASSERT_PASS++))
  else
    echo "    ✗ $desc (pattern '$pattern' unexpectedly found in $filepath)"
    ((ASSERT_FAIL++))
  fi
}

# Print summary and exit with appropriate code
finish() {
  echo ""
  echo "  Assertions: $ASSERT_PASS passed, $ASSERT_FAIL failed"
  [ "$ASSERT_FAIL" -eq 0 ]
}

# ── Guard hook helpers ──────────────────────────────────────

# Run a guard script with given JSON input. Returns its stdout.
run_guard() {
  local script="$1" json_input="$2"
  echo "$json_input" | bash "$script" 2>/dev/null || true
}

# Build tool-use JSON for file-path tools (Read, Write, Edit)
json_file_tool() {
  local tool="$1" path="$2"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path"
}

# Build tool-use JSON for search tools (Glob, Grep)
json_search_tool() {
  local tool="$1" path="$2"
  printf '{"tool_name":"%s","tool_input":{"path":"%s","pattern":"*"}}' "$tool" "$path"
}

# Build tool-use JSON for Bash
json_bash_tool() {
  local cmd="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# Build tool-use JSON for Write (with content)
json_write_tool() {
  local path="$1" content="$2"
  # Use jq to safely encode the content
  jq -n --arg p "$path" --arg c "$content" \
    '{"tool_name":"Write","tool_input":{"file_path":$p,"content":$c}}'
}

# Build tool-use JSON for Edit (with new_string)
json_edit_tool() {
  local path="$1" content="$2"
  jq -n --arg p "$path" --arg c "$content" \
    '{"tool_name":"Edit","tool_input":{"file_path":$p,"new_string":$c}}'
}

# Check if guard output indicates a block
is_blocked() {
  local output="$1"
  echo "$output" | grep -q '"continue":false'
}

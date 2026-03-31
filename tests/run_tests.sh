#!/usr/bin/env bash
# Test runner — executes all test_*.sh files in this directory.
# Exit code is non-zero if any test fails.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ERRORS=()

for test_file in "$TESTS_DIR"/test_*.sh; do
  [ -f "$test_file" ] || continue
  test_name=$(basename "$test_file" .sh)
  echo "━━━ $test_name ━━━"
  if bash "$test_file"; then
    echo "  ✓ PASS"
    ((PASS++))
  else
    echo "  ✗ FAIL"
    ((FAIL++))
    ERRORS+=("$test_name")
  fi
  echo ""
done

echo "════════════════════════════════"
echo "  $PASS passed, $FAIL failed"
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "  Failed: ${ERRORS[*]}"
fi
echo "════════════════════════════════"

[ "$FAIL" -eq 0 ]

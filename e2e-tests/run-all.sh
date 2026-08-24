#!/usr/bin/env bash
# ============================================================================
# E2E Test Runner - Orchestrates all WordPress vs PHP compatibility tests
# ============================================================================
#
# This script runs every e2e test in order, collects logs into the
# logs-audit directory, and produces a summary report. It is designed
# to be called from the GitHub Actions workflow after the PHP packages
# are installed.
#
# Usage:
#   ./e2e-tests/run-all.sh <WP_ROOT> <PHP_SERIES> <LOG_DIR> [METADATA_JSON]
#
# Arguments:
#   WP_ROOT   - path to WordPress installation (e.g. /var/www/html)
#   PHP_SERIES - PHP major.minor (e.g. 8.6)
#   LOG_DIR   - directory for audit logs (e.g. ./e2e-tests/logs-audit)
#   METADATA_JSON - optional JSON string with version, OS, build hash, etc.
# ============================================================================
set -euo pipefail

WP_ROOT="${1:?Usage: $0 <WP_ROOT> <PHP_SERIES> <LOG_DIR> [METADATA_JSON]}"

PHP_SERIES="${2:?PHP series required}"

LOG_DIR="${3:?Log directory required}"

METADATA="${4:-{\"source\":\"e2e-audit\"}}}"

PHP_BIN="/usr/bin/php${PHP_SERIES}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d "$WP_ROOT" ] || { echo "ERROR: WP_ROOT '$WP_ROOT' is not a directory"; exit 1; }
[ -x "$PHP_BIN" ] || { echo "ERROR: $PHP_BIN not found"; exit 1; }
mkdir -p "$LOG_DIR"

echo "============================================"
echo " E2E WordPress Compatibility Test Suite"
echo "============================================"
echo "PHP:      $($PHP_BIN -r 'echo PHP_VERSION;')"
echo "Series:   $PHP_SERIES"
echo "WP Root:  $WP_ROOT"
echo "Log Dir:  $LOG_DIR"
echo "============================================"
echo ""

OVERALL_FAILS=0
OVERALL_PASSES=0
TESTS=()
RESULTS=()

# -- Define tests in order --
TESTS+=(
  "01-syntax-check:Syntax Check:PHP syntax lint of all WordPress files"
  "02-deprecation-check:Deprecation Detection:Scan for deprecated/removed PHP functions"
  "04-nginx-fpm-test:Nginx+FPM Integration:Full web stack test with Nginx and PHP-FPM"
  "05-fpm-socket-direct:FPM Socket Direct:Direct FastCGI protocol test (no web server)"
  "06-before-after-migration:Before/After Migration:PHP language feature migration analysis"
)

# -- Run tests --
for test_entry in "${TESTS[@]}"; do
  IFS=':' read -r script name desc <<< "$test_entry"
  SCRIPT_PATH="${SCRIPT_DIR}/${script}.sh"

  echo "---"
  echo "Running: $name"
  echo "  Script: $script.sh"
  echo "  Desc:   $desc"
  echo ""

  if [ ! -x "$SCRIPT_PATH" ]; then
    echo "  SKIP: script not found or not executable"
    RESULTS+=("$name:SKIP")
    continue
  fi

  TEST_START=$(date +%s)
  set +e
  case "$script" in
    01-syntax-check)
      "$SCRIPT_PATH" "$WP_ROOT" "$PHP_BIN" "$LOG_DIR" "$METADATA"
      ;;
    02-deprecation-check)
      "$SCRIPT_PATH" "$WP_ROOT" "$PHP_BIN" "$LOG_DIR" "$METADATA"
      ;;
    04-nginx-fpm-test)
      "$SCRIPT_PATH" "$WP_ROOT" "$PHP_SERIES" "$LOG_DIR" "$METADATA"
      ;;
    05-fpm-socket-direct)
      "$SCRIPT_PATH" "$PHP_SERIES" "$LOG_DIR" "$METADATA"
      ;;
    06-before-after-migration)
      "$SCRIPT_PATH" "$WP_ROOT" "$PHP_BIN" "$LOG_DIR" "$METADATA"
      ;;
    *)
      echo "  SKIP: unknown test $script"
      RESULTS+=("$name:SKIP")
      continue
      ;;
  esac
  TEST_RC=$?
  set -e
  TEST_END=$(date +%s)
  TEST_DURATION=$((TEST_END - TEST_START))

  if [ $TEST_RC -eq 0 ]; then
    echo "  PASS (${TEST_DURATION}s)"
    RESULTS+=("$name:PASS:${TEST_DURATION}s")
    OVERALL_PASSES=$((OVERALL_PASSES + 1))
  else
    echo "  FAIL (${TEST_DURATION}s)"
    RESULTS+=("$name:FAIL:${TEST_DURATION}s")
    OVERALL_FAILS=$((OVERALL_FAILS + 1))
  fi
  echo ""
done

# -- Generate summary report --
SUMMARY_FILE="${LOG_DIR}/$(date -u +%Y-%m-%d_%H-%M-%S)_00-summary.md"
cat > "$SUMMARY_FILE" << HDR
# E2E WordPress Compatibility Audit - Summary

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | $($PHP_BIN -r 'echo PHP_VERSION;') |
| **PHP Series** | $PHP_SERIES |
| **WordPress Root** | $WP_ROOT |
| **OS** | $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown') |
| **Metadata** | $METADATA |

---

## Test Results

| # | Test | Result | Duration |
|---|---|---|---|
HDR

for r in "${RESULTS[@]}"; do
  IFS=':' read -r rname rstatus rduration <<< "$r"
  printf '| %s | %s | %s | %s |\n' "${#RESULTS[@]}" "$rname" "$rstatus" "${rduration:-}" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" << FOOTER

---

## Overall: $((OVERALL_PASSES + OVERALL_FAILS)) tests, $OVERALL_PASSES passed, $OVERALL_FAILS failed

## Individual Test Reports

FOOTER

# List generated log files
for log in "${LOG_DIR}"/*.md; do
  [ -f "$log" ] || continue
  BN=$(basename "$log")
  echo "- [${BN}](./${BN})" >> "$SUMMARY_FILE"
done

echo "============================================"
echo " Results: $OVERALL_PASSES passed, $OVERALL_FAILS failed"
echo " Summary: $SUMMARY_FILE"
echo "============================================"

if [ "$OVERALL_FAILS" -gt 0 ]; then
  echo "RESULT: SOME_TESTS_FAILED=$OVERALL_FAILS"
  exit 1
else
  echo "RESULT: ALL_TESTS_PASSED"
  exit 0
fi

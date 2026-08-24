#!/usr/bin/env bash
# ============================================================================
# E2E Test 01: PHP Syntax Checker - Full WordPress Codebase
# ============================================================================
#
# Lints every .php file in the WordPress installation against the just-built
# PHP binary. Catches syntax errors introduced by new PHP language changes
# (new reserved words, stricter tokeniser rules, removed syntax forms).
#
# Usage:
#   ./e2e-tests/01-syntax-check.sh <WP_ROOT> <PHP_BIN> <LOG_DIR> <METADATA>
#
# Arguments:
#   WP_ROOT   - path to WordPress installation (e.g. /var/www/html)
#   PHP_BIN   - path to the PHP CLI binary (e.g. /usr/bin/php8.6)
#   LOG_DIR   - directory for audit logs (e.g. ./e2e-tests/logs-audit)
#   METADATA  - JSON string with test metadata (version, OS, build hash)
# ============================================================================
set -euo pipefail

WP_ROOT="${1:?Usage: $0 <WP_ROOT> <PHP_BIN> <LOG_DIR> <METADATA>}"

PHP_BIN="${2:?PHP binary path required}"

LOG_DIR="${3:?Log directory required}"

METADATA="${4:-{}}"

[ -d "$WP_ROOT" ] || { echo "ERROR: WP_ROOT not a directory"; exit 1; }
[ -x "$PHP_BIN" ] || { echo "ERROR: PHP_BIN not executable"; exit 1; }
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_01-syntax-check.md"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 01: PHP Syntax Check

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | \`"$PHP_VERSION"\` |
| **PHP Binary** | \`"$PHP_BIN"\` |
| **WordPress Root** | \`"$WP_ROOT"\` |
| **OS** | $OS_NAME |
| **Metadata** | \`"$METADATA"\` |

---
HDR

# -- Collect PHP files --
mapfile -t PHP_FILES < <(find "$WP_ROOT" -name '*.php' \
  -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null)
TOTAL=${#PHP_FILES[@]}
FAILS=0
FAIL_LIST=""

echo "=== Syntax Check: $TOTAL PHP files ===" | tee -a "$LOG_FILE"
echo "PHP Version: $PHP_VERSION" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# -- Lint each file --
for f in "${PHP_FILES[@]}"; do
  REL="${f#$WP_ROOT/}"
  OUT=$($PHP_BIN -d error_reporting=32767 -d display_errors=1 -l "$f" 2>&1) || {
    FAILS=$((FAILS + 1))
    echo "FAIL: $REL" | tee -a "$LOG_FILE"
    echo '   ```' | tee -a "$LOG_FILE"
    echo "$OUT" | sed 's/^/   /' | tee -a "$LOG_FILE"
    echo '   ```' | tee -a "$LOG_FILE"
    FAIL_LIST="${FAIL_LIST}${REL}: ${OUT}"$'\n'
  }
done

PASSED=$((TOTAL - FAILS))
RATE=$(awk "BEGIN {printf \"%.2f\", $PASSED * 100 / $TOTAL}" 2>/dev/null || echo 'N/A')

cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Total files scanned** | $TOTAL |
| **Passed** | $PASSED |
| **Failed** | $FAILS |
| **Pass rate** | ${RATE}% |
SUM

if [ "$FAILS" -gt 0 ]; then
  printf '\n## Failed Files\n\n%s\n' "$FAIL_LIST" >> "$LOG_FILE"
  echo "RESULT: SYNTAX_ERRORS_FOUND=$FAILS" | tee -a "$LOG_FILE"
  exit 1
else
  echo "RESULT: ALL_SYNTAX_OK (0 errors across $TOTAL files)" | tee -a "$LOG_FILE"
  exit 0
fi

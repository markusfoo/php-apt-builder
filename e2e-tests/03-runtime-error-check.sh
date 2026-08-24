#!/usr/bin/env bash
# ============================================================================
# E2E Test 03: Runtime Error Detection via PHP-FPM + Web Requests
# ============================================================================
#
# Probes the running WordPress installation through HTTP and captures all
# PHP Fatal errors, Warnings, Notices, and Deprecated messages from the
# FPM error log. Groups findings by severity and provides file:line context.
#
# Usage:
#   ./e2e-tests/03-runtime-error-check.sh <BASE_URL> <SERIES> <LOG_DIR> <METADATA>
#
# Arguments:
#   BASE_URL  - base URL of the WordPress install (e.g. http://localhost)
#   SERIES    - PHP series (e.g. 8.6) -- used to find FPM log
#   LOG_DIR   - directory for audit logs
#   METADATA  - JSON string with test metadata
# ============================================================================
set -euo pipefail

BASE_URL="${1:?Usage: $0 <BASE_URL> <SERIES> <LOG_DIR> <METADATA>}"

SERIES="${2:?PHP series required}"

LOG_DIR="${3:?Log directory required}"

METADATA="${4:-{}}}"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_03-runtime-error-check.md"
FPM_LOG="/var/log/php${SERIES}-fpm-e2e.log"
PHP_BIN="/usr/bin/php${SERIES}"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 03: Runtime Error Detection

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | \`$PHP_VERSION\` |
| **Base URL** | \`$BASE_URL\` |
| **FPM Log** | \`$FPM_LOG\` |
| **OS** | $OS_NAME |
| **Metadata** | \`$METADATA\` |

---

## HTTP Probes
HDR

# -- Probe key WordPress pages --
PAGES=(
  "/"
  "/wp-login.php"
  "/wp-admin/install.php"
  "/wp-cron.php"
  "/wp-admin/load-styles.php"
  "/wp-admin/load-scripts.php"
)

PROBE_OK=0
PROBE_FAIL=0

for PAGE in "${PAGES[@]}"; do
  HTTP_CODE=$(curl -s -o "/tmp/e2e-probe${PAGE//\//_}.html" -w '%{http_code}' \
    "${BASE_URL}${PAGE}" --max-time 15 2>/dev/null || echo "000")
  STATUS="OK"
  [ "$HTTP_CODE" = "200" ] || { STATUS="FAIL"; PROBE_FAIL=$((PROBE_FAIL + 1)); }
  [ "$STATUS" = "OK" ] && PROBE_OK=$((PROBE_OK + 1))
  echo "| \`$PAGE\` | HTTP $HTTP_CODE | $STATUS |" >> "$LOG_FILE"
done

echo "" >> "$LOG_FILE"
echo "| **Probes passed** | $PROBE_OK / ${#PAGES[@]} |" >> "$LOG_FILE"
echo "| **Probes failed** | $PROBE_FAIL |" >> "$LOG_FILE"

# -- Analyze FPM error log --
echo "" >> "$LOG_FILE"
echo "## FPM Error Log Analysis" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

FATAL_COUNT=0
WARNING_COUNT=0
NOTICE_COUNT=0
DEPRECATED_COUNT=0
OTHER_COUNT=0

if [ -f "$FPM_LOG" ] && [ -s "$FPM_LOG" ]; then
  # Extract and count by severity
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE 'Fatal error|SIGSEGV|segfault|core dump|panic'; then
      FATAL_COUNT=$((FATAL_COUNT + 1))
      echo '### Fatal Error' >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "$line" >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "" >> "$LOG_FILE"
    elif echo "$line" | grep -qiE 'PHP Warning'; then
      WARNING_COUNT=$((WARNING_COUNT + 1))
      echo '### Warning' >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "$line" >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "" >> "$LOG_FILE"
    elif echo "$line" | grep -qiE 'PHP Notice|Undefined'; then
      NOTICE_COUNT=$((NOTICE_COUNT + 1))
    elif echo "$line" | grep -qiE 'PHP Deprecated'; then
      DEPRECATED_COUNT=$((DEPRECATED_COUNT + 1))
      echo '### Deprecated' >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "$line" >> "$LOG_FILE"
      echo "\`\`\`" >> "$LOG_FILE"
      echo "" >> "$LOG_FILE"
    else
      OTHER_COUNT=$((OTHER_COUNT + 1))
    fi
  done < "$FPM_LOG"
else
  echo "No FPM error log found (clean run -- no errors written)." >> "$LOG_FILE"
fi

# -- Summary --
cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Fatal errors** | $FATAL_COUNT |
| **Warnings** | $WARNING_COUNT |
| **Notices** | $NOTICE_COUNT |
| **Deprecated messages** | $DEPRECATED_COUNT |
| **Other** | $OTHER_COUNT |
| **HTTP probes passed** | $PROBE_OK / ${#PAGES[@]} |
SUM

if [ "$FATAL_COUNT" -gt 0 ]; then
  echo "RESULT: FATAL_ERRORS_FOUND=$FATAL_COUNT" | tee -a "$LOG_FILE"
  exit 1
else
  echo "RESULT: ALL_RUNTIME_CLEAN (warnings=$WARNING_COUNT, notices=$NOTICE_COUNT, deprecated=$DEPRECATED_COUNT)" | tee -a "$LOG_FILE"
  exit 0
fi

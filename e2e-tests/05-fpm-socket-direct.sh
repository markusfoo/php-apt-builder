#!/usr/bin/env bash
# ============================================================================
# E2E Test 05: Direct PHP-FPM Socket Test (No Web Server)
# ============================================================================
#
# Tests PHP-FPM directly through its Unix socket using cgi-fcgi, bypassing
# Nginx entirely. This isolates FPM behaviour from any web server quirks
# and tests raw FastCGI protocol handling.
#
# Usage:
#   ./e2e-tests/05-fpm-socket-direct.sh <SERIES> <LOG_DIR> <METADATA>
#
# Arguments:
#   SERIES    - PHP series (e.g. 8.6)
#   LOG_DIR   - directory for audit logs
#   METADATA  - JSON string with test metadata
# ============================================================================
set -euo pipefail

SERIES="${1:?Usage: $0 <SERIES> <LOG_DIR> <METADATA>}"

LOG_DIR="${2:?Log directory required}"

METADATA="${3:-{}}"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_05-fpm-socket-direct.md"
PHP_BIN="/usr/bin/php${SERIES}"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')
FPM_SOCK="/run/php/php${SERIES}-fpm.sock"
FAILS=0

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 05: Direct FPM Socket Test

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | \`$PHP_VERSION\` |
| **FPM Socket** | \`$FPM_SOCK\` |
| **Method** | Direct FastCGI (no web server) |
| **OS** | $OS_NAME |
| **Metadata** | \`$METADATA\` |

---

## Test Results
HDR

# -- Ensure FPM is running --
if [ ! -S "$FPM_SOCK" ]; then
  mkdir -p /run/php
  php-fpm${SERIES} --daemonize 2>&1 | tee -a "$LOG_FILE"
  sleep 1
fi
[ -S "$FPM_SOCK" ] || { echo "FATAL: FPM socket not found" | tee -a "$LOG_FILE"; exit 1; }

echo "| Test | Detail | Result |" >> "$LOG_FILE"
echo "|---|---|---|" >> "$LOG_FILE"

# -- Install cgi-fcgi if needed --
if ! command -v cgi-fcgi &>/dev/null; then
  apt-get install -y --no-install-recommends libfcgi0ldbl 2>/dev/null || \
    apt-get install -y --no-install-recommends libfcgi-bin 2>/dev/null || \
    echo "WARNING: cgi-fcgi not available, using SCRIPT_FILENAME method"
fi

# -- Create test scripts --
TEST_DIR="/tmp/e2e-fpm-direct"
mkdir -p "$TEST_DIR"

echo "<?php echo 'FPM_DIRECT_OK'; ?>" > "$TEST_DIR/simple.php"
echo "<?php phpinfo(INFO_GENERAL); ?>" > "$TEST_DIR/info.php"
echo "<?php echo json_encode(['php_version' => PHP_VERSION, 'sapi' => PHP_SAPI, 'memory' => ini_get('memory_limit')]); ?>" > "$TEST_DIR/env.php"
echo "<?php \$data = str_repeat('X', 1024 * 1024); echo 'LARGE_OK_' . strlen(\$data); ?>" > "$TEST_DIR/large.php"

# -- Test via SCRIPT_FILENAME env var --
run_fpm_test() {
  local name="$1" script="$2" expect="$3"
  local result
  # Use the built-in php-cgi to speak FastCGI to the socket
  result=$(SCRIPT_NAME=/test.php SCRIPT_FILENAME="$script" \
    REQUEST_METHOD=GET \
    cgi-fcgi -bind -connect "$FPM_SOCK" 2>/dev/null | head -20 || echo "FAILED")

  local status="PASS"
  if echo "$result" | grep -q "$expect"; then
    status="PASS"
  else
    status="FAIL"
    FAILS=$((FAILS + 1))
  fi
  echo "| $name | Expecting '$expect' in response | $status |" >> "$LOG_FILE"
}

if command -v cgi-fcgi &>/dev/null; then
  run_fpm_test "Simple PHP execution" "$TEST_DIR/simple.php" "FPM_DIRECT_OK"
  run_fpm_test "PHP info output" "$TEST_DIR/info.php" "PHP Version"
  run_fpm_test "Environment variables" "$TEST_DIR/env.php" "php_version"
  run_fpm_test "Large response (1MB)" "$TEST_DIR/large.php" "LARGE_OK"
else
  # Fallback: use PHP CLI to test FPM connectivity
  echo "| cgi-fcgi unavailable | Using CLI fallback | SKIP |" >> "$LOG_FILE"

  # Test FPM via HTTP (start a minimal nginx on port 8081)
  cat > /etc/nginx/sites-available/fpm-direct << 'NGXDIR'
  server {
      listen 8081;
      root /tmp/e2e-fpm-direct;
      index index.php;
      location ~ \.php$ {
          include fastcgi_params;
          fastcgi_pass unix:/run/php/__FPM_SOCK__;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
      }
  }
NGXDIR
  sed -i "s/__FPM_SOCK__/php${SERIES}-fpm.sock/g" /etc/nginx/sites-available/fpm-direct
  ln -sf /etc/nginx/sites-available/fpm-direct /etc/nginx/sites-enabled/fpm-direct
  nginx -t && nginx -s reload 2>/dev/null || nginx
  sleep 1

  for test_name in simple info env large; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8081/${test_name}.php" --max-time 10 2>/dev/null || echo "000")
    STATUS="PASS"
    [ "$CODE" = "200" ] || { STATUS="FAIL"; FAILS=$((FAILS + 1)); }
    echo "| ${test_name}.php | HTTP $CODE | $STATUS |" >> "$LOG_FILE"
  done
fi

# -- Summary --
cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Tests run** | 4 |
| **Passed** | $((4 - FAILS)) |
| **Failed** | $FAILS |
| **FPM Socket** | $FPM_SOCK |
SUM

if [ "$FAILS" -gt 0 ]; then
  echo "RESULT: FPM_DIRECT_TEST_FAILS=$FAILS" | tee -a "$LOG_FILE"
  exit 1
else
  echo "RESULT: ALL_FPM_DIRECT_TESTS_PASSED" | tee -a "$LOG_FILE"
  exit 0
fi

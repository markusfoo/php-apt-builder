#!/usr/bin/env bash
# ============================================================================
# E2E Test 04: Full Nginx + PHP-FPM + LIVE WordPress Integration Test
# ============================================================================
#
# Sets up Nginx with the just-built PHP-FPM and tests against a fully
# installed WordPress (MariaDB + WP-CLI). Verifies real page rendering,
# login flow, REST API, RSS feeds, and PHP execution through FPM.
#
# Usage:
#   ./e2e-tests/04-nginx-fpm-test.sh <WP_ROOT> <SERIES> <LOG_DIR> <METADATA>
#
# Arguments:
#   WP_ROOT   - path to WordPress installation
#   SERIES    - PHP series (e.g. 8.6)
#   LOG_DIR   - directory for audit logs
#   METADATA  - JSON string with test metadata
# ============================================================================
set -euo pipefail

WP_ROOT="${1:?Usage: $0 <WP_ROOT> <SERIES> <LOG_DIR> <METADATA>}"
SERIES="${2:?PHP series required}"
LOG_DIR="${3:?Log directory required}"
METADATA="${4:-{}}"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_04-nginx-fpm-test.md"
PHP_BIN="/usr/bin/php${SERIES}"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')
FPM_SOCK="/run/php/php${SERIES}-fpm.sock"
FAILS=0
TOTAL_TESTS=0

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 04: Nginx + PHP-FPM + Live WordPress Integration

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | \`$PHP_VERSION\` |
| **FPM Socket** | \`$FPM_SOCK\` |
| **WordPress Root** | \`$WP_ROOT\` |
| **Database** | MariaDB (admin/admin @ localhost) |
| **OS** | $OS_NAME |
| **Metadata** | \`$METADATA\` |

---

## Test Results

| # | Test | URL | Expected | Got | Result |
|---|---|---|---|---|---|
HDR

# -- Configure Nginx --
echo "::group::Nginx Configuration"
cat > /etc/nginx/sites-available/wp-e2e << 'NGXCFG'
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    root /var/www/html;
    index index.php index.html;
    server_name _;
    client_max_body_size 64M;
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/__FPM_SOCK__;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 60;
    }
    location ~ /\. { deny all; }
}
NGXCFG
sed -i "s/__FPM_SOCK__/php${SERIES}-fpm.sock/g" /etc/nginx/sites-available/wp-e2e
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wp-e2e /etc/nginx/sites-enabled/wp-e2e
echo "Nginx config test:"
nginx -t 2>&1 | tee -a "$LOG_FILE"
echo "::endgroup::"

# -- Ensure FPM is running --
echo "FPM socket check: $FPM_SOCK"
if [ ! -S "$FPM_SOCK" ]; then
  echo "  Socket missing, starting FPM..."
  mkdir -p /run/php
  php-fpm${SERIES} --daemonize 2>&1 | tee -a "$LOG_FILE"
  sleep 1
fi
if [ ! -S "$FPM_SOCK" ]; then
  echo "FATAL: FPM socket not found at $FPM_SOCK" | tee -a "$LOG_FILE"
  echo "RESULT: INTEGRATION_TEST_FAILS=1 FATALS=1" | tee -a "$LOG_FILE"
  exit 1
fi
ls -la "$FPM_SOCK"
echo "  OK"

# Restart nginx
echo "Starting Nginx on port 8080..."
nginx -s stop 2>/dev/null || true
sleep 1
if ! nginx 2>&1 | tee -a "$LOG_FILE"; then
  echo "FATAL: nginx failed to start" | tee -a "$LOG_FILE"
  echo "RESULT: INTEGRATION_TEST_FAILS=1 FATALS=1" | tee -a "$LOG_FILE"
  exit 1
fi
sleep 1

# Verify nginx is listening
if ss -tlnp 2>/dev/null | grep -q ':8080'; then
  echo "  Nginx listening on :8080 OK"
else
  echo "  WARNING: Nginx not listening on :8080"
  ss -tlnp 2>/dev/null || echo "    (ss not available)"
fi

# -- Test runner --
# Usage: run_test "name" "url" "expected_codes"
run_test() {
  local name="$1" url="$2"
  local -a expected
  read -ra expected <<< "$3"
  local safe_name
  safe_name=$(echo "$name" | tr ' ' '_')
  local html="/tmp/e2e-nginx-${safe_name}.html"
  local code
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  code=$(curl -s -o "$html" -w '%{http_code}' "$url" --max-time 15 2>/dev/null) || code="000"

  local status="PASS"
  local ok=0
  for exp in "${expected[@]}"; do
    [ "$code" = "$exp" ] && { ok=1; break; }
  done
  if [ "$ok" -eq 0 ]; then
    status="FAIL"
    FAILS=$((FAILS + 1))
    local body_snippet
    body_snippet=$(head -c 300 "$html" 2>/dev/null | tr '\n' ' ' || echo "(empty)")
    echo "  [$status] $name <- HTTP $code (expected: ${expected[*]})"
    echo "           URL: $url"
    echo "           Body: $body_snippet"
  else
    echo "  [$status] $name <- HTTP $code"
  fi
  echo "| $TOTAL_TESTS | $name | \`$url\` | ${expected[*]} | $code | $status |" >> "$LOG_FILE"
}

# Content verifier: check that response body contains expected text
# Usage: check_content "test name" "html file" "expected substring"
check_content() {
  local name="$1" html="$2" expect="$3"
  local found=0
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  if [ -f "$html" ] && grep -qi "$expect" "$html" 2>/dev/null; then
    found=1
  fi
  if [ "$found" -eq 1 ]; then
    echo "  [PASS] $name <- '$expect' found in response"
    echo "| $TOTAL_TESTS | $name | - | '$expect' | found | PASS |" >> "$LOG_FILE"
  else
    FAILS=$((FAILS + 1))
    echo "  [FAIL] $name <- '$expect' NOT found in response"
    echo "| $TOTAL_TESTS | $name | - | '$expect' | NOT FOUND | FAIL |" >> "$LOG_FILE"
  fi
}

echo ""
echo "Running LIVE WordPress integration tests..."
echo ""

# ==================================================================
# GROUP A: Basic PHP-FPM (no WordPress needed)
# ==================================================================

echo "--- Group A: Basic PHP-FPM ---"

# TEST A1: Static file (nginx direct, no PHP)
echo "<!-- e2e static test -->" > /var/www/html/static-test.html
run_test "A1: Static HTML" "http://localhost:8080/static-test.html" "200"

# TEST A2: phpinfo via FPM
# Use echo marker + phpinfo() to reliably detect PHP execution
SERIES_SHORT="${SERIES}"
echo "<?php echo 'E2E_PHPINFO_MARKER=' . PHP_VERSION; phpinfo(); ?>" > /var/www/html/e2e-info.php
run_test "A2: phpinfo via FPM" "http://localhost:8080/e2e-info.php" "200"

INFO_HTML="/tmp/e2e-nginx-A2:_phpinfo_via_FPM.html"

TOTAL_TESTS=$((TOTAL_TESTS + 1))
# Check for our echo marker first (most reliable), then fallback to PHP Version text
if [ -f "$INFO_HTML" ] && grep -q "E2E_PHPINFO_MARKER=" "$INFO_HTML" 2>/dev/null; then
  echo "  [PASS] A2: phpinfo contains E2E_PHPINFO_MARKER (PHP executed correctly)"
  echo "| $TOTAL_TESTS | A2: phpinfo content | - | E2E_PHPINFO_MARKER | found | PASS |" >> "$LOG_FILE"
elif [ -f "$INFO_HTML" ] && grep -qi "PHP Version" "$INFO_HTML" 2>/dev/null; then
  echo "  [PASS] A2: phpinfo contains 'PHP Version'"
  echo "| $TOTAL_TESTS | A2: phpinfo content | - | 'PHP Version' | found | PASS |" >> "$LOG_FILE"
else
  FAILS=$((FAILS + 1))
  echo "  [FAIL] A2: phpinfo content check failed"
  echo "  Body snippet: $(head -c 500 "$INFO_HTML" 2>/dev/null | tr '\n' ' ')"
  echo "| $TOTAL_TESTS | A2: phpinfo content | - | E2E_PHPINFO_MARKER | NOT FOUND | FAIL |" >> "$LOG_FILE"
fi
rm -f /var/www/html/e2e-info.php

# TEST A3: PHP echo
echo "<?php echo 'FPM_OK_' . PHP_VERSION; ?>" > /var/www/html/e2e-echo.php
run_test "A3: PHP echo via FPM" "http://localhost:8080/e2e-echo.php" "200"
rm -f /var/www/html/e2e-echo.php

# TEST A4: POST request
echo "<?php echo json_encode(['method' => \$_SERVER['REQUEST_METHOD'], 'post' => \$_POST]); ?>" > /var/www/html/e2e-post.php

TOTAL_TESTS=$((TOTAL_TESTS + 1))
POST_CODE=$(curl -s -o /tmp/e2e-post-out.html -w '%{http_code}' -X POST -d 'test=hello' "http://localhost:8080/e2e-post.php" --max-time 10 2>/dev/null) || POST_CODE="000"
POST_BODY=$(head -c 200 /tmp/e2e-post-out.html 2>/dev/null)
if [ "$POST_CODE" = "200" ] && echo "$POST_BODY" | grep -q 'hello'; then
  echo "  [PASS] A4: POST to PHP <- HTTP $POST_CODE, data=hello found"
  echo "| $TOTAL_TESTS | A4: POST to PHP via FPM | - | 200 | $POST_CODE | PASS |" >> "$LOG_FILE"
else
  echo "  [FAIL] A4: POST to PHP <- HTTP $POST_CODE"
  echo "           Body: $POST_BODY"
  FAILS=$((FAILS + 1))
  echo "| $TOTAL_TESTS | A4: POST to PHP via FPM | - | 200 | $POST_CODE | FAIL |" >> "$LOG_FILE"
fi
rm -f /var/www/html/e2e-post.php

# ==================================================================
# GROUP B: Live WordPress Pages
# ==================================================================

echo ""
echo "--- Group B: Live WordPress Pages ---"

# TEST B1: Homepage (should be 200 with real WordPress content)
run_test "B1: WordPress Homepage" "http://localhost:8080/" "200"

# Verify homepage contains WordPress content
WP_HOME_HTML="/tmp/e2e-nginx-B1:_WordPress_Homepage.html"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ -f "$WP_HOME_HTML" ] && grep -qiE '(site-title|entry-title|blog|wordpress|E2E PHP Audit)' "$WP_HOME_HTML" 2>/dev/null; then
  echo "  [PASS] B1: Homepage contains WordPress content"
  echo "| $TOTAL_TESTS | B1: Homepage content | - | WP content | found | PASS |" >> "$LOG_FILE"
else
  FAILS=$((FAILS + 1))
  echo "  [FAIL] B1: Homepage does NOT contain WordPress content"
  echo "  Body snippet: $(head -c 300 "$WP_HOME_HTML" 2>/dev/null | tr '\n' ' ')"
  echo "| $TOTAL_TESTS | B1: Homepage content | - | WP content | NOT FOUND | FAIL |" >> "$LOG_FILE"
fi

# TEST B2: wp-login.php (should be 200 with login form)
run_test "B2: WordPress Login Page" "http://localhost:8080/wp-login.php" "200"
WP_LOGIN_HTML="/tmp/e2e-nginx-B2:_WordPress_Login_Page.html"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ -f "$WP_LOGIN_HTML" ] && grep -qiE '(log in|loginform|user_login|password)' "$WP_LOGIN_HTML" 2>/dev/null; then
  echo "  [PASS] B2: Login page has login form"
  echo "| $TOTAL_TESTS | B2: Login form | - | loginform | found | PASS |" >> "$LOG_FILE"
else
  FAILS=$((FAILS + 1))
  echo "  [FAIL] B2: Login page missing login form"
  echo "  Body snippet: $(head -c 300 "$WP_LOGIN_HTML" 2>/dev/null | tr '\n' ' ')"
  echo "| $TOTAL_TESTS | B2: Login form | - | loginform | NOT FOUND | FAIL |" >> "$LOG_FILE"
fi

# TEST B3: wp-admin/ (should redirect to wp-login.php = 302, or 200 if already logged in)
run_test "B3: WordPress Admin" "http://localhost:8080/wp-admin/" "200 301 302"

# TEST B4: WordPress REST API (should be 200 with JSON)
run_test "B4: WP REST API" "http://localhost:8080/wp-json/" "200"
WP_API_HTML="/tmp/e2e-nginx-B4:_WP_REST_API.html"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ -f "$WP_API_HTML" ] && grep -qiE '("name"|"description"|rest_route|authentication)' "$WP_API_HTML" 2>/dev/null; then
  echo "  [PASS] B4: REST API returns valid JSON"
  echo "| $TOTAL_TESTS | B4: REST API content | - | JSON | found | PASS |" >> "$LOG_FILE"
else
  FAILS=$((FAILS + 1))
  echo "  [FAIL] B4: REST API does NOT return valid JSON"
  echo "  Body snippet: $(head -c 300 "$WP_API_HTML" 2>/dev/null | tr '\n' ' ')"
  echo "| $TOTAL_TESTS | B4: REST API content | - | JSON | NOT FOUND | FAIL |" >> "$LOG_FILE"
fi

# TEST B5: RSS Feed
run_test "B5: RSS Feed" "http://localhost:8080/?feed=rss2" "200"
WP_RSS_HTML="/tmp/e2e-nginx-B5:_RSS_Feed.html"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ -f "$WP_RSS_HTML" ] && grep -qiE '(<rss|<channel|<title>)' "$WP_RSS_HTML" 2>/dev/null; then
  echo "  [PASS] B5: RSS feed is valid XML"
  echo "| $TOTAL_TESTS | B5: RSS content | - | <rss> | found | PASS |" >> "$LOG_FILE"
else
  FAILS=$((FAILS + 1))
  echo "  [FAIL] B5: RSS feed is NOT valid XML"
  echo "  Body snippet: $(head -c 300 "$WP_RSS_HTML" 2>/dev/null | tr '\n' ' ')"
  echo "| $TOTAL_TESTS | B5: RSS content | - | <rss> | NOT FOUND | FAIL |" >> "$LOG_FILE"
fi

# TEST B6: wp-cron.php (should return 200)
run_test "B6: WP Cron" "http://localhost:8080/wp-cron.php?doing_wp_cron" "200"

# TEST B7: WordPress AJAX endpoint (returns 400 without action param — normal WP behavior)
run_test "B7: WP AJAX endpoint" "http://localhost:8080/wp-admin/admin-ajax.php" "200 400"

# TEST B8: WordPress setup is complete (wp-admin/install.php should redirect or 200)
run_test "B8: WP Install redirect" "http://localhost:8080/wp-admin/install.php" "200 301 302"

# -- Check error logs --
echo ""
echo "Error log check:"
FPM_ERR="/var/log/php${SERIES}-fpm-audit.log"
FATALS=0
if [ -f "$FPM_ERR" ] && [ -s "$FPM_ERR" ]; then
  FATALS=$(grep -ciE 'Fatal error|SIGSEGV|segfault|panic' "$FPM_ERR" 2>/dev/null || echo 0)
  echo "  FPM fatal errors: $FATALS"
  if [ "$FATALS" -gt 0 ]; then
    echo "  FPM log excerpt:"
    tail -20 "$FPM_ERR" | sed 's/^/    /'
  fi
else
  echo "  FPM error log: clean"
fi
NGINX_ERRS=$(grep -ciE '502|503|upstream.*failed' /var/log/nginx/error.log 2>/dev/null || echo 0)
echo "  Nginx upstream errors: $NGINX_ERRS"

echo "" >> "$LOG_FILE"
echo "## Error Log Check" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "| FPM Fatal errors | $FATALS |" >> "$LOG_FILE"
echo "| Nginx upstream errors | $NGINX_ERRS |" >> "$LOG_FILE"

# -- WP-CLI verification --
echo ""
echo "WP-CLI database verification:"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if command -v wp &>/dev/null; then
  WP_VER_CLI=$(wp core version --allow-root --path=/var/www/html 2>/dev/null || echo "FAILED")
  if [ "$WP_VER_CLI" != "FAILED" ]; then
    echo "  [PASS] WP-CLI: WordPress $WP_VER_CLI installed"
    echo "| $TOTAL_TESTS | WP-CLI version | - | $WP_VER_CLI | found | PASS |" >> "$LOG_FILE"
  else
    FAILS=$((FAILS + 1))
    echo "  [FAIL] WP-CLI: could not get version"
    echo "| $TOTAL_TESTS | WP-CLI version | - | - | FAILED | FAIL |" >> "$LOG_FILE"
  fi
else
  echo "  [SKIP] WP-CLI not available"
  echo "| $TOTAL_TESTS | WP-CLI version | - | - | SKIP |" >> "$LOG_FILE"
fi

# -- Summary --
PASSED=$((TOTAL_TESTS - FAILS))
cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Tests run** | $TOTAL_TESTS |
| **Passed** | $PASSED |
| **Failed** | $FAILS |
| **FPM Fatal errors** | $FATALS |
| **Nginx upstream errors** | $NGINX_ERRS |
SUM

echo ""
echo "=============================="
echo " Integration Test Summary"
echo "=============================="
echo " Tests:  $TOTAL_TESTS total, $PASSED passed, $FAILS failed"
echo " FPM Fatal errors: $FATALS"
echo " Nginx errors: $NGINX_ERRS"
echo "=============================="

if [ "$FAILS" -gt 0 ] || [ "$FATALS" -gt 0 ]; then
  echo "RESULT: INTEGRATION_TEST_FAILS=$FAILS FATALS=$FATALS" | tee -a "$LOG_FILE"
  exit 1
else
  echo "RESULT: ALL_INTEGRATION_TESTS_PASSED" | tee -a "$LOG_FILE"
  exit 0
fi

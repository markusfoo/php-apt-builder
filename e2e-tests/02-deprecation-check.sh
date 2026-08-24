#!/usr/bin/env bash
# ============================================================================
# E2E Test 02: Deprecation and Removal Detection
# ============================================================================
#
# Scans the entire WordPress codebase for PHP functions, constants, and
# patterns that are deprecated or removed in the target PHP version.
# For each finding provides: file+line, deprecated name, version info,
# and a concrete replacement recommendation with PHP 8.x syntax.
#
# Usage:
#   ./e2e-tests/02-deprecation-check.sh <WP_ROOT> <PHP_BIN> <LOG_DIR> <METADATA>
# ============================================================================
set -euo pipefail

WP_ROOT="${1:?Usage: $0 <WP_ROOT> <PHP_BIN> <LOG_DIR> <METADATA>}"

PHP_BIN="${2:?PHP binary path required}"

LOG_DIR="${3:?Log directory required}"

METADATA="${4:-{}}}"

[ -d "$WP_ROOT" ] || { echo "ERROR: WP_ROOT not a directory"; exit 1; }
[ -x "$PHP_BIN" ] || { echo "ERROR: PHP_BIN not executable"; exit 1; }
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_02-deprecation-check.md"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
PHP_MAJOR=$($PHP_BIN -r 'echo PHP_MAJOR_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')

# -- Deprecation database --
# Format: func|dep_ver|rem_ver|replacement|fix_example
DEP_DB="/tmp/e2e-dep-db.txt"
cat > "$DEP_DB" << 'DEPS'
mysql_connect|5.5|7.0|mysqli_connect or PDO|$conn = new mysqli($host, $user, $pass, $db);
mysql_query|5.5|7.0|mysqli_query or PDO::query|$result = $conn->query($sql);
mysql_fetch_array|5.5|7.0|mysqli_fetch_array or PDO::fetch|$row = $result->fetch_array(MYSQLI_ASSOC);
mysql_fetch_assoc|5.5|7.0|mysqli_fetch_assoc or PDO::fetch|$row = $result->fetch_assoc();
mysql_num_rows|5.5|7.0|mysqli_num_rows or PDO rowCount|$count = $result->num_rows;
mysql_real_escape_string|5.5|7.0|mysqli_real_escape_string or prepared stmts|$safe = $conn->real_escape_string($input);
mysql_error|5.5|7.0|mysqli_error or PDO::errorInfo|echo $conn->error;
mysql_close|5.5|7.0|mysqli_close|$conn->close();
mysql_select_db|5.5|7.0|mysqli_select_db|$conn->select_db($dbname);
mysql_result|5.5|7.0|mysqli_result or fetch_column|$val = $result->fetch_column(0);
mysql_affected_rows|5.5|7.0|mysqli_affected_rows|$rows = $conn->affected_rows;
mysql_insert_id|5.5|7.0|mysqli_insert_id|$id = $conn->insert_id;
mysql_free_result|5.5|7.0|mysqli_free_result|$result->free();
create_function|7.2|9.0|Anonymous functions (closures)|$fn = function($arg) { return $arg * 2; };
each|7.2|8.0|foreach|foreach ($arr as $key => $value) { ... }
get_magic_quotes_gpc|7.4|8.0|Remove entirely (removed in PHP 5.4)|// magic_quotes was removed in PHP 5.4
get_magic_quotes_runtime|7.4|8.0|Remove entirely (removed in PHP 5.4)|// magic_quotes was removed in PHP 5.4
utf8_encode|8.2|9.0|mb_convert_encoding|$encoded = mb_convert_encoding($str, 'UTF-8');
utf8_decode|8.2|9.0|mb_convert_encoding|$decoded = mb_convert_encoding($str, 'ISO-8859-1');
DEPS

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 02: Deprecation and Removal Detection

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **PHP Version** | \`$PHP_VERSION\` |
| **WordPress Root** | \`$WP_ROOT\` |
| **OS** | $OS_NAME |
| **Metadata** | \`$METADATA\` |

---

## Scan Results
HDR

TOTAL_FINDINGS=0
FILES_SCANNED=0
TOTAL_PATTERNS=$(wc -l < "$DEP_DB")

echo "Scanning for $TOTAL_PATTERNS deprecated patterns..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# -- Scan each PHP file --
while IFS= read -r -d '' phpfile; do
  FILES_SCANNED=$((FILES_SCANNED + 1))
  REL="${phpfile#$WP_ROOT/}"

  while IFS='|' read -r func dep_ver rem_ver repl fix_ex; do
    [ -z "$func" ] && continue

    if grep -n -w "$func" "$phpfile" >/dev/null 2>&1; then
      MATCHES=$(grep -n -w "$func" "$phpfile" 2>/dev/null || true)
      while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue
        TOTAL_FINDINGS=$((TOTAL_FINDINGS + 1))
        LNUM=$(echo "$match_line" | cut -d: -f1)
        LCONTENT=$(echo "$match_line" | cut -d: -f2- | sed 's/^[[:space:]]*//')

        # Determine status based on PHP version
        REM_MAJOR=${rem_ver%%.*}
        DEP_MAJOR=${dep_ver%%.*}
        if [ "$REM_MAJOR" -le "$PHP_MAJOR" ] 2>/dev/null; then
          STATUS="REMOVED"
          BADGE="REMOVED in PHP $rem_ver"
        elif [ "$DEP_MAJOR" -le "$PHP_MAJOR" ] 2>/dev/null; then
          STATUS="DEPRECATED"
          BADGE="Deprecated in PHP $dep_ver"
        else
          STATUS="FUTURE"
          BADGE="Future deprecation (PHP $dep_ver)"
        fi

        cat >> "$LOG_FILE" << ENTRY
### [${BADGE}] \`"$func"\` in ${REL}:${LNUM}

| Detail | Value |
|---|---|
| **File** | ${REL}:${LNUM} |
| **Code** | \`"$LCONTENT"\` |
| **Deprecated in** | PHP ${dep_ver} |
| **Removed in** | PHP ${rem_ver} |
| **Status on PHP ${PHP_VERSION}** | ${STATUS} |
| **Replacement** | ${repl} |
| **Fix Example** | \`"$fix_ex"\` |

ENTRY
      done <<< "$MATCHES"
    fi
  done < "$DEP_DB"
done < <(find "$WP_ROOT" -name '*.php' -not -path '*/vendor/*' -not -path '*/node_modules/*' -print0 2>/dev/null)

# -- Summary --
cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Files scanned** | $FILES_SCANNED |
| **Total findings** | $TOTAL_FINDINGS |
| **PHP Version tested** | $PHP_VERSION |
| **Patterns checked** | $TOTAL_PATTERNS |
SUM

if [ "$TOTAL_FINDINGS" -gt 0 ]; then
  cat >> "$LOG_FILE" << RECS

## Recommendations

1. **Immediately replace** all REMOVED function calls
2. **Plan migration** for all DEPRECATED function calls
3. **Monitor** FUTURE deprecations for upcoming PHP releases
4. Each finding above includes a concrete code replacement
RECS
  echo "RESULT: DEPRECATIONS_FOUND=$TOTAL_FINDINGS" | tee -a "$LOG_FILE"
  exit 0  # deprecations are warnings, not hard failures
else
  echo "RESULT: NO_DEPRECATIONS_FOUND" | tee -a "$LOG_FILE"
  exit 0
fi

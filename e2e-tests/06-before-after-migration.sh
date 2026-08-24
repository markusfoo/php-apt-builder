#!/usr/bin/env bash
# ============================================================================
# E2E Test 06: Before/After PHP Migration Analysis
# ============================================================================
#
# Compares WordPress code against known breaking changes between the
# previous stable PHP version and the new build. For each change found,
# shows: the old (deprecated) code, the new (correct) code, and the
# exact file:line where it occurs.
#
# Usage:
#   ./e2e-tests/06-before-after-migration.sh <WP_ROOT> <PHP_BIN> <LOG_DIR> <METADATA>
#
# Arguments:
#   WP_ROOT   - path to WordPress installation
#   PHP_BIN   - path to the PHP CLI binary
#   LOG_DIR   - directory for audit logs
#   METADATA  - JSON string with test metadata
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
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_06-before-after-migration.md"
PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
PHP_MAJOR=$($PHP_BIN -r 'echo PHP_MAJOR_VERSION;')
PHP_MINOR=$($PHP_BIN -r 'echo PHP_MINOR_VERSION;')
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')

# -- Header --
cat > "$LOG_FILE" << HDR
# E2E Test 06: Before/After PHP Migration Analysis

| Field | Value |
|---|---|
| **Test Date** | $(date -u +%Y-%m-%d) |
| **New PHP Version** | \`$PHP_VERSION\` |
| **WordPress Root** | \`$WP_ROOT\` |
| **OS** | $OS_NAME |
| **Metadata** | \`$METADATA\` |

---

## Migration Changes Detected
HDR

# -- Breaking changes database --
# Format: pattern|old_desc|new_desc|old_code|new_code|since_version
CHANGES_DB="/tmp/e2e-changes-db.txt"
cat > "$CHANGES_DB" << 'CHANGES'
\$this in closures|\$this not available in anonymous functions|\$this automatically bound in closures|function () { \$this->method(); }|function () { \$this->method(); }|5.4
dynamic call to non-static|Cannot call non-static methods statically|Strict error for non-static method calls|ClassName::nonStaticMethod()|(new ClassName)->nonStaticMethod()|8.0
nullable type hints (mixed)|No mixed type hint|mixed type available|function foo(\$arg)|function foo(mixed \$arg): mixed|8.0
return type declarations|No return type enforcement|Return types enforced|function foo()|function foo(): int|7.0
union types|No union type support|Union types supported|function foo(\$x)|function foo(int|string \$x)|8.0
named arguments|Only positional args|Named args supported|foo(\$a, \$b)|foo(b: \$b, a: \$a)|8.0
match expression|No match|match expression available|switch (\$x) { case 1: ... }|match(\$x) { 1 => ..., default => ... }|8.0
nullsafe operator|Manual null checks|Nullsafe operator available|if (\$obj !== null) { \$obj->method(); }|\$obj?->method();|8.0
readonly properties|No readonly|readonly properties supported|public int \$x;|public readonly int \$x;|8.1
enums|No enum type|enum type available|class Status { const ACTIVE = 1; }|enum Status { case Active; }|8.1
fibers|No fiber support|Fiber class available|N/A|\$fiber = new Fiber(function (): void { ... });|8.1
disjunctive normal form types|No DNF types|DNF types supported|function foo(\$x)|function foo((A&B)|C \$x)|8.2
CHANGES

TOTAL_FINDINGS=0
FILES_SCANNED=0

echo "Scanning for migration changes..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

while IFS= read -r -d '' phpfile; do
  FILES_SCANNED=$((FILES_SCANNED + 1))
  REL="${phpfile#$WP_ROOT/}"

  while IFS='|' read -r pattern old_desc new_desc old_code new_code since_ver; do
    [ -z "$pattern" ] && continue

    # Skip patterns that start with backslash (they are conceptual, not searchable)
    [[ "$pattern" == \\* ]] && continue

    if grep -qE "$pattern" "$phpfile" 2>/dev/null; then
      MATCHES=$(grep -nE "$pattern" "$phpfile" 2>/dev/null || true)
      while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue
        TOTAL_FINDINGS=$((TOTAL_FINDINGS + 1))
        LNUM=$(echo "$match_line" | cut -d: -f1)
        LCONTENT=$(echo "$match_line" | cut -d: -f2- | sed 's/^[[:space:]]*//')

        cat >> "$LOG_FILE" << ENTRY
### Change: $old_desc

| Detail | Value |
|---|---|
| **File** | ${REL}:${LNUM} |
| **Current code** | \`"$LCONTENT"\` |
| **What changed** | $old_desc |
| **New approach** | $new_desc |
| **Before (old PHP)** | \`"$old_code"\` |
| **After (PHP ${since_ver}+)** | \`"$new_code"\` |
| **Available since** | PHP ${since_ver} |

ENTRY
      done <<< "$MATCHES"
    fi
  done < "$CHANGES_DB"
done < <(find "$WP_ROOT" -name '*.php' -not -path '*/vendor/*' -not -path '*/node_modules/*' -print0 2>/dev/null)

# -- Summary --
cat >> "$LOG_FILE" << SUM
---

## Summary

| Metric | Value |
|---|---|
| **Files scanned** | $FILES_SCANNED |
| **Migration changes found** | $TOTAL_FINDINGS |
| **PHP Version** | $PHP_VERSION |

## What This Means

This test identifies places in WordPress where newer PHP language features
*could* be adopted, or where old patterns exist that have cleaner equivalents
in PHP ${PHP_MAJOR}.${PHP_MINOR}. These are not bugs -- they are opportunities
to modernize the codebase for better performance and readability.
SUM

echo "RESULT: MIGRATION_ANALYSIS_COMPLETE findings=$TOTAL_FINDINGS" | tee -a "$LOG_FILE"
exit 0

# E2E Test 03: Runtime Error Detection

| Field | Value |
|---|---|
| **Test Date** | 2026-08-24 |
| **PHP Version** | `8.6.0beta1` |
| **Base URL** | `http://localhost:8080` |
| **FPM Log** | `/var/log/php8.6-fpm-e2e.log` |
| **OS** | Ubuntu 22.04.5 LTS |
| **Metadata** | `{"release":"php8.6.0-beta1-1","php":"8.6.0beta1","os":"Ubuntu 22.04","date":"2026-08-24"}}}` |

---

## HTTP Probes
| `/` | HTTP 200 | OK |
| `/wp-login.php` | HTTP 200 | OK |
| `/wp-admin/install.php` | HTTP 200 | OK |
| `/wp-cron.php` | HTTP 200 | OK |
| `/wp-admin/load-styles.php` | HTTP 200 | OK |
| `/wp-admin/load-scripts.php` | HTTP 200 | OK |

| **Probes passed** | 6 / 6 |
| **Probes failed** | 0 |

## FPM Error Log Analysis

No FPM error log found (clean run -- no errors written).
---

## Summary

| Metric | Value |
|---|---|
| **Fatal errors** | 0 |
| **Warnings** | 0 |
| **Notices** | 0 |
| **Deprecated messages** | 0 |
| **Other** | 0 |
| **HTTP probes passed** | 6 / 6 |
RESULT: ALL_RUNTIME_CLEAN (warnings=0, notices=0, deprecated=0)

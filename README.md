# PHP APT Builder

Pre-built `.deb` packages for PHP pre-release versions (beta/RC), published as
**GitHub Releases** with all assets attached. No APT repository setup
required — just download the `.deb` files and install.

Built from the **real Debian php-team packaging**, adapted for the target
PHP series. Produces the same split of packages that `deb.sury.org` publishes
(`phpX.Y-cli`, `phpX.Y-fpm`, `phpX.Y-common`, `phpX.Y-gd`, `phpX.Y-mysql`,
`phpX.Y-curl`, `phpX.Y-mbstring`, `phpX.Y-xml`, `phpX.Y-zip`, etc.).

**PECL extensions** are built automatically as part of every release:
xdebug, redis, igbinary, msgpack, apcu, mongodb, imagick, memcached.
Extensions that fail to compile are skipped with a warning.

Target: **Ubuntu 22.04 (jammy) / amd64**.

## Quick start

```bash
# Download all .deb files from the latest GitHub Release
# (or pick individual packages you need)

sudo dpkg -i php*.deb
sudo apt-get -f install

php8.6 -v
php8.6 -m
```

## Workflow overview

```
resolve -> prepare-and-validate -> build -> smoke-test --+-> e2e-wordpress-test -> publish
                                           build-pecl  --+
```

| Job | What it does |
|---|---|
| **resolve** | Confirms the php-src tag exists and packaging matches the target series |
| **prepare-and-validate** | Fetches source, validates packaging without compiling |
| **build** | Compiles all PHP `.deb` packages |
| **smoke-test** | Installs in a clean container and runs `php -v`, `php -m`, `php-fpm -t` |
| **build-pecl** | Builds PECL extensions against the compiled PHP (parallel with smoke-test) |
| **e2e-wordpress-test** | Installs all .debs, deploys WordPress, tests via Nginx+PHP-FPM, auto-skips broken PECL |
| **publish** | Uploads new `.deb` files to the GitHub Release (smart upsert, respects skip-list) |

### PECL extensions

Built automatically in the `build-pecl` job. To add or remove extensions,
edit the `EXTENSIONS` variable in `build-php.yml`.

Imagick and msgpack include build-time patches for PHP 8.6 API compatibility.

### Smart release management

The `publish` job does **not** delete and recreate releases. Instead:

- If a release for this version tag already exists, only **new** `.deb`
  files are uploaded (existing assets are kept).
- Beta/RC/alpha versions are automatically marked as pre-release.
- If the E2E test detected broken PECL extensions, those packages are
  automatically excluded from the release via a skip-list mechanism.

### E2E WordPress gate (build-time)

Before any release is published, the `e2e-wordpress-test` job runs on a clean
Ubuntu 22.04 container:

1. Installs **all** built .deb packages (core PHP + PECL)
2. Deploys the latest WordPress
3. Configures Nginx + PHP-FPM
4. Runs automated checks (HTTP responses, content validation, error logs)
5. If PECL extensions cause crashes: identifies the culprit, removes it,
   re-tests, and generates a **skip-list** so the publish job excludes
   those broken packages (core PHP failures always hard-fail)

This ensures every release can actually serve a real PHP application before
it reaches users.

## E2E WordPress Compatibility Audit (post-release)

A **separate, dedicated workflow** (`e2e-wordpress-audit.yml`) runs after a
release has been published. This is the deep compatibility verification
suite — it proactively tests the latest PHP pre-release build against the
world's most popular CMS to find issues **before** developers or users
report them.

### Why this matters

Instead of waiting for pull requests or bug reports from the community,
this system provides **real-time compatibility visibility**: every new
PHP beta/RC/dev build is automatically tested against WordPress, and any
incompatibilities, deprecations, or errors are logged with concrete fix
recommendations. This enables PHP developers to see the exact impact of
their changes on real-world applications and allows WordPress developers
to prepare updates before the PHP version is even released.

### How it works

The workflow downloads the .deb packages from a GitHub Release, installs
them on a clean Ubuntu 22.04 machine, deploys WordPress (latest stable or
nightly dev build), and runs these tests in order:

| # | Test | What it does |
|---|---|---|
| 01 | **PHP Syntax Check** | Lints every `.php` file in WordPress against the new PHP binary. Catches syntax errors from new reserved words, stricter tokeniser rules, removed syntax forms. |
| 02 | **Deprecation Detection** | Scans WordPress for functions/constants deprecated or removed in the target PHP version. Each finding includes the file, line, deprecated name, and a **concrete replacement** with correct PHP 8.x code. |
| 03 | **Runtime Error Collection** | After all HTTP tests, parses the FPM error log for PHP Fatal errors, Warnings, Notices, and Deprecated messages. Groups by severity with file:line context. |
| 04 | **Nginx + PHP-FPM Integration** | Full web stack test: configures Nginx, starts PHP-FPM, exercises WordPress core pages (homepage, login, admin, REST API, RSS, cron, AJAX), tests static files, POST handling, and checks both FPM and Nginx error logs. |
| 05 | **Direct FPM Socket Test** | Tests PHP-FPM directly through its Unix socket using the FastCGI protocol, bypassing Nginx entirely. Isolates FPM behaviour from web server quirks. |
| 06 | **Before/After Migration Analysis** | Compares WordPress code against known breaking changes between PHP versions. Shows the old (deprecated) pattern, the new (correct) pattern, and where in WordPress it could be modernized. |

### Test environments

- **Nginx + PHP-FPM**: Full LEMP stack with MariaDB + WP-CLI, testing WordPress through the standard web server path (tests 03, 04)
- **Direct FPM socket**: Raw FastCGI protocol test without any web server (test 05) — isolates PHP-FPM behaviour to catch issues that Nginx might mask or handle differently

### Audit logs

All test results are collected in `e2e-tests/logs-audit/` with per-date
Markdown reports containing:

- **Metadata**: PHP version, OS, release tag, build hash, test date
- **Detailed findings**: per-file results with line numbers
- **Recommendations**: concrete fix code for every deprecation/change found
- **Before/after comparisons**: old PHP pattern vs new correct pattern

Logs are stored chronologically, making it easy to track how WordPress
compatibility evolves across PHP pre-release builds over time.

### Running the audit

```bash
# Via GitHub Actions (recommended)
# Go to Actions -> E2E WordPress Audit -> Run workflow
# Specify release tag and WordPress version

# Or locally (after installing the .deb packages)
chmod +x e2e-tests/run-all.sh
e2e-tests/run-all.sh /var/www/html 8.6 ./e2e-tests/logs-audit
```

## Workflow files

| File | When to use |
|---|---|
| `build-php.yml` | Day-to-day: build PHP from source, test, publish release |
| `bootstrap-packaging.yml` | Run once: set up `packaging/debian/` for a new PHP series |
| `extension-checker.yml` | Fast PECL compile test (~2 min) against an existing release |
| `e2e-wordpress-audit.yml` | Post-release deep WordPress compatibility audit |

## `build-php.yml` inputs

| Input | Default | Meaning |
|---|---|---|
| `php_tag` | `php-8.6.0beta1` | Git tag in `php/php-src` to build |
| `target_series` | `8.6` | PHP series — must match `packaging/debian/` |
| `pkg_upstream_version` | `8.6.0~beta1` | Debian-ordered upstream version (`~` sorts before nothing) |
| `pkg_revision` | `1` | Debian package revision suffix |
| `publish` | `true` | Create/update a GitHub Release if build + smoke-test pass |

---

## Changelog

### 2026-08-24 — E2E WordPress Compatibility Audit System

- Added `e2e-wordpress-audit.yml` workflow: post-release deep compatibility
  audit that downloads .deb packages from a release and tests against
  the latest WordPress build
- Added `e2e-tests/` directory with 6 documented test scripts:
  - `01-syntax-check.sh` — PHP syntax lint of all WordPress files
  - `02-deprecation-check.sh` — deprecated/removed function detection
    with concrete replacement recommendations for PHP 8.x
  - `03-runtime-error-check.sh` — FPM error log analysis (Fatal, Warning,
    Notice, Deprecated) from live HTTP requests
  - `04-nginx-fpm-test.sh` — full Nginx + PHP-FPM + MariaDB + WP-CLI
    integration test against a live WordPress installation (18 checks)
  - `05-fpm-socket-direct.sh` — direct FastCGI socket test (no web server)
  - `06-before-after-migration.sh` — PHP language feature migration
    analysis with before/after code patterns
  - `run-all.sh` — master orchestrator that runs all tests and produces
    a summary report
- Audit logs are automatically committed to the repo under
  `e2e-tests/logs-audit/<tag>/<date>/` on every run
- Each test produces structured Markdown logs with metadata headers,
  detailed findings, summary tables, and fix recommendations

### 2026-08-24 — E2E WordPress Gate (build-time)

- Added `e2e-wordpress-test` job to `build-php.yml` as a gate before
  release publication
- Deploys latest WordPress on clean Ubuntu 22.04, tests via Nginx+PHP-FPM
- Automated checks: HTTP responses, WordPress content detection,
  phpinfo, FPM error log, Nginx error log
- Auto-fix mechanism: if a PECL extension causes crashes, identifies the
  culprit, removes it, re-tests, and generates a skip-list
- Publish job respects skip-list: broken PECL packages are excluded from
  release, core PHP failures always hard-fail and block the release

### 2026-08-24 — CI Infrastructure

- Fixed YAML parse errors in workflow definitions
- Fixed circular dependency in job `needs:` declarations
- Added smart release management: upsert instead of recreate
- Added apt retry/timeout configuration for CI reliability
- Switched from branch-based apt repo to GitHub Releases

### 8.6.0 Beta 1 (initial)

- Initial project setup: Debian packaging adopted from `debian/main/8.5`
- Fixed 11 Debian patches for PHP 8.6.0beta1 API changes
- Fixed session.save_path default to `/var/lib/php/sessions`
- Fixed lintian: removed dh-systemd (not on Ubuntu 22.04)
- Integrated PECL extension building into main workflow (8 extensions)
- Added extension-checker workflow for fast compile testing
- Simplified release tag format: `php8.6.0-beta1-1`

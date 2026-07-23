#!/usr/bin/env bash
set -euo pipefail

# Static checks: shell syntax, shellcheck lint, ante settings JSON validity.
# No credentials needed. Exits non-zero on the first failure.

cd "$(dirname "$0")/.."

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

echo "=== lint ==="

bash -n scripts/*.sh && pass "bash -n scripts/*.sh" || fail "bash -n scripts/*.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh && pass "shellcheck scripts/*.sh" || fail "shellcheck scripts/*.sh"
else
  echo "[WARN] shellcheck not installed; skipping lint"
fi

jq empty ante/settings.json && pass "jq empty ante/settings.json" || fail "jq empty ante/settings.json"

echo "=== lint complete ==="

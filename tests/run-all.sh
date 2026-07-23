#!/usr/bin/env bash
set -euo pipefail

# Runs all safe test scripts (lint, agents, merge).
# Skips e2e (needs credentials + real PR). Run tests/e2e.sh separately.

cd "$(dirname "$0")/.."

SCRIPTS=(tests/lint.sh tests/agents.sh tests/merge.sh)
FAILED=0

for s in "${SCRIPTS[@]}"; do
  echo
  bash "$s" || { echo "[FAIL] $s"; FAILED=1; }
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "[PASS] all tests passed"
else
  echo "[FAIL] one or more tests failed"
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# End-to-end local run: executes review.sh against a real PR.
# Requires ante on PATH, gh authenticated, and all env vars the action injects.
# This script will POST comments to the PR — point it at a test repo/PR.

cd "$(dirname "$0")/.."

REQUIRED_VARS=(PR_NUMBER REPO HEAD_SHA GITHUB_TOKEN INPUT_PROVIDER INPUT_EFFORT)
MISSING=()
for v in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!v:-}" ]; then
    MISSING+=("$v")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "[FAIL] Missing required env vars: ${MISSING[*]}"
  echo
  echo "Set them before running, e.g.:"
  echo "  export RUNNER_TEMP=/tmp"
  echo "  export PR_NUMBER=123"
  echo "  export REPO=owner/repo"
  echo "  export HEAD_SHA=\$(git rev-parse HEAD)"
  echo "  export GITHUB_TOKEN=ghp_xxx"
  echo "  export INPUT_PROVIDER=anthropic"
  echo "  export INPUT_EFFORT=medium"
  echo "  export ANTHROPIC_API_KEY=sk-ant-xxx   # must match INPUT_PROVIDER"
  echo
  echo "Then: bash tests/e2e.sh"
  exit 1
fi

if ! command -v ante >/dev/null 2>&1; then
  echo "[FAIL] ante binary not found on PATH. Run scripts/install-ante.sh first."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "[FAIL] gh CLI not found on PATH."
  exit 1
fi

export RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
export GITHUB_ACTION_PATH="$(pwd)"

echo "=== e2e ==="
echo "PR:      $REPO#$PR_NUMBER"
echo "SHA:     $HEAD_SHA"
echo "Provider: $INPUT_PROVIDER ($INPUT_EFFORT)"
echo "Temp:    $RUNNER_TEMP"
echo

bash scripts/review.sh
RC=$?

echo
echo "=== e2e complete (review.sh exit $RC) ==="
echo "Inspect:  $RUNNER_TEMP/ante_review.json  $RUNNER_TEMP/ante.out  $RUNNER_TEMP/ante.err"

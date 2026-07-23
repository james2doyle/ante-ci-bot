#!/usr/bin/env bash
set -euo pipefail
# post-comment.sh PR_NUMBER REPO HEAD_SHA PATH LINE SIDE BODY
# Posts a single line-anchored review comment via the GitHub REST API.
# gh pr comment has no --line/--path/--side/--commit, so review comments
# (a distinct object type) must go through gh api.
# POST /repos/{owner}/{repo}/pulls/{pull_number}/comments
# Returns exit 0 on skip (invalid input, non-blocking), exit 0 on success,
# exit 1 on API failure (caller logs the warning).

PR_NUMBER="$1"
REPO="$2"
HEAD_SHA="$3"
CPATH="$4"
CLINE="$5"
CSIDE="$6"
CBODY="$7"

# API requires path as a non-empty string, line as a positive integer that
# exists in the diff for commit_id (else 422), and a non-empty body.
# Skip invalid values non-blocking (exit 0 so the caller continues the loop).
if [ -z "$CPATH" ] || [ "$CPATH" = "null" ]; then
  echo "::warning::skipping comment: missing or null path"
  exit 0
fi
if ! [[ "$CLINE" =~ ^[0-9]+$ ]] || [ "$CLINE" -le 0 ]; then
  echo "::warning::skipping comment on $CPATH: invalid line '$CLINE'"
  exit 0
fi
if [ -z "$CBODY" ] || [ "$CBODY" = "null" ]; then
  echo "::warning::skipping comment on $CPATH:$CLINE: empty or null body"
  exit 0
fi
case "$CSIDE" in
  LEFT|RIGHT) ;;
  *) CSIDE="RIGHT" ;;
esac

# Capture gh api output and exit code. --silent suppresses success output;
# on failure, stderr contains the HTTP error body (e.g. 422 validation
# errors) which we surface to the workflow log for debugging.
API_ERR_FILE=$(mktemp)
trap 'rm -f "$API_ERR_FILE"' EXIT
set +e
gh api -X POST "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
  -f body="$CBODY" \
  -f commit_id="$HEAD_SHA" \
  -f path="$CPATH" \
  -F line="$CLINE" \
  -f side="$CSIDE" \
  --silent 2>"$API_ERR_FILE"
API_RC=$?
set -e

if [ "$API_RC" -ne 0 ]; then
  echo "::warning::gh api failed (exit $API_RC) for $CPATH:$CLINE"
  cat "$API_ERR_FILE" || true
  exit 1
fi

exit 0

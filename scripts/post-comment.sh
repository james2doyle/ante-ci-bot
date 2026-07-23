#!/usr/bin/env bash
set -euo pipefail
# post-comment.sh PR_NUMBER REPO HEAD_SHA PATH LINE SIDE BODY
# Posts a single line-anchored review comment via the GitHub REST API.
# gh pr comment has no --line/--path/--side/--commit, so review comments
# (a distinct object type) must go through gh api.
# POST /repos/{owner}/{repo}/pulls/{pull_number}/comments

PR_NUMBER="$1"
REPO="$2"
HEAD_SHA="$3"
CPATH="$4"
CLINE="$5"
CSIDE="$6"
CBODY="$7"

# API requires line as a positive integer that exists in the diff for
# commit_id (else 422). Skip invalid values non-blocking.
if ! [[ "$CLINE" =~ ^[0-9]+$ ]] || [ "$CLINE" -le 0 ]; then
  echo "::warning::skipping comment on $CPATH: invalid line '$CLINE'"
  exit 0
fi
case "$CSIDE" in
  LEFT|RIGHT) ;;
  *) CSIDE="RIGHT" ;;
esac

gh api -X POST "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
  -f body="$CBODY" \
  -f commit_id="$HEAD_SHA" \
  -f path="$CPATH" \
  -F line="$CLINE" \
  -f side="$CSIDE" \
  --silent

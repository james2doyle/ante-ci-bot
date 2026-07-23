#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.ante/bin:$PATH"

if ! command -v ante >/dev/null 2>&1; then
  echo "::warning::ante binary not found; skipping review"
  exit 0
fi

PR_NUMBER="${PR_NUMBER:?}"
HEAD_SHA="${HEAD_SHA:?}"
REPO="${REPO:?}"
MAX="${INPUT_MAX_DIFF_LINES:-4000}"
INPUT_PROVIDER="${INPUT_PROVIDER:-anthropic}"
INPUT_EFFORT="${INPUT_EFFORT:-medium}"

# RUNNER_TEMP is job-specific and auto-cleaned on GitHub Actions; fall back to
# /tmp for local/M0 testing where RUNNER_TEMP is unset.
TMP="${RUNNER_TEMP:-/tmp}"
DIFF_FILE="$TMP/pr.diff"
REVIEW_FILE="$TMP/ante_review.json"

# 1. Fetch the PR diff
if ! gh pr diff "$PR_NUMBER" --repo "$REPO" > "$DIFF_FILE"; then
  echo "::warning::failed to fetch diff"
  exit 0
fi
if [ "$(wc -l < "$DIFF_FILE")" -gt "$MAX" ]; then
  head -n "$MAX" "$DIFF_FILE" > "$DIFF_FILE.tmp" && mv "$DIFF_FILE.tmp" "$DIFF_FILE"
  printf '\n\n--- NOTE: diff truncated to %s lines for context limits. Review only the shown portion. ---\n' "$MAX" >> "$DIFF_FILE"
  echo "diff truncated to $MAX lines"
fi

# 2. Point ANTE_HOME at the action's bundled ante/ directory so ante discovers
#    the code-reviewer sub-agent, skills, and AGENTS.md in place — no copying
#    into ~/.ante/. The binary install location (ANTE_INSTALL_DIR) is separate
#    and handled by install-ante.sh. settings.json in this dir is read by ante,
#    but --provider/--effort are always passed below and override it; --model
#    overrides when INPUT_MODEL is set. model/provider were stripped from the
#    bundled settings.json so a non-anthropic provider uses its own default
#    model when INPUT_MODEL is empty.
export ANTE_HOME="${GITHUB_ACTION_PATH:-$(pwd)}/ante"

# 3. Run ante headless. yolo is implied in headless mode (no --yolo needed).
#    The main agent delegates the review to the code-reviewer sub-agent, which
#    reads the diff file and writes the review JSON. The diff path and review
#    path are passed explicitly in the delegation. No stdin piping needed — the
#    sub-agent reads the diff file directly. A custom prompt input, if provided,
#    is appended to focus the review. minimal stdout -> $TMP/ante.out (agent
#    messages, for log debugging only; does not affect the Write-tool file).
DELEGATION="Delegate the pull request review to the code-reviewer and security-reviewer sub-agents. The diff is at $DIFF_FILE. Tell the sub-agent to read it, review it, and write the review JSON to $REVIEW_FILE per its instructions."
if [ -n "${INPUT_PROMPT:-}" ]; then
  DELEGATION="$DELEGATION

Additional review focus from the caller:
$INPUT_PROMPT"
fi

ARGS=(--provider "$INPUT_PROVIDER" --effort "$INPUT_EFFORT"
      --no-session-save
      --output-format minimal
      --prompt "$DELEGATION")
[ -n "${INPUT_MODEL:-}" ] && ARGS+=(--model "$INPUT_MODEL")

rm -f "$REVIEW_FILE"
set +e
ante "${ARGS[@]}" < /dev/null > "$TMP/ante.out" 2> "$TMP/ante.err"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "::warning::ante exited $RC"
  cat "$TMP/ante.err" || true
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Ante review could not run (exit $RC). Check workflow logs." || true
  exit 0   # non-blocking
fi

# 4. Validate the review file ante wrote (sole source of truth)
if [ ! -f "$REVIEW_FILE" ] || ! jq empty "$REVIEW_FILE" 2>/dev/null; then
  echo "::warning::ante did not produce a valid $REVIEW_FILE"
  echo "::group::ante stderr"
  cat "$TMP/ante.err" || true
  echo "::endgroup::"
  echo "::group::ante stdout"
  cat "$TMP/ante.out" || true
  echo "::endgroup::"
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Ante ran but did not produce a structured review. See workflow logs." || true
  exit 0   # non-blocking
fi

# 5. Post summary (top-level PR issue comment). --edit-last --create-if-none
#    dedupes across re-pushes: edits the bot's last issue comment if present,
#    else creates.
SUMMARY_FILE="$TMP/ante_summary.md"
jq -r '.summary // ""' "$REVIEW_FILE" > "$SUMMARY_FILE"
if [ -s "$SUMMARY_FILE" ]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --edit-last --create-if-none --body-file "$SUMMARY_FILE" || true
fi

# 6. Post each line review comment via gh api (see post-comment.sh)
jq -c '.comments[]?' "$REVIEW_FILE" | while read -r c; do
  CPATH="$(printf '%s' "$c" | jq -r '.path')"
  CLINE="$(printf '%s' "$c" | jq -r '.line')"
  CSIDE="$(printf '%s' "$c" | jq -r '.side // "RIGHT"')"
  CBODY="$(printf '%s' "$c" | jq -r '.body')"
  "${GITHUB_ACTION_PATH:-$(pwd)}/scripts/post-comment.sh" \
    "$PR_NUMBER" "$REPO" "$HEAD_SHA" "$CPATH" "$CLINE" "$CSIDE" "$CBODY" \
    || echo "::warning::failed to post comment on $CPATH:$CLINE"
done

exit 0

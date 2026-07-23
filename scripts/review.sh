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
REVIEW_CODE="$TMP/ante_review_code.json"
REVIEW_SEC="$TMP/ante_review_sec.json"
REVIEW_COMMENTS="$TMP/ante_review_comments.json"

# 1. Fetch the PR diff
if ! gh pr diff "$PR_NUMBER" --repo "$REPO" > "$DIFF_FILE"; then
  echo "::warning::failed to fetch diff"
  exit 0
fi
DIFF_LINES=$(wc -l < "$DIFF_FILE")
echo "diff fetched: $DIFF_LINES lines"
if [ "$DIFF_LINES" -eq 0 ]; then
  echo "::warning::diff is empty; nothing to review"
  exit 0
fi
if [ "$DIFF_LINES" -gt "$MAX" ]; then
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
#    The main agent delegates the review to three sub-agents (code-reviewer,
#    security-reviewer, comment-reviewer), each writing its review JSON to a
#    separate per-agent file. The diff path and per-agent review paths are
#    passed explicitly in the delegation. No stdin piping needed — each
#    sub-agent reads the diff file directly. A custom prompt input, if
#    provided, is appended to focus the review. minimal stdout -> $TMP/ante.out
#    (agent messages, for log debugging only; does not affect the Write-tool
#    files). Per-agent files are merged into $REVIEW_FILE in step 4.
DELEGATION="Delegate the pull request review to three sub-agents. The diff is at $DIFF_FILE. Tell each sub-agent to read it, review it, and write its review JSON to its assigned path per its instructions. Each finding MUST be a separate line-anchored entry in comments[] — do not narrate findings in the summary field:
- code-reviewer: write to $REVIEW_CODE
- security-reviewer: write to $REVIEW_SEC
- comment-reviewer: write to $REVIEW_COMMENTS"
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

rm -f "$REVIEW_FILE" "$REVIEW_CODE" "$REVIEW_SEC" "$REVIEW_COMMENTS"
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

# 4. Merge per-agent review files into $REVIEW_FILE (sole source of truth).
#    Each sub-agent writes to its own file; we merge all that exist and are
#    valid into one. A missing file means that sub-agent produced no review —
#    non-blocking. Summaries are concatenated; comments are concatenated.
#    Each summary block and line-comment body is prefixed with its source
#    sub-agent's name (e.g. "**code-reviewer:** ...") so PR readers can tell
#    which agent produced each comment. Attribution is applied here, in the
#    merge, rather than in the sub-agent prompts, so it is always consistent.
ALL_REVIEW_FILES=("$REVIEW_CODE" "$REVIEW_SEC" "$REVIEW_COMMENTS")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  name="${ALL_REVIEW_NAMES[$i]}"
  if [ ! -f "$f" ]; then
    echo "$name: no review file produced"
    continue
  fi
  if ! jq empty "$f" 2>/dev/null; then
    echo "::warning::$name: review file is not valid JSON, skipping"
    continue
  fi
  # Schema check: comments must be an array (or absent); summary must be a
  # string (or absent). Log violations but still include the file — the merge
  # jq handles non-array comments safely via []? and non-string summaries via
  # select().
  CTYPE=$(jq -r '.comments | type' "$f" 2>/dev/null || echo "null")
  STYPE=$(jq -r '.summary | type' "$f" 2>/dev/null || echo "null")
  CCOUNT=$(jq '.comments | if type == "array" then length else 0 end' "$f" 2>/dev/null || echo 0)
  if [ "$CTYPE" != "array" ] && [ "$CTYPE" != "null" ]; then
    echo "::warning::$name: comments is $CTYPE (expected array); will be treated as empty"
  fi
  if [ "$STYPE" != "string" ] && [ "$STYPE" != "null" ]; then
    echo "::warning::$name: summary is $STYPE (expected string); will be omitted"
  fi
  echo "$name: $CCOUNT comment(s), summary=$STYPE"
  VALID_FILES+=("$f")
  VALID_NAMES+=("$name")
done

if [ "${#VALID_FILES[@]}" -eq 0 ]; then
  echo "::warning::ante did not produce any valid review files"
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

# Build a JSON array of the valid agents' names, parallel to the slurped
# review-file order, so the jq filter can prefix each summary block and
# comment body with its source agent name.
NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

if ! jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | select(.path != null and .path != "" and (.line // 0) > 0 and (.body // "") != "") | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE"; then
  echo "::warning::failed to merge review files"
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Ante review could not be merged. Check workflow logs." || true
  exit 0   # non-blocking
fi

# Warn if any comments were dropped by the merge filter (missing/null path,
# non-positive line, or empty body). Breaks down by reason so the workflow
# log shows exactly what the sub-agents got wrong.
DROPPED_PATH=$(jq -s '[.[].comments[]? | select(.path == null or .path == "")] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_LINE=$(jq -s '[.[].comments[]? | select((.line // 0) <= 0)] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_BODY=$(jq -s '[.[].comments[]? | select((.body // "") == "")] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_TOTAL=$((DROPPED_PATH + DROPPED_LINE + DROPPED_BODY))
if [ "$DROPPED_TOTAL" -gt 0 ]; then
  echo "::warning::dropped $DROPPED_TOTAL comment(s): path=$DROPPED_PATH line=$DROPPED_LINE body=$DROPPED_BODY"
fi

# 5. Post summary (top-level PR issue comment). --edit-last --create-if-none
#    dedupes across re-pushes: edits the bot's last issue comment if present,
#    else creates.
MERGED_COUNT=$(jq '.comments | length' "$REVIEW_FILE" 2>/dev/null || echo 0)
echo "merged: $MERGED_COUNT line comment(s) to post"
SUMMARY_FILE="$TMP/ante_summary.md"
jq -r '.summary // ""' "$REVIEW_FILE" > "$SUMMARY_FILE"
if [ -s "$SUMMARY_FILE" ]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --edit-last --create-if-none --body-file "$SUMMARY_FILE" || true
fi

# 6. Post each line review comment via gh api (see post-comment.sh).
#    Logs each attempt so the workflow log shows exactly what was posted
#    and what failed.
jq -c '.comments[]?' "$REVIEW_FILE" | while read -r c; do
  CPATH="$(printf '%s' "$c" | jq -r '.path')"
  CLINE="$(printf '%s' "$c" | jq -r '.line')"
  CSIDE="$(printf '%s' "$c" | jq -r '.side // "RIGHT"')"
  CBODY="$(printf '%s' "$c" | jq -r '.body')"
  if "${GITHUB_ACTION_PATH:-$(pwd)}/scripts/post-comment.sh" \
    "$PR_NUMBER" "$REPO" "$HEAD_SHA" "$CPATH" "$CLINE" "$CSIDE" "$CBODY"; then
    echo "posted: $CPATH:$CLINE ($CSIDE)"
  else
    echo "::warning::failed to post comment on $CPATH:$CLINE"
  fi
done

exit 0

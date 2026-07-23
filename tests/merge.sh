#!/usr/bin/env bash
set -euo pipefail

# Tests the jq merge logic from review.sh step 4 in isolation.
# Creates sample per-agent review files, runs the same jq -s merge command,
# and verifies summaries concatenate and comments merge correctly.
# Also verifies each summary block and line-comment body is prefixed with its
# source sub-agent name (attribution is applied in the merge, not by the LLM).
# Also tests the edge case where some agents produce no file (non-blocking).
# No credentials needed.

cd "$(dirname "$0")/.."

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

TMP="tests/tmp"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "=== merge ==="

# Case 1: all three agents produce reviews.
cat > "$TMP/ante_review_code.json" <<'EOF'
{"summary":"Code looks good overall.","comments":[{"path":"src/a.ts","line":10,"side":"RIGHT","severity":"warning","body":"off-by-one"}]}
EOF
cat > "$TMP/ante_review_sec.json" <<'EOF'
{"summary":"No security issues found.","comments":[]}
EOF
cat > "$TMP/ante_review_comments.json" <<'EOF'
{"summary":"Stale TODO on line 5.","comments":[{"path":"src/b.ts","line":5,"side":"RIGHT","severity":"info","body":"vague TODO"}]}
EOF

REVIEW_FILE="$TMP/ante_review.json"
ALL_REVIEW_FILES=("$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
    VALID_NAMES+=("${ALL_REVIEW_NAMES[$i]}")
  fi
done

[ "${#VALID_FILES[@]}" -eq 3 ] || fail "expected 3 valid files, got ${#VALID_FILES[@]}"
[ "${#VALID_NAMES[@]}" -eq 3 ] || fail "expected 3 valid names, got ${#VALID_NAMES[@]}"

NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge failed"

SUMMARY_COUNT=$(jq -r '.summary' "$REVIEW_FILE" | grep -c . || true)
[ "$SUMMARY_COUNT" -ge 3 ] || fail "expected >=3 summary lines, got $SUMMARY_COUNT"

COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 2 ] || fail "expected 2 comments, got $COMMENT_COUNT"

# Verify both comment paths are present.
jq -e '.comments[] | select(.path == "src/a.ts" and .line == 10)' "$REVIEW_FILE" >/dev/null \
  || fail "missing comment from code-reviewer"
jq -e '.comments[] | select(.path == "src/b.ts" and .line == 5)' "$REVIEW_FILE" >/dev/null \
  || fail "missing comment from comment-reviewer"

# Verify attribution: each summary block and comment body is prefixed with its
# source sub-agent name.
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*code-reviewer:\*\*' \
  || fail "summary missing code-reviewer prefix"
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*security-reviewer:\*\*' \
  || fail "summary missing security-reviewer prefix"
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*comment-reviewer:\*\*' \
  || fail "summary missing comment-reviewer prefix"
jq -e '.comments[] | select(.path == "src/a.ts" and (.body | startswith("**code-reviewer:** ")))' "$REVIEW_FILE" >/dev/null \
  || fail "code-reviewer comment body not prefixed"
jq -e '.comments[] | select(.path == "src/b.ts" and (.body | startswith("**comment-reviewer:** ")))' "$REVIEW_FILE" >/dev/null \
  || fail "comment-reviewer comment body not prefixed"

pass "merge with all 3 agents: summaries + comments merged with attribution"

# Case 2: only one agent produces a review (others missing — non-blocking).
rm -f "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json" "$REVIEW_FILE"

ALL_REVIEW_FILES=("$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
    VALID_NAMES+=("${ALL_REVIEW_NAMES[$i]}")
  fi
done

[ "${#VALID_FILES[@]}" -eq 1 ] || fail "expected 1 valid file, got ${#VALID_FILES[@]}"
[ "${#VALID_NAMES[@]}" -eq 1 ] || fail "expected 1 valid name, got ${#VALID_NAMES[@]}"
[ "${VALID_NAMES[0]}" = "code-reviewer" ] || fail "expected code-reviewer name, got ${VALID_NAMES[0]}"

NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with 1 file failed"

COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 1 ] || fail "expected 1 comment, got $COMMENT_COUNT"

# Attribution still applied when only one agent produced a review.
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*code-reviewer:\*\*' \
  || fail "single-agent summary missing code-reviewer prefix"
jq -e '.comments[] | select(.body | startswith("**code-reviewer:** "))' "$REVIEW_FILE" >/dev/null \
  || fail "single-agent comment body not prefixed"

pass "merge with 1 agent (2 missing): graceful, posts what exists with attribution"

# Case 3: all agents produce empty comments (clean PR).
cat > "$TMP/ante_review_code.json" <<'EOF'
{"summary":"Code looks good.","comments":[]}
EOF
cat > "$TMP/ante_review_sec.json" <<'EOF'
{"summary":"No security issues.","comments":[]}
EOF
cat > "$TMP/ante_review_comments.json" <<'EOF'
{"summary":"Comments look good.","comments":[]}
EOF

ALL_REVIEW_FILES=("$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
    VALID_NAMES+=("${ALL_REVIEW_NAMES[$i]}")
  fi
done

NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with empty comments failed"

COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 0 ] || fail "expected 0 comments on clean PR, got $COMMENT_COUNT"

# Clean PR still gets attributed summary blocks (no comments to attribute).
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*code-reviewer:\*\*' \
  || fail "clean-PR summary missing code-reviewer prefix"
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*security-reviewer:\*\*' \
  || fail "clean-PR summary missing security-reviewer prefix"
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*comment-reviewer:\*\*' \
  || fail "clean-PR summary missing comment-reviewer prefix"

pass "merge with clean PR (all comments empty): 0 comments, attributed summaries"

# Case 4: comments with missing/null path, invalid line, or empty body are
# filtered out.
cat > "$TMP/ante_review_code.json" <<'EOF'
{"summary":"Code review.","comments":[
  {"path":"src/a.py","line":10,"side":"RIGHT","severity":"warning","body":"valid"},
  {"path":null,"line":20,"side":"RIGHT","severity":"error","body":"null path"},
  {"line":30,"side":"RIGHT","severity":"info","body":"missing path key"},
  {"path":"","line":40,"side":"RIGHT","severity":"warning","body":"empty path"},
  {"path":"src/b.py","line":0,"side":"RIGHT","severity":"warning","body":"zero line"},
  {"path":"src/c.py","line":-5,"side":"RIGHT","severity":"error","body":"negative line"},
  {"path":"src/d.py","line":50,"side":"RIGHT","severity":"warning","body":""},
  {"path":"src/e.py","line":60,"side":"RIGHT","severity":"info"}
]}
EOF
cat > "$TMP/ante_review_sec.json" <<'EOF'
{"summary":"Security review.","comments":[]}
EOF
cat > "$TMP/ante_review_comments.json" <<'EOF'
{"summary":"Comment review.","comments":[]}
EOF

ALL_REVIEW_FILES=("$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
    VALID_NAMES+=("${ALL_REVIEW_NAMES[$i]}")
  fi
done

NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | select(.path != null and .path != "" and (.line // 0) > 0 and (.body // "") != "") | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with invalid comments failed"

# Only the valid comment (src/a.py:10) should survive; 7 invalid ones dropped.
COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 1 ] || fail "expected 1 valid comment after filter, got $COMMENT_COUNT"

jq -e '.comments[] | select(.path == "src/a.py" and .line == 10)' "$REVIEW_FILE" >/dev/null \
  || fail "valid comment was filtered out"

# Verify the per-reason dropped-count warning logic matches.
DROPPED_PATH=$(jq -s '[.[].comments[]? | select(.path == null or .path == "")] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_LINE=$(jq -s '[.[].comments[]? | select((.line // 0) <= 0)] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_BODY=$(jq -s '[.[].comments[]? | select((.body // "") == "")] | length' "${VALID_FILES[@]}" 2>/dev/null || echo 0)
DROPPED_TOTAL=$((DROPPED_PATH + DROPPED_LINE + DROPPED_BODY))
[ "$DROPPED_TOTAL" -eq 7 ] || fail "expected 7 dropped comments, got $DROPPED_TOTAL (path=$DROPPED_PATH line=$DROPPED_LINE body=$DROPPED_BODY)"

pass "merge filters comments with null/empty path, non-positive line, or empty body (1 kept, 7 dropped)"

# Case 5: schema violations — comments is not an array, summary is not a
# string. The merge jq handles these safely ([]? produces nothing for non-
# arrays; select() skips non-string summaries). Verify no crash and empty
# output for the malformed agent.
cat > "$TMP/ante_review_code.json" <<'EOF'
{"summary":"Code review.","comments":[{"path":"src/a.py","line":10,"side":"RIGHT","severity":"warning","body":"valid"}]}
EOF
cat > "$TMP/ante_review_sec.json" <<'EOF'
{"summary":42,"comments":"not an array"}
EOF
cat > "$TMP/ante_review_comments.json" <<'EOF'
{"summary":"Comment review.","comments":[{"path":"src/b.py","line":5,"side":"RIGHT","severity":"info","body":"ok"}]}
EOF

ALL_REVIEW_FILES=("$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json")
ALL_REVIEW_NAMES=("code-reviewer" "security-reviewer" "comment-reviewer")
VALID_FILES=()
VALID_NAMES=()
for i in "${!ALL_REVIEW_FILES[@]}"; do
  f="${ALL_REVIEW_FILES[$i]}"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
    VALID_NAMES+=("${ALL_REVIEW_NAMES[$i]}")
  fi
done

NAMES_JSON=$(printf '%s\n' "${VALID_NAMES[@]}" | jq -R . | jq -s .)

jq -s --argjson names "$NAMES_JSON" '
  {
    summary: [ range(0, length) as $i | .[$i] | select((.summary | type) == "string" and .summary != "") | "**\($names[$i]):**\n\n\(.summary)" ] | join("\n\n"),
    comments: [ range(0, length) as $i | .[$i] | .comments[]? | select(.path != null and .path != "" and (.line // 0) > 0 and (.body // "") != "") | .body = ("**\($names[$i]):** " + .body) ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with schema violations failed"

# security-reviewer had non-array comments (0 entries) and non-string summary
# (skipped). code-reviewer + comment-reviewer each had 1 valid comment.
COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 2 ] || fail "expected 2 comments with schema-violating agent, got $COMMENT_COUNT"

# security-reviewer's non-string summary (42) must NOT appear in the merged
# summary (select((.summary | type) == "string") skips numbers).
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*code-reviewer:\*\*' \
  || fail "summary missing code-reviewer prefix"
jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*comment-reviewer:\*\*' \
  || fail "summary missing comment-reviewer prefix"
# security-reviewer's summary was a number, so it should be absent.
! jq -r '.summary' "$REVIEW_FILE" | grep -q '\*\*security-reviewer:\*\*' \
  || fail "security-reviewer non-string summary should have been skipped"

pass "merge handles schema violations (non-array comments, non-string summary) without crash"

echo "=== merge complete ==="

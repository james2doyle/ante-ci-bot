#!/usr/bin/env bash
set -euo pipefail

# Tests the jq merge logic from review.sh step 4 in isolation.
# Creates sample per-agent review files, runs the same jq -s merge command,
# and verifies summaries concatenate and comments merge correctly.
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
VALID_FILES=()
for f in "$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json"; do
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
  fi
done

[ "${#VALID_FILES[@]}" -eq 3 ] || fail "expected 3 valid files, got ${#VALID_FILES[@]}"

jq -s '
  {
    summary: [ .[] | select(.summary != null and .summary != "") | .summary ] | join("\n\n"),
    comments: [ .[] | .comments[]? ]
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

pass "merge with all 3 agents: summaries + comments merged correctly"

# Case 2: only one agent produces a review (others missing — non-blocking).
rm -f "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json" "$REVIEW_FILE"

VALID_FILES=()
for f in "$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json"; do
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
  fi
done

[ "${#VALID_FILES[@]}" -eq 1 ] || fail "expected 1 valid file, got ${#VALID_FILES[@]}"

jq -s '
  {
    summary: [ .[] | select(.summary != null and .summary != "") | .summary ] | join("\n\n"),
    comments: [ .[] | .comments[]? ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with 1 file failed"

COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 1 ] || fail "expected 1 comment, got $COMMENT_COUNT"

pass "merge with 1 agent (2 missing): graceful, posts what exists"

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

VALID_FILES=()
for f in "$TMP/ante_review_code.json" "$TMP/ante_review_sec.json" "$TMP/ante_review_comments.json"; do
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    VALID_FILES+=("$f")
  fi
done

jq -s '
  {
    summary: [ .[] | select(.summary != null and .summary != "") | .summary ] | join("\n\n"),
    comments: [ .[] | .comments[]? ]
  }
' "${VALID_FILES[@]}" > "$REVIEW_FILE" || fail "jq merge with empty comments failed"

COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_FILE")
[ "$COMMENT_COUNT" -eq 0 ] || fail "expected 0 comments on clean PR, got $COMMENT_COUNT"

pass "merge with clean PR (all comments empty): 0 comments"

echo "=== merge complete ==="

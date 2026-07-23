#!/usr/bin/env bash
set -euo pipefail

# Verifies all ante/agents/*.md files follow project conventions:
# - frontmatter has name, description, tools
# - no hardcoded /tmp/ante_review path
# - required section headers present (## What to flag, ## What to skip, ## Output)
# - diff-source paragraph present
# - Write tool in frontmatter tools
# No credentials needed.

cd "$(dirname "$0")/.."

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

echo "=== agents ==="

AGENTS=(ante/agents/code-reviewer.md ante/agents/security-reviewer.md ante/agents/comment-reviewer.md)

for f in "${AGENTS[@]}"; do
  [ -f "$f" ] || fail "$f missing"
done
pass "all agent files exist"

# No hardcoded /tmp/ante_review paths anywhere in agent files.
if rg -q "/tmp/ante_review" ante/agents/; then
  fail "hardcoded /tmp/ante_review path found in ante/agents/"
fi
pass "no hardcoded /tmp/ante_review paths"

# Required section headers every agent must have.
REQUIRED_SECTIONS=("## What to flag" "## What to skip" "## Output")
for f in "${AGENTS[@]}"; do
  for s in "${REQUIRED_SECTIONS[@]}"; do
    rg -q "^${s}\$" "$f" || fail "$f missing section: $s"
  done
done
pass "all agents have required sections"

# Frontmatter: name, description, tools, and Write tool listed.
for f in "${AGENTS[@]}"; do
  rg -q "^name: " "$f" || fail "$f missing frontmatter: name"
  rg -q "^description: " "$f" || fail "$f missing frontmatter: description"
  rg -q "^tools:" "$f" || fail "$f missing frontmatter: tools"
  rg -q "^  - Write$" "$f" || fail "$f missing Write in frontmatter tools"
done
pass "all agents have valid frontmatter"

# Diff-source paragraph: each agent must reference the delegation-provided diff path.
for f in "${AGENTS[@]}"; do
  rg -q "path to a unified PR diff file is provided in your task delegation" "$f" \
    || fail "$f missing diff-source paragraph"
done
pass "all agents reference delegation-provided diff path"

# Delegation-provided review path: must not hardcode, must say "provided in your task delegation".
for f in "${AGENTS[@]}"; do
  rg -q "provided in your task" "$f" \
    || fail "$f must write to delegation-provided path, not a hardcoded one"
done
pass "all agents write to delegation-provided review path"

# Line-comment contract: findings must go in comments[], not summary prose.
for f in "${AGENTS[@]}"; do
  rg -q "One finding = one comments\[\] entry" "$f" \
    || fail "$f must enforce one-finding-per-comment rule"
  rg -q "Do NOT list individual findings" "$f" \
    || fail "$f must forbid narrating findings in summary"
  rg -q "path is REQUIRED" "$f" \
    || fail "$f must mark path as required on comments"
done
pass "all agents enforce line-comment contract"

echo "=== agents complete ==="

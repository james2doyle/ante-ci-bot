# Ante PR Review Bot — Implementation Plan

A composite GitHub Action (bash) that runs the [ante](https://ante.run/usage/headless) headless CLI to review a PR and post a summary plus file/line comments via `gh`.

## Repository layout

```text
ante-ci-bot/
├── action.yml                 # composite action definition + inputs
├── PLAN.md                    # this file
├── scripts/
│   ├── install-ante.sh        # idempotent ante install
│   ├── review.sh              # main orchestration
│   └── post-comment.sh        # posts one line comment via gh
└── README.md                  # usage (recommended)
```

## `action.yml`

```yaml
name: "Ante PR Review"
description: "AI code review via the ante headless CLI — posts a PR summary and file/line comments."
inputs:
  provider:
    description: "ante provider: anthropic | openai | gemini | xai | openrouter"
    required: false
    default: "anthropic"
  model:
    description: "Model override (optional; provider default if empty)"
    required: false
    default: ""
  effort:
    description: "Effort: min | low | medium | high | xhigh | max"
    required: false
    default: "medium"
  prompt:
    description: "Custom reviewer prompt (optional; built-in used if empty)"
    required: false
    default: ""
  max-diff-lines:
    description: "Truncate the diff beyond this many lines to avoid context overflow"
    required: false
    default: "4000"
  github-token:
    description: "Token for gh"
    required: false
    default: ${{ github.token }}
runs:
  using: "composite"
  steps:
    - name: Install ante
      shell: bash
      run: ${{ github.action_path }}/scripts/install-ante.sh
    - name: Run review
      shell: bash
      env:
        INPUT_PROVIDER: ${{ inputs.provider }}
        INPUT_MODEL: ${{ inputs.model }}
        INPUT_EFFORT: ${{ inputs.effort }}
        INPUT_PROMPT: ${{ inputs.prompt }}
        INPUT_MAX_DIFF_LINES: ${{ inputs.max-diff-lines }}
        GITHUB_TOKEN: ${{ inputs.github-token }}
        PR_NUMBER: ${{ github.event.pull_request.number }}
        HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        REPO: ${{ github.repository }}
      run: ${{ github.action_path }}/scripts/review.sh
```

Composite actions expose inputs as `INPUT_*` env vars (consumed in `review.sh`). `GITHUB_ACTION_PATH` is auto-set for composite steps (used to locate `post-comment.sh`).

## `scripts/install-ante.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.ante/bin:$PATH"
if command -v ante >/dev/null 2>&1; then
  echo "ante already installed: $(ante --version 2>/dev/null || echo unknown)"
  exit 0
fi
# Install to a stable, PATH-visible location on the runner
export ANTE_INSTALL_DIR="$HOME/.ante/bin"
curl -fsSL https://ante.run/install.sh | bash
echo "ante installed: $(ante --version 2>/dev/null || echo unknown)"
```

## `scripts/review.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.ante/bin:$PATH"

if ! command -v ante >/dev/null 2>&1; then
  echo "::warning::ante binary not found; skipping review"; exit 0
fi

PR_NUMBER="${PR_NUMBER:?}"
HEAD_SHA="${HEAD_SHA:?}"
REPO="${REPO:?}"
MAX="${INPUT_MAX_DIFF_LINES:-4000}"
REVIEW_FILE=/tmp/ante_review.json

# 1. Fetch the PR diff
if ! gh pr diff "$PR_NUMBER" --repo "$REPO" > /tmp/pr.diff; then
  echo "::warning::failed to fetch diff"; exit 0
fi
if [ "$(wc -l < /tmp/pr.diff)" -gt "$MAX" ]; then
  head -n "$MAX" /tmp/pr.diff > /tmp/pr.diff.tmp && mv /tmp/pr.diff.tmp /tmp/pr.diff
  echo "diff truncated to $MAX lines"
fi

# 2. Resolve prompt (custom or built-in)
PROMPT_FILE=/tmp/review_prompt.md
if [ -n "${INPUT_PROMPT:-}" ]; then
  printf '%s' "$INPUT_PROMPT" > "$PROMPT_FILE"
else
  cat > "$PROMPT_FILE" <<'PROMPT_EOF'
You are a senior code reviewer. The pull request diff is supplied on stdin.
You MAY read repository files with the Read/Glob/Grep tools to verify context and
to obtain the EXACT absolute line number in the NEW version of each file (RIGHT side).

After reviewing, write your review as a JSON file to exactly this path:
/tmp/ante_review.json

The file must contain a single JSON object (no markdown, no prose) matching:
{
  "summary": "Concise markdown summary of the changes and overall assessment.",
  "comments": [
    {
      "path": "relative/path/to/file",
      "line": 123,
      "side": "RIGHT",
      "severity": "info|warning|error",
      "body": "Clear description of the issue plus a concrete suggested improvement."
    }
  ]
}

Rules:
- Only comment on lines present in the diff (changed or context lines, RIGHT side).
- Use absolute line numbers as they appear in the new file.
- Keep each body focused, actionable, and include a concrete suggestion.
- If no issues, write {"summary": "...", "comments": []}.
- Write ONLY to /tmp/ante_review.json. Do not modify any other files.
PROMPT_EOF
fi

# 3. Run ante headless. All tools are allowed (headless implies yolo, so no
#    approvals). ante writes the review JSON to the temp file per the prompt.
ARGS=(--provider "$INPUT_PROVIDER" --effort "$INPUT_EFFORT"
      --no-session-save --yolo
      --output-format json
      --prompt "$(cat "$PROMPT_FILE")")
[ -n "${INPUT_MODEL:-}" ] && ARGS+=(--model "$INPUT_MODEL")

rm -f "$REVIEW_FILE"
set +e
ante "${ARGS[@]}" < /tmp/pr.diff > /tmp/ante.jsonl 2> /tmp/ante.err
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "::warning::ante exited $RC"
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "⚠️ Ante review could not run (exit $RC). Check workflow logs." || true
  exit 0   # non-blocking
fi

# 4. Validate the review file ante wrote
if [ ! -f "$REVIEW_FILE" ] || ! jq empty "$REVIEW_FILE" 2>/dev/null; then
  echo "::warning::ante did not produce a valid $REVIEW_FILE"; cat /tmp/ante.err; exit 0
fi

# 5. Post summary (top-level PR comment)
SUMMARY="$(jq -r '.summary // ""' "$REVIEW_FILE")"
if [ -n "$SUMMARY" ]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$SUMMARY" || true
fi

# 6. Post each line comment via post-comment.sh
jq -c '.comments[]?' "$REVIEW_FILE" | while read -r c; do
  CPATH="$(echo "$c" | jq -r '.path')"
  CLINE="$(echo "$c" | jq -r '.line')"
  CSIDE="$(echo "$c" | jq -r '.side // "RIGHT"")"
  CBODY="$(echo "$c" | jq -r '.body')"
  "$GITHUB_ACTION_PATH/scripts/post-comment.sh" \
    "$PR_NUMBER" "$REPO" "$HEAD_SHA" "$CPATH" "$CLINE" "$CSIDE" "$CBODY" \
    || echo "::warning::failed to post comment on $CPATH:$CLINE"
done

exit 0
```

## `scripts/post-comment.sh`

Called once per comment by `review.sh`. Takes positional args and posts a single line comment via `gh`.

```bash
#!/usr/bin/env bash
set -euo pipefail
# post-comment.sh PR_NUMBER REPO HEAD_SHA PATH LINE SIDE BODY
PR_NUMBER="$1"
REPO="$2"
HEAD_SHA="$3"
CPATH="$4"
CLINE="$5"
CSIDE="$6"
CBODY="$7"
gh pr comment "$PR_NUMBER" --repo "$REPO" \
  --body "$CBODY" --commit "$HEAD_SHA" \
  --path "$CPATH" --line "$CLINE" --side "$CSIDE"
```

## Review flow

All tools are allowed (headless implies yolo, so no approvals). ante is instructed to write its review as a single JSON object to `/tmp/ante_review.json` via the `Write` tool. The action treats that file as the source of truth:

1. `review.sh` validates the file exists and is valid JSON (`jq empty`).
2. Posts the `summary` as a top-level PR comment.
3. Loops `jq -c '.comments[]?'` and calls `scripts/post-comment.sh` per comment.

The runner is ephemeral and the action never commits/pushes, so any side effects of the full tool set are contained to the job; the prompt keeps ante focused on the review file.

## Consuming workflow (`.github/workflows/ante-review.yml`)

```yaml
name: Ante Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - uses: ./.github/actions/ante-review   # or: uses: your-org/ante-ci-bot@v1
        with:
          provider: anthropic
          effort: medium
          github-token: ${{ secrets.GITHUB_TOKEN }}
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Provider secret mapping (ante reads from env; action stays provider-agnostic):
- `anthropic` → `ANTHROPIC_API_KEY`
- `openai` → `OPENAI_API_KEY`
- `gemini` → `GEMINI_API_KEY` (verify exact name in ante providers docs)
- `xai` → `XAI_API_KEY`
- `openrouter` → `OPENROUTER_API_KEY`

## Milestones

- [ ] **M0 — Verify ante `Write` tool.** Run locally:
  `ante --yolo -p 'write {"ok":true} to /tmp/ante_review.json using the Write tool'`
  Confirm ante can create the file (all tools are allowed in headless/yolo, so no `--include-tools` needed). This gates the file-based flow.
- [ ] **M1 — Scaffold files** (`action.yml`, `scripts/*`) per the sections above.
- [ ] **M2 — Local dry run** of `review.sh` against a sample diff file (mock `gh` or use a real PR) to validate file handling + `jq` loop.
- [ ] **M3 — Wire workflow** + set the provider secret; run on a test PR.
- [ ] **M4 — Validate line-comment anchoring**: confirm `gh pr comment --line/--path/--side` posts on the correct RIGHT-side lines; fix any off-by-one from diff→file mapping.
- [ ] **M5 — Docs**: README with inputs table, secret requirements, and the fork-PR caveat below.

## Risks & mitigations

- **Diff→absolute line mapping.** `gh pr comment --line` needs the line number in the new file. Mitigation: ante runs in the checked-out PR workspace, so it reads real files for exact numbers; prompt restricts comments to diff lines. If a posted line is invalid, `gh` fails and we skip (non-blocking).
- **Fork PRs.** `actions/checkout` of `head.sha` fails for untrusted forks. Mitigation: for external contributions use `pull_request_target` (with the security trade-off of running in the base context) or restrict the workflow to trusted PRs; document clearly.
- **Comment spam on `synchronize`.** Every push re-posts comments. Mitigation (v1): accept it; future: post summary as an edited bot comment or dedupe by marker.
- **Large diffs / context overflow.** Mitigation: `max-diff-lines` truncation (default 4000) + note in summary that the diff was truncated.
- **ante auth/network failure.** Mitigation: non-zero exit posts a warning comment and exits 0 (never blocks the PR).
- **ante does not write the file.** If ante ignores the instruction, `/tmp/ante_review.json` is missing/invalid. Mitigation: step 4 validates with `jq empty` and exits 0 (non-blocking) with a warning.
- **Full tool set.** Headless implies yolo, so all tools run without approval. Mitigation: ephemeral runner + no commit + prompt guard keeps side effects contained to the job.
- **Provider secret name.** Gemini/xai/openrouter env var names should be confirmed against `ante` providers docs before publishing.

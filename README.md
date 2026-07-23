# Ante PR Review

A composite GitHub Action that runs the [ante](https://ante.run) headless CLI to review pull requests and posts:

- a **summary** as a top-level PR comment (deduped across re-pushes), and
- **line-anchored review comments** on specific files/lines via the GitHub REST API.

The review is performed by three bundled sub-agents (in `ante/agents/`) that each read the PR diff, review it from their own angle, and write a structured JSON review. `review.sh` merges the per-agent reviews into one file and posts it with `gh`. The action is **non-blocking**: any ante/API failure posts a warning comment and exits 0 so it never breaks a PR pipeline.

## Usage

Drop the action into your repo (e.g. `.github/actions/ante-review`) or reference it from a published release, then add a workflow:

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
    # Skip fork PRs: GITHUB_TOKEN is read-only and secrets are unavailable on
    # forks, so the provider API key can't be accessed. See "Fork PRs" below.
    if: github.event.pull_request.head.repo.full_name == github.repository
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - uses: james2doyle/ante-ci-bot@v1
        with:
          provider: openrouter
          effort: medium
          github-token: ${{ secrets.GITHUB_TOKEN }}
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
```

## Inputs

| Input             | Required | Default          | Description                                                                 |
|-------------------|----------|------------------|-----------------------------------------------------------------------------|
| `provider`        | no       | `openrouter`      | ante provider: `anthropic`, `openai`, `gemini`, `xai`, `openrouter`, `openai-compatible` |
| `model`           | no       | `tencent/hy3`             | Model override. Empty = provider default.                                   |
| `effort`          | no       | `medium`         | `min` / `low` / `medium` / `high` / `xhigh` / `max`                         |
| `max-diff-lines`  | no       | `4000`           | Truncates the diff beyond this many lines to avoid context overflow.        |

## Provider secrets

ante reads the provider API key from an environment variable. Set the matching secret in your repo and pass it via `env:` on the step. The action itself is provider-agnostic.

| Provider            | Environment variable              |
|---------------------|-----------------------------------|
| `anthropic`         | `ANTHROPIC_API_KEY`               |
| `openai`            | `OPENAI_API_KEY`                  |
| `gemini`            | `GEMINI_API_KEY` (or `VERTEX_GEMINI_API_KEY` for Vertex AI) |
| `xai`               | `XAI_API_KEY`                     |
| `openrouter`        | `OPENROUTER_API_KEY`              |
| `openai-compatible` | `OPENAI_COMPATIBLE_API_KEY`       |

Example with OpenAI:

```yaml
      - uses: ./.github/actions/ante-review
        with:
          provider: openai
          model: gpt-4o
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
```

## How it works

1. `install-ante.sh` runs the official ante installer (idempotent; skips if `ante` is already on PATH).
2. `review.sh` fetches the PR diff with `gh pr diff`, truncates it to `max-diff-lines` if needed, and sets `ANTE_HOME` to the action's bundled `ante/` directory so ante discovers the sub-agents, skills, and global `AGENTS.md` in place — no file copying.
3. ante runs headless with `--output-format minimal`. The main agent delegates to three sub-agents (`code-reviewer`, `security-reviewer`, `comment-reviewer`), each reading the diff and writing its own review JSON to a per-agent file under `$RUNNER_TEMP`. `review.sh` merges those files with `jq` into `$RUNNER_TEMP/ante_review.json` — the **sole source of truth**.
4. `review.sh` posts the merged `summary` as a PR issue comment (`gh pr comment --edit-last --create-if-none` so re-pushes edit instead of spamming), then loops over `comments[]` and calls `post-comment.sh` per comment.
5. `post-comment.sh` posts each line-anchored review comment via `gh api -X POST repos/{owner}/{repo}/pulls/{n}/comments` (`gh pr comment` has no `--line/--path/--side/--commit` flags).

All temp files live under `RUNNER_TEMP` (job-specific, auto-cleaned). The runner is ephemeral and the action never commits or pushes. Headless mode implies yolo (all tools auto-approved for the main agent), but each sub-agent restricts its own tools to `Read`/`Grep`/`Glob`/`Write` via its frontmatter, and the prompt guard (write only to the assigned review JSON path) plus the ephemeral runner contain side effects to the job.

## Fork PRs

The workflow's `if: github.event.pull_request.head.repo.full_name == github.repository` guard skips fork PRs because:

- `GITHUB_TOKEN` is read-only on forks, so the bot can't post comments.
- Repo secrets (the provider API key) are unavailable on forks.

For external contributions you can switch the trigger to `pull_request_target`, which runs in the base repo context with write access and secrets. **This has a security trade-off**: `pull_request_target` runs workflow code from the base branch (not the PR head), but if you explicitly check out the PR head and run arbitrary code from it, you can be exposed to a malicious PR. This action only reads a diff file and never executes PR-controlled code, so `pull_request_target` is safe here — but if you add steps that run PR-sourced code, gate them carefully.

## Behavior notes

- **Non-blocking.** Any ante exit, missing review file, or API failure posts a warning comment and exits 0. The action never fails the job.
- **Comment dedup.** The summary is edited in place across re-pushes via `--edit-last --create-if-none`. Line review comments are not deduped in v1 and will accumulate on re-push; a future version may submit a grouped review via `POST .../pulls/n/reviews`.
- **Line anchoring.** The GitHub API returns 422 if `line` is not in the diff for `commit_id`. The sub-agent is instructed to comment only on diff lines using absolute line numbers from the checked-out PR head; `post-comment.sh` validates the line is a positive integer and the loop skips any 422 (non-blocking).
- **Diff truncation.** When the diff exceeds `max-diff-lines`, it is truncated and a marker is appended so the model knows the picture is incomplete.

## Testing

Test scripts live in `tests/`. Run the safe ones together (no credentials needed):

```bash
bash tests/run-all.sh          # lint + agents + merge
```

Or run individually:

### Lint and syntax checks

```bash
bash tests/lint.sh
```

Runs `shellcheck scripts/*.sh`, `bash -n scripts/*.sh`, and `jq empty ante/settings.json`.

### Agent file conventions

```bash
bash tests/agents.sh
```

Verifies every `ante/agents/*.md` file: frontmatter has `name`/`description`/`tools` with `Write` listed, required section headers present (`## What to flag`, `## What to skip`, `## Output`), diff-source paragraph present, no hardcoded `/tmp/ante_review` paths, and review path is delegation-provided.

### jq merge logic

```bash
bash tests/merge.sh
```

Tests the `jq -s` merge from `review.sh` step 4 in isolation using sample per-agent files under `tests/tmp/` (auto-cleaned). Covers three cases: all three agents produce reviews, only one produces a review (others missing — non-blocking), and a clean PR (all comments empty).

### End-to-end local run

```bash
bash tests/e2e.sh
```

Runs `review.sh` against a real PR. Requires `ante` on PATH, `gh` authenticated, and the env vars the action injects. The script checks for required vars and exits with guidance if any are missing:

```bash
export RUNNER_TEMP=/tmp
export PR_NUMBER=123
export REPO=owner/repo
export HEAD_SHA=$(git rev-parse HEAD)
export GITHUB_TOKEN=ghp_xxx
export INPUT_PROVIDER=anthropic
export INPUT_EFFORT=medium
export ANTHROPIC_API_KEY=sk-ant-xxx   # must match INPUT_PROVIDER
bash tests/e2e.sh
```

This fetches the real PR diff, runs ante headless, merges the per-agent reviews, and **posts comments to the PR** — point it at a test repo. Inspect `$RUNNER_TEMP/ante_review.json` and `$RUNNER_TEMP/ante.out` / `ante.err` for debugging.

## Repository layout

```text
ante-ci-bot/
├── ante/                          # bundled ante config (used via ANTE_HOME)
│   ├── AGENTS.md                  # global instructions
│   ├── settings.json              # ante settings (model/provider stripped)
│   ├── skills/review/SKILL.md     # review skill
│   └── agents/
│       ├── code-reviewer.md       # correctness, logic, perf, API, tests
│       ├── security-reviewer.md   # security vulnerabilities (OWASP)
│       └── comment-reviewer.md    # comment accuracy, stale docs, TODOs
├── action.yml                     # composite action definition + inputs
├── scripts/
│   ├── install-ante.sh            # idempotent ante install
│   ├── review.sh                  # main orchestration
│   └── post-comment.sh            # posts one line review comment via gh api
├── AGENTS.md                      # project Agent file
└── README.md                      # this file
```

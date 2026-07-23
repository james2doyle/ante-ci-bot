# AGENTS.md — ante-ci-bot

Composite GitHub Action that runs the [ante](https://ante.run) headless CLI to review PRs and posts a summary comment + line-anchored review comments via `gh`. Bash + YAML + Markdown. No build step, no test framework.

IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for GitHub Actions composite actions and the ante CLI. Check `ante --help` or https://ante.run/docs before assuming CLI behavior.

## Two AGENTS.md files — do not confuse

| File                       | Audience                  | Purpose                                              |
| :------------------------- | :------------------------ | :-------------------------------------------------- |
| `./AGENTS.md` (this file)  | Agents editing the action | Repo conventions, contracts, workflows              |
| `./ante/AGENTS.md`         | The ante runtime at review time | Global preferences injected into the review agent |

Never edit `ante/AGENTS.md` to change this repo's agent behavior — it changes what the PR-review bot says to PR authors.

## Repository layout

```text
action.yml                  # composite action: inputs + 2 steps (install, review)
scripts/
  install-ante.sh           # idempotent ante installer (curl https://ante.run/install.sh)
  review.sh                 # main orchestration: diff -> ante -> JSON -> post comments
  post-comment.sh           # posts ONE line-anchored comment via gh api
ante/                       # bundled ante config (consumed via ANTE_HOME at review time)
  AGENTS.md                 # review-time global preferences (NOT this repo's instructions)
  settings.json             # ante settings — model/provider intentionally stripped
  agents/code-reviewer.md   # sub-agent that writes the review JSON
  agents/security-reviewer.md
  skills/review/SKILL.md
```

## The core contract: review JSON

`$REVIEW_FILE` (`$RUNNER_TEMP/ante_review.json`) is the **sole source of truth**. `review.sh` validates it with `jq` and posts from it. The sub-agent writes it via the `Write` tool.

```json
{
  "summary": "markdown — what the PR does + overall assessment",
  "comments": [
    { "path": "relative/path", "line": 123, "side": "RIGHT",
      "severity": "info|warning|error", "body": "issue + impact + concrete fix" }
  ]
}
```

Schema rules: `line` is a positive integer in the NEW file (RIGHT side, absolute); `side` is `LEFT` or `RIGHT` (default `RIGHT`); empty `comments` array when the PR is clean.

## Non-blocking is sacred

Every failure path posts a `::warning::`, a warning PR comment, and `exit 0`. The action must never fail a PR pipeline.

| Failure                  | Response                                  |
| :----------------------- | :---------------------------------------- |
| ante binary missing      | `::warning::` + `exit 0`                  |
| `gh pr diff` fails       | `::warning::` + `exit 0`                  |
| ante exits non-zero      | warning PR comment + `exit 0`             |
| review JSON missing/invalid | warning PR comment + `exit 0`          |
| a line comment 422s      | `::warning::`, continue loop              |

## Procedural workflows

### Add a new action input

1. Declare it in `action.yml` under `inputs:` with `required`, `default`.
2. Forward it in the `Run review` step's `env:` as `INPUT_<NAME>: ${{ inputs.<name> }}`.
3. Read it in `review.sh` with `INPUT_<NAME>="${INPUT_<NAME>:-<default>}"` near the other `INPUT_*` reads (around line 13-15).
4. Consume it in the ante `ARGS=(...)` array (line ~59-63) or the `DELEGATION` string (line ~51).

### Add a new ante sub-agent

1. Create `ante/agents/<name>.md` with frontmatter `name`, `description`, `tools:` (restrict to the minimum needed — see `code-reviewer.md`).
2. The sub-agent must write its review JSON to the path passed in its delegation. Do NOT hardcode `/tmp/ante_review.json` — `security-reviewer.md` does this and is a known inconsistency.
3. Wire it into `review.sh` by editing the `DELEGATION` string, or expose it via a skill in `ante/skills/<name>/SKILL.md`.

### Add a new review skill

1. Create `ante/skills/<name>/SKILL.md` with frontmatter `name`, `description`, optional `argument-hint`.
2. Skills are discovered automatically via `ANTE_HOME` — no wiring needed.

## Dos and Don'ts

- **Don't** add `model` or `provider` to `ante/settings.json`. **Do** pass them via `--provider` / `--model` CLI flags in `review.sh` (`ARGS=(...)`, line ~59-63) so per-run inputs control them.
- **Don't** use `gh pr comment` for line-anchored review comments — it has no `--line/--path/--side/--commit` flags. **Do** use `gh api -X POST repos/{owner}/{repo}/pulls/{n}/comments` via `post-comment.sh`.
- **Don't** write temp files outside `RUNNER_TEMP`. **Do** use `TMP="${RUNNER_TEMP:-/tmp}"` and place all temp files under `$TMP`.
- **Don't** fail the job on ante/API errors. **Do** post a `::warning::` + warning PR comment, then `exit 0`.
- **Don't** pipe the diff via stdin to ante. **Do** pass the diff file path in the `DELEGATION` string; the sub-agent reads it with `Read`.

## Conventions

- All shell scripts: `#!/usr/bin/env bash` + `set -euo pipefail`.
- Use `gh` for every GitHub API call. Never `curl` the API directly.
- Summary comment dedupes via `gh pr comment --edit-last --create-if-none`. Line comments are NOT deduped in v1 (will accumulate on re-push).
- `ANTE_HOME` (config dir, points at bundled `ante/`) is separate from `ANTE_INSTALL_DIR` (binary location, `$HOME/.ante/bin`). Don't conflate them.
- Headless mode implies yolo (all tools auto-approved for the main agent). Sub-agents restrict their own tools via frontmatter `tools:`.
- Comments in shell scripts explain non-obvious GitHub Actions / ante behavior (e.g., why `gh api` not `gh pr comment`, `RUNNER_TEMP` semantics). Keep this convention; don't strip them.

## Verifying changes

No test suite. To validate edits:

```bash
shellcheck scripts/*.sh          # lint (if installed)
bash -n scripts/*.sh             # syntax check
jq empty ante/settings.json      # settings valid
```

For an end-to-end local run, set `RUNNER_TEMP=/tmp`, `PR_NUMBER`, `REPO`, `HEAD_SHA`, `GITHUB_TOKEN`, and the `INPUT_*` vars, then `GITHUB_ACTION_PATH=$(pwd) bash scripts/review.sh` from the repo root.

## Further reading

- `README.md` — human-facing docs (usage, inputs table, provider secrets, fork-PR security notes). Read it when modifying user-facing behavior or the workflow example.

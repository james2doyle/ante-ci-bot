# AGENTS.md — ante-ci-bot

Composite GitHub Action that runs the [ante](https://ante.run) headless CLI to review PRs and posts a summary comment + line-anchored review comments via `gh`. Bash + YAML + Markdown. No build step; tests are shell scripts under `tests/`.

IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for GitHub Actions composite actions and the ante CLI. Check `ante --help` or https://ante.run/docs before assuming CLI behavior.

## Two AGENTS.md files — do not confuse

| File                       | Audience                  | Purpose                                              |
| :------------------------- | :------------------------ | :-------------------------------------------------- |
| `./AGENTS.md` (this file)  | Agents editing the action | Repo conventions, contracts, workflows              |
| `./ante/AGENTS.md`         | The ante runtime at review time | Global preferences injected into the review agent |

Never edit `ante/AGENTS.md` to change this repo's agent behavior — it changes what the PR-review bot says to PR authors.

## Repository layout

```text
[Docs Index]|root: .
|action.yml
|scripts/  :{install-ante.sh, review.py, post_comment.py, review_core.py}
|tests/   :{test_lint.py, test_agents.py, test_merge.py, test_post_comment.py, e2e.py, run_all.py}
|pyproject.toml
|ante/    :{AGENTS.md, settings.json, agents/*.md, skills/review/SKILL.md}
```

## The core contract: review JSON

`$REVIEW_FILE` (`$RUNNER_TEMP/ante_review.json`) is the **sole source of truth**. `review.sh` merges per-agent review files into it with `jq` and posts from it. Each sub-agent writes its own file (`$REVIEW_CODE`, `$REVIEW_SEC`, `$REVIEW_COMMENTS`) via the `Write` tool; `review.sh` step 4 merges all that exist into `$REVIEW_FILE`. The merge prefixes each summary block and line-comment body with its source sub-agent's name (e.g. `**code-reviewer:** ...`) so PR readers can tell which agent produced each comment. Attribution is applied in the merge, not by the sub-agents, so it is always consistent — do not add prefixes in the sub-agent prompts.

```json
{
  "summary": "markdown — what the PR does + overall assessment",
  "comments": [
    { "path": "relative/path", "line": 123, "side": "RIGHT",
      "severity": "info|warning|error", "body": "issue + impact + concrete fix" }
  ]
}
```

Schema rules: `line` is the head-file line number — a positive integer in the NEW file (RIGHT side, absolute), obtained by Reading the actual source file (not by counting diff lines); `side` is `LEFT` or `RIGHT` (default `RIGHT`); empty `comments` array when the PR is clean.

## Existing comments dedup

`review.py` fetches existing PR review comments via `gh api` before running ante and writes them to `$RUNNER_TEMP/ante_existing_comments.json` as a JSON array of `{path, line, body}`. This file is passed to each sub-agent via the delegation string. Each sub-agent reads it and skips findings whose `path + line + body` exactly matches an existing comment — preventing accumulation across re-runs on the same PR.

The file is always valid JSON — `[]` when there are no existing comments or on fetch failure (non-blocking). Sub-agents are instructed to proceed without dedup if the file is missing or empty.

Within-run dedup (two sub-agents flagging the same issue) is handled separately by the merge step in `review_core.py`.

## Non-blocking is sacred

Every failure path posts a `::warning::`, a warning PR comment, and `exit 0`. The action must never fail a PR pipeline.

| Failure                  | Response                                  |
| :----------------------- | :---------------------------------------- |
| ante binary missing      | `::warning::` + `exit 0`                  |
| `gh pr diff` fails       | `::warning::` + `exit 0`                  |
| ante exits non-zero      | warning PR comment + `exit 0`             |
| all per-agent review files missing/invalid | warning PR comment + `exit 0` |
| a line comment 422s      | `::warning::`, continue loop              |

## Procedural workflows

### Add a new action input

1. Declare it in `action.yml` under `inputs:` with `required`, `default`.
2. Forward it in the `Run review` step's `env:` as `INPUT_<NAME>: ${{ inputs.<name> }}`.
3. Read it in `review.py` with `env("INPUT_<NAME>", "<default>")` near the other env reads.
4. Consume it in `build_ante_args()` or `build_delegation()`.

```python
# review.py — env reads block
ANTE_EFFORT   = env("INPUT_EFFORT", "quick")
NEW_INPUT     = env("INPUT_NEW_INPUT", "default_value")
```

### Add a new ante sub-agent

1. Create `ante/agents/<name>.md` with frontmatter `name`, `description`, `tools:` (restrict to the minimum needed — see `code-reviewer.md`).
2. The sub-agent must write its review JSON to the path passed in its delegation. Do NOT hardcode `/tmp/ante_review.json`.

```yaml
# ante/agents/<name>.md frontmatter
---
name: <name>-reviewer
description: Reviews PRs for <focus area>
tools: [Read, Write]
---
```

3. Wire it into `review.py`: add the sub-agent + path to the `review_files` dict in `main()`, add the file (and its display name) to the `files` / `names` lists passed to `load_agent_reviews()` and `merge_reviews()` so its summary and comments get attributed. Alternatively, expose it via a skill in `ante/skills/<name>/SKILL.md`.

### Add a new review skill

1. Create `ante/skills/<name>/SKILL.md` with frontmatter `name`, `description`, optional `argument-hint`.
2. Skills are discovered automatically via `ANTE_HOME` — no wiring needed.

## Dos and Don'ts

- **Don't** add `model` or `provider` to `ante/settings.json`. **Do** pass them via `--provider` / `--model` CLI flags in `review.py` (`build_ante_args()`, line ~120-130) so per-run inputs control them.
- **Don't** use `gh pr comment` for line-anchored review comments — it has no `--line/--path/--side/--commit` flags. **Do** use `gh api -X POST repos/{owner}/{repo}/pulls/{n}/comments` via `post_comment.py`.
- **Don't** write temp files outside `RUNNER_TEMP`. **Do** use `TMP="${RUNNER_TEMP:-/tmp}"` and place all temp files under `$TMP`.
- **Don't** fail the job on ante/API errors. **Do** post a `::warning::` + warning PR comment, then `exit 0`.
- **Don't** pipe the diff via stdin to ante. **Do** pass the diff file path in the `DELEGATION` string; the sub-agent reads it with `Read`.

## Conventions

- All shell scripts: `#!/usr/bin/env bash` + `set -euo pipefail`.
- Python scripts: `#!/usr/bin/env python3`, stdlib only, plain `assert` in tests.
- Use `gh` for every GitHub API call. Never `curl` the API directly.
- Summary comment dedupes via `gh pr comment --edit-last --create-if-none`. Line comments dedupe across runs via `ante_existing_comments.json` (fetched before ante runs and passed to each sub-agent).
- `ANTE_HOME` (config dir, points at bundled `ante/`) is separate from `ANTE_INSTALL_DIR` (binary location, `$HOME/.ante/bin`). Don't conflate them.
- Headless mode implies yolo (all tools auto-approved for the main agent). Sub-agents restrict their own tools via frontmatter `tools:`.
- Comments in Python scripts explain non-obvious GitHub Actions / ante behavior (e.g., why `gh api` not `gh pr comment`, `RUNNER_TEMP` semantics). Keep this convention; don't strip them.
- Scratch/throwaway files created while developing or ad-hoc testing must live under `tests/tmp/` (auto-cleaned by `tests/test_merge.py`'s `tempfile` and gitignored). Never write scratch files to `/tmp`, `$TMP`, or the workspace root.

## Verifying changes

Tests are Python assert scripts under `tests/`. Run the safe ones together:

```bash
python3 tests/run_all.py          # lint + agents + merge (no credentials needed)
```

Or run individually:

```bash
python3 tests/test_lint.py        # ruff, py_compile, json.load(settings.json)
python3 tests/test_agents.py      # agent file conventions: frontmatter, sections, paths
python3 tests/test_merge.py       # merge logic from review_core.py (6 cases, calls real fn)
python3 tests/e2e.py              # end-to-end (needs credentials + real PR; POSTS comments)
```

`tests/e2e.py` requires `ante` on PATH, `gh` authenticated, and the env vars the action injects (`PR_NUMBER`, `REPO`, `HEAD_SHA`, `GITHUB_TOKEN`, `INPUT_PROVIDER`, `INPUT_EFFORT`, plus the matching provider API key). It will POST comments to the PR — point it at a test repo.

Always check the `./README.md` for any outdated or incorrect details after code changes.

## Further reading

- `README.md` — human-facing docs (usage, inputs table, provider secrets, fork-PR security notes). Read it when modifying user-facing behavior or the workflow example.

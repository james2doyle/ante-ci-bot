#!/usr/bin/env python3
"""Ante PR review orchestrator.

Replaces scripts/review.sh. Reads the same INPUT_* env vars, fetches the PR
diff via `gh`, runs ante headless with three sub-agents, merges the per-agent
review JSON files, and posts a summary comment + line-anchored review comments.

Every failure path is non-blocking: print a ::warning::, post a warning PR
comment, and exit 0. The action must never fail a PR pipeline.
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# review_core and post_comment live in the same scripts/ directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_core import (
    AgentReview,
    MergedReview,
    count_dropped,
    load_agent_reviews,
    merge_reviews,
)
from post_comment import post_comment, validate_comment, Comment as PostComment


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def warn(msg: str) -> None:
    """Emit a GitHub Actions workflow warning and print to stderr."""
    print(f"::warning::{msg}", file=sys.stderr)


def gh(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a gh CLI command. Caller checks .returncode."""
    return subprocess.run(["gh", *args], capture_output=True, text=True, **kwargs)


def fetch_diff(pr_number: str, repo: str, out: Path, max_lines: int) -> bool:
    """Fetch the PR diff via `gh pr diff`. Returns False if empty or failed."""
    result = gh(["pr", "diff", pr_number, "--repo", repo], stdout=open(out, "w"))
    if result.returncode != 0:
        warn(f"failed to fetch diff: {result.stderr.strip()}")
        return False
    lines = out.read_text().splitlines()
    if len(lines) == 0:
        warn("diff is empty; nothing to review")
        return False
    if len(lines) > max_lines:
        truncated = "\n".join(lines[:max_lines])
        marker = (
            f"\n\n--- NOTE: diff truncated to {max_lines} lines for context limits."
            " Review only the shown portion. ---\n"
        )
        out.write_text(truncated + marker)
        print(f"diff truncated to {max_lines} lines")
    else:
        print(f"diff fetched: {len(lines)} lines")
    return True


def build_delegation(diff_file: Path, review_files: dict[str, Path], prompt: str) -> str:
    """Build the ante delegation string (review.sh:81-90)."""
    delegation = (
        f"Delegate the pull request review to three sub-agents. The diff is at {diff_file}. "
        "Tell each sub-agent to read it, review it, and write its review JSON to its assigned "
        "path per its instructions. Each finding MUST be a separate line-anchored entry in "
        "comments[] — do not narrate findings in the summary field. The line number for each "
        "comment MUST be the head-file line number: the agent MUST Read the actual source file "
        "and use the line number from Read output (the number to the left of the colon), NOT a "
        "line count from the diff file:\n"
    )
    for name, path in review_files.items():
        delegation += f"- {name}: write to {path}\n"
    if prompt:
        delegation += f"\nAdditional review focus from the caller:\n{prompt}"
    return delegation


def build_ante_args(provider: str, effort: str, model: str, delegation: str) -> list[str]:
    """Build the ante CLI args (review.sh:92-96)."""
    args = [
        "ante",
        "--provider", provider,
        "--effort", effort,
        "--no-session-save",
        "--output-format", "minimal",
        "--prompt", delegation,
    ]
    if model:
        args += ["--model", model]
    return args


def run_ante(args: list[str], out: Path, err: Path) -> int:
    """Run ante headless. Returns the exit code (review.sh:98-102)."""
    result = subprocess.run(
        args,
        stdin=subprocess.DEVNULL,
        stdout=open(out, "w"),
        stderr=open(err, "w"),
    )
    return result.returncode


def post_warning_comment(pr_number: str, repo: str, message: str) -> None:
    """Post a warning comment to the PR (non-blocking)."""
    gh(["pr", "comment", pr_number, "--repo", repo, "--body", message], check=False)


def post_summary(pr_number: str, repo: str, summary: str) -> None:
    """Post the top-level PR summary comment. --edit-last --create-if-none
    dedupes across re-pushes (review.sh:218-225)."""
    if not summary:
        return
    # Write summary to a temp file so gh can read it via --body-file (handles
    # multiline markdown safely without shell escaping).
    summary_file = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "ante_summary.md"
    summary_file.write_text(summary)
    gh([
        "pr", "comment", pr_number,
        "--repo", repo,
        "--edit-last", "--create-if-none",
        "--body-file", str(summary_file),
    ], check=False)


def post_line_comments(pr_number: str, repo: str, head_sha: str, merged: MergedReview) -> None:
    """Post each line review comment via post_comment.post_comment (in-process,
    no per-comment subprocess spawn — review.sh:230-241)."""
    for c in merged.comments:
        validated = validate_comment(PostComment(path=c.path, line=c.line, body=c.body, side=c.side))
        if validated is None:
            continue
        if post_comment(pr_number, repo, head_sha, validated):
            print(f"posted: {c.path}:{c.line} ({c.side.value})")
        else:
            warn(f"failed to post comment on {c.path}:{c.line}")


def dump_review_files(files: list[Path], names: list[str]) -> None:
    """Dump per-agent review files to the workflow log (review.sh:30-43)."""
    print("::group::raw per-agent review files")
    for f, name in zip(files, names):
        print(f"--- {f} ---")
        if not f.exists():
            print("(file does not exist)")
        else:
            try:
                data = json.loads(f.read_text())
                print(json.dumps(data, indent=2))
            except Exception:
                print(f.read_text())
    print("::endgroup::")


def main() -> None:
    # Read env vars (same contract as review.sh:10-15).
    pr_number = env("PR_NUMBER")
    head_sha = env("HEAD_SHA")
    repo = env("REPO")
    if not pr_number or not head_sha or not repo:
        warn("missing PR_NUMBER, HEAD_SHA, or REPO env var")
        sys.exit(0)

    provider = env("INPUT_PROVIDER", "openrouter")
    model = env("INPUT_MODEL")
    effort = env("INPUT_EFFORT", "medium")
    prompt = env("INPUT_PROMPT")
    max_diff_lines = int(env("INPUT_MAX_DIFF_LINES", "4000"))

    # install-ante.sh puts the binary at $HOME/.ante/bin, but that PATH export
    # from step 1's bash shell does not carry into step 2's shell. Re-export it
    # here so shutil.which finds the binary (matching review.sh line 3).
    ante_install_dir = Path.home() / ".ante" / "bin"
    os.environ["PATH"] = f"{ante_install_dir}{os.pathsep}{os.environ.get('PATH', '')}"

    # ante binary check (review.sh:5-8).
    if shutil.which("ante") is None:
        warn("ante binary not found; skipping review")
        sys.exit(0)

    # Temp directory: RUNNER_TEMP is job-specific and auto-cleaned on GitHub
    # Actions; fall back to /tmp for local/M0 testing.
    tmp = Path(env("RUNNER_TEMP", "/tmp"))

    diff_file = tmp / "pr.diff"
    review_file = tmp / "ante_review.json"
    review_code = tmp / "ante_review_code.json"
    review_sec = tmp / "ante_review_sec.json"
    review_comments = tmp / "ante_review_comments.json"
    ante_out = tmp / "ante.out"
    ante_err = tmp / "ante.err"

    # 1. Fetch the PR diff.
    if not fetch_diff(pr_number, repo, diff_file, max_diff_lines):
        sys.exit(0)

    # 2. Point ANTE_HOME at the action's bundled ante/ directory (review.sh:70).
    action_path = env("GITHUB_ACTION_PATH", str(Path(__file__).resolve().parent.parent))
    os.environ["ANTE_HOME"] = str(Path(action_path) / "ante")

    # 3. Run ante headless (review.sh:81-110).
    review_files = {
        "code-reviewer": review_code,
        "security-reviewer": review_sec,
        "comment-reviewer": review_comments,
    }
    delegation = build_delegation(diff_file, review_files, prompt)
    ante_args = build_ante_args(provider, effort, model, delegation)

    # Clean previous per-agent files.
    for f in review_files.values():
        f.unlink(missing_ok=True)
    review_file.unlink(missing_ok=True)

    rc = run_ante(ante_args, ante_out, ante_err)
    if rc != 0:
        warn(f"ante exited {rc}")
        print(ante_err.read_text() or "", file=sys.stderr)
        post_warning_comment(pr_number, repo, f"Ante review could not run (exit {rc}). Check workflow logs.")
        sys.exit(0)  # non-blocking

    # 4. Load and merge per-agent review files (review.sh:120-187).
    files = [review_code, review_sec, review_comments]
    names = ["code-reviewer", "security-reviewer", "comment-reviewer"]
    reviews = load_agent_reviews(files, names)

    # Check if all agents produced nothing useful.
    if all(r.summary is None and len(r.comments) == 0 for r in reviews):
        warn("ante did not produce any valid review files")
        dump_review_files(files, names)
        print("::group::ante stderr")
        print(ante_err.read_text() or "")
        print("::endgroup::")
        print("::group::ante stdout")
        print(ante_out.read_text() or "")
        print("::endgroup::")
        post_warning_comment(pr_number, repo, "Ante ran but did not produce a structured review. See workflow logs.")
        sys.exit(0)

    merged = merge_reviews(reviews)

    # Warn about dropped comments (review.sh:200-213).
    dropped = count_dropped(reviews)
    if dropped.total > 0:
        warn(f"dropped {dropped.total} comment(s) (unique): path={dropped.path} line={dropped.line} body={dropped.body}")
        dump_review_files(files, names)

    # Write the merged review JSON to $REVIEW_FILE (sole source of truth —
    # kept for e2e/debugging parity with the bash version).
    review_file.write_text(json.dumps({
        "summary": merged.summary,
        "comments": [
            {
                "path": c.path,
                "line": c.line,
                "side": c.side.value,
                "severity": c.severity.value,
                "body": c.body,
            }
            for c in merged.comments
        ],
    }, indent=2))

    # 5. Post summary (review.sh:218-225).
    print(f"merged: {len(merged.comments)} line comment(s) to post")
    post_summary(pr_number, repo, merged.summary)

    # 6. Post each line review comment (review.sh:230-241).
    post_line_comments(pr_number, repo, head_sha, merged)

    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Post a single line-anchored review comment via `gh api`.

`gh pr comment` has no --line/--path/--side/--commit flags, so review comments
(a distinct GitHub object type) must go through `gh api` directly:
POST /repos/{owner}/{repo}/pulls/{pull_number}/comments

Importable as a function (review.py calls this in-process — no per-comment
subprocess spawn) or as a CLI (`python3 post_comment.py ARGS...`).
"""

import argparse
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

from review_core import Side


@dataclass
class Comment:
    path: str
    line: int
    body: str
    side: Side = Side.RIGHT


def validate_comment(c: Comment) -> Optional[Comment]:
    """Validate a comment against the GitHub API contract.

    Returns the comment with side normalized (LEFT|RIGHT), or None if the
    comment should be skipped (non-blocking — caller continues its loop).
    Matches post-comment.sh:22-37.
    """
    if not c.path or c.path == "null":
        print("::warning::skipping comment: missing or null path")
        return None
    if not isinstance(c.line, int) or c.line <= 0:
        print(f"::warning::skipping comment on {c.path}: invalid line '{c.line}'")
        return None
    if not c.body or c.body == "null":
        print(f"::warning::skipping comment on {c.path}:{c.line}: empty or null body")
        return None
    # Normalize side: accept LEFT/RIGHT, default anything else to RIGHT.
    try:
        side = Side(str(c.side).upper())
    except ValueError:
        side = Side.RIGHT
    return Comment(path=c.path, line=c.line, body=c.body, side=side)


def post_comment(pr_number: str, repo: str, head_sha: str, c: Comment) -> bool:
    """POST one line comment via gh api. Returns True on success.

    On API failure, prints a warning and returns False (caller logs the
    warning — non-blocking for the overall review). Matches post-comment.sh:44-59.
    """
    result = subprocess.run(
        [
            "gh", "api", "-X", "POST",
            f"repos/{repo}/pulls/{pr_number}/comments",
            "-f", f"body={c.body}",
            "-f", f"commit_id={head_sha}",
            "-f", f"path={c.path}",
            "-F", f"line={c.line}",
            "-f", f"side={c.side.value}",
            "--silent",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"::warning::gh api failed (exit {result.returncode}) for {c.path}:{c.line}")
        print(result.stderr or "", file=sys.stderr)
        return False
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Post one line-anchored PR review comment via gh api")
    parser.add_argument("pr_number", help="PR number")
    parser.add_argument("repo", help="owner/repo")
    parser.add_argument("head_sha", help="HEAD commit SHA")
    parser.add_argument("path", help="file path")
    parser.add_argument("line", type=int, help="line number")
    parser.add_argument("side", nargs="?", default="RIGHT", help="LEFT or RIGHT (default RIGHT)")
    parser.add_argument("body", help="comment body")
    args = parser.parse_args()

    c = Comment(path=args.path, line=args.line, side=args.side, body=args.body)
    c = validate_comment(c)
    if c is None:
        sys.exit(0)  # skip, non-blocking
    sys.exit(0 if post_comment(args.pr_number, args.repo, args.head_sha, c) else 1)


if __name__ == "__main__":
    main()

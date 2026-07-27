#!/usr/bin/env python3
"""Tests for post_comment.py validation logic.

Ports the validation cases from post-comment.sh:22-37 (null path, bad line,
empty body, side normalization). Does NOT test the gh api call (requires
credentials + real PR); that is covered by tests/e2e.py.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from post_comment import Comment, Side, validate_comment


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def passed(msg: str) -> None:
    print(f"[PASS] {msg}")


def main() -> None:
    print("=== post_comment ===")

    # Null / empty path -> skip
    assert validate_comment(Comment(path="", line=1, body="x")) is None, "empty path should skip"
    assert validate_comment(Comment(path="null", line=1, body="x")) is None, "null path should skip"
    passed("null/empty path -> skip")

    # Non-positive line -> skip
    assert validate_comment(Comment(path="a.py", line=0, body="x")) is None, "line 0 should skip"
    assert validate_comment(
        Comment(path="a.py", line=-5, body="x"),
    ) is None, "negative line should skip"
    passed("non-positive line -> skip")

    # Empty / null body -> skip
    assert validate_comment(Comment(path="a.py", line=1, body="")) is None, "empty body should skip"
    assert validate_comment(
        Comment(path="a.py", line=1, body="null"),
    ) is None, "null body should skip"
    passed("empty/null body -> skip")

    # Valid comment -> returned with side normalized
    c = validate_comment(Comment(path="a.py", line=10, body="fix this"))
    assert c is not None and c.path == "a.py" and c.line == 10 and c.body == "fix this"
    passed("valid comment returned unchanged")

    # Side normalization: LEFT/RIGHT preserved, anything else -> RIGHT
    c = validate_comment(Comment(path="a.py", line=1, body="x", side="left"))
    assert c is not None and c.side == Side.LEFT
    c = validate_comment(Comment(path="a.py", line=1, body="x", side="RIGHT"))
    assert c is not None and c.side == Side.RIGHT
    c = validate_comment(Comment(path="a.py", line=1, body="x", side="bogus"))
    assert c is not None and c.side == Side.RIGHT
    c = validate_comment(Comment(path="a.py", line=1, body="x"))  # default
    assert c is not None and c.side == Side.RIGHT
    passed("side normalization: LEFT/RIGHT preserved, unknown -> RIGHT")

    print("=== post_comment complete ===")


if __name__ == "__main__":
    main()

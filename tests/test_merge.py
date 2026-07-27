#!/usr/bin/env python3
"""Tests the merge logic from review_core.py in isolation.

Ports all 6 cases from tests/merge.sh (381 lines -> ~120 lines). Each case
calls the real merge_reviews function — no duplicated logic, no drift when
the merge changes.
"""

import json
import sys
import tempfile
from pathlib import Path

# scripts/ must be importable from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from review_core import (
    AgentReview,
    MergedReview,
    Severity,
    normalize_comment,
    merge_reviews,
    count_dropped,
    load_agent_reviews,
)


def write_review(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data))


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def passed(msg: str) -> None:
    print(f"[PASS] {msg}")


def main() -> None:
    print("=== merge ===")
    tmp = Path(tempfile.mkdtemp(prefix="ante_test_"))

    code = tmp / "ante_review_code.json"
    sec = tmp / "ante_review_sec.json"
    comments = tmp / "ante_review_comments.json"
    files = [code, sec, comments]
    names = ["code-reviewer", "security-reviewer", "comment-reviewer"]

    # --- Case 1: all three agents produce reviews ---
    write_review(code, {
        "summary": "Code looks good overall.",
        "comments": [{"path": "src/a.ts", "line": 10, "side": "RIGHT", "severity": "warning", "body": "off-by-one"}],
    })
    write_review(sec, {"summary": "No security issues found.", "comments": []})
    write_review(comments, {
        "summary": "Stale TODO on line 5.",
        "comments": [{"path": "src/b.ts", "line": 5, "side": "RIGHT", "severity": "info", "body": "vague TODO"}],
    })

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)

    assert len(merged.comments) == 2, f"expected 2 comments, got {len(merged.comments)}"
    assert "> [!CAUTION]\n> code-reviewer" in merged.summary, "summary missing code-reviewer prefix"
    assert "> [!WARNING]\n> security-reviewer" in merged.summary, "summary missing security-reviewer prefix"
    assert "> [!NOTE]\n> comment-reviewer" in merged.summary, "summary missing comment-reviewer prefix"
    paths = {c.path for c in merged.comments}
    assert paths == {"src/a.ts", "src/b.ts"}, f"unexpected paths: {paths}"
    assert all(
        c.body.startswith(f"> [!CAUTION]\n> {names[0]}\n\n") or
        c.body.startswith(f"> [!NOTE]\n> {names[2]}\n\n")
        for c in merged.comments
    )
    passed("merge with all 3 agents: summaries + comments merged with attribution")

    # --- Case 2: only one agent produces a review (others missing) ---
    sec.unlink(); comments.unlink()
    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)

    assert len(merged.comments) == 1, f"expected 1 comment, got {len(merged.comments)}"
    assert "> [!CAUTION]\n> code-reviewer" in merged.summary
    assert merged.comments[0].body.startswith("> [!CAUTION]\n> code-reviewer\n\n")
    passed("merge with 1 agent (2 missing): graceful, posts what exists with attribution")

    # --- Case 3: all agents produce empty comments (clean PR) ---
    write_review(code, {"summary": "Code looks good.", "comments": []})
    write_review(sec, {"summary": "No security issues.", "comments": []})
    write_review(comments, {"summary": "Comments look good.", "comments": []})

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)

    assert len(merged.comments) == 0, f"expected 0 comments on clean PR, got {len(merged.comments)}"
    assert "> [!CAUTION]\n> code-reviewer" in merged.summary
    assert "> [!WARNING]\n> security-reviewer" in merged.summary
    assert "> [!NOTE]\n> comment-reviewer" in merged.summary
    passed("merge with clean PR (all comments empty): 0 comments, attributed summaries")

    # --- Case 4: comments with missing/null path, invalid line, or empty body ---
    write_review(code, {
        "summary": "Code review.",
        "comments": [
            {"path": "src/a.py", "line": 10, "side": "RIGHT", "severity": "warning", "body": "valid"},
            {"path": None, "line": 20, "side": "RIGHT", "severity": "error", "body": "null path"},
            {"line": 30, "side": "RIGHT", "severity": "info", "body": "missing path key"},
            {"path": "", "line": 40, "side": "RIGHT", "severity": "warning", "body": "empty path"},
            {"path": "src/b.py", "line": 0, "side": "RIGHT", "severity": "warning", "body": "zero line"},
            {"path": "src/c.py", "line": -5, "side": "RIGHT", "severity": "error", "body": "negative line"},
            {"path": "src/d.py", "line": 50, "side": "RIGHT", "severity": "warning", "body": ""},
            {"path": "src/e.py", "line": 60, "side": "RIGHT", "severity": "info"},
        ],
    })
    write_review(sec, {"summary": "Security review.", "comments": []})
    write_review(comments, {"summary": "Comment review.", "comments": []})

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)
    dropped = count_dropped(reviews)

    assert len(merged.comments) == 1, f"expected 1 valid comment after filter, got {len(merged.comments)}"
    assert merged.comments[0].path == "src/a.py" and merged.comments[0].line == 10
    assert dropped.total == 7, f"expected 7 unique dropped, got {dropped.total} (path={dropped.path} line={dropped.line} body={dropped.body})"
    passed("merge filters comments with null/empty path, non-positive line, or empty body (1 kept, 7 dropped)")

    # --- Case 5: schema violations — comments not an array, summary not a string ---
    write_review(code, {
        "summary": "Code review.",
        "comments": [{"path": "src/a.py", "line": 10, "side": "RIGHT", "severity": "warning", "body": "valid"}],
    })
    write_review(sec, {"summary": 42, "comments": "not an array"})
    write_review(comments, {
        "summary": "Comment review.",
        "comments": [{"path": "src/b.py", "line": 5, "side": "RIGHT", "severity": "info", "body": "ok"}],
    })

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)

    assert len(merged.comments) == 2, f"expected 2 comments with schema-violating agent, got {len(merged.comments)}"
    assert "> [!CAUTION]\n> code-reviewer" in merged.summary
    assert "> [!NOTE]\n> comment-reviewer" in merged.summary
    assert "> [!WARNING]\n> security-reviewer" not in merged.summary, "non-string summary should have been skipped"
    passed("merge handles schema violations (non-array comments, non-string summary) without crash")

    # --- Case 6: field-name aliases ---
    write_review(code, {
        "summary": "Code review.",
        "comments": [
            {"file": "src/a.py", "line_number": 10, "side": "RIGHT", "severity": "warning", "message": "aliased file+line_number+message"},
            {"filename": "src/b.py", "lineno": 20, "severity": "error", "comment": "aliased filename+lineno+comment"},
            {"path": "src/c.py", "line": 30, "text": "aliased path+line+text"},
        ],
    })
    write_review(sec, {"summary": "Security review.", "comments": []})
    write_review(comments, {"summary": "Comment review.", "comments": []})

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)
    dropped = count_dropped(reviews)

    assert len(merged.comments) == 3, f"expected 3 comments after alias normalization, got {len(merged.comments)}"
    by_path = {c.path: c.line for c in merged.comments}
    assert by_path == {"src/a.py": 10, "src/b.py": 20, "src/c.py": 30}, f"aliases not normalized: {by_path}"
    assert dropped.total == 0, f"expected 0 dropped with aliases, got {dropped.total}"
    passed("merge normalizes field aliases (file/filename, message/comment/text, line_number/lineno) — 3 kept, 0 dropped")

    # --- Case 7: two agents flag the same path+line — collapse into one ---
    write_review(code, {
        "summary": "Code review.",
        "comments": [
            {"path": "src/a.py", "line": 10, "side": "RIGHT", "severity": "warning", "body": "off-by-one in loop"}
        ],
    })
    write_review(sec, {
        "summary": "Security review.",
        "comments": [
            {"path": "src/a.py", "line": 10, "side": "RIGHT", "severity": "error", "body": "integer overflow"}
        ],
    })
    write_review(comments, {"summary": "Comment review.", "comments": []})

    reviews = load_agent_reviews(files, names)
    merged = merge_reviews(reviews)

    assert len(merged.comments) == 1, f"expected 1 collapsed comment, got {len(merged.comments)}"
    c = merged.comments[0]
    assert c.path == "src/a.py" and c.line == 10
    # Both agents' prefixed bodies present, separated by ---
    assert "> [!CAUTION]\n> code-reviewer\n\noff-by-one in loop" in c.body
    assert "> [!WARNING]\n> security-reviewer\n\ninteger overflow" in c.body
    assert "---" in c.body
    # Max severity wins
    assert c.severity == Severity.ERROR
    passed("merge collapses same path+line: joined bodies, max severity (warning+error -> error)")

    print("=== merge complete ===")


if __name__ == "__main__":
    main()

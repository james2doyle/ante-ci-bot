#!/usr/bin/env python3
"""Pure review logic: dataclasses, normalize, merge, dropped-count.

No I/O, no subprocess, no GitHub API. This is the heart of the migration —
the ~10-line jq filter from review.sh:175-187, now importable and testable
without duplicating logic 6x in tests.
"""

import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional


class Side(str, Enum):
    LEFT = "LEFT"
    RIGHT = "RIGHT"


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass
class Comment:
    path: str
    line: int
    body: str
    side: Side = Side.RIGHT
    severity: Severity = Severity.INFO

    @property
    def is_valid(self) -> bool:
        """A comment is valid iff it has a non-empty path, positive line, and
        non-empty body — matching the jq select filter in review.sh:175-187."""
        return bool(self.path) and self.line > 0 and bool(self.body)


@dataclass
class AgentReview:
    """One sub-agent's review output (code-reviewer, security-reviewer, ...)."""
    name: str
    summary: Optional[str]
    comments: list[Comment]


@dataclass
class MergedReview:
    """All per-agent reviews merged into one review file (the JSON contract)."""
    summary: str
    comments: list[Comment]


@dataclass
class DroppedCount:
    total: int
    path: int
    line: int
    body: int


def normalize_comment(raw: dict) -> Comment:
    """Normalize field aliases into a Comment. Invalid fields become empty
    string / 0 so callers can filter and count dropped by reason.

    Aliases (matching review.sh:175-187):
      - path: file, filename
      - body: message, comment, text
      - line: line_number, lineno
    """
    path = raw.get("path") or raw.get("file") or raw.get("filename")
    if not isinstance(path, str):
        path = str(path) if path is not None else ""

    body = raw.get("body") or raw.get("message") or raw.get("comment") or raw.get("text") or ""
    if not isinstance(body, str):
        body = str(body) if body is not None else ""

    line = raw.get("line") or raw.get("line_number") or raw.get("lineno") or 0
    try:
        line = int(line)
    except (TypeError, ValueError):
        line = 0

    side_raw = raw.get("side", "RIGHT")
    try:
        side = Side(side_raw)
    except ValueError:
        side = Side.RIGHT

    sev_raw = raw.get("severity", "info")
    try:
        severity = Severity(sev_raw)
    except ValueError:
        severity = Severity.INFO

    return Comment(path=path, line=line, body=body, side=side, severity=severity)


# Maps each sub-agent name to its GFM alert type.
# code-reviewer findings are warnings, security-reviewer findings are
# cautions, and comment-reviewer findings are informational notes.
ALERT_MAP = {
    "code-reviewer": "CAUTION",
    "security-reviewer": "WARNING",
    "comment-reviewer": "NOTE",
}


def merge_reviews(reviews: list[AgentReview]) -> MergedReview:
    """Concatenate attributed summaries; collect and attribute valid comments.

    Attribution is applied here (in the merge), not by sub-agents, so it is
    always consistent regardless of what the sub-agent prompt says. Invalid
    comments (empty path, non-positive line, empty body) are dropped — matching
    the jq select filter in review.sh:175-187.
    """
    blocks = [
        f"> [!{ALERT_MAP.get(r.name, 'NOTE')}]\n> {r.name}\n\n{r.summary}"
        for r in reviews
        if r.summary and isinstance(r.summary, str)
    ]
    comments = []
    for r in reviews:
        for c in r.comments:
            if not c.is_valid:
                continue
            comments.append(Comment(
                path=c.path,
                line=c.line,
                body=f"> [!{ALERT_MAP.get(r.name, 'NOTE')}]\n> {r.name}\n\n{c.body}",
                side=c.side,
                severity=c.severity,
            ))

    # Collapse comments at the same path+line: join bodies with a separator,
    # take the higher severity. Dedup is by (path, line) only — body text is
    # non-deterministic across agents, so we never compare it.
    SEVERITY_ORDER = {Severity.INFO: 0, Severity.WARNING: 1, Severity.ERROR: 2}

    grouped: dict[tuple[str, int], Comment] = {}
    for c in comments:
        key = (c.path, c.line)
        if key in grouped:
            existing = grouped[key]
            # Take the higher severity
            if SEVERITY_ORDER.get(c.severity, 0) > SEVERITY_ORDER.get(existing.severity, 0):
                severity = c.severity
            else:
                severity = existing.severity
            grouped[key] = Comment(
                path=c.path,
                line=c.line,
                body=f"{existing.body}\n\n---\n\n{c.body}",
                side=existing.side,
                severity=severity,
            )
        else:
            grouped[key] = c
    comments = list(grouped.values())

    return MergedReview(summary="\n\n".join(blocks), comments=comments)


def count_dropped(reviews: list[AgentReview]) -> DroppedCount:
    """Count unique dropped comments by reason.

    A single comment missing both path and body counts once in total but
    appears in both per-reason counts (matching review.sh:200-213).
    """
    total = path = line = body = 0
    for r in reviews:
        for c in r.comments:
            dropped = False
            if not c.path:
                path += 1
                dropped = True
            if c.line <= 0:
                line += 1
                dropped = True
            if not c.body:
                body += 1
                dropped = True
            if dropped:
                total += 1
    return DroppedCount(total=total, path=path, line=line, body=body)


def load_agent_reviews(
    files: list[Path],
    names: list[str],
) -> list[AgentReview]:
    """Load per-agent review JSON files into AgentReview objects.

    Missing files, invalid JSON, and schema violations are handled gracefully
    (non-blocking) — matching review.sh:120-154. Invalid comments within a
    valid file are normalized (empty fields) so merge_reviews can filter them
    and count_dropped can count them by reason.
    """
    reviews: list[AgentReview] = []
    for f, name in zip(files, names):
        if not f.exists():
            print(f"{name}: no review file produced")
            reviews.append(AgentReview(name=name, summary=None, comments=[]))
            continue
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            print(f"::warning::{name}: review file is not valid JSON, skipping")
            reviews.append(AgentReview(name=name, summary=None, comments=[]))
            continue

        # Schema validation: comments must be array (or absent); summary must
        # be string (or absent). Log violations but still include the file —
        # merge handles non-array comments safely (treated as empty) and
        # non-string summaries are skipped by the summary filter.
        comments_raw = data.get("comments")
        summary_raw = data.get("summary")

        if comments_raw is not None and not isinstance(comments_raw, list):
            print(f"::warning::{name}: comments is {type(comments_raw).__name__} (expected array); will be treated as empty")
            comments_raw = []
        if summary_raw is not None and not isinstance(summary_raw, str):
            print(f"::warning::{name}: summary is {type(summary_raw).__name__} (expected string); will be omitted")
            summary_raw = None

        comments: list[Comment] = []
        if isinstance(comments_raw, list):
            for c in comments_raw:
                if isinstance(c, dict):
                    comments.append(normalize_comment(c))

        reviews.append(AgentReview(
            name=name,
            summary=summary_raw if isinstance(summary_raw, str) else None,
            comments=comments,
        ))
    return reviews

#!/usr/bin/env python3
"""Tests that all ante/agents/*.md files follow project conventions.

Ports tests/agents.sh using pathlib + re instead of rg. Same assertions:
frontmatter keys, required sections, no hardcoded /tmp/ante_review,
diff-source paragraph, line-comment contract, head-file line number rule.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENTS_DIR = ROOT / "ante" / "agents"

AGENT_FILES = [
    AGENTS_DIR / "code-reviewer.md",
    AGENTS_DIR / "security-reviewer.md",
    AGENTS_DIR / "comment-reviewer.md",
]

REQUIRED_SECTIONS = ["## What to flag", "## What to skip", "## Output"]
FRONTMATTER_KEYS = ["name:", "description:", "tools:"]


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def passed(msg: str) -> None:
    print(f"[PASS] {msg}")


def read_text(path: Path) -> str:
    if not path.exists():
        fail(f"{path} missing")
    return path.read_text(encoding="utf-8")


def check_frontmatter(text: str, path: Path) -> None:
    for key in FRONTMATTER_KEYS:
        if not re.search(rf"^{re.escape(key)}", text, re.MULTILINE):
            fail(f"{path} missing frontmatter: {key}")
    # Write tool must be listed in frontmatter tools.
    if not re.search(r"^  - Write$", text, re.MULTILINE):
        fail(f"{path} missing Write in frontmatter tools")


def check_sections(text: str, path: Path) -> None:
    for section in REQUIRED_SECTIONS:
        if not re.search(rf"^{re.escape(section)}$", text, re.MULTILINE):
            fail(f"{path} missing section: {section}")


def main() -> None:
    print("=== agents ===")

    # All agent files exist.
    for f in AGENT_FILES:
        if not f.exists():
            fail(f"{f} missing")
    passed("all agent files exist")

    # No hardcoded /tmp/ante_review paths.
    for f in AGENT_FILES:
        text = f.read_text(encoding="utf-8")
        if "/tmp/ante_review" in text:
            fail(f"hardcoded /tmp/ante_review path found in {f}")
    passed("no hardcoded /tmp/ante_review paths")

    # Required sections.
    for f in AGENT_FILES:
        text = read_text(f)
        check_sections(text, f)
    passed("all agents have required sections")

    # Frontmatter.
    for f in AGENT_FILES:
        text = read_text(f)
        check_frontmatter(text, f)
    passed("all agents have valid frontmatter")

    # Diff-source paragraph.
    for f in AGENT_FILES:
        text = read_text(f)
        if "path to a unified PR diff file is provided in your task delegation" not in text:
            fail(f"{f} missing diff-source paragraph")
    passed("all agents reference delegation-provided diff path")

    # Delegation-provided review path.
    for f in AGENT_FILES:
        text = read_text(f)
        if "provided in your task" not in text:
            fail(f"{f} must write to delegation-provided path, not a hardcoded one")
    passed("all agents write to delegation-provided review path")

    # Line-comment contract.
    for f in AGENT_FILES:
        text = read_text(f)
        if "One finding = one comments[] entry" not in text:
            fail(f"{f} must enforce one-finding-per-comment rule")
        if "Do NOT list individual findings" not in text:
            fail(f"{f} must forbid narrating findings in summary")
        if "path is REQUIRED" not in text:
            fail(f"{f} must mark path as required on comments")
    passed("all agents enforce line-comment contract")

    # Head-file line number.
    for f in AGENT_FILES:
        text = read_text(f)
        if "head-file line number" not in text:
            fail(f"{f} must reference head-file line number")
        if "Do NOT derive" not in text:
            fail(f"{f} must forbid counting lines from the diff file")
        if "MUST then use Read to open each file" not in text:
            fail(f"{f} must mandate Reading the source file before commenting")
    passed("all agents enforce head-file line number via Read")

    print("=== agents complete ===")


if __name__ == "__main__":
    main()

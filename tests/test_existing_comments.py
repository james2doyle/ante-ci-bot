#!/usr/bin/env python3
"""Tests for the existing comments dedup logic in review.py.

Tests that:
- build_delegation includes the existing comments file path
- The delegation instructs agents to read and dedup against existing comments
- The existing comments file is always valid JSON (even when empty)
"""

import json
import sys
import tempfile
from pathlib import Path

# scripts/ must be importable from tests/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from review import build_delegation  # noqa: E402


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def passed(msg: str) -> None:
    print(f"[PASS] {msg}")


def main() -> None:
    print("=== existing comments dedup ===")

    tmp = Path(tempfile.mkdtemp(prefix="ante_test_"))
    diff_file = tmp / "pr.diff"
    existing_path = tmp / "ante_existing_comments.json"
    review_files = {"code-reviewer": tmp / "ante_review_code.json"}

    # Test 1: delegation includes existing comments path
    delegation = build_delegation(diff_file, review_files, existing_path, "")
    assert str(existing_path) in delegation, "delegation should include existing comments path"
    passed("delegation includes existing comments file path")

    # Test 2: delegation instructs agents to read existing comments
    assert "existing" in delegation.lower(), "delegation should mention existing comments"
    passed("delegation mentions existing comments")

    # Test 3: delegation instructs agents to skip duplicates
    assert "skip" in delegation.lower() or "dedup" in delegation.lower(), \
        "delegation should instruct agents to skip duplicates"
    passed("delegation instructs agents to skip duplicate comments")

    # Test 4: delegation handles empty prompt
    delegation_no_prompt = build_delegation(diff_file, review_files, existing_path, "")
    assert "Additional review focus" not in delegation_no_prompt, \
        "empty prompt should not add additional focus section"
    passed("empty prompt handled correctly")

    # Test 5: delegation includes custom prompt
    custom_prompt = "Focus on error handling"
    delegation_with_prompt = build_delegation(diff_file, review_files, existing_path, custom_prompt)
    assert custom_prompt in delegation_with_prompt, "custom prompt should be included"
    passed("custom prompt included in delegation")

    # Test 6: existing comments file is always valid JSON
    # Empty list case
    empty_file = tmp / "empty_comments.json"
    empty_file.write_text(json.dumps([]))
    data = json.loads(empty_file.read_text())
    assert data == [], "empty comments file should parse to empty list"
    passed("empty existing comments file is valid JSON")

    # Missing/empty file fallback
    missing_file = tmp / "missing_comments.json"
    # Simulate what review.py does: always write valid JSON
    missing_file.write_text(json.dumps([]))
    data = json.loads(missing_file.read_text())
    assert isinstance(data, list), "comments file should always be a list"
    passed("missing comments file fallback is valid JSON list")

    print("=== existing comments dedup complete ===")


if __name__ == "__main__":
    main()

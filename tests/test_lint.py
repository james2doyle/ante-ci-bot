#!/usr/bin/env python3
"""Static checks: py_compile, ruff lint, ante settings JSON validity.

Ports tests/lint.sh. Replaces shellcheck/bash -n with ruff + py_compile,
and jq empty with json.load.
"""

import json
import py_compile
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def passed(msg: str) -> None:
    print(f"[PASS] {msg}")


def main() -> None:
    print("=== lint ===")

    scripts_dir = ROOT / "scripts"
    py_files = sorted(scripts_dir.glob("*.py"))
    test_files = sorted((ROOT / "tests").glob("test_*.py"))
    all_py = py_files + test_files

    # py_compile: syntax check on all .py files.
    for f in all_py:
        try:
            py_compile.compile(str(f), doraise=True)
        except py_compile.PyCompileError as e:
            fail(f"py_compile {f.name}: {e}")
    passed(f"py_compile {' '.join(f.name for f in all_py)}")

    # ruff check (replaces shellcheck). Only runs if ruff is installed.
    if subprocess.run(["which", "ruff"], capture_output=True).returncode != 0:
        print("[WARN] ruff not installed; skipping ruff check")
    else:
        result = subprocess.run(
            ["ruff", "check", str(scripts_dir), str(ROOT / "tests")],
            capture_output=True, text=True, cwd=ROOT,
        )
        if result.returncode != 0:
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            fail("ruff check scripts/ tests/")
        passed("ruff check scripts/ tests/")

    # ante/settings.json validity (replaces `jq empty`).
    settings = ROOT / "ante" / "settings.json"
    try:
        json.load(settings.open())
    except Exception as e:
        fail(f"ante/settings.json: {e}")
    passed("ante/settings.json valid")

    print("=== lint complete ===")


if __name__ == "__main__":
    main()

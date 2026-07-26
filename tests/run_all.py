#!/usr/bin/env python3
"""Runs all safe test scripts (test_lint, test_agents, test_merge).

Ports tests/run-all.sh. Skips e2e (needs credentials + real PR); run
tests/e2e.py separately.
"""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TESTS = [
    ROOT / "test_lint.py",
    ROOT / "test_agents.py",
    ROOT / "test_merge.py",
    ROOT / "test_existing_comments.py",
    ROOT / "test_post_comment.py",
]


def run_test(path: Path) -> bool:
    """Import and run a test module's main() function. Returns True on pass."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        print(f"[FAIL] could not load {path.name}")
        return False
    mod = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = mod
    spec.loader.exec_module(mod)
    if hasattr(mod, "main"):
        try:
            mod.main()
            return True
        except SystemExit as e:
            return e.code == 0
    return True


def main() -> None:
    failed = 0
    for t in TESTS:
        print()
        if not run_test(t):
            print(f"[FAIL] {t.name}")
            failed += 1

    print()
    if failed == 0:
        print("[PASS] all tests passed")
    else:
        print(f"[FAIL] {failed} test(s) failed")
        sys.exit(1)


if __name__ == "__main__":
    main()

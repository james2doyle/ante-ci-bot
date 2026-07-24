#!/usr/bin/env python3
"""End-to-end local run: executes review.py against a real PR.

Ports tests/e2e.sh. Requires ante on PATH, gh authenticated, and all env vars
the action injects. This script will POST comments to the PR — point it at a
test repo/PR.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

REQUIRED_VARS = ["PR_NUMBER", "REPO", "HEAD_SHA", "GITHUB_TOKEN", "INPUT_PROVIDER", "INPUT_EFFORT"]


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def main() -> None:
    missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
    if missing:
        print(f"[FAIL] Missing required env vars: {', '.join(missing)}")
        print()
        print("Set them before running, e.g.:")
        print("  export RUNNER_TEMP=/tmp")
        print("  export PR_NUMBER=123")
        print("  export REPO=owner/repo")
        print("  export HEAD_SHA=$(git rev-parse HEAD)")
        print("  export GITHUB_TOKEN=ghp_xxx")
        print("  export INPUT_PROVIDER=anthropic")
        print("  export INPUT_EFFORT=medium")
        print("  export ANTHROPIC_API_KEY=sk-ant-xxx   # must match INPUT_PROVIDER")
        print()
        print("Then: python3 tests/e2e.py")
        sys.exit(1)

    if shutil.which("ante") is None:
        fail("ante binary not found on PATH. Run scripts/install-ante.sh first.")
    if shutil.which("gh") is None:
        fail("gh CLI not found on PATH.")

    os.environ.setdefault("RUNNER_TEMP", "/tmp")
    os.environ["GITHUB_ACTION_PATH"] = str(ROOT)

    print("=== e2e ===")
    print(f"PR:      {os.environ['REPO']}#{os.environ['PR_NUMBER']}")
    print(f"SHA:     {os.environ['HEAD_SHA']}")
    print(f"Provider: {os.environ['INPUT_PROVIDER']} ({os.environ['INPUT_EFFORT']})")
    print(f"Temp:    {os.environ['RUNNER_TEMP']}")
    print()

    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "review.py")],
        cwd=ROOT,
    )

    print()
    tmp = Path(os.environ["RUNNER_TEMP"])
    print(f"=== e2e complete (review.py exit {result.returncode}) ===")
    print(f"Inspect:  {tmp}/ante_review.json  {tmp}/ante.out  {tmp}/ante.err")


if __name__ == "__main__":
    main()

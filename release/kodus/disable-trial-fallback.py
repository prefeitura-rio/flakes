#!/usr/bin/env python3
"""Fail closed on a 401 in the pinned Kodus CLI; do not submit a trial review."""
import hashlib
from pathlib import Path
import sys

EXPECTED = "92ecee24442204677b8f2253055dd62f7497b5ed1279d10a5fd071d60c4a89fc"
NEEDLE = b"async function runTrialFallback({ diff, spinner, ctx, globalOpts, githubPat, heavy, }) {"
GUARD = b'\n    throw new Error("Trial fallback disabled for CI reviews");'


def disable(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Pinned CLI command file is missing or a symlink")
    content = path.read_bytes()
    if hashlib.sha256(content).hexdigest() != EXPECTED or content.count(NEEDLE) != 1:
        raise ValueError("Unexpected CLI command file; review the version and guard")
    path.write_bytes(content.replace(NEEDLE, NEEDLE + GUARD, 1))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Expected the npm install directory")
        disable(Path(sys.argv[1]) / "node_modules/@kodus/cli/dist/features/review/command.js")
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

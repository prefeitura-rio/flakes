#!/usr/bin/env python3
"""Review a prepared PR with the self-hosted Kodus CLI; never run PR code."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

FOCUS = (
    "Review the Quality Gate's own tests for meaningful regression protection. "
    "Identify concrete weak or missing assertions, incorrect mocks, missing "
    "positive/negative cases, isolation errors, or tests that would pass when "
    "the protected behavior is broken. Cite relevant test and engine changes. "
    "Do not infer quality from test counts or claim mutation testing ran."
)


def main():
    temp = Path(os.environ["RUNNER_TEMP"])
    base = os.environ["QG_REVIEW_BASE"]
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("Invalid base revision")
    url = urlsplit(os.environ["KODUS_API_URL"])
    if (url.scheme != "https" or url.hostname not in {"kodus-api.squirrel-regulus.ts.net", "kodus-api-1.squirrel-regulus.ts.net"}
            or url.port not in (None, 443) or url.username or url.password or url.path or url.query or url.fragment):
        raise ValueError("Kodus URL must be the approved private HTTPS API origin")
    if not os.environ.get("KODUS_TEAM_KEY", "").startswith("kodus_") or os.environ.get("KODUS_TOKEN"):
        raise ValueError("Dedicated Kodus team key is missing or overridden")
    repo = temp / "kodus-review-repo"
    result = temp / "kodus-self-test-review.json"
    cli = temp / "kodus-cli/node_modules/.bin/kodus"
    with tempfile.TemporaryDirectory(prefix="kodus-home-") as home:
        env = {**os.environ, "HOME": home, "KODUS_DISABLE_UPDATE_CHECK": "1"}
        # Do not pass GitHub or Tailscale credentials to the CLI process.
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "KODUS_TAILSCALE_CLIENT_ID", "KODUS_TAILSCALE_CLIENT_SECRET"):
            env.pop(name, None)
        command = [str(cli), "review", "--branch", base, "--focus", FOCUS, "--context", str(temp / "kodus-self-test-context.md"), "--agent", "--output", str(result)]
        subprocess.run(command, cwd=repo, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if not result.is_file() or result.stat().st_size > 2_000_000:
        raise ValueError("No usable Kodus result")
    envelope = json.loads(result.read_text(encoding="utf-8"))
    if not isinstance(envelope, dict) or not envelope.get("ok"):
        raise ValueError("Review did not complete")
    data = envelope.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("issues"), list) or "trialInfo" in data or "rateLimit" in data:
        raise ValueError("Review result is invalid or used trial mode")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Kodus self-test review failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)

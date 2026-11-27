#!/usr/bin/env python3
"""Publish a neutral check only for the still-current PR head."""
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def api(*args, payload=None):
    result = subprocess.run(["gh", "api", *args], input=payload, text=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return json.loads(result.stdout)


def text(value):
    value = html.escape(str(value or "")).replace("\n", " ")[:2000]
    return re.sub(r"([\\`*_\[\]()!|~#])", r"\\\1", value)


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    number = os.environ["QG_REVIEW_PR"]
    head = os.environ["QG_REVIEW_HEAD"]
    if repo != "prefeitura-rio/flakes" or not re.fullmatch(r"[1-9][0-9]*", number) or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("Invalid PR identity")
    pr = api(f"repos/{repo}/pulls/{number}")
    if (pr.get("state") != "open" or pr.get("base", {}).get("ref") != "master"
            or pr.get("head", {}).get("sha") != head
            or (pr.get("head", {}).get("repo") or {}).get("full_name") != repo):
        print("PR is no longer current; no check published.")
        return
    result = Path(os.environ["RUNNER_TEMP"]) / "kodus-self-test-review.json"
    lines = ["Advisory review; it does not block merging or replace mutation testing.", ""]
    title = "Kodus self-test review unavailable"
    if os.environ.get("QG_REVIEW_STATUS") == "success" and result.is_file() and result.stat().st_size <= 2_000_000:
        envelope = json.loads(result.read_text(encoding="utf-8"))
        data = envelope.get("data") if envelope.get("ok") is True else None
        if isinstance(data, dict) and isinstance(data.get("issues"), list) and "trialInfo" not in data and "rateLimit" not in data:
            title = "Kodus self-test review complete"
            lines += [text(data.get("summary", "Review complete.")), ""]
            for issue in data["issues"][:50]:
                if isinstance(issue, dict):
                    location = f"{issue.get('file', '')}:{issue.get('line', '')}"
                    lines.append(f"- **{text(issue.get('severity', 'unknown'))}** `{text(location)}`: {text(issue.get('message', ''))}")
                    suggestion = issue.get("suggestion") or issue.get("recommendation")
                    if suggestion:
                        lines.append(f"  - Suggested action: {text(suggestion)}")
            if len(data["issues"]) > 50:
                lines.append("- Additional findings omitted.")
    if title.endswith("unavailable"):
        lines.append("The review did not complete. See the workflow run for diagnostics; do not interpret this as a clean review.")
    summary = "\n".join(lines)[:60_000]
    payload = {
        "name": "Kodus / Quality Gate self-test review",
        "head_sha": head,
        "status": "completed",
        "conclusion": "neutral",
        "details_url": f"https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "output": {"title": title, "summary": summary},
    }
    api("--method", "POST", f"repos/{repo}/check-runs", "--input", "-", payload=json.dumps(payload))
    print(title)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Could not publish self-test review: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)

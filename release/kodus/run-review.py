#!/usr/bin/env python3
"""Review a prepared PR with the self-hosted Kodus CLI; never run PR code."""
import html
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


def text(value):
    value = html.escape(str(value or "")).replace("\n", " ")[:2000]
    value = value.replace("@", "@\u200b")
    return re.sub(r"([\\`*_\[\]()!|~#])", r"\\\1", value)


def write_summary(data, number, head, path):
    lines = [
        "## Kodus self-test review",
        "",
        f"PR #{number}, commit `{head}`. Advisory only; not proof of test quality.",
        "",
        text(data.get("summary") or "Review complete."),
        "",
    ]
    issues = data["issues"]
    if isinstance(data.get("notices"), list):
        lines.extend(f"- Note: {text(notice)}" for notice in data["notices"][:10] if isinstance(notice, str))
    if not issues:
        lines.append("No findings in the reviewed changes.")
    for issue in issues[:50]:
        location = f"{issue.get('file', '')}:{issue.get('line', '')}"
        lines.append(f"- **{text(issue.get('severity', 'unknown'))}** `{text(location)}`: {text(issue.get('message', ''))}")
        suggestion = issue.get("suggestion") or issue.get("recommendation")
        if suggestion:
            lines.append(f"  - Suggested action: {text(suggestion)}")
    if len(issues) > 50:
        lines.append("Additional findings omitted.")
    with open(path, "a", encoding="utf-8") as output:
        output.write("\n".join(lines) + "\n")


def identity():
    base = os.environ["QG_REVIEW_BASE"]
    head = os.environ["QG_REVIEW_HEAD"]
    number = os.environ["QG_REVIEW_PR"]
    if (not re.fullmatch(r"[0-9a-f]{40}", base) or not re.fullmatch(r"[0-9a-f]{40}", head)
            or not re.fullmatch(r"[1-9][0-9]*", number)):
        raise ValueError("Invalid PR identity")
    return base, head, number


def read_result(path):
    if not path.is_file() or path.stat().st_size > 2_000_000:
        raise ValueError("No usable Kodus result")
    envelope = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        raise ValueError("Review did not complete")
    data = envelope.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("issues"), list) or "trialInfo" in data or "rateLimit" in data:
        raise ValueError("Review result is invalid or used trial mode")
    if any(not isinstance(issue, dict) or not isinstance(issue.get("message"), str) for issue in data["issues"]):
        raise ValueError("Review contains invalid findings")
    return data


def gh(*args, payload=None):
    result = subprocess.run(["gh", "api", *args], input=payload, text=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    return json.loads(result.stdout)


def added_lines(patch):
    """Return new-file line numbers actually added in GitHub's visible diff."""
    result = set()
    line = None
    for row in patch.splitlines():
        hunk = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", row)
        if hunk:
            line = int(hunk.group(1))
        elif line is not None and row.startswith("+"):
            result.add(line)
            line += 1
        elif line is not None and row.startswith(" "):
            line += 1
    return result


def current_pr(pr, repository, base, head):
    return (pr.get("state") == "open" and pr.get("base", {}).get("ref") == "master"
            and pr.get("base", {}).get("sha") == base and pr.get("head", {}).get("sha") == head
            and (pr.get("base", {}).get("repo") or {}).get("full_name") == repository
            and (pr.get("head", {}).get("repo") or {}).get("full_name") == repository)


def publish_review():
    base, head, number = identity()
    repository = os.environ["GITHUB_REPOSITORY"]
    if repository != "prefeitura-rio/flakes" or not os.environ.get("GH_TOKEN"):
        raise ValueError("Missing PR review authorization")
    data = read_result(Path(os.environ["RUNNER_TEMP"]) / "kodus-self-test-review.json")
    endpoint = f"repos/{repository}/pulls/{number}"
    pr = gh(endpoint)
    if not current_pr(pr, repository, base, head):
        print("PR changed or closed; no review posted.")
        return
    marker = f"<!-- kodus-self-test-review:{head}:{base} -->"
    review_pages = gh("--paginate", "--slurp", endpoint + "/reviews?per_page=100")
    if not isinstance(review_pages, list) or any(not isinstance(page, list) for page in review_pages):
        raise ValueError("Invalid GitHub review listing")
    if any(not isinstance(review, dict) for page in review_pages for review in page):
        raise ValueError("Invalid GitHub review listing")
    if any(marker in (review.get("body") or "") and (review.get("user") or {}).get("login") == "github-actions[bot]"
           for page in review_pages for review in page):
        print("A Kodus review already exists for this head and base.")
        return
    pages = gh("--paginate", "--slurp", endpoint + "/files?per_page=100")
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("Invalid GitHub file listing")
    files = [file for page in pages for file in page]
    if (any(not isinstance(file, dict) for file in files) or type(pr.get("changed_files")) is not int
            or len(files) != pr["changed_files"] or len(files) > 3000):
        raise ValueError("Incomplete GitHub file listing")
    allowed = {file["filename"]: added_lines(file["patch"]) for file in files
               if isinstance(file, dict) and isinstance(file.get("filename"), str) and isinstance(file.get("patch"), str)}
    comments = []
    general = []
    seen = set()
    for issue in data["issues"][:50]:
        filename = issue.get("file")
        line = issue.get("line")
        message = f"**Kodus · {text(issue.get('severity', 'unknown'))}**\n\n{text(issue['message'])}"
        suggestion = issue.get("suggestion") or issue.get("recommendation")
        if suggestion:
            message += f"\n\nSuggested action: {text(suggestion)}"
        key = (filename if isinstance(filename, str) else "", line if type(line) is int else None, issue["message"])
        if key in seen:
            continue
        seen.add(key)
        if (isinstance(filename, str) and type(line) is int and line in allowed.get(filename, set())
                and len(comments) < 20):
            comments.append({"path": filename, "line": line, "side": "RIGHT", "body": message})
        else:
            detail = f"- `{text(filename)}:{text(line)}` — {text(issue['message'])}"
            if suggestion:
                detail += f" Suggested action: {text(suggestion)}"
            general.append(detail)
    body = ["## Kodus self-test review", "", "Automated, advisory feedback; human review is still required.", "",
            text(data.get("summary") or "Review complete.")]
    if isinstance(data.get("notices"), list):
        body.extend(f"\n- Note: {text(notice)}" for notice in data["notices"][:10] if isinstance(notice, str))
    if not data["issues"]:
        body.append("No findings in the reviewed changes; this does not prove test quality.")
    if general:
        body.extend(["", "**Findings not placed inline:**", *general])
    if len(data["issues"]) > 50:
        body.append("Additional findings omitted.")
    body_text = "\n".join(body)
    if len(body_text.encode("utf-8")) > 48_000:
        body_text = body_text.encode("utf-8")[:48_000].decode("utf-8", errors="ignore")
        body_text += "\n\nAdditional findings omitted."
    payload = {"commit_id": head, "event": "COMMENT", "body": body_text + "\n\n" + marker}
    if comments:
        payload["comments"] = comments
    # Recheck immediately before posting; commit_id anchors any remaining race.
    if not current_pr(gh(endpoint), repository, base, head):
        print("PR changed or closed; no review posted.")
        return
    gh("--method", "POST", endpoint + "/reviews", "--input", "-", payload=json.dumps(payload))
    print(f"Posted an advisory Kodus review with {len(comments)} inline comments.")


def main():
    temp = Path(os.environ["RUNNER_TEMP"])
    base, head, number = identity()
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
    data = read_result(result)
    write_summary(data, number, head, os.environ["GITHUB_STEP_SUMMARY"])


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--comment"]:
            publish_review()
        elif not sys.argv[1:]:
            main()
        else:
            raise ValueError("Unknown command")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"Kodus self-test review failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)

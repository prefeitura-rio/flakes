#!/usr/bin/env python3
"""Select a current same-repository PR from a completed self-test workflow."""
import json
import os
import re
import subprocess
import sys


def decide(event, pr, files, repository):
    run = event.get("workflow_run", {})
    linked = run.get("pull_requests") or []
    if (run.get("event") != "pull_request" or run.get("path") != ".github/workflows/quality-gate-tests.yml"
            or run.get("head_repository", {}).get("full_name") != repository or len(linked) != 1):
        return {"review": False, "reason": "Workflow run has no unique eligible same-repository PR."}
    number = linked[0].get("number")
    head = run.get("head_sha", "")
    base = pr.get("base", {}).get("sha", "")
    if (not isinstance(number, int) or number <= 0 or pr.get("number") != number
            or pr.get("state") != "open" or pr.get("base", {}).get("ref") != "master"
            or pr.get("base", {}).get("repo", {}).get("full_name") != repository
            or pr.get("head", {}).get("repo", {}).get("full_name") != repository
            or pr.get("head", {}).get("sha") != head
            or not re.fullmatch(r"[0-9a-f]{40}", head) or not re.fullmatch(r"[0-9a-f]{40}", base)):
        return {"review": False, "reason": "PR was closed, updated, or is outside the trusted repository."}
    if not isinstance(files, list) or pr.get("changed_files") != len(files) or len(files) > 3000:
        raise ValueError("Incomplete PR file listing; cannot determine review scope")
    if not any(str(f.get(k, "")).startswith("tests/") for f in files for k in ("filename", "previous_filename")):
        return {"review": False, "reason": "No self-test files changed."}
    return {"review": True, "number": number, "head": head, "base": base}


def api(path, paginate=False):
    args = ["gh", "api"] + (["--paginate", "--slurp"] if paginate else []) + [path]
    result = subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return json.loads(result.stdout)


def main():
    if sys.argv[1:] == ["--fixture"]:
        data = json.load(sys.stdin)
        print(json.dumps(decide(data["event"], data["pr"], data["files"], data["repository"])))
        return
    repository = os.environ["GITHUB_REPOSITORY"]
    if repository != "prefeitura-rio/flakes":
        raise ValueError("Unexpected repository")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
        event = json.load(source)
    run = event.get("workflow_run", {})
    linked = run.get("pull_requests") or []
    if (run.get("event") != "pull_request" or run.get("path") != ".github/workflows/quality-gate-tests.yml"
            or run.get("head_repository", {}).get("full_name") != repository or len(linked) != 1):
        result = {"review": False, "reason": "Workflow run has no unique eligible same-repository PR."}
    else:
        number = linked[0].get("number")
        if not isinstance(number, int) or number <= 0:
            raise ValueError("Invalid PR number")
        pr = api(f"repos/{repository}/pulls/{number}")
        pages = api(f"repos/{repository}/pulls/{number}/files?per_page=100", paginate=True)
        files = [entry for page in pages for entry in page]
        result = decide(event, pr, files, repository)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"review={'true' if result['review'] else 'false'}\n")
        if result["review"]:
            for key in ("number", "head", "base"):
                output.write(f"{key}={result[key]}\n")
    print(result.get("reason", "Eligible PR selected."))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Unable to select the self-test review: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)

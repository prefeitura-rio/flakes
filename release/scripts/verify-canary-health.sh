#!/usr/bin/env bash
# Succeeds only when the canary analysis of a commit is proven healthy.
#
# The proof is the `quality-gate-canary-<sha>` artifact of a run of the canary
# analysis workflow. Artifact names are not a credential: any workflow of the
# repository can upload one with any name. So only artifacts of runs that
#
#   - belong to the analysis workflow file,
#   - ran on the release branch of this repository (never a fork or a feature
#     branch, whose workflow file could have been edited),
#   - were triggered by the schedule, a workflow_run or a manual dispatch,
#   - finished successfully (the analysis exits non-zero when it is unhealthy),
#
# are accepted, and the JSON must be healthy and name the same commit.
#
# --not-before TIMESTAMP rejects analyses older than that instant. Promotion uses
# it to require an analysis made after the bake time ended.
set -euo pipefail

workflow_file="quality-gate-canary-analysis.yml"
release_branch="master"
repository="${GITHUB_REPOSITORY:-}"
sha=""
not_before=""
output=""

usage() {
  cat >&2 <<'USAGE'
Usage: verify-canary-health.sh --sha SHA [options]

Options:
  --repository OWNER/REPO  repository that ran the analysis (default: $GITHUB_REPOSITORY)
  --not-before TIMESTAMP   ISO 8601 instant; older analyses are rejected
  --output FILE            copy the verified canary-analysis.json here
  --workflow-file NAME     analysis workflow file (default: quality-gate-canary-analysis.yml)
  --release-branch NAME    branch the analysis must have run on (default: master)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --not-before) not_before="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --workflow-file) workflow_file="$2"; shift 2 ;;
    --release-branch) release_branch="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "--sha must be a full 40-character commit SHA." >&2
  usage
  exit 2
fi
if [[ -z "$repository" ]]; then
  echo "--repository or GITHUB_REPOSITORY is required." >&2
  exit 2
fi

artifact_name="quality-gate-canary-${sha}"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

runs="$(gh api --method GET \
  "repos/${repository}/actions/workflows/${workflow_file}/runs" \
  -f "branch=${release_branch}" -f status=success -f per_page=50)"

run_ids="$(jq -r --arg repository "$repository" --arg branch "$release_branch" '
  .workflow_runs[]
  | select(.head_branch == $branch)
  | select(.head_repository.full_name == $repository)
  | select(.event == "schedule" or .event == "workflow_run" or .event == "workflow_dispatch")
  | .id' <<<"$runs")"

for run_id in $run_ids; do
  artifacts="$(gh api --method GET "repos/${repository}/actions/runs/${run_id}/artifacts" -f "name=${artifact_name}")"
  while IFS=$'\t' read -r artifact_id created_at; do
    [[ -n "$artifact_id" ]] || continue
    if [[ -n "$not_before" && "$created_at" < "$not_before" ]]; then
      continue
    fi
    archive="$workspace/${artifact_id}.zip"
    gh api "repos/${repository}/actions/artifacts/${artifact_id}/zip" > "$archive"
    document="$workspace/${artifact_id}.json"
    if ! unzip -p "$archive" canary-analysis.json > "$document" 2>/dev/null; then
      continue
    fi
    if jq -e --arg sha "$sha" '.healthy == true and .candidate_sha == $sha' "$document" >/dev/null 2>&1; then
      echo "Canary analysis of ${sha} is healthy (run ${run_id}, ${created_at})." >&2
      if [[ -n "$output" ]]; then
        cp "$document" "$output"
      fi
      exit 0
    fi
  done < <(jq -r '.artifacts[] | select(.expired == false) | [.id, .created_at] | @tsv' <<<"$artifacts")
done

echo "No healthy canary analysis of ${sha} from ${release_branch}${not_before:+ after ${not_before}} was found." >&2
exit 1

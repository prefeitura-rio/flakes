#!/usr/bin/env bash
# Create a sandbox pipeline with the candidate revision and print its ID.
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^[1-9][0-9]*$ || ! "$2" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Usage: trigger-gitlab-canary.sh PROJECT_ID FULL_COMMIT_SHA" >&2
  exit 2
fi
: "${GITLAB_API:?GITLAB_API is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

project_id="$1"
request=$(jq -nc --arg sha "$2" '{
  ref: "main",
  variables: [
    {key: "QUALITY_GATE_REF", value: $sha},
    {key: "QUALITY_GATE_CANARY", value: "true"}
  ]
}')

if ! response=$(curl --fail-with-body --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "$request" \
  "${GITLAB_API%/}/projects/$project_id/pipeline"); then
  printf 'Could not create GitLab canary pipeline for project %s: %s\n' "$project_id" "$response" >&2
  exit 1
fi

if ! pipeline_id=$(jq -er '.id | select(type == "number" and . > 0 and floor == .)' <<<"$response"); then
  printf 'GitLab returned no valid pipeline ID for project %s.\n' "$project_id" >&2
  exit 1
fi
printf '%s\n' "$pipeline_id"

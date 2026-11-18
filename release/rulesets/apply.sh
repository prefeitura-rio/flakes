#!/usr/bin/env bash
# Applies the repository governance the Quality Gate release flow depends on.
#
# Nothing is changed unless --apply is given. Without it the script prints every
# request it would send. It needs a token that administers the repository
# (`gh auth status`), and the release App must already be installed; see
# APP-SETUP.md.
set -euo pipefail

repository="prefeitura-rio/flakes"
apply=false
app_id=""
rulesets_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# phrmendes, gabriel-milan
reviewer_ids=(22376151 35741485)

usage() {
  cat >&2 <<'EOF'
Usage: apply.sh --app-id ID [--repository OWNER/REPO] [--apply]

  --app-id ID        numeric ID of the release GitHub App (the "App ID" shown in
                     the App settings, not the installation ID)
  --repository R     repository to configure (default: prefeitura-rio/flakes)
  --apply            send the requests (default is a dry run)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) app_id="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$app_id" =~ ^[0-9]+$ ]]; then
  echo "--app-id is required and must be numeric." >&2
  usage
  exit 2
fi

call() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "$apply" != true ]]; then
    echo "DRY RUN  $method /repos/$repository/$path"
    [[ -n "$body" ]] && jq . <<<"$body"
    return 0
  fi
  if [[ -n "$body" ]]; then
    gh api --method "$method" "/repos/$repository/$path" --input - <<<"$body" >/dev/null
  else
    gh api --method "$method" "/repos/$repository/$path" >/dev/null
  fi
  echo "applied  $method /repos/$repository/$path"
}

reviewers_json() {
  local entries=()
  for id in "${reviewer_ids[@]}"; do
    entries+=("{\"type\":\"User\",\"id\":$id}")
  done
  local IFS=,
  echo "[${entries[*]}]"
}

# Environments: only master can deploy and admins cannot bypass. Only the
# emergency environment asks for human approval; the automated ones must not
# wait for a person on every canary analysis, promotion or cache publication.
environment() {
  local name="$1" reviewers="$2"
  call PUT "environments/$name" "$(jq -n \
    --argjson reviewers "$reviewers" \
    '{
      prevent_self_review: true,
      can_admins_bypass: false,
      reviewers: $reviewers,
      deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}
    }')"
  call POST "environments/$name/deployment-branch-policies" '{"name":"master","type":"branch"}'
}

environment quality-gate-release '[]'
environment quality-gate-promotion "$(reviewers_json)"
environment cachix-publish '[]'

# Workflows get read-only tokens by default and cannot approve pull requests.
call PUT "actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'

# Rulesets: the tag ruleset is the only one that names the App.
tags_ruleset="$(jq --argjson app "$app_id" \
  '.bypass_actors = [{actor_id: $app, actor_type: "Integration", bypass_mode: "always"}]' \
  "$rulesets_dir/quality-gate-tags.json")"
call POST "rulesets" "$tags_ruleset"
call POST "rulesets" "$(cat "$rulesets_dir/master.json")"

cat <<EOF

Secrets are not copied by this script. After the environments exist, create
these environment secrets and then delete the repository-level copies:

  quality-gate-release    QUALITY_GATE_RELEASE_APP_ID
                          QUALITY_GATE_RELEASE_APP_PRIVATE_KEY
                          GITLAB_CANARY_TOKEN
  quality-gate-promotion  QUALITY_GATE_RELEASE_APP_ID
                          QUALITY_GATE_RELEASE_APP_PRIVATE_KEY
  cachix-publish          CACHIX_AUTH_TOKEN   (rotate the token first)

The reusable release workflow runs without an environment, so the App secrets
must also stay available to it until the workflow in prefeitura-rio/actions
accepts an environment; review that exception before the first release.

Verify afterwards:
  gh api /repos/$repository/rulesets --jq '.[] | {name, enforcement}'
  gh api /repos/$repository/environments --jq '.environments[] | {name, can_admins_bypass}'
  gh api /repos/$repository/actions/permissions/workflow
EOF

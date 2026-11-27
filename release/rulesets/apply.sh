#!/usr/bin/env bash
# Applies, or verifies, the repository governance the Quality Gate release flow
# depends on: Environments, default workflow permissions and rulesets.
#
#   apply.sh --app-id ID             dry run: compare with GitHub, print what would change
#   apply.sh --app-id ID --apply     change only what differs; running it twice is a no-op
#   apply.sh --app-id ID --verify    read only; exit 1 when GitHub differs from the desired state
#
# --skip-ruleset NAME leaves one ruleset alone in every mode (repeatable). The
# `protect-master` ruleset requires the Quality Gate checks and review of code
# owners, which cannot be satisfied while the workflows still live only in the
# stacked pull requests; apply it once they are on master.
#
# It needs a token that administers the repository (`gh auth status`) and the
# release App to be installed; see APP-SETUP.md. Secret values are never read or
# copied: --verify only checks which secret names exist where.
set -euo pipefail

repository="prefeitura-rio/flakes"
mode="dry-run"
app_id=""
include_kodus=false
skipped_rulesets=()
rulesets_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# phrmendes, gabriel-milan
reviewer_ids=(22376151 35741485)

# Where each protected secret must live. Anything stored at repository level is
# readable by every branch with write access, so these names must not exist there.
secrets_of() {
  case "$1" in
    quality-gate-release) echo "QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY GITLAB_CANARY_TOKEN" ;;
    quality-gate-promotion) echo "QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY" ;;
    cachix-publish) echo "CACHIX_AUTH_TOKEN" ;;
    quality-gate-kodus-review) echo "KODUS_TEAM_KEY KODUS_TAILSCALE_CLIENT_ID KODUS_TAILSCALE_CLIENT_SECRET" ;;
  esac
}
environment_names="quality-gate-release quality-gate-promotion cachix-publish quality-gate-kodus-review"
protected_secrets="QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY GITLAB_CANARY_TOKEN CACHIX_AUTH_TOKEN KODUS_TEAM_KEY KODUS_TAILSCALE_CLIENT_ID KODUS_TAILSCALE_CLIENT_SECRET"

usage() {
  cat >&2 <<'EOF'
Usage: apply.sh --app-id ID [--repository OWNER/REPO] [--skip-ruleset NAME]... [--include-kodus] [--apply | --verify]

  --app-id ID        numeric ID of the release GitHub App (the "App ID" shown in
                     the App settings, not the installation ID)
  --repository R     repository to configure (default: prefeitura-rio/flakes)
  --skip-ruleset N   do not create, change or verify the ruleset called N (repeatable)
  --include-kodus    configure and verify the optional Kodus review Environment
  --apply            change what differs (default is a dry run)
  --verify           read only; exit 1 if the repository differs from the policy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) app_id="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --skip-ruleset) skipped_rulesets+=("$2"); shift 2 ;;
    --include-kodus) include_kodus=true; shift ;;
    --apply) mode="apply"; shift ;;
    --verify) mode="verify"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$app_id" =~ ^[0-9]+$ ]]; then
  echo "--app-id is required and must be numeric." >&2
  usage
  exit 2
fi

problems=()
problem() { problems+=("$1"); }

# GET that treats any failure (404 included) as "absent".
fetch() {
  gh api "/repos/$repository/$1" 2>/dev/null
}

# Like `fetch`, but a 404 answers with an empty listing: the resource does not
# exist yet, which is a fact other checks report. Any other failure, a 403 above
# all, leaves the status non-zero: it means "cannot know", not "empty".
fetch_listing() {
  local output errors
  errors="$(mktemp)"
  if output="$(gh api "/repos/$repository/$1" 2>"$errors")"; then
    rm -f "$errors"
    printf '%s' "$output"
    return 0
  fi
  if grep -q 'HTTP 404' "$errors"; then
    rm -f "$errors"
    echo '{}'
    return 0
  fi
  rm -f "$errors"
  return 1
}

# Writes the request, or only prints it unless --apply was given.
send() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "$mode" != apply ]]; then
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

# --- environments -----------------------------------------------------------

reviewers_json() {
  local entries=()
  for id in "${reviewer_ids[@]}"; do
    entries+=("{\"type\":\"User\",\"id\":$id}")
  done
  local IFS=,
  echo "[${entries[*]}]"
}

# Only master can deploy and admins cannot bypass. Only the emergency
# environment asks for human approval; the automated ones must not wait for a
# person on every canary analysis, promotion or cache publication.
environment() {
  local name="$1" reviewers="$2" expected_ids actual differences=()
  expected_ids="$(jq -c '[.[].id] | sort' <<<"$reviewers")"

  if ! actual="$(fetch "environments/$name")"; then
    differences+=("the environment does not exist")
  else
    [[ "$(jq -r '.can_admins_bypass' <<<"$actual")" == false ]] || differences+=("administrators can bypass it")
    [[ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$actual")" == true ]] || differences+=("deployments are not limited to custom branch policies")
    local actual_ids
    actual_ids="$(jq -c '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?.reviewer.id] | sort' <<<"$actual")"
    [[ "$actual_ids" == "$expected_ids" ]] || differences+=("reviewers are $actual_ids, expected $expected_ids")
    if [[ "$expected_ids" != "[]" ]]; then
      [[ "$(jq -r '[.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review] | first // false' <<<"$actual")" == true ]] || differences+=("self-review is allowed")
    fi
  fi

  if ((${#differences[@]} > 0)); then
    for difference in "${differences[@]}"; do problem "environment $name: $difference"; done
    echo "CHANGE   environment $name: ${differences[*]}"
    if [[ "$mode" != verify ]]; then
      send PUT "environments/$name" "$(jq -n --argjson reviewers "$reviewers" '{
        prevent_self_review: true,
        can_admins_bypass: false,
        reviewers: $reviewers,
        deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}
      }')"
    fi
  else
    echo "OK       environment $name"
  fi

  local policies
  if policies="$(fetch "environments/$name/deployment-branch-policies")" \
    && jq -e '.branch_policies[]? | select(.name == "master" and .type == "branch")' <<<"$policies" >/dev/null; then
    echo "OK       environment $name deploys from master only"
  else
    problem "environment $name: no branch policy for master"
    echo "CHANGE   environment $name: add the master branch policy"
    if [[ "$mode" != verify ]]; then
      send POST "environments/$name/deployment-branch-policies" '{"name":"master","type":"branch"}'
    fi
  fi
  if [[ "$name" == quality-gate-kodus-review && -n "${policies:-}" ]] && jq -e '.branch_policies[]? | select(.name != "master" or .type != "branch")' <<<"$policies" >/dev/null; then
    problem "environment $name: unexpected deployment branch or tag policy; remove it explicitly after review"
    echo "PENDING  environment $name has an additional deployment policy"
  fi
}

# --- workflow permissions ---------------------------------------------------

workflow_permissions() {
  local actual
  if actual="$(fetch "actions/permissions/workflow")" \
    && [[ "$(jq -r '.default_workflow_permissions' <<<"$actual")" == read ]] \
    && [[ "$(jq -r '.can_approve_pull_request_reviews' <<<"$actual")" == false ]]; then
    echo "OK       default workflow permissions are read-only"
  else
    problem "workflow permissions: default token is not read-only or workflows can approve pull requests"
    echo "CHANGE   workflow permissions"
    if [[ "$mode" != verify ]]; then
      send PUT "actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
    fi
  fi
}

# --- rulesets ---------------------------------------------------------------

# The parts of a ruleset that carry policy. GitHub fills in defaults for the
# rest, so comparing whole documents would always differ.
ruleset_facets='{
  target,
  enforcement,
  include: .conditions.ref_name.include,
  exclude: .conditions.ref_name.exclude,
  bypass: ([.bypass_actors[]? | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_id)),
  rules: ([.rules[] | {type} + (
      if .type == "pull_request" then
        {parameters: (.parameters | {dismiss_stale_reviews_on_push, require_code_owner_review, require_last_push_approval, required_approving_review_count, required_review_thread_resolution})}
      elif .type == "required_status_checks" then
        {parameters: {strict: .parameters.strict_required_status_checks_policy, checks: ([.parameters.required_status_checks[] | {context, integration_id}] | sort_by(.context))}}
      else {} end)] | sort_by(.type))
}'

ruleset() {
  local desired="$1" name id actual
  name="$(jq -r .name <<<"$desired")"

  for skipped in ${skipped_rulesets[@]+"${skipped_rulesets[@]}"}; do
    if [[ "$skipped" == "$name" ]]; then
      echo "SKIPPED  ruleset $name (--skip-ruleset)"
      return
    fi
  done
  id="$(fetch rulesets | jq -r --arg name "$name" '[.[] | select(.name == $name)] | first | .id // empty' || true)"

  if [[ -z "$id" ]]; then
    problem "ruleset $name does not exist"
    echo "CHANGE   ruleset $name: create"
    [[ "$mode" == verify ]] || send POST rulesets "$desired"
    return
  fi

  actual="$(fetch "rulesets/$id")"
  if [[ "$(jq -S "$ruleset_facets" <<<"$actual")" == "$(jq -S "$ruleset_facets" <<<"$desired")" ]]; then
    echo "OK       ruleset $name"
  else
    problem "ruleset $name differs from release/rulesets"
    echo "CHANGE   ruleset $name: update #$id"
    [[ "$mode" == verify ]] || send PUT "rulesets/$id" "$desired"
  fi
}

# --- secrets (read only: values are never touched) --------------------------

secrets() {
  # A listing that cannot be read is not an empty one: without it nobody knows
  # whether a protected secret is still stored where any branch can read it.
  local listing repository_secrets=""
  if listing="$(fetch_listing actions/secrets)"; then
    repository_secrets="$(jq -r '.secrets[]?.name' <<<"$listing")"
  else
    problem "cannot read the repository secrets (administrator access is needed); protected secrets at repository level were not checked"
    echo "UNKNOWN  repository secrets could not be read"
  fi
  for secret in $protected_secrets; do
    if grep -qx "$secret" <<<"$repository_secrets"; then
      problem "secret $secret is stored at repository level; move it to its environment and delete this copy"
      echo "PENDING  secret $secret is readable by every branch (repository level)"
    fi
  done
  local name present
  for name in $environment_names; do
    if [[ "$name" == quality-gate-kodus-review && "$include_kodus" != true ]]; then
      continue
    fi
    if ! listing="$(fetch_listing "environments/$name/secrets")"; then
      problem "cannot read the secrets of environment $name"
      echo "UNKNOWN  secrets of environment $name could not be read"
      continue
    fi
    present="$(jq -r '.secrets[]?.name' <<<"$listing")"
    if [[ "$name" != quality-gate-kodus-review ]]; then
      for secret in KODUS_TEAM_KEY KODUS_TAILSCALE_CLIENT_ID KODUS_TAILSCALE_CLIENT_SECRET; do
        if grep -qx "$secret" <<<"$present"; then
          problem "secret $secret is stored in environment $name; keep it only in quality-gate-kodus-review"
          echo "PENDING  secret $secret is present in unexpected environment $name"
        fi
      done
    fi
    for secret in $(secrets_of "$name"); do
      if ! grep -qx "$secret" <<<"$present"; then
        problem "secret $secret is missing from environment $name"
        echo "PENDING  secret $secret is missing from environment $name"
      fi
    done
  done
}

environment quality-gate-release '[]'
environment quality-gate-promotion "$(reviewers_json)"
environment cachix-publish '[]'
if [[ "$include_kodus" == true ]]; then
  environment quality-gate-kodus-review '[]'
fi
workflow_permissions

# Only the first tag ruleset names the App. Version tags also fall under it, so
# the second one, without any bypass, is what keeps even the App from moving or
# deleting a release: the strictest ruleset wins.
ruleset "$(jq --argjson app "$app_id" \
  '.bypass_actors = [{actor_id: $app, actor_type: "Integration", bypass_mode: "always"}]' \
  "$rulesets_dir/quality-gate-tags.json")"
ruleset "$(cat "$rulesets_dir/quality-gate-version-tags.json")"
ruleset "$(cat "$rulesets_dir/master.json")"

secrets

if ((${#problems[@]} == 0)); then
  echo
  echo "The repository matches the Quality Gate governance."
  exit 0
fi

echo
echo "${#problems[@]} difference(s) from the Quality Gate governance:"
printf '  - %s\n' "${problems[@]}"

cat <<EOF

Secrets are never copied by this script. Create them as environment secrets,
then delete the repository-level copies and run --verify again:

  quality-gate-release    QUALITY_GATE_RELEASE_APP_ID
                          QUALITY_GATE_RELEASE_APP_PRIVATE_KEY
                          GITLAB_CANARY_TOKEN
  quality-gate-promotion  QUALITY_GATE_RELEASE_APP_ID
                          QUALITY_GATE_RELEASE_APP_PRIVATE_KEY
  cachix-publish          CACHIX_AUTH_TOKEN   (rotate the token first)
EOF

# A dry run or an apply may leave differences behind (secrets, or changes not
# yet sent); only --verify turns them into a failure.
[[ "$mode" == verify ]] && exit 1
exit 0

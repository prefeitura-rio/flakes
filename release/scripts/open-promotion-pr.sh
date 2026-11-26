#!/usr/bin/env bash
# Opens the pull request that sets release/channels.yaml `latest` to a candidate
# whose canary analysis is healthy. It is safe to run every day:
#
#   - an open PR for the candidate  -> nothing to do
#   - a PR closed without merging   -> the candidate was rejected; warn and stop
#   - the branch exists, no PR      -> an earlier run pushed it and failed before
#                                      opening the PR; open the PR from it
#   - otherwise                     -> create the branch, commit and open the PR
#
# Run it from a checkout of the base branch whose `origin` can push.
set -euo pipefail

usage() {
  echo "Usage: open-promotion-pr.sh --version-tag quality-gate-vX.Y.Z [--base master]" >&2
}

version_tag=""
base="master"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version-tag) version_tag="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$version_tag" =~ ^quality-gate-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--version-tag must look like quality-gate-vX.Y.Z." >&2
  usage
  exit 2
fi

branch="automation/quality-gate-promotion-${version_tag}"
title="chore: promote Quality Gate ${version_tag}"
body="Automated canary analysis passed for \`${version_tag}\` after the three-day bake period. See the workflow artifact for per-sandbox findings and engine classification."
channels="release/channels.yaml"

pull_requests="$(gh pr list --state all --head "$branch" --json number,state --limit 20)"

open_pr="$(jq -r '[.[] | select(.state == "OPEN")] | first | .number // empty' <<<"$pull_requests")"
if [[ -n "$open_pr" ]]; then
  echo "Promotion PR #${open_pr} already exists for ${version_tag}."
  exit 0
fi

merged_pr="$(jq -r '[.[] | select(.state == "MERGED")] | first | .number // empty' <<<"$pull_requests")"
if [[ -n "$merged_pr" ]]; then
  echo "Promotion PR #${merged_pr} for ${version_tag} was already merged."
  exit 0
fi

closed_pr="$(jq -r '[.[] | select(.state == "CLOSED")] | first | .number // empty' <<<"$pull_requests")"
if [[ -n "$closed_pr" ]]; then
  echo "::warning::Promotion PR #${closed_pr} for ${version_tag} was closed without merging, so it is not proposed again. Delete the branch ${branch} to propose it again."
  exit 0
fi

latest_of() {
  awk -F': *' '$1 == "latest" { print $2 }' | tr -d '"'
}

if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git fetch --quiet origin "$branch"
  proposed="$(git show "FETCH_HEAD:${channels}" | latest_of)"
  if [[ "$proposed" != "$version_tag" ]]; then
    echo "Branch ${branch} exists but sets latest to \"${proposed}\", not ${version_tag}. Delete it and run again." >&2
    exit 1
  fi
  echo "Branch ${branch} already exists without a PR; opening the PR from it."
else
  git switch --create "$branch"
  previous="$(latest_of < "$channels")"
  sed -i -E "s/^latest:.*$/latest: \"${version_tag}\"/" "$channels"
  if grep -q '^previous:' "$channels"; then
    sed -i -E "s/^previous:.*$/previous: \"${previous}\"/" "$channels"
  else
    sed -i "/^latest:/a previous: \"${previous}\"" "$channels"
  fi
  git add "$channels"
  git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "$title"
  git push --set-upstream origin "$branch"
fi

gh pr create --base "$base" --head "$branch" --title "$title" --body "$body"

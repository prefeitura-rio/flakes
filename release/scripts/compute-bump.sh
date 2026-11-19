#!/usr/bin/env bash
# Prints the semantic version component to bump (major, minor or patch) for the
# commits between the previous release tag and the target, following
# Conventional Commits:
#
#   type!: ... or a "BREAKING CHANGE" footer   -> major
#   feat: ...                                 -> minor
#   anything else                             -> patch
set -euo pipefail

repository="."
previous_tag=""
target_sha=""

usage() {
  echo "Usage: compute-bump.sh --target-sha SHA [--previous-tag TAG] [--repository PATH]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repository="$2"; shift 2 ;;
    --previous-tag) previous_tag="$2"; shift 2 ;;
    --target-sha) target_sha="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$target_sha" ]]; then
  usage
  exit 2
fi

range="$target_sha"
if [[ -n "$previous_tag" ]]; then
  range="${previous_tag}..${target_sha}"
fi

bump="patch"
while IFS= read -r -d '' message; do
  subject="${message%%$'\n'*}"
  if [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$message"; then
    echo major
    exit 0
  fi
  if [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
    bump="minor"
  fi
done < <(git -C "$repository" log --format='%B%x00' "$range")

echo "$bump"

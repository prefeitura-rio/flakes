#!/usr/bin/env bash

set -euo pipefail

repository="."
remote="origin"
candidate_tag=""
floating_tag="quality-gate-latest"

usage() {
  cat >&2 <<'EOF'
Usage: move-floating-tag.sh --candidate-tag TAG [options]

Options:
  --repository PATH       Git repository path (default: .)
  --remote NAME           Git remote name (default: origin)
  --candidate-tag TAG    Immutable version tag to promote (required)
  --floating-tag TAG     Mutable tag to update (default: quality-gate-latest)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="$2"
      shift 2
      ;;
    --remote)
      remote="$2"
      shift 2
      ;;
    --candidate-tag)
      candidate_tag="$2"
      shift 2
      ;;
    --floating-tag)
      floating_tag="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$candidate_tag" ]]; then
  echo "--candidate-tag is required." >&2
  usage
  exit 2
fi

if [[ ! "$candidate_tag" =~ ^quality-gate-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Candidate tag must match quality-gate-vX.Y.Z." >&2
  exit 1
fi

candidate_sha=$(git -C "$repository" rev-parse --verify "${candidate_tag}^{commit}")

git -C "$repository" \
  -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  tag -fa "$floating_tag" "$candidate_sha" \
  -m "Promote ${candidate_tag}"

git -C "$repository" push "$remote" "refs/tags/${floating_tag}" --force

printf 'floating_tag=%s\n' "$floating_tag"
printf 'candidate_tag=%s\n' "$candidate_tag"
printf 'candidate_sha=%s\n' "$candidate_sha"

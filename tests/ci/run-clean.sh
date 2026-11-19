#!/usr/bin/env bash
# Runs the Quality Gate self-test in a clean Ubuntu container.
#
#   tests/ci/run-clean.sh
#
# The committed HEAD is cloned into the container, so commit (or stash) first:
# uncommitted changes are not tested. The Nix store lives in a named volume, so
# only the first run is slow. The volume is named after the image it was seeded
# from: the Nix profile lives in the image and points into the store, so a volume
# seeded by another image would be missing what the profile refers to. A change
# to the Dockerfile therefore starts a fresh volume; remove the old ones with
# `docker volume rm $(docker volume ls -q --filter name=quality-gate-clean-room-nix)`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="quality-gate-clean-room"
runtime="${CONTAINER_RUNTIME:-docker}"

if [ -n "$(git -C "$root" status --porcelain)" ]; then
  echo "warning: uncommitted changes are not part of this run" >&2
fi

# A worktree's .git points at a host path, so test a plain clone of HEAD.
source_clone="$(mktemp -d)"
trap 'rm -rf "$source_clone"' EXIT
git clone --quiet --no-hardlinks "$root" "$source_clone"
chmod -R a+rX "$source_clone"

"$runtime" build --quiet --tag "$image" "$root/tests/ci" >/dev/null
image_id="$("$runtime" image inspect --format '{{.Id}}' "$image")"
volume="quality-gate-clean-room-nix-${image_id#sha256:}"
volume="${volume:0:48}"

# The volume starts empty; seed it from the image the first time.
if ! "$runtime" volume inspect "$volume" >/dev/null 2>&1; then
  "$runtime" volume create "$volume" >/dev/null
  "$runtime" run --rm --user root --volume "$volume:/seed" "$image" \
    sh -c 'cp -a /nix/. /seed/ && chown -R runner /seed'
fi

"$runtime" run --rm \
  --volume "$volume:/nix" \
  --volume "$source_clone:/source:ro" \
  --env CI=true \
  "$image" bash -euo pipefail -c '
    git config --global --add safe.directory "*"
    git config --global --unset-all user.name 2>/dev/null || true
    git config --global --unset-all user.email 2>/dev/null || true
    git clone --quiet /source /home/runner/work
    cd /home/runner/work
    nix profile install --inputs-from . nixpkgs#devenv
    nix build .#quality-gate .#quality-gate-detect .#quality-gate-python .#quality-gate-go .#quality-gate-typescript --no-link
    devenv tasks run quality-gate:self-test
  '

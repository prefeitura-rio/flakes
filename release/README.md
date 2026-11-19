# Quality Gate releases

The flakes repository is the only source of truth for the Quality Gate motor:
the Nushell orchestrator, rules, configurations and tool versions are built by
the flake's own `flake.lock`.

## Automatic release

After a push to `master`, `Quality Gate Tests` runs the internal tests and
validates the `quality-gate` flake app. The release workflow starts only after
that workflow succeeds for the exact same commit.

The release sequence is:

```text
validate master tip
calculate quality-gate-vX.Y.Z
validate master tip again
atomically publish immutable version tag and quality-gate-next
```

The immutable tag is the audit trail. Consumers use `quality-gate-latest`, which
is promoted separately after the three-day bake period and an approved channel
PR. The first release creates `quality-gate-next`; `latest` is promoted by the
Quality Gate Promotion workflow.

The new flakes-based motor starts at `quality-gate-v1.0.0`; the previous
`quality-gate-v1.x` tags belonged to the frozen implementation in
`prefeitura-rio/actions` and are not reused by this repository.

The release workflow compares the four Quality Gate app derivations
(`quality-gate`, `-python`, `-go` and `-typescript`) across the supported
systems with the last `quality-gate-v*` tag. Changes to unrelated flakes
packages, infrastructure profiles or documentation do not create a new
Quality Gate release. Changes to the Quality Gate bootstrap profile are also
treated as release-worthy.

## Canary promotion

`release/channels.yaml` declares the stable channel and its three-day bake
period. A PR changing `latest` is validated by `release/promote.nu` and a push
of the approved PR promotes `quality-gate-latest`. The manual workflow supports
an approved emergency rollback to any existing immutable version tag.

Before the first approved promotion, `quality-gate-latest` does not exist. The
default consumer configuration intentionally fails with an explicit
unresolved-reference message instead of silently selecting an untested
revision.

To opt a consumer into the canary during the bake period, set:

- local hooks: `QUALITY_GATE_REF=quality-gate-next`;
- GitLab CI: `PREFRIO_REF=quality-gate-next`.

The canary is opt-in. `quality-gate-latest` remains the stable channel and is
only updated by the promotion workflow.

The release and promotion workflows are prepared for a dedicated GitHub App;
see [the setup runbook](rulesets/APP-SETUP.md). Until that App is installed and
the tag ruleset is applied, do not publish the first Quality Gate release.

The canary analysis workflow triggers the five sandbox pipelines with the
candidate SHA, waits for all Quality Gate jobs, downloads their traces and
compares them with `release/canary-expectations.yaml`. A failed check is
healthy only when it is an expected finding for that fixture. Engine markers
such as exit code 3, missing cache/configuration, permission errors or runner
failures always make the candidate unhealthy. Healthy candidates that complete
the bake period produce an automated promotion PR.

## Consumer synchronization

The GitLab adapter resolves `quality-gate-latest` to one commit SHA at the start
of a pipeline. Detection publishes that SHA as a dotenv artifact, and every
Quality Gate job runs the app from that exact SHA. A release occurring while a
pipeline is running cannot split its jobs between two revisions.

The local hook resolves the same tag before each commit. If the network is
temporarily unavailable, it may use the cached SHA for up to 14 days and emits
an explicit warning. A missing or older cache blocks the commit. `--no-verify`
remains an intentional bypass, with CI as the final barrier.

## Release toolkit

The release workflow reuses the provider-neutral workflow from
`prefeitura-rio/actions`, pinned to commit
`b8e2a9d72d350362d228f48c84e086d9aec679e9`. That reusable workflow performs
the target validation, version calculation, gate verification and atomic tag
publication. The flakes repository does not duplicate or checkout the release
scripts.

The release toolkit's contract tests run in the `actions` repository, which is
the owner of that reusable release infrastructure.

## Binary cache

The Quality Gate workflows use the public `prefeitura-rio` Cachix cache and
also pull the public `devenv` cache. The cache stores the Quality Gate-specific
derivations that are not available from `cache.nixos.org`, notably the
`complexipy` package and the small flake wrappers.

The GitHub secret `CACHIX_AUTH_TOKEN` is used only by trusted builds on
`master` (or an explicitly approved manual run) to publish results. Pull
requests can read the public cache but never push to it. A cache miss remains
safe: Nix falls back to the official cache and builds the missing derivation
locally.

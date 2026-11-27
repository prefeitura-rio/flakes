# Quality Gate releases

The flakes repository is the only source of truth for the Quality Gate motor:
the Nushell orchestrator, rules, configurations and tool versions are built by
the flake's own `flake.lock`.

## Automatic release

After a push to `master`, `Quality Gate Tests` runs the internal tests and
validates the five `quality-gate` flake apps. The release workflow starts only
after that workflow succeeds for the exact same commit.

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

### What makes a release

The release workflow compares the derivations of the five apps (`quality-gate`,
`quality-gate-detect` and the Python, Go and TypeScript ones) across the
supported systems with the last `quality-gate-v*` tag. Changes to unrelated
flakes packages, infrastructure profiles, tests or documentation do not create a
release.

Two files are imported by consumers straight from this repository, outside those
derivations, and are compared as files: the bootstrap profile
`devenv/quality-gate.nix` and its runner `devenv/files/quality-gate/runner.nix`.
A change to either one is released too, so it goes through the bake time like any
other change of the motor.

### Version bump

The component to bump comes from the commits since the previous release
(`release/scripts/compute-bump.sh`), following Conventional Commits:

| Commits since the last tag | Bump |
| --- | --- |
| `type!:` in a subject, or a `BREAKING CHANGE:` footer | major |
| at least one `feat:` | minor |
| anything else | patch |

The first release is `1.0.0` (`initial_version`), the first stable version of the
flakes-based motor.

## Canary promotion

`release/channels.yaml` declares the stable channel and its three-day bake
period. A PR changing `latest` is validated by `release/promote.nu`, and a push
of the approved PR promotes `quality-gate-latest`.

Before the first approved promotion, `quality-gate-latest` does not exist. The
default consumer configuration intentionally fails with an explicit
unresolved-reference message instead of silently selecting an untested
revision.

To opt a consumer into the canary during the bake period, set:

- local hooks: `QUALITY_GATE_REF=quality-gate-next`;
- GitLab CI: `QUALITY_GATE_REF=quality-gate-next`.

The canary is opt-in. `quality-gate-latest` remains the stable channel and is
only updated by the promotion workflow.

### Rollback

The manual workflow only rolls `quality-gate-latest` back to an immutable tag
that is **older** than the current stable one. It needs a second approval and
never moves forward. See
[the runbook](../docs/runbooks/failed-quality-gate-release.md).

### The canary analysis

The canary analysis workflow triggers the five sandbox pipelines with the
candidate SHA, waits for them and downloads the JUnit report that the engine
writes for each Quality Gate job. Every check is classified as `finding` or
`engine` from that report, never from the log text, and compared with
`release/canary-expectations.yaml`:

- a failed check is healthy only when it is an expected finding of that sandbox;
- an expected finding that does not happen makes the candidate unhealthy;
- any `engine` result, a missing report, a job that did not finish, or a
  diagnostic mentioning `.cache/quality-gate/` does too.

The analysis retains up to 1024 UTF-8 bytes of each diagnostic reason without
splitting a character, and marks longer ones as truncated. Classification uses
the original message; the complete diagnostic remains in the sandbox job's
GitLab artifact. Cache diagnostics are checked before truncation.

The candidate must be the target of an immutable `quality-gate-v*` tag of this
repository. A healthy candidate whose bake time is over produces the automatic
promotion PR.

**The analysis is the proof of promotion.** `release/scripts/verify-canary-health.sh`
accepts the artifact `quality-gate-canary-<sha>` only from a successful run of the
analysis workflow on `master` of this repository, started by the schedule, a
`workflow_run` or a manual dispatch, and only when the JSON inside is healthy and
names the same commit. It also requires analysis version 2, which includes the
cache diagnostic check; older artifacts cannot satisfy promotion. Any workflow
of the repository can upload an artifact with any name, so the name alone proves
nothing. Both the validation of a promotion PR and the `promote` job require such
a proof made **after the end of the bake**: the sandboxes are checked again at
the end, not only on the first day.

### What the sandboxes must cover

A canary built only from repositories that are expected to fail cannot notice a
check that starts flagging clean code, nor a broken test job. The evaluator
(`release/canary-analysis.nu`) already supports both shapes, so covering them is a
matter of adding projects to `release/canary-expectations.yaml`:

- a **clean sandbox**: `expected_findings: []` and `expected_skipped: []`. Every
  check must pass and the `quality-gate:tests` job must run and pass, so a false
  positive or a broken test runner makes the candidate unhealthy;
- a sandbox with a **failing test**: `expected_findings` lists the test check
  (for example `test:python:pytest`). It must keep failing, as a finding.

The GitLab projects themselves are created outside this repository; each one
needs its project `id` in the file.

The validation of the PR runs the script from the PR itself and is informational;
the `promote` job runs on `master` and is the one that enforces it.

## Consumer synchronization

The GitLab adapter resolves `quality-gate-latest` to one commit SHA in the
`quality-gate:detect` job and publishes it in the dotenv report as
`QUALITY_GATE_PIPELINE_REVISION`. Every other job of the pipeline runs exactly
that SHA, so a release or a rollback while a pipeline is running cannot split it
between two revisions.

The local hook resolves the same tag before each commit. If the network is
temporarily unavailable, it may use the cached SHA for up to 14 days and emits
an explicit warning. A missing or older cache blocks the commit. `--no-verify`
remains an intentional bypass, with CI as the final barrier.

A consumer imports the bootstrap profile from this repository. To make that part
follow the channel and its bake time, declare the input on the channel tag, as
shown in the [README](../README.md#devenv-profiles).

## Release toolkit

The release workflow reuses the provider-neutral workflow from
`prefeitura-rio/actions`, pinned to commit
`f7f930e3a1ee9306fe7a7f2a780c3747803bbee3`, with the toolkit at
`b8e2a9d72d350362d228f48c84e086d9aec679e9`. That reusable workflow performs the
target validation, version calculation, gate verification and atomic tag
publication, and it runs in the `quality-gate-release` Environment. The flakes
repository does not duplicate or check out the release scripts.

The release toolkit's contract tests run in the `actions` repository, which is
the owner of that reusable release infrastructure.

## Binary cache

The Quality Gate workflows use the public `prefeitura-rio` Cachix cache and
also pull the public `devenv` cache. The cache stores the Quality Gate-specific
derivations that are not available from `cache.nixos.org`, notably the
`complexipy` package and the small flake wrappers.

`CACHIX_AUTH_TOKEN` exists only in the `cachix-publish` Environment, which only
`master` can use. Only the two `publish-*` jobs read it, after the tests, and only
for a push to `master`. Pull requests can read the public cache but never push to
it. A cache miss remains safe: Nix falls back to the official cache and builds the
missing derivation locally. Those jobs do not block a release either: a cache
outage costs a local build, not a delayed fix.

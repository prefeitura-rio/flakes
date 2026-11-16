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
atomically publish immutable version tag and quality-gate-latest
```

The immutable tag is the audit trail. Consumers use `quality-gate-latest`, which
is moved only by this workflow after the gate passes.

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

The release workflow reuses the provider-neutral toolkit from
`prefeitura-rio/actions`, pinned to commit
`13dc55b38fd546b1a2805ba72374efc2cf5c38ba`. The flakes repository does not
duplicate the release scripts. The toolkit's own contract tests are executed
from that pinned checkout by the Quality Gate Tests workflow.

```bash
bash release-toolkit/release/tests/test-version.sh
bash release-toolkit/release/tests/test-publish-tags.sh
```

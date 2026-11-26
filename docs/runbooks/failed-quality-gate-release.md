# Failed Quality Gate release

## Signals

- `quality-gate-next` points to a release that cannot be promoted after the
  three-day bake time.
- The promotion workflow rejects `release/channels.yaml`.
- The scheduled reconciliation workflow opens
  `[Quality Gate] release channels diverged`.

## Recovery

### Roll back `quality-gate-latest`

Run `Quality Gate Promotion` manually, select an **older** immutable
`quality-gate-vX.Y.Z` tag, provide the incident reason, and have a second
reviewer approve the `quality-gate-promotion` environment. The emergency path
refuses any version that is not older than the current stable one, and it only
works when a stable channel already exists.

The workflow opens a PR that sets `release/channels.yaml` to the same tag. That
PR validates as a no-op because the channel already points to the tag. The
reconciliation issue stays open, with a single updated comment, until the
declared channel and the tag agree.

### Stop the line

1. Pause releases: disable the `Quality Gate Release` workflow so no new
   `quality-gate-next` is published while the incident is open.
2. Roll `quality-gate-latest` back as above.
3. If `quality-gate-next` also points at the bad release, publish a fixed
   release; `next` only moves forward and is never rolled back by hand.
4. Re-enable the release workflow after the fix has baked in the sandboxes.

### Promoting a newer version

There is no emergency path to a newer version. A fixed release must complete
the three-day bake and the canary analysis, and is promoted by the normal PR.
The promotion needs a healthy canary analysis made **after** the bake ended
(`release/scripts/verify-canary-health.sh`): the PR is validated against it and
the `promote` job refuses to move the tag without it. If the PR was approved by
hand before that analysis exists, `promote` fails and nothing moves; run the
`Quality Gate Canary Analysis` workflow for the candidate and run `promote` again.

If the workflows or GitHub Actions are unavailable, a repository administrator
can move the tag manually with the release App credentials, following
`release/rulesets/APP-SETUP.md`, and must record the reason in the incident.
That path needs the App private key, so its safekeeping is part of the
preparation, not of the incident: the key must be kept in the company's password
vault, readable by at least two administrators, and rotated after every use.
The vault and the two people are decided by the owners of the Quality Gate and
are recorded in `APP-SETUP.md`.

### A released version cannot be changed

`protect-quality-gate-version-tags` forbids updating or deleting any
`quality-gate-v*` tag, and it has **no bypass actor**, not even the release App.
A bad release is never fixed by moving its tag: publish a new version and roll
`quality-gate-latest` back meanwhile. If a version tag really has to go (for
example one published by mistake), an organization owner disables that ruleset,
removes the tag and enables it again, and the incident records it.

## Safety

- Immutable version tags are never moved.
- Promotion and rollback only move `quality-gate-latest`.
- A second human approval (not the requester) is required for an emergency rollback.

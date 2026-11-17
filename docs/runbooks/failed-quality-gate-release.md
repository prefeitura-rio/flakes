# Failed Quality Gate release

## Signals

- `quality-gate-next` points to a release that cannot be promoted after the
  three-day bake time.
- The promotion workflow rejects `release/channels.yaml`.
- The scheduled reconciliation workflow opens
  `[Quality Gate] release channels diverged`.

## Recovery

For an emergency rollback, run `Quality Gate Promotion` manually, select the
previous immutable `quality-gate-vX.Y.Z` tag, provide the incident reason, and
approve the `quality-gate-promotion` environment.

After the emergency action, open a PR updating `release/channels.yaml` to the
same stable tag. The reconciliation issue closes automatically once the
declared channel and tag agree.

## Safety

- Immutable version tags are never moved.
- Promotion and rollback only move `quality-gate-latest`.
- A human approval is required for manual emergency promotion/rollback.

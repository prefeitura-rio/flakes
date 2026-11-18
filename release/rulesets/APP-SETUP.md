# Quality Gate release identity

The release and promotion workflows are prepared for a dedicated GitHub App.
The App must be created and installed by an organization owner; this document
is intentionally a runbook, not an automatic administrative change.

## App permissions

Install the App only on `prefeitura-rio/flakes` with repository contents,
pull requests, and issues read/write permissions, and metadata read
permission. Disable Actions approval and workflow creation for the App.

Store its App ID and private key as:

```text
QUALITY_GATE_RELEASE_APP_ID
QUALITY_GATE_RELEASE_APP_PRIVATE_KEY
```

Rotate the private key after installation. The workflows use the App only for
release tags and emergency synchronization PRs.

Configure the `quality-gate-promotion` Environment with at least two required
reviewers (`phrmendes` and `gabriel-milan`, or the responsible team) and
disable self-review. The person who requests an emergency operation must not
be able to approve their own request.

## Ruleset actor

Set the bypass actor in
`release/rulesets/quality-gate-tags.json` to the numeric integration ID of
the installed App (`5818520` in the current organization). The tags ruleset
must allow only this App to create, update or delete `quality-gate-*` refs.

Do not use the generic GitHub Actions integration as a bypass actor: a workflow
from an unreviewed branch would then have the same authority. The App must
also be the identity used by the reusable release workflow and by emergency
promotion. PRs created by the App trigger normal validation workflows.

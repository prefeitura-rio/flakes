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

## Ruleset actor

Replace the placeholder bypass actor in
`release/rulesets/quality-gate-tags.json` with the numeric integration ID of
the installed App. The tags ruleset must allow only this App to create, update
or delete `quality-gate-*` refs.

Do not use the generic GitHub Actions integration as a bypass actor: a workflow
from an unreviewed branch would then have the same authority. The App must
also be the identity used by the reusable release workflow and by emergency
promotion. PRs created by the App trigger normal validation workflows.

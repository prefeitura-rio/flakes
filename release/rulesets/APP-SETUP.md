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

## Backup of the private key

The manual path of the runbook, used when GitHub Actions is down, needs the App
private key. It is kept in the company's password vault, readable by at least two
administrators, and rotated after every use. Vault and owners: _to be recorded
here by the owners of the Quality Gate_.

## Applying the governance

`apply.sh` configures everything this flow depends on: the three Environments
(only `master` may deploy, admins cannot bypass, the emergency one requires the
two reviewers and forbids self-review), read-only default workflow permissions
and the three rulesets, with the App as the only bypass actor of the tags ruleset and no bypass actor at all on the version tags.
It compares each resource with GitHub first, so running it again changes nothing.

```bash
release/rulesets/apply.sh --app-id <App ID>             # dry run
release/rulesets/apply.sh --app-id <App ID> --apply     # apply
release/rulesets/apply.sh --app-id <App ID> --verify    # read only, exit 1 on drift
```

Use the **App ID** from the App settings page, not the installation ID.

## Where each secret lives

A secret stored at repository level is readable by a workflow in any branch with
write access, which would let that branch mint an App token and move the
`quality-gate-*` tags the ruleset protects. Every protected secret therefore
lives only in the Environment that guards it, and the job that uses it declares
that Environment:

| Environment | Secrets | Used by |
| --- | --- | --- |
| `quality-gate-release` | `QUALITY_GATE_RELEASE_APP_ID`, `QUALITY_GATE_RELEASE_APP_PRIVATE_KEY`, `GITLAB_CANARY_TOKEN` | release (through the `environment` input of the reusable release workflow), automated promotion, canary analysis |
| `quality-gate-promotion` | `QUALITY_GATE_RELEASE_APP_ID`, `QUALITY_GATE_RELEASE_APP_PRIVATE_KEY` | emergency rollback (two reviewers) |
| `cachix-publish` | `CACHIX_AUTH_TOKEN` | the two cache publication jobs |

The reusable release workflow in `prefeitura-rio/actions` accepts an optional
`environment` input; `quality-gate-release.yml` passes `quality-gate-release`
and still hands over the two App secrets by name. After the Environments exist,
create the secrets there, **delete the repository-level copies** (rotate the
Cachix token first, since it was readable until now) and run `--verify`: it
fails while any copy remains or any Environment secret is missing.

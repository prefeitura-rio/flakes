# Quality Gate rulesets

These JSON files are the desired repository policy for `master` and all
`quality-gate-*` tags. They are kept as code so the policy can be reviewed
alongside the release workflow.

The tag ruleset allows the GitHub Actions integration (ID `15368`) to publish
immutable version tags and move the mutable `quality-gate-latest` tag. All
other actors are blocked from creating, updating or deleting matching tags.
Version tags remain immutable in the release script; the bypass is required
only because GitHub cannot distinguish the mutable tag from the version-tag
pattern.

The `master` ruleset requires pull-request delivery, linear history, and the
Quality Gate self-test status. It intentionally has no bypass actor.

## Apply

Applying a ruleset is an administrative operation. Review the JSON and the
repository's current branch policy before applying it:

```bash
gh api --method POST \
  repos/prefeitura-rio/flakes/rulesets \
  --input release/rulesets/quality-gate-tags.json

gh api --method POST \
  repos/prefeitura-rio/flakes/rulesets \
  --input release/rulesets/master.json
```

Use `PATCH /repos/prefeitura-rio/flakes/rulesets/<id>` when updating an
existing ruleset rather than creating a duplicate. Inspect current rulesets
first:

```bash
gh api repos/prefeitura-rio/flakes/rulesets \
  --jq '.[] | [.id, .name, .enforcement, .target] | @tsv'
```

The rulesets are not applied automatically by CI.

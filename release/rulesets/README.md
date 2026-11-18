# Quality Gate rulesets

These JSON files are the desired repository policy for `master` and all
`quality-gate-*` tags. They are kept as code so the policy can be reviewed
alongside the release workflow.

The tag ruleset allows only the dedicated release GitHub App (App ID `5818520`,
see [APP-SETUP.md](APP-SETUP.md)) to create, update or delete `quality-gate-*`
tags: it publishes immutable version tags and moves the mutable
`quality-gate-next` and `quality-gate-latest` tags. Everyone else, including the
generic GitHub Actions integration, is blocked. Version tags stay immutable in
the release script; the bypass exists only because GitHub cannot tell the mutable
tags from the version-tag pattern.

The `master` ruleset requires pull-request delivery, code-owner review, linear
history, and the Quality Gate self-test and Darwin build. It has no bypass actor.

## Apply and verify

Applying governance is an administrative operation, so it is never done by CI.
Use `apply.sh` instead of calling the API by hand: it compares every resource
with GitHub and only changes what differs, so it can be run again at any time.

```bash
release/rulesets/apply.sh --app-id 5818520             # dry run: what would change
release/rulesets/apply.sh --app-id 5818520 --apply     # change it
release/rulesets/apply.sh --app-id 5818520 --verify    # read only; exit 1 on any difference
```

It covers the three Environments, the default workflow permissions and both
rulesets (an existing ruleset with the same name is updated with
`PUT /repos/prefeitura-rio/flakes/rulesets/<id>`, never duplicated). `--verify`
also fails while any protected secret is still stored at repository level or is
missing from its Environment; secret values are never read or copied.

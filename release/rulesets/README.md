# Quality Gate rulesets

These JSON files are the desired repository policy for `master`, for the
`quality-gate-*` tags and for the immutable `quality-gate-v*` version tags. They
are kept as code so the policy can be reviewed alongside the release workflow.

| File | Ruleset | Rules | Bypass |
| --- | --- | --- | --- |
| `master.json` | `protect-master` | pull request with code-owner review, approval of the last push, linear history, required checks | none |
| `quality-gate-tags.json` | `protect-quality-gate-tags` | creation, update and deletion of `quality-gate-*` | the release App only |
| `quality-gate-version-tags.json` | `protect-quality-gate-version-tags` | update and deletion of `quality-gate-v*` | **none** |

The tag ruleset allows only the dedicated release GitHub App (App ID `5818520`,
see [APP-SETUP.md](APP-SETUP.md)) to create, update or delete `quality-gate-*`
tags: it publishes immutable version tags and moves the mutable
`quality-gate-next` and `quality-gate-latest` tags. Everyone else, including the
generic GitHub Actions integration, is blocked. Version tags stay immutable in
the release script; the bypass exists only because GitHub cannot tell the mutable
tags from the version-tag pattern.

The second tag ruleset is what makes a version immutable. The first one must let
the App move the mutable `quality-gate-next` and `quality-gate-latest`, and
GitHub cannot tell them apart from a version tag by the name pattern alone, so
the App could also move or delete `quality-gate-v1.2.0`. Rulesets add up and the
strictest wins, so a second one over `quality-gate-v*` without any bypass actor
forbids that, for the App too. Creating a version tag is still left to the App
by the first ruleset.

The `master` ruleset requires pull-request delivery, code-owner review, linear
history, and the Quality Gate self-test and Darwin build. It has no bypass actor.
The two checks are accepted only when GitHub Actions reports them: a commit
status of the same name, which anyone with write access can post, does not satisfy
them. A code owner who pushes to a pull request cannot approve it either, because
the approval of the last push must come from someone else.

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

## Order of application

`protect-master` requires the Quality Gate checks and code-owner review, so it
can only be applied once the workflows exist on `master`. Apply everything else
first and leave it out:

```bash
release/rulesets/apply.sh --app-id 5818520 --apply  --skip-ruleset protect-master
release/rulesets/apply.sh --app-id 5818520 --verify --skip-ruleset protect-master
```

After the Quality Gate is merged, run both commands again without the flag.

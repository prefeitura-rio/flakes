# Advisory Kodus review of Quality Gate self-tests

The optional workflow `.github/workflows/quality-gate-kodus-review.yml` runs
after `Quality Gate Tests` completes for a PR. It selects a current, open,
same-repository PR targeting `master` only when files under `tests/` changed.
It writes the advisory findings to the GitHub Actions job summary and submits a
comment-only PR review as `github-actions[bot]`. Findings on added diff lines
are posted inline; others appear in the review body. It never approves or
requests changes. Before posting, it checks the PR is open and both the head and
base match the review; summaries can still become stale. Repeated runs for the
same head and base do not post duplicate reviews. Failures are reported as unavailable,
not as a clean review. Fork PRs and runs with missing or ambiguous PR
associations are skipped. It does not review the entire suite, prove tests
meaningful, run mutations, or replace human review.

The privileged workflow runs from the protected default branch using
`workflow_run`, rather than exposing credentials to `pull_request` workflows.
It reads PR metadata using GitHub, fetches Git objects into an **empty working
tree**, and never checks out, executes or downloads artifacts from PR code.
The job needs `pull-requests: write` to post comments. This is a job-level token
permission available to actions in the job; actions are pinned by commit. The
comment command receives the token explicitly, and the Kodus CLI does not.
Repository approval settings must remain unchanged. The CLI sees the complete
committed diff and a bounded selection of changed test blobs as context. An
adversarial PR can still submit prompt-injection
content; review output is untrusted. The Kodus backend may need access to the
GitHub repository for context not present in the diff; this has not been
validated with the GitLab-only Kodus connection.

## Before enabling

1. Confirm the self-hosted Kodus version supports CLI 0.4.22, team-key reviews,
   GitHub-hosted source context, and the selected model. Test auth failure,
   trial fallback, incomplete output, and data handling. Current upstream CLI
   documentation may describe features newer than the deployed server.
   CLI 0.4.22 can submit the diff to the self-hosted trial endpoint after an
   authentication 401. The wrapper rejects results marked as trial, but the
   submission has already occurred. Confirm the server's trial response and
   data handling are acceptable before enabling the workflow; a missing trial
   marker cannot be distinguished from a normal review by the wrapper.
2. Review the Tailscale policy and ingress changes in the infrastructure
   repository. Apply them only after an approved plan, ensuring `tag:kodus-api`
   is attached only to the Kodus API ingress and `tag:kodus-github-ci` can reach
   only that tag on TCP 443. Changing ingress tags can recreate its Tailscale
   device; plan for hostname/certificate continuity and test connectivity.
3. Create a dedicated Tailscale OAuth client constrained to
   `tag:kodus-github-ci` with `auth_keys` write access, and a dedicated Kodus
   team key with only the necessary review permissions. Set expiration,
   ownership, rotation, cost controls, and incident response. Neither secret
   belongs at repository or organization scope.
4. Run `release/rulesets/apply.sh --app-id <ID> --include-kodus` as a dry run.
   After review and explicit authorization, apply it, install the three secrets
   in the master-only `quality-gate-kodus-review` Environment, and run the same
   command with `--verify`. Ensure there are no extra deployment branch/tag
   policies and no repository-level copies of the protected secret names. The
   Environment must not allow admin bypass. Check organization secrets too;
   `apply.sh` only checks repository and Environment secret names.
5. Set repository variable `KODUS_SELF_TEST_API_URL` to the approved private
   HTTPS origin (`https://kodus-api.squirrel-regulus.ts.net` or the documented
   `kodus-api-1` collision variant). Confirm direct TLS and DNS from a
   GitHub-hosted runner. The Tailscale action uses a normal network interface;
   the CLI does not reliably use a userspace HTTP proxy.
6. Review the CLI's transitive npm dependencies and OS/runtime supply chain
   before production. The workflow pins CLI 0.4.22, Node/npm and the SHA-256
   of its generated npm lock, then uses `npm ci` with lifecycle scripts off.
   Registry resolution drift fails closed until the lock hash is reviewed and
   updated. Installation happens before any Kodus or Tailscale secrets are
   supplied; the hosted runner itself remains an external dependency.
7. Test a controlled PR, including a deliberately weak test and a clean test,
   a stale head or base, duplicate runs, a fork, a provider outage and a
   Tailscale failure. Check inline placement, review-body fallbacks and the
   intended SHA; failures must be visible, no PR code may run, and the existing
   required checks and releases must remain unaffected. Confirm GitHub accepts
   comment-only reviews without changing the repository approval setting.
   Then set `KODUS_SELF_TEST_REVIEW_ENABLED=true` as a repository variable.

## Disable and troubleshoot

Set `KODUS_SELF_TEST_REVIEW_ENABLED` to `false` or remove it. Investigate the
workflow run for selection, network, CLI and GitHub API errors without printing
secrets, raw test output or private code. Revoke the dedicated credentials if
compromise is suspected. No review runs if selection cannot identify a current
PR; GitHub may omit the association for forked or old workflow runs.

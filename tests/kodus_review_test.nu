use std/assert
use std/testing *
use support/qg.nu

const ROOT = path self | path dirname | path join ..
const SELECT = path self | path dirname | path join .. release kodus select-pr.py
const PREPARE = path self | path dirname | path join .. release kodus prepare-review.py
const PUBLISH = path self | path dirname | path join .. release kodus publish-review.py
const REVIEW = path self | path dirname | path join .. release kodus run-review.py
const TRIAL_GUARD = path self | path dirname | path join .. release kodus disable-trial-fallback.py
const WORKFLOW = path self | path dirname | path join .. .github workflows quality-gate-kodus-review.yml

def fixture [] {
    let head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    let base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    let repo = 'prefeitura-rio/flakes'
    {
        repository: $repo
        event: {workflow_run: {event: pull_request, path: '.github/workflows/quality-gate-tests.yml', head_sha: $head, head_repository: {full_name: $repo}, pull_requests: [{number: 42}]}}
        pr: {number: 42, state: open, changed_files: 1, base: {sha: $base, ref: master, repo: {full_name: $repo}}, head: {sha: $head, repo: {full_name: $repo}}}
        files: [{filename: 'tests/quality-gate_test.nu'}]
    }
}

def run-selection-fixture [input: record] {
    $input | to json | ^python3 $SELECT --fixture | complete
}

@test
def test_kodus_selects_only_current_self_test_pull_requests [] {
    let data = fixture
    let accepted = run-selection-fixture $data
    assert equal $accepted.exit_code 0 $accepted.stderr
    assert equal ($accepted.stdout | from json | get review) true
    for case in [
        ($data | update pr.head.sha 'cccccccccccccccccccccccccccccccccccccccc')
        ($data | update pr.head.repo.full_name 'other/fork')
        ($data | update event.workflow_run.path '.github/workflows/other.yml')
        ($data | update pr.state closed)
        ($data | update files [{filename: README.md}])
    ] {
        let outcome = run-selection-fixture $case
        assert equal $outcome.exit_code 0 $outcome.stderr
        assert equal ($outcome.stdout | from json | get review) false
    }
    let renamed = $data | update files [{filename: other.nu, previous_filename: 'tests/old.nu'}]
    assert equal (run-selection-fixture $renamed | get stdout | from json | get review) true
    let incomplete = $data | update pr.changed_files 2
    assert ((run-selection-fixture $incomplete | get exit_code) != 0) 'incomplete file listings must fail, not pass'
}

@test
def test_kodus_context_reads_git_blobs_not_worktree_symlinks [] {
    let repo = mktemp --directory | str trim
    try {
        qg commit-all $repo
        let base = ^git -C $repo rev-parse HEAD | str trim
        qg write-file $repo 'tests/case.nu' 'assert behavior'
        ^ln -s /proc/self/environ ($repo | path join tests leak.nu)
        qg commit-all $repo
        let head = ^git -C $repo rev-parse HEAD | str trim
        let command = 'import importlib.util,sys; s=importlib.util.spec_from_file_location("prep",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.make_context(sys.argv[2],sys.argv[3],sys.argv[4]))'
        let result = with-env {PYTHONDONTWRITEBYTECODE: '1'} { ^python3 -c $command $PREPARE $repo $base $head | complete }
        assert equal $result.exit_code 0 $result.stderr
        assert ($result.stdout | str contains 'assert behavior')
        assert not ($result.stdout | str contains '/proc/self/environ')
    } finally {
        qg cleanup $repo
    }
}

@test
def test_kodus_review_uses_trusted_workflow_and_optional_environment [] {
    let workflow = open --raw $WORKFLOW | from yaml
    assert equal $workflow.on.workflow_run.workflows ['Quality Gate Tests']
    assert equal $workflow.jobs.review.environment quality-gate-kodus-review
    assert ($workflow.jobs.select.if | str contains "vars.KODUS_SELF_TEST_REVIEW_ENABLED == 'true'")
    let steps = $workflow.jobs.review.steps
    let checkouts = $steps | where {|step| ($step.uses? | default '') | str starts-with 'actions/checkout@' }
    assert equal ($checkouts | length) 1
    assert equal ($checkouts | first | get with.ref) '${{ github.sha }}'
    assert equal ($checkouts | first | get with.persist-credentials) false
    assert equal $workflow.jobs.review.permissions.checks write
    let tailscale = $steps | where {|step| ($step.uses? | default '') | str starts-with 'tailscale/github-action@' } | first
    assert equal $tailscale.with.tags 'tag:kodus-github-ci'
    let runs = $steps | each {|step| $step.run? | default '' } | str join "\n"
    assert ($runs | str contains 'release/kodus/prepare-review.py')
    assert ($runs | str contains 'release/kodus/run-review.py')
    assert ($runs | str contains '--ignore-scripts')
    let mkdir_at = $runs | str index-of 'mkdir -p "$RUNNER_TEMP/kodus-cli"'
    let install_at = $runs | str index-of 'npm install --package-lock-only'
    assert ($mkdir_at >= 0 and $install_at > $mkdir_at) 'the npm prefix must exist before installation'
    assert ($runs | str contains 'sha256sum --check')
    assert ($runs | str contains 'release/kodus/disable-trial-fallback.py')
}

@test
def test_kodus_trial_guard_refuses_unexpected_or_already_modified_cli [] {
    let root = mktemp --directory | str trim
    try {
        let target = $root | path join command.js
        'async function runTrialFallback({ diff, spinner, ctx, globalOpts, githubPat, heavy, }) {' | save --force $target
        let command = '
import hashlib, importlib.util, pathlib, sys
s=importlib.util.spec_from_file_location("guard",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
p=pathlib.Path(sys.argv[2]); m.EXPECTED=hashlib.sha256(p.read_bytes()).hexdigest()
m.disable(p)
assert m.GUARD in p.read_bytes()
try:
    m.disable(p)
except ValueError:
    pass
else:
    raise AssertionError("unexpected or already patched CLI was accepted")
'
        let result = with-env {PYTHONDONTWRITEBYTECODE: '1'} { ^python3 -c $command $TRIAL_GUARD $target | complete }
        assert equal $result.exit_code 0 $result.stderr
    } finally {
        qg cleanup $root
    }
}

@test
def test_kodus_publishes_neutral_check_only_for_current_head [] {
    let root = mktemp --directory | str trim
    try {
        let bin = $root | path join bin
        mkdir $bin
        let fake = $bin | path join gh
        '#!/bin/sh
if [ "$2" = "--method" ]; then cat > "$CAPTURE"; printf "{\"id\":1}\n"; else cat "$PR_JSON"; fi
' | save --force $fake
        ^chmod +x $fake
        let data = fixture
        let pr_file = $root | path join pr.json
        let capture = $root | path join posted.json
        $data.pr | to json | save --force $pr_file
        {ok: true, data: {summary: 'Reviewed', issues: [{file: 'tests/a.nu', line: 2, severity: high, message: '<script>test</script>'}]}} | to json | save --force ($root | path join kodus-self-test-review.json)
        let test_env = {
            PATH: ($env.PATH | prepend $bin)
            GITHUB_REPOSITORY: 'prefeitura-rio/flakes'
            GITHUB_RUN_ID: '123'
            QG_REVIEW_PR: '42'
            QG_REVIEW_HEAD: $data.pr.head.sha
            QG_REVIEW_STATUS: success
            RUNNER_TEMP: $root
            PR_JSON: $pr_file
            CAPTURE: $capture
        }
        let completed = with-env $test_env { ^python3 $PUBLISH | complete }
        assert equal $completed.exit_code 0 $completed.stderr
        let check = open $capture
        assert equal $check.head_sha $data.pr.head.sha
        assert equal $check.conclusion neutral
        assert ($check.output.summary | str contains '&lt;script&gt;')
        rm $capture
        let failure = with-env ($test_env | update QG_REVIEW_STATUS failure) { ^python3 $PUBLISH | complete }
        assert equal $failure.exit_code 0 $failure.stderr
        assert equal (open $capture | get output.title) 'Kodus self-test review unavailable'
        assert equal (open $capture | get conclusion) neutral
        rm $capture
        $data.pr | update head.sha 'cccccccccccccccccccccccccccccccccccccccc' | to json | save --force $pr_file
        let stale = with-env $test_env { ^python3 $PUBLISH | complete }
        assert equal $stale.exit_code 0 $stale.stderr
        assert not ($capture | path exists) 'must not publish a check on an outdated head'
    } finally {
        qg cleanup $root
    }
}

@test
def test_kodus_review_rejects_unapproved_api_and_does_not_pass_other_tokens [] {
    let root = mktemp --directory | str trim
    try {
        mkdir ($root | path join kodus-review-repo)
        let bin = $root | path join kodus-cli node_modules .bin
        mkdir $bin
        let cli = $bin | path join kodus
        '#!/bin/sh
[ -z "${GH_TOKEN:-}" ] || exit 9
[ -z "${KODUS_TAILSCALE_CLIENT_SECRET:-}" ] || exit 9
printf "%s" "$FAKE_RESULT" > "$RUNNER_TEMP/kodus-self-test-review.json"
' | save --force $cli
        ^chmod +x $cli
        'context' | save --force ($root | path join kodus-self-test-context.md)
        let test_env = {
            RUNNER_TEMP: $root
            QG_REVIEW_BASE: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            KODUS_API_URL: 'https://kodus-api.squirrel-regulus.ts.net'
            KODUS_TEAM_KEY: 'kodus_example'
            KODUS_TOKEN: ''
            GH_TOKEN: 'must-not-reach-cli'
            KODUS_TAILSCALE_CLIENT_SECRET: 'must-not-reach-cli'
            FAKE_RESULT: '{"ok":true,"data":{"issues":[]}}'
        }
        let success = with-env $test_env { ^python3 $REVIEW | complete }
        assert equal $success.exit_code 0 $success.stderr
        let cloud = with-env ($test_env | update KODUS_API_URL 'https://api.kodus.io') { ^python3 $REVIEW | complete }
        assert ($cloud.exit_code != 0)
        let trial = with-env ($test_env | update FAKE_RESULT '{"ok":true,"data":{"issues":[],"trialInfo":{}}}') { ^python3 $REVIEW | complete }
        assert ($trial.exit_code != 0)
    } finally {
        qg cleanup $root
    }
}

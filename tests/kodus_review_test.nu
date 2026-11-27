use std/assert
use std/testing *
use support/qg.nu

const PREPARE = path self | path dirname | path join .. release kodus prepare-review.py
const REVIEW = path self | path dirname | path join .. release kodus run-review.py
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
    let root = mktemp --directory | str trim
    try {
        let bin = $root | path join bin
        mkdir $bin
        let fake = $bin | path join gh
        '#!/bin/sh
case "$*" in
  *"/files?per_page=100"*) cat "$FAKE_FILES" ;;
  *"/pulls/42"*) cat "$FAKE_PR" ;;
  *) exit 1 ;;
esac
' | save --force $fake
        ^chmod +x $fake
        let event_file = $root | path join event.json
        let pr_file = $root | path join pr.json
        let files_file = $root | path join files.json
        let output = $root | path join output
        $input.event | to json | save --force $event_file
        $input.pr | to json | save --force $pr_file
        $input.pages? | default [$input.files] | to json | save --force $files_file
        '' | save --force $output
        let script = open --raw $WORKFLOW | from yaml | get jobs.select.steps | first | get run
        let test_env = {
            PATH: ($env.PATH | prepend $bin)
            GITHUB_REPOSITORY: $input.repository
            GITHUB_EVENT_PATH: $event_file
            GITHUB_OUTPUT: $output
            FAKE_PR: $pr_file
            FAKE_FILES: $files_file
        }
        let result = with-env $test_env { ^bash -c $script | complete }
        {exit_code: $result.exit_code, stderr: $result.stderr, outputs: (open --raw $output)}
    } finally {
        qg cleanup $root
    }
}

@test
def test_kodus_selects_only_current_self_test_pull_requests [] {
    let data = fixture
    let accepted = run-selection-fixture $data
    assert equal $accepted.exit_code 0 $accepted.stderr
    assert ($accepted.outputs | str contains 'review=true')
    assert ($accepted.outputs | str contains 'number=42')
    assert ($accepted.outputs | str contains $data.pr.head.sha)
    for case in [
        ($data | update pr.head.sha 'cccccccccccccccccccccccccccccccccccccccc')
        ($data | update pr.head.repo.full_name 'other/fork')
        ($data | update event.workflow_run.head_repository.full_name 'other/fork')
        ($data | update event.workflow_run.path '.github/workflows/other.yml')
        ($data | update event.workflow_run.pull_requests [])
        ($data | update pr.base.ref 'other-branch')
        ($data | update pr.base.repo.full_name 'other/fork')
        ($data | update pr.state closed)
        ($data | update files [{filename: README.md}])
    ] {
        let outcome = run-selection-fixture $case
        assert equal $outcome.exit_code 0 $outcome.stderr
        assert ($outcome.outputs | str contains 'review=false')
    }
    let renamed = $data | update files [{filename: other.nu, previous_filename: 'tests/old.nu'}]
    assert ((run-selection-fixture $renamed | get outputs) | str contains 'review=true')
    let paginated = $data | update pr.changed_files 2 | upsert pages [[{filename: README.md}] [{filename: 'tests/a.nu'}]]
    assert ((run-selection-fixture $paginated | get outputs) | str contains 'review=true')
    let incomplete = $data | update pr.changed_files 2
    assert ((run-selection-fixture $incomplete | get exit_code) != 0) 'incomplete file listings must fail, not pass'
    let invalid = $data | update event.workflow_run.pull_requests [{number: '42;exit 0'}]
    assert ((run-selection-fixture $invalid | get exit_code) != 0) 'invalid PR identifiers must fail'
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
    assert (($workflow.jobs.review.permissions.checks? | default '') != write)
    assert equal $workflow.jobs.review.permissions.pull-requests write
    assert equal $workflow.jobs.review.concurrency.cancel-in-progress false
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
    assert ($runs | str contains 'release/kodus/run-review.py --comment')
    let review = $steps | where name? == 'Review self-test changes' | first
    assert not ('GH_TOKEN' in ($review.env | columns))
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
            QG_REVIEW_HEAD: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            QG_REVIEW_PR: '42'
            GITHUB_STEP_SUMMARY: ($root | path join summary.md)
            KODUS_API_URL: 'https://kodus-api.squirrel-regulus.ts.net'
            KODUS_TEAM_KEY: 'kodus_example'
            KODUS_TOKEN: ''
            GH_TOKEN: 'must-not-reach-cli'
            KODUS_TAILSCALE_CLIENT_SECRET: 'must-not-reach-cli'
            FAKE_RESULT: '{"ok":true,"data":{"summary":"Reviewed","issues":[{"file":"tests/a.nu","line":2,"severity":"high","message":"<script>test</script>"}]}}'
        }
        let success = with-env $test_env { ^python3 $REVIEW | complete }
        assert equal $success.exit_code 0 $success.stderr
        let summary = open --raw $test_env.GITHUB_STEP_SUMMARY
        assert ($summary | str contains 'PR #42')
        assert ($summary | str contains $test_env.QG_REVIEW_HEAD)
        assert ($summary | str contains '&lt;script&gt;')
        let cloud = with-env ($test_env | update KODUS_API_URL 'https://api.kodus.io') { ^python3 $REVIEW | complete }
        assert ($cloud.exit_code != 0)
        let trial = with-env ($test_env | update FAKE_RESULT '{"ok":true,"data":{"issues":[],"trialInfo":{}}}') { ^python3 $REVIEW | complete }
        assert ($trial.exit_code != 0)
        let rate_limit = with-env ($test_env | update FAKE_RESULT '{"ok":true,"data":{"issues":[],"rateLimit":{}}}') { ^python3 $REVIEW | complete }
        assert ($rate_limit.exit_code != 0)
        let malformed = with-env ($test_env | update FAKE_RESULT '{"ok":true,"data":{"issues":["invalid"]}}') { ^python3 $REVIEW | complete }
        assert ($malformed.exit_code != 0)
        assert equal (open --raw $test_env.GITHUB_STEP_SUMMARY) $summary 'a trial result must not be published as a valid review'
    } finally {
        qg cleanup $root
    }
}

@test
def test_kodus_posts_inline_review_and_skips_stale_or_duplicate_commits [] {
    let root = mktemp --directory | str trim
    try {
        let bin = $root | path join bin
        mkdir $bin
        let fake = $bin | path join gh
        '#!/bin/sh
case "$*" in
  *"--method POST"*) cat > "$CAPTURE"; printf "{}\n" ;;
  *"/reviews?per_page=100"*) cat "$REVIEWS"; if [ -n "${STALE_PR:-}" ]; then cp "$STALE_PR" "$PR_JSON"; fi ;;
  *"/files?per_page=100"*) cat "$FILES" ;;
  *"/pulls/42"*) cat "$PR_JSON" ;;
  *) exit 1 ;;
esac
' | save --force $fake
        ^chmod +x $fake
        let data = fixture
        let pr_file = $root | path join pr.json
        let files_file = $root | path join files.json
        let reviews_file = $root | path join reviews.json
        let capture = $root | path join posted.json
        $data.pr | to json | save --force $pr_file
        let patch = "@@ -1,2 +1,3 @@\n old\n+added\n old\n@@ -10,1 +11,2 @@\n+another\n old\n"
        [[{filename: 'tests/a.nu', patch: $patch}]] | to json | save --force $files_file
        [[]] | to json | save --force $reviews_file
        {ok: true, data: {summary: 'Review complete', issues: [
            {file: 'tests/a.nu', line: 2, severity: high, message: 'Missing assertion @someone'}
            {file: 'tests/a.nu', line: 2, severity: high, message: 'Missing assertion @someone'}
            {file: 'tests/a.nu', line: 3, severity: medium, message: 'Not an added line'}
            {file: 'tests/a.nu', line: 11, severity: high, message: 'Flaky test'}
        ]}} | to json | save --force ($root | path join kodus-self-test-review.json)
        let test_env = {
            PATH: ($env.PATH | prepend $bin)
            RUNNER_TEMP: $root
            GITHUB_REPOSITORY: 'prefeitura-rio/flakes'
            QG_REVIEW_PR: '42'
            QG_REVIEW_HEAD: $data.pr.head.sha
            QG_REVIEW_BASE: $data.pr.base.sha
            GH_TOKEN: 'test-token'
            PR_JSON: $pr_file
            FILES: $files_file
            REVIEWS: $reviews_file
            CAPTURE: $capture
            STALE_PR: ''
        }
        let result = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $result.exit_code 0 $result.stderr
        let posted = open $capture
        assert equal $posted.event COMMENT
        assert equal $posted.commit_id $data.pr.head.sha
        assert equal ($posted.comments | length) 2
        assert equal ($posted.comments | get line) [2 11]
        assert ($posted.body | str contains 'Not an added line')
        assert not (($posted.comments | first | get body) | str contains '@someone') 'model output must not trigger mentions'
        rm $capture

        $data.pr | update head.sha 'cccccccccccccccccccccccccccccccccccccccc' | to json | save --force $pr_file
        let stale = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $stale.exit_code 0 $stale.stderr
        assert not ($capture | path exists) 'must not comment on an outdated head'

        $data.pr | to json | save --force $pr_file
        [[{user: {login: 'github-actions[bot]'}, body: $'<!-- kodus-self-test-review:($data.pr.head.sha):($data.pr.base.sha) -->'}]] | to json | save --force $reviews_file
        let duplicate = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $duplicate.exit_code 0 $duplicate.stderr
        assert not ($capture | path exists) 'must not post the same review twice'

        [[{user: {login: human}, body: $'<!-- kodus-self-test-review:($data.pr.head.sha):($data.pr.base.sha) -->'}]] | to json | save --force $reviews_file
        let human_marker = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $human_marker.exit_code 0 $human_marker.stderr
        assert ($capture | path exists) 'a human-authored marker must not suppress the review'
        rm $capture

        [[]] | to json | save --force $reviews_file
        let stale_file = $root | path join stale.json
        $data.pr | update head.sha 'cccccccccccccccccccccccccccccccccccccccc' | to json | save --force $stale_file
        let race = with-env ($test_env | update STALE_PR $stale_file) { ^python3 $REVIEW --comment | complete }
        assert equal $race.exit_code 0 $race.stderr
        assert not ($capture | path exists) 'must recheck the head immediately before posting'

        $data.pr | update base.sha 'cccccccccccccccccccccccccccccccccccccccc' | to json | save --force $pr_file
        let changed_base = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $changed_base.exit_code 0 $changed_base.stderr
        assert not ($capture | path exists) 'must not comment when the base changed'

        $data.pr | to json | save --force $pr_file
        [[]] | to json | save --force $files_file
        let incomplete = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert ($incomplete.exit_code != 0) 'incomplete file listings must not produce comments'
        assert not ($capture | path exists)

        [[{filename: 'tests/a.nu'}]] | to json | save --force $files_file
        let missing_patch = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $missing_patch.exit_code 0 $missing_patch.stderr
        let general = open $capture
        assert (($general.comments? | default []) | is-empty)
        assert ($general.body | str contains 'Missing assertion')
        rm $capture

        {ok: true, data: {summary: 'Review complete', notices: ['Partial context'], issues: []}} | to json | save --force ($root | path join kodus-self-test-review.json)
        let clean = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $clean.exit_code 0 $clean.stderr
        let clean_review = open $capture
        assert equal $clean_review.event COMMENT
        assert ($clean_review.body | str contains 'No findings')
        assert ($clean_review.body | str contains 'Partial context')
        assert (($clean_review.comments? | default []) | is-empty)
        rm $capture

        let long = 1..2000 | each {|_| 'x' } | str join ''
        let findings = 1..50 | each {|n| {file: 'tests/a.nu', line: 3, message: $'($long)($n)'} }
        {ok: true, data: {issues: $findings}} | to json | save --force ($root | path join kodus-self-test-review.json)
        let large = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert equal $large.exit_code 0 $large.stderr
        let large_body = open $capture | get body
        assert (($large_body | encode utf-8 | length) < 50_000)
        assert ($large_body | str contains 'Additional findings omitted.')
        assert ($large_body | str contains $'<!-- kodus-self-test-review:($data.pr.head.sha):($data.pr.base.sha) -->')
        rm $capture

        {ok: true, data: {issues: [], trialInfo: {}}} | to json | save --force ($root | path join kodus-self-test-review.json)
        let trial = with-env $test_env { ^python3 $REVIEW --comment | complete }
        assert ($trial.exit_code != 0)
        assert not ($capture | path exists) 'a trial response must not be posted as a normal review'
    } finally {
        qg cleanup $root
    }
}

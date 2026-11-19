use std/assert
use std/testing *
use support/isolation.nu

const WORKFLOWS = path self | path dirname | path join .. .github workflows

def workflows []: nothing -> table {
    glob ($WORKFLOWS | path join '*.yml') | sort | each {|file|
        {file: ($file | path basename), document: (open --raw $file | from yaml)}
    }
}

@test
def test_jobs_that_push_with_the_release_app_do_not_persist_the_checkout_token [] {
    let offenders = workflows | each {|workflow|
        $workflow.document.jobs | items {|name, job|
            let steps = $job.steps? | default []
            let uses_app = $steps | any {|step| ($step.uses? | default '') | str starts-with 'actions/create-github-app-token@' }
            let leaking = $steps
                | where {|step| ($step.uses? | default '') | str starts-with 'actions/checkout@' }
                | where {|step| ($step.with?.persist-credentials? | default true) != false }
            if $uses_app and ($leaking | is-not-empty) { $'($workflow.file):($name)' }
        } | compact
    } | flatten
    assert ($offenders | is-empty) $'checkout persists GITHUB_TOKEN, which overrides the App token on push: ($offenders | to nuon)'
}

@test
def test_no_workflow_grants_write_permissions_to_every_job [] {
    let offenders = workflows | each {|workflow|
        let permissions = $workflow.document.permissions? | default null
        if $permissions == null {
            $'($workflow.file): permissions are not declared'
        } else if ($permissions | describe | str starts-with 'record') {
            let writes = $permissions | items {|scope, level| if $level == write { $scope } } | compact
            if ($writes | is-not-empty) { $'($workflow.file): workflow-level write for ($writes | str join ", ")' }
        } else {
            $'($workflow.file): permissions must be an explicit read-only record'
        }
    } | compact
    assert ($offenders | is-empty) ($offenders | str join "\n")
}

const MASTER_RULESET = path self | path dirname | path join .. release rulesets master.json

def triggers [document: record]: nothing -> list<string> {
    let on = $document.on
    match ($on | describe | split row '<' | first) {
        string => [$on]
        list => $on
        _ => ($on | columns)
    }
}

# A job that holds something worth stealing: an Environment, a secret other than
# the job token, a write permission, or a call to a reusable workflow, which may
# receive secrets.
def privileges [job: record]: nothing -> list<string> {
    let text = $job | to json
    let secrets = $text | parse --regex 'secrets\.(?<name>[A-Za-z0-9_]+)' | get name | where {|name| $name != GITHUB_TOKEN } | uniq
    let indexed = if ($text =~ 'secrets\s*\[') { ['secrets[...]'] } else { [] }
    let permissions = $job.permissions? | default {}
    let writes = if ($permissions | describe | str starts-with 'record') {
        $permissions | items {|scope, level| if $level == write { $'permission ($scope): write' } } | compact
    } else {
        []
    }
    []
    | append (if ($job.environment? | default null) != null { ['environment'] } else { [] })
    | append ($secrets | each {|name| $'secret ($name)' })
    | append $indexed
    | append $writes
    | append (if ($job.uses? | default null) != null { ['reusable workflow'] } else { [] })
}

# Only a job that insists on an event other than a pull request stays out of
# one. A job without `if`, or with an `||` that reopens the door, does not.
def reachable-from-pull-requests [workflow: record, job: record]: nothing -> bool {
    if not (triggers $workflow.document | any {|event| $event in [pull_request pull_request_target] }) {
        return false
    }
    let condition = $job.if? | default ''
    let restricted = ($condition =~ "github\\.event_name == '(push|schedule|workflow_dispatch|workflow_run)'") and not ($condition | str contains '||')
    not $restricted
}

@test
def test_privileged_jobs_are_not_reachable_from_pull_requests [] {
    let offenders = workflows | each {|workflow|
        $workflow.document.jobs | items {|name, job|
            let held = privileges $job
            if ($held | is-not-empty) and (reachable-from-pull-requests $workflow $job) {
                $'($workflow.file):($name) is reachable from pull requests and holds: ($held | str join ", ")'
            }
        } | compact
    } | flatten
    assert ($offenders | is-empty) ($offenders | str join "\n")
}

@test
def test_the_reachability_rule_catches_the_mistakes_it_exists_for [] {
    let on_pull_request = {document: {on: {pull_request: {branches: [master]}}}}
    let cases = [
        {name: 'no if at all', job: {environment: release}, reachable: true}
        {name: 'if with an or', job: {environment: release, if: "github.event_name == 'push' || github.event_name == 'pull_request'"}, reachable: true}
        {name: 'if on another condition', job: {environment: release, if: "github.ref == 'refs/heads/master'"}, reachable: true}
        {name: 'push only', job: {environment: release, if: "github.event_name == 'push'"}, reachable: false}
        {name: 'push and branch', job: {environment: release, if: "github.event_name == 'push' && github.ref == 'refs/heads/master'"}, reachable: false}
    ]
    let wrong = $cases | each {|case|
        let actual = reachable-from-pull-requests $on_pull_request $case.job
        if $actual != $case.reachable { $'($case.name): expected reachable=($case.reachable)' }
    } | compact
    assert ($wrong | is-empty) ($wrong | str join "\n")
    let held = privileges {steps: [{run: 'echo ${{ toJSON(secrets) }}', env: {TOKEN: "${{ secrets['CACHIX_AUTH_TOKEN'] }}"}}]}
    assert ('secrets[...]' in $held) 'an indexed secret must be seen'
}

@test
def test_no_workflow_hands_over_every_secret [] {
    let pattern = 'secrets\s*:\s*inherit|toJSON\(\s*secrets|\$\{\{\s*secrets\s*\}\}|join\(\s*secrets'
    let offenders = glob ($WORKFLOWS | path join '*.yml') | each {|file|
        if (open --raw $file) =~ $pattern { $file | path basename }
    } | compact
    assert ($offenders | is-empty) $'these workflows expose all secrets: ($offenders | to nuon)'
}

@test
def test_the_checks_master_requires_come_from_jobs_that_always_run_on_pull_requests [] {
    let required = open $MASTER_RULESET
        | get rules
        | where type == required_status_checks
        | first
        | get parameters.required_status_checks.context
    let producers = workflows
        | where {|workflow| triggers $workflow.document | any {|event| $event == pull_request } }
        | each {|workflow|
            let paths = $workflow.document.on.pull_request?.paths? | default []
            $workflow.document.jobs | items {|id, job|
                {name: ($job.name? | default $id), unconditional: (($job.if? | default '') == '' and ($paths | is-empty))}
            }
        }
        | flatten
    let missing = $required | where {|context| not ($producers | any {|job| $job.name == $context and $job.unconditional }) }
    assert ($missing | is-empty) $'required checks no job reports on every pull request, so a pull request could never merge or the check could be skipped: ($missing | to nuon)'
}

@test
def test_the_canary_analysis_fails_loudly_when_it_cannot_promote [] {
    let workflow = open --raw ($WORKFLOWS | path join quality-gate-canary-analysis.yml) | from yaml
    let step = $workflow.jobs.analyze.steps | first
    assert equal $step.name 'Require the release App when a promotion is expected'
    assert (($step.run | str contains '${{') | not $in) 'the check must read env vars, not interpolate expressions'
    let cases = [
        {expected: true, has_app: true, outcome: pass}
        {expected: true, has_app: false, outcome: fail}
        {expected: false, has_app: false, outcome: pass}
        {expected: false, has_app: true, outcome: pass}
    ]
    let failures = $cases | each {|case|
        let result = with-env {PROMOTION_EXPECTED: ($case.expected | into string), HAS_RELEASE_APP: ($case.has_app | into string)} {
            ^bash -c $step.run | complete
        }
        let actual = if $result.exit_code == 0 { 'pass' } else { 'fail' }
        if $actual != $case.outcome { $'expected=($case.expected) app=($case.has_app): wanted ($case.outcome), got ($actual)' }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
    let job_env = $workflow.jobs.analyze.env
    assert ($job_env.PROMOTION_EXPECTED | str contains "github.event_name != 'workflow_dispatch'")
    assert ($job_env.PROMOTION_EXPECTED | str contains 'inputs.create_promotion_pr')
}

def steps-of [job: record]: nothing -> list<record> {
    $job.steps? | default []
}

@test
def test_promotion_proves_the_canary_is_healthy_before_it_moves_the_tag [] {
    let workflow = open --raw ($WORKFLOWS | path join quality-gate-promotion.yml) | from yaml
    for name in [promote validate] {
        let runs = steps-of ($workflow.jobs | get $name) | each {|step| $step.run? | default '' }
        let verifying = $runs | where {|run| $run | str contains 'verify-canary-health.sh' }
        assert ($verifying | is-not-empty) $'($name) never checks the canary analysis'
        let script = $verifying | first
        # The analysis must be newer than the end of the bake, not any past one.
        assert ($script | str contains '--not-before') $'($name) accepts an analysis made before the bake ended'
    }
    let promote = steps-of $workflow.jobs.promote | each {|step| $step.run? | default '' } | str join "\n"
    let verify_at = $promote | str index-of 'verify-canary-health.sh'
    let move_at = $promote | str index-of 'move-floating-tag.sh'
    assert ($verify_at >= 0 and $move_at > $verify_at) 'the tag must only move after the proof was verified'
}

@test
def test_state_changing_jobs_never_share_a_concurrency_group_with_validation [] {
    let workflow = open --raw ($WORKFLOWS | path join quality-gate-promotion.yml) | from yaml
    assert (($workflow.concurrency? | default null) == null) 'a workflow-wide group lets a validation cancel a queued promotion'
    let groups = $workflow.jobs | items {|name, job| {job: $name, group: ($job.concurrency?.group? | default ''), cancel: ($job.concurrency?.cancel-in-progress? | default false)} }
    assert (($groups | where group == '' | is-empty)) $'jobs without a concurrency group: ($groups | where group == "" | get job | to nuon)'
    assert equal ($groups | get group | uniq | length) ($groups | length) 'every job needs its own group'
    let mutating = $groups | where job in [promote emergency]
    assert ($mutating | all {|entry| $entry.cancel == false }) 'a promotion or rollback must never be cancelled half way'
}

@test
def test_app_tokens_are_limited_to_the_permissions_the_job_needs [] {
    let offenders = workflows | each {|workflow|
        $workflow.document.jobs | items {|name, job|
            steps-of $job
            | where {|step| ($step.uses? | default '') | str starts-with 'actions/create-github-app-token@' }
            | where {|step| ($step.with? | default {} | columns | where {|key| $key | str starts-with 'permission-' } | is-empty) }
            | each {|_| $'($workflow.file):($name)' }
        } | flatten
    } | flatten
    assert ($offenders | is-empty) $'App tokens carry every permission of the installation: ($offenders | to nuon)'
}

@test
def test_a_cache_outage_cannot_block_a_release [] {
    let workflow = open --raw ($WORKFLOWS | path join quality-gate-tests.yml) | from yaml
    for name in [publish-cache publish-darwin-cache] {
        let job = $workflow.jobs | get $name
        assert equal ($job.continue-on-error? | default false) true $'($name) fails the whole workflow, and the release waits for it'
    }
    for name in [tests darwin-build] {
        assert (($workflow.jobs | get $name | get continue-on-error? | default false) != true) $'($name) must keep blocking'
    }
}

@test
def test_no_checkout_leaves_the_token_in_the_git_config [] {
    let offenders = workflows | each {|workflow|
        $workflow.document.jobs | items {|name, job|
            steps-of $job
            | where {|step| ($step.uses? | default '') | str starts-with 'actions/checkout@' }
            | where {|step| ($step.with?.persist-credentials? | default true) != false }
            | each {|_| $'($workflow.file):($name)' }
        } | flatten
    } | flatten
    assert ($offenders | is-empty) $'checkout persists the job token: ($offenders | to nuon)'
}

@test
def test_the_release_bump_comes_from_the_commits_since_the_last_tag [] {
    let workflow = open --raw ($WORKFLOWS | path join quality-gate-release.yml) | from yaml
    assert (($workflow.jobs.release.with.bump) | str contains 'needs.quality-gate-change.outputs.bump') 'the bump must not be a constant'
    let compare = steps-of $workflow.jobs.quality-gate-change | where id? == compare | first
    assert ($compare.run | str contains 'compute-bump.sh')
    assert ($compare.run | str contains 'devenv/files/quality-gate/runner.nix') 'a change to the runner must also be released'
}

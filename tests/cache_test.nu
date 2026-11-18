use std/assert
use std/testing *
use support/qg.nu *

const WORKFLOWS = path self | path dirname | path join .. .github workflows
const PUBLISH_JOBS = [publish-cache publish-darwin-cache]

def workflow-files []: nothing -> list<path> {
    glob ($WORKFLOWS | path join '*.yml') | sort
}

def parse-workflow [file: path]: nothing -> record {
    open --raw $file | from yaml
}

# Every `uses:` reference of every job and step, with where it was found.
def action-references []: nothing -> table {
    workflow-files | each {|file|
        let workflow = parse-workflow $file
        let name = $file | path basename
        $workflow.jobs | items {|job_name, job|
            let job_uses = if 'uses' in $job { [{file: $name, job: $job_name, uses: $job.uses}] } else { [] }
            let step_uses = ($job.steps? | default [])
                | where {|step| 'uses' in $step }
                | each {|step| {file: $name, job: $job_name, uses: $step.uses} }
            $job_uses ++ $step_uses
        } | flatten
    } | flatten
}

# Cachix steps with the job that owns them.
def cachix-steps []: nothing -> table {
    workflow-files | each {|file|
        let workflow = parse-workflow $file
        $workflow.jobs | items {|job_name, job|
            ($job.steps? | default [])
            | where {|step| ($step.uses? | default '') | str starts-with 'cachix/cachix-action@' }
            | each {|step| {file: ($file | path basename), job: $job_name, with: $step.with, environment: ($job.environment? | default null), condition: ($job.if? | default ''), needs: ($job.needs? | default [])} }
        } | flatten
    } | flatten
}

@test
def test_only_trusted_publish_jobs_can_write_to_the_cache [] {
    let steps = cachix-steps
    assert (($steps | length) >= 5) 'expected the cachix steps of the tests, release and canary workflows'
    let writers = $steps | where {|step| ('authToken' in $step.with) or ($step.with.skipPush? | default false) != true }
    assert equal ($writers | get job | sort) ($PUBLISH_JOBS | sort) $'only the publish jobs may write: ($writers | select file job | to nuon)'
    for step in $writers {
        assert equal $step.environment cachix-publish $'($step.job) must run in the cachix-publish environment'
        assert ($step.condition | str contains "github.event_name == 'push'") $'($step.job) must run on push only'
        assert ($step.condition | str contains "refs/heads/master") $'($step.job) must run on master only'
        assert ($step.needs | is-not-empty) $'($step.job) must wait for the checks'
        assert equal $step.with.authToken '${{ secrets.CACHIX_AUTH_TOKEN }}'
    }
    let readers = $steps | where {|step| $step.job not-in $PUBLISH_JOBS }
    for step in $readers {
        assert equal $step.with.skipPush true $'($step.file):($step.job) must never push'
        assert equal $step.with.name prefeitura-rio
        assert equal $step.with.extraPullNames devenv
    }
}

@test
def test_the_cache_token_is_referenced_only_by_the_publish_jobs [] {
    let references = workflow-files | each {|file|
        open --raw $file | lines | enumerate | where {|row| $row.item | str contains 'CACHIX_AUTH_TOKEN' } | each {|row| $'($file | path basename):($row.index + 1)' }
    } | flatten
    assert equal ($references | length) 2 $'expected exactly the two publish steps, found: ($references | to nuon)'
    let publish_files = workflow-files | each {|file|
        let workflow = parse-workflow $file
        $PUBLISH_JOBS | where {|job| $job in ($workflow.jobs | columns) } | each {|job| {file: ($file | path basename), job: $job} }
    } | flatten
    assert equal ($publish_files | length) 2
}

@test
def test_every_action_is_pinned_to_a_full_commit_sha [] {
    let unpinned = action-references
        | where {|reference| not ($reference.uses | str starts-with './') }
        | where {|reference| not ($reference.uses =~ '@[0-9a-f]{40}( |$)') }
    assert ($unpinned | is-empty) $'unpinned references: ($unpinned | to nuon)'
}

@test
def test_the_same_action_uses_the_same_commit_everywhere [] {
    let inconsistent = action-references
        | where {|reference| not ($reference.uses | str starts-with './') }
        | each {|reference|
            let parts = $reference.uses | split row '@'
            {action: ($parts | first), commit: ($parts | last | split row ' ' | first)}
        }
        | group-by action
        | items {|action, rows| {action: $action, commits: ($rows | get commit | uniq)} }
        | where {|entry| ($entry.commits | length) > 1 }
    assert ($inconsistent | is-empty) $'actions pinned to different commits: ($inconsistent | to nuon)'
}

@test
def test_release_passes_only_the_release_app_secrets [] {
    let workflow = parse-workflow ($WORKFLOWS | path join quality-gate-release.yml)
    let secrets = $workflow.jobs.release.secrets
    assert (($secrets | describe) | str starts-with 'record') 'secrets: inherit hands every secret to another repository'
    assert equal ($secrets | columns | sort) [QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY]
    assert (($workflow.jobs.release.uses) =~ 'prefeitura-rio/actions/.github/workflows/release.yml@[0-9a-f]{40}$')
}

@test
def test_the_discovery_app_only_runs_detect [] {
    let root = fixture-repo go-clean
    let outcome = try {
        let allowed = run-app $root quality-gate-detect detect
        assert equal $allowed.exit_code 0 $allowed.stderr
        assert (($allowed.stderr + $allowed.stdout) | str contains 'Detected project')
        for arguments in [[ci] [category lint] [test] [detect extra]] {
            let refused = run-app $root quality-gate-detect ...$arguments
            assert equal $refused.exit_code 2 $'($arguments | str join " ") must be refused'
            assert ($refused.stderr | str contains 'only supports') $refused.stderr
        }
        null
    } catch {|error|
        $error.msg
    }
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

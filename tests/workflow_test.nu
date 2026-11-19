use std/assert
use std/testing *

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

@test
def test_environment_gated_jobs_never_run_on_pull_requests [] {
    let offenders = workflows | each {|workflow|
        $workflow.document.jobs | items {|name, job|
            let environment = $job.environment? | default null
            let condition = $job.if? | default ''
            if $environment != null and ($condition | str contains 'pull_request') {
                $'($workflow.file):($name) uses environment ($environment) but is reachable from pull requests'
            }
        } | compact
    } | flatten
    assert ($offenders | is-empty) ($offenders | str join "\n")
}

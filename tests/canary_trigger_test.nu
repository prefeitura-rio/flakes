use std/assert
use std/testing *
use support/isolation.nu
use support/qg.nu [write-executable]

const TRIGGER = path self | path dirname | path join .. release scripts trigger-gitlab-canary.sh
const WORKFLOW = path self | path dirname | path join .. .github workflows quality-gate-canary-analysis.yml
const SHA = '692671c62b79c59c9668faf88e95e3d4dc1d4c4a'

def fixture []: nothing -> path {
    let root = mktemp --directory | str trim
    let script = [
        '#!/bin/sh'
        'printf "%s\n" "$@" > "$CURL_ARGS"'
        'if [ "$CURL_FAIL" = true ]; then'
        '  printf "%s" "{\"error\":\"variables is invalid\"}"'
        '  exit 22'
        'fi'
        'printf "%s" "$CURL_RESPONSE"'
    ] | str join (char nl)
    write-executable ($root | path join bin curl) $script
    $root
}

def trigger [root: path, --fail, --response: string = '{"id":1234}', --project: string = '48', --sha: string = $SHA]: nothing -> record {
    with-env {
        PATH: ($env.PATH | prepend ($root | path join bin))
        GITLAB_API: 'https://git.example.test/api/v4/'
        GITLAB_TOKEN: 'fixture-secret'
        CURL_ARGS: ($root | path join curl.args)
        CURL_FAIL: (if $fail { 'true' } else { 'false' })
        CURL_RESPONSE: $response
    } {
        ^bash $TRIGGER $project $sha | complete
    }
}

@test
def test-canary-creates-pipeline-with-gitlab-variables-array [] {
    let root = fixture
    let result = trigger $root
    let args = open --raw ($root | path join curl.args) | lines
    let data_index = $args | enumerate | where item == '--data' | get index | first
    let payload = $args | get ($data_index + 1) | from json
    rm --recursive --force $root
    assert equal $result.exit_code 0 $result.stderr
    assert equal ($result.stdout | str trim) '1234'
    assert equal $payload.ref 'main'
    assert equal $payload.variables [{key: QUALITY_GATE_REF, value: $SHA} {key: QUALITY_GATE_CANARY, value: 'true'}]
    assert ('Content-Type: application/json' in $args)
    assert equal ($args | last) 'https://git.example.test/api/v4/projects/48/pipeline'
    assert (not ($result.stdout | str contains 'fixture-secret'))
}

@test
def test-canary-reports-gitlab-error-without-exposing-token [] {
    let root = fixture
    let result = trigger $root --fail
    rm --recursive --force $root
    assert ($result.exit_code != 0)
    assert ($result.stderr | str contains 'variables is invalid')
    assert (not ($result.stderr | str contains 'fixture-secret'))
}

@test
def test-canary-rejects-missing-or-invalid-pipeline-id [] {
    let invalid = ['{}' '{"id":null}' '{"id":"1234"}' '{"id":-1}' '{"id":1.5}' 'not-json']
    let errors = $invalid | each {|response|
        let root = fixture
        let result = trigger $root --response $response
        rm --recursive --force $root
        if $result.exit_code == 0 { $response }
    } | compact
    assert ($errors | is-empty) $'invalid responses were accepted: ($errors | to nuon)'
}

@test
def test-canary-rejects-invalid-project-or-sha-before-request [] {
    let root = fixture
    let invalid_project = trigger $root --project '48/../../x'
    let invalid_sha = trigger $root --sha 'abc123'
    let sent = ($root | path join curl.args | path exists)
    rm --recursive --force $root
    assert ($invalid_project.exit_code != 0)
    assert ($invalid_sha.exit_code != 0)
    assert (not $sent)
}

@test
def test-canary-workflow-uses-pipeline-trigger-helper [] {
    let workflow = open --raw $WORKFLOW | from yaml
    let step = $workflow.jobs.analyze.steps | where {|item| ($item.name? | default '') == 'Trigger and analyze sandbox pipelines' } | first
    assert ($step.run | str contains 'bash release/scripts/trigger-gitlab-canary.sh "$project_id" "$candidate_sha"')
    assert (not ($step.run | str contains 'variables[QUALITY_GATE_REF]'))
}

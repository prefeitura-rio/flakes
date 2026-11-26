use std/assert
use std/testing *
use support/isolation.nu
use support/qg.nu [write-executable]

const VERIFY = path self | path dirname | path join .. release scripts verify-canary-health.sh
const WORKFLOW = path self | path dirname | path join .. .github workflows quality-gate-canary-analysis.yml

const REPOSITORY = 'prefeitura-rio/flakes'
const SHA = '0123456789abcdef0123456789abcdef01234567'

# ---------------------------------------------------------------------------
# verify-canary-health.sh
# ---------------------------------------------------------------------------

def run-fixture [runs: list<record>]: nothing -> path {
    let root = mktemp --directory | str trim
    let bin = $root | path join bin
    {workflow_runs: $runs} | to json | save --force ($root | path join runs.json)
    # The `gh` stand-in answers the three endpoints the script reads and logs
    # every call, so the query itself can be asserted.
    write-executable ($bin | path join gh) $"#!/bin/sh
echo \"$*\" >> '($root)/calls.log'
for argument in \"$@\"; do
  case \"$argument\" in
    repos/*/runs) cat '($root)/runs.json'; exit 0 ;;
    repos/*/runs/*/artifacts) id=\"${argument%/artifacts}\"; id=\"${id##*/}\"; cat \"($root)/artifacts-$id.json\"; exit 0 ;;
    repos/*/artifacts/*/zip) id=\"${argument%/zip}\"; id=\"${id##*/}\"; cat \"($root)/artifact-$id.json\"; exit 0 ;;
  esac
done
exit 1
"
    # Artifacts are plain JSON in the test, so `unzip -p archive file` just cats it.
    write-executable ($bin | path join unzip) "#!/bin/sh\ncat \"$2\"\n"
    $root
}

def run-record [overrides: record = {}]: nothing -> record {
    {
        id: 100
        event: schedule
        head_branch: master
        head_repository: {full_name: $REPOSITORY}
    } | merge $overrides
}

def add-artifact [root: path, run: int, id: int, analysis: record, --created: string = '2026-11-19T04:40:00Z', --expired] {
    {artifacts: [{id: $id, created_at: $created, expired: $expired}]} | to json | save --force ($root | path join $'artifacts-($run).json')
    $analysis | to json | save --force ($root | path join $'artifact-($id).json')
}

def --wrapped verify [root: path, ...arguments: string]: nothing -> record {
    with-env {PATH: ($env.PATH | prepend ($root | path join bin))} {
        ^bash $VERIFY --repository $REPOSITORY --sha $SHA ...$arguments | complete
    }
}

def healthy-analysis []: nothing -> record {
    {analysis_version: 2, candidate_sha: $SHA, healthy: true, projects: []}
}

@test
def test_the_canary_workflow_emits_the_current_proof_version [] {
    let workflow = open --raw $WORKFLOW | from yaml
    let step = $workflow.jobs.analyze.steps | where {|item| ($item.name? | default '') == 'Trigger and analyze sandbox pipelines' } | first
    let start = 'jq --arg candidate_ref "$candidate_ref" --arg candidate_sha "$candidate_sha"'
    let end = '| tee canary-analysis.json'
    assert ($step.run | str contains $start)
    assert ($step.run | str contains $end)
    let middle = $step.run | split row $start | last | split row $end | first
    let script = ["set -euo pipefail" $'($start)($middle)'] | str join (char nl)
    let root = run-fixture [(run-record)]
    let results = $root | path join results.json
    [{analysis: {healthy: true}}] | to json | save --force $results
    let run = with-env {candidate_ref: 'quality-gate-next', candidate_sha: $SHA, results: $results} {
        ^bash -c $script | complete
    }
    assert equal $run.exit_code 0 $run.stderr
    let proof = $run.stdout | from json
    assert equal $proof.analysis_version 2
    assert equal $proof.healthy true
    add-artifact $root 100 7 $proof
    assert equal (verify $root | get exit_code) 0 'the verifier must accept the workflow proof'
    rm --recursive --force $root
}

@test
def test_legacy_and_wrong_analysis_versions_cannot_prove_health [] {
    let root = run-fixture [(run-record)]
    for version in [null 1 3 '2'] {
        add-artifact $root 100 7 (healthy-analysis | upsert analysis_version $version)
        let result = verify $root
        assert equal $result.exit_code 1 $'analysis version ($version | to nuon) must be rejected'
    }
    add-artifact $root 100 7 (healthy-analysis | reject analysis_version)
    assert equal (verify $root | get exit_code) 1 'old artifacts have no version'
    rm --recursive --force $root
}

@test
def test-a-healthy-analysis-from-the-release-branch-is-accepted [] {
    let root = run-fixture [(run-record)]
    add-artifact $root 100 7 (healthy-analysis)
    let output = $root | path join verified.json
    let result = verify $root --output $output
    let calls = open --raw ($root | path join calls.log)
    let verified = open $output
    rm --recursive --force $root
    assert equal $result.exit_code 0 $result.stderr
    assert equal $verified.candidate_sha $SHA
    assert ($calls | str contains 'branch=master') 'the query must be limited to the release branch'
    assert ($calls | str contains 'status=success') 'only successful runs prove anything'
}

@test
def test-an-unhealthy-analysis-is-rejected [] {
    let root = run-fixture [(run-record)]
    add-artifact $root 100 7 (healthy-analysis | merge {healthy: false})
    let result = verify $root
    rm --recursive --force $root
    assert equal $result.exit_code 1
}

@test
def test-an-artifact-copied-from-another-candidate-is-rejected [] {
    let root = run-fixture [(run-record)]
    add-artifact $root 100 7 (healthy-analysis | merge {candidate_sha: 'ffffffffffffffffffffffffffffffffffffffff'})
    let result = verify $root
    rm --recursive --force $root
    assert equal $result.exit_code 1
}

@test
def test-runs-that-are-not-from-the-release-branch-of-this-repository-are-ignored [] {
    let cases = [
        {name: feature-branch, run: (run-record {head_branch: feature})}
        {name: fork, run: (run-record {head_repository: {full_name: 'someone/flakes'}})}
        {name: pull-request, run: (run-record {event: pull_request})}
        {name: push, run: (run-record {event: push})}
    ]
    let failures = $cases | each {|case|
        let root = run-fixture [$case.run]
        add-artifact $root 100 7 (healthy-analysis)
        let result = verify $root
        rm --recursive --force $root
        if $result.exit_code != 1 { $'($case.name): exit ($result.exit_code), expected 1' }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
}

@test
def test-an-expired-artifact-is-ignored [] {
    let root = run-fixture [(run-record)]
    add-artifact $root 100 7 (healthy-analysis) --expired
    let result = verify $root
    rm --recursive --force $root
    assert equal $result.exit_code 1
}

@test
def test-a-new-analysis-can-be-required-after-the-bake [] {
    let root = run-fixture [(run-record)]
    add-artifact $root 100 7 (healthy-analysis) --created '2026-11-19T04:40:00Z'
    let stale = verify $root --not-before '2026-11-20T00:00:00Z'
    let fresh = verify $root --not-before '2026-11-19T00:00:00Z'
    rm --recursive --force $root
    assert equal $stale.exit_code 1 'an analysis older than the end of the bake must not promote'
    assert equal $fresh.exit_code 0
}

@test
def test-the-commit-must-be-a-full-sha [] {
    let root = run-fixture []
    let result = with-env {PATH: ($env.PATH | prepend ($root | path join bin))} {
        ^bash $VERIFY --repository $REPOSITORY --sha quality-gate-next | complete
    }
    rm --recursive --force $root
    assert equal $result.exit_code 2
}

use std/assert
use std/testing *
use support/isolation.nu

const WORKFLOW = path self | path dirname | path join .. .github workflows quality-gate-canary-analysis.yml

def assembly-script []: nothing -> string {
    let workflow = open --raw $WORKFLOW | from yaml
    let step = $workflow.jobs.analyze.steps | where {|item| ($item.name? | default '') == 'Trigger and analyze sandbox pipelines' } | first
    let start = 'jq --arg id "$project_id" --arg name "$project_name"'
    let end = 'mv "$results.tmp" "$results"'
    assert ($step.run | str contains '--slurpfile analysis "$analysis_file"')
    assert (not ($step.run | str contains '--argjson analysis'))
    assert ($step.run | str contains $start)
    assert ($step.run | str contains $end)
    let middle = $step.run | split row $start | last | split row $end | first
    ["set -euo pipefail" $'($start)($middle)($end)'] | str join (char nl)
}

def assemble [root: path]: nothing -> record {
    with-env {
        project_id: '48'
        project_name: 'python-battlegrounds'
        analysis_file: ($root | path join analysis.json)
        results: ($root | path join results.json)
    } {
        ^bash -c (assembly-script) | complete
    }
}

@test
def test_canary_assembly_accepts_large_analysis_without_command_line_arguments [] {
    let root = mktemp --directory | str trim
    let outcome = try {
        let large = 0..2047 | each { 'x' | fill --width 1024 --character 'x' } | str join
        {healthy: true, diagnostic: $large} | to json --raw | save --force ($root | path join analysis.json)
        '[]' | save --force ($root | path join results.json)
        let run = assemble $root
        assert equal $run.exit_code 0 $run.stderr
        let result = open --raw ($root | path join results.json) | from json | first
        assert equal $result.project_id 48
        assert equal $result.project 'python-battlegrounds'
        assert equal $result.analysis.healthy true
        assert equal ($result.analysis.diagnostic | str length) ($large | str length)
        null
    } catch {|error| $error.msg }
    rm --recursive --force $root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_canary_assembly_rejects_empty_or_multiple_analysis_documents [] {
    let root = mktemp --directory | str trim
    let outcome = try {
        for input in ['' '{} {}' '[]'] {
            $input | save --force ($root | path join analysis.json)
            '[]' | save --force ($root | path join results.json)
            let run = assemble $root
            assert ($run.exit_code != 0) $'accepted invalid analysis: ($input)'
            assert equal (open --raw ($root | path join results.json) | from json) []
        }
        null
    } catch {|error| $error.msg }
    rm --recursive --force $root
    if $outcome != null { error make {msg: $outcome} }
}

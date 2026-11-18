use std/assert
use std/testing *

source ../release/canary-analysis.nu
use support/qg.nu *

def junit [name: string, category: string]: nothing -> string {
    if $category == success {
        $'<testsuites><testsuite><testcase name="($name)" /></testsuite></testsuites>'
    } else {
        $'<testsuites><testsuite><testcase name="($name)"><failure message="Category: ($category)">Category: ($category)</failure></testcase></testsuite></testsuites>'
    }
}

@test
def test_expected_findings_are_healthy [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:detect' 'quality-gate:format' 'quality-gate:lint']
        expected_findings: ['format:python:ruff' 'lint:python:ruff']
        required_checks: ['format:python:ruff' 'lint:python:ruff']
        expected_skipped: []
    } [
        {name: 'quality-gate:detect', status: success, trace: ''}
        {
            name: 'quality-gate:format'
            status: failed
            junit: (junit '. / format:python:ruff' finding)
        }
        {
            name: 'quality-gate:lint'
            status: failed
            junit: (junit '. / lint:python:ruff' finding)
        }
    ])
    assert equal $result.healthy true
}

@test
def test_engine_failure_is_not_healthy [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:detect']
        expected_findings: []
        expected_skipped: []
    } [
        {
            name: 'quality-gate:detect'
            status: failed
            junit: (junit 'quality-gate:detect' engine)
        }
    ])
    assert equal $result.healthy false
    assert equal ($result.engine_failures | length) 1
}

@test
def test_unexpected_finding_is_not_healthy [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:detect' 'quality-gate:lint']
        expected_findings: []
        expected_skipped: []
    } [
        {name: 'quality-gate:detect', status: success, trace: ''}
        {
            name: 'quality-gate:lint'
            status: failed
            junit: (junit '. / lint:python:ruff' finding)
        }
    ])
    assert equal $result.healthy false
    assert equal ($result.unexpected_findings | length) 1
}

@test
def test_incomplete_pipeline_is_inconclusive [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:detect' 'quality-gate:tests']
        expected_findings: []
        expected_skipped: ['quality-gate:tests']
    } [
        {name: 'quality-gate:detect', status: success, trace: ''}
        {name: 'quality-gate:tests', status: running, trace: ''}
    ])
    assert equal $result.healthy false
    assert equal ($result.inconclusive | length) 1
}

@test
def test_normal_tool_text_does_not_create_engine_failure [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:format']
        expected_findings: ['format:python:ruff']
        required_checks: ['format:python:ruff']
        expected_skipped: []
    } [
        {
            name: 'quality-gate:format'
            status: failed
            junit: '<testsuites><testsuite><testcase name=". / format:python:ruff"><failure message="Category: finding">Category: finding\nNo such file or directory in source diagnostic</failure></testcase></testsuite></testsuites>'
        }
    ])
    assert equal $result.healthy true
    assert equal ($result.engine_failures | length) 0
}

def engine-job [root: path, app: string, category: string]: nothing -> record {
    let result = run-app $root $app category $category
    {
        name: $'quality-gate:($category)'
        status: (if $result.exit_code == 0 { 'success' } else { 'failed' })
        junit: (open --raw $result.junit)
        trace: ''
    }
}

def detect-job []: nothing -> record {
    {name: 'quality-gate:detect', status: 'success', trace: ''}
}

@test
def test_the_report_written_by_the_engine_is_understood [] {
    let root = fixture-repo python-format
    let outcome = try {
        let result = evaluate {
            required_jobs: ['quality-gate:detect' 'quality-gate:format']
            expected_findings: ['format:python:ruff']
            required_checks: ['format:python:ruff']
            expected_skipped: []
        } [(detect-job) (engine-job $root quality-gate-python format)]
        assert equal $result.healthy true $'unhealthy: ($result | to nuon)'
        assert equal ($result.jobs | where name == 'format:python:ruff' | first | get category) finding
        null
    } catch {|error|
        $error.msg
    }
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_a_check_that_stops_detecting_makes_the_canary_unhealthy [] {
    let root = fixture-repo python-clean
    let outcome = try {
        let result = evaluate {
            required_jobs: ['quality-gate:detect' 'quality-gate:format']
            expected_findings: ['format:python:ruff']
            required_checks: ['format:python:ruff']
            expected_skipped: []
        } [(detect-job) (engine-job $root quality-gate-python format)]
        assert equal $result.healthy false
        assert equal $result.missing_findings ['format:python:ruff']
        null
    } catch {|error|
        $error.msg
    }
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_a_tool_that_could_not_run_is_an_engine_failure [] {
    let root = fixture-repo python-format
    let outcome = try {
        let bin = $root | path join fakebin
        write-exit-tool $bin ruff 2 'ruff: invalid configuration'
        let run = run-script $root {PATH: ($env.PATH | prepend $bin)} category format
        let result = evaluate {
            required_jobs: ['quality-gate:format']
            expected_findings: ['format:python:ruff']
            required_checks: ['format:python:ruff']
            expected_skipped: []
        } [{name: 'quality-gate:format', status: 'failed', junit: (open --raw $run.junit), trace: ''}]
        assert equal $result.healthy false
        assert equal ($result.engine_failures | length) 1
        assert equal $result.missing_findings ['format:python:ruff']
        null
    } catch {|error|
        $error.msg
    }
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_expectations_can_name_the_project [] {
    let root = fixture-repo python-format
    let outcome = try {
        let job = engine-job $root quality-gate-python format
        let base = {required_jobs: ['quality-gate:format'], required_checks: ['format:python:ruff'], expected_skipped: []}
        let named = evaluate ($base | merge {expected_findings: ['. / format:python:ruff']}) [$job]
        assert equal $named.healthy true $'unhealthy: ($named | to nuon)'
        let wrong = evaluate ($base | merge {expected_findings: ['services/api / format:python:ruff']}) [$job]
        assert equal $wrong.healthy false
        assert equal ($wrong.unexpected_findings | length) 1
        assert equal $wrong.missing_findings ['services/api / format:python:ruff']
        null
    } catch {|error|
        $error.msg
    }
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_a_failed_job_without_a_readable_report_is_an_engine_failure [] {
    let expectation = {required_jobs: ['quality-gate:lint'], expected_findings: [], required_checks: [], expected_skipped: []}
    for junit in ['' 'not xml at all' '<testsuites><testsuite>'] {
        let result = evaluate $expectation [{name: 'quality-gate:lint', status: 'failed', junit: $junit, trace: ''}]
        assert equal $result.healthy false $'junit "($junit)" must not be healthy'
        assert equal ($result.engine_failures | length) 1
    }
}

@test
def test_required_checks_and_jobs_must_have_run [] {
    let result = evaluate {
        required_jobs: ['quality-gate:detect' 'quality-gate:lint']
        expected_findings: []
        required_checks: ['lint:python:ruff' 'lint:python:basedpyright']
        expected_skipped: []
    } [
        (detect-job)
        {name: 'quality-gate:lint', status: 'success', junit: '<testsuites><testsuite><testcase name=". / lint:python:ruff" /></testsuite></testsuites>', trace: ''}
    ]
    assert equal $result.healthy false
    assert equal $result.missing_checks ['lint:python:basedpyright']
    let without_job = evaluate {required_jobs: ['quality-gate:strlint'], expected_findings: [], required_checks: [], expected_skipped: []} [(detect-job)]
    assert equal $without_job.healthy false
    assert equal $without_job.missing_jobs ['quality-gate:strlint']
}

@test
def test_a_job_skipped_without_being_expected_to_is_unhealthy [] {
    let expectation = {required_jobs: ['quality-gate:detect' 'quality-gate:tests'], expected_findings: [], required_checks: [], expected_skipped: []}
    let skipped = evaluate $expectation [(detect-job) {name: 'quality-gate:tests', status: 'skipped', trace: ''}]
    assert equal $skipped.healthy false
    assert equal ($skipped.unexpected_skipped | length) 1
    let expected = evaluate ($expectation | merge {expected_skipped: ['quality-gate:tests']}) [(detect-job) {name: 'quality-gate:tests', status: 'skipped', trace: ''}]
    assert equal $expected.healthy true
}

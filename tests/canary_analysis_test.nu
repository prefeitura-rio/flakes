use std/assert
use std/testing *

source ../release/canary-analysis.nu

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

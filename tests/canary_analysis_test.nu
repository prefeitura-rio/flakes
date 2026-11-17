use std/assert
use std/testing *

source ../release/canary-analysis.nu

@test
def test_expected_findings_are_healthy [] {
    let result = (evaluate {
        required_jobs: ['quality-gate:detect' 'quality-gate:format' 'quality-gate:lint']
        expected_findings: ['quality-gate:format' 'quality-gate:lint']
        expected_skipped: []
    } [
        {name: 'quality-gate:detect', status: success, trace: ''}
        {name: 'quality-gate:format', status: failed, trace: 'finding: ruff found violations'}
        {name: 'quality-gate:lint', status: failed, trace: 'finding: complexipy found violations'}
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
        {name: 'quality-gate:detect', status: failed, trace: 'engine: nix run failed with exit code 3'}
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
        {name: 'quality-gate:lint', status: failed, trace: 'finding: unexpected violation'}
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

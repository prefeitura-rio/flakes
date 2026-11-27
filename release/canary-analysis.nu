#!/usr/bin/env nu

def xml-testcases [junit: string]: nothing -> list<record> {
    if ($junit | str trim | is-empty) {
        return []
    }
    try {
        let document = $junit | from xml
        $document.content
        | where tag == testsuite
        | each {|suite| $suite.content | where tag == testcase }
        | flatten
    } catch {
        []
    }
}

def check-name [name: string]: nothing -> string {
    if ($name | str contains ' / ') {
        $name | split row ' / ' | last
    } else {
        $name
    }
}

# Keep the classification proof compact even when a tool emits megabytes of
# diagnostics. The complete message remains available in the GitLab artifact.
def summarize-reason [message: string]: nothing -> string {
    if ($message | str length) > 1024 {
        let bytes = $message | into binary
        mut limit = 1024
        mut prefix = $bytes | bytes at 0..<$limit
        while (($prefix | decode utf-8 | into binary) != $prefix) {
            $limit = $limit - 1
            $prefix = $bytes | bytes at 0..<$limit
        }
        $"($prefix | decode utf-8)\n[truncated; see GitLab job artifact]"
    } else {
        $message
    }
}

def classify-testcase [job: record, testcase: record]: nothing -> record {
    let raw_name = $testcase.attributes.name? | default $job.name
    let name = check-name $raw_name
    let failures = $testcase.content? | default [] | where tag == failure
    if ($failures | is-empty) {
        { name: $name, qualified: $raw_name, job: $job.name, status: 'success', category: 'none', reason: '' }
    } else {
        let message = $failures | first | get attributes.message? | default ''
        # The engine writes the category as the first line of the message. Tool
        # output further down can say anything, so it is never searched.
        let category = if ($message | str starts-with 'Category: finding') {
            'finding'
        } else {
            'engine'
        }
        # Inspect the full diagnostic before truncating the proof. The cache can
        # otherwise satisfy an expected finding while hiding a broken check.
        let cache_diagnostic = $message | str contains '.cache/quality-gate/'
        { name: $name, qualified: $raw_name, job: $job.name, status: $job.status, category: $category, reason: (summarize-reason $message), cache_diagnostic: $cache_diagnostic }
    }
}

export def classify-job [job: record]: nothing -> list<record> {
    let status = $job.status
    let junit = $job.junit? | default ''
    if $status in [skipped, manual] {
        [{ name: $job.name, qualified: $job.name, job: $job.name, status: $status, category: 'none', reason: '' }]
    } else if $status in [created, pending, running] {
        [{ name: $job.name, qualified: $job.name, job: $job.name, status: $status, category: 'inconclusive', reason: 'Job did not finish.' }]
    } else {
        let testcases = xml-testcases $junit
        if ($testcases | is-empty) {
            let category = if $status == success { 'none' } else { 'engine' }
            [{ name: $job.name, qualified: $job.name, job: $job.name, status: $status, category: $category, reason: (if $status == success { '' } else { 'Quality Gate JUnit artifact was missing or invalid.' }) }]
        } else {
            $testcases | each {|testcase| classify-testcase $job $testcase }
        }
    }
}

# An entry of expected_findings is either a check name ("lint:python:ruff") or a
# project-qualified one ("services/api / lint:python:ruff").
def matches-entry [row: record, entries: list<string>]: nothing -> bool {
    ($row.name in $entries) or ($row.qualified in $entries)
}

export def evaluate [expectation: record, jobs: list<record>]: nothing -> record {
    let classified = $jobs | each {|job| classify-job $job } | flatten
    let expected_findings = $expectation.expected_findings? | default []
    let expected_skipped = $expectation.expected_skipped? | default []
    let required_jobs = $expectation.required_jobs? | default []
    let required_checks = $expectation.required_checks? | default []
    let job_names = $classified | get job | uniq
    let check_names = $classified | get name | uniq
    let missing_jobs = $required_jobs | where {|name| $name not-in $job_names }
    let missing_checks = $required_checks | where {|name| $name not-in $check_names }
    let findings = $classified | where category == finding
    let engine_failures = $classified | where category == engine
    let unexpected_findings = $findings | where {|row| not (matches-entry $row $expected_findings) }
    let missing_findings = $expected_findings | where {|entry|
        not ($findings | any {|row| $entry in [$row.name $row.qualified] })
    }
    let unexpected_skipped = $classified | where status == skipped and job not-in $expected_skipped
    let inconclusive = $classified | where category == inconclusive
    let cache_diagnostics = $classified | where {|row| $row.cache_diagnostic? | default false }
    let healthy = (
        ($missing_jobs | is-empty)
        and ($missing_checks | is-empty)
        and ($missing_findings | is-empty)
        and ($engine_failures | is-empty)
        and ($unexpected_findings | is-empty)
        and ($unexpected_skipped | is-empty)
        and ($inconclusive | is-empty)
        and ($cache_diagnostics | is-empty)
    )
    {
        healthy: $healthy
        missing_jobs: $missing_jobs
        missing_checks: $missing_checks
        missing_findings: $missing_findings
        engine_failures: $engine_failures
        unexpected_findings: $unexpected_findings
        unexpected_skipped: $unexpected_skipped
        inconclusive: $inconclusive
        cache_diagnostics: $cache_diagnostics
        jobs: $classified
    }
}

def main [
    command: string
    expectation_file: path
    project_id: int
    jobs_file: path
] {
    if $command != evaluate {
        error make {msg: $'Unknown command: ($command)'}
    }
    let document = open --raw $expectation_file | from yaml
    let jobs = open --raw $jobs_file | from json
    let project = $document.projects | where id == $project_id | first
    if $project == null {
        error make {msg: $'No canary expectation exists for project ($project_id).'}
    }
    let expectation = $project | merge {required_jobs: $document.required_jobs}
    let result = evaluate $expectation $jobs
    $result | to json
}

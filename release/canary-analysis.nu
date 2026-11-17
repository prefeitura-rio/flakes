#!/usr/bin/env nu

const ENGINE_MARKERS = [
    'Category: `engine`'
    'engine: '
    'exit code 3'
    'Permission denied'
    'unexpected EOF'
    'could not resolve Quality Gate'
    'failed to initialize build cache'
    'No such file or directory'
]

def has-engine-marker [trace: string]: nothing -> bool {
    $ENGINE_MARKERS | any {|marker| $trace | str contains $marker }
}

export def classify-job [job: record]: nothing -> record {
    let name = $job.name
    let status = $job.status
    let trace = $job.trace? | default ''
    if $status in [success] {
        { name: $name, status: 'success', category: 'none', reason: '' }
    } else if $status in [skipped, manual] {
        { name: $name, status: $status, category: 'none', reason: '' }
    } else if $status in [created, pending, running] {
        { name: $name, status: $status, category: 'inconclusive', reason: 'Job did not finish.' }
    } else if (has-engine-marker $trace) {
        { name: $name, status: $status, category: 'engine', reason: 'Engine failure marker found in job trace.' }
    } else {
        { name: $name, status: $status, category: 'finding', reason: 'Job failed without an engine failure marker.' }
    }
}

export def evaluate [expectation: record, jobs: list<record>]: nothing -> record {
    let classified = $jobs | each {|job| classify-job $job }
    let expected_findings = $expectation.expected_findings? | default []
    let expected_skipped = $expectation.expected_skipped? | default []
    let required_jobs = $expectation.required_jobs? | default []
    let names = $classified | get name
    let missing = $required_jobs | where {|name| $name not-in $names }
    let engine_failures = $classified | where category == engine
    let unexpected_findings = $classified | where category == finding and name not-in $expected_findings
    let unexpected_skipped = $classified | where status == skipped and name not-in $expected_skipped
    let inconclusive = $classified | where category == inconclusive
    let healthy = (($missing | is-empty) and ($engine_failures | is-empty) and ($unexpected_findings | is-empty) and ($unexpected_skipped | is-empty) and ($inconclusive | is-empty))
    {
        healthy: $healthy
        missing_jobs: $missing
        engine_failures: $engine_failures
        unexpected_findings: $unexpected_findings
        unexpected_skipped: $unexpected_skipped
        inconclusive: $inconclusive
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

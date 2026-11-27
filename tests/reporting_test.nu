use std/assert
use std/testing *
use support/qg.nu *
source ../devenv/files/quality-gate/quality-gate.nu

def finish [root: path, outcome: any] {
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

def fail-tool [bin: path, name: string, output: string] {
    write-executable ($bin | path join $name) $"#!/bin/sh\ncat <<'QG_TEST_OUTPUT'\n($output)\nQG_TEST_OUTPUT\nexit 1\n"
}

@test
def test_markdown_and_junit_remove_terminal_codes_without_losing_unicode [] {
    let root = fixture-repo python-clean
    let outcome = try {
        let bin = $root | path join fakebin
        let esc = char --integer 27
        let csi = char --integer 155
        let osc = char --integer 157
        let end = char --integer 156
        let text = $"($esc)[38;2;244;191;117;1m⚠($esc)[0m F401 unused import\n╭─[ação.py:4:2]\n($esc)]8;;https://example.invalid/secret($esc)\\detalhes($esc)]8;;($esc)\\ (char --integer 1)\n($esc)[38:2:255:0:0mcolon-color($esc)[0m ($csi)31mcsi-color($csi)0m ($osc)8;;https://example.invalid/other($end)link($osc)8;;($end)\nsource contains ``` in a string"
        fail-tool $bin ruff $text
        write-exit-tool $bin complexipy 0
        let summary = $'($root)-reports/summary.md'
        let result = run-script $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_SUMMARY_FILE: $summary
            QUALITY_GATE_REVISION: $"rev-($esc)[31m123($esc)[0m"
        } category lint
        let markdown = open --raw $summary
        let junit = open --raw $result.junit
        for report in [$markdown $junit] {
            assert (not ($report | str contains $esc)) 'reports must not contain ANSI escapes'
            assert (not ($report | str contains $csi)) 'reports must not contain C1 CSI control characters'
            assert (not ($report | str contains $osc)) 'reports must not contain C1 OSC control characters'
            assert (not ($report | str contains (char --integer 1))) 'reports must not contain control characters'
            assert (not ($report | str contains 'example.invalid/')) 'OSC hyperlink targets must not appear'
            assert ($report | str contains 'ação.py') 'UTF-8 filenames must remain readable'
            assert ($report | str contains 'detalhes') 'visible hyperlink text must be preserved'
            assert ($report | str contains 'colon-color csi-color') 'colour parameter text must be removed without dropping diagnostics'
        }
        assert ($markdown | str contains 'Revision: `rev-123`')
        assert ($markdown | str contains '````text') 'embedded backticks must not break the Markdown code block'
        assert equal ($result.checks | where failed | first | get category) finding
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_lint_summary_counts_recognized_headers_without_changing_verdict [] {
    let root = fixture-repo ts-clean
    let outcome = try {
        let bin = $root | path join fakebin
        let text = "  × eslint(no-var): Use const\n  ⚠ jsx-a11y(alt-text): Missing alt\n  × eslint(no-var): Use let\n"
        fail-tool $bin oxlint $text
        let summary = $'($root)-reports/lint.md'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin), QUALITY_GATE_SUMMARY_FILE: $summary} category lint
        let markdown = open --raw $summary
        assert ($markdown | str contains '| `eslint(no-var)` | error | 2 |') $markdown
        assert ($markdown | str contains '| `jsx-a11y(alt-text)` | warning | 1 |') $markdown
        assert ($markdown | str contains 'counts may be incomplete')
        assert equal ($result.checks | where failed | first | get category) finding
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_markdown_bounds_long_diagnostics_but_junit_remains_complete [] {
    let root = fixture-repo python-clean
    let outcome = try {
        let bin = $root | path join fakebin
        let text = ((0..39 | each { 'x' | fill --width 1024 --character 'x' } | str join) + 'END-OF-DIAGNOSTIC .cache/quality-gate/uv/probe.py')
        fail-tool $bin ruff $text
        write-exit-tool $bin complexipy 0
        let summary = $'($root)-reports/lint.md'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin), QUALITY_GATE_SUMMARY_FILE: $summary} category lint
        let markdown = open --raw $summary
        let junit = open --raw $result.junit
        assert ($markdown | str contains 'Diagnostic truncated in this summary')
        assert ($markdown | str contains ($result.junit | path basename))
        assert (not ($markdown | str contains 'END-OF-DIAGNOSTIC'))
        assert ($junit | str contains 'END-OF-DIAGNOSTIC') 'the full proof must remain in JUnit'
        assert equal ($result.checks | where failed | first | get category) finding
        let reports = $'($root)-reports'
        let expectations = $reports | path join expectations.yaml
        let jobs = $reports | path join jobs.json
        "required_jobs: ['quality-gate:lint']\nprojects:\n  - id: 48\n    expected_findings: ['lint:python:ruff']\n" | save --force $expectations
        [{name: 'quality-gate:lint', status: failed, junit: $junit}] | to json --raw | save --force $jobs
        let canary = ^nu ($FLAKE | path join release canary-analysis.nu) evaluate $expectations 48 $jobs | complete
        assert equal $canary.exit_code 0 $canary.stderr
        let verdict = $canary.stdout | from json
        assert equal $verdict.healthy false 'the complete JUnit must still be checked by the canary'
        assert equal ($verdict.cache_diagnostics | length) 1
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_summary_without_junit_keeps_the_complete_diagnostic [] {
    hide-env --ignore-errors QUALITY_GATE_JUNIT_FILE
    let text = ((0..39 | each { 'x' | fill --width 1024 --character 'x' } | str join) + 'END-OF-DIAGNOSTIC')
    assert equal (summary-diagnostic $text) $text
}

@test
def test_truncation_keeps_utf8_boundaries_and_existing_replacement_characters [] {
    let header = 'ação�'
    let padding = 'x' | fill --width (32767 - ($header | str length)) --character 'x'
    let text = $'($header)($padding)⚠ after-boundary'
    let summary = with-env {QUALITY_GATE_JUNIT_FILE: '/tmp/probe.xml'} { summary-diagnostic $text }
    assert ($summary | str starts-with $header)
    assert equal (($summary | split row '�' | length) - 1) 1 'truncation must not introduce a replacement character'
    assert (not ($summary | str contains '⚠')) 'a partially cut Unicode symbol must be omitted'
    assert ($summary | str contains 'Diagnostic truncated')
}

@test
def test_successful_install_logs_do_not_drown_out_type_errors [] {
    let root = fixture-repo ts-clean
    let outcome = try {
        let bin = $root | path join fakebin
        write-node-runtime $bin 24
        write-exit-tool $bin npm 0 'added 53 packages; npm audit fix --force'
        write-project-compiler $root tsc 'echo "src/app.ts:1: type error TS2322"; exit 2'
        let summary = $'($root)-reports/typecheck.md'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin), QUALITY_GATE_SUMMARY_FILE: $summary} category typecheck
        let report = open --raw $summary
        assert ($result.stdout | str contains 'npm audit fix --force') 'the complete install log must remain visible in CI'
        assert (not ($report | str contains 'npm audit fix --force')) 'successful installation is not a compiler diagnostic'
        assert ($report | str contains 'TS2322') $report
        assert equal ($result.checks | where failed | first | get category) finding
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_failed_dependency_install_remains_in_reports_as_engine_failure [] {
    let root = fixture-repo ts-clean
    let outcome = try {
        let bin = $root | path join fakebin
        write-node-runtime $bin 24
        write-exit-tool $bin npm 1 'registry unavailable: test diagnostic'
        let summary = $'($root)-reports/typecheck.md'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin), QUALITY_GATE_SUMMARY_FILE: $summary} category typecheck
        let report = open --raw $summary
        assert ($report | str contains 'registry unavailable: test diagnostic') $report
        assert equal ($result.checks | where failed | first | get category) engine
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_only_known_redundant_golangci_warnings_are_shortened [] {
    let root = fixture-repo go-clean
    let outcome = try {
        let bin = $root | path join fakebin
        let text = "main.go:4:2: unchecked error (errcheck)\nlevel=warning msg=\"[linters_context] gocritic: no need to enable check \\\"appendAssign\\\": it's already enabled\"\nlevel=warning msg=\"[linters_context] gocritic: no need to enable check \\\".cache/quality-gate/probe\\\": it's already enabled\"\nlevel=warning msg=\"another warning must remain\""
        fail-tool $bin golangci-lint $text
        write-exit-tool $bin go 0
        let summary = $'($root)-reports/lint.md'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin), QUALITY_GATE_SUMMARY_FILE: $summary} category lint
        let report = open --raw $summary
        assert ($result.stdout | str contains 'no need to enable check') 'the complete warning must remain in the job log'
        assert (not ($report | str contains 'appendAssign')) $report
        assert ($report | str contains '1 redundant gocritic configuration warnings omitted') $report
        assert ($report | str contains 'another warning must remain') $report
        assert ($report | str contains '.cache/quality-gate/probe') 'the canary must still see cache diagnostics in JUnit'
        assert (($result.checks | where check == 'lint:go:golangci' | first | get message) | str contains '.cache/quality-gate/probe')
        assert ($report | str contains 'unchecked error') $report
        assert ($report | str contains '| `errcheck` | unspecified | 1 |') $report
        assert equal ($result.checks | where check == 'lint:go:golangci' | first | get category) finding
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

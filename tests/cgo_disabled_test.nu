use std/assert
use std/testing *
use support/qg.nu *

def finish [root: path, outcome: any] {
    cleanup $root
    if $outcome != null { error make {msg: $outcome} }
}

def isolated-nix-path [root: path]: nothing -> list<path> {
    let bin = $root | path join host-bin
    mkdir $bin
    let nix = which nix | where type == external | first | get path
    ^ln -s $nix ($bin | path join nix)
    [$bin]
}

@test
def test_go_checks_disable_cgo_and_report_skipped_files [] {
    let root = fixture-repo go-clean
    let outcome = try {
        write-file $root main.go "package main\n\nimport (\n    \"net/http\"\n    \"os/user\"\n)\n\nfunc main() { _ = http.MethodGet; _ = user.Current }\n"
        write-file $root main_test.go "package main\n\nimport \"testing\"\n\nfunc TestMainPackage(t *testing.T) {}\n"
        write-file $root native.go "//go:build cgo\n\npackage main\n\n/* static int answer(void) { return 42; } */\nimport \"C\"\n\nfunc nativeAnswer() int { return int(C.answer()) }\n"
        write-file $root 'native```probe.go' "//go:build cgo\n\npackage main\n\nfunc otherNative() {}\n"
        write-file $root native_test.go "//go:build cgo\n\npackage main\n\nimport \"testing\"\n\nfunc TestNative(t *testing.T) {}\n"
        write-file $root cgoonly/native.go "package cgoonly\n\n/* static int answer(void) { return 42; } */\nimport \"C\"\n\nfunc Answer() int { return int(C.answer()) }\n"
        commit-all $root
        let path = isolated-nix-path $root
        let environment = {PATH: $path, CGO_ENABLED: '1', CC: '/nonexistent/compiler'}
        let build = with-env $environment { run-app $root quality-gate-go category typecheck }
        assert equal $build.exit_code 0 $'typecheck: ($build.stdout) ($build.stderr)'
        let summary = open --raw $'($root)-reports/summary.md'
        let junit = open --raw $build.junit
        assert ('## Go cgo coverage' in ($summary | lines)) 'the cgo notice must have a proper Markdown heading'
        assert ($summary | str contains '````text') 'file names containing backticks must not break the Markdown block'
        for report in [$build.stdout $summary $junit] {
            assert ($report | str contains 'CGO_ENABLED=0') $report
            assert ($report | str contains 'native.go') $report
            assert ($report | str contains 'native_test.go') $report
            assert ($report | str contains 'native```probe.go') $report
            assert ($report | str contains 'cgoonly/native.go') $report
        }
        let lint = with-env $environment { run-app $root quality-gate-go category lint }
        let vet = $lint.checks | where check == 'lint:go:vet' | first
        assert equal $vet.category none $vet.message
        let golangci = $lint.checks | where check == 'lint:go:golangci' | first
        assert (not ($golangci.message | str contains 'cgo preprocessing failed')) $golangci.message
        let tests = with-env $environment { run-app $root quality-gate-go test }
        assert equal $tests.exit_code 0 $'go test: ($tests.stdout) ($tests.stderr)'
        assert ((open --raw $tests.junit) | str contains 'cgoonly/native.go')
        let direct = with-env $environment { run-app $root quality-gate-go typecheck go build }
        assert equal $direct.exit_code 0 $'individual check: ($direct.stdout) ($direct.stderr)'
        assert ($direct.stdout | str contains 'CGO_ENABLED=0') $direct.stdout
        assert ($direct.stdout | str contains 'cgoonly/native.go') $direct.stdout
        write-file $root main.go "package main\n\nfunc main() { missingSymbol() }\n"
        let bad_source = with-env $environment { run-app $root quality-gate-go category typecheck }
        assert ($bad_source.exit_code != 0)
        let failure = $bad_source.checks | where failed | first
        assert equal $failure.category finding $failure.message
        assert ($failure.message | str contains 'Go compilation reported errors') $failure.message
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_formatter_reports_include_paths_in_junit [] {
    let root = fixture-repo python-format
    let outcome = try {
        let run = run-app $root quality-gate-python category format
        assert ($run.exit_code != 0)
        let failure = $run.checks | where failed | first
        assert equal $failure.category finding
        assert ($failure.message | str contains '.py') 'the formatter diagnostic should identify the affected file'
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_cgo_metadata_failure_warns_without_leaking_tool_output [] {
    let root = fixture-repo go-clean
    let outcome = try {
        let bin = $root | path join fakebin
        write-executable ($bin | path join go) "#!/bin/sh\nif [ \"$1\" = list ]; then echo 'sensitive diagnostic' >&2; exit 1; fi\nexit 0\n"
        let summary = $'($root)-reports/summary.md'
        let run = run-script $root {PATH: ($env.PATH | prepend $bin), CGO_ENABLED: '1', QUALITY_GATE_SUMMARY_FILE: $summary} category typecheck
        assert equal $run.exit_code 0 $run.stderr
        for report in [$run.stdout (open --raw $summary) (open --raw $run.junit)] {
            assert ($report | str contains 'cgo file detection was incomplete') $report
            assert (not ($report | str contains 'sensitive diagnostic')) $report
        }
        write-executable ($bin | path join go) "#!/bin/sh\nif [ \"$1\" = list ]; then printf '%s\\n' '{\"GoFiles\":[\"native.go\"],\"Error\":{\"Err\":\"sensitive diagnostic\"}}'; fi\nexit 0\n"
        let incomplete = run-script $root {PATH: ($env.PATH | prepend $bin), CGO_ENABLED: '1', QUALITY_GATE_SUMMARY_FILE: $summary} category typecheck
        assert equal $incomplete.exit_code 0 $incomplete.stderr
        assert ((open --raw $summary) | str contains 'cgo file detection was incomplete')
        assert (not ((open --raw $summary) | str contains 'sensitive diagnostic'))
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_go_cgo_notice_respects_project_exclusions [] {
    let root = fixture-repo go-clean
    let outcome = try {
        write-file $root native.go "//go:build cgo\n\npackage main\n\nfunc native() {}\n"
        write-file $root excluded/native.go "package excluded\n\n/* static int a(void) { return 1; } */\nimport \"C\"\n"
        write-file $root extra.go "package main\n\nfunc extra() {}\n"
        write-file $root another.go "package main\n\nfunc another() {}\n"
        write-file $root .quality-gate/exclude 'excluded/native.go'
        commit-all $root
        let path = isolated-nix-path $root
        let run = with-env {PATH: $path, CGO_ENABLED: '1', CC: '/nonexistent/compiler'} {
            run-app $root quality-gate-go category typecheck
        }
        assert equal $run.exit_code 0 $run.stderr
        let junit = open --raw $run.junit
        assert ($junit | str contains '- native.go') $junit
        assert (not ($junit | str contains 'excluded/native.go')) $junit
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

@test
def test_python_checks_keep_the_callers_cgo_environment [] {
    let root = fixture-repo python-format
    let outcome = try {
        let bin = $root | path join fakebin
        write-executable ($bin | path join ruff) "#!/bin/sh\nprintf 'inherited-cgo=%s\\n' \"$CGO_ENABLED\" >&2\nexit 1\n"
        let run = run-script $root {PATH: ($env.PATH | prepend $bin), CGO_ENABLED: '1'} category format
        assert ($run.exit_code != 0)
        assert ((open --raw $run.junit) | str contains 'inherited-cgo=1')
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

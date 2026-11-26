use std/assert
use std/testing *
use support/qg.nu *

def finish [root: path, outcome: any] {
    cleanup $root
    if $outcome != null {
        error make {msg: $outcome}
    }
}

def failed-checks [result: record]: nothing -> table {
    $result.checks | where failed
}

# ---------------------------------------------------------------------------
# Auto-fix must follow the same exclusions as the checks.
# ---------------------------------------------------------------------------

@test
def test-fix-does-not-touch-excluded-files-in-any-language [] {
    let cases = [
        {fixture: python-excluded, app: quality-gate-python, language: python, fixme: fixme.py, broken: "y=2\n", fixed: "y = 2\n", generated: gen/bad.py}
        {fixture: go-excluded, app: quality-gate-go, language: go, fixme: c/fixme.go, broken: "package c\n\nfunc Three() int {\n\n\treturn 3\n}\n", fixed: "package c\n\nfunc Three() int {\n\treturn 3\n}\n", generated: gen/bad.go}
        {fixture: ts-excluded, app: quality-gate-typescript, language: typescript, fixme: src/fixme.ts, broken: "export const value=1\n", fixed: "export const value = 1;\n", generated: gen/bad.ts}
    ]
    for case in $cases {
        let root = fixture-repo $case.fixture
        let outcome = try {
            write-file $root $case.fixme $case.broken
            commit-all $root
            let before = open --raw ($root | path join $case.generated)
            let result = run-app $root $case.app fix $case.language
            assert equal $result.exit_code 0
            assert equal (open --raw ($root | path join $case.fixme)) $case.fixed $'($case.language): the non-excluded file must be fixed'
            assert equal (open --raw ($root | path join $case.generated)) $before $'($case.language): the excluded file must not be rewritten'
            null
        } catch {|error|
            $'($case.fixture): ($error.msg)'
        }
        finish $root $outcome
    }
}

# ---------------------------------------------------------------------------
# basedpyright keeps ignoring the virtualenv when exclusions are configured.
# ---------------------------------------------------------------------------

@test
def test-pyright-ignores-the-virtualenv-even-with-exclusions [] {
    let root = fixture-repo python-excluded
    let outcome = try {
        let first = run-app $root quality-gate-python category typecheck
        assert equal $first.exit_code 0
        write-file $root .venv/bad_module.py "value: int = 'text'\n"
        let second = run-app $root quality-gate-python category typecheck
        assert equal $second.exit_code 0 $'a broken file inside .venv must not be analysed:\n($second.stdout)'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-pyright-ignores-cache-but-still-checks-project-code [] {
    let root = fixture-repo python-clean
    let outcome = try {
        for file in [
            '.cache/quality-gate/uv/archive-v0/dependency/bad.py'
            'src/.cache/quality-gate/uv/archive-v0/dependency/bad.py'
            '.cache/another-tool/bad.py'
        ] {
            write-file $root $file "value: int = 'text'\n"
        }
        let clean = run-app $root quality-gate-python category typecheck
        assert equal $clean.exit_code 0 $'cache errors must be ignored:\n($clean.stdout)\n($clean.stderr)'
        assert equal (failed-checks $clean | length) 0
        write-file $root app.py "value: int = 'text'\n"
        let broken = run-app $root quality-gate-python category typecheck
        assert ($broken.exit_code != 0) 'the cache exclusion must not hide real source errors'
        let failure = failed-checks $broken | first
        assert equal $failure.check 'typecheck:python:basedpyright'
        assert equal $failure.category finding
        assert ($failure.message | str contains 'app.py') $failure.message
        assert (not ($failure.message | str contains '.cache/')) $failure.message
        null
    } catch {|error| $error.msg }
    finish $root $outcome
}

# ---------------------------------------------------------------------------
# Exclusion guard rails.
# ---------------------------------------------------------------------------

@test
def test-broad-exclusion-patterns-are-rejected [] {
    let root = fixture-repo python-excluded
    let outcome = try {
        for pattern in ['*' '**' '**/*' '.' '/'] {
            write-file $root .quality-gate/exclude $'($pattern)(char nl)'
            let result = run-app $root quality-gate-detect detect
            assert ($result.exit_code != 0) $'pattern ($pattern) must be rejected'
            assert (($result.stdout + $result.stderr) | str contains 'Broad patterns') $'pattern ($pattern): ($result.stderr)'
        }
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-exclusions-cannot_hide_more_than_thirty_percent_of_the_code [] {
    let root = fixture-repo python-excluded
    let outcome = try {
        for index in 1..4 {
            write-file $root $'gen/extra($index).py' "value = 1\n"
        }
        commit-all $root
        let result = run-app $root quality-gate-detect detect
        assert ($result.exit_code != 0)
        assert (($result.stdout + $result.stderr) | str contains 'maximum is 30%') $result.stderr
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-unknown-categories-and-verbs-are-rejected [] {
    let root = fixture-repo python-clean
    let outcome = try {
        let cases = [
            {arguments: [category bogus], message: 'Usage'}
            {arguments: [category], message: 'Usage'}
            {arguments: [bogus python], message: 'Usage'}
            {arguments: [lint bogus], message: 'Unknown language'}
        ]
        for case in $cases {
            let result = run-app $root quality-gate-python ...$case.arguments
            assert ($result.exit_code != 0) $'($case.arguments | str join " ") must fail, got exit 0:\n($result.stdout)'
            assert (($result.stdout + $result.stderr) | str contains $case.message) $'($case.arguments | str join " ") must report: ($case.message)'
        }
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

# ---------------------------------------------------------------------------
# Python runtime and lock handling.
# ---------------------------------------------------------------------------

@test
def test-stale-lockfile-is-an-engine-failure-and-is-never-rewritten [] {
    let root = fixture-repo python-stale-lock
    let outcome = try {
        let result = run-app $root quality-gate-python category typecheck
        assert ($result.exit_code != 0)
        let failures = failed-checks $result
        assert equal ($failures | get check) [typecheck:python:basedpyright]
        assert equal ($failures | first | get category) engine
        assert equal (tree-status $root) '' 'uv.lock must not be rewritten'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-python-interpreter-follows-the-project-declaration [] {
    let cases = [
        {fixture: python-pinned-312, expected: '3.12'}
        {fixture: python-requires-312, expected: '3.12'}
        {fixture: python-clean, expected: '3.14'}
    ]
    for case in $cases {
        let root = fixture-repo $case.fixture
        let outcome = try {
            let result = run-app $root quality-gate-python category typecheck
            assert equal $result.exit_code 0 $result.stdout
            let venvs = quality-gate-venvs $root
            assert equal ($venvs | length) 1 $'expected one Quality Gate environment, got ($venvs)'
            assert (not (($root | path join .venv) | path exists)) 'the project .venv must not be created or touched'
            let configuration = open --raw ($venvs | first | path join pyvenv.cfg)
            assert ($configuration | str contains $'version_info = ($case.expected).') $'($case.fixture) expected Python ($case.expected):\n($configuration)'
            null
        } catch {|error|
            $'($case.fixture): ($error.msg)'
        }
        finish $root $outcome
    }
}

@test
def test-unavailable-python-is-an-engine-failure-and-never-downloaded [] {
    let root = fixture-repo python-pinned-39
    let outcome = try {
        let result = run-app $root quality-gate-python category typecheck
        assert ($result.exit_code != 0)
        let failure = failed-checks $result | first
        assert equal $failure.category engine
        assert ($failure.message | str contains '3.9') $failure.message
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

# ---------------------------------------------------------------------------
# Node runtime selection (per project) and validation.
# ---------------------------------------------------------------------------

def monorepo-with-node-versions []: nothing -> path {
    let root = mktemp --directory | str trim
    for spec in [{name: a, major: 22} {name: b, major: 24}] {
        let target = $root | path join apps $spec.name
        mkdir $target
        ^cp -a $'($FLAKE | path join tests fixtures corpus ts-clean)/.' $target
        $'($spec.major)(char nl)' | save --force ($target | path join .node-version)
    }
    commit-all $root
    $root
}

@test
def test-node-runtime-is-selected-for-each-project [] {
    let root = monorepo-with-node-versions
    let outcome = try {
        let bin = $root | path join fakebin
        let log = $root | path join node.log
        mkdir $bin
        write-node-runtime $bin 26
        for major in [22 24] {
            write-node-runtime ($root | path join $'node($major)') $major
        }
        write-exit-tool $bin npm 0
        for name in [a b] {
            let project = $root | path join apps $name
            write-project-compiler $project tsc $"echo \"($name):$\(node --version\)\" >> '($log)'"
        }
        let result = run-script $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_NODE_22_BIN: ($root | path join node22)
            QUALITY_GATE_NODE_24_BIN: ($root | path join node24)
        } category typecheck
        assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
        assert equal (open --raw $log | lines | sort) ['a:v22.0.0' 'b:v24.0.0']
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-node-version-mismatch-is-rejected [] {
    let root = fixture-repo ts-clean
    let outcome = try {
        let bin = $root | path join fakebin
        write-node-runtime $bin 22
        write-exit-tool $bin npm 0
        write-project-compiler $root tsc 'exit 0'
        let result = run-script $root {PATH: ($env.PATH | prepend $bin)} category typecheck
        assert ($result.exit_code != 0)
        let failure = failed-checks $result | first
        assert equal $failure.category engine
        assert ($failure.message | str contains 'declares Node.js major 24') $failure.message
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-typecheck-requires-the-project-compiler [] {
    let root = fixture-repo ts-clean
    let outcome = try {
        let bin = $root | path join fakebin
        write-node-runtime $bin 24
        write-exit-tool $bin npm 0
        write-exit-tool $bin npx 0
        let result = run-script $root {PATH: ($env.PATH | prepend $bin)} category typecheck
        assert ($result.exit_code != 0)
        let failure = failed-checks $result | first
        assert equal $failure.category finding
        assert ($failure.message | str contains 'is not installed in the project') $failure.message
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-vue-projects-are-checked-with-vue-tsc-and-others-with-tsc [] {
    let cases = [
        {vue: true, expected: 'vue-tsc', other: 'tsc'}
        {vue: false, expected: 'tsc', other: 'vue-tsc'}
    ]
    for case in $cases {
        let root = fixture-repo ts-clean
        let outcome = try {
            if $case.vue {
                write-file $root src/App.vue "<template><div /></template>\n"
                commit-all $root
            }
            let bin = $root | path join fakebin
            let log = $root | path join compilers.log
            write-node-runtime $bin 24
            write-exit-tool $bin npm 0
            for name in [tsc vue-tsc] {
                write-project-compiler $root $name $"echo '($name)' >> '($log)'"
            }
            let result = run-script $root {PATH: ($env.PATH | prepend $bin)} category typecheck
            assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
            assert equal (open --raw $log | lines | uniq) [$case.expected] $'vue=($case.vue)'
            null
        } catch {|error|
            $error.msg
        }
        finish $root $outcome
    }
}

# ---------------------------------------------------------------------------
# Exit-code contract: which tool exit codes are findings and which are engine
# failures. The corpus proves the real tools; this table proves the boundary.
# ---------------------------------------------------------------------------

def classify [fixture: string, category: string, tools: list<record>, extra: closure]: nothing -> table {
    let root = fixture-repo $fixture
    let outcome = try {
        let bin = $root | path join fakebin
        mkdir $bin
        for tool in $tools {
            write-exit-tool $bin $tool.name $tool.code ($tool.output? | default '')
        }
        do $extra $root $bin
        let result = run-script $root {PATH: ($env.PATH | prepend $bin)} category $category
        $result.checks | select check failed category
    } catch {|error|
        cleanup $root
        error make {msg: $error.msg}
    }
    cleanup $root
    $outcome
}

def category-of [table: table, check: string]: nothing -> string {
    let rows = $table | where check == $check
    if ($rows | is-empty) {
        error make {msg: $'check ($check) did not run: ($table | to nuon)'}
    }
    let row = $rows | first
    if $row.failed { $row.category } else { 'pass' }
}

@test
def test-python-tool-exit-codes-are-classified-by-tool [] {
    let nothing = {|root bin| null }
    let cases = [
        {category: format, tools: [{name: ruff, code: 1}], check: 'format:python:ruff', expected: finding}
        {category: format, tools: [{name: ruff, code: 2}], check: 'format:python:ruff', expected: engine}
        {category: format, tools: [{name: ruff, code: 0}], check: 'format:python:ruff', expected: pass}
        {category: lint, tools: [{name: ruff, code: 1} {name: complexipy, code: 0}], check: 'lint:python:ruff', expected: finding}
        {category: lint, tools: [{name: ruff, code: 2} {name: complexipy, code: 0}], check: 'lint:python:ruff', expected: engine}
        {category: lint, tools: [{name: ruff, code: 0} {name: complexipy, code: 1}], check: 'lint:python:complexipy', expected: finding}
        {category: lint, tools: [{name: ruff, code: 0} {name: complexipy, code: 2}], check: 'lint:python:complexipy', expected: engine}
        {category: strlint, tools: [{name: ast-grep, code: 1}], check: 'lint:python:strlint', expected: finding}
        {category: strlint, tools: [{name: ast-grep, code: 2}], check: 'lint:python:strlint', expected: engine}
    ]
    let failures = $cases | each {|case|
        let table = classify python-clean $case.category $case.tools $nothing
        let actual = category-of $table $case.check
        if $actual != $case.expected {
            $'($case.check) with ($case.tools | to nuon): expected ($case.expected), got ($actual)'
        }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
}

@test
def test-go-tool-exit-codes-are-classified-by-tool [] {
    let nothing = {|root bin| null }
    let cases = [
        {category: lint, tools: [{name: golangci-lint, code: 1} {name: go, code: 0}], check: 'lint:go:golangci', expected: finding}
        {category: lint, tools: [{name: golangci-lint, code: 3} {name: go, code: 0}], check: 'lint:go:golangci', expected: engine}
        {category: lint, tools: [{name: golangci-lint, code: 0} {name: go, code: 1}], check: 'lint:go:vet', expected: finding}
        {category: lint, tools: [{name: golangci-lint, code: 0} {name: go, code: 0}], check: 'lint:go:vet', expected: pass}
        {category: format, tools: [{name: gofumpt, code: 0, output: 'main.go'} {name: goimports, code: 0}], check: 'format:go:gofumpt', expected: finding}
        {category: format, tools: [{name: gofumpt, code: 2} {name: goimports, code: 0}], check: 'format:go:gofumpt', expected: engine}
        {category: format, tools: [{name: gofumpt, code: 0} {name: goimports, code: 2}], check: 'format:go:goimports', expected: engine}
    ]
    let failures = $cases | each {|case|
        let table = classify go-clean $case.category $case.tools $nothing
        let actual = category-of $table $case.check
        if $actual != $case.expected {
            $'($case.check) with ($case.tools | to nuon): expected ($case.expected), got ($actual)'
        }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
}

@test
def test-typescript-tool-exit-codes-are-classified-by-tool [] {
    let prepare = {|root bin|
        write-node-runtime $bin 24
    }
    let with_compiler = {|code|
        {|root bin|
            do $prepare $root $bin
            write-project-compiler $root tsc $'exit ($code)'
        }
    }
    let cases = [
        {category: lint, tools: [{name: oxlint, code: 1, output: 'x no-debugger'}], prepare: $prepare, check: 'lint:typescript:oxlint', expected: finding}
        {category: lint, tools: [{name: oxlint, code: 1, output: 'Failed to parse oxlint configuration file.'}], prepare: $prepare, check: 'lint:typescript:oxlint', expected: engine}
        {category: lint, tools: [{name: oxlint, code: 0}], prepare: $prepare, check: 'lint:typescript:oxlint', expected: pass}
        {category: format, tools: [{name: oxfmt, code: 1, output: 'src/app.ts'}], prepare: $prepare, check: 'format:typescript:oxfmt', expected: finding}
        {category: format, tools: [{name: oxfmt, code: 2}], prepare: $prepare, check: 'format:typescript:oxfmt', expected: engine}
        {category: typecheck, tools: [{name: npm, code: 0}], prepare: (do $with_compiler 1), check: 'typecheck:typescript:tsc', expected: finding}
        {category: typecheck, tools: [{name: npm, code: 0}], prepare: (do $with_compiler 2), check: 'typecheck:typescript:tsc', expected: finding}
        {category: typecheck, tools: [{name: npm, code: 0}], prepare: (do $with_compiler 3), check: 'typecheck:typescript:tsc', expected: engine}
        {category: typecheck, tools: [{name: npm, code: 0}], prepare: (do $with_compiler 0), check: 'typecheck:typescript:tsc', expected: pass}
        {category: typecheck, tools: [{name: npm, code: 1}], prepare: (do $with_compiler 0), check: 'typecheck:typescript:tsc', expected: engine}
    ]
    let failures = $cases | each {|case|
        let table = classify ts-clean $case.category $case.tools $case.prepare
        let actual = category-of $table $case.check
        if $actual != $case.expected {
            $'($case.check) with ($case.tools | to nuon): expected ($case.expected), got ($actual)'
        }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
}

@test
def test-a-failing-test-runner-is-always-a-finding [] {
    let root = fixture-repo go-clean
    let outcome = try {
        write-file $root main_test.go "package main\n"
        let bin = $root | path join fakebin
        write-exit-tool $bin go 2
        let result = run-script $root {PATH: ($env.PATH | prepend $bin)} test
        let failures = failed-checks $result
        assert equal ($failures | get check) [test:go:test]
        assert equal ($failures | first | get category) finding
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

# ---------------------------------------------------------------------------
# Reports must stay valid XML whatever the tools print.
# ---------------------------------------------------------------------------

@test
def test-terminal-escape-sequences-never-reach-the-reports [] {
    let root = fixture-repo python-clean
    let outcome = try {
        let bin = $root | path join fakebin
        let esc = char --integer 27
        let line = $"($esc)]8;;https://example.invalid/T201($esc)\\T201($esc)]8;;($esc)\\ ($esc)[31mprint found($esc)[0m(char --integer 7)(char --integer 1)"
        write-executable ($bin | path join ruff) $"#!/bin/sh\ncat <<'EOF'\n($line)\nEOF\nexit 1\n"
        write-exit-tool $bin complexipy 0
        let result = run-script $root {PATH: ($env.PATH | prepend $bin)} category lint
        let failures = failed-checks $result
        assert equal ($failures | get check) [lint:python:ruff]
        assert equal ($failures | first | get category) finding
        let raw = open --raw $result.junit
        assert not ($raw | str contains (char --integer 27)) 'the JUnit report must not contain ESC'
        assert not ($raw | str contains (char --integer 1)) 'the JUnit report must not contain control characters'
        assert ($raw | str contains 'T201 print found') 'the diagnostic text must survive the sanitizing'
        assert not ($raw | str contains 'example.invalid') 'hyperlink targets (OSC 8) must be removed, not just their ESC bytes'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

# ---------------------------------------------------------------------------
# Nested projects and workspaces
# ---------------------------------------------------------------------------

@test
def test-files-of-a-nested-project-are-checked-once-by-that-project [] {
    let root = fixture-repo python-nested
    let outcome = try {
        let result = run-app $root quality-gate-python category lint
        let projects = $result.checks | get project | uniq | sort
        assert equal $projects ['.' 'services/api'] 'both projects must be discovered'
        let failing = failed-checks $result | where check == 'lint:python:ruff' | get project
        assert equal $failing ['services/api'] $'the violation belongs to the nested project only, not also to the project around it:\n($result.stdout)'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-a-uv-workspace-member-uses-the-lockfile-of-the-workspace-root [] {
    let root = fixture-repo python-workspace
    let outcome = try {
        let result = run-app $root quality-gate-python category typecheck
        assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
        assert equal ($result.checks | get project | uniq | sort) ['.' 'packages/lib']
        assert equal (failed-checks $result | length) 0
        assert (not (($root | path join packages lib .venv) | path exists)) 'the member must not get an environment inside the repository'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-an-npm-workspace-member-uses-the-lockfile-and-node-version-of-the-workspace-root [] {
    let root = fixture-repo ts-workspace
    let outcome = try {
        seed-node-modules $root
        let result = run-app $root quality-gate-typescript category typecheck
        assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
        assert equal ($result.checks | get project | uniq) ['packages/lib']
        assert equal (failed-checks $result | length) 0
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-the-hook-selects-only-the-project-that-owns-a-changed-file [] {
    let root = fixture-repo python-nested
    let outcome = try {
        let result = with-env {QUALITY_GATE_CHANGED_FILES: 'services/api/api.py'} {
            run-app $root quality-gate-python category lint
        }
        assert equal ($result.checks | get project | uniq) ['services/api'] 'a change inside a nested project must not select the project around it'
        null
    } catch {|error|
        $error.msg
    }
    finish $root $outcome
}

@test
def test-the-exclusion-cap-is-exactly-thirty-percent [] {
    let cases = [
        {excluded: 3, accepted: true}
        {excluded: 4, accepted: false}
    ]
    for case in $cases {
        let root = fixture-repo python-clean
        let outcome = try {
            # Ten code files in total, `excluded` of them under gen/.
            for index in 1..$case.excluded { write-file $root $'gen/g($index).py' "value = 1\n" }
            for index in 1..(9 - $case.excluded) { write-file $root $'kept($index).py' "value = 1\n" }
            write-file $root .quality-gate/exclude "gen/\n"
            commit-all $root
            let result = run-app $root quality-gate-detect detect
            if $case.accepted {
                assert equal $result.exit_code 0 $'($case.excluded) of 10 files is 30% and must be accepted:\n($result.stderr)'
            } else {
                assert ($result.exit_code != 0) $'($case.excluded) of 10 files must be refused'
                assert (($result.stdout + $result.stderr) | str contains 'maximum is 30%') $result.stderr
            }
            null
        } catch {|error|
            $error.msg
        }
        finish $root $outcome
    }
}

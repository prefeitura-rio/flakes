use std/testing *
use support/qg.nu *

# Every case is a small repository with exactly one deliberate violation. The
# real app must report that check as a finding, every other check must pass, and
# the repository must be left untouched.

def run-cases [app: string, expected: list<string>, cases: list<record>, --before-typecheck: closure] {
    let failures = $cases | each {|case|
        let root = fixture-repo $case.fixture
        let outcome = try {
            if $before_typecheck != null {
                assert-corpus-case $root $app $expected $case.failing --before-typecheck $before_typecheck
            } else {
                assert-corpus-case $root $app $expected $case.failing
            }
            null
        } catch {|error|
            $'($case.fixture): ($error.msg | str substring 0..700)'
        }
        cleanup $root
        $outcome
    } | compact
    if ($failures | is-not-empty) {
        error make {msg: ($failures | str join "\n\n")}
    }
}

@test
def test-python-corpus-reports-each-violation-as-a-finding [] {
    run-cases quality-gate-python $PYTHON_CHECKS [
        {fixture: python-clean, failing: []}
        {fixture: python-format, failing: [format:python:ruff]}
        {fixture: python-lint, failing: [lint:python:ruff]}
        {fixture: python-complexity, failing: [lint:python:complexipy]}
        {fixture: python-typeerror, failing: [lint:python:basedpyright]}
        {fixture: python-warning, failing: [lint:python:basedpyright]}
        {fixture: python-strlint, failing: [lint:python:strlint]}
    ]
}

@test
def test-go-corpus-reports-each-violation-as-a-finding [] {
    run-cases quality-gate-go $GO_CHECKS [
        {fixture: go-clean, failing: []}
        {fixture: go-gofumpt, failing: [format:go:gofumpt]}
        {fixture: go-imports, failing: [format:go:gofumpt format:go:goimports]}
        {fixture: go-errcheck, failing: [lint:go:golangci]}
        {fixture: go-vet, failing: [lint:go:golangci lint:go:vet]}
        {fixture: go-strlint, failing: [lint:go:strlint]}
        {fixture: go-compile, failing: [lint:go:golangci lint:go:vet typecheck:go:build]}
    ]
}

@test
def test-typescript-corpus-reports-each-violation-as-a-finding [] {
    run-cases quality-gate-typescript $TYPESCRIPT_CHECKS [
        {fixture: ts-clean, failing: []}
        {fixture: ts-format, failing: [format:typescript:oxfmt]}
        {fixture: ts-lint, failing: [lint:typescript:oxlint]}
        {fixture: ts-strlint, failing: [lint:typescript:strlint]}
        {fixture: ts-typeerror, failing: [lint:typescript:typecheck]}
    ] --before-typecheck {|root| seed-node-modules $root }
}

@test
def test-python-exclusions-apply-to-every-tool [] {
    run-cases quality-gate-python $PYTHON_CHECKS [
        {fixture: python-excluded, failing: []}
    ]
}

@test
def test-go-exclusions-apply-to-every-tool [] {
    run-cases quality-gate-go $GO_CHECKS [
        {fixture: go-excluded, failing: []}
    ]
}

@test
def test-typescript-exclusions-apply-to-every-tool [] {
    run-cases quality-gate-typescript $TYPESCRIPT_CHECKS [
        {fixture: ts-excluded, failing: []}
    ] --before-typecheck {|root| seed-node-modules $root }
}

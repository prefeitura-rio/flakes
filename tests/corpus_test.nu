use std/testing *
use support/qg.nu *

# Every case is a small repository with exactly one deliberate violation. The
# real app must report that check as a finding, every other check must pass, and
# the repository must be left untouched.

def run-cases [app: string, expected: list<string>, cases: list<record>, --before-typecheck: closure] {
    let failures = $cases | each {|case|
        let root = fixture-repo $case.fixture
        let outcome = try {
            let messages = $case.messages? | default {}
            if $before_typecheck != null {
                assert-corpus-case $root $app $expected $case.failing --before-typecheck $before_typecheck --messages $messages
            } else {
                assert-corpus-case $root $app $expected $case.failing --messages $messages
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
        {fixture: python-typeerror, failing: [typecheck:python:basedpyright]}
        {fixture: python-warning, failing: [typecheck:python:basedpyright]}
        {fixture: python-strlint, failing: [lint:python:strlint]}
        {fixture: python-complexipy-override, failing: [lint:python:complexipy]}
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
        {fixture: ts-typeerror, failing: [typecheck:typescript:tsc]}
        {fixture: ts-vite-classic, failing: [typecheck:typescript:tsc]}
        {fixture: ts-vite-classic-clean, failing: []}
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

@test
def test-suppression-directives-do-not-lower-the-floor [] {
    run-cases quality-gate-typescript $TYPESCRIPT_CHECKS [
        {
            fixture: ts-suppress
            failing: [lint:typescript:oxlint lint:typescript:strlint]
            messages: {'lint:typescript:oxlint': 'ban-ts-comment', 'lint:typescript:strlint': 'no-blanket-disable'}
        }
    ] --before-typecheck {|root| seed-node-modules $root }
    run-cases quality-gate-python $PYTHON_CHECKS [
        {
            fixture: python-suppress
            failing: [lint:python:ruff lint:python:strlint]
            messages: {'lint:python:ruff': 'PGH004', 'lint:python:strlint': 'no-pyright-directive'}
        }
    ]
    run-cases quality-gate-go $GO_CHECKS [
        {fixture: go-suppress, failing: [lint:go:golangci], messages: {'lint:go:golangci': 'nolintlint'}}
        {fixture: go-generated, failing: [lint:go:golangci], messages: {'lint:go:golangci': 'errcheck'}}
    ]
}

@test
def test-a-local-tsconfig-exclude-does-not-remove-files-from-the-typecheck [] {
    run-cases quality-gate-typescript $TYPESCRIPT_CHECKS [
        {fixture: ts-tsconfig-exclude, failing: [typecheck:typescript:tsc]}
    ] --before-typecheck {|root| seed-node-modules $root }
}

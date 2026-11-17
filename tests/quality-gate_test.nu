use std/assert
use std/testing *

const SCRIPT = path self | path dirname | path join ../devenv/files/quality-gate/quality-gate.nu
const FLAKE = path self | path dirname | path join ..
const QUALITY_GATE_FILES = path self | path dirname | path join ../devenv/files/quality-gate

def write-fixture-file [root: path, relative: string, content: string] {
    let target = $root | path join $relative
    let parent = $target | path dirname
    mkdir $parent
    $content | save --force $target
}

def quality-gate-environment [root: path]: nothing -> record {
    {
        QUALITY_GATE_PROJECT_DIR: $root
        QUALITY_GATE_GO_RULES: ($QUALITY_GATE_FILES | path join go rules)
        QUALITY_GATE_GO_CONFIG: ($QUALITY_GATE_FILES | path join go .golangci.yml)
        QUALITY_GATE_PYTHON_RULES: ($QUALITY_GATE_FILES | path join python rules)
        QUALITY_GATE_PYRIGHT_CONFIG: ($QUALITY_GATE_FILES | path join python pyrightconfig.json)
        QUALITY_GATE_RUFF_CONFIG: ($QUALITY_GATE_FILES | path join python ruff.toml)
        QUALITY_GATE_TYPESCRIPT_CONFIG: ($QUALITY_GATE_FILES | path join typescript tsconfig.quality-gate.json)
        QUALITY_GATE_TYPESCRIPT_RULES: ($QUALITY_GATE_FILES | path join typescript rules)
        QUALITY_GATE_OXLINT_CONFIG: ($QUALITY_GATE_FILES | path join typescript .oxlintrc.json)
        QUALITY_GATE_OXFMT_CONFIG: ($QUALITY_GATE_FILES | path join typescript .oxfmtrc.json)
    }
}

def run-quality-gate [root: path, ...arguments: string] {
    with-env (quality-gate-environment $root) {
        ^nu $SCRIPT ...$arguments | complete
    }
}

def run-quality-gate-with-env [root: path, extra: record, ...arguments: string] {
    let environment = (quality-gate-environment $root) | merge $extra
    with-env $environment {
        ^nu $SCRIPT ...$arguments | complete
    }
}

def run-quality-gate-app [root: path, app: string, ...arguments: string] {
    with-env { QUALITY_GATE_PROJECT_DIR: $root } {
        cd $FLAKE
        ^nix --extra-experimental-features 'nix-command flakes' run $'($FLAKE)#($app)' -- ...$arguments | complete
    }
}

def write-executable [target: path, content: string] {
    let parent = $target | path dirname
    mkdir $parent
    $content | save --force $target
    ^chmod +x $target
}

def write-fake-tool [bin: path, name: string] {
    write-executable ($bin | path join $name) ([
        '#!/usr/bin/env nu'
        'def --wrapped main [...args: string] {'
        '    let log = if ("QUALITY_GATE_FAKE_LOG" in $env) { $env.QUALITY_GATE_FAKE_LOG } else { "" }'
        '    if ($log | is-not-empty) {'
        '        let previous = if ($log | path exists) { open --raw $log } else { "" }'
        '        ($previous + (($args | str join " ") + (char nl))) | save --force $log'
        '    }'
        '    let failure = if ("QUALITY_GATE_FAKE_FAILURE" in $env) { $env.QUALITY_GATE_FAKE_FAILURE } else { "false" }'
        '    if ($failure == "true") {'
        "        print 'diagnostic <bad> & \"quoted\"'"
        '        exit 1'
        '    }'
        '}'
    ] | str join (char nl))
}

def write-ast-grep-config [root: path, language: string]: nothing -> path {
    let rules = $QUALITY_GATE_FILES | path join $language rules
    let config = $root | path join 'sgconfig.yaml'
    let content = if $language == 'typescript' {
        [
            'ruleDirs:'
            $'  - ($rules)'
            'languageGlobs:'
            '  typescript:'
            '    - "*.ts"'
            '    - "*.tsx"'
        ] | str join (char nl)
    } else {
        ['ruleDirs:' $'  - ($rules)'] | str join (char nl)
    }
    ($content + (char nl)) | save --force $config
    $config
}

def run-ast-grep [root: path, config: path] {
    with-env {} {
        cd $root
        ^ast-grep scan --config $config | complete
    }
}

def make-fixture []: nothing -> path {
    mktemp --directory | str trim
}

@test
def test-detects-all-languages [] {
    let root = make-fixture
    try {
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fixture-file $root pyproject.toml "[project]\nname = 'fixture'\nversion = '0.1.0'\n"
        write-fixture-file $root package.json '{"name":"fixture","scripts":{"test":"vitest run"}}'
        write-fixture-file $root tsconfig.json '{}'
        write-fixture-file $root dist/ignored/pyproject.toml "[project]\nname = 'ignored'\n"

        let result = run-quality-gate $root detect
        assert equal $result.exit_code 0
        assert ($result.stderr | str contains 'Detected project .: go, python, typescript')
        assert not ($result.stderr | str contains 'dist/ignored')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-fails-without-local-tests [] {
    let root = make-fixture
    try {
        write-fixture-file $root pyproject.toml "[project]\nname = 'fixture'\nversion = '0.1.0'\n"

        let result = run-quality-gate $root test
        assert ($result.exit_code != 0)
        assert ($result.stdout | str contains 'No local tests were found')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-qg-script-requires-a-category-and-language [] {
    let root = make-fixture
    try {
        write-fixture-file $root pyproject.toml "[project]\nname = 'fixture'\nversion = '0.1.0'\n"
        let result = with-env {
            QUALITY_GATE_PROJECT_DIR: $root
            QUALITY_GATE_SHORTCUT: true
        } {
            ^nu $SCRIPT qg | complete
        }
        assert ($result.exit_code != 0)
        assert ($result.stdout | str contains 'Usage: qg')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-detects-setup-py-and-ignores-nested-projects [] {
    let root = make-fixture
    try {
        ^git -C $root init --quiet
        write-fixture-file $root setup.py "from setuptools import setup\nsetup(name='fixture')\n"
        write-fixture-file $root package.json '{"name":"not-typescript"}'
        write-fixture-file $root nested/package.json '{"name":"nested"}'
        write-fixture-file $root tools/api/pyproject.toml "[project]\nname = 'api'\nversion = '0.1.0'\n"
        write-fixture-file $root dist/ignored/pyproject.toml "[project]\nname = 'ignored'\n"
        write-fixture-file $root tests/ignored/pyproject.toml "[project]\nname = 'ignored'\n"
        write-fixture-file $root .gitignore "dist/\ntests/\n"

        let result = run-quality-gate $root detect
        assert equal $result.exit_code 0
        assert ($result.stderr | str contains 'Detected project .: python')
        assert ($result.stderr | str contains 'Detected project tools/api: python')
        assert not ($result.stderr | str contains 'dist/ignored')
        assert not ($result.stderr | str contains 'tests/ignored')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-changed-files-limit-detection-to-touched-projects [] {
    let root = make-fixture
    try {
        ^git -C $root init --quiet
        write-fixture-file $root apps/api/go.mod "module example.com/api\n\ngo 1.23.0\n"
        write-fixture-file $root apps/web/pyproject.toml "[project]\nname = 'web'\nversion = '0.1.0'\n"
        let detection = $root | path join detection.env
        let result = run-quality-gate-with-env $root {
            QUALITY_GATE_CHANGED_FILES: "apps/api/main.go"
            QUALITY_GATE_DETECTION_FILE: $detection
        } detect
        assert equal $result.exit_code 0
        let values = open --raw $detection
        assert ($values | str contains 'QUALITY_GATE_PROJECT_COUNT=1')
        assert ($values | str contains 'QUALITY_GATE_LANGUAGES=go')
        assert not ($values | str contains 'python')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-hook-skips-when-no-project-is-affected [] {
    let root = make-fixture
    try {
        ^git -C $root init --quiet
        write-fixture-file $root services/api/go.mod "module example.com/api\n\ngo 1.23.0\n"
        write-fixture-file $root tools/gen.py "value = 1\n"
        let result = run-quality-gate-with-env $root {
            QUALITY_GATE_CHANGED_FILES: "tools/gen.py"
        } hook python
        assert equal $result.exit_code 0
        assert ($result.stdout | str contains 'Summary: all 0 checks passed.')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-fix-continues-after-a-nonfixable-ruff-failure [] {
    let root = make-fixture
    try {
        ^git -C $root init --quiet
        let bin = $root | path join bin
        let log = $root | path join commands.log
        write-fixture-file $root services/one/pyproject.toml "[project]\nname = 'one'\nversion = '0.1.0'\n"
        write-fixture-file $root services/two/pyproject.toml "[project]\nname = 'two'\nversion = '0.1.0'\n"
        write-fake-tool $bin ruff
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
            QUALITY_GATE_FAKE_FAILURE: "true"
        } fix python
        assert equal $result.exit_code 0
        assert equal (open --raw $log | lines | length) 4
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-typescript-typecheck-requires-a-lockfile [] {
    let root = make-fixture
    try {
        write-fixture-file $root package.json "{\n  \"name\": \"fixture\",\n  \"private\": true\n}\n"
        write-fixture-file $root tsconfig.json "{\n  \"compilerOptions\": {\n    \"strict\": true\n  }\n}\n"
        write-fixture-file $root .node-version "22\n"
        let result = run-quality-gate $root typecheck typescript
        assert ($result.exit_code != 0)
        assert (($result.stdout + $result.stderr) | str contains 'No lockfile found')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-pnpm-typecheck-requires-a-versioned-package-manager [] {
    let root = make-fixture
    try {
        write-fixture-file $root package.json '{"name":"fixture","private":true}'
        write-fixture-file $root pnpm-lock.yaml "lockfileVersion: 9.0\n"
        write-fixture-file $root tsconfig.json '{"compilerOptions":{"strict":true}}'
        write-fixture-file $root .node-version "22\n"
        let result = run-quality-gate $root typecheck typescript
        assert ($result.exit_code != 0)
        assert (($result.stdout + $result.stderr) | str contains 'requires package.json packageManager')

        let bin = $root | path join bin
        let log = $root | path join commands.log
        write-fixture-file $root package.json "{\n  \"name\": \"fixture\",\n  \"private\": true,\n  \"packageManager\": \"pnpm@9.1.0\"\n}\n"
        write-fake-tool $bin pnpm
        write-executable ($bin | path join tsc) "#!/usr/bin/env nu\nprint '{\"compilerOptions\":{},\"files\":[]}'\n"
        let valid = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
        } typecheck typescript
        assert equal $valid.exit_code 0
        assert ((open --raw $log) | str contains 'install --frozen-lockfile')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-format-category-writes-summary-and-junit [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        let log = $root | path join commands.log
        let summary = $root | path join summary.md
        let junit = $root | path join junit.xml
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fake-tool $bin gofumpt
        write-fake-tool $bin goimports
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
            QUALITY_GATE_SUMMARY_FILE: $summary
            QUALITY_GATE_JUNIT_FILE: $junit
            QUALITY_GATE_REVISION: "fixture-revision"
        } category format
        assert equal $result.exit_code 0
        let summary_content = open --raw $summary
        let junit_content = open --raw $junit
        assert ($summary_content | str contains 'Revision: `fixture-revision`')
        assert ($summary_content | str contains '`format:go:gofumpt`')
        assert ($junit_content | str contains 'tests="2" failures="0"')
        assert (($log | path exists))
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-failing-check-escapes-junit-diagnostics [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        let junit = $root | path join junit.xml
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fake-tool $bin golangci-lint
        write-fake-tool $bin go
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_FAILURE: "true"
            QUALITY_GATE_JUNIT_FILE: $junit
        } category lint
        assert ($result.exit_code != 0)
        let junit_content = open --raw $junit
        assert ($junit_content | str contains 'failures="2"')
        assert ($junit_content | str contains 'message="')
        assert ($junit_content | str contains '<![CDATA[')
        assert ($junit_content | str contains 'diagnostic <bad> & "quoted"')
        assert not ($junit_content | str contains '<![CDATA[golangci-lint failed with exit code 1\n\nDiagnostics:\ndiagnostic &lt;bad&gt;')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-typecheck-failure-suggests-go-build [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        let summary = $root | path join summary.md
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fake-tool $bin go
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_FAILURE: "true"
            QUALITY_GATE_SUMMARY_FILE: $summary
        } category typecheck
        assert ($result.exit_code != 0)
        assert ((open --raw $summary) | str contains 'How to fix it:')
        assert ((open --raw $summary) | str contains 'go build ./...')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-local-go-config-is-warned-and-central-config-is-used [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        let log = $root | path join commands.log
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fixture-file $root .golangci.yml "linters:\n  disable-all: true\n"
        write-fake-tool $bin golangci-lint
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
        } lint go golangci
        assert equal $result.exit_code 0
        assert ($result.stderr | str contains 'Ignoring local quality configuration')
        assert ((open --raw $log) | str contains $'--config (($QUALITY_GATE_FILES | path join go .golangci.yml))')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-local-ast-grep-rules-are-run-after-central-rules [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        let log = $root | path join commands.log
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fixture-file $root sgconfig.yaml "ruleDirs:\n  - rules\n"
        write-fixture-file $root .quality-gate/sgconfig.yaml "ruleDirs:\n  - rules\n"
        write-fake-tool $bin ast-grep
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
        } lint go strlint
        assert equal $result.exit_code 0
        let commands = open --raw $log | lines
        assert equal ($commands | length) 2
        assert equal ($commands | get 1) 'scan --config .quality-gate/sgconfig.yaml'
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-central-ast-grep-rules-reject-invalid-code [] {
    let cases = [
        {
            language: go
            file: main.go
            valid: "package main\n\nimport \"fmt\"\n\nfunc main() { _ = fmt.Errorf(\"failed: %w\", err) }\n"
            invalid: "package main\n\nimport (\n  \"fmt\"\n  \"net/http\"\n)\n\nfunc main() {\n  panic(\"bad\")\n  _, _ = http.Get(\"https://example.com\")\n  _ = fmt.Errorf(\"failed: %v\", err)\n}\n"
            rules: [no-panic no-http-default-client]
        }
        {
            language: python
            file: app.py
            valid: "import ast\nimport logging\n\nlogger = logging.getLogger(__name__)\nvalue = ast.literal_eval(source)\nlogger.info(\"value=%s\", value)\n"
            invalid: "def parse(source):\n    print(eval(source))\n    try:\n        return source\n    except:\n        return None\n"
            rules: [no-eval]
        }
        {
            language: typescript
            file: app.ts
            valid: "const value = input as string;\nconst other = input as unknown;\n"
            invalid: "const value = input as any;\nconsole.log(value);\n"
            rules: [no-any-assertion no-console]
        }
    ]

    for case in $cases {
        let root = make-fixture
        try {
            write-fixture-file $root $case.file $case.valid
            let config = write-ast-grep-config $root $case.language
            let valid = run-ast-grep $root $config
            assert equal $valid.exit_code 0

            write-fixture-file $root $case.file $case.invalid
            let invalid = run-ast-grep $root $config
            assert ($invalid.exit_code != 0)
            for rule in $case.rules {
                assert (($invalid.stdout + $invalid.stderr) | str contains $'error[($rule)]')
            }
        } catch {|error|
            rm --recursive --force $root
            error make {msg: $error.msg}
        }
        rm --recursive --force $root
    }
}

@test
def test-quality-gate-app-runs-the-embedded-script [] {
    let root = make-fixture
    try {
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        let result = with-env { QUALITY_GATE_PROJECT_DIR: $root } {
            cd $FLAKE
            ^nix --extra-experimental-features 'nix-command flakes' run $'($FLAKE)#quality-gate' -- detect | complete
        }
        assert equal $result.exit_code 0
        assert ($result.stderr | str contains 'Detected project .: go')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-go-app-runs-real-static-checks [] {
    let root = make-fixture
    try {
        write-fixture-file $root go.mod "module example.com/fixture\n\ngo 1.23.0\n"
        write-fixture-file $root main.go "package main\n\nfunc main() {}\n"
        let passing = run-quality-gate-app $root quality-gate-go ci
        assert equal $passing.exit_code 0
        assert ($passing.stdout | str contains 'Summary: all')
        let files = glob ($root | path join '*') | each {|file| $file | path basename }
        assert ($files | all {|file| $file in ['go.mod' 'main.go'] })

        write-fixture-file $root main.go "package main\n\nfunc main() { panic(\"forbidden\") }\n"
        let failing = run-quality-gate-app $root quality-gate-go ci
        assert ($failing.exit_code != 0)
        assert (($failing.stdout + $failing.stderr) | str contains 'no-panic')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-python-app-runs-real-lint-checks [] {
    let root = make-fixture
    try {
        write-fixture-file $root pyproject.toml "[project]\nname = 'fixture'\nversion = '0.1.0'\nrequires-python = '>=3.13'\ndependencies = []\n"
        write-fixture-file $root app.py "def add(left: int, right: int) -> int:\n    return left + right\n"
        let lock = with-env {} {
            cd $root
            ^uv lock | complete
        }
        assert equal $lock.exit_code 0
        let result = run-quality-gate-app $root quality-gate-python category lint
        assert equal $result.exit_code 0
        assert ($result.stdout | str contains 'Summary: all')

        let bin = $root | path join bin
        let log = $root | path join commands.log
        write-fake-tool $bin basedpyright
        let basedpyright = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
            QUALITY_GATE_FAKE_LOG: $log
        } lint python basedpyright
        assert equal $basedpyright.exit_code 0
        let command = open --raw $log
        assert ($command | str contains $'--venvpath ($root)')
        assert ($command | str contains $'--pythonpath (($root | path join .venv bin python))')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-typescript-app-runs-real-format-and-lint-checks [] {
    let root = make-fixture
    try {
        write-fixture-file $root package.json "{\n  \"name\": \"fixture\",\n  \"private\": true\n}\n"
        write-fixture-file $root tsconfig.json "{\n  \"compilerOptions\": {\n    \"strict\": true\n  }\n}\n"
        write-fixture-file $root src/app.ts "export const add = (left: number, right: number): number => left + right;\n"
        let formatting = run-quality-gate-app $root quality-gate-typescript category format
        assert equal $formatting.exit_code 0
        let linting = run-quality-gate-app $root quality-gate-typescript category lint
        assert equal $linting.exit_code 0
        assert ($linting.stdout | str contains 'Summary: all')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-react-project-uses-oxlint-react-and-a11y-rules [] {
    let root = make-fixture
    try {
        write-fixture-file $root package.json '{"name":"fixture","private":true,"dependencies":{"react":"19.0.0"}}'
        write-fixture-file $root tsconfig.json '{"compilerOptions":{"strict":true}}'
        write-fixture-file $root src/app.tsx "import { useState } from 'react';\n\nexport function Bad({ condition }: { condition: boolean }) {\n    if (condition) {\n        const [value] = useState(0);\n        return <div>{value}</div>;\n    }\n    return <img src='avatar.png' />;\n}\n"
        let result = run-quality-gate-app $root quality-gate-typescript category lint
        assert ($result.exit_code != 0)
        let output = $result.stdout + $result.stderr
        assert ($output | str contains 'react-hooks(rules-of-hooks)')
        assert ($output | str contains 'jsx-a11y(alt-text)')
        assert not ($output | str contains 'react-doctor')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test-typescript-solution-references-preserve-project-options [] {
    let root = make-fixture
    try {
        let bin = $root | path join bin
        write-fixture-file $root package.json "{\n  \"name\": \"fixture\",\n  \"private\": true\n}\n"
        write-fixture-file $root package-lock.json "{\n  \"name\": \"fixture\",\n  \"version\": \"1.0.0\",\n  \"lockfileVersion\": 3,\n  \"requires\": true,\n  \"packages\": {\n    \"\": {\n      \"name\": \"fixture\",\n      \"version\": \"1.0.0\"\n    }\n  }\n}\n"
        write-fixture-file $root .node-version "22\n"
        write-fixture-file $root tsconfig.json "{\n  \"files\": [],\n  \"references\": [{\"path\": \"./tsconfig.app.json\"}]\n}\n"
        write-fixture-file $root tsconfig.app.json "{\n  \"compilerOptions\": {\n    \"jsx\": \"react-jsx\",\n    \"target\": \"ES2022\",\n    \"module\": \"ESNext\"\n  },\n  \"include\": [\"src\"]\n}\n"
        write-fixture-file $root src/main.tsx "export const value = <div />;\n"
        write-executable ($bin | path join tsc) ([
            '#!/usr/bin/env nu'
            'def --wrapped main [...args: string] {'
            '    let index = ($args | enumerate | where item == "--project" | get index | first)'
            '    let project = $args | get ($index + 1)'
            '    if ($project | str ends-with "tsconfig.app.json") {'
            "        print '{\"compilerOptions\":{\"jsx\":\"react-jsx\",\"target\":\"es2022\",\"module\":\"esnext\"},\"files\":[\"./src/main.tsx\"]}'"
            '    } else {'
            "        print '{\"compilerOptions\":{},\"references\":[{\"path\":\"./tsconfig.app.json\"}]}'"
            '    }'
            '}'
        ] | str join (char nl))
        write-executable ($bin | path join npm) ([
            '#!/usr/bin/env nu'
            'def --wrapped main [...args: string] {'
            '    let joined = $args | str join " "'
            '    if ($joined | str contains "--noEmit") {'
            '        let index = ($args | enumerate | where item == "--project" | get index | first)'
            '        let config = open ($args | get ($index + 1))'
            '        if ($config.compilerOptions.jsx? | default null) != "react-jsx" {'
            '            print "solution compiler options were not preserved"'
            '            exit 1'
            '        }'
            '    }'
            '}'
        ] | str join (char nl))
        let result = run-quality-gate-with-env $root {
            PATH: ($env.PATH | prepend $bin)
        } typecheck typescript
        assert equal $result.exit_code 0
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

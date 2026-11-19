export const FLAKE = path self | path dirname | path join .. ..

use isolation.nu

export const PYTHON_CHECKS = [
    format:python:ruff
    lint:python:ruff
    lint:python:complexipy
    lint:python:strlint
    typecheck:python:basedpyright
]

export const GO_CHECKS = [
    format:go:gofumpt
    format:go:goimports
    lint:go:golangci
    lint:go:vet
    lint:go:strlint
    typecheck:go:build
]

export const TYPESCRIPT_CHECKS = [
    format:typescript:oxfmt
    lint:typescript:oxlint
    lint:typescript:strlint
    typecheck:typescript:tsc
]

export def fixture-repo [name: string]: nothing -> path {
    let root = mktemp --directory | str trim
    let source = $FLAKE | path join tests fixtures corpus $name
    ^cp -a $'($source)/.' $root
    commit-all $root
    $root
}

export def commit-all [root: path] {
    if not (($root | path join .git) | path exists) {
        ^git -C $root init --quiet
    }
    ^git -C $root add --all
    ^git -C $root -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture
}

export def write-file [root: path, relative: string, content: string] {
    let target = $root | path join $relative
    mkdir ($target | path dirname)
    $content | save --force $target
}

export def cleanup [root: path] {
    rm --recursive --force $root
    rm --recursive --force $'($root)-reports'
    rm --recursive --force $'($root)-cache'
}

export def seed-node-modules [root: path] {
    let bin = $root | path join node_modules .bin
    mkdir $bin
    "#!/bin/sh\nexec tsc \"$@\"\n" | save --force ($bin | path join tsc)
    ^chmod +x ($bin | path join tsc)
    let lockfile = if ($root | path join pnpm-lock.yaml | path exists) { 'pnpm-lock.yaml' } else { 'package-lock.json' }
    let fingerprint = [
        (open --raw ($root | path join package.json))
        (open --raw ($root | path join $lockfile))
        (open --raw ($root | path join .node-version))
    ] | str join (char nul) | hash sha256 | str trim
    $fingerprint | save --force ($root | path join node_modules .quality-gate-dependencies)
}

export def junit-checks [file: path]: nothing -> table {
    if not ($file | path exists) {
        return []
    }
    let raw = open --raw $file
    let document = try {
        $raw | from xml
    } catch {|error|
        error make {msg: $'invalid JUnit XML in ($file): ($error.msg)\n($raw | str substring 0..1500)'}
    }
    $document.content
    | where tag == testsuite
    | each {|suite| $suite.content | where tag == testcase }
    | flatten
    | each {|case|
        let failures = $case.content? | default [] | where tag == failure
        let name = $case.attributes.name
        let message = if ($failures | is-empty) { '' } else { $failures | first | get attributes.message? | default '' }
        let category = if ($failures | is-empty) {
            'none'
        } else if ($message | str starts-with 'Category: finding') {
            'finding'
        } else if ($message | str starts-with 'Category: engine') {
            'engine'
        } else {
            'unknown'
        }
        {
            project: (if ($name | str contains ' / ') { $name | split row ' / ' | first } else { '.' })
            check: (if ($name | str contains ' / ') { $name | split row ' / ' | last } else { $name })
            failed: ($failures | is-not-empty)
            category: $category
            message: $message
        }
    }
}

export def run-app [root: path, app: string, ...arguments: string]: nothing -> record {
    let reports = $'($root)-reports'
    mkdir $reports
    let junit = $reports | path join $'junit-(random uuid).xml'
    let result = with-env {
        QUALITY_GATE_PROJECT_DIR: $root
        QUALITY_GATE_JUNIT_FILE: $junit
        QUALITY_GATE_SUMMARY_FILE: ($reports | path join summary.md)
        CI: ''
        QUALITY_GATE_CI: ''
        QUALITY_GATE_MODE: ''
        QUALITY_GATE_REPORT_UNTIL: ''
        GOLANGCI_LINT_CACHE: $'($root)-cache/golangci'
        XDG_CACHE_HOME: $'($root)-cache/xdg'
    } {
        cd $FLAKE
        ^nix --extra-experimental-features 'nix-command flakes' run $'($FLAKE)#($app)' -- ...$arguments | complete
    }
    $result | insert checks (junit-checks $junit) | insert junit $junit
}

export def tree-status [root: path]: nothing -> string {
    ^git -C $root status --porcelain | str trim
}

# Runs the four static categories through the published app and compares the
# outcome of every check with the expectation.
export def assert-corpus-case [
    root: path
    app: string
    expected_checks: list<string>
    expected_failures: list<string>
    --before-typecheck: closure
    --messages: record = {}
] {
    mut checks = []
    for category in [format lint strlint typecheck] {
        if $category == typecheck and $before_typecheck != null {
            do $before_typecheck $root
        }
        let result = run-app $root $app category $category
        if ($result.checks | is-empty) {
            error make {msg: $'category ($category) produced no JUnit checks:\n($result.stdout)\n($result.stderr)'}
        }
        # The exit code is the contract CI relies on: a category that reports a
        # failed check must fail, and one that reports none must not.
        let reported_failure = $result.checks | where failed | is-not-empty
        if $reported_failure and $result.exit_code != 1 {
            error make {msg: $'category ($category) reports failed checks but exited with ($result.exit_code), expected 1'}
        }
        if (not $reported_failure) and $result.exit_code != 0 {
            error make {msg: $'category ($category) reports no failed check but exited with ($result.exit_code):\n($result.stdout)\n($result.stderr)'}
        }
        $checks = ($checks | append $result.checks)
    }
    let ran = $checks | get check | sort
    if $ran != ($expected_checks | sort) {
        error make {msg: $'unexpected set of checks: ($ran | to nuon), expected ($expected_checks | sort | to nuon)'}
    }
    let failed = $checks | where failed | get check | sort
    if $failed != ($expected_failures | sort) {
        let details = $checks | where failed | select check category message | to nuon
        error make {msg: $'failing checks: ($failed | to nuon), expected ($expected_failures | sort | to nuon). Details: ($details)'}
    }
    let reported = $checks
    let wrong_rule = $messages | items {|check, expected|
        let found = $reported | where check == $check | where failed
        if ($found | is-empty) or not (($found | first | get message) | str contains $expected) {
            $'($check) must fail with ($expected), got: (($found | get --optional 0.message | default "no failure" | str substring 0..300))'
        }
    } | compact
    if ($wrong_rule | is-not-empty) {
        error make {msg: ($wrong_rule | str join "\n")}
    }
    let not_findings = $checks | where failed | where category != finding
    if ($not_findings | is-not-empty) {
        error make {msg: $'failures must be findings, got: ($not_findings | select check category | to nuon)'}
    }
    let status = tree-status $root
    if ($status | is-not-empty) {
        error make {msg: $'checks must not change the repository, but git status reports:\n($status)'}
    }
}

export def write-executable [target: path, content: string] {
    mkdir ($target | path dirname)
    (test-shell-script $content) | save --force $target
    ^chmod +x $target
}

# Scripts written for `/bin/sh` run under the pinned dash when the development
# shell provides one, whatever `/bin/sh` is on this machine.
export def test-shell-script [content: string]: nothing -> string {
    let shell = $env.QUALITY_GATE_TEST_SH? | default ''
    if ($shell | is-empty) or not ($content | str starts-with '#!/bin/sh') {
        $content
    } else {
        $content | str replace '#!/bin/sh' $'#!($shell)'
    }
}

# A stand-in for an external tool that prints `output` and exits with `code`.
export def write-exit-tool [bin: path, name: string, code: int, output: string = ''] {
    let escaped = $output | str replace --all "'" "'\\''"
    write-executable ($bin | path join $name) $"#!/bin/sh\nprintf '%s\\n' '($escaped)'\nexit ($code)\n"
}

export def write-node-runtime [bin: path, major: int, log: path = ''] {
    let logging = if ($log | is-empty) { '' } else { $'echo "node ($major)" >> "($log)"' }
    write-executable ($bin | path join node) $"#!/bin/sh\n($logging)\nprintf 'v($major).0.0\\n'\n"
}

export def run-script [root: path, extra: record, ...arguments: string]: nothing -> record {
    let files = $FLAKE | path join devenv files quality-gate
    let environment = {
        QUALITY_GATE_PROJECT_DIR: $root
        QUALITY_GATE_GO_RULES: ($files | path join go rules)
        QUALITY_GATE_GO_CONFIG: ($files | path join go .golangci.yml)
        QUALITY_GATE_PYTHON_RULES: ($files | path join python rules)
        QUALITY_GATE_PYRIGHT_CONFIG: ($files | path join python pyrightconfig.json)
        QUALITY_GATE_RUFF_CONFIG: ($files | path join python ruff.toml)
        QUALITY_GATE_TYPESCRIPT_CONFIG: ($files | path join typescript tsconfig.quality-gate.json)
        QUALITY_GATE_TYPESCRIPT_RULES: ($files | path join typescript rules)
        QUALITY_GATE_OXLINT_CONFIG: ($files | path join typescript .oxlintrc.json)
        QUALITY_GATE_OXFMT_CONFIG: ($files | path join typescript .oxfmtrc.json)
        QUALITY_GATE_REPORT_POLICY: ($files | path join policy report-only.yaml)
        QUALITY_GATE_JUNIT_FILE: ($'($root)-reports' | path join $'junit-(random uuid).xml')
        CI: ''
        QUALITY_GATE_CI: ''
        QUALITY_GATE_MODE: ''
        GOLANGCI_LINT_CACHE: $'($root)-cache/golangci'
        XDG_CACHE_HOME: $'($root)-cache/xdg'
    } | merge $extra
    mkdir $'($root)-reports'
    let result = with-env $environment {
        ^nu ($files | path join quality-gate.nu) ...$arguments | complete
    }
    $result | insert checks (junit-checks ($environment.QUALITY_GATE_JUNIT_FILE)) | insert junit $environment.QUALITY_GATE_JUNIT_FILE
}

# A stand-in for the compiler the project is checked with
# (`node_modules/.bin/<name>`). `--showConfig` prints the JSON of a config, which
# lives in a file the script only cats, so the result does not depend on how the
# shell treats escapes. Any other call runs `on_check`.
export def write-project-compiler [
    project: path
    name: string
    on_check: string = ''
    --files: list<string> = ['./src/app.ts']
    --show-config: record = {}
] {
    let bin = $project | path join node_modules .bin
    let document = $bin | path join $'($name)-config.json'
    mkdir $bin
    {compilerOptions: {}, files: $files} | merge $show_config | to json --raw | save --force $document
    write-executable ($bin | path join $name) $"#!/bin/sh\nif [ \"$1\" = \"--showConfig\" ]; then cat '($document)'; exit 0; fi\n($on_check)\n"
}

# The Python environment the Quality Gate keeps for a project lives in the run's
# own cache, not in the repository.
export def quality-gate-venvs [root: path]: nothing -> list<path> {
    glob $'($root)-cache/xdg/quality-gate/venvs/*'
}

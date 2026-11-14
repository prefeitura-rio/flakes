use std/assert

const SCRIPT = path self | path dirname | path join ../devenv/files/quality-gate/quality-gate.nu

def write-fixture-file [root: path, relative: string, content: string] {
    let target = $root | path join $relative
    let parent = $target | path dirname
    mkdir $parent
    $content | save --force $target
}

def run-quality-gate [root: path, ...arguments: string] {
    with-env { QUALITY_GATE_PROJECT_DIR: $root } {
        ^nu $SCRIPT ...$arguments | complete
    }
}

def make-fixture []: nothing -> path {
    mktemp --directory | str trim
}

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

def test-qg-script-rejects-tool-aliases [] {
    let root = make-fixture
    try {
        write-fixture-file $root pyproject.toml "[project]\nname = 'fixture'\nversion = '0.1.0'\n"
        let result = with-env {
            QUALITY_GATE_PROJECT_DIR: $root
            QUALITY_GATE_SHORTCUT: true
        } {
            ^nu $SCRIPT lint python ruff | complete
        }
        assert ($result.exit_code != 0)
        assert ($result.stdout | str contains 'Usage: qg')
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

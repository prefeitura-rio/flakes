use std/assert
use std/testing *
use support/qg.nu *

# The bootstrap runner is what every developer hook executes before the Quality
# Gate app. These tests build the real script and drive it against a local Git
# remote and a stand-in `nix`.

def build-runner []: nothing -> path {
    let expression = $"let flake = builtins.getFlake \"path:($FLAKE)\"; pkgs = import flake.inputs.nixpkgs-quality-gate { system = builtins.currentSystem; }; in import ($FLAKE)/devenv/files/quality-gate/runner.nix { inherit pkgs; }"
    let result = ^nix --extra-experimental-features 'nix-command flakes' build --impure --no-link --print-out-paths --expr $expression | complete
    if $result.exit_code != 0 {
        error make {msg: $'could not build the runner: ($result.stderr)'}
    }
    $result.stdout | lines | last | str trim
}

# A consumer repository plus a bare "flakes" remote that carries the tags.
def bootstrap-fixture []: nothing -> record {
    let root = mktemp --directory | str trim
    let remote = $root | path join remote.git
    let seed = $root | path join seed
    let consumer = $root | path join consumer
    ^git init --quiet --bare $remote
    ^git init --quiet $seed
    'one' | save --force ($seed | path join file.txt)
    ^git -C $seed add --all
    ^git -C $seed -c user.name=t -c user.email=t@example.invalid commit --quiet -m one
    ^git -C $seed tag --annotate quality-gate-v1.0.0 --message release
    ^git -C $seed tag --annotate quality-gate-latest --message latest
    ^git -C $seed push --quiet $remote --tags
    ^git init --quiet $consumer
    let bin = $root | path join bin
    mkdir $bin
    {
        root: $root
        remote: $remote
        consumer: $consumer
        bin: $bin
        sha: (^git -C $seed rev-parse 'HEAD' | str trim)
        log: ($root | path join nix.log)
    }
}

def fake-nix [fixture: record] {
    write-executable ($fixture.bin | path join nix) $"#!/bin/sh\necho \"$*\" >> '($fixture.log)'\necho \"revision=$QUALITY_GATE_REVISION\" >> '($fixture.log)'\n"
}

def run-runner [runner: path, fixture: record, extra: record, ...arguments: string]: nothing -> record {
    with-env ({
        PATH: ($env.PATH | prepend $fixture.bin)
        QUALITY_GATE_REPO_URL: $fixture.remote
        QUALITY_GATE_RESOLVED_SHA: ''
        QUALITY_GATE_REF: ''
        QUALITY_GATE_RUN_REF: ''
        CI: ''
        QUALITY_GATE_CI: ''
    } | merge $extra) {
        cd $fixture.consumer
        ^$runner ...$arguments | complete
    }
}

def write-cache [fixture: record, sha: string, age_days: int, ref: string] {
    let timestamp = (date now | into int) / 1_000_000_000 | into int
    let written = $timestamp - ($age_days * 86400)
    $"($sha)(char nl)($written)(char nl)($ref)(char nl)" | save --force ($fixture.consumer | path join .git quality-gate-resolved)
}

@test
def test-runner-resolves-the-floating-tag-to-a-sha-and-caches-it [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        let result = run-runner $runner $fixture {} resolve
        assert equal $result.exit_code 0 $result.stderr
        assert equal ($result.stdout | str trim) $fixture.sha
        let cache = open --raw ($fixture.consumer | path join .git quality-gate-resolved) | lines
        assert equal ($cache | first) $fixture.sha
        assert equal ($cache | last) 'quality-gate-latest'
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-uses-a-recent-cache-when-offline-and-warns [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        write-cache $fixture 'cafebabecafebabecafebabecafebabecafebabe' 13 'quality-gate-latest'
        let result = run-runner $runner $fixture {QUALITY_GATE_REPO_URL: '/nonexistent/remote.git'} resolve
        assert equal $result.exit_code 0 $result.stderr
        assert equal ($result.stdout | str trim) 'cafebabecafebabecafebabecafebabecafebabe'
        assert ($result.stderr | str contains 'offline') $result.stderr
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-blocks-after-fourteen-days-offline [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        write-cache $fixture 'cafebabecafebabecafebabecafebabecafebabe' 15 'quality-gate-latest'
        let result = run-runner $runner $fixture {QUALITY_GATE_REPO_URL: '/nonexistent/remote.git'} resolve
        assert equal $result.exit_code 3
        assert ($result.stderr | str contains 'older than 14 days') $result.stderr
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-refuses-a-cache-that-belongs-to-another-reference [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        write-cache $fixture 'cafebabecafebabecafebabecafebabecafebabe' 1 'quality-gate-next'
        let result = run-runner $runner $fixture {QUALITY_GATE_REPO_URL: '/nonexistent/remote.git'} resolve
        assert equal $result.exit_code 3
        assert ($result.stderr | str contains 'belongs to quality-gate-next') $result.stderr
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-fails_when_offline_without_any_cache [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        let result = run-runner $runner $fixture {QUALITY_GATE_REPO_URL: '/nonexistent/remote.git'} resolve
        assert equal $result.exit_code 3
        assert ($result.stderr | str contains 'no cached revision') $result.stderr
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-dispatches-each-command-to-the-matching-app [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        fake-nix $fixture
        let cases = [
            {arguments: [hook python], app: quality-gate-python}
            {arguments: [hook py], app: quality-gate-python}
            {arguments: [hook go], app: quality-gate-go}
            {arguments: [fix typescript], app: quality-gate-typescript}
            {arguments: [fix ts], app: quality-gate-typescript}
            {arguments: [lint go], app: quality-gate-go}
            {arguments: [format python ruff], app: quality-gate-python}
            {arguments: [category lint], app: quality-gate}
            {arguments: [detect], app: quality-gate}
        ]
        let failures = $cases | each {|case|
            '' | save --force $fixture.log
            let result = run-runner $runner $fixture {QUALITY_GATE_RESOLVED_SHA: $fixture.sha} ...$case.arguments
            let log = open --raw $fixture.log
            let expected = $'github:prefeitura-rio/flakes/($fixture.sha)#($case.app) --'
            if $result.exit_code != 0 {
                $'($case.arguments | str join " "): exit ($result.exit_code): ($result.stderr)'
            } else if not ($log | str contains $expected) {
                $'($case.arguments | str join " "): expected ($expected) in ($log | str trim)'
            } else if not ($log | str contains $'revision=($fixture.sha)') {
                $'($case.arguments | str join " "): the app must receive QUALITY_GATE_REVISION'
            }
        } | compact
        assert ($failures | is-empty) ($failures | str join "\n")
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test-runner-rejects-a-local-run-reference-in-ci [] {
    let runner = build-runner
    let fixture = bootstrap-fixture
    let outcome = try {
        fake-nix $fixture
        let local = run-runner $runner $fixture {QUALITY_GATE_RUN_REF: 'path:/work/flakes'} hook python
        assert equal $local.exit_code 0 $local.stderr
        assert ((open --raw $fixture.log) | str contains 'path:/work/flakes#quality-gate-python')
        let ci = run-runner $runner $fixture {QUALITY_GATE_RUN_REF: 'path:/work/flakes', CI: 'true'} hook python
        assert equal $ci.exit_code 3
        assert ($ci.stderr | str contains 'not allowed in CI') $ci.stderr
        null
    } catch {|error|
        $error.msg
    }
    cleanup $fixture.root
    if $outcome != null { error make {msg: $outcome} }
}

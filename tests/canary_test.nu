use std/assert
use std/testing *

source ../release/promote.nu

const PROMOTE_SCRIPT = path self | path dirname | path join ../release/promote.nu
const MOVE_TAG_SCRIPT = path self | path dirname | path join ../release/scripts/move-floating-tag.sh

@test
def test_canary_requires_bake_time [] {
    let created = (date now) - 1day
    let result = (decide 'quality-gate-v1.0.0' '' $created (date now) 3)
    assert equal $result.decision reject
}

@test
def test_canary_promotes_after_bake_time [] {
    let created = (date now) - 3day
    let result = (decide 'quality-gate-v1.0.0' '' $created (date now) 3)
    assert equal $result.decision promote
}

@test
def test_canary_is_idempotent [] {
    let result = (decide 'quality-gate-v1.0.0' 'quality-gate-v1.0.0' ((date now) - 10day) (date now) 3)
    assert equal $result.decision noop
}

@test
def test_canary_force_allows_rollback [] {
    let result = (decide 'quality-gate-v0.9.0' 'quality-gate-v1.0.0' (date now) (date now) 3 true)
    assert equal $result.decision promote
}

@test
def test_canary_force_rejects_forward_promotion [] {
    let result = (decide 'quality-gate-v1.1.0' 'quality-gate-v1.0.0' (date now) (date now) 3 true)
    assert equal $result.decision reject
}

@test
def test_canary_force_requires_existing_stable_channel [] {
    let result = (decide 'quality-gate-v1.0.0' '' (date now) (date now) 3 true)
    assert equal $result.decision reject
}

@test
def test_canary_rejects_future_tags [] {
    let result = (decide 'quality-gate-v1.0.0' '' ((date now) + 1day) (date now) 3)
    assert equal $result.decision reject
    assert ($result.reason | str contains 'future') $result.reason
}

@test
def test_canary_bake_boundary_is_exact [] {
    let now = date now
    let almost = (decide 'quality-gate-v1.0.0' '' ($now - 3day + 1min) $now 3)
    assert equal $almost.decision reject
    assert ($almost.reason | str contains 'bake time') $almost.reason
    let complete = (decide 'quality-gate-v1.0.0' '' ($now - 3day) $now 3)
    assert equal $complete.decision promote
}

@test
def test_canary_versions_are_compared_numerically [] {
    let now = date now
    let cases = [
        {candidate: 'quality-gate-v1.9.0', current: 'quality-gate-v1.10.0', expected: promote}
        {candidate: 'quality-gate-v1.10.0', current: 'quality-gate-v1.9.0', expected: reject}
        {candidate: 'quality-gate-v1.2.0', current: 'quality-gate-v1.3.0', expected: promote}
        {candidate: 'quality-gate-v1.3.0', current: 'quality-gate-v1.2.0', expected: reject}
        {candidate: 'quality-gate-v1.0.9', current: 'quality-gate-v1.0.10', expected: promote}
        {candidate: 'quality-gate-v1.99.99', current: 'quality-gate-v2.0.0', expected: promote}
        {candidate: 'quality-gate-v2.0.0', current: 'quality-gate-v1.99.99', expected: reject}
    ]
    let failures = $cases | each {|case|
        let result = (decide $case.candidate $case.current ($now - 30day) $now 3 true)
        if $result.decision != $case.expected {
            $'emergency ($case.candidate) over ($case.current): expected ($case.expected), got ($result.decision) - ($result.reason)'
        }
    } | compact
    assert ($failures | is-empty) ($failures | str join "\n")
}

@test
def test_canary_rejects_invalid_version_tags [] {
    for candidate in ['quality-gate-next' 'quality-gate-v1.0' 'v1.0.0'] {
        let result = (decide $candidate '' ((date now) - 10day) (date now) 3 true)
        assert equal $result.decision reject
    }
    let cli_result = (^nu $PROMOTE_SCRIPT validate quality-gate-next '' 2026-01-01 2026-01-10 3 --force | complete)
    assert equal $cli_result.exit_code 0
    assert ($cli_result.stdout | str contains '"decision": "reject"')
    let tag_result = (^bash $MOVE_TAG_SCRIPT --candidate-tag quality-gate-next | complete)
    assert equal $tag_result.exit_code 1
}

@test
def test_canary_moves_only_the_floating_tag [] {
    let root = mktemp --directory | str trim
    let bare = $root | path join remote.git
    let repository = $root | path join repository
    try {
        ^git init --bare --quiet $bare
        ^git init --quiet $repository
        ^git -C $repository config user.name 'Quality Gate test'
        ^git -C $repository config user.email 'quality-gate-test@example.invalid'
        ^git -C $repository remote add origin $bare

        'first' | save ($repository | path join README.md)
        ^git -C $repository add README.md
        ^git -C $repository commit --quiet -m 'first'
        ^git -C $repository tag --annotate quality-gate-v1.0.0 --message 'Release quality-gate-v1.0.0'

        'second' | save --force ($repository | path join README.md)
        ^git -C $repository add README.md
        ^git -C $repository commit --quiet -m 'second'
        ^git -C $repository tag --annotate quality-gate-v1.1.0 --message 'Release quality-gate-v1.1.0'
        ^git -C $repository push --quiet --set-upstream origin HEAD
        ^git -C $repository push --quiet origin --tags

        let first_move = (^bash $MOVE_TAG_SCRIPT --repository $repository --candidate-tag quality-gate-v1.0.0 | complete)
        assert equal $first_move.exit_code 0
        let first_tag_ref = (^git -C $repository show-ref refs/tags/quality-gate-v1.0.0 | str trim)
        let second_move = (^bash $MOVE_TAG_SCRIPT --repository $repository --candidate-tag quality-gate-v1.1.0 | complete)
        assert equal $second_move.exit_code 0

        let second_tag_ref = (^git -C $repository show-ref refs/tags/quality-gate-v1.1.0 | str trim)
        let latest_sha = (^git --git-dir $bare rev-parse 'refs/tags/quality-gate-latest^{}' | str trim)
        let candidate_sha = (^git --git-dir $bare rev-parse 'refs/tags/quality-gate-v1.1.0^{}' | str trim)
        assert equal $first_tag_ref (^git -C $repository show-ref refs/tags/quality-gate-v1.0.0 | str trim)
        assert equal $second_tag_ref (^git -C $repository show-ref refs/tags/quality-gate-v1.1.0 | str trim)
        assert equal $latest_sha $candidate_sha
    } catch {|error|
        rm --recursive --force $root
        error make {msg: $error.msg}
    }
    rm --recursive --force $root
}

@test
def test_canary_floating_tag_move_loses_a_race_against_a_concurrent_promotion [] {
    let root = mktemp --directory | str trim
    let bare = $root | path join remote.git
    let repository = $root | path join repository
    let bin = $root | path join bin
    let outcome = try {
        ^git init --bare --quiet $bare
        ^git init --quiet $repository
        ^git -C $repository config user.name 'Quality Gate test'
        ^git -C $repository config user.email 'quality-gate-test@example.invalid'
        ^git -C $repository remote add origin $bare
        for version in [1.0.0 1.1.0 1.2.0] {
            $version | save --force ($repository | path join README.md)
            ^git -C $repository add README.md
            ^git -C $repository commit --quiet -m $version
            ^git -C $repository tag --annotate $'quality-gate-v($version)' --message $version
        }
        ^git -C $repository push --quiet --set-upstream origin HEAD
        ^git -C $repository push --quiet origin --tags
        let first = (^bash $MOVE_TAG_SCRIPT --repository $repository --candidate-tag quality-gate-v1.0.0 | complete)
        assert equal $first.exit_code 0 $first.stderr

        let racer = (^git --git-dir $bare rev-parse 'refs/tags/quality-gate-v1.2.0^{commit}' | str trim)
        let real_git = (^which git | str trim)
        mkdir $bin
        $"#!/bin/sh\n'($real_git)' \"$@\"\nstatus=$?\ncase \" $* \" in\n  *\" ls-remote \"*) '($real_git)' --git-dir '($bare)' update-ref refs/tags/quality-gate-latest ($racer) ;;\nesac\nexit $status\n" | save --force ($bin | path join git)
        ^chmod +x ($bin | path join git)

        let before = (^git --git-dir $bare rev-parse 'refs/tags/quality-gate-latest^{commit}' | str trim)
        let lost = with-env {PATH: ($env.PATH | prepend $bin)} {
            ^bash $MOVE_TAG_SCRIPT --repository $repository --candidate-tag quality-gate-v1.1.0 | complete
        }
        assert ($lost.exit_code != 0) 'the move must fail when the remote tag changed after it was read'
        let after = (^git --git-dir $bare rev-parse 'refs/tags/quality-gate-latest^{commit}' | str trim)
        assert equal $after $racer 'the concurrent promotion must be preserved'
        assert ($before != $racer)
        null
    } catch {|error|
        $error.msg
    }
    rm --recursive --force $root
    if $outcome != null { error make {msg: $outcome} }
}

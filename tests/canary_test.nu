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
def test_canary_rejects_future_tags [] {
    let result = (decide 'quality-gate-v1.0.0' '' ((date now) + 1day) (date now) 3)
    assert equal $result.decision reject
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

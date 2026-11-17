use std/assert
use std/testing *

source ../release/promote.nu

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

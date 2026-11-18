use std/assert
use std/testing *

const FLAKE_ROOT = path self | path dirname | path join ..

@test
def test_quality_gate_workflow_uses_the_shared_cache_without_pr_push [] {
    let workflow = open --raw ($FLAKE_ROOT | path join .github workflows quality-gate-tests.yml) | from yaml
    let pull_jobs = [$workflow.jobs.tests $workflow.jobs.darwin-build]
    for job in $pull_jobs {
        let cache_step = $job.steps | where name == 'Use Quality Gate binary caches' | first
        assert equal $cache_step.with.name prefeitura-rio
        assert equal $cache_step.with.extraPullNames devenv
        assert equal $cache_step.with.skipPush true
    }
    let publish = $workflow | get jobs | get publish-cache
    assert equal $publish.environment cachix-publish
    let publish_step = $publish.steps | where name == 'Publish Quality Gate builds' | first
    assert equal $publish_step.with.authToken '${{ secrets.CACHIX_AUTH_TOKEN }}'
}

@test
def test_release_workflow_only_pulls_the_shared_cache [] {
    let workflow = open --raw ($FLAKE_ROOT | path join .github workflows quality-gate-release.yml) | from yaml
    assert not ('secrets' in $workflow.jobs.release)
    let cache_step = $workflow.jobs.quality-gate-change.steps | where name == 'Use Quality Gate binary caches' | first
    assert equal $cache_step.with.name prefeitura-rio
    assert equal $cache_step.with.extraPullNames devenv
    assert equal $cache_step.with.skipPush true
}

@test
def test_flake_exposes_a_lightweight_discovery_app [] {
    let flake = open --raw ($FLAKE_ROOT | path join flake.nix)
    assert ($flake | str contains 'quality-gate-detect')
    assert ($flake | str contains 'name = "quality-gate-detect"')
    assert ($flake | str contains 'git')
    assert ($flake | str contains 'nushell')
}

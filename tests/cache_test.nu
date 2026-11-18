use std/assert
use std/testing *

const FLAKE_ROOT = path self | path dirname | path join ..

@test
def test_quality_gate_workflow_uses_the_shared_cache_without_pr_push [] {
    let workflow = open --raw ($FLAKE_ROOT | path join .github workflows quality-gate-tests.yml)
    assert ($workflow | str contains 'name: prefeitura-rio')
    assert ($workflow | str contains 'extraPullNames: devenv')
    assert ($workflow | str contains 'skipPush: true')
    assert ($workflow | str contains 'Publish Quality Gate binary cache')
    assert ($workflow | str contains 'environment: cachix-publish')
    assert ($workflow | str contains 'authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}')
}

@test
def test_release_workflow_only_pulls_the_shared_cache [] {
    let workflow = open --raw ($FLAKE_ROOT | path join .github workflows quality-gate-release.yml)
    assert ($workflow | str contains 'name: prefeitura-rio')
    assert ($workflow | str contains 'extraPullNames: devenv')
    assert ($workflow | str contains 'skipPush: true')
}

@test
def test_flake_exposes_a_lightweight_discovery_app [] {
    let flake = open --raw ($FLAKE_ROOT | path join flake.nix)
    assert ($flake | str contains 'quality-gate-detect')
    assert ($flake | str contains 'name = "quality-gate-detect"')
    assert ($flake | str contains 'git')
    assert ($flake | str contains 'nushell')
}

use std/assert
use std/testing *
use support/isolation.nu

# release/rulesets/apply.sh against a stateful fake of the GitHub API that starts
# from a snapshot of the real repository (tests/fixtures/github-api/before.json).

const TESTS = path self | path dirname
const APPLY = path self | path dirname | path join .. release rulesets apply.sh
const FAKE_GH = path self | path dirname | path join support fake-gh.nu
const BEFORE = path self | path dirname | path join fixtures github-api before.json

const ENVIRONMENT_SECRETS = {
    quality-gate-release: [QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY GITLAB_CANARY_TOKEN]
    quality-gate-promotion: [QUALITY_GATE_RELEASE_APP_ID QUALITY_GATE_RELEASE_APP_PRIVATE_KEY]
    cachix-publish: [CACHIX_AUTH_TOKEN]
    quality-gate-kodus-review: [KODUS_TEAM_KEY KODUS_TAILSCALE_CLIENT_ID KODUS_TAILSCALE_CLIENT_SECRET]
}

def new-world []: nothing -> record {
    let root = mktemp --directory | str trim
    let bin = $root | path join bin
    mkdir $bin
    cp $FAKE_GH ($bin | path join gh)
    ^chmod +x ($bin | path join gh)
    cp $BEFORE ($root | path join state.json)
    {root: $root, bin: $bin, state: ($root | path join state.json)}
}

def edit-state [world: record, change: closure] {
    open $world.state | do $change $in | to json | save --force $world.state
}

# What the repository looks like once the secrets were moved by hand.
def secrets-in-environments [world: record] {
    edit-state $world {|state|
        $state | update repository_secrets [] | update environment_secrets $ENVIRONMENT_SECRETS
    }
}

def forget-writes [world: record] {
    edit-state $world {|state| $state | update writes [] }
}

def writes [world: record]: nothing -> list<string> {
    (open $world.state).writes
}

def --wrapped apply-script [world: record, ...arguments: string]: nothing -> record {
    with-env {PATH: ($env.PATH | prepend $world.bin), FAKE_GH_STATE: $world.state} {
        ^bash $APPLY --app-id 5818520 ...$arguments | complete
    }
}

def finish [world: record, outcome: any] {
    rm --recursive --force $world.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_a_dry_run_reads_the_repository_and_sends_nothing [] {
    let world = new-world
    let outcome = try {
        let result = apply-script $world
        assert equal $result.exit_code 0 $result.stderr
        assert equal (writes $world) []
        assert ($result.stdout | str contains 'DRY RUN  PUT /repos/prefeitura-rio/flakes/environments/quality-gate-release')
        assert ($result.stdout | str contains 'CHANGE   environment quality-gate-promotion: administrators can bypass it')
        assert ($result.stdout | str contains 'DRY RUN  POST /repos/prefeitura-rio/flakes/rulesets')
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_verify_fails_on_the_repository_as_it_is_today [] {
    let world = new-world
    let outcome = try {
        let result = apply-script $world --verify
        assert equal $result.exit_code 1
        assert equal (writes $world) []
        for expected in [
            'environment quality-gate-release: the environment does not exist'
            'environment quality-gate-promotion: administrators can bypass it'
            'environment cachix-publish: the environment does not exist'
            'workflow permissions'
            'ruleset protect-quality-gate-tags does not exist'
            'ruleset protect-master does not exist'
            'secret CACHIX_AUTH_TOKEN is stored at repository level'
            'secret GITLAB_CANARY_TOKEN is stored at repository level'
            'secret QUALITY_GATE_RELEASE_APP_PRIVATE_KEY is missing from environment quality-gate-release'
        ] {
            assert ($result.stdout | str contains $expected) $'missing from the report: ($expected)\n($result.stdout)'
        }
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_apply_configures_everything_and_verify_then_passes [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let applied = apply-script $world --apply
        assert equal $applied.exit_code 0 $'($applied.stdout)\n($applied.stderr)'

        let state = open $world.state
        for name in [quality-gate-release quality-gate-promotion cachix-publish] {
            let environment = $state.environments | get $name
            assert equal $environment.can_admins_bypass false $name
            assert ($state.policies | get $name | any {|policy| $policy.name == master }) $'($name) must deploy from master only'
        }
        let reviewers = {|name|
            $state.environments | get $name | get protection_rules
            | where type == required_reviewers | get reviewers | flatten | get reviewer.id | sort
        }
        assert equal (do $reviewers quality-gate-promotion) [22376151 35741485]
        assert equal (do $reviewers quality-gate-release) []
        assert equal (do $reviewers cachix-publish) []
        assert equal $state.workflow {default_workflow_permissions: read, can_approve_pull_request_reviews: false}
        assert equal ($state.rulesets | length) 3
        let tags = $state.rulesets | where name == protect-quality-gate-tags | first
        assert equal $tags.bypass_actors [{actor_id: 5818520, actor_type: Integration, bypass_mode: always}]
        assert equal ($state.rulesets | where name == protect-master | first | get bypass_actors) []
        let version_tags = $state.rulesets | where name == protect-quality-gate-version-tags | first
        assert equal $version_tags.bypass_actors [] 'nobody, not even the release App, may move or delete a version tag'
        assert equal ($version_tags.rules | get type | sort) [deletion update]
        assert equal $version_tags.conditions.ref_name.include ['refs/tags/quality-gate-v*']

        let verified = apply-script $world --verify
        assert equal $verified.exit_code 0 $'($verified.stdout)\n($verified.stderr)'
        assert ($verified.stdout | str contains 'matches the Quality Gate governance')
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_applying_twice_changes_nothing_the_second_time [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let first = apply-script $world --apply
        assert equal $first.exit_code 0 $'($first.stdout)\n($first.stderr)'
        assert (((writes $world) | length) > 0)
        forget-writes $world
        let second = apply-script $world --apply
        assert equal $second.exit_code 0 $'($second.stdout)\n($second.stderr)'
        assert equal (writes $world) [] 'a second run must not send any write'
        assert equal ((open $world.state).rulesets | length) 3 'rulesets must not be duplicated'
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_optional_kodus_environment_is_guarded_when_enabled [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let applied = apply-script $world --include-kodus --apply
        assert equal $applied.exit_code 0 $'($applied.stdout)\n($applied.stderr)'
        let state = open $world.state
        assert equal $state.environments.quality-gate-kodus-review.can_admins_bypass false
        assert equal ($state.policies | get quality-gate-kodus-review | get name) [master]
        assert equal (apply-script $world --include-kodus --verify | get exit_code) 0
        edit-state $world {|state|
            $state | update policies ($state.policies | update cachix-publish ($state.policies | get cachix-publish | append {id: 98, name: '*', type: branch}))
        }
        assert equal (apply-script $world --include-kodus --verify | get exit_code) 0 'extra-policy checking is limited to the new Kodus Environment'
        edit-state $world {|state|
            $state | update policies ($state.policies | update quality-gate-kodus-review ($state.policies | get quality-gate-kodus-review | append {id: 99, name: '*', type: branch}))
        }
        let broad = apply-script $world --include-kodus --verify
        assert equal $broad.exit_code 1
        assert ($broad.stdout | str contains 'unexpected deployment branch or tag policy')
        edit-state $world {|state|
            $state | update policies ($state.policies | update quality-gate-kodus-review ($state.policies | get quality-gate-kodus-review | where name == master))
        }
        edit-state $world {|state|
            $state | update environment_secrets ($state.environment_secrets | update cachix-publish [CACHIX_AUTH_TOKEN KODUS_TEAM_KEY])
        }
        let misplaced = apply-script $world --include-kodus --verify
        assert equal $misplaced.exit_code 1
        assert ($misplaced.stdout | str contains 'secret KODUS_TEAM_KEY is stored in environment cachix-publish')
        secrets-in-environments $world
        edit-state $world {|state| $state | update repository_secrets [KODUS_TEAM_KEY] }
        let unprotected = apply-script $world --verify
        assert equal $unprotected.exit_code 1
        assert ($unprotected.stdout | str contains 'secret KODUS_TEAM_KEY is stored at repository level')
        null
    } catch {|error| $error.msg }
    finish $world $outcome
}

@test
def test_drift_is_detected_and_repaired_without_creating_duplicates [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let first = apply-script $world --apply
        assert equal $first.exit_code 0 $first.stdout

        edit-state $world {|state|
            let rulesets = $state.rulesets | each {|ruleset|
                if $ruleset.name == protect-master {
                    $ruleset | update enforcement disabled
                } else {
                    $ruleset | update bypass_actors ($ruleset.bypass_actors | append {actor_id: 15368, actor_type: Integration, bypass_mode: always})
                }
            }
            $state
            | update rulesets $rulesets
            | update environments ($state.environments | update quality-gate-promotion ($state.environments | get quality-gate-promotion | update can_admins_bypass true))
            | update workflow {default_workflow_permissions: write, can_approve_pull_request_reviews: true}
        }

        let verified = apply-script $world --verify
        assert equal $verified.exit_code 1
        for expected in [
            'ruleset protect-master differs'
            'ruleset protect-quality-gate-tags differs'
            'ruleset protect-quality-gate-version-tags differs'
            'environment quality-gate-promotion: administrators can bypass it'
            'workflow permissions'
        ] {
            assert ($verified.stdout | str contains $expected) $'drift not reported: ($expected)\n($verified.stdout)'
        }

        forget-writes $world
        let repaired = apply-script $world --apply
        assert equal $repaired.exit_code 0 $'($repaired.stdout)\n($repaired.stderr)'
        let sent = writes $world
        assert ($sent | all {|write| $write | str starts-with 'PUT' }) $'repairs must update in place, sent: ($sent | to nuon)'
        assert equal ((open $world.state).rulesets | length) 3
        assert equal (apply-script $world --verify | get exit_code) 0
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_an_existing_ruleset_with_the_same_name_is_updated_not_recreated [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        edit-state $world {|state|
            $state | update rulesets [{id: 77, name: protect-master, target: branch, enforcement: active, conditions: {ref_name: {include: ['refs/heads/master'], exclude: []}}, rules: [{type: deletion}], bypass_actors: []}]
        }
        let result = apply-script $world --apply
        assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
        let sent = writes $world
        assert ($sent | any {|write| $write == 'PUT rulesets/77' }) $'the existing ruleset must be updated: ($sent | to nuon)'
        assert equal ((open $world.state).rulesets | where name == protect-master | length) 1
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_a_skipped_ruleset_is_neither_created_nor_verified [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let applied = apply-script $world --apply --skip-ruleset protect-master
        assert equal $applied.exit_code 0 $'($applied.stdout)\n($applied.stderr)'
        assert ($applied.stdout | str contains 'SKIPPED  ruleset protect-master')
        let rulesets = (open $world.state).rulesets
        assert equal ($rulesets | get name | sort) [protect-quality-gate-tags protect-quality-gate-version-tags]

        let verified = apply-script $world --verify --skip-ruleset protect-master
        assert equal $verified.exit_code 0 $'($verified.stdout)\n($verified.stderr)'
        let strict = apply-script $world --verify
        assert equal $strict.exit_code 1
        assert ($strict.stdout | str contains 'ruleset protect-master does not exist')

        # Once the checks exist on master the skip is dropped and the ruleset is created.
        let complete = apply-script $world --apply
        assert equal $complete.exit_code 0 $'($complete.stdout)\n($complete.stderr)'
        assert equal ((open $world.state).rulesets | length) 3
        assert equal (apply-script $world --verify | get exit_code) 0
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_secrets_left_at_repository_level_fail_the_verification [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let applied = apply-script $world --apply
        assert equal $applied.exit_code 0
        edit-state $world {|state| $state | update repository_secrets [CACHIX_AUTH_TOKEN] }
        let result = apply-script $world --verify
        assert equal $result.exit_code 1
        assert ($result.stdout | str contains 'secret CACHIX_AUTH_TOKEN is stored at repository level')
        assert not ($result.stdout | str contains 'secret GITLAB_CANARY_TOKEN is stored')
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_the_app_id_is_validated_before_anything_runs [] {
    let world = new-world
    let outcome = try {
        for id in ['' 'abc' '12x'] {
            let result = with-env {PATH: ($env.PATH | prepend $world.bin), FAKE_GH_STATE: $world.state} {
                ^bash $APPLY --app-id $id | complete
            }
            assert equal $result.exit_code 2 $'app id "($id)"'
        }
        assert equal (writes $world) []
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

# ---------------------------------------------------------------------------
# Docs, rulesets, workflows and apply.sh must describe the same governance.
# ---------------------------------------------------------------------------

const RELEASE = path self | path dirname | path join .. release
const WORKFLOWS = path self | path dirname | path join .. .github workflows

@test
def test_the_docs_name_the_app_that_the_tag_ruleset_trusts [] {
    let tags = open ($RELEASE | path join rulesets quality-gate-tags.json)
    let actors = $tags.bypass_actors
    assert equal ($actors | length) 1 'only the release App may bypass the tag ruleset'
    assert equal ($actors | first | get actor_type) Integration
    let app = $actors | first | get actor_id | into string
    for document in [README.md APP-SETUP.md] {
        let text = open --raw ($RELEASE | path join rulesets $document)
        assert ($text | str contains $app) $'($document) must name the App ID ($app)'
    }
    for file in [quality-gate-tags.json quality-gate-version-tags.json master.json] {
        let ruleset = open ($RELEASE | path join rulesets $file)
        let generic = $ruleset.bypass_actors | where actor_id == 15368
        assert ($generic | is-empty) $'($file) lets the generic GitHub Actions integration bypass the ruleset'
    }
    let script = open --raw ($RELEASE | path join rulesets apply.sh)
    assert (not ($script | str contains '5818520')) 'the App ID is a parameter of apply.sh, never hard-coded'
}

@test
def test_every_environment_the_workflows_use_is_configured_by_apply_sh [] {
    let configured = open --raw ($RELEASE | path join rulesets apply.sh)
        | lines
        | where {|line| $line starts-with 'environment_names=' }
        | first
        | str replace 'environment_names=' ''
        | str trim --char '"'
        | split row ' '
    let used = glob ($WORKFLOWS | path join '*.yml') | each {|file|
        let workflow = open --raw $file | from yaml
        $workflow.jobs | items {|_, job|
            let direct = $job.environment? | default ''
            let name = if ($direct | describe | str starts-with 'record') { $direct.name } else { $direct }
            [$name ($job.with?.environment? | default '')]
        } | flatten
    } | flatten | where {|name| $name | is-not-empty } | uniq
    assert ($used | is-not-empty) 'the workflows are expected to use environments'
    let unknown = $used | where {|name| $name not-in $configured }
    assert ($unknown | is-empty) $'environments used by workflows but not configured by apply.sh: ($unknown | to nuon)'
}

@test
def test_master_trusts_check_results_only_from_github_actions_and_needs_a_second_pair_of_eyes [] {
    let master = open ($RELEASE | path join rulesets master.json)
    let checks = $master.rules | where type == required_status_checks | first | get parameters.required_status_checks
    assert ($checks | is-not-empty)
    let spoofable = $checks | where {|check| ($check.integration_id? | default null) != 15368 } | get context
    assert ($spoofable | is-empty) $'any commit status could satisfy: ($spoofable | to nuon)'
    let review = $master.rules | where type == pull_request | first | get parameters
    assert equal $review.require_last_push_approval true 'a code owner must not approve a pull request they pushed to'
    assert equal $review.require_code_owner_review true
}

@test
def test_a_status_check_that_any_source_can_satisfy_is_reported_as_drift [] {
    let world = new-world
    let outcome = try {
        secrets-in-environments $world
        let applied = apply-script $world --apply
        assert equal $applied.exit_code 0 $'($applied.stdout)\n($applied.stderr)'
        edit-state $world {|state|
            let rulesets = $state.rulesets | each {|ruleset|
                if $ruleset.name == protect-master {
                    let rules = $ruleset.rules | each {|rule|
                        if $rule.type == required_status_checks {
                            $rule | update parameters.required_status_checks ($rule.parameters.required_status_checks | each {|check| $check | reject integration_id })
                        } else { $rule }
                    }
                    $ruleset | update rules $rules
                } else { $ruleset }
            }
            $state | update rulesets $rulesets
        }
        let verified = apply-script $world --verify
        assert equal $verified.exit_code 1
        assert ($verified.stdout | str contains 'ruleset protect-master differs') $verified.stdout
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_verify_does_not_pass_when_the_secret_listings_cannot_be_read [] {
    let cases = [
        {failing: 'GET actions/secrets', expected: 'cannot read the repository secrets'}
        {failing: 'GET environments/cachix-publish/secrets', expected: 'cannot read the secrets of environment cachix-publish'}
    ]
    for case in $cases {
        let world = new-world
        let outcome = try {
            secrets-in-environments $world
            let applied = apply-script $world --apply
            assert equal $applied.exit_code 0 $'($applied.stdout)\n($applied.stderr)'
            # A secret still stored at repository level, with a token that cannot list them.
            edit-state $world {|state| $state | update repository_secrets [CACHIX_AUTH_TOKEN] }
            let verified = with-env {FAKE_GH_FAIL: $case.failing} { apply-script $world --verify }
            assert equal $verified.exit_code 1 $'($case.failing): an unreadable listing must not be reported as compliant\n($verified.stdout)'
            assert ($verified.stdout | str contains $case.expected) $verified.stdout
            assert not ($verified.stdout | str contains 'matches the Quality Gate governance')
            null
        } catch {|error|
            $error.msg
        }
        finish $world $outcome
    }
}

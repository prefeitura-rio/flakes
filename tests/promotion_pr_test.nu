use std/assert
use std/testing *

# release/scripts/open-promotion-pr.sh against a real Git repository with a bare
# remote. The fake `gh` answers `pr list` from a file and records `pr create`.

const SCRIPT = path self | path dirname | path join .. release scripts open-promotion-pr.sh
const TAG = 'quality-gate-v1.2.0'
const BRANCH = 'automation/quality-gate-promotion-quality-gate-v1.2.0'

def new-world []: nothing -> record {
    let root = mktemp --directory | str trim
    let remote = $root | path join remote.git
    let work = $root | path join work
    let bin = $root | path join bin
    mkdir $bin
    ^git init --quiet --bare --initial-branch master $remote
    ^git init --quiet --initial-branch master $work
    let identity = [-c user.name=t -c user.email=t@example.invalid]
    mkdir ($work | path join release)
    "version: 1\nlatest: \"quality-gate-v1.0.0\"\nprevious: \"\"\nbake_days: 3\n" | save --force ($work | path join release channels.yaml)
    ^git -C $work add --all
    ^git -C $work ...$identity commit --quiet -m base
    ^git -C $work remote add origin $remote
    ^git -C $work push --quiet origin master
    let log = $root | path join gh.log
    let pull_requests = $root | path join prs.json
    '[]' | save --force $pull_requests
    let fake = $"#!/usr/bin/env bash
case \"$1 $2\" in
  'pr list') cat '($pull_requests)' ;;
  'pr create') echo \"$*\" >> '($log)'; echo https://example.invalid/pull/1 ;;
  *) echo \"unexpected gh call: $*\" >&2; exit 2 ;;
esac
"
    $fake | save --force ($bin | path join gh)
    ^chmod +x ($bin | path join gh)
    {root: $root, remote: $remote, work: $work, bin: $bin, log: $log, prs: $pull_requests, identity: $identity}
}

def --wrapped run-script [world: record, ...arguments: string]: nothing -> record {
    with-env {
        PATH: ($env.PATH | prepend $world.bin)
        GIT_CONFIG_GLOBAL: '/dev/null'
        GIT_AUTHOR_NAME: t
        GIT_AUTHOR_EMAIL: t@example.invalid
        GIT_COMMITTER_NAME: t
        GIT_COMMITTER_EMAIL: t@example.invalid
    } {
        cd $world.work
        ^bash $SCRIPT ...$arguments | complete
    }
}

def created [world: record]: nothing -> list<string> {
    if ($world.log | path exists) { open --raw $world.log | lines } else { [] }
}

def remote-branches [world: record]: nothing -> list<string> {
    ^git --git-dir $world.remote for-each-ref --format '%(refname:short)' refs/heads | lines
}

def remote-channels [world: record]: nothing -> string {
    ^git --git-dir $world.remote show $'($BRANCH):release/channels.yaml'
}

def finish [world: record, outcome: any] {
    rm --recursive --force $world.root
    if $outcome != null { error make {msg: $outcome} }
}

@test
def test_a_healthy_candidate_gets_a_branch_and_a_pull_request [] {
    let world = new-world
    let outcome = try {
        let result = run-script $world --version-tag $TAG
        assert equal $result.exit_code 0 $'($result.stdout)\n($result.stderr)'
        assert ($BRANCH in (remote-branches $world))
        let channels = remote-channels $world
        assert ($channels | str contains $'latest: "($TAG)"') $channels
        assert ($channels | str contains 'previous: "quality-gate-v1.0.0"') $channels
        let calls = created $world
        assert equal ($calls | length) 1
        assert ($calls | first | str contains $'--head ($BRANCH)')
        assert ($calls | first | str contains '--base master')
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_an_open_pull_request_is_left_alone [] {
    let world = new-world
    let outcome = try {
        '[{"number": 7, "state": "OPEN"}]' | save --force $world.prs
        let result = run-script $world --version-tag $TAG
        assert equal $result.exit_code 0 $result.stderr
        assert ($result.stdout | str contains 'already exists')
        assert equal (remote-branches $world) [master]
        assert equal (created $world) []
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_a_pull_request_closed_without_merge_is_not_proposed_again [] {
    let world = new-world
    let outcome = try {
        # The first run pushed the branch; reviewers closed the PR without merging.
        let first = run-script $world --version-tag $TAG
        assert equal $first.exit_code 0 $first.stderr
        '[{"number": 9, "state": "CLOSED"}]' | save --force $world.prs
        '' | save --force $world.log
        let second = run-script $world --version-tag $TAG
        assert equal $second.exit_code 0 $'the daily run must not fail: ($second.stdout) ($second.stderr)'
        assert ($second.stdout | str contains '::warning::')
        assert ($second.stdout | str contains 'closed without merging')
        assert equal (created $world | where {|line| $line | is-not-empty }) []
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_a_branch_pushed_by_a_run_that_failed_before_opening_the_pr_is_reused [] {
    let world = new-world
    let outcome = try {
        let first = run-script $world --version-tag $TAG
        assert equal $first.exit_code 0 $first.stderr
        # Simulate the failure: the branch is on the remote but no PR exists.
        '' | save --force $world.log
        ^git -C $world.work switch --quiet master
        ^git -C $world.work branch --quiet --delete --force $BRANCH
        let second = run-script $world --version-tag $TAG
        assert equal $second.exit_code 0 $'($second.stdout)\n($second.stderr)'
        assert ($second.stdout | str contains 'opening the PR from it')
        assert equal (created $world | where {|line| $line | is-not-empty } | length) 1
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_an_existing_branch_with_other_content_is_an_error [] {
    let world = new-world
    let outcome = try {
        ^git -C $world.work switch --quiet --create $BRANCH
        "version: 1\nlatest: \"quality-gate-v0.9.0\"\nprevious: \"\"\n" | save --force ($world.work | path join release channels.yaml)
        ^git -C $world.work add --all
        ^git -C $world.work ...$world.identity commit --quiet -m other
        ^git -C $world.work push --quiet origin $BRANCH
        ^git -C $world.work switch --quiet master
        let result = run-script $world --version-tag $TAG
        assert ($result.exit_code != 0)
        assert ($result.stderr | str contains 'Delete it and run again')
        assert equal (created $world) []
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

@test
def test_the_version_tag_is_validated [] {
    let world = new-world
    let outcome = try {
        for tag in ['' 'v1.2.0' 'quality-gate-v1.2' 'quality-gate-v1.2.0; rm -rf /'] {
            let result = run-script $world --version-tag $tag
            assert equal $result.exit_code 2 $'tag "($tag)"'
        }
        assert equal (remote-branches $world) [master]
        null
    } catch {|error|
        $error.msg
    }
    finish $world $outcome
}

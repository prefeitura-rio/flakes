#!/usr/bin/env nu
# A stateful stand-in for `gh api` that behaves like the parts of the GitHub REST
# API release/rulesets/apply.sh uses, including the failures that make a script
# non-idempotent: creating a ruleset or branch policy twice is a 422, a missing
# environment is a 404, and the server fills in defaults the client never sent.
#
# State lives in the JSON file named by FAKE_GH_STATE; tests/fixtures/github-api
# holds a snapshot captured from the real repository. Every write is appended to
# `writes` so tests can assert what was (not) sent.

def fail [status: int, message: string] {
    print -e $message
    exit $status
}

def not-found [] {
    fail 1 'gh: Not Found (HTTP 404)'
}

def unprocessable [message: string] {
    fail 1 $'gh: Validation Failed \(HTTP 422\): ($message)'
}

def record-write [state: record, method: string, path: string]: nothing -> record {
    $state | update writes ($state.writes | append $'($method) ($path)')
}

def reviewer-rule [body: record]: nothing -> list<record> {
    let reviewers = $body.reviewers? | default []
    if ($reviewers | is-empty) {
        []
    } else {
        [{
            type: required_reviewers
            prevent_self_review: ($body.prevent_self_review? | default false)
            reviewers: ($reviewers | each {|reviewer|
                {type: $reviewer.type, reviewer: {login: $'user-($reviewer.id)', id: $reviewer.id, type: $reviewer.type}}
            })
        }]
    }
}

# What GitHub stores after receiving a ruleset: the same document plus defaults
# the client did not send.
def stored-ruleset [id: int, body: record]: nothing -> record {
    let rules = $body.rules | each {|rule|
        if $rule.type == pull_request {
            $rule | update parameters ($rule.parameters | merge {allowed_merge_methods: [merge squash rebase]})
        } else {
            $rule
        }
    }
    $body
    | update rules $rules
    | merge {id: $id, source_type: Repository, source: 'prefeitura-rio/flakes', current_user_can_bypass: always}
}

def --wrapped main [...args: string] {
    let wants_input = ($args | any {|argument| $argument == '--input' })
    let body = if $wants_input { open --raw /dev/stdin | from json } else { null }
    if ($args | first) != api {
        fail 2 $'fake gh only implements api, got ($args | first)'
    }
    let method = if '--method' in $args { $args | get (($args | enumerate | where item == '--method' | first | get index) + 1) } else { 'GET' }
    let path = $args | where {|argument| $argument | str starts-with '/repos/' } | first | str replace --regex '^/repos/[^/]+/[^/]+/' ''
    let state_file = $env.FAKE_GH_STATE
    let state = open $state_file

    let segments = $path | split row '/'
    let result = match [$method $segments] {
        [GET [environments $name]] => {
            if $name not-in ($state.environments | columns) { not-found }
            {response: ($state.environments | get $name)}
        }
        [GET [environments $name deployment-branch-policies]] => {
            if $name not-in ($state.environments | columns) { not-found }
            let policies = $state.policies | get --optional $name | default []
            {response: {total_count: ($policies | length), branch_policies: $policies}}
        }
        [GET [environments $name secrets]] => {
            if $name not-in ($state.environments | columns) { not-found }
            let names = $state.environment_secrets | get --optional $name | default []
            {response: {total_count: ($names | length), secrets: ($names | each {|secret| {name: $secret}})}}
        }
        [GET [actions permissions workflow]] => { {response: $state.workflow} }
        [GET [actions secrets]] => {
            {response: {total_count: ($state.repository_secrets | length), secrets: ($state.repository_secrets | each {|secret| {name: $secret}})}}
        }
        [GET [rulesets]] => {
            {response: ($state.rulesets | each {|ruleset| $ruleset | select id name target enforcement })}
        }
        [GET [rulesets $id]] => {
            let found = $state.rulesets | where id == ($id | into int)
            if ($found | is-empty) { not-found }
            {response: ($found | first)}
        }
        [PUT [environments $name]] => {
            let rules = (reviewer-rule $body) ++ (if ($body.deployment_branch_policy?.custom_branch_policies? | default false) { [{type: branch_policy}] } else { [] })
            let environment = {
                name: $name
                can_admins_bypass: ($body.can_admins_bypass? | default true)
                protection_rules: $rules
                deployment_branch_policy: ($body.deployment_branch_policy? | default null)
            }
            {state: (record-write ($state | update environments ($state.environments | upsert $name $environment)) $method $path)}
        }
        [POST [environments $name deployment-branch-policies]] => {
            if $name not-in ($state.environments | columns) { not-found }
            let existing = $state.policies | get --optional $name | default []
            if ($existing | any {|policy| $policy.name == $body.name }) { unprocessable 'Name has already been taken' }
            let policy = {id: ($state.next_id + 1), name: $body.name, type: $body.type}
            {state: (record-write ($state | update next_id ($state.next_id + 1) | update policies ($state.policies | upsert $name ($existing | append $policy))) $method $path)}
        }
        [PUT [actions permissions workflow]] => {
            {state: (record-write ($state | update workflow $body) $method $path)}
        }
        [POST [rulesets]] => {
            if ($state.rulesets | any {|ruleset| $ruleset.name == $body.name }) { unprocessable 'Name must be unique' }
            let id = $state.next_id + 1
            {state: (record-write ($state | update next_id $id | update rulesets ($state.rulesets | append (stored-ruleset $id $body))) $method $path)}
        }
        [PUT [rulesets $id]] => {
            let numeric = $id | into int
            if ($state.rulesets | where id == $numeric | is-empty) { not-found }
            let rulesets = $state.rulesets | each {|ruleset| if $ruleset.id == $numeric { stored-ruleset $numeric $body } else { $ruleset } }
            {state: (record-write ($state | update rulesets $rulesets) $method $path)}
        }
        _ => { fail 2 $'fake gh: ($method) ($path) is not implemented' }
    }

    if 'state' in $result {
        $result.state | to json | save --force $state_file
    } else {
        print ($result.response | to json)
    }
}

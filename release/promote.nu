#!/usr/bin/env nu

export def decide [
    candidate: string
    current: string
    created: datetime
    now: datetime
    bake_days: int
    force: bool = false
]: nothing -> record {
    if ($candidate | is-empty) {
        return { decision: 'noop', reason: 'No candidate version was requested.' }
    }
    if not ($candidate =~ '^quality-gate-v[0-9]+\.[0-9]+\.[0-9]+$') {
        return {
            decision: 'reject'
            reason: 'The candidate must match quality-gate-vX.Y.Z.'
        }
    }
    if ($current | is-not-empty) and not ($current =~ '^quality-gate-v[0-9]+\.[0-9]+\.[0-9]+$') {
        return {
            decision: 'reject'
            reason: 'The current stable version has an invalid format.'
        }
    }
    if $candidate == $current {
        return { decision: 'noop', reason: 'The requested version is already latest.' }
    }
    if $force {
        if ($current | is-empty) {
            return {
                decision: 'reject'
                reason: 'Emergency mode is only valid for rolling back an existing stable channel.'
            }
        }
        if not ((version-compare $candidate $current) < 0) {
            return {
                decision: 'reject'
                reason: 'Emergency mode may only roll back to an older immutable release.'
            }
        }
    }
    if $created > $now {
        return { decision: 'reject', reason: 'The candidate tag was created in the future.' }
    }
    let age = $now - $created
    if not $force and $age < ($bake_days * 1day) {
        return {
            decision: 'reject'
            reason: $'The candidate has not completed its ($bake_days)-day bake time.'
        }
    }
    {
        decision: 'promote'
        reason: (if $force { 'Emergency promotion/rollback was explicitly requested.' } else { 'Bake time completed.' })
        candidate: $candidate
    }
}

def version-compare [left: string, right: string]: nothing -> int {
    let left_parts = $left | str replace 'quality-gate-v' '' | split row '.' | each {|part| $part | into int}
    let right_parts = $right | str replace 'quality-gate-v' '' | split row '.' | each {|part| $part | into int}
    mut comparison = 0
    for index in 0..2 {
        if $comparison == 0 {
            if ($left_parts | get $index) < ($right_parts | get $index) {
                $comparison = -1
            } else if ($left_parts | get $index) > ($right_parts | get $index) {
                $comparison = 1
            }
        }
    }
    $comparison
}

def main [
    command: string
    candidate: string
    current: string
    created: string
    now: string
    bake_days: int
    --force
] {
    if $command != validate {
        error make { msg: $'Unknown command: ($command)' }
    }
    decide $candidate $current ($created | into datetime) ($now | into datetime) $bake_days $force
    | to json
}

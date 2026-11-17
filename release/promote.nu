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

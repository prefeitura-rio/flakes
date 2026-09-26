# nu-lint-ignore-file: external_script_as_argument, exit_only_in_main

use std/log

# Format a command and its arguments for an error message.
def format-command [command: string, ...args: string]: nothing -> string {
    ([$command] | append $args | str join " ")
}

# Raise a labelled error after logging it.
export def fail [message: string, context: record<command: string, span: record>]: nothing -> error {
    log error $message
    error make {
        msg: $message
        label: {text: $context.command, span: $context.span}
    }
}

# Return true when a path exists and is a regular file.
export def is-file [path: path]: nothing -> bool {
    if not ($path | path exists) { false } else { ($path | path type) == file }
}

# Run a command. Suppress successful child output with --quiet.
export def run-command [
    --quiet # suppress successful child output
    command: string
    ...args: string
]: nothing -> record {
    let result = do { ^$command ...$args } | complete
    if not $quiet {
        if $result.stdout != "" {
            print ($result.stdout | str trim)
        }
        if $result.stderr != "" and $result.exit_code == 0 {
            print ($result.stderr | str trim)
        }
    }
    if $result.exit_code != 0 {
        if not $quiet and $result.stderr != "" {
            log error ($result.stderr | str trim)
        }
        fail $"Command failed (exit ($result.exit_code)): (format-command $command ...$args)" {
            command: $command
            span: (metadata $command).span
        }
    }
    $result
}

# Decrypt named SOPS files, run an action with their plaintext paths, and clean up.
export def run-with-sops [secrets: record, action: closure]: nothing -> nothing {
    let temp_dir = (run-command --quiet mktemp ...[--directory]).stdout | str trim
    try {
        let files = $secrets
        | items {|name encrypted|
            if not (is-file $encrypted) {
                fail $"Missing SOPS file: ($encrypted)." {
                    command: run-with-sops
                    span: (metadata $encrypted).span
                }
            }
            let plaintext = $temp_dir | path join $name
            run-command sops ...[
                decrypt
                --output
                $plaintext
                $encrypted
            ]
            {name: $name value: $plaintext}
        }
        | reduce --fold {} {|entry result|
            $result | insert $entry.name $entry.value
        }
        do $action $files
    } finally {
        rm --recursive --force $temp_dir
    }
}

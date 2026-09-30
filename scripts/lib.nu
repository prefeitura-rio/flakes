# nu-lint-ignore-file: external_script_as_argument, exit_only_in_main

use std/log

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

# Format a failed command message.
def format-failure [exit_code: int, ...words: string]: nothing -> string {
    $"Command failed \(exit ($exit_code)\): ($words | str join ' ')"
}

# Run a command. Show child output live, or capture it with --quiet.
export def run-command [
    --quiet # capture child output instead of showing it
    command: string
    ...args: string
]: nothing -> record {
    let span = (metadata $command).span
    if $quiet {
        let result = do { ^$command ...$args } | complete
        if $result.exit_code != 0 {
            fail (format-failure $result.exit_code $command ...$args) {command: $command span: $span}
        }
        return $result
    }
    try { ^$command ...$args } catch {
        fail (format-failure $env.LAST_EXIT_CODE $command ...$args) {command: $command span: $span}
    }
    {stdout: "" stderr: "" exit_code: 0}
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

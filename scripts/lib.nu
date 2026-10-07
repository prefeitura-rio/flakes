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

# Run a command and show its output live. Fail on a nonzero exit status, except --allow-exit-code.
export def run-command [
    --allow-exit-code: int # treat this nonzero exit status as success
    command: string
    ...args: string
]: nothing -> record {
    let span = (metadata $command).span
    let exit_code = try {
        ^$command ...$args
        0
    } catch {
        $env.LAST_EXIT_CODE
    }
    if $exit_code != 0 and $exit_code != $allow_exit_code {
        fail $"Command failed \(exit ($exit_code)\): ($command) ($args | str join ' ')" {command: $command span: $span}
    }
    {exit_code: $exit_code}
}

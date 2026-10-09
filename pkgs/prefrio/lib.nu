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

# Run a command with live output; fail on a nonzero exit, except --allow-exit-code.
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

const PROJECT_FILE = ".project.json"

# Find the nearest directory with a .project.json, searching upwards.
export def find-project-dir [from?: path]: nothing -> oneof<path, nothing> {
    mut dir = $from | default (pwd) | path expand
    loop {
        if (is-file ($dir | path join $PROJECT_FILE)) { return $dir }
        let parent = $dir | path dirname
        if $parent == $dir { return null }
        $dir = $parent
    }
}

# Return the project root: the .project.json folder, else the Git root, else the current folder.
export def project-root []: nothing -> path {
    let project = find-project-dir
    if $project != null { return $project }
    let result = do { git rev-parse --show-toplevel } | complete
    if $result.exit_code == 0 { $result.stdout | str trim } else { pwd | path expand }
}

# Read the .project.json of the current project.
export def read-project []: nothing -> record {
    let dir = find-project-dir
    if $dir == null {
        fail $"No ($PROJECT_FILE) found in (pwd) or any parent directory." {
            command: project
            span: (metadata $dir).span
        }
    }
    let path = $dir | path join $PROJECT_FILE
    let project = try { open $path } catch {|err|
        fail $"Could not read ($path): ($err.msg)" {command: project span: (metadata $path).span}
    }
    let name = if ($project | describe | str starts-with record) { $project.name? } else { null }
    if $name == null or $name == "" {
        fail $"($path) must be a record with a name." {command: project span: (metadata $path).span}
    }
    $project
}

# Choose an environment: the named one, or the only one; fail when ambiguous.
export def select-environment [project: record, name: oneof<string, nothing>]: nothing -> record {
    let environments = $project.env? | default {}
    if ($environments | is-empty) {
        fail $"Project ($project.name) has no env record in ($PROJECT_FILE)." {
            command: environment
            span: (metadata $project).span
        }
    }
    let available = $environments | columns
    let chosen = if $name != null {
        $name
    } else if ($available | length) == 1 {
        $available | first
    } else {
        fail $"Project ($project.name) has several environments. Pass --environment: ($available | str join ', ')." {
            command: environment
            span: (metadata $project).span
        }
    }
    if $chosen not-in $available {
        fail $"Project ($project.name) has no environment ($chosen). Available: ($available | str join ', ')." {
            command: environment
            span: (metadata $chosen).span
        }
    }
    $environments | get --optional $chosen
}

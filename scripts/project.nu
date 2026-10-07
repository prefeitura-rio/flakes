use ./lib.nu [fail]

const PROJECT_FILE = ".project.nuon"

# Find a project file in this directory or a parent directory.
def find-project-file-in [directory: path]: nothing -> oneof<record, nothing> {
    let candidate = $directory | path join $PROJECT_FILE
    if ($candidate | path exists) {
        {path: $candidate, root: $directory}
    } else {
        let parent = $directory | path dirname
        if $parent == $directory { null } else { find-project-file-in $parent }
    }
}

# Use the Git repository root, or the current directory outside a repository.
def default-root []: nothing -> string {
    let result = do { git rev-parse --show-toplevel } | complete
    if $result.exit_code == 0 {
        $result.stdout | str trim
    } else {
        pwd | path expand
    }
}

# Locate the optional project file. Without one, the project root is the repository root.
def locate-project-file []: nothing -> record {
    let override = $env.PREFRIO_PROJECT_FILE? | default null
    if $override != null {
        let path = $override | path expand
        if not ($path | path exists) { fail $"Project file not found: ($path)." {command: locate-project-file span: (metadata $path).span} }
        {
            path: $path
            root: ($path | path dirname)
        }
    } else {
        find-project-file-in (pwd | path expand) | default {path: null, root: (default-root)}
    }
}

# Read and normalize the optional nearest .project.nuon.
export def load-project-config []: nothing -> record {
    let file = locate-project-file
    let raw = if $file.path == null { {} } else {
        try { open $file.path } catch { fail $"Cannot read project file: ($file.path)." {command: load-project-config span: (metadata $file.path).span} }
    }
    {
        root: $file.root
        project: ($raw.project? | default null)
        k8s: ($raw.k8s? | default null)
    }
}

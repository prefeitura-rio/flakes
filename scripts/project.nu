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

# Locate the configured project file.
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
        let found = find-project-file-in (pwd | path expand)
        if $found == null { fail $"No ($PROJECT_FILE) found from (pwd)." {command: locate-project-file span: (metadata (pwd)).span} }
        $found
    }
}

# Select the active environment from the project file.
def select-environment [raw: record, --prod]: nothing -> record {
    let environments = $raw.env? | default null
    if $environments == null { {} } else {
        let name = if $prod { "prod" } else { "staging" }
        let selected = $environments | get --optional $name
        if $selected == null {
            fail $"Environment '($name)' is not configured in ($PROJECT_FILE)." {
                command: select-environment
                span: (metadata $name).span
            }
        }
        $selected | insert name $name
    }
}

# Resolve a project-relative path.
def resolve-project-path [paths: record]: nothing -> oneof<string, nothing> {
    if $paths.value == null { null } else {
        $paths.root | path join $paths.directory | path join $paths.value | path expand
    }
}

# Resolve plain and encrypted Terraform variable files.
def resolve-variable-files [context: record]: nothing -> record {
    let tf = $context.raw.tf? | default {}
    let value = $context.environment.vars? | default ($tf.vars? | default null)
    let path = resolve-project-path {root: $context.root, directory: $context.directory, value: $value}
    if $path == null { {plain: null, sops: null} } else if ($path | str ends-with .sops.json) { {plain: null, sops: $path} } else { {plain: $path, sops: null} }
}

# Apply explicit Terraform environment overrides.
def apply-overrides []: record -> record {
    let config = $in
    let vars = if $env.TF_SOPS_FILE? != null {
        $config.tf.vars | upsert plain null | upsert sops ($env.TF_SOPS_FILE | path expand)
    } else if $env.TF_VARS_FILE? != null {
        $config.tf.vars | upsert plain ($env.TF_VARS_FILE | path expand) | upsert sops null
    } else { $config.tf.vars }

    let backend = if $env.TF_BACKEND_CONFIG? != null {
        let parts = $env.TF_BACKEND_CONFIG | split row "="

        {
            ($parts.0): ($parts | skip 1 | str join "=")
        }
    } else { $config.tf.backend }

    $config | upsert tf ($config.tf | upsert vars $vars | upsert backend $backend)
}

# Normalize project identity fields.
def normalize-base [context: record]: nothing -> record {
    let root_name = $context.file.root | path basename
    {
        root: $context.file.root
        name: ($context.raw.name? | default $root_name)
        environment: ($context.environment.name? | default null)
        project: (
            $context.environment.project?
            | default ($context.raw.project? | default null)
        )
    }
}

# Normalize Terraform settings.
def normalize-terraform [context: record]: nothing -> record {
    let tf_raw = $context.raw.tf? | default {}
    {
        dir: ($context.file.root | path join $context.tf_dir | path expand)
        vars: $context.vars
        backend: ($context.environment.backend? | default ($tf_raw.backend? | default {}))
        plan_file: (
            if ($context.environment.name? | default "staging") == "prod" {
                "tofu.prod.plan"
            } else {
                "tofu.plan"
            }
        )
    }
}

# Normalize optional K3s settings.
def normalize-k3s [root: path, value: oneof<record, nothing>]: nothing -> oneof<record, nothing> {
    if $value == null { null } else {
        $value | upsert kubeconfig (resolve-project-path {
            root: $root
            directory: .
            value: ($value.kubeconfig? | default kubeconfig.sops.yaml)
        })
    }
}

# Build the normalized project record.
def normalize-project [context: record]: nothing -> record {
    let tf_raw = $context.raw.tf? | default {}
    let tf_dir = $tf_raw.dir? | default .
    let vars = resolve-variable-files {
        root: $context.file.root
        directory: $tf_dir
        raw: $context.raw
        environment: $context.environment
    }
    let base = normalize-base $context
    $base | merge {
        tf: (normalize-terraform ($context | insert tf_dir $tf_dir | insert vars $vars)),
        k8s: ($context.raw.k8s? | default null),
        k3s: (normalize-k3s $context.file.root ($context.raw.k3s? | default null))
    } | apply-overrides
}

# Read and normalize the nearest local .project.nuon.
export def load-project-config [--prod]: nothing -> record {
    let file = locate-project-file
    let raw = try { open $file.path } catch { fail $"Cannot read project file: ($file.path)." {command: load-project-config span: (metadata $file.path).span} }
    normalize-project {
        file: $file
        raw: $raw
        environment: (
            if $prod {
                select-environment $raw --prod
            } else {
                select-environment $raw
            }
        )
    }
}

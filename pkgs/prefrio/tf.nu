use std/log
use ./lib.nu [run-command fail is-file project-root find-project-dir]

const SKIM_HEIGHT = "40%"
const PLAN_DIR = "terragrunt.plan"
const PLAN_FILE = "tfplan.tfplan"

# Return the fixed Terragrunt root.
def units-root [root: path]: nothing -> string {
    let units_dir = $root | path join units
    if not ($units_dir | path exists) {
        fail $"The units directory does not exist: ($units_dir). Run prefrio inside a project with a .project.json." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }
    $units_dir
}

# List the units below the units directory as paths relative to it.
def unit-names [units_dir: path]: nothing -> list<string> {
    glob ($units_dir | path join "**/terragrunt.hcl") --no-dir --exclude ["**/.terragrunt-cache/**" "**/.terraform/**"]
    | each {|file| $file | path dirname | path relative-to $units_dir }
    | where $it != ""
    | sort
}

# List the <module>/<environment> units that match the selectors, failing when none do.
def candidate-units [units_dir: path, selection: record]: nothing -> list<string> {
    let environment = $selection.environment
    let module = $selection.module
    let all_units = unit-names $units_dir
    if ($all_units | is-empty) {
        fail $"No terragrunt.hcl found under ($units_dir)." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }

    let in_environment = if $environment == null { $all_units } else {
        $all_units | where {
            let parts = $in | path split
            ($parts | length) == 2 and $parts.1? == $environment
        }
    }
    if ($in_environment | is-empty) {
        fail $"No unit belongs to the ($environment) environment under ($units_dir)." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }

    let matching = if $module == null { $in_environment } else {
        $in_environment | where $it == $module or ($it | path split | first) == $module
    }
    if ($matching | is-empty) {
        let scope = if $environment == null { $"under ($units_dir)" } else { $"in the ($environment) environment" }
        fail $"($module) is not a unit or module ($scope). Available: ($in_environment | str join ', ')." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }
    $matching
}

# Pick one item with skim; null when nothing is chosen, fail when the plugin is missing.
def pick-one [prompt: string, missing_plugin_hint: string]: list<string> -> oneof<string, nothing> {
    let items = $in
    if (scope commands | where name == sk | is-empty) {
        fail $"The skim plugin is not loaded. ($missing_plugin_hint)" {
            command: picker
            span: (metadata $prompt).span
        }
    }

    let choice = try {
        $items | sk --height $SKIM_HEIGHT --prompt $prompt | default null
    } catch {
        null
    }
    if $choice == "" { null } else { $choice }
}

# Remove the saved plans, reporting a useful error.
def clear-plans [plans: path]: nothing -> nothing {
    try { rm --recursive --force $plans } catch {|err| fail $"Could not remove the saved plans in ($plans): ($err.msg)" {
            command: plan
            span: (metadata $plans).span
        } }
}

# Plan the chosen units with Terragrunt, saving the plans in the plan directory.
def run-plan [selection: record, ...extra: string]: nothing -> nothing {
    let units_dir = units-root (project-root)
    let plans = $units_dir | path join $PLAN_DIR
    let candidates = candidate-units $units_dir $selection
    let narrowed = $selection.module != null or $selection.environment != null
    let chosen = if $selection.all or ($candidates | length) == 1 {
        $candidates
    } else {
        let choice = $candidates | pick-one "unit> " "Pass --all or --module NAME."
        if $choice == null {
            fail "No unit selected. Pass --all or --module NAME." {
                command: terragrunt
                span: (metadata $units_dir).span
            }
        }
        [$choice]
    }
    let filters = if $selection.all and not $narrowed { [] } else {
        $chosen | each {|unit| [--filter $"./($unit)"] } | flatten
    }

    clear-plans $plans
    run-command terragrunt ...[
        run
        --all
        --working-dir
        $units_dir
        --out-dir
        $plans
        ...$filters
        --
        plan
        ...$extra
    ]
    log info "Terragrunt plan completed"
}

# Check the inputs, then validate the chosen units with OpenTofu.
def run-validate [selection: record]: nothing -> nothing {
    let units_dir = units-root (project-root)
    let candidates = candidate-units $units_dir $selection
    let narrowed = $selection.module != null or $selection.environment != null
    let filters = if $narrowed {
        $candidates | each {|unit| [--filter $"./($unit)"] } | flatten
    } else { [] }

    run-command terragrunt ...[
        hcl
        validate
        --working-dir
        $units_dir
        --inputs
        --strict
        ...$filters
    ]
    run-command terragrunt ...[
        run
        --all
        --working-dir
        $units_dir
        ...$filters
        --
        validate
    ]
    log info "Terragrunt validate completed"
}

# Choose one SOPS variables file with a compact fuzzy finder.
def choose-tfvars-file [root: path]: nothing -> oneof<string, nothing> {
    let files = glob ($root | path join "**/*.tfvars.sops.json") --no-dir --exclude ["**/.terragrunt-cache/**" "**/.terraform/**"] | sort
    match ($files | length) {
        0 => {
            fail $"No *.tfvars.sops.json files found under ($root)." {
                command: edit-vars
                span: (metadata $root).span
            }
        }
        1 => {
            $files | first
        }
        _ => {
            let choice = $files | path relative-to $root | pick-one "tfvars> " "Pass a file path or run prefrio from the Nix package."
            if $choice == null { null } else {
                $root | path join $choice
            }
        }
    }
}

# Initialize every Terragrunt unit.
export def "main tf init" [...extra: string]: nothing -> nothing {
    let units_dir = units-root (project-root)
    run-command terragrunt ...[
        run
        --all
        --working-dir
        $units_dir
        --
        init
        -reconfigure
        ...$extra
    ]
    log info "Terragrunt init completed"
}

# Plan one unit by default, or every unit with --all. --module and --environment narrow the units (--module gcp --environment stg is gcp/stg), and --all takes every unit left. Plans are saved in units/terragrunt.plan.
export def "main tf plan" [
    --all(-a)
    --module(-m): string
    --environment(-e): string
    ...extra: string
]: nothing -> nothing {
    let selection = {
        all: $all
        module: (
            if $module == null { null } else {
                $module | str trim
            }
        )
        environment: (
            if $environment == null { null } else {
                $environment | str trim
            }
        )
    }

    run-plan $selection ...$extra
}

# Check the inputs and validate the units. --module and --environment narrow the units; without them every unit is checked.
export def "main tf validate" [--module(-m): string, --environment(-e): string]: nothing -> nothing {
    let selection = {
        module: (
            if $module == null { null } else {
                $module | str trim
            }
        )
        environment: (
            if $environment == null { null } else {
                $environment | str trim
            }
        )
    }

    run-validate $selection
}

# Run tfsec with the central config on every project that owns one of the given files, or on the current project without files. Every project is scanned before the command fails.
export def "main tf scan" [...files: string]: nothing -> nothing {
    let span = (metadata $files).span

    if ($env.TF_LIB? | is-empty) {
        fail "TF_LIB is not set. Run prefrio inside the infra devenv, which provides the central tfsec config." {command: scan span: $span}
    }

    let config = $env.TF_LIB | path join tfsec.yml
    let dirs = if ($files | is-empty) {
        [
            (pwd)
        ]
    } else {
        $files | path expand | path dirname
    }

    let projects = $dirs | each {|dir| find-project-dir $dir } | where $it != null | uniq

    if ($files | is-empty) and ($projects | is-empty) {
        fail $"No .project.json found in (pwd) or any parent directory. Run prefrio inside a project." {command: scan span: $span}
    }

    let base = pwd | path expand
    let failed = $projects
    | each {|project| try { $project | path relative-to $base | default --empty . } catch { $project } }
    | where { try { tfsec --no-color --concise-output --ignore-hcl-errors --config-file $config $in; false } catch { true } }

    if ($failed | is-not-empty) {
        fail $"tfsec reported problems in: ($failed | str join ', ')" {command: scan span: $span}
    }
}

# Apply the saved plans. Selectors are not accepted here.
export def "main tf apply" []: nothing -> nothing {
    let units_dir = units-root (project-root)
    let plans = $units_dir | path join $PLAN_DIR
    let units = glob ($plans | path join $"**/($PLAN_FILE)") --no-dir
    | each {|file| $file | path dirname | path relative-to $plans }
    | sort

    if ($units | is-empty) {
        fail $"No saved plans under ($plans). Run prefrio tf plan first." {
            command: apply
            span: (metadata $plans).span
        }
    }

    let filters = $units | each {|unit| [--filter $"./($unit)"] } | flatten
    log info $"Applying: ($units | str join ', ')"
    let approval = if ($env.TF_AUTO_APPROVE? | is-empty) { [] } else { [--non-interactive] }

    run-command terragrunt ...[
        run
        --all
        --working-dir
        $units_dir
        --out-dir
        $plans
        ...$approval
        ...$filters
        --
        apply
    ]
    clear-plans $plans
    log info "Terragrunt apply completed"
}

# Edit a SOPS variables file.
export def "main tf edit-vars" [file?: path]: nothing -> nothing {
    let root = project-root
    let sops_file = if $file != null {
        $file | path expand
    } else { choose-tfvars-file $root }
    if $sops_file == null {
        log info "No variables file selected"
        return
    }
    if not (is-file $sops_file) {
        fail $"SOPS variables file not found: ($sops_file)." {
            command: edit-vars
            span: (metadata $sops_file).span
        }
    }
    let result = run-command --allow-exit-code 200 sops ...[edit $sops_file]
    if $result.exit_code == 200 {
        log info "No variable changes to save"
        return
    }
    log info "Variables file edited"
}

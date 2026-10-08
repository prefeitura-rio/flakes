use std/log
use ./lib.nu [run-command fail is-file project-root]

const SKIM_HEIGHT = "40%"
const PLAN_DIR = "terragrunt.plan"
const PLAN_FILE = "tfplan.tfplan"

# Return the fixed Terragrunt root.
def units-root [root: path]: nothing -> string {
    let units_dir = $root | path join units
    if not ($units_dir | path exists) {
        fail $"The units directory does not exist: ($units_dir). Run prefrio inside a project with a .project.nuon." {
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
    | where {|name| $name != "" }
    | sort
}

# Keep the units of an environment. A unit is <module>/<environment>, so the environment is the second folder.
def units-of-environment [units: list<string>, environment: oneof<string, nothing>]: nothing -> list<string> {
    if $environment == null { return $units }
    $units | where {|name|
        let parts = $name | path split
        ($parts | length) == 2 and $parts.1? == $environment
    }
}

# Keep the units that are the module itself or sit inside the module folder.
def units-of-module [units: list<string>, module: oneof<string, nothing>]: nothing -> list<string> {
    if $module == null { return $units }
    $units | where {|name| $name == $module or ($name | path split | first) == $module }
}

# List the units that match the environment and module selectors, failing when none do.
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

    let in_environment = units-of-environment $all_units $environment
    if ($in_environment | is-empty) {
        fail $"No unit belongs to the ($environment) environment under ($units_dir)." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }

    let matching = units-of-module $in_environment $module
    if ($matching | is-empty) {
        let scope = if $environment == null { $"under ($units_dir)" } else { $"in the ($environment) environment" }
        fail $"($module) is not a unit or module ($scope). Available: ($in_environment | str join ', ')." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }
    $matching
}

# Pick one of the candidate units: the only one, or the choice made in a picker.
def pick-unit [units_dir: path]: list<string> -> string {
    let units = $in
    if ($units | length) == 1 {
        return ($units | first)
    }

    if (scope commands | where name == sk | is-empty) {
        fail "The skim plugin is not loaded. Pass --all or --module NAME." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }

    let choice = try {
        $units | sk --height $SKIM_HEIGHT --prompt "unit> " | default null
    } catch {
        null
    }

    if $choice == null or $choice == "" {
        fail "No unit selected. Pass --all or --module NAME." {
            command: terragrunt
            span: (metadata $units_dir).span
        }
    }
    $choice
}

# Remove the saved plans, reporting a useful error.
def clear-plans [plans: path]: nothing -> nothing {
    try { rm --recursive --force $plans } catch {|err| fail $"Could not remove the saved plans in ($plans): ($err.msg)" {
            command: plan
            span: (metadata $plans).span
        } }
}

# Initialize every unit.
def run-init [...extra: string]: nothing -> nothing {
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

# Plan the chosen units with Terragrunt, saving the plans in the plan directory.
def run-plan [selection: record, ...extra: string]: nothing -> nothing {
    let units_dir = units-root (project-root)
    let plans = $units_dir | path join $PLAN_DIR
    let candidates = candidate-units $units_dir $selection
    let narrowed = $selection.module != null or $selection.environment != null
    let chosen = if $selection.all { $candidates } else { [($candidates | pick-unit $units_dir)] }
    let filters = if $selection.all and not $narrowed { [] } else { $chosen | each {|unit| [--filter $"./($unit)"] } | flatten }

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

# Apply the units that have a saved plan. The plan directory records what was planned.
def run-apply []: nothing -> nothing {
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
            if (scope commands | where name == sk | is-empty) {
                fail "The skim plugin is not loaded. Pass a file path or run prefrio from the Nix package." {
                    command: edit-vars
                    span: (metadata $root).span
                }
            }
            let choice = $files | path relative-to $root | sk --height $SKIM_HEIGHT --prompt "tfvars> " | default null
            if $choice == null { null } else {
                $root | path join $choice
            }
        }
    }
}

# Initialize every Terragrunt unit.
export def "main tf init" [...extra: string]: nothing -> nothing {
    run-init ...$extra
}

# Plan one unit by default, or every unit with --all. --module and --environment narrow the units (--module gcp --environment stg is gcp/stg), and --all takes every unit left. Plans are saved in units/terragrunt.plan.
export def "main tf plan" [--all(-a), --module(-m): string, --environment(-e): string, ...extra: string]: nothing -> nothing {
    let selection = {
        all: $all
        module: (if $module == null { null } else { $module | str trim })
        environment: (if $environment == null { null } else { $environment | str trim })
    }

    run-plan $selection ...$extra
}

# Apply the saved plans. Selectors are not accepted here.
export def "main tf apply" []: nothing -> nothing {
    run-apply
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

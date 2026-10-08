use std/log
use ./lib.nu [run-command fail is-file project-root]

const SKIM_HEIGHT = "40%"
const PLAN_DIR = "terragrunt.plan"
const PLAN_FILE = "tfplan.tfplan"

# Return the fixed Terragrunt root.
def live-root [root: path]: nothing -> string {
    let live = $root | path join live
    if not ($live | path exists) {
        fail $"The live module root does not exist: ($live). Run prefrio inside a project with a .project.nuon." {
            command: terragrunt
            span: (metadata $live).span
        }
    }
    $live
}

# List the units below the live root as paths relative to it.
def unit-names [live: path]: nothing -> list<string> {
    glob ($live | path join "**/terragrunt.hcl") --no-dir --exclude ["**/.terragrunt-cache/**" "**/.terraform/**"]
    | each {|file| $file | path dirname | path relative-to $live }
    | where {|name| $name != "" }
    | sort
}

# Choose one unit: the --mod value, the only unit present, or a picker.
def select-unit [live: path, unit: oneof<string, nothing>]: nothing -> string {
    let units = unit-names $live
    if ($units | is-empty) {
        fail $"No terragrunt.hcl found under ($live)." {
            command: terragrunt
            span: (metadata $live).span
        }
    }

    if $unit != null {
        if $unit not-in $units {
            fail $"($unit) is not a unit under ($live). Available: ($units | str join ', ')." {
                command: terragrunt
                span: (metadata $unit).span
            }
        }
        return $unit
    }

    if ($units | length) == 1 {
        return ($units | first)
    }

    if (scope commands | where name == sk | is-empty) {
        fail "The skim plugin is not loaded. Pass --all or --mod NAME." {
            command: terragrunt
            span: (metadata $live).span
        }
    }

    let choice = try {
        $units | sk --height $SKIM_HEIGHT --prompt "unit> " | default null
    } catch {
        null
    }

    if $choice == null or $choice == "" {
        fail "No unit selected. Pass --all or --mod NAME." {
            command: terragrunt
            span: (metadata $live).span
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
    let live = live-root (project-root)
    run-command terragrunt ...[
        run
        --all
        --working-dir
        $live
        --
        init
        -reconfigure
        ...$extra
    ]
    log info "Terragrunt init completed"
}

# Plan the chosen units with Terragrunt, saving the plans in the plan directory.
def run-plan [all: bool, unit: oneof<string, nothing>, ...extra: string]: nothing -> nothing {
    if $all and $unit != null {
        fail "Use either --all or --mod, not both." {
            command: plan
            span: (metadata $unit).span
        }
    }

    let live = live-root (project-root)
    let plans = $live | path join $PLAN_DIR
    let filters = if $all { [] } else { [--filter $"./(select-unit $live $unit)"] }

    clear-plans $plans
    run-command terragrunt ...[
        run
        --all
        --working-dir
        $live
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
    let live = live-root (project-root)
    let plans = $live | path join $PLAN_DIR
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
    let approval = if ($env.TF_AUTO_APPROVE? | is-empty) { [] } else { [--non-interactive] }

    run-command terragrunt ...[
        run
        --all
        --working-dir
        $live
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

# Plan one unit by default, or every unit with --all. Plans are saved in live/terragrunt.plan.
export def "main tf plan" [--all, --mod(-m): string, ...extra: string]: nothing -> nothing {
    let unit = if $mod == null { null } else {
        $mod | str trim
    }

    run-plan $all $unit ...$extra
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

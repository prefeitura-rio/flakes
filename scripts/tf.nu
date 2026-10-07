use std/log
use ./lib.nu [run-command fail is-file]

const SKIM_HEIGHT = "40%"

# Find the Git repository root, or use the current directory outside a repository.
def project-root []: nothing -> path {
    let result = do { git rev-parse --show-toplevel } | complete
    if $result.exit_code == 0 { $result.stdout | str trim } else { pwd | path expand }
}

# Return the fixed Terragrunt root.
def live-root [root: path]: nothing -> path {
    let live = $root | path join live
    if not ($live | path exists) {
        fail $"The live module root does not exist: ($live)." {
            command: terragrunt
            span: (metadata $live).span
        }
    }
    $live
}

# List the Terragrunt units under the live root, with a name for the picker.
def discover-units [working_dir: path]: nothing -> list<record> {
    glob ($working_dir | path join "**/terragrunt.hcl") --no-dir --exclude ["**/.terragrunt-cache/**" "**/.terraform/**"]
    | each {|path|
        let dir = ($path | path dirname)
        let relative = $dir | path relative-to $working_dir
        {
            name: (if $relative == "" { $dir | path basename } else { $relative })
            dir: $dir
        }
    }
    | sort-by name
}

# Choose one unit: the --unit value, the only unit present, or a picker.
def select-unit [working_dir: path, unit: oneof<string, nothing>]: nothing -> record {
    let units = (discover-units $working_dir)
    if ($units | is-empty) {
        fail $"No terragrunt.hcl found under ($working_dir)." {
            command: terragrunt
            span: (metadata $working_dir).span
        }
    }

    if $unit != null {
        let chosen = $units | where name == $unit
        if ($chosen | is-empty) {
            fail $"($unit) is not a unit under ($working_dir). Available: ($units.name | str join ', ')." {
                command: terragrunt
                span: (metadata $unit).span
            }
        }
        return ($chosen | first)
    }

    if ($units | length) == 1 {
        return ($units | first)
    }

    if (scope commands | where name == sk | is-empty) {
        fail "The skim plugin is not loaded. Pass --all or --unit NAME." {
            command: terragrunt
            span: (metadata $working_dir).span
        }
    }

    let choice = (try {
        $units.name | sk --height $SKIM_HEIGHT --prompt "unit> " | default null
    } catch {
        null
    })

    if $choice == null or $choice == "" {
        fail "No unit selected. Pass --all or --unit NAME." {
            command: terragrunt
            span: (metadata $working_dir).span
        }
    }
    $units | where name == $choice | first
}

# Write a plan manifest only after its plan command succeeds.
def write-manifest [live: path, manifest: record]: nothing -> nothing {
    let directory = $live | path join terragrunt.plan
    try {
        mkdir $directory
        ($manifest | to nuon) | save --force ($directory | path join prefrio.nuon)
    } catch {|err|
        fail $"Could not write the plan manifest: ($err.msg)" {
            command: plan
            span: (metadata $directory).span
        }
    }
}

# Read and validate the last successful plan manifest.
def read-manifest [live: path]: nothing -> record {
    let path = $live | path join terragrunt.plan prefrio.nuon
    if not (is-file $path) {
        fail $"Plan manifest not found: ($path). Run prefrio tf plan first." {
            command: apply
            span: (metadata $path).span
        }
    }
    try {
        open $path
    } catch {|err|
        fail $"Could not read the plan manifest: ($err.msg)" {
            command: apply
            span: (metadata $path).span
        }
    }
}

# Build approval flags for an apply.
def approval-flags []: nothing -> list<string> {
    match ($env.TF_AUTO_APPROVE? | default null) {
        null | "" => []
        _ => [--non-interactive]
    }
}

# Run Terragrunt for all units, one unit, or the manifest-selected plan.
def run-terragrunt [options: record, ...extra: string]: nothing -> nothing {
    let root = project-root
    let live = live-root $root
    let action = $options.action

    if $action == plan and $options.all and $options.unit != null {
        fail "Use either --all or --mod, not both." {
            command: plan
            span: (metadata $options.unit).span
        }
    }

    if $action == init {
        let args = [
            run
            --all
            --working-dir
            $live
            --
            init
            -reconfigure
            ...$extra
        ]
        run-command terragrunt ...$args
        log info "Terragrunt init completed"
        return
    }

    if $action == apply {
        if ($extra | is-not-empty) {
            fail "tf apply takes no selectors. It applies the last generated plan." {
                command: apply
                span: (metadata $action).span
            }
        }
        let manifest = read-manifest $live
        let scope = $manifest.scope? | default null
        let args = if $scope == all {
            let plan_dir = $root | path join ($manifest.plan_dir? | default live/terragrunt.plan)
            if not ($plan_dir | path exists) {
                fail $"Plan directory not found: ($plan_dir). Run prefrio tf plan first." {
                    command: apply
                    span: (metadata $plan_dir).span
                }
            }
            [
                run
                --all
                --working-dir
                $live
                --out-dir
                $plan_dir
                ...(approval-flags)
                --
                apply
            ]
        } else if $scope == unit {
            let unit_name = $manifest.unit? | default null
            let unit = if $unit_name == null {
                fail "The plan manifest has no unit." {
                    command: apply
                    span: (metadata $manifest).span
                }
            } else {
                let units = discover-units $live | where name == $unit_name
                if ($units | is-empty) {
                    fail $"Manifest unit not found under ($live): ($unit_name)." {
                        command: apply
                        span: (metadata $unit_name).span
                    }
                }
                $units | first
            }
            let plan = $manifest.plan? | default null
            if $plan == null {
                fail "The plan manifest has no plan file." {
                    command: apply
                    span: (metadata $manifest).span
                }
            }
            let plan_file = $root | path join $plan
            if not (is-file $plan_file) {
                fail $"Plan file not found: ($plan_file). Run prefrio tf plan first." {
                    command: apply
                    span: (metadata $plan_file).span
                }
            }
            [
                run
                --working-dir
                $unit.dir
                --
                apply
                ...(if (approval-flags | is-not-empty) { [-auto-approve] } else { [] })
                $plan_file
            ]
        } else {
            fail "The plan manifest has an invalid scope. Run prefrio tf plan again." {
                command: apply
                span: (metadata $manifest).span
            }
        }
        run-command terragrunt ...$args
        log info "Terragrunt apply completed"
        return
    }

    let all = $options.all
    let unit = if $all { null } else { select-unit $live $options.unit }
    let plan_dir = $live | path join terragrunt.plan
    try { rm --recursive --force $plan_dir } catch {|err|
        fail $"Could not remove old plans in ($plan_dir): ($err.msg)" {
            command: plan
            span: (metadata $plan_dir).span
        }
    }

    let args = if $all {
        [
            run
            --all
            --working-dir
            $live
            --out-dir
            $plan_dir
            --
            plan
            ...$extra
        ]
    } else {
        let plan_file = $plan_dir | path join $"(($unit.name | split row / | str join -)).tfplan"
        try { mkdir $plan_dir } catch {|err|
            fail $"Could not prepare ($plan_dir): ($err.msg)" {
                command: plan
                span: (metadata $plan_dir).span
            }
        }
        [
            run
            --working-dir
            $unit.dir
            --
            plan
            $"-out=($plan_file)"
            ...$extra
        ]
    }
    run-command terragrunt ...$args

    if $all {
        write-manifest $live {
            scope: all
            working_dir: live
            plan_dir: live/terragrunt.plan
        }
    } else {
        write-manifest $live {
            scope: unit
            working_dir: live
            unit: $unit.name
            plan: $"live/terragrunt.plan/(($unit.name | split row / | str join -)).tfplan"
        }
    }
    log info "Terragrunt plan completed"
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
        1 => { $files | first }
        _ => {
            if (scope commands | where name == sk | is-empty) {
                fail "The skim plugin is not loaded. Pass a file path or run prefrio from the Nix package." {
                    command: edit-vars
                    span: (metadata $root).span
                }
            }
            let choice = $files | path relative-to $root | sk --height $SKIM_HEIGHT --prompt "tfvars> " | default null
            if $choice == null { null } else { $root | path join $choice }
        }
    }
}

# Initialize every Terragrunt unit.
export def "main tf init" [...extra: string]: nothing -> nothing {
    run-terragrunt {action: init} ...$extra
}

# Plan one unit by default, or every unit with --all.
export def "main tf plan" [--all, --mod(-m): string, ...extra: string]: nothing -> nothing {
    let unit = if $mod == null { null } else { $mod | str trim }
    run-terragrunt {action: plan, all: $all, unit: $unit} ...$extra
}

# Apply the last generated plan. Selectors are not accepted here.
export def "main tf apply" []: nothing -> nothing {
    run-terragrunt {action: apply}
}

# Edit a SOPS variables file.
export def "main tf edit-vars" [file?: path]: nothing -> nothing {
    let root = project-root
    let sops_file = if $file != null { $file | path expand } else { choose-tfvars-file $root }
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

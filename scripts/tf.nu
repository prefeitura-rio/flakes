use std/log
use ./lib.nu [run-command fail is-file]

# Find the Git repository root, or use the current directory outside a repository.
def project-root []: nothing -> path {
    let result = do { git rev-parse --show-toplevel } | complete
    if $result.exit_code == 0 { $result.stdout | str trim } else { pwd | path expand }
}

# Resolve the directory where Terragrunt runs from the required TG_WORKING_DIR variable.
# A relative value is resolved from the Git repository root.
def resolve-working-dir [root: path]: nothing -> path {
    let value = $env.TG_WORKING_DIR? | default null
    if $value == null or $value == "" {
        fail "Set TG_WORKING_DIR to the directory where Terragrunt should run." {
            command: terragrunt
            span: (metadata $value).span
        }
    }

    let directory = $root | path join $value | path expand
    if not ($directory | path exists) {
        fail $"TG_WORKING_DIR does not exist: ($directory)." {
            command: terragrunt
            span: (metadata $directory).span
        }
    }
    $directory
}

# Run one action across every Terragrunt unit below TG_WORKING_DIR.
# Plans are saved per unit under terragrunt.plan there; apply uses them. Terragrunt asks once before apply and destroy.
def run-terragrunt [action: string, ...extra: string]: nothing -> nothing {
    let working_dir = resolve-working-dir (project-root)
    let plan_dir = $working_dir | path join terragrunt.plan
    if $action == apply and not ($plan_dir | path exists) {
        fail $"Terragrunt plan not found: ($plan_dir). Run prefrio tf plan first." {
            command: apply
            span: (metadata $plan_dir).span
        }
    }

    if $action == plan {
        try { rm --recursive --force $plan_dir } catch {|err| fail $"Could not remove old plans in ($plan_dir): ($err.msg)" {
                command: plan
                span: (metadata $plan_dir).span
            } }
    }

    let approval = match ($env.TF_AUTO_APPROVE? | default null) {
        null | "" => []
        _ => [--non-interactive]
    }

    let args = [
        run
        --all
        --working-dir
        $working_dir
        ...(if $action in [plan apply] { [--out-dir $plan_dir] } else { [] })
        ...(if $action in [apply destroy] { $approval } else { [] })
        --
        $action
        ...(if $action == init { [-reconfigure] } else { [] })
        ...$extra
    ]
    run-command terragrunt ...$args
    log info $"Terragrunt ($action) completed"
}

# Choose one SOPS variables file with a fuzzy finder.
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
                fail "The skim plugin is not loaded. Pass the file path or run prefrio from the Nix package." {
                    command: edit-vars
                    span: (metadata $root).span
                }
            }
            let choice = $files | path relative-to $root | sk --prompt "tfvars> " | default null
            if $choice == null { null } else {
                $root | path join $choice
            }
        }
    }
}

# Initialize every Terragrunt unit.
export def "main tf init" [...extra: string]: nothing -> nothing {
    run-terragrunt init ...$extra
}

# Plan every Terragrunt unit and save the plans.
export def "main tf plan" [...extra: string]: nothing -> nothing {
    run-terragrunt plan ...$extra
}

# Apply the saved plans of every Terragrunt unit.
export def "main tf apply" [...extra: string]: nothing -> nothing {
    run-terragrunt apply ...$extra
}

# Destroy every Terragrunt unit.
export def "main tf destroy" [...extra: string]: nothing -> nothing {
    run-terragrunt destroy ...$extra
}

# Edit a SOPS variables file. Without a path, choose one of the project files with a fuzzy finder.
export def "main tf edit-vars" [file?: path]: nothing -> nothing {
    let sops_file = if $file != null {
        $file | path expand
    } else { choose-tfvars-file (project-root) }

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

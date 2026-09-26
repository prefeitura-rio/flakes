# nu-lint-ignore-file: max_positional_params

use std/log
use ./lib.nu [run-command fail is-file run-with-sops]
use ./project.nu [load-project-config]

# Resolve Terraform files and optional kubeconfig inputs.
def resolve-inputs [config: record]: nothing -> record {
    let tf = $config | get tf
    let tfdir = $tf | get dir
    let vars = $tf | get vars
    let variables = $vars | get --optional plain | default ($vars | get --optional sops | default null)
    let sops_file = $vars | get --optional sops | default null
    let variables = if $variables == null or ($variables | path type) == absolute {
        $variables
    } else {
        $tfdir | path join $variables
    }
    let k3s = $config.k3s? | default {}
    let kubeconfig_value = $k3s.kubeconfig? | default null
    let kubeconfig = if $kubeconfig_value == null { null } else {
        $kubeconfig_value | path expand
    }
    if $variables != null and not (is-file $variables) {
        fail $"Terraform variables file not found: ($variables)." {
            command: terraform
            span: (metadata $variables).span
        }
    }
    if $kubeconfig != null and not (is-file $kubeconfig) {
        fail $"Terraform kubeconfig file not found: ($kubeconfig)." {
            command: terraform
            span: (metadata $kubeconfig).span
        }
    }
    let secrets = {}
    | if $sops_file != null { upsert tfvars $variables } else { }
    | if $kubeconfig != null { upsert kubeconfig $kubeconfig } else { }
    {
        directory: $tfdir
        variables: $variables
        kubeconfig: $kubeconfig
        secrets: $secrets
    }
}

# Build arguments for a variables file.
def build-variable-args [files: record, inputs: record]: nothing -> list<string> {
    let tfvars = $files | get --optional tfvars | default $inputs.variables
    if $tfvars == null { [] } else { [$"-var-file=($tfvars)"] }
}

# Build arguments for an optional kubeconfig.
def build-kubeconfig-args [files: record, inputs: record]: nothing -> list<string> {
    let kubeconfig = $files | get --optional kubeconfig | default $inputs.kubeconfig
    if $kubeconfig == null { [] } else { [$"-var=kubeconfig_path=($kubeconfig)"] }
}

# Build action-specific Terraform arguments.
def build-approval-args [action: string]: nothing -> list<string> {
    if $action != apply { return [] }
    match ($env.TF_AUTO_APPROVE? | default null) {
        null | "" => []
        _ => [--auto-approve]
    }
}

# Build all Terraform arguments from one execution context.
def build-terraform-args [context: record]: nothing -> list<string> {
    let inputs = $context.inputs
    [
        ...[$"-chdir=($inputs.directory)" $context.action]
        ...(build-variable-args $context.files $inputs)
        ...(build-kubeconfig-args $context.files $inputs)
        ...(if $context.config.environment != null {
        [$"-var=environment=($context.config.environment)"]
    } else { [] })
        ...(match $context.action {
        plan => {
            [$"-out=($context.config.tf.plan_file)"]
        }
        apply => [$context.config.tf.plan_file]
        _ => []
    })
        ...(build-approval-args $context.action)
        ...$context.extra
    ]
}

# Execute Terraform with an optional KUBECONFIG.
def run-tofu [context: record]: nothing -> record {
    let args = build-terraform-args $context
    let kubeconfig = $context.files | get --optional kubeconfig | default $context.inputs.kubeconfig
    with-env (if $kubeconfig == null { {} } else { {KUBECONFIG: $kubeconfig} }) {
        run-command tofu ...$args
    }
}

# Run one Terraform action with optional SOPS variables and kubeconfig credentials.
def run-terraform-action [action: string, ...extra: string]: nothing -> nothing {
    let config = load-project-config
    let inputs = resolve-inputs $config
    let context = {
        action: $action
        config: $config
        inputs: $inputs
        extra: $extra
    }
    if ($inputs.secrets | is-empty) {
        run-tofu ($context | insert files {})
    } else {
        run-with-sops $inputs.secrets {|files|
            run-tofu ($context | insert files $files)
        }
    }
    log info $"Terraform ($action) completed"
}

# Run Terraform plan.
export def "main tf plan" [...extra: string]: nothing -> nothing {
    run-terraform-action plan ...$extra
}

# Run Terraform apply.
export def "main tf apply" [...extra: string]: nothing -> nothing {
    run-terraform-action apply ...$extra
}

# Destroy Terraform resources.
export def "main tf destroy" [...extra: string]: nothing -> nothing {
    run-terraform-action destroy ...$extra
}

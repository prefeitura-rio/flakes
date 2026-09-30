# nu-lint-ignore-file: dispatch_with_subcommands

use std/log
use ./lib.nu [run-command fail is-file run-with-sops]
use ./project.nu [load-project-config]

const TAILNET_NAME = "squirrel-regulus.ts.net"
const TAILSCALE_HOST = $"tailscale-operator-onprem.($TAILNET_NAME)"

# Check that Tailscale is connected to the expected tailnet.
def validate-tailscale []: nothing -> nothing {
    let status = try {
        run-command --quiet tailscale ...[status --json]
        | get stdout
        | from json
    } catch {
        fail $"Tailscale is not connected to ($TAILNET_NAME). Run `tailscale up` and retry." {
            command: validate-tailscale
            span: (metadata $TAILNET_NAME).span
        }
    }

    let dns_name = $status
    | get Self.DNSName --optional
    | default unknown
    | str trim --right --char .

    if not ($dns_name | str ends-with $TAILNET_NAME) {
        fail $"Tailscale is not connected to ($TAILNET_NAME). Run `tailscale up` and retry." {
            command: validate-tailscale
            span: (metadata $dns_name).span
        }
    }

    log info $"Connected to ($TAILNET_NAME)"
}

# Prepare the encrypted K3s kubeconfig directory.
def prepare-kubeconfig-directory []: nothing -> string {
    let directory = $env.K3S_SOPS_DIR? | default .k3s | path expand
    try { mkdir $directory } catch {|err| fail $"Could not create the K3s SOPS directory: ($directory): ($err.msg)" {
            command: prepare-kubeconfig-directory
            span: (metadata $directory).span
        } }
    $directory
}

# Generate a plaintext kubeconfig in a temporary path.
def generate-kubeconfig [path: path]: nothing -> nothing {
    log info $"Generating a temporary kubeconfig through ($TAILSCALE_HOST)"
    with-env {KUBECONFIG: $path} {
        run-command tailscale ...[configure kubeconfig $TAILSCALE_HOST]
    }
    if not (is-file $path) {
        fail "Tailscale did not create a kubeconfig in the temporary directory." {
            command: generate-kubeconfig
            span: (metadata $path).span
        }
    }
}

# Encrypt and verify a temporary kubeconfig.
def encrypt-and-verify-kubeconfig [paths: record]: nothing -> nothing {
    run-command sops ...[
        encrypt
        --input-type
        yaml
        --output-type
        yaml
        --filename-override
        $paths.destination
        --output
        $paths.encrypted
        $paths.plaintext
    ]
    if not (is-file $paths.encrypted) {
        fail $"Failed to encrypt the K3s kubeconfig at ($paths.destination)." {
            command: encrypt-and-verify-kubeconfig
            span: (metadata $paths.destination).span
        }
    }
    run-with-sops {kubeconfig: $paths.encrypted} {|files|
        with-env {KUBECONFIG: $files.kubeconfig} {
            run-command kubectl ...[get nodes]
        }
    }
}

# Generate, encrypt and verify the K3s kubeconfig through Tailscale.
export def "main k3s get-kubeconfig" []: nothing -> nothing {
    validate-tailscale

    let sops_dir = prepare-kubeconfig-directory
    let destination = $sops_dir | path join kubeconfig.sops.yaml
    let temp_dir = (run-command --quiet mktemp ...[--directory]).stdout | str trim
    let temp = {
        plaintext: ($temp_dir | path join kubeconfig)
        encrypted: ($sops_dir | path join $".kubeconfig.sops.(random uuid).yaml")
    }
    try {
        generate-kubeconfig $temp.plaintext
        encrypt-and-verify-kubeconfig {destination: $destination, plaintext: $temp.plaintext, encrypted: $temp.encrypted}
        mv --force $temp.encrypted $destination
        log info $"K3s kubeconfig encrypted at ($destination); kubectl get nodes succeeded"
    } finally {
        rm --force $temp.plaintext $temp.encrypted
        rm --recursive --force $temp_dir
    }
}

# Run a command with the decrypted K3s kubeconfig injected as KUBECONFIG.
export def "main k3s run" [command: string, ...args: string]: nothing -> nothing {
    let config = load-project-config
    let kubeconfig = $config.k3s? | default null | get --optional kubeconfig | default null
    if $kubeconfig == null {
        fail "No k3s.kubeconfig found in the project file." {
            command: k3s-run
            span: (metadata $config).span
        }
    }
    if not (is-file $kubeconfig) {
        fail $"K3s kubeconfig file not found: ($kubeconfig)." {
            command: k3s-run
            span: (metadata $kubeconfig).span
        }
    }
    run-with-sops {kubeconfig: $kubeconfig} {|files|
        with-env {KUBECONFIG: $files.kubeconfig} {
            run-command $command ...$args
        }
    }
}

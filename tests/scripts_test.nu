# nu-lint-ignore-file: redundant_nu_subprocess, unused_helper_functions

use std/assert
use std/testing *

const ROOT = path self | path dirname | path dirname
const TF_SCRIPT = $ROOT | path join scripts/tf.nu
const K3S_SCRIPT = $ROOT | path join scripts/k3s.nu
const AUTH_SCRIPT = $ROOT | path join scripts/prefrio.nu
const DECRYPTED_VARIABLES_NAME = "tfvars"
const DECRYPTED_KUBECONFIG_NAME = "kubeconfig"

# Raise a labelled test-fixture error.
def test-error [message: string]: nothing -> error {
    error make {
        msg: $message
        label: {text: test-fixture span: (metadata $message).span}
    }
}

# Parse test-process JSON output.
def parse-json []: string -> record {
    try { from json } catch {|err| test-error $err.msg }
}

# Parse a JSON argument list.
def parse-json-list []: string -> list<string> {
    try { from json } catch {|err| test-error $err.msg }
}

# Read a fixture text file.
def read-text [path: path]: nothing -> string {
    try { open --raw $path } catch {|err| test-error $err.msg }
}

# Write the project files for an isolated fixture.
def write-project-fixture [paths: record]: nothing -> nothing {
    let project = {
        name: smoke
        tf: {dir: terraform}
        env: {
            staging: {
                project: rj-civitas-dev
                vars: terraform.tfvars.sops.json
            }
        }
        "k8s": {cluster: smoke-cluster, region: us-central1}
        k3s: {kubeconfig: .k3s/kubeconfig.sops.yaml}
    }
    write-file ($project | to nuon) ($paths.directory | path join .project.nuon)
    write-file "{}" ($paths.terraform | path join terraform.tfvars.sops.json)
    write-file "" ($paths.kubeconfig | path join kubeconfig.sops.yaml)
}

# Write all fake external commands for an isolated fixture.
def write-fake-tools [bin: path]: nothing -> nothing {
    write-fake-sops ($bin | path join sops)
    write-fake-tofu ($bin | path join tofu)
    write-fake-tailscale ($bin | path join tailscale)
    write-fake-kubectl ($bin | path join kubectl)
    write-fake-gcloud ($bin | path join gcloud)
}

# Create an isolated project fixture with fake external commands.
def make-fixture []: nothing -> record {
    let directory = try { mktemp --directory | str trim } catch {|err| test-error $err.msg }
    let bin = $directory | path join bin
    let terraform = $directory | path join terraform
    let kubeconfig = $directory | path join .k3s
    let tofu_args = $directory | path join tofu-args.json
    let tailscale_args = $directory | path join tailscale-args.json
    let kubectl_args = $directory | path join kubectl-args.json
    let gcloud_args = $directory | path join gcloud-args.json
    let sops_args = $directory | path join sops-args.json
    try {
        mkdir $bin $terraform $kubeconfig
        write-project-fixture {directory: $directory terraform: $terraform kubeconfig: $kubeconfig}
        write-fake-tools $bin
    } catch {|err|
        rm --recursive --force $directory
        test-error $err.msg
    }
    {
        directory: $directory
        bin: $bin
        tofu_args: $tofu_args
        tailscale_args: $tailscale_args
        kubectl_args: $kubectl_args
        gcloud_args: $gcloud_args
        sops_args: $sops_args
        path: ($env.PATH? | default [])
    }
}

# Write a text file and report a useful fixture error.
def write-file [content: string path: path]: nothing -> nothing {
    try { $content | save --force $path } catch {|err|
        test-error $"Could not write fixture file ($path): ($err.msg)"
    }
}

# Write a fake SOPS executable that copies the source to its output or records edit args.
def write-fake-sops [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    if $args.0? == edit {
        $args | to json | save --force $env.SOPS_ARGS_FILE
    } else {
        let output_index = $args | enumerate | where item == \"--output\" | get index | first
        let output = $args | get ($output_index + 1)
        open --raw ($args | last) | save --force $output
    }
}
" $path
    make-executable $path
}

# Write a fake OpenTofu executable that records its arguments.
def write-fake-tofu [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    $args | to json | save --force $env.TOFU_ARGS_FILE
}
" $path
    make-executable $path
}

# Write a fake Tailscale executable for K3s tests.
def write-fake-tailscale [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu --stdin

def --wrapped main [...args: string] {
    if $args == [status --json] {
        print '{\"Self\": {\"DNSName\": \"node.squirrel-regulus.ts.net.\"}}'
    } else if $args == [configure kubeconfig tailscale-operator-onprem.squirrel-regulus.ts.net] {
        let kubeconfig = [\"apiVersion: v1\" \"kind: Config\"] | str join (char newline)
        $kubeconfig | save --force $env.KUBECONFIG
        {args: $args kubeconfig: $env.KUBECONFIG} | to json | save --force $env.TAILSCALE_ARGS_FILE
    } else {
        error make {msg: \"Unexpected Tailscale command.\"}
    }
}
" $path
    make-executable $path
}

# Write a fake kubectl executable for K3s tests.
def write-fake-kubectl [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    let kubeconfig = $env.KUBECONFIG? | default null
    if $kubeconfig == null or not ($kubeconfig | path exists) {
        error make {msg: \"kubectl received no readable KUBECONFIG.\"}
    }
    {args: $args kubeconfig: $kubeconfig} | to json | save --force $env.KUBECTL_ARGS_FILE
    print 'node ready'
}
" $path
    make-executable $path
}

# Write a fake gcloud executable for auth tests.
def write-fake-gcloud [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    let calls = if ($env.GCLOUD_ARGS_FILE | path exists) { open --raw $env.GCLOUD_ARGS_FILE | from json } else { [] }
    $calls | append [$args] | to json | save --force $env.GCLOUD_ARGS_FILE
}
" $path
    make-executable $path
}

# Make a fixture executable.
def make-executable [path: path]: nothing -> nothing {
    let result = chmod +x $path | complete
    if $result.exit_code != 0 { test-error $result.stderr }
}

# Run a module command in an isolated fixture.
def run-module [context: record, ...args: string]: nothing -> record {
    let command = $context.command
    | append $args
    | str join " "
    let source = $"use ($context.module) *; main ($command)"
    with-env {
        PATH: ([$context.fixture.bin] | append $context.fixture.path)
        TOFU_ARGS_FILE: $context.fixture.tofu_args
        TAILSCALE_ARGS_FILE: $context.fixture.tailscale_args
        KUBECTL_ARGS_FILE: $context.fixture.kubectl_args
        GCLOUD_ARGS_FILE: $context.fixture.gcloud_args
        SOPS_ARGS_FILE: $context.fixture.sops_args
    } {
        try {
            cd $context.directory
            nu -c $source | complete
        } catch {|err|
            {exit_code: 1 stdout: "" stderr: $err.msg}
        }
    }
}

# Run prefrio.nu as a script in an isolated fixture.
def run-script [context: record, ...args: string]: nothing -> record {
    let arg_list = $context.command
    | append $args
    | str join " "
    with-env {
        PATH: ([$context.fixture.bin] | append $context.fixture.path)
        TOFU_ARGS_FILE: $context.fixture.tofu_args
        TAILSCALE_ARGS_FILE: $context.fixture.tailscale_args
        KUBECTL_ARGS_FILE: $context.fixture.kubectl_args
        GCLOUD_ARGS_FILE: $context.fixture.gcloud_args
        SOPS_ARGS_FILE: $context.fixture.sops_args
        PREFRIO_WORKDIR: $context.directory
    } {
        try {
            cd ($context.module | path dirname)
            nu ($context.module) ...($arg_list | split row " ") | complete
        } catch {|err|
            {exit_code: 1 stdout: "" stderr: $err.msg}
        }
    }
}

# Remove an isolated project fixture.
def remove-fixture [fixture: record]: nothing -> nothing {
    try { rm --recursive --force $fixture.directory } catch { }
}

# Create one isolated Terraform fixture for each test.
@before-each
def setup []: nothing -> record {
    make-fixture
}

# Remove the fixture after every test.
@after-each
def cleanup []: record -> nothing {
    remove-fixture $in
}

# Verify the Terraform command receives decrypted variables and kubeconfig paths.
@test
def prefrio-tf-plan-builds-expected-tofu-arguments []: record -> nothing {
    let fixture = $in
    let result = with-env {
        K3S_SOPS_DIR: ($fixture.directory | path join .k3s)
        TF_DIR: ($fixture.directory | path join terraform)
    } {
        run-module {fixture: $fixture module: $TF_SCRIPT command: [tf] directory: $fixture.directory} plan
    }

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.tofu_args | parse-json-list
    let terraform_directory = $fixture.directory | path join terraform
    let variable_args = $args | where $it =~ ^-var-file=
    assert ($"-chdir=($terraform_directory)" in $args)
    assert (($variable_args | length) == 1)
    assert (($variable_args.0? | str replace "-var-file=" "" | path basename) == tfvars)
    let kubeconfig_args = $args | where $it =~ ^-var=kubeconfig_path=
    assert (($kubeconfig_args | length) == 1)
    assert (($kubeconfig_args.0? | str replace "-var=kubeconfig_path=" "" | path basename) == kubeconfig)
    assert ("plan" in $args)
}

# Verify an explicit variables file replaces the project default in the full CLI workflow.
@test
def prefrio-tf-plan-uses-explicit-variables-file []: record -> nothing {
    let fixture = $in
    let override = $fixture.directory | path join override.tfvars.json
    write-file "{}" $override
    let result = with-env {TF_VARS_FILE: $override} {
        hide-env --ignore-errors TF_SOPS_FILE
        run-module {fixture: $fixture module: $TF_SCRIPT command: [tf] directory: $fixture.directory} plan
    }

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.tofu_args | parse-json-list
    assert ($"-var-file=($override)" in $args)
    assert (not ($args | any { "terraform.tfvars.sops.json" in $in }))
}

# Verify project discovery from a child directory.
@test
def prefrio-tf-plan-detects-parent-project []: record -> nothing {
    let fixture = $in
    let nested = $fixture.directory | path join terraform modules service
    try { mkdir $nested } catch {|err| test-error $err.msg }
    let result = run-module {fixture: $fixture module: $TF_SCRIPT command: [tf] directory: $nested} plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.tofu_args | parse-json-list
    let terraform_directory = $fixture.directory | path join terraform
    assert ($"-chdir=($terraform_directory)" in $args)
    assert ("-var=environment=staging" in $args)
}

# Verify the complete K3s kubeconfig workflow with isolated fake tools.
@test
def prefrio-k3s-get-kubeconfig-uses-tailscale-sops-workflow []: record -> nothing {
    let fixture = $in
    let sops_directory = $fixture.directory | path join generated-k3s
    let result = with-env {K3S_SOPS_DIR: $sops_directory} {
        run-module {fixture: $fixture module: $K3S_SCRIPT command: [k3s] directory: $fixture.directory} get-kubeconfig
    }

    assert equal $result.exit_code 0 $result.stderr
    let destination = $sops_directory | path join kubeconfig.sops.yaml
    assert ($destination | path exists)
    assert ((read-text $destination) =~ "apiVersion: v1")
    let tailscale = read-text $fixture.tailscale_args | parse-json
    assert (not ($tailscale.kubeconfig | path exists))
    assert ("configure" in $tailscale.args)
    assert ("tailscale-operator-onprem.squirrel-regulus.ts.net" in $tailscale.args)
    let kubectl = read-text $fixture.kubectl_args | parse-json
    assert ("get" in $kubectl.args)
    assert ("nodes" in $kubectl.args)
    assert (not ($kubectl.kubeconfig | path exists))
}

# Verify the auth command runs the full gcloud login sequence.
@test
def prefrio-auth-runs-gcloud-login-sequence []: record -> nothing {
    let fixture = $in
    let result = run-script {fixture: $fixture module: $AUTH_SCRIPT command: [auth] directory: $fixture.directory}

    assert equal $result.exit_code 0 $result.stderr
    let calls = read-text $fixture.gcloud_args | from json
    assert equal $calls.0 [auth login]
    assert equal $calls.1 [auth application-default login]
    assert equal $calls.2 [auth application-default set-quota-project rj-iplanrio-dia]
}

# Verify k8s fetches GKE credentials using the project config.
@test
def prefrio-k8s-fetches-gke-credentials-from-project-config []: record -> nothing {
    let fixture = $in
    let result = run-script {fixture: $fixture module: $AUTH_SCRIPT command: [k8s] directory: $fixture.directory}

    assert equal $result.exit_code 0 $result.stderr
    let calls = read-text $fixture.gcloud_args | from json
    assert equal $calls.0 [container clusters get-credentials smoke-cluster --region us-central1 --project rj-civitas-dev]
}

# Verify tf init runs tofu init with upgrade and reconfigure.
@test
def prefrio-tf-init-runs-tofu-init []: record -> nothing {
    let fixture = $in
    let result = with-env {
        TF_DIR: ($fixture.directory | path join terraform)
        TF_BACKEND_CONFIG: "prefix=smoke/staging"
    } {
        run-module {fixture: $fixture module: $TF_SCRIPT command: [tf] directory: $fixture.directory} init
    }

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.tofu_args | parse-json-list
    let terraform_directory = $fixture.directory | path join terraform
    assert ($"-chdir=($terraform_directory)" in $args)
    assert ("init" in $args)
    assert ("-upgrade" in $args)
    assert ("-reconfigure" in $args)
    assert ("-backend-config=prefix=smoke/staging" in $args)
}

# Verify tf edit-vars opens the SOPS-encrypted variables file.
@test
def prefrio-tf-edit-vars-opens-sops-file []: record -> nothing {
    let fixture = $in
    let result = run-module {fixture: $fixture module: $TF_SCRIPT command: [tf] directory: $fixture.directory} edit-vars

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.sops_args | parse-json-list
    assert ("edit" in $args)
    assert ("--input-type" in $args)
    assert ("json" in $args)
    assert ("--output-type" in $args)
    let sops_file = $args | last
    assert (($sops_file | path basename) == terraform.tfvars.sops.json)
}

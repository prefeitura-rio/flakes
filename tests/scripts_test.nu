# nu-lint-ignore-file: redundant_nu_subprocess, unused_helper_functions

use std/assert
use std/testing *

const ROOT = path self | path dirname | path dirname
const TF_SCRIPT = $ROOT | path join scripts/tf.nu
const LIB_SCRIPT = $ROOT | path join scripts/lib.nu
const AUTH_SCRIPT = $ROOT | path join scripts/prefrio.nu

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

# Write a text file and report a useful fixture error.
def write-file [content: string path: path]: nothing -> nothing {
    try { $content | save --force $path } catch {|err|
        test-error $"Could not write fixture file ($path): ($err.msg)"
    }
}

# Write the Terragrunt units and encrypted files of an isolated fixture.
def write-project-fixture [directory: path]: nothing -> nothing {
    for unit in [a b] {
        write-file "" ($directory | path join live $unit terragrunt.hcl)
    }
    write-file "{}" ($directory | path join live a terraform.tfvars.sops.json)
}

# Write all fake external commands for an isolated fixture.
def write-fake-tools [bin: path]: nothing -> nothing {
    write-fake-sops ($bin | path join sops)
    write-fake-terragrunt ($bin | path join terragrunt)
    write-fake-kubectl ($bin | path join kubectl)
    write-fake-gcloud ($bin | path join gcloud)
}

# Create an isolated project fixture with fake external commands.
def make-fixture []: nothing -> record {
    let directory = try { mktemp --directory | str trim } catch {|err| test-error $err.msg }
    let bin = $directory | path join bin
    try {
        mkdir $bin ($directory | path join live a) ($directory | path join live b)
        write-project-fixture $directory
        write-fake-tools $bin
    } catch {|err|
        rm --recursive --force $directory
        test-error $err.msg
    }
    {
        directory: $directory
        bin: $bin
        terragrunt_args: ($directory | path join terragrunt-args.json)
        kubectl_args: ($directory | path join kubectl-args.json)
        gcloud_args: ($directory | path join gcloud-args.json)
        sops_args: ($directory | path join sops-args.json)
        path: ($env.PATH? | default [])
    }
}

# Write a fake SOPS executable that copies the source to its output or records edit args.
def write-fake-sops [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    if $args.0? == edit {
        $args | to json | save --force $env.SOPS_ARGS_FILE
        exit ($env.SOPS_EDIT_EXIT_CODE? | default 0 | into int)
    } else {
        let output_index = $args | enumerate | where item == \"--output\" | get index | first
        let output = $args | get ($output_index + 1)
        open --raw ($args | last) | save --force $output
    }
}
" $path
    make-executable $path
}

# Write a fake Terragrunt executable that records its arguments.
def write-fake-terragrunt [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    $args | to json | save --force $env.TERRAGRUNT_ARGS_FILE
}
" $path
    make-executable $path
}

# Write a fake kubectl executable that records its arguments and kubeconfig.
def write-fake-kubectl [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    {args: $args kubeconfig: ($env.KUBECONFIG? | default null)} | to json | save --force $env.KUBECTL_ARGS_FILE
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

# Build the environment for fake external commands.
def fixture-env [fixture: record]: nothing -> record {
    {
        PATH: ([$fixture.bin] | append $fixture.path)
        TERRAGRUNT_ARGS_FILE: $fixture.terragrunt_args
        KUBECTL_ARGS_FILE: $fixture.kubectl_args
        GCLOUD_ARGS_FILE: $fixture.gcloud_args
        SOPS_ARGS_FILE: $fixture.sops_args
        TG_WORKING_DIR: live
    }
}

# Run a module command in an isolated fixture.
def run-module [context: record, ...args: string]: nothing -> record {
    let command = $context.command
    | append $args
    | str join " "
    let source = $"use ($context.module) *; main ($command)"
    with-env (fixture-env $context.fixture | merge ($context.env? | default {})) {
        try {
            cd $context.directory
            nu -c $source | complete
        } catch {|err|
            {exit_code: 1, stdout: "", stderr: $err.msg}
        }
    }
}

# Run prefrio.nu as a script in an isolated fixture.
def run-script [context: record, ...args: string]: nothing -> record {
    let arg_list = $context.command
    | append $args
    | str join " "
    with-env (fixture-env $context.fixture | merge ($context.env? | default {})) {
        try {
            cd $context.directory
            nu ($context.module) ...($arg_list | split row " ") | complete
        } catch {|err|
            {exit_code: 1, stdout: "", stderr: $err.msg}
        }
    }
}

# Run a tf subcommand from a directory inside the fixture.
def run-tf-in [context: record, ...args: string]: nothing -> record {
    run-module {
        fixture: $context.fixture
        module: $TF_SCRIPT
        command: [tf]
        directory: $context.directory
        env: ($context.env? | default {})
    } ...$args
}

# Run a tf subcommand from the fixture root.
def run-tf [fixture: record, ...args: string]: nothing -> record {
    run-tf-in {fixture: $fixture directory: $fixture.directory} ...$args
}

# Return the Terragrunt working directory of a fixture.
def live-dir []: record -> path {
    get directory | path join live
}

# Remove an isolated project fixture.
def remove-fixture [fixture: record]: nothing -> nothing {
    try { rm --recursive --force $fixture.directory } catch { }
}

# Create one isolated fixture for each test.
@before-each
def setup []: nothing -> record {
    make-fixture
}

# Remove the fixture after every test.
@after-each
def cleanup []: record -> nothing {
    remove-fixture $in
}

# Verify plan runs every unit and saves plans under the project root.
@test
def prefrio-tf-plan-runs-all-units-with-saved-plans []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    assert equal $args [run --all --working-dir ($fixture | live-dir) --out-dir $plan_dir -- plan]
}

# Verify plan removes saved plans of units that no longer exist.
@test
def prefrio-tf-plan-clears-stale-plans []: record -> nothing {
    let fixture = $in
    let stale = ($fixture | live-dir) | path join terragrunt.plan removed-unit
    try { mkdir $stale } catch {|err| test-error $err.msg }
    let result = run-tf $fixture plan

    assert equal $result.exit_code 0 $result.stderr
    assert (not ($stale | path exists)) "A stale unit plan survived."
}

# Verify the Git repository root is the project root from a child directory.
@test
def prefrio-tf-plan-uses-git-root-from-a-child-directory []: record -> nothing {
    let fixture = $in
    let nested = $fixture.directory | path join live a modules service
    try { mkdir $nested } catch {|err| test-error $err.msg }
    let init = git init --quiet $fixture.directory | complete
    assert equal $init.exit_code 0 $init.stderr
    let result = run-tf-in {fixture: $fixture directory: $nested} plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert (($fixture | live-dir) in $args)
}

# Verify the current directory is the root outside a Git repository.
@test
def prefrio-tf-plan-uses-current-directory-outside-git []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert (($fixture | live-dir) in $args)
}

# Verify apply refuses to run without saved plans.
@test
def prefrio-tf-apply-requires-saved-plans []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture apply

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Terragrunt plan not found")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify apply uses saved plans and leaves the single confirmation to Terragrunt.
@test
def prefrio-tf-apply-uses-saved-plans-and-confirms []: record -> nothing {
    let fixture = $in
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    try { mkdir $plan_dir } catch {|err| test-error $err.msg }
    let result = run-tf $fixture apply

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --all --working-dir ($fixture | live-dir) --out-dir $plan_dir -- apply]
}

# Verify TF_AUTO_APPROVE skips the Terragrunt confirmation on apply.
@test
def prefrio-tf-apply-auto-approves-on-request []: record -> nothing {
    let fixture = $in
    try { mkdir (($fixture | live-dir) | path join terragrunt.plan) } catch {|err| test-error $err.msg }
    let result = with-env {TF_AUTO_APPROVE: 1} {
        run-tf $fixture apply
    }

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert ("--non-interactive" in $args)
}

# Verify destroy runs all units without a saved plan and keeps the confirmation.
@test
def prefrio-tf-destroy-confirms-without-saved-plan []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture destroy

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --all --working-dir ($fixture | live-dir) -- destroy]
}

# Verify init reconfigures every unit backend.
@test
def prefrio-tf-init-reconfigures-all-units []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture init

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --all --working-dir ($fixture | live-dir) -- init -reconfigure]
}

# Verify the removed --prod flag is rejected instead of ignored.
@test
def prefrio-tf-plan-rejects-prod-flag []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--prod"

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "unknown_flag")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify edit-vars opens the only variables file without a prompt.
@test
def prefrio-tf-edit-vars-picks-the-only-file []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture edit-vars

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.sops_args | parse-json-list
    assert equal $args [edit ($fixture.directory | path join live a terraform.tfvars.sops.json)]
}

# Verify edit-vars opens an explicit file even when several candidates exist.
@test
def prefrio-tf-edit-vars-accepts-explicit-file []: record -> nothing {
    let fixture = $in
    let explicit = $fixture.directory | path join live b terraform.tfvars.sops.json
    write-file "{}" $explicit
    let result = run-tf $fixture edit-vars $explicit

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.sops_args | parse-json-list
    assert equal $args [edit $explicit]
}

# Verify edit-vars explains how to proceed when the fuzzy finder is unavailable.
@test
def prefrio-tf-edit-vars-requires-skim-for-several-files []: record -> nothing {
    let fixture = $in
    write-file "{}" ($fixture.directory | path join live b terraform.tfvars.sops.json)
    let result = run-tf $fixture edit-vars

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "skim plugin is not loaded")
    assert (not ($fixture.sops_args | path exists))
}

# Verify edit-vars fails when the project has no variables file.
@test
def prefrio-tf-edit-vars-fails-without-files []: record -> nothing {
    let fixture = $in
    try { rm --force ($fixture.directory | path join live a terraform.tfvars.sops.json) } catch {|err| test-error $err.msg }
    let result = run-tf $fixture edit-vars

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "No \\*.tfvars.sops.json files found")
}

# Verify edit-vars accepts SOPS no-change status.
@test
def prefrio-tf-edit-vars-accepts-no-change-status []: record -> nothing {
    let fixture = $in
    let result = with-env {SOPS_EDIT_EXIT_CODE: "200"} {
        run-tf $fixture edit-vars
    }

    assert equal $result.exit_code 0 $result.stderr
}

# Verify edit-vars still fails for SOPS errors.
@test
def prefrio-tf-edit-vars-rejects-error-status []: record -> nothing {
    let fixture = $in
    let result = with-env {SOPS_EDIT_EXIT_CODE: "1"} {
        run-tf $fixture edit-vars
    }

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "exit 1")
}

# Verify the auth command runs the full gcloud login sequence.
@test
def prefrio-auth-runs-gcloud-login-sequence []: record -> nothing {
    let fixture = $in
    let result = run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [auth]
        directory: $fixture.directory
    }

    assert equal $result.exit_code 0 $result.stderr

    let calls = try { read-text $fixture.gcloud_args | from json } catch {|err| test-error $err.msg }

    assert equal $calls.0? [auth login]
    assert equal $calls.1? [auth application-default login]
    assert equal $calls.2? [auth application-default set-quota-project rj-iplanrio-dia]
}

# Verify get-kubeconfig fetches GKE credentials for the cluster in CLOUDSDK_CONTAINER_CLUSTER.
@test
def prefrio-get-kubeconfig-fetches-gke-credentials-for-the-env-cluster []: record -> nothing {
    let fixture = $in
    let result = run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [get-kubeconfig]
        directory: $fixture.directory
        env: {CLOUDSDK_CONTAINER_CLUSTER: gitlab}
    }

    assert equal $result.exit_code 0 $result.stderr
    let calls = try { read-text $fixture.gcloud_args | from json } catch {|err| test-error $err.msg }
    assert equal $calls.0? [container clusters get-credentials gitlab]
}

# Verify get-kubeconfig forwards extra flags to gcloud.
@test
def prefrio-get-kubeconfig-forwards-gcloud-flags []: record -> nothing {
    let fixture = $in
    let result = run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [get-kubeconfig]
        directory: $fixture.directory
        env: {CLOUDSDK_CONTAINER_CLUSTER: gitlab}
    } "--region" us-central1

    assert equal $result.exit_code 0 $result.stderr
    let calls = try { read-text $fixture.gcloud_args | from json } catch {|err| test-error $err.msg }
    assert equal $calls.0? [container clusters get-credentials gitlab --region us-central1]
}

# Verify get-kubeconfig requires CLOUDSDK_CONTAINER_CLUSTER.
@test
def prefrio-get-kubeconfig-requires-a-cluster []: record -> nothing {
    let fixture = $in
    let result = run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [get-kubeconfig]
        directory: $fixture.directory
        env: {CLOUDSDK_CONTAINER_CLUSTER: ""}
    }

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Set CLOUDSDK_CONTAINER_CLUSTER")
    assert (not ($fixture.gcloud_args | path exists))
}

# Verify k runs kubectl against the Tailscale API with an empty kubeconfig.
@test
def prefrio-k-runs-kubectl-against-the-tailscale-api []: record -> nothing {
    let fixture = $in
    let result = run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [k]
        directory: $fixture.directory
    } "-n" gitlab get pods

    assert equal $result.exit_code 0 $result.stderr
    let kubectl = read-text $fixture.kubectl_args | parse-json
    assert equal $kubectl.args [
        --server
        https://tailscale-operator-onprem.squirrel-regulus.ts.net
        --token
        unused
        -n
        gitlab
        get
        pods
    ]
    assert equal $kubectl.kubeconfig /dev/null
}

# Verify KUBE_HOST replaces the default API server.
@test
def prefrio-k-uses-kube-host-when-set []: record -> nothing {
    let fixture = $in
    let result = with-env {KUBE_HOST: "https://k3s.example.test"} {
        run-script {
            fixture: $fixture
            module: $AUTH_SCRIPT
            command: [k]
            directory: $fixture.directory
        } get nodes
    }

    assert equal $result.exit_code 0 $result.stderr
    let kubectl = read-text $fixture.kubectl_args | parse-json
    assert equal ($kubectl.args | first 2) [--server https://k3s.example.test]
}

# Verify tf commands refuse to run without TG_WORKING_DIR.
@test
def prefrio-tf-plan-requires-working-directory []: record -> nothing {
    let fixture = $in
    let result = run-tf-in {
        fixture: $fixture
        directory: $fixture.directory
        env: {TG_WORKING_DIR: ""}
    } plan

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Set TG_WORKING_DIR")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify tf commands refuse a TG_WORKING_DIR that does not exist.
@test
def prefrio-tf-plan-rejects-missing-working-directory []: record -> nothing {
    let fixture = $in
    let result = run-tf-in {
        fixture: $fixture
        directory: $fixture.directory
        env: {TG_WORKING_DIR: missing}
    } plan

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "TG_WORKING_DIR does not exist")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify an absolute TG_WORKING_DIR selects a narrower set of units and keeps plans there.
@test
def prefrio-tf-plan-uses-absolute-working-directory []: record -> nothing {
    let fixture = $in
    let unit = ($fixture | live-dir) | path join a
    let result = run-tf-in {
        fixture: $fixture
        directory: $fixture.directory
        env: {TG_WORKING_DIR: $unit}
    } plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [
        run
        --all
        --working-dir
        $unit
        --out-dir
        ($unit | path join terragrunt.plan)
        --
        plan
    ]
}

# Verify run-command shows child output while the child still runs.
@test
def run-command-streams-output-while-the-command-runs []: record -> nothing {
    let source = $"use ($LIB_SCRIPT) [run-command]; run-command sh ...[-c 'echo first; sleep 1; echo second'] | ignore"
    let stamps = nu -c $source
    | lines
    | each {|line| {line: $line at: (date now)} }

    assert equal ($stamps | get line) [first second]
    assert ((($stamps | last).at - ($stamps | first).at) >= 500ms)
}

# Verify run-command reports the exit code of a failing command.
@test
def run-command-reports-failing-exit-code []: record -> nothing {
    let source = $"use ($LIB_SCRIPT) [run-command]; run-command sh ...[-c 'exit 3']"
    let result = nu -c $source | complete

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "exit 3")
}

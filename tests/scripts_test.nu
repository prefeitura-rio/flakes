# nu-lint-ignore-file: redundant_nu_subprocess, unused_helper_functions, catch_builtin_error_try

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
    let out_index = ($args | enumerate | where item == "--out-dir" | get index? | first)
    if $out_index != null {
        mkdir ($args | get ($out_index + 1))
    }
    for arg in $args {
        if ($arg | str starts-with "-out=") {
            "" | save --force ($arg | str replace "-out=" "")
        }
    }
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

# Verify init initializes every Terragrunt unit.
@test
def prefrio-tf-init-runs-all-units []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture init

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --all --working-dir ($fixture | live-dir) -- init -reconfigure]
}

# Verify --all plans every unit and writes a manifest.
@test
def prefrio-tf-plan-all-writes-manifest []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    assert equal $args [run --all --working-dir ($fixture | live-dir) --out-dir $plan_dir -- plan]
    let manifest = open ($plan_dir | path join prefrio.nuon)
    assert equal $manifest.scope all
    assert equal $manifest.working_dir live
}

# Verify --all removes stale plans before planning.
@test
def prefrio-tf-plan-all-clears-stale-plans []: record -> nothing {
    let fixture = $in
    let stale = ($fixture | live-dir) | path join terragrunt.plan removed-unit
    try { mkdir $stale } catch {|err| test-error $err.msg }
    let result = run-tf $fixture plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    assert (not ($stale | path exists)) "A stale unit plan survived."
}

# Verify Git root discovery from a child directory.
@test
def prefrio-tf-plan-all-uses-git-root-from-a-child-directory []: record -> nothing {
    let fixture = $in
    let nested = $fixture.directory | path join live a modules service
    try { mkdir $nested } catch {|err| test-error $err.msg }
    let init = git init --quiet $fixture.directory | complete
    assert equal $init.exit_code 0 $init.stderr
    let result = run-tf-in {fixture: $fixture directory: $nested} plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert (($fixture | live-dir) in $args)
}

# Verify the current directory is the root outside a Git repository.
@test
def prefrio-tf-plan-all-uses-current-directory-outside-git []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert (($fixture | live-dir) in $args)
}

# Verify apply requires the all-module manifest.
@test
def prefrio-tf-apply-requires-manifest []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture apply

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Plan manifest not found")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify apply consumes the all-module manifest without selectors.
@test
def prefrio-tf-apply-uses-all-manifest []: record -> nothing {
    let fixture = $in
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    try { mkdir $plan_dir } catch {|err| test-error $err.msg }
    write-file ({scope: all working_dir: live plan_dir: live/terragrunt.plan} | to nuon) ($plan_dir | path join prefrio.nuon)
    let result = run-tf $fixture apply

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --all --working-dir ($fixture | live-dir) --out-dir $plan_dir -- apply]
}

# Verify TF_AUTO_APPROVE skips the all-module confirmation.
@test
def prefrio-tf-apply-auto-approves []: record -> nothing {
    let fixture = $in
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    try { mkdir $plan_dir } catch {|err| test-error $err.msg }
    write-file ({scope: all working_dir: live plan_dir: live/terragrunt.plan} | to nuon) ($plan_dir | path join prefrio.nuon)
    let result = with-env {TF_AUTO_APPROVE: 1} { run-tf $fixture apply }

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert ("--non-interactive" in $args)
}

# Verify the default plan picks the only unit without a picker.
@test
def prefrio-tf-plan-single-unit []: record -> nothing {
    let fixture = $in
    try { rm --recursive --force (($fixture | live-dir) | path join b) } catch {|err| test-error $err.msg }
    let result = run-tf $fixture plan

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    let unit_dir = ($fixture | live-dir) | path join a
    let plan_file = ($fixture | live-dir) | path join terragrunt.plan a.tfplan
    let manifest = open (($fixture | live-dir) | path join terragrunt.plan prefrio.nuon)
    assert equal $args [run --working-dir $unit_dir -- plan $"-out=($plan_file)"]
    assert equal $manifest.scope unit
    assert equal $manifest.unit a
}

# Verify --mod selects one module and writes its plan.
@test
def prefrio-tf-plan-unit-selects-module []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--mod" b

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    let unit_dir = ($fixture | live-dir) | path join b
    let plan_file = ($fixture | live-dir) | path join terragrunt.plan b.tfplan
    assert equal $args [run --working-dir $unit_dir -- plan $"-out=($plan_file)"]
}

# Verify --mod reports unknown modules.
@test
def prefrio-tf-plan-unit-reports-unknown-module []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--mod" nope

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "is not a unit under")
    assert ($result.stderr =~ "Available: a, b")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify the default picker path fails clearly without skim or a terminal.
@test
def prefrio-tf-plan-default-requires-selection []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "skim plugin is not loaded")
    assert ($result.stderr =~ "--all")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify --all and --mod cannot be combined.
@test
def prefrio-tf-plan-rejects-all-with-unit []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--all" "--mod" a

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Use either --all or --mod")
}

# Verify apply requires the selected unit's manifest.
@test
def prefrio-tf-apply-unit-requires-manifest []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture apply

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Plan manifest not found")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify apply consumes a unit manifest without selectors.
@test
def prefrio-tf-apply-unit-uses-manifest []: record -> nothing {
    let fixture = $in
    let plan_dir = ($fixture | live-dir) | path join terragrunt.plan
    let plan_file = $plan_dir | path join a.tfplan
    try { mkdir $plan_dir; write-file "" $plan_file } catch {|err| test-error $err.msg }
    write-file ({scope: unit working_dir: live unit: a plan: live/terragrunt.plan/a.tfplan} | to nuon) ($plan_dir | path join prefrio.nuon)
    let result = run-tf $fixture apply

    assert equal $result.exit_code 0 $result.stderr
    let args = read-text $fixture.terragrunt_args | parse-json-list
    assert equal $args [run --working-dir (($fixture | live-dir) | path join a) -- apply $plan_file]
}

# Verify init has no module selector and initializes all units.
@test
def prefrio-tf-init-rejects-module-selector []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture init "--mod" a

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "doesn't have flag")
}

# Verify --help exposes the new scope flags.
@test
def prefrio-tf-plan-help-shows-scope-flags []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--help"

    assert equal $result.exit_code 0 $result.stderr
    assert ($result.stdout =~ "--all")
    assert ($result.stdout =~ "--mod")
    assert (not ($fixture.terragrunt_args | path exists))
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

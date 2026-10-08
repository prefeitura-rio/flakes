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
        write-file "" ($directory | path join units $unit terragrunt.hcl)
    }
    write-file "{}" ($directory | path join units a terraform.tfvars.sops.json)
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
        mkdir $bin ($directory | path join units a) ($directory | path join units b)
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

def write-fake-sops [path: path]: nothing -> nothing {
    write-file "#!/usr/bin/env -S nu
def --wrapped main [...args: string] {
    $args | to json | save --force $env.SOPS_ARGS_FILE
}
" $path
    make-executable $path
}

# Write a fake Terragrunt executable that records every call.
def write-fake-terragrunt [path: path]: nothing -> nothing {
    write-file ([
        '#!/usr/bin/env -S nu'
        'def --wrapped main [...args: string] {'
        '    let calls = if ($env.TERRAGRUNT_ARGS_FILE | path exists) { open --raw $env.TERRAGRUNT_ARGS_FILE | from json } else { [] }'
        '    $calls | append [$args] | to json | save --force $env.TERRAGRUNT_ARGS_FILE'
        '    exit ($env.FAKE_EXIT? | default 0 | into int)'
        '}'
    ] | str join "\n") $path
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
            ($context.stdin? | default "") | nu -c $source | complete
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
        stdin: ($context.stdin? | default "")
    } ...$args
}

# Run a tf subcommand from the fixture root.
def run-tf [fixture: record, ...args: string]: nothing -> record {
    run-tf-in {fixture: $fixture directory: $fixture.directory} ...$args
}

# Return the Terragrunt working directory of a fixture.
def units-dir []: record -> path {
    get directory | path join units
}

# Read every Terragrunt call recorded by the fake executable.
def read-terragrunt-calls [fixture: record]: nothing -> list<list<string>> {
    try { read-text $fixture.terragrunt_args | from json } catch {|err| test-error $err.msg }
}

# Return the directory where saved plans live.
def plan-dir []: record -> path {
    get directory | path join units terragrunt.plan
}

# Write an empty saved plan for a unit and return its directory.
def write-plan [fixture: record, unit: string]: nothing -> path {
    let directory = ($fixture | plan-dir) | path join $unit
    try { mkdir $directory } catch {|err| test-error $err.msg }
    write-file "" ($directory | path join tfplan.tfplan)
    $directory
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
    assert equal (read-terragrunt-calls $fixture) [[run --all --working-dir ($fixture | units-dir) -- init -reconfigure]]
}

# Verify --all plans every unit and saves the plans in the plan directory.
@test
def prefrio-tf-plan-all-plans-every-unit []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    let calls = [[run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) -- plan]]
    assert equal (read-terragrunt-calls $fixture) $calls
}

# Verify plan removes stale plans before planning.
@test
def prefrio-tf-plan-clears-stale-plans []: record -> nothing {
    let fixture = $in
    let stale = write-plan $fixture removed-unit
    let result = run-tf $fixture plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    assert (not ($stale | path exists)) "A stale plan survived."
}

# Verify the default plan picks the only unit without a picker.
@test
def prefrio-tf-plan-single-unit []: record -> nothing {
    let fixture = $in
    try { rm --recursive --force (($fixture | units-dir) | path join b) } catch {|err| test-error $err.msg }
    let result = run-tf $fixture plan

    assert equal $result.exit_code 0 $result.stderr
    let calls = [[run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) --filter ./a -- plan]]
    assert equal (read-terragrunt-calls $fixture) $calls
}

# Verify --module reports unknown modules and keeps the saved plans.
@test
def prefrio-tf-plan-unit-reports-unknown-module []: record -> nothing {
    let fixture = $in
    let plan = write-plan $fixture a
    let result = run-tf $fixture plan "--module" nope

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "is not a unit or module under")
    assert ($result.stderr =~ "Available: a, b")
    assert (not ($fixture.terragrunt_args | path exists))
    assert ($plan | path exists) "A bad selection removed the saved plans."
}

# Verify Git root discovery from a child directory.
@test
def prefrio-tf-plan-uses-git-root-from-a-child-directory []: record -> nothing {
    let fixture = $in
    let nested = $fixture.directory | path join units a modules service
    try { mkdir $nested } catch {|err| test-error $err.msg }
    let init = git init --quiet $fixture.directory | complete
    assert equal $init.exit_code 0 $init.stderr
    let result = run-tf-in {fixture: $fixture directory: $nested} plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    assert (($fixture | units-dir) in (read-terragrunt-calls $fixture | flatten))
}

# Verify apply needs saved plans.
@test
def prefrio-tf-apply-requires-saved-plans []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture apply

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "No saved plans")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify TF_AUTO_APPROVE makes apply non-interactive.
@test
def prefrio-tf-apply-auto-approves []: record -> nothing {
    let fixture = $in
    write-plan $fixture a
    let result = with-env {TF_AUTO_APPROVE: 1} { run-tf $fixture apply }

    assert equal $result.exit_code 0 $result.stderr
    assert ("--non-interactive" in (read-terragrunt-calls $fixture | first))
}

# Verify a failed apply keeps the saved plans.
@test
def prefrio-tf-apply-keeps-the-plans-when-it-fails []: record -> nothing {
    let fixture = $in
    let plan = write-plan $fixture a
    let result = run-tf-in {fixture: $fixture directory: $fixture.directory env: {FAKE_EXIT: 1}} apply

    assert ($result.exit_code != 0)
    assert ($plan | path exists) "The plans of a failed apply were removed."
}

# Replace the flat fixture units with module-first units, as in <module>/<environment>.
def use-module-first-units [fixture: record, units: list<string>]: nothing -> nothing {
    let root = $fixture | units-dir
    try { rm --recursive --force ($root | path join a) ($root | path join b) } catch {|err| test-error $err.msg }
    for unit in $units {
        let directory = $root | path join ...($unit | split row "/")
        try { mkdir $directory } catch {|err| test-error $err.msg }
        write-file "" ($directory | path join terragrunt.hcl)
    }
}

# Verify --all with --environment plans only the units of that environment.
@test
def prefrio-tf-plan-all-environment-plans-only-that-environment []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg k8s/prod]
    let cases = [
        {environment: stg, filters: [--filter ./gcp/stg --filter ./k8s/stg]}
        {environment: prod, filters: [--filter ./gcp/prod --filter ./k8s/prod]}
    ]

    for case in $cases {
        let result = run-tf $fixture plan "--all" "--environment" $case.environment
        assert equal $result.exit_code 0 $"($case.environment): ($result.stderr)"
    }

    let expected = $cases | each {|case|
        [run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) ...$case.filters -- plan]
    }
    assert equal (read-terragrunt-calls $fixture) $expected
}

# Verify --module and --environment narrow the units, and --all takes every unit left.
@test
def prefrio-tf-plan-selectors-narrow-the-units []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg]
    let cases = [
        {args: [-a -m gcp], units: [gcp/prod gcp/stg]}
        {args: [-m gcp -e stg], units: [gcp/stg]}
        {args: [-m gcp -e prod -a], units: [gcp/prod]}
        {args: [-m k8s], units: [k8s/stg]}
        {args: [-m k8s/stg], units: [k8s/stg]}
        {args: [-a -e stg], units: [gcp/stg k8s/stg]}
        {args: [--all --module k8s --environment stg], units: [k8s/stg]}
    ]

    for case in $cases {
        let result = run-tf $fixture plan ...$case.args
        assert equal $result.exit_code 0 $"($case.args | str join ' '): ($result.stderr)"
    }

    let expected = $cases | each {|case|
        let filters = $case.units | each {|unit| [--filter $"./($unit)"] } | flatten
        [run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) ...$filters -- plan]
    }
    assert equal (read-terragrunt-calls $fixture) $expected
}

# Verify pass-through arguments reach Terragrunt next to every selector.
@test
def prefrio-tf-plan-forwards-extra-arguments-with-selectors []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod]
    let cases = [
        {args: [-a], units: [gcp/prod gcp/stg], narrowed: false}
        {args: [-a -e stg], units: [gcp/stg], narrowed: true}
        {args: [-m gcp -e prod], units: [gcp/prod], narrowed: true}
        {args: [-m gcp -a], units: [gcp/prod gcp/stg], narrowed: true}
    ]

    for case in $cases {
        let result = run-tf $fixture plan ...$case.args "--" "-refresh=false"
        assert equal $result.exit_code 0 $"($case.args | str join ' '): ($result.stderr)"
    }

    let expected = $cases | each {|case|
        let filters = if $case.narrowed { $case.units | each {|unit| [--filter $"./($unit)"] } | flatten } else { [] }
        [run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) ...$filters -- plan -refresh=false]
    }
    assert equal (read-terragrunt-calls $fixture) $expected
}

# Verify selectors that match no unit fail, naming the units that exist, and never reach Terragrunt.
@test
def prefrio-tf-plan-rejects-selectors-that-match-no-unit []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg]
    let cases = [
        {args: [-a -e st], message: "No unit belongs to the st environment"}
        {args: [-a -e STG], message: "No unit belongs to the STG environment"}
        {args: [-a -e gcp], message: "No unit belongs to the gcp environment"}
        {args: [-a -e k8s], message: "No unit belongs to the k8s environment"}
        {args: [-a -m gc], message: "gc is not a unit or module under"}
        {args: [-a -m stg], message: "stg is not a unit or module under"}
        {args: [-a -m gcp/st], message: "gcp/st is not a unit or module under"}
        {args: [-e stg -m k8s/prod], message: "k8s/prod is not a unit or module in the stg environment", available: "gcp/stg, k8s/stg"}
        {args: [-m k8s -e prod], message: "k8s is not a unit or module in the prod environment", available: "gcp/prod"}
    ]

    for case in $cases {
        let result = run-tf $fixture plan ...$case.args
        let label = $case.args | str join " "
        assert ($result.exit_code != 0) $"($label) should fail."
        assert ($result.stderr =~ $case.message) $"($label): ($result.stderr)"
        if ($case.available? != null) {
            assert ($result.stderr =~ $"Available: ($case.available)") $"($label): ($result.stderr)"
        }
    }
    assert (not ($fixture.terragrunt_args | path exists)) "A bad selection reached Terragrunt."
}

# Verify planning one environment removes the saved plans of the other environment.
@test
def prefrio-tf-plan-environment-clears-the-plans-of-the-other-environment []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg k8s/prod]
    let stale = write-plan $fixture gcp/prod
    let result = run-tf $fixture plan "-a" "-e" stg

    assert equal $result.exit_code 0 $result.stderr
    assert (not ($stale | path exists)) "A prod plan survived a staging plan."
}

# Verify init takes no selector at all.
@test
def prefrio-tf-init-rejects-every-selector []: record -> nothing {
    let fixture = $in
    let cases = [
        [--module a] [-m a] [--environment stg] [-e stg] [--all] [-a]
    ]

    for args in $cases {
        let result = run-tf $fixture init ...$args
        let label = $args | str join " "
        assert ($result.exit_code != 0) $"init ($label) should fail."
        assert ($result.stderr =~ "doesn't have flag") $"init ($label): ($result.stderr)"
    }
    assert (not ($fixture.terragrunt_args | path exists)) "A rejected flag reached Terragrunt."
}

# Verify plan refuses to guess when several units remain and no picker is available.
@test
def prefrio-tf-plan-needs-a-choice-when-several-units-remain []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg k8s/prod]

    for args in [[] [-m gcp] [-e stg]] {
        let result = run-tf $fixture plan ...$args
        let label = $args | str join " "
        assert ($result.exit_code != 0) $"plan ($label) should fail."
        assert ($result.stderr =~ "skim plugin is not loaded") $"plan ($label): ($result.stderr)"
        assert ($result.stderr =~ "--all") $"plan ($label): ($result.stderr)"
    }
    assert (not ($fixture.terragrunt_args | path exists)) "An ambiguous selection reached Terragrunt."
}

# Verify apply runs exactly the planned units, says which, and removes the plans.
@test
def prefrio-tf-apply-runs-exactly-the-planned-units []: record -> nothing {
    let fixture = $in
    use-module-first-units $fixture [gcp/stg gcp/prod k8s/stg k8s/prod]
    write-plan $fixture gcp/stg
    write-plan $fixture k8s/stg
    let result = run-tf $fixture apply

    assert equal $result.exit_code 0 $result.stderr
    let calls = [[run --all --working-dir ($fixture | units-dir) --out-dir ($fixture | plan-dir) --filter ./gcp/stg --filter ./k8s/stg -- apply]]
    assert equal (read-terragrunt-calls $fixture) $calls
    assert ($result.stderr =~ "Applying: gcp/stg, k8s/stg")
    assert (not ($fixture | plan-dir | path exists)) "The applied plans were kept."
}

# Verify get-kubeconfig stops before gcloud when the project file cannot name a cluster.
@test
def prefrio-get-kubeconfig-rejects-an-unusable-project []: record -> nothing {
    let fixture = $in
    let cases = [
        {project: (two-environment-project), args: ["--environment" qa], message: "no environment qa"}
        {project: {name: kms, env: {default: {project: rj-iplanrio-dia}}}, args: [], message: "has no cluster"}
        {project: {name: tailscale}, args: [], message: "has no env record"}
        {project: null, args: [], message: "No .project.nuon found"}
        {raw: "{", args: [], message: "Could not read"}
        {raw: "[1, 2]", args: [], message: "must be a record with a name"}
        {raw: "{env: {}}", args: [], message: "must be a record with a name"}
    ]

    for item in ($cases | enumerate) {
        let directory = $fixture.directory | path join $"case($item.index)"
        try { mkdir $directory } catch {|err| test-error $err.msg }
        if $item.item.raw? != null { write-file $item.item.raw ($directory | path join .project.nuon) }
        if $item.item.project? != null { write-project $directory $item.item.project }
        let result = run-get-kubeconfig $fixture $directory ...$item.item.args

        assert ($result.exit_code != 0) $"case ($item.index) should fail."
        assert ($result.stderr =~ $item.item.message) $"case ($item.index): ($result.stderr)"
    }
    assert (not ($fixture.gcloud_args | path exists)) "A bad project reached gcloud."
}

# Verify a unit name is not an environment in a project whose units have no environment folder.
@test
def prefrio-tf-plan-environment-is-not-a-unit-name []: record -> nothing {
    let fixture = $in
    let result = run-tf $fixture plan "-a" "-e" a

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "No unit belongs to the a environment")
    assert (not ($fixture.terragrunt_args | path exists))
}

# Verify get-kubeconfig leaves out --location when the environment has no region.
@test
def prefrio-get-kubeconfig-omits-location-without-a-region []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory {name: demo, env: {default: {project: rj-demo, cluster: demo}}}
    let result = run-get-kubeconfig $fixture $fixture.directory

    assert equal $result.exit_code 0 $result.stderr
    assert equal (read-gcloud-calls $fixture | first) [container clusters get-credentials demo --project rj-demo]
}

# Verify cache folders never count as units.
@test
def prefrio-tf-plan-ignores-cache-folders []: record -> nothing {
    let fixture = $in
    for cache in [.terragrunt-cache/hash .terraform/modules] {
        let directory = ($fixture | units-dir) | path join a ...($cache | split row "/")
        try { mkdir $directory } catch {|err| test-error $err.msg }
        write-file "" ($directory | path join terragrunt.hcl)
    }
    let result = run-tf $fixture plan "-m" nope

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "Available: a, b")
    assert (not ($result.stderr | str contains "cache"))
}

# Verify plan explains an empty or missing units directory.
@test
def prefrio-tf-plan-reports-an-empty-or-missing-units-directory []: record -> nothing {
    let fixture = $in
    let units = $fixture | units-dir
    try { rm --recursive --force ($units | path join a) ($units | path join b) } catch {|err| test-error $err.msg }
    let empty = run-tf $fixture plan "-a"

    assert ($empty.exit_code != 0)
    assert ($empty.stderr =~ "No terragrunt.hcl found under")

    try { rm --recursive --force $units } catch {|err| test-error $err.msg }
    let missing = run-tf $fixture plan "-a"

    assert ($missing.exit_code != 0)
    assert ($missing.stderr =~ "The units directory does not exist")
    assert (not ($fixture.terragrunt_args | path exists)) "A missing units directory reached Terragrunt."
}

# Verify edit-vars hands the only variables file to sops, ignoring cache copies.
@test
def prefrio-tf-edit-vars-hands-the-only-variables-file-to-sops []: record -> nothing {
    let fixture = $in
    let cache = ($fixture | units-dir) | path join a .terragrunt-cache hash
    try { mkdir $cache } catch {|err| test-error $err.msg }
    write-file "{}" ($cache | path join terraform.tfvars.sops.json)
    let result = run-tf $fixture edit-vars

    assert equal $result.exit_code 0 $result.stderr
    let expected = $fixture | units-dir | path join a terraform.tfvars.sops.json
    assert equal (read-text $fixture.sops_args | from json) [edit $expected]
}

# Verify edit-vars fails before sops when it cannot choose one existing file.
@test
def prefrio-tf-edit-vars-needs-one-existing-file []: record -> nothing {
    let fixture = $in
    let units = $fixture | units-dir

    let missing = run-tf $fixture edit-vars ($fixture.directory | path join nope.tfvars.sops.json)
    assert ($missing.exit_code != 0)
    assert ($missing.stderr =~ "SOPS variables file not found")

    write-file "{}" ($units | path join b terraform.tfvars.sops.json)
    let several = run-tf $fixture edit-vars
    assert ($several.exit_code != 0)
    assert ($several.stderr =~ "skim plugin is not loaded")

    try { rm --force ($units | path join a terraform.tfvars.sops.json) ($units | path join b terraform.tfvars.sops.json) } catch {|err| test-error $err.msg }
    let none = run-tf $fixture edit-vars
    assert ($none.exit_code != 0)
    assert ($none.stderr | str contains "files found under")

    assert (not ($fixture.sops_args | path exists)) "A rejected choice reached sops."
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

# Write a .project.nuon into a directory.
def write-project [directory: path, project: record]: nothing -> nothing {
    mkdir $directory
    write-file ($project | to nuon) ($directory | path join .project.nuon)
}

# Return a project with one GKE environment.
def single-project []: nothing -> record {
    {
        name: gitlab
        env: {default: {project: rj-gitlab, region: us-central1, cluster: gitlab}}
    }
}

# Return a project with a staging and a production environment.
def two-environment-project []: nothing -> record {
    {
        name: superapp
        env: {
            stg: {project: rj-superapp-staging, region: us-central1, cluster: application}
            prod: {project: rj-superapp, region: us-central1, cluster: application}
        }
    }
}

# Run get-kubeconfig from a directory with the given arguments.
def run-get-kubeconfig [fixture: record, directory: path, ...args: string]: nothing -> record {
    run-script {
        fixture: $fixture
        module: $AUTH_SCRIPT
        command: [get-kubeconfig]
        directory: $directory
    } ...$args
}

# Read the gcloud calls recorded by the fake executable.
def read-gcloud-calls [fixture: record]: nothing -> list<list<string>> {
    try { read-text $fixture.gcloud_args | from json } catch {|err| test-error $err.msg }
}

# Verify get-kubeconfig uses the only environment of the project file.
@test
def prefrio-get-kubeconfig-uses-the-only-environment []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory (single-project)
    let result = run-get-kubeconfig $fixture $fixture.directory

    assert equal $result.exit_code 0 $result.stderr
    let calls = read-gcloud-calls $fixture
    assert equal $calls.0? [container clusters get-credentials gitlab --project rj-gitlab --location us-central1]
}

# Verify --environment selects one environment of a project.
@test
def prefrio-get-kubeconfig-selects-an-environment []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory (two-environment-project)
    let result = run-get-kubeconfig $fixture $fixture.directory "--environment" prod

    assert equal $result.exit_code 0 $result.stderr
    let calls = read-gcloud-calls $fixture
    assert equal $calls.0? [container clusters get-credentials application --project rj-superapp --location us-central1]
}

# Verify get-kubeconfig refuses to guess among several environments.
@test
def prefrio-get-kubeconfig-requires-env-when-ambiguous []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory (two-environment-project)
    let result = run-get-kubeconfig $fixture $fixture.directory

    assert ($result.exit_code != 0)
    assert ($result.stderr =~ "several environments")
    assert ($result.stderr =~ "stg, prod")
    assert (not ($fixture.gcloud_args | path exists))
}

# Verify get-kubeconfig forwards extra flags to gcloud.
@test
def prefrio-get-kubeconfig-forwards-gcloud-flags []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory (single-project)
    let result = run-get-kubeconfig $fixture $fixture.directory "--internal-ip"

    assert equal $result.exit_code 0 $result.stderr
    let calls = read-gcloud-calls $fixture
    assert equal $calls.0? [container clusters get-credentials gitlab --project rj-gitlab --location us-central1 --internal-ip]
}

# Verify tf finds the project root from a child directory without Git.
@test
def prefrio-tf-plan-all-uses-the-project-file-from-a-child-directory []: record -> nothing {
    let fixture = $in
    write-project $fixture.directory (single-project)
    let nested = $fixture.directory | path join units a modules service
    try { mkdir $nested } catch {|err| test-error $err.msg }
    let result = run-tf-in {fixture: $fixture directory: $nested} plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    assert (($fixture | units-dir) in (read-terragrunt-calls $fixture | flatten))
}

# Verify the project file wins over the Git root in a monorepo.
@test
def prefrio-tf-plan-all-prefers-the-project-file-over-the-git-root []: record -> nothing {
    let fixture = $in
    let init = git init --quiet $fixture.directory | complete
    assert equal $init.exit_code 0 $init.stderr
    let project = $fixture.directory | path join caio
    write-project $project (single-project)
    for unit in [gcp k8s] {
        try { mkdir ($project | path join units $unit) } catch {|err| test-error $err.msg }
        write-file "" ($project | path join units $unit terragrunt.hcl)
    }
    let result = run-tf-in {fixture: $fixture directory: ($project | path join units gcp)} plan "--all"

    assert equal $result.exit_code 0 $result.stderr
    assert (($project | path join units) in (read-terragrunt-calls $fixture | flatten))
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

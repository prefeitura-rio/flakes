# flakes

Shared Nix packages for Prefeitura do Rio infrastructure projects.

## prefrio

A Nushell CLI for Terragrunt, SOPS and Kubernetes. A project is a directory with a `.project.nuon`; all its Terraform units live below `units/` in that directory.

```nu
prefrio auth                    # Google Cloud login
prefrio get-kubeconfig          # gcloud container clusters get-credentials, from .project.nuon
prefrio get-kubeconfig -e prod  # choose an environment when the project has several
prefrio k get pods -n gitlab    # kubectl through the Tailscale K3s API
prefrio tf init                 # initialize every unit
prefrio tf init -e prod         # initialize only the prod units
prefrio tf plan                 # choose one unit with a small fuzzy finder
prefrio tf plan -m k8s/stg      # choose one unit by name
prefrio tf plan --all           # plan every unit
prefrio tf plan --all -e stg    # plan every staging unit
prefrio tf plan -e prod         # choose one prod unit with the fuzzy finder
prefrio tf apply                # apply the last generated plan
prefrio tf edit-vars [file]
```

### Project file

`prefrio` finds the project by walking up from the current directory to the first `.project.nuon`. Without one it falls back to the Git root, then to the current directory. This lets several projects share one Git repository.

```nuon
{
  name: superapp
  env: {
    stg: {project: rj-superapp-staging, region: us-central1, cluster: application}
    prod: {project: rj-superapp, region: us-central1, cluster: application}
  }
}
```

`env` is optional. Use the key `default` for a project with a single environment, and `stg` and `prod` to match the environment folder in the unit paths under `units/` (`units/gcp/stg` or `units/stg/gcp`). `region` and `cluster` are optional too, but `get-kubeconfig` needs a cluster. `get-kubeconfig` uses the only environment, or the one named by `--environment`/`-e`; with several environments it refuses to guess. Extra flags go to `gcloud`.

### Modules and plans

`prefrio tf init` initializes every unit below `units/`. `tf plan` selects one unit by default, with `-m`/`--mod` for scripts and `--all` for every unit. `--environment`/`-e` (on `init` and `plan`) limits the units to those with that name as a folder in their path, such as `stg` or `prod`, whatever the layout. With `--all` it plans every unit of the environment, and with the picker or `-m` it only offers units of that environment. The picker uses `PREFRIO_SKIM_HEIGHT` and defaults to `40%`.

`tf plan` removes the saved plans, then runs `terragrunt run --all --out-dir units/terragrunt.plan -- plan`. With `-m` it adds `--filter ./<unit>` so only that unit is planned, and with `-e` it adds one `--filter` for each unit of the environment. Terragrunt writes one `tfplan.tfplan` per unit, in a folder named after the unit (for example `units/terragrunt.plan/gcp/stg/tfplan.tfplan`). Add `terragrunt.plan/` to `.gitignore`: plans can hold sensitive values.

`tf apply` takes no selector. The plan directory records what was planned, so it applies exactly the units that have a `tfplan.tfplan`, with one `--filter` per unit, and removes the directory once the apply succeeds. It logs `Applying: <units>` before it starts. To apply one environment, plan only that environment (`tf plan --all -e stg`) and then run `tf apply`: only the planned units can be applied. Planning clears earlier plans, so staging and prod are never applied together by accident. Terragrunt orders the units from their `dependency` blocks and asks for confirmation; `TF_AUTO_APPROVE` makes the run non-interactive.

A saved plan is computed with the outputs its dependencies had at plan time. When an upstream unit changes outputs, apply that unit first and plan the downstream one again.

`tf edit-vars` runs `sops edit`. Pass a file path to choose it directly; without a path it uses the compact fuzzy finder.

Run the tests:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

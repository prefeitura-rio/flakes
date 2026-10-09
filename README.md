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
prefrio tf plan                 # choose one unit with a small fuzzy finder
prefrio tf plan -m gcp -e stg   # one unit: the gcp module in stg
prefrio tf plan -m gcp -a       # the gcp module in every environment
prefrio tf plan -a -e stg       # every staging unit
prefrio tf plan -a              # every unit
prefrio tf apply                # apply the last generated plan
prefrio tf edit-vars [file]
```

### Use in devenv

The flake has an overlay that adds `pkgs.prefrio`: the CLI together with gcloud, kubectl, OpenTofu, SOPS and Terragrunt, all built with the nixpkgs of the consumer.

```nix
{ pkgs, inputs, ... }:
{
  overlays = [ inputs.prefrio.overlays.default ];
  packages = [ pkgs.prefrio ];
}
```

`nix run` and `packages.<system>.prefrio` give the CLI alone, with its tools only inside its own `PATH`.

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

`env` is optional. Use the key `default` for a project with a single environment, and `stg` and `prod` to match the environment folder in the unit paths under `units/` (`units/gcp/stg`). `region` and `cluster` are optional too, but `get-kubeconfig` needs a cluster. `get-kubeconfig` uses the only environment, or the one named by `--environment`/`-e`; with several environments it refuses to guess. Extra flags go to `gcloud`.

### Modules and plans

`prefrio tf init` initializes every unit below `units/`. It takes no selector: Terragrunt also initializes a unit when it plans or applies it.

`tf plan` has two selectors that narrow the units and one switch:

- `-m`/`--module NAME` keeps the units whose path is `NAME` or sits inside the `NAME` folder (`gcp` matches `gcp/stg` and `gcp/prod`; `gcp/stg` matches one unit).
- `-e`/`--environment NAME` keeps the units whose environment folder is `NAME`. A unit is `units/<module>/<environment>`, so the environment is the second folder (`stg` or `prod`). A module name such as `gcp` is not an environment, and a project whose units have no environment folder has none.
- `-a`/`--all` plans every unit left. Without it, `plan` takes the only unit left, or opens the picker when several remain.

The selectors combine: `-m gcp -e stg` is the unit `gcp/stg`, and `-m gcp -a` is the gcp module in every environment. The picker uses `PREFRIO_SKIM_HEIGHT` and defaults to `40%`.

`tf plan` removes the saved plans, then runs `terragrunt run --all --out-dir units/terragrunt.plan -- plan`. When any selector is used it adds one `--filter ./<unit>` for each unit it plans. Terragrunt writes one `tfplan.tfplan` per unit, in a folder named after the unit (for example `units/terragrunt.plan/gcp/stg/tfplan.tfplan`). Add `terragrunt.plan/` to `.gitignore`: plans can hold sensitive values.

`tf apply` takes no selector. The plan directory records what was planned, so it applies exactly the units that have a `tfplan.tfplan`, with one `--filter` per unit, and removes the directory once the apply succeeds. It logs `Applying: <units>` before it starts. To apply one environment, plan only that environment (`tf plan -a -e stg`) and then run `tf apply`: only the planned units can be applied. Planning clears earlier plans, so staging and prod are never applied together by accident. Terragrunt orders the units from their `dependency` blocks and asks for confirmation; `TF_AUTO_APPROVE` makes the run non-interactive.

A saved plan is computed with the outputs its dependencies had at plan time. When an upstream unit changes outputs, apply that unit first and plan the downstream one again.

`tf edit-vars` runs `sops edit`. Pass a file path to choose it directly; without a path it uses the compact fuzzy finder.

Run the tests:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

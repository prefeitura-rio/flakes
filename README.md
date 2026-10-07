# flakes

Shared Nix packages for Prefeitura do Rio infrastructure projects.

## prefrio

A Nushell CLI for Terragrunt, SOPS and Kubernetes. All Terraform units live below `live/`.

```nu
prefrio auth                    # Google Cloud login
prefrio get-kubeconfig          # gcloud container clusters get-credentials
prefrio k get pods -n gitlab    # kubectl through the Tailscale K3s API
prefrio tf init                 # initialize every unit
prefrio tf plan                 # choose one unit with a small fuzzy finder
prefrio tf plan -m stg          # choose one unit by name
prefrio tf plan --all           # plan every unit
prefrio tf apply                # apply the last generated plan
prefrio tf edit-vars [file]
```

### Modules and plans

`prefrio tf init` always initializes every unit below `live/`. `tf plan` selects one unit by default, with `-m`/`--mod` for scripts and `--all` for every unit. The picker uses `PREFRIO_SKIM_HEIGHT` and defaults to `40%`.

A single-unit plan is saved as `live/terragrunt.plan/<module>.tfplan`. An all-unit plan uses Terragrunt's directory layout in `live/terragrunt.plan/`. Both write `live/terragrunt.plan/prefrio.nuon`.

`prefrio tf apply` takes no selector. It reads the manifest and applies exactly the last successful plan. It fails when the manifest or its plan is missing. `TF_AUTO_APPROVE` skips the apply confirmation.

`tf edit-vars` runs `sops edit`. Pass a file path to choose it directly; without a path it uses the compact fuzzy finder.

Run the tests:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

# flakes

Shared files for Prefeitura do Rio infrastructure projects.

## prefrio

The Flake provides one Nushell CLI with auto-imported `tf` module for Terragrunt, SOPS and Kubernetes operations. Enter a project Flake with `direnv allow` or `nix develop`, then run:

```nu
prefrio --help
prefrio auth
prefrio get-kubeconfig
prefrio k get pods -n gitlab
prefrio tf init
prefrio tf plan
prefrio tf apply
prefrio tf edit-vars
```

A project needs no configuration file. Only `TG_WORKING_DIR` is required. The project root, used to resolve a relative `TG_WORKING_DIR` and to search for variable files, is the nearest folder with a `.project.nuon`, or else the Git repository root, or else the current directory. Add a `.project.nuon` only to configure `get-kubeconfig`:

```nuon
{
  project: rj-my-project
  k8s: {cluster: my-cluster, region: us-central1}
}
```

### get-kubeconfig

`get-kubeconfig` fetches GKE credentials from `project` and `k8s` in the project file.

### k

`k` runs `kubectl` against the K3s API through Tailscale, which identifies the caller, so no kubeconfig is needed. It adds `--server` and a placeholder token, uses an empty kubeconfig, and passes every other argument to `kubectl`: `prefrio k get pods -n gitlab`. Set `KUBE_HOST` to use another API server. Terraform providers read the same variable, so one value serves both tools.

### tf

All `tf` commands run `terragrunt run --all`, so every unit below the working directory runs in dependency order. Terragrunt reads its own SOPS files and generates backends and providers.

`TG_WORKING_DIR` is required: it is the directory where Terragrunt runs, and the same variable Terragrunt reads itself. A relative value is resolved from the project root. Set it in the project's shell, for example `TG_WORKING_DIR=live` to run every unit, or `TG_WORKING_DIR=live/infra` to run only that group.

- `init` runs `init -reconfigure` in every unit.
- `plan` saves one plan per unit under `terragrunt.plan/` in the working directory and removes old plans first.
- `apply` applies those saved plans and fails when `terragrunt.plan/` is missing. Terragrunt asks once before it applies.
- `destroy` runs without a saved plan. Terragrunt asks once before it destroys.
- `TF_AUTO_APPROVE` makes `apply` and `destroy` skip that question.

`tf edit-vars` runs `sops edit` on one file. Pass the path to choose it directly. Without a path, it finds every `*.tfvars.sops.json` under the project root: one match opens at once, several open a fuzzy finder (the `skim` Nushell plugin, loaded by the `prefrio` package).

Logs are Nushell records with `level` and `message` fields.

Run the deterministic smoke tests from this repository:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

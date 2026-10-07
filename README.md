# flakes

Shared Nix packages for Prefeitura do Rio infrastructure projects.

## prefrio

A Nushell CLI for Terragrunt, SOPS and Kubernetes. Set `TG_WORKING_DIR` in the project flake (for example `"live"`), then run:

```nu
prefrio auth                    # Google Cloud login
prefrio get-kubeconfig          # GKE credentials, from .project.nuon
prefrio k get pods -n gitlab    # kubectl through the Tailscale K3s API
prefrio tf init
prefrio tf plan
prefrio tf apply
prefrio tf destroy
prefrio tf edit-vars [file]
```

- **`tf`** runs `terragrunt run --all` in `TG_WORKING_DIR`. A relative path is resolved from the project root: the nearest `.project.nuon`, else the Git root, else the current directory.
- **`plan`** saves plans in `terragrunt.plan/`. `apply` uses them and fails without them. Terragrunt asks once before `apply` and `destroy`; `TF_AUTO_APPROVE` skips the question.
- **`edit-vars`** runs `sops edit`. Without a path it picks among `*.tfvars.sops.json` files, with a fuzzy finder when there are several.
- **`k`** needs no kubeconfig. `KUBE_HOST` replaces the default API server and is also read by the Terraform providers.
- **`.project.nuon`** is optional, only for `get-kubeconfig`: `{project: rj-x, k8s: {cluster: c, region: us-central1}}`.

Run the tests:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

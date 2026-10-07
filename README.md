# flakes

Shared Nix packages for Prefeitura do Rio infrastructure projects.

## prefrio

A Nushell CLI for Terragrunt, SOPS and Kubernetes. A project configures it with environment variables in its flake dev shell:

```nix
TG_WORKING_DIR = "live";                    # where Terragrunt runs
CLOUDSDK_CORE_PROJECT = "rj-my-project";    # for get-kubeconfig
CLOUDSDK_COMPUTE_REGION = "us-central1";    # for get-kubeconfig
CLOUDSDK_CONTAINER_CLUSTER = "gitlab";     # for get-kubeconfig
```

```nu
prefrio auth                    # Google Cloud login
prefrio get-kubeconfig          # gcloud container clusters get-credentials gitlab
prefrio k get pods -n gitlab    # kubectl through the Tailscale K3s API
prefrio tf init
prefrio tf plan
prefrio tf apply
prefrio tf destroy
prefrio tf edit-vars [file]
```

- **`tf`** runs `terragrunt run --all` in `TG_WORKING_DIR`. A relative path is resolved from the Git root, or the current directory outside a repository.
- **`plan`** saves plans in `terragrunt.plan/`. `apply` uses them and fails without them. Terragrunt asks once before `apply` and `destroy`; `TF_AUTO_APPROVE` skips the question.
- **`edit-vars`** runs `sops edit`. Without a path it picks among `*.tfvars.sops.json` files, with a fuzzy finder when there are several.
- **`get-kubeconfig`** passes extra flags to `gcloud`, for example `--region`. For another cluster, set `CLOUDSDK_CONTAINER_CLUSTER` on that command.
- **`k`** needs no kubeconfig. `KUBE_HOST` replaces the default API server and is also read by the Terraform providers.

Run the tests:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

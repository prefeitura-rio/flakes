# flakes

Shared files for Prefeitura do Rio infrastructure projects.

## prefrio

The Flake provides one Nushell CLI with auto-imported `tf` and `k3s` modules for OpenTofu, SOPS and Kubernetes operations. Enter a project Flake with `direnv allow` or `nix develop`, then run:

```nu
prefrio --help
prefrio tf init
prefrio tf plan
prefrio tf plan --prod
prefrio k3s get-kubeconfig
prefrio k8s --prod
```

Projects define their staging and production settings in `.project.nuon`:

```nuon
{
  name: my-project
  tf: {dir: terraform}
  env: {
    staging: {
      project: rj-civitas-dev
      vars: terraform.tfvars.sops.json
      backend: {prefix: my-project/staging}
    }
    prod: {
      project: rj-civitas-prod
      vars: terraform.tfvars.prod.sops.json
      backend: {prefix: my-project/prod}
    }
  }
}
```

Staging is the default. Add `--prod` to `tf init`, `tf plan`, `tf apply`, `tf destroy`, `tf edit-vars`, or `k8s` to select production. A project without the requested `prod` entry fails instead of falling back to base settings. Staging plans use `tofu.plan`; production plans use `tofu.prod.plan`. Always use the same `--prod` flag for `plan` and `apply`, so a staging apply cannot consume a production plan or the reverse. Apply fails with a clear message when the selected plan file is missing. Target selection does not use `ENV` or `TF_ENVIRONMENT`. The CLI detects the project from the current directory. It decrypts SOPS files into temporary files only for the child process and removes them after success or failure. OpenTofu handles confirmation for apply and destroy; `TF_AUTO_APPROVE` adds `--auto-approve` to apply. Logs are Nushell records with `level` and `message` fields.

Run the deterministic smoke tests from this repository:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

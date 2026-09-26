# flakes

Shared files for Prefeitura do Rio infrastructure projects.

## prefrio

The Flake provides one Nushell CLI with auto-imported `tf` and `k3s` modules for OpenTofu, SOPS and Kubernetes operations. Enter a project Flake with `direnv allow` or `nix develop`, then run:

```nu
prefrio --help
$env.ENV = "staging"
prefrio tf plan
prefrio k3s get-kubeconfig
```

The CLI detects the project from the current directory. It decrypts SOPS files into temporary files only for the child process and removes them after success or failure. OpenTofu handles confirmation for apply and destroy; `TF_AUTO_APPROVE` adds `--auto-approve` to apply. Logs are Nushell records with `level` and `message` fields.

Run the deterministic smoke tests from this repository:

```nu
nix develop --command nu -c 'use nutest; nutest run-tests --path tests/scripts_test.nu --fail'
```

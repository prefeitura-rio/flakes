# prefrio

CLI for Terragrunt, SOPS and Kubernetes. A project is a directory with a `.project.json`; its Terraform units live in `units/<module>/<environment>`.

Run `prefrio --help` to list the commands, and `prefrio <command> --help` for the flags of one command (for example `prefrio tf plan --help`).

## Project file

`prefrio` walks up from the current directory to the first `.project.json`.

```json
{
  "name": "superapp",
  "env": {
    "stg": { "project": "rj-superapp-staging", "region": "us-central1", "cluster": "application" },
    "prod": { "project": "rj-superapp", "region": "us-central1", "cluster": "application" }
  }
}
```

Use the environment key `default` for a project with one environment, and `stg` and `prod` otherwise.

## Use

```nix
{ pkgs, inputs, ... }:
{
  overlays = [ inputs.prefrio.overlays.default ];
  packages = [ pkgs.prefrio ];
}
```

`pkgs.prefrio` has the CLI plus gcloud, kubectl, OpenTofu, SOPS and Terragrunt. Run the tests with `run-tests` in `devenv shell`.

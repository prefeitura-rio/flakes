# flakes

Nix packages for Prefeitura do Rio infrastructure. Each package lives in its own folder, with its build instructions (`default.nix`), its README and its tests. `flake.nix` only lists what the flake exposes, and `overlays.nix` loads the packages.

| Package                           | Description                             |
| --------------------------------- | --------------------------------------- |
| [prefrio](pkgs/prefrio/README.md) | CLI for Terragrunt, SOPS and Kubernetes |

Every `.nix` file under `pkgs/` is a module that defines an overlay: `overlays.<name> = final: _prev: { <name> = ...; };`. `overlays.nix` loads them all with [import-tree](https://github.com/denful/import-tree), composes them into `overlays.default`, exposes each one as `overlays.<name>`, and builds `packages.<system>` from that same overlay. A file or folder whose name starts with `_` is skipped, so a helper that is not a module must start with `_`.

## Devenv profiles

Each file in `devenv/` is a devenv module that a project can import. A project declares this flake as an input and lists the profiles it wants:

```yaml
inputs:
  prefrio:
    url: github:prefeitura-rio/flakes
imports:
  - prefrio/devenv/infra.nix
```

| Profile                   | Description                                                                                                     |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- |
| [infra](devenv/infra.nix) | prefrio, `TF_LIB` with the shared Terragrunt root and the tflint and tfsec configs, and the Terraform git hooks |

A profile can use only the inputs that every project declares: `nixpkgs`, `git-hooks` and `prefrio`.

Files that belong to a profile, such as a config file, live in `devenv/files/<profile>/`, and the profile refers to them by relative path:

```
devenv/
├── infra.nix
└── files/
    └── infra/
        ├── root.hcl
        ├── tflint.hcl
        └── tfsec.yml
```

```nix
env.TFLINT_CONFIG_FILE = "${./files/infra}/tflint.hcl";
```

The path is a store path once a project imports the profile, so the files are pinned with the lock and cannot change underneath a project.

`TF_LIB` points at `devenv/files/infra`. A Terragrunt unit includes the shared root from there:

```hcl
include "root" {
  path   = "${get_env("TF_LIB")}/root.hcl"
  expose = true
}
```

The root finds the project through its `.project.json`, which must define `state_prefix`. Units live in `units/<module>` for a project with one environment, and in `units/<module>/<environment>` otherwise.

`tflint.hcl` and `tfsec.yml` are the only tflint and tfsec configs. `prefrio tf scan` passes `tfsec.yml` to tfsec, so an exclusion applies to every project and a project does not carry its own `.tfsec/config.yml`.

## Development

New to Nix, flakes or devenv? Read [docs/nix.md](docs/nix.md).

Development uses devenv. `devenv shell` opens a shell with Nushell, nu-lint and nixfmt, and the tests run as devenv tasks:

```bash
devenv shell
devenv tasks run <pkg>:test
devenv tasks run pkgs:test # use this to run all tests in all packages
```

## Adding a package

1. Create `pkgs/<name>/` with a `default.nix` that defines `overlays.<name>`, a `README.md`, and a `tests/` folder. The flake picks it up with no other change.
2. In `devenv.nix`, add a `<name>:test` task and list it in the `after` of `pkgs:test`.

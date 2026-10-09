# flakes

Nix packages for Prefeitura do Rio infrastructure. Each package lives in its own folder, with its build instructions (`default.nix`), its README and its tests. `flake.nix` only lists what the flake exposes, and `overlays.nix` loads the packages.

| Package                           | Description                             |
| --------------------------------- | --------------------------------------- |
| [prefrio](pkgs/prefrio/README.md) | CLI for Terragrunt, SOPS and Kubernetes |

Every `.nix` file under `pkgs/` is a module that defines an overlay: `overlays.<name> = final: _prev: { <name> = ...; };`. `overlays.nix` loads them all with [import-tree](https://github.com/denful/import-tree), composes them into `overlays.default`, exposes each one as `overlays.<name>`, and builds `packages.<system>` from that same overlay. A file or folder whose name starts with `_` is skipped, so a helper that is not a module must start with `_`.

## Development

`flake.nix` has no development shell. Work in the devenv environment, which brings Nushell, nu-lint, nixfmt and the test runner:

```bash
devenv shell
devenv tasks run <pkg>:test
devenv tasks run pkgs:test # use this to run all tests in all packages
```

## Adding a package

1. Create `pkgs/<name>/` with a `default.nix` that defines `overlays.<name>`, a `README.md`, and a `tests/` folder. The flake picks it up with no other change.
2. In `devenv.nix`, add a `<name>:test` task and list it in the `after` of `pkgs:test`.

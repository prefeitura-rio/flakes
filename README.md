# flakes

Nix packages for Prefeitura do Rio infrastructure. Each package lives in its own folder, with its build instructions (`pkg.nix`), its README and its tests. `flake.nix` only wires the packages together.

| Package                      | Description                             |
| ---------------------------- | --------------------------------------- |
| [prefrio](prefrio/README.md) | CLI for Terragrunt, SOPS and Kubernetes |

The flake exposes each package as `packages.<system>.<name>`, and `overlays.default` adds them to `pkgs`.

## Development

`flake.nix` has no development shell. Work in the devenv environment, which brings Nushell, nu-lint, nixfmt and the test runner:

```bash
devenv shell
run-tests
```

## Adding a package

1. Create a folder with a `pkg.nix` that takes `{ pkgs }` and returns the package, a `README.md`, and a `tests/` folder.
2. Add the package to `packages` and to `overlays.default` in `flake.nix`.

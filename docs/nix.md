# Nix in this repository

This repository builds its packages with Nix and is developed with devenv. This page explains the pieces in a few lines each, then shows how they fit together here.

**In this page:** [Nix](#nix) · [Modules](#modules) · [Overlays](#overlays) · [Flakes](#flakes) · [devenv](#devenv) · [How this repository uses them](#how-this-repository-uses-them) · [Installation](#installation) · [Conventions](#conventions)

> [!TIP]
> Just want to set up your machine? Jump to [Installation](#installation).

## Nix

Nix is a package manager and build system with its own purely functional language.

- A package is a **derivation**: a build recipe whose result is stored in an immutable path, `/nix/store/<hash>-<name>`. The hash covers every input, so the same inputs give the same path.
- **nixpkgs** is the large collection of packages and library functions (`lib`) written in that language.

About the language:

- The language is lazy and functional.
- A function takes one argument, often an attribute set (`{ pkgs }: ...`).
- You will mostly meet `let ... in`, `with`, `//` (merge) and `inherit`.

Official docs: [Nix tutorials](https://nix.dev/tutorials/)

| Topic                      | Video (Vimjoyer)                                                                                                                              |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix and its ecosystem      | [Nix(OS) Ecosystem Explained](https://www.youtube.com/watch?v=X_jMqi-0SrM)                                                                    |
| The language and functions | [Nix Language Explained](https://www.youtube.com/watch?v=UgrwoAGSPOQ), [Nix Functions Explained](https://www.youtube.com/watch?v=HiTgbsFlPzs) |
| Derivations and packages   | [Nix is Simpler Than You Think: Derivations & Packages](https://www.youtube.com/watch?v=GBTTVrmqkfE)                                          |

## Modules

- A module is a Nix file with a fixed structure: it declares **options**, the settings other modules can set, and it defines values for the options it wants to set.
- The module system merges all modules into one result.
- NixOS is built from modules, but the system is general: `lib.evalModules` evaluates any set of modules, and this repository uses it on its own to collect overlays.

| Topic   | Official docs                                                                | Video (Vimjoyer)                                                             |
| ------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Modules | [Module system tutorial](https://nix.dev/tutorials/module-system/index.html) | [NIXBITS: NixOS Module Anatomy](https://www.youtube.com/watch?v=xdDZT1cEuLU) |

## Overlays

- An overlay is a function `final: prev: { ... }` that adds or changes packages in nixpkgs.
- `prev` is the package set before the overlay, and `final` is the result with every overlay applied, so take dependencies from `final`.
- Applying overlays to nixpkgs gives a new package set.
- This is how this repository ships its packages.

| Topic    | Official docs                                                 | Video (Vimjoyer)                                                                            |
| -------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Overlays | [Overlays (NixOS Wiki)](https://wiki.nixos.org/wiki/Overlays) | [Customize Nix Packages: Overrides & Overlays](https://www.youtube.com/watch?v=jHb7Pe7x1ZY) |

## Flakes

- A flake is a directory with a `flake.nix` that declares its **inputs** (dependencies, pinned in `flake.lock`) and its **outputs**: a function from the inputs to an attribute set such as `packages.<system>` or `overlays`.
- Other projects use a flake by URL, for example `github:prefeitura-rio/flakes`.

> [!NOTE]
> A flake only sees files that git knows about. A new file must be added (`git add -N <file>` is enough) before the flake can read it.

| Topic  | Official docs                                                                                                                                             | Video (Vimjoyer)                                                         |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Flakes | [Flakes on nix.dev](https://nix.dev/concepts/flakes.html), [`nix flake` reference](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html) | [Ultimate Nix Flakes Guide](https://www.youtube.com/watch?v=JCeYq72Sko0) |

## devenv

- devenv builds a development environment from a declarative file.
- `devenv.nix` lists packages, environment variables, tasks and git hooks.
- `devenv.yaml` declares the inputs and imports, and `devenv.lock` pins them.
- You work with `devenv shell` and `devenv tasks run`.

| Topic  | Official docs                   | Video (Vimjoyer)                                                                                         |
| ------ | ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| devenv | [devenv.sh](https://devenv.sh/) | [Devenv.sh: Instant Reproducible Dev Environments with Nix](https://www.youtube.com/watch?v=Oj9AxyiaVvU) |

## How this repository uses them

```text
flake.nix        inputs (nixpkgs, import-tree) and the outputs: overlays and packages
overlays.nix     loads pkgs/ and builds the overlays
pkgs/<name>/     one package: default.nix, its sources, README.md and tests/
devenv.nix       development environment: tools, test tasks, nixfmt hook
devenv.yaml      devenv inputs: nixpkgs, git-hooks, nutest
flake.lock       pinned inputs of the flake
devenv.lock      pinned inputs of devenv
```

How a package gets from a file to `pkgs.prefrio`:

1. `pkgs/<name>/default.nix` is a module that defines an [overlay](#overlays): `overlays.<name> = final: _prev: { <name> = <derivation>; };`.
2. `overlays.nix` loads every `.nix` file under `pkgs/` with [import-tree](https://github.com/denful/import-tree) and evaluates them with the module system. That collects the overlays, and adds `default`, which composes them all.
3. `flake.nix` exposes the `overlays`, and builds `packages.<system>` by applying `overlays.default` to nixpkgs.
4. A consumer, such as the infra repository, adds the flake as an input and uses `inputs.prefrio.overlays.default`. Then `pkgs.prefrio` is available in its devenv.

The package itself is built in `pkgs/prefrio/default.nix`:

- `writeShellApplication` makes the `prefrio` launcher, which runs the Nushell script with a Nushell that has the skim plugin (`nushell.withPlugins`).
- `buildEnv` joins the launcher with the tools it drives: gcloud, kubectl, OpenTofu, SOPS and Terragrunt.

## Installation

Install Nix, enable flakes, then install devenv. Official guides: [Install Nix](https://nix.dev/install-nix), [Nix downloads](https://nixos.org/download/) and [devenv: getting started](https://devenv.sh/getting-started/). The commands below come from them.

### 1. Install Nix

**Linux**

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

**macOS**

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install
```

Open a new terminal and run `nix --version`. macOS ships an old Bash, so the devenv guide recommends a newer one from nixpkgs:

```bash
nix-env --install --attr bashInteractive -f https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable
```

### 2. Enable flakes

> [!IMPORTANT]
> The `nix` command and flakes are experimental features, off by default, and the installers above do not enable them. Until you enable them, `nix` commands fail with `experimental Nix feature 'nix-command' is disabled`.

To enable flakes, run:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

### 3. Install devenv

```bash
nix-env --install --attr devenv -f https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable
```

To upgrade it later:

```bash
nix-env --upgrade --attr devenv -f https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable
```

Check it with `devenv --version`. Then `devenv shell` in this repository gives you the development environment.

## Conventions

- Nix files have no comments. The documentation lives in option `description` and `example` fields, in package `meta`, and in the READMEs.
- Every `.nix` file under `pkgs/` is loaded as a module. A helper that is not a module must have a name starting with `_`, which import-tree skips.
- A new package is one folder under `pkgs/`; the flake needs no other change. Add its `<name>:test` task to `devenv.nix` and list it in `pkgs:test`.

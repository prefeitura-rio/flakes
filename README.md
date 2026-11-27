# flakes

Nix packages for Prefeitura do Rio infrastructure. Each package lives in its own folder, with its build instructions (`default.nix`), its README and its tests. `flake.nix` only lists what the flake exposes, and `overlays.nix` loads the packages.

| Package | Description |
| --- | --- |
| [complexipy](pkgs/complexipy/README.md) | Python cognitive-complexity analyzer |
| [prefrio](pkgs/prefrio/README.md) | CLI for Terragrunt, SOPS and Kubernetes |
| `quality-gate` | Central Quality Gate app; language-specific apps are also exposed |

Every `.nix` file under `pkgs/` is a module that defines an overlay: `overlays.<name> = final: _prev: { <name> = ...; };`. `overlays.nix` loads them all with [import-tree](https://github.com/denful/import-tree), composes them into `overlays.default`, exposes each one as `overlays.<name>`, and builds `packages.<system>` from that same overlay. A file or folder whose name starts with `_` is skipped, so a helper that is not a module must start with `_`.

## Devenv profiles

Each file in `devenv/` is a devenv module that a project can import. A project declares this flake as an input and lists the profiles it wants:

```yaml
profile: quality-gate

inputs:
  git-hooks:
    url: github:cachix/git-hooks.nix
    inputs:
      nixpkgs:
        follows: nixpkgs
  prefrio:
    url: github:prefeitura-rio/flakes
  quality-gate:
    url: github:prefeitura-rio/flakes/quality-gate-latest
imports:
  - prefrio/devenv/infra.nix
  - quality-gate/devenv/quality-gate.nix
```

The Quality Gate profile has its own input, pinned to the `quality-gate-latest`
channel. The engine already runs from that channel; this makes the bootstrap
(the hook wrapper and the runner) follow it as well, so a change to either one
reaches consumers only after its bake time. Pinning the whole `prefrio` input to
the channel would also freeze the infrastructure profile, which has its own
cadence. The profile uses nothing from the other inputs, so a separate input is
enough.

Set `profile: quality-gate` when the repository must install the quality-gate
hooks on ordinary `devenv shell` entry. Alternatively, select the profile once
when trusting the directory:

```bash
devenv --profile quality-gate allow
```

This follows the bootstrap used by the other devenv repositories: after a
clone, the developer configures the shell hook once, for example:

```bash
eval "$(devenv hook bash)"
```

Then `devenv allow` authorizes automatic activation for the repository.
Devenv/prek installs `.git/hooks/pre-commit` during that first activation.
Later directory entries and commits from a terminal, IDE or GUI use the same
environment and Git hook without manually running `devenv shell` each time.

| Profile | Description |
| --- | --- |
| [infra](devenv/infra.nix) | prefrio, `TF_LIB` with the shared Terragrunt root, ast-grep, tflint and tfsec configs, and the Terraform git hooks |
| [quality-gate](devenv/quality-gate.nix) | Opt-in Python, Go and TypeScript format, lint, structural-lint, typecheck and application-test tasks |

A profile can use only the inputs that every project declares: `nixpkgs`, `git-hooks` and `prefrio`.

The quality-gate profile is intentionally opt-in. Importing it makes the
profile available, but it does not add its tools or tasks to the default
environment:

```bash
devenv tasks list
devenv --profile quality-gate tasks list
devenv --profile quality-gate tasks run quality-gate:all
```

Files that belong to a profile, such as a config file, live in `devenv/files/<profile>/`, and the profile refers to them by relative path:

```
devenv/
├── infra.nix
├── quality-gate.nix
└── files/
    ├── infra/
    │   ├── ast-grep/
    │   ├── root.hcl
    │   ├── tflint.hcl
    │   └── tfsec.yml
    └── quality-gate/
        ├── go/
        ├── python/
        ├── typescript/
        └── quality-gate.nu
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

The `ast-grep/` directory holds structural rules, tests and snapshots for every infrastructure repository that imports this profile. Add a test with each rule. Run `ast-grep test --config devenv/files/infra/ast-grep/sgconfig.yml` in this repository. In an importing repository, run `ast-grep scan --config $TF_LIB/ast-grep/sgconfig.yml --no-ignore hidden`.

## Quality gate

The `quality-gate` profile bootstraps the organization's static checks on Go,
Python and TypeScript projects. The executable motor is the flake app, published
as `quality-gate-latest`; the profile does not provide an alternative copy of
the rules or tools. This keeps the flakes as the only source of truth.

The Quality Gate apps use the separate `nixpkgs-quality-gate` input. The regular
`nixpkgs` input remains reserved for the other flakes packages, such as
`prefrio`, so updating Quality Gate tools does not rebuild or change unrelated
package derivations.

```bash
nix run github:prefeitura-rio/flakes/quality-gate-latest#quality-gate -- category lint
```

The profile is opt-in: import it, then select it with `--profile quality-gate`.
Its tasks delegate to the same app used by the CI and its hooks. The consumer's
`devenv.lock` is not a source of Quality Gate rules or tool versions.

```bash
devenv --profile quality-gate tasks run quality-gate:all
devenv --profile quality-gate tasks run quality-gate:tests
```

### Tasks

| Task                                                                       | What it runs                                                                     |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `quality-gate:all`                                                         | format, lint, strlint and typecheck for every detected project                   |
| `quality-gate:format`, `:lint`, `:strlint`, `:typecheck`                   | one category for every detected project                                          |
| `quality-gate:detect`                                                      | lists the detected projects without running checks                               |
| `quality-gate:tests`                                                       | the repository tests of every detected project                                  |
| `format:<language>:all`, `lint:<language>:all`, `typecheck:<language>:all` | every format, lint or typecheck check of one language (`python`, `go`, `typescript`) |
| `format:<language>:<tool>`, `lint:<language>:<tool>`, `typecheck:<language>:<tool>` | a single check, for example `typecheck:python:basedpyright`                |

`strlint` is the structural lint, done with ast-grep. `quality-gate:all` does not run `quality-gate:tests`: static policy is central, while the test contract belongs to each repository.

### Manual tasks and the `qg` alias

A developer can run any granular task manually:

```bash
devenv --profile quality-gate tasks run lint:python:complexipy
devenv --profile quality-gate tasks run typecheck:python:basedpyright
devenv --profile quality-gate tasks run lint:python:all
```

Inside the devenv shell, the profile also exposes the shorter `qg` command.
It invokes the same central Nushell script without requiring the long
`devenv --profile quality-gate tasks run` prefix:

```bash
qg lint py
qg lint python
qg strlint ts
qg strlint typescript
```

The alias accepts only the task and the language. It never receives a tool
name:

```bash
qg lint py
qg lint python
qg strlint ts
qg strlint typescript
qg format go
qg typecheck typescript
```

The first argument is the task category. The second argument can be the
language abbreviation (`py`, `ts`) or its full name (`python`, `typescript`).
The task category runs all checks belonging to that language and category.

The full `quality-gate` command remains available when a descriptive command
name is preferred. It delegates to the published flake app:

```bash
quality-gate category lint
```

The profile also provides language-specific pre-commit hooks:

| Hook | Tasks covered |
|---|---|
| `quality-gate:python` | Python format and all Python lint, type and structural checks |
| `quality-gate:go` | Go format, lint, build typecheck and structural checks |
| `quality-gate:typescript` | TypeScript format and all TypeScript lint, type and structural checks |

The hooks are selected by staged file patterns and do not run
`quality-gate:tests`. A consumer that imports the profile must declare the
`git-hooks` input.

Hooks may auto-fix supported formatting and lint issues, but they must not
run `git add`. After an auto-fix, the hook rejects the current commit so the
developer can review the changes and stage them explicitly.

### Test workflow

The `quality-gate:tests` task discovers every supported project and delegates
the test execution to the project:

| Language | Runner |
|---|---|
| Python | `uv run pytest` |
| Go | `go test ./...` |
| TypeScript | the `scripts.test` command through npm or pnpm |

In the GitLab pipeline, `quality-gate:tests` waits for `format`, `lint`,
`strlint` and `typecheck`. The pre-commit hooks do not run tests. Coverage and
the semantic quality of tests are outside this profile and belong to Kodus. A
project without local test files fails with `No local tests were found`.

The Quality Gate does not invoke a consumer's `devenv test`. A repository may
keep richer tasks that start its own `processes` or `services`, such as
integration suites. Those tasks remain owned and invoked by the repository;
the shared profile only runs the generic project test runners above.

### Project discovery

Projects are found recursively under `QUALITY_GATE_PROJECT_DIR`, which defaults to the current directory. A directory is a project when it has:

| Language   | Markers                                |
| ---------- | -------------------------------------- |
| Python     | `pyproject.toml` or `setup.py`         |
| Go         | `go.mod`                               |
| TypeScript | `package.json` and `tsconfig.json`     |

Each project is checked on its own, so a monorepo reports one result per project, language and check. A project inside another project of the same language is checked as itself only: its files are not checked again by the project around it, and a change inside it selects it, not the outer one, in the hooks. A workspace member (npm, pnpm or uv) uses the lockfile, `.node-version` and `node_modules` of the workspace root. Inside a Git repository, discovery uses tracked and non-ignored untracked files, so directories such as `tools/` are valid projects while `node_modules`, `.venv`, `dist` and other ignored files are excluded. Outside Git, a short fallback list excludes generated and dependency directories. The command fails when no project is found.

### Checks

| Language   | format                | lint                                         | strlint | typecheck                  | quality-gate:tests                   |
| ---------- | --------------------- | -------------------------------------------- | ------- | -------------------------- | ------------------------------------ |
| Python     | `ruff format --check` | `ruff check`, `complexipy`                   | ast-grep | `basedpyright`             | `uv run pytest`                      |
| Go         | `gofumpt`, `goimports` | `golangci-lint`, `go vet`                  | ast-grep | `go build ./...`           | `go test ./...`                      |
| TypeScript | `oxfmt`               | `oxlint` (React/Next/a11y plugins when applicable) | ast-grep | `tsc`, `vue-tsc` or `nuxt` | `npm test` or `pnpm test` |

TypeScript handling is framework aware:

- Next.js enables the Oxlint React, JSX accessibility and Next.js plugins and ignores `.next/` and `out/`. React projects enable the React and JSX accessibility plugins.
- Vue `<script>` blocks, including the `setup` and `lang` variants, are scanned by the shared ast-grep rules.
- Typecheck is always invoked by the central runner (`tsc` or `vue-tsc`, the
  project's own, from `node_modules/.bin`) with the mandatory Quality Gate
  compiler options. The same compiler expands the config, so `.vue` files are
  listed. Nuxt projects run `nuxt prepare` first. A consumer's
  `scripts.typecheck` is not used for this global check.
- The files come from the project's `files` and `include`. Its `exclude` is not
  honoured (only `node_modules`, `bower_components`, `jspm_packages` and
  `outDir` stay out): to leave code out of the Quality Gate, list it in
  `.quality-gate/exclude`, where it is reviewed and shown in the report.
- Generated solution-reference configs use the `.quality-gate-tsconfig.*.json`
  name beside the source config and are removed after the check; consumers
  should ignore that pattern.
- Typecheck and tests need a committed lockfile, `package-lock.json` for npm or `pnpm-lock.yaml` for pnpm. A pnpm lockfile also needs `packageManager: pnpm@<version>` in `package.json`.
- Typecheck needs a `.node-version` file, or `QUALITY_GATE_NODE_VERSION`.
- `quality-gate:tests` requires `scripts.test` in `package.json` for TypeScript projects.

Python projects with a `pyproject.toml` are synchronized with `uv sync --locked --all-groups`, so they need a compatible `uv.lock`, found in the project or in a parent directory up to the repository root (a uv workspace member uses the lock of its root). The environment lives in the Quality Gate cache (`$XDG_CACHE_HOME/quality-gate/venvs`), never in the repository: the developer's own `.venv` is not touched, and `uv sync` cannot prune packages installed by hand.
The temporary basedpyright configuration is created as
`.quality-gate-pyrightconfig.json` beside the project config and removed after
the check; consumers should ignore that exact filename in `.gitignore`.

### Configuration precedence

The four Quality Gate categories are centrally enforced in every execution:

- `format` always uses the central formatter configuration and versions;
- `lint` always uses the central Ruff, golangci-lint and Oxlint configurations;
- `strlint` always runs the central ast-grep rules; repository rules are additive;
- `typecheck` always applies the central basedpyright and TypeScript strictness
  settings.

Repository-local formatter and linter configurations are intentionally ignored
by the Quality Gate. This prevents a consumer from weakening the corporate
floor. Project-local TypeScript configuration is used only for project
structure, paths and framework resolution; the Quality Gate overwrites its
mandatory compiler options. Local `tsconfig` exclusions cannot remove files
from the Quality Gate scope.

Structural lint is additive. The central ast-grep rules always run first. Then the repository's own rules run, if it has `.quality-gate/sgconfig.yaml` or `.quality-gate/rules/`. A repository can add rules but cannot remove the central ones. A generic root `rules/` directory or `sgconfig.yaml` is intentionally ignored.

### Central exclusions

Repositories may add one `.quality-gate/exclude` at the repository root. It uses
one path/glob per line, with blank lines and `#` comments ignored. Exclusions
are intended only for generated code, migrations and vendored code; they cannot
disable an individual rule. A nested `.quality-gate/exclude` is rejected. The
runner applies the paths to project discovery, auto-fix,
Python/Ruff, complexipy, TypeScript/Oxlint/Oxfmt/tsc, ast-grep, basedpyright,
golangci-lint and the Go package list used by `go vet` and `go build`.
Generated code is analysed like any other: golangci-lint does not skip a file
because it says `Code generated ... DO NOT EDIT`, since a comment is enough to
turn the Quality Gate off for a file. List generated code here.
Keep this file under CODEOWNERS review in consumers.

```text
# Generated client code
generated/
db/migrations/**
```

### Check names

A check is identified as `<category>:<language>:<tool>`, for example
`format:go:gofumpt`, `lint:python:ruff`, `strlint:...` per language and
`typecheck:python:basedpyright`, `typecheck:typescript:tsc`,
`typecheck:go:build`. These names are what the JUnit reports, the canary
expectations and the devenv tasks use, so a name is part of the contract.

### Reports

Every category prints a Markdown table to the terminal with one row per project, language and check, and the output of a failing check is printed as it runs. The Markdown and JUnit reports also include each failure's output and an actionable next step:

- Markdown and JUnit remove terminal escape codes while preserving Unicode.
- Successful dependency-install output stays in the job log, not the typecheck
  diagnostic. Failed installations retain their output in the reports.
- For recognized lint diagnostic formats, the Markdown summary counts parsed
  rules and severities. Counts can be incomplete; they do not affect the verdict.
- When a JUnit file is configured, a long diagnostic in the Markdown summary
  is limited to 32,768 UTF-8 bytes and points to the complete JUnit and job log.
  Without a JUnit destination it is not truncated. JUnit keeps the complete
  diagnostic after known warning suppression so the canary sees the full proof.
- The reports omit only known redundant gocritic configuration warnings; the
  complete unfiltered output remains in the job log.

These variables write reports to files:

| Variable                        | Output                                            |
| ------------------------------- | ------------------------------------------------- |
| `QUALITY_GATE_SUMMARY_FILE`     | Markdown report with failure details and fixes    |
| `QUALITY_GATE_JUNIT_FILE`       | JUnit XML report                                  |
| `QUALITY_GATE_DETECTION_FILE`   | detected languages and project count, as `KEY=value` lines |
| `QUALITY_GATE_PROJECT_DIR`      | directory to scan                                 |
| `QUALITY_GATE_NODE_VERSION`     | Node.js version when there is no `.node-version`  |
| `QUALITY_GATE_REF`              | release tag or SHA resolved by the local hook     |
| `QUALITY_GATE_MODE`             | `block` (default) or time-limited `report`       |
| `QUALITY_GATE_REPORT_UNTIL`     | required deadline for report-only mode           |

The tools, including `complexipy` and Oxlint, are pinned by this repository.
The consumer's `devenv.lock` does not fix the Quality Gate versions or rules.

Each failed check is classified in the console, Markdown and JUnit reports:

- `finding`: the checked code did not satisfy the central policy (normally
  tool exit code `1`). This is an expected apuração result for a codebase that
  still has findings and is not evidence that the Quality Gate motor failed.
- `engine`: the motor or its execution environment failed (for example a
  missing tool/configuration, an unexpected command failure, or an exit code
  other than `1`). Engine failures are release and canary-health failures.

The distinction is intentionally preserved even though both categories block
the default `QUALITY_GATE_MODE=block` execution. Consumers that analyze
fixtures or canary sandboxes can allow only the configured `finding` results;
an `engine` result must remain unhealthy.

### Report-only rollout

The default mode is blocking. A consumer may temporarily set
`QUALITY_GATE_MODE=report` while adopting the curated policy, but must also set
`QUALITY_GATE_REPORT_UNTIL=YYYY-MM-DD`. The deadline cannot be more than 45 days
ahead and an expired/missing deadline blocks the execution. All checks and
reports still run, but failures are marked `REPORT-ONLY` during the valid
window. In GitLab CI, the project and exact deadline must also be present in
the central `policy/report-only.yaml` allowlist. The adapter provides the
project through `QUALITY_GATE_REPORT_PROJECT`; when `CI` is set and it is
missing, report-only mode is refused. Removing the variable returns
the consumer to blocking mode. Report-only applies to the static checks: the
project's own tests keep blocking.

### Runtimes

Each project picks its own runtime, so a monorepo can mix versions:

- **Node.js** 22, 24 and 26 are bundled. The major in the project's
  `.node-version` (or `QUALITY_GATE_NODE_VERSION`) selects the runtime for that
  project's install, typecheck and tests; a major that is not bundled fails with
  an `engine` error instead of silently using another one.
- **Python** 3.11 to 3.14 are bundled and `uv` may use only those (no
  downloads). `.python-version` or `requires-python` selects the interpreter;
  a version that is not bundled fails with an `engine` error. The Python app is
  about 380 MiB larger because it carries four interpreters.
- **Go** never downloads a toolchain (`GOTOOLCHAIN=local`). The Quality Gate
  runs Go checks and tests with `CGO_ENABLED=0`, even if the caller sets it to
  `1`. Cgo-dependent packages and files can be skipped by Go; console, Markdown
  and JUnit reports list detected project files omitted for this reason, or
  warn when detection is incomplete. Format and structural checks may still
  inspect those files. A project that requires cgo may fail to build with it
  disabled; `go test -race` also requires cgo. Such projects must run those
  checks separately in their own environment.
- TypeScript is checked with the project's own `node_modules/.bin/tsc` (or
  `vue-tsc`), so the project must declare `typescript` and commit its lockfile.

### Finding or engine

Every failed check in the console, Markdown and JUnit reports is classified.
The classification follows the tool's exit code, not its text:

| Tool | `finding` | `engine` |
| --- | --- | --- |
| ruff, ruff format, oxfmt, oxlint, ast-grep, complexipy, basedpyright, `go vet`, `go build` | exit 1 | any other non-zero exit |
| golangci-lint | exit 1 | exit 3 (it could not run) and anything else |
| `tsc`, `vue-tsc` | exit 1 or 2 | any other non-zero exit |
| `pytest`, `go test`, `npm test`, `pnpm test` | any failure | - |
| `uv sync`, `npm ci`, `pnpm install` | - | any failure |
| a missing lockfile, `.node-version`, `uv.lock`, project compiler or `scripts.test`, or an invalid `tsconfig.json` | the consumer's configuration | - |

Oxlint reports an invalid configuration with exit 1, so that one message is
treated as `engine`. The canary analysis considers any `engine` result a failure
of the Quality Gate itself. See [the classification map](docs/quality-gate-error-classification.md)
for current limits and follow-ups.

Inline suppressions must identify the specific rule and include a justification.
The central policies reject blanket suppressions, in every language:

| Language | Rejected | By |
| --- | --- | --- |
| TypeScript | `eslint-disable` / `oxlint-disable` without a rule name, `@ts-nocheck`; `@ts-ignore` and `@ts-expect-error` need a description | the `no-blanket-disable` rule, Oxlint `ban-ts-comment` |
| Python | `# noqa` and `# ruff: noqa` without a code, `# type: ignore` without a rule, `# pyright:` / `# basedpyright:` directives that change the mode or switch rules off (only `# pyright: ignore[rule]` is accepted) | Ruff `PGH003`/`PGH004`, basedpyright `reportIgnoreCommentWithoutRule`, the `no-pyright-directive` rule |
| Go | `//nolint` without a linter, `//nolint:all`, or without an explanation | `nolintlint` |

A file cannot opt out of the policy: not with a comment, not with a generated-file
header, not through its own `tsconfig` `exclude`. Only `.quality-gate/exclude`
can, and it is capped and listed in every report.

## Development

New to Nix, flakes or devenv? Read [docs/nix.md](docs/nix.md).

Development uses devenv. `devenv shell` opens a shell with Nushell, nu-lint and nixfmt, and the tests run as devenv tasks:

```bash
devenv shell
devenv tasks run <pkg>:test
devenv tasks run quality-gate:self-test # test the Quality Gate itself
devenv tasks run pkgs:test # package tests plus internal flakes tests
```

The self-test must not depend on the machine that runs it. Inside `devenv shell`
the fake tools run under `dash` (the `/bin/sh` of Ubuntu runners) and every test
file ignores your global Git configuration (`tests/support/isolation.nu`). The
shell carries the same nushell, ast-grep, uv and `complexipy` as the released
apps, from the `nixpkgs-quality-gate` revision of `flake.lock`; a test fails if
`devenv.lock` and `flake.lock` stop pinning the same revision.

Two environment variables help while developing:

- `QUALITY_GATE_UPDATE_SNAPSHOT=1` rewrites `tests/snapshots/quality-gate-policy.json`
  instead of comparing with it. Review the diff: it is the review of the policy.
- `QUALITY_GATE_TEST_REPORT=<file>` writes a JUnit report of the self-test and
  fails the run when fewer test cases ran than were discovered. The workflow
  sets it and uploads the report.

New files are visible to the flake apps only once Git knows them
(`git add -N <file>` is enough): a rule or a fixture that Git ignores is silently
missing from the apps the tests run. Before pushing, run the suite in a clean
Ubuntu container with no Git identity and an unprivileged user:

```bash
tests/ci/run-clean.sh   # tests the committed HEAD; needs Docker or CONTAINER_RUNTIME=podman
```

## Adding a package

1. Create `pkgs/<name>/` with a `default.nix` that defines `overlays.<name>`, a `README.md`, and a `tests/` folder. The flake picks it up with no other change.
2. In `devenv.nix`, add a `<name>:test` task and list it in the `after` of `pkgs:test`.

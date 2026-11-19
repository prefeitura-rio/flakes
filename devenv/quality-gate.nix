{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) escapeShellArgs;

  qualityGateRunner = import ./files/quality-gate/runner.nix { inherit pkgs; };
  qgScript = ''
    def main [...args: string] {
      ${qualityGateRunner} ...$args
    }
  '';

  nuTask = command: {
    package = pkgs.nushell;
    exec = "${qualityGateRunner} ${escapeShellArgs command}";
  };

  languageHook =
    {
      name,
      files,
      language,
    }:
    {
      enable = true;
      inherit name files;
      entry = "${pkgs.writeShellScript name ''
        set -eu
        git_bin="${pkgs.git}/bin/git"
        if [ "$#" -gt 0 ]; then
          export QUALITY_GATE_CHANGED_FILES="$(printf '%s\n' "$@")"
        else
          unset QUALITY_GATE_CHANGED_FILES || true
        fi
        export QUALITY_GATE_RESOLVED_SHA="$(${qualityGateRunner} resolve)"
        before_status="$("$git_bin" status --porcelain)"
        failed=0
        if ! ${qualityGateRunner} hook ${language}; then
          failed=1
        fi
        if [ "$failed" -eq 0 ]; then
          exit 0
        fi
        ${qualityGateRunner} fix ${language}
        after_status="$("$git_bin" status --porcelain)"
        if [ "$before_status" = "$after_status" ]; then
          echo "Quality Gate found no automatic fixes for this failure."
        else
          echo "Quality Gate applied automatic fixes. Review the changes, run git add manually, and commit again."
        fi
        if ${qualityGateRunner} hook ${language}; then
          echo "Checks pass after the fixes. Review the changes and run git add manually before committing again."
        else
          echo "Checks still fail after the fixes. Review the diagnostics, run git add manually, and commit again."
        fi
        exit 1
      ''}";
      language = "system";
      pass_filenames = true;
      require_serial = true;
      stages = [ "pre-commit" ];
    };

  aggregate = after: { inherit after; };
in
{
  profiles.quality-gate.module = {
    packages = [
      pkgs.nushell
    ];

    git-hooks.hooks = {
      quality-gate-python = languageHook {
        name = "quality-gate:python";
        language = "python";
        files = "\\.(py|pyi)$|(^|/)(pyproject\\.toml|setup\\.py)$";
      };

      quality-gate-go = languageHook {
        name = "quality-gate:go";
        language = "go";
        files = "\\.go$|(^|/)(go\\.mod|go\\.sum)$";
      };

      quality-gate-typescript = languageHook {
        name = "quality-gate:typescript";
        language = "typescript";
        files = "\\.(ts|tsx|mts|cts|vue)$|(^|/)(package\\.json|tsconfig\\.json|pnpm-lock\\.yaml|package-lock\\.json)$";
      };
    };

    scripts.quality-gate = {
      package = pkgs.nushell;
      binary = "nu";
      exec = ''
        def main [...args: string] {
          ${qualityGateRunner} ...$args
        }
      '';
      description = "Run the shared quality gate checks.";
    };

    scripts.qg = {
      package = pkgs.nushell;
      binary = "nu";
      exec = qgScript;
      description = "Short alias for the shared quality gate checks.";
    };

    tasks = {
      "format:python:ruff" = nuTask [
        "format"
        "python"
        "ruff"
      ];
      "lint:python:ruff" = nuTask [
        "lint"
        "python"
        "ruff"
      ];
      "lint:python:complexipy" = nuTask [
        "lint"
        "python"
        "complexipy"
      ];
      "typecheck:python:basedpyright" = nuTask [
        "typecheck"
        "python"
        "basedpyright"
      ];
      "lint:python:strlint" = nuTask [
        "lint"
        "python"
        "strlint"
      ];
      "format:python:all" = aggregate [
        "format:python:ruff"
      ];
      "lint:python:all" = aggregate [
        "lint:python:ruff"
        "lint:python:complexipy"
        "lint:python:strlint"
      ];
      "typecheck:python:all" = aggregate [
        "typecheck:python:basedpyright"
      ];

      "format:go:gofumpt" = nuTask [
        "format"
        "go"
        "gofumpt"
      ];
      "format:go:goimports" = nuTask [
        "format"
        "go"
        "goimports"
      ];
      "lint:go:golangci" = nuTask [
        "lint"
        "go"
        "golangci"
      ];
      "lint:go:strlint" = nuTask [
        "lint"
        "go"
        "strlint"
      ];
      "lint:go:vet" = nuTask [
        "lint"
        "go"
        "vet"
      ];
      "typecheck:go:build" = nuTask [
        "typecheck"
        "go"
        "build"
      ];
      "format:go:all" = aggregate [
        "format:go:gofumpt"
        "format:go:goimports"
      ];
      "lint:go:all" = aggregate [
        "lint:go:golangci"
        "lint:go:strlint"
        "lint:go:vet"
      ];
      "typecheck:go:all" = aggregate [
        "typecheck:go:build"
      ];

      "format:typescript:oxfmt" = nuTask [
        "format"
        "typescript"
        "oxfmt"
      ];
      "lint:typescript:oxlint" = nuTask [
        "lint"
        "typescript"
        "oxlint"
      ];
      "lint:typescript:strlint" = nuTask [
        "lint"
        "typescript"
        "strlint"
      ];
      "typecheck:typescript:tsc" = nuTask [
        "typecheck"
        "typescript"
        "tsc"
      ];
      "format:typescript:all" = aggregate [
        "format:typescript:oxfmt"
      ];
      "lint:typescript:all" = aggregate [
        "lint:typescript:oxlint"
        "lint:typescript:strlint"
      ];
      "typecheck:typescript:all" = aggregate [
        "typecheck:typescript:tsc"
      ];

      "quality-gate:detect" = nuTask [ "detect" ];
      "quality-gate:format" = nuTask [
        "category"
        "format"
      ];
      "quality-gate:lint" = nuTask [
        "category"
        "lint"
      ];
      "quality-gate:strlint" = nuTask [
        "category"
        "strlint"
      ];
      "quality-gate:typecheck" = nuTask [
        "category"
        "typecheck"
      ];
      "quality-gate:tests" = nuTask [ "test" ];
      "quality-gate:all" = nuTask [ "ci" ];
    };
  };
}

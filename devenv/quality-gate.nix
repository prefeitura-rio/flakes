{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) escapeShellArgs;

  qualityGateRunner = pkgs.writeShellScript "quality-gate-runner" ''
    set -eu
    git_bin="${pkgs.git}/bin/git"
    awk_bin="${pkgs.gawk}/bin/awk"
    sed_bin="${pkgs.gnused}/bin/sed"
    date_bin="${pkgs.coreutils}/bin/date"
    quality_gate_repo="https://github.com/prefeitura-rio/flakes.git"
    quality_gate_ref="quality-gate-latest"
    quality_gate_run_ref="''${QUALITY_GATE_RUN_REF:-}"
    git_dir="$("$git_bin" rev-parse --git-dir)"
    cache_file="$git_dir/quality-gate-latest"
    quality_gate_sha="''${QUALITY_GATE_RESOLVED_SHA:-}"

    if [ -n "$quality_gate_run_ref" ]; then
      quality_gate_sha="local"
    fi

    if [ -z "$quality_gate_sha" ]; then
      if quality_gate_sha="$("$git_bin" ls-remote "$quality_gate_repo" "refs/tags/$quality_gate_ref^{}" | "$awk_bin" 'NR == 1 { print $1 }')"; then
        if [ -z "$quality_gate_sha" ]; then
          quality_gate_sha="$("$git_bin" ls-remote "$quality_gate_repo" "refs/tags/$quality_gate_ref" | "$awk_bin" 'NR == 1 { print $1 }')"
        fi
        if [ -n "$quality_gate_sha" ]; then
          printf '%s\n%s\n' "$quality_gate_sha" "$("$date_bin" +%s)" > "$cache_file"
        fi
      fi

      if [ -z "$quality_gate_sha" ]; then
        if [ ! -s "$cache_file" ]; then
          echo "Quality Gate could not resolve quality-gate-latest and has no cached revision." >&2
          exit 1
        fi
        quality_gate_sha="$("$sed_bin" -n '1p' "$cache_file")"
        cached_at="$("$sed_bin" -n '2p' "$cache_file")"
        now="$("$date_bin" +%s)"
        age="$((now - cached_at))"
        if [ "$age" -gt 1209600 ]; then
          echo "Quality Gate cache is older than 14 days; connect to the network before committing." >&2
          exit 1
        fi
        echo "WARNING: Quality Gate is offline; using cached revision $quality_gate_sha." >&2
      fi
    fi

    if [ "''${1:-}" = resolve ]; then
      printf '%s\n' "$quality_gate_sha"
      exit 0
    fi

    quality_gate_app="quality-gate"
    language=""
    case "''${1:-}" in
      hook|fix)
        language="''${2:-}"
        ;;
      qg)
        language="''${3:-}"
        ;;
      format|lint|strlint|typecheck)
        language="''${2:-}"
        ;;
    esac
    case "$language" in
      py|python) quality_gate_app="quality-gate-python" ;;
      go) quality_gate_app="quality-gate-go" ;;
      ts|typescript) quality_gate_app="quality-gate-typescript" ;;
    esac

    export QUALITY_GATE_REVISION="$quality_gate_sha"
    if [ -z "$quality_gate_run_ref" ]; then
      quality_gate_run_ref="github:prefeitura-rio/flakes/$quality_gate_sha"
    fi
    exec ${pkgs.nix}/bin/nix run "$quality_gate_run_ref#$quality_gate_app" -- "$@"
  '';
  qgScript = ''
    def main [...args: string] {
      ${qualityGateRunner} qg ...$args
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
        if [ "$#" -gt 0 ]; then
          export QUALITY_GATE_CHANGED_FILES="$(printf '%s\n' "$@")"
        else
          unset QUALITY_GATE_CHANGED_FILES || true
        fi
        export QUALITY_GATE_RESOLVED_SHA="$(${qualityGateRunner} resolve)"
        failed=0
        if ! ${qualityGateRunner} hook ${language}; then
          failed=1
        fi
        if [ "$failed" -eq 0 ]; then
          exit 0
        fi
        echo "Quality Gate applied automatic fixes."
        ${qualityGateRunner} fix ${language}
        if ${qualityGateRunner} hook ${language}; then
          echo "Checks pass after the fixes. Review the changes, run git add manually, and commit again."
        else
          echo "Checks still fail after the fixes. Review the diagnostics, run git add manually, and commit again."
        fi
        exit 1
      ''}";
      language = "system";
      pass_filenames = true;
      stages = [ "pre-commit" ];
    };

  aggregate = after: { inherit after; };
in
{
  profiles.quality-gate.module = {
    packages = [
      pkgs.nix
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
      "lint:python:basedpyright" = nuTask [
        "lint"
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
        "lint:python:basedpyright"
        "lint:python:strlint"
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
      "lint:go:build" = nuTask [
        "lint"
        "go"
        "build"
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
        "lint:go:build"
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
      "lint:typescript:react-doctor" = nuTask [
        "lint"
        "typescript"
        "react-doctor"
      ];
      "lint:typescript:strlint" = nuTask [
        "lint"
        "typescript"
        "strlint"
      ];
      "lint:typescript:typecheck" = nuTask [
        "lint"
        "typescript"
        "typecheck"
      ];
      "format:typescript:all" = aggregate [
        "format:typescript:oxfmt"
      ];
      "lint:typescript:all" = aggregate [
        "lint:typescript:oxlint"
        "lint:typescript:react-doctor"
        "lint:typescript:strlint"
        "lint:typescript:typecheck"
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

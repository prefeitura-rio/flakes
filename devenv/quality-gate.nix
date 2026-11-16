{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) escapeShellArgs optionalString;

  qualityGateDir = ./files/quality-gate;
  script = "${qualityGateDir}/quality-gate.nu";
  qualityGateScript = builtins.readFile script;
  qgScript = ''
    def main [...args: string] {
      ${pkgs.nushell}/bin/nu ${script} qg ...$args
    }
  '';

  goimports = pkgs.runCommand "goimports" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.gosimports}/bin/gosimports $out/bin/goimports
  '';

  complexipy = pkgs.callPackage ../pkgs/complexipy/_package.nix { };
  react-doctor = pkgs.callPackage ../pkgs/react-doctor/_package.nix { };

  toolPackages = with pkgs; [
    ast-grep
    basedpyright
    complexipy
    go
    go-tools
    goimports
    gofumpt
    golangci-lint
    nodejs
    oxfmt
    oxlint
    pnpm
    react-doctor
    ruff
    typescript
    uv
  ];

  languageToolPackages = {
    python = with pkgs; [
      ast-grep
      basedpyright
      complexipy
      ruff
      uv
    ];
    go = with pkgs; [
      ast-grep
      go
      go-tools
      goimports
      gofumpt
      golangci-lint
    ];
    typescript = with pkgs; [
      ast-grep
      nodejs
      oxfmt
      oxlint
      pnpm
      react-doctor
      typescript
    ];
  };

  qualityGateEnv = {
    QUALITY_GATE_GO_RULES = "${qualityGateDir}/go/rules";
    QUALITY_GATE_GO_CONFIG = "${qualityGateDir}/go/.golangci.yml";
    QUALITY_GATE_PYTHON_RULES = "${qualityGateDir}/python/rules";
    QUALITY_GATE_PYRIGHT_CONFIG = "${qualityGateDir}/python/pyrightconfig.json";
    QUALITY_GATE_RUFF_CONFIG = "${qualityGateDir}/python/ruff.toml";
    QUALITY_GATE_TYPESCRIPT_CONFIG = "${qualityGateDir}/typescript/tsconfig.quality-gate.json";
    QUALITY_GATE_TYPESCRIPT_RULES = "${qualityGateDir}/typescript/rules";
    QUALITY_GATE_OXLINT_CONFIG = "${qualityGateDir}/typescript/.oxlintrc.json";
    QUALITY_GATE_OXFMT_CONFIG = "${qualityGateDir}/typescript/.oxfmtrc.json";
  };

  nuTask = command: {
    package = pkgs.nushell;
    exec =
      optionalString (toolPackages != [ ])
        "$env.PATH = ($env.PATH | prepend ${builtins.toJSON (lib.splitString ":" (lib.makeBinPath toolPackages))})\n"
      + "nu ${script} ${escapeShellArgs command}";
  };

  languageHook =
    {
      name,
      files,
      language,
      fixes ? [ ],
    }:
    let
      packages = languageToolPackages.${language};
      exports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") qualityGateEnv
      );
    in
    {
      enable = true;
      inherit name files;
      entry = "${pkgs.writeShellScript name ''
        set -eu
        ${exports}
        export PATH="${lib.makeBinPath packages}:$PATH"
        if [ "$#" -gt 0 ]; then
          export QUALITY_GATE_CHANGED_FILES="$(printf '%s\n' "$@")"
        else
          unset QUALITY_GATE_CHANGED_FILES || true
        fi
        failed=0
        if ! ${pkgs.nushell}/bin/nu ${script} hook ${language}; then
          failed=1
        fi
        if [ "$failed" -eq 0 ]; then
          exit 0
        fi
        if [ ${toString (builtins.length fixes)} -eq 0 ]; then
          exit 1
        fi
        echo "Quality Gate applied automatic fixes."
        ${lib.concatMapStringsSep "\n" (command: "${lib.escapeShellArgs command}") fixes}
        if ${pkgs.nushell}/bin/nu ${script} hook ${language}; then
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
    env = qualityGateEnv;

    packages = [ pkgs.nushell ];

    git-hooks.hooks = {
      quality-gate-python = languageHook {
        name = "quality-gate:python";
        language = "python";
        files = "\\.(py|pyi)$|(^|/)(pyproject\\.toml|setup\\.py)$";
        fixes = [
          [
            "ruff"
            "format"
            "--config"
            "${qualityGateDir}/python/ruff.toml"
            "."
          ]
          [
            "ruff"
            "check"
            "--config"
            "${qualityGateDir}/python/ruff.toml"
            "--fix"
            "."
          ]
        ];
      };

      quality-gate-go = languageHook {
        name = "quality-gate:go";
        language = "go";
        files = "\\.go$|(^|/)(go\\.mod|go\\.sum)$";
        fixes = [
          [
            "gofumpt"
            "-w"
            "."
          ]
          [
            "goimports"
            "-w"
            "."
          ]
        ];
      };

      quality-gate-typescript = languageHook {
        name = "quality-gate:typescript";
        language = "typescript";
        files = "\\.(ts|tsx|mts|cts|vue)$|(^|/)(package\\.json|tsconfig\\.json|pnpm-lock\\.yaml|package-lock\\.json)$";
        fixes = [
          [
            "oxfmt"
            "--config"
            "${qualityGateDir}/typescript/.oxfmtrc.json"
            "--write"
            "."
          ]
        ];
      };
    };

    scripts.quality-gate = {
      package = pkgs.nushell;
      binary = "nu";
      exec = qualityGateScript;
      packages = toolPackages;
      description = "Run the shared quality gate checks.";
    };

    scripts.qg = {
      package = pkgs.nushell;
      binary = "nu";
      exec = qgScript;
      packages = toolPackages;
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

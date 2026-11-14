{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) escapeShellArgs optionalString;

  qualityGateDir = ./files/quality-gate;
  script = "${qualityGateDir}/quality-gate.nu";
  qgScript = ''
    $env.QUALITY_GATE_SHORTCUT = true
    ${builtins.readFile script}
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
      checks,
    }:
    {
      enable = true;
      inherit name files;
      entry = "${pkgs.writeShellScript name ''
        set -eu
        ${lib.concatMapStringsSep "\n" (
          command: "${pkgs.nushell}/bin/nu ${script} ${escapeShellArgs command}"
        ) checks}
      ''}";
      language = "system";
      pass_filenames = false;
      stages = [ "pre-commit" ];
    };

  aggregate = after: { inherit after; };
in
{
  profiles.quality-gate.module = {
    env = {
      QUALITY_GATE_GO_RULES = "${qualityGateDir}/go/rules";
      QUALITY_GATE_GO_CONFIG = "${qualityGateDir}/go/.golangci.yml";
      QUALITY_GATE_PYTHON_RULES = "${qualityGateDir}/python/rules";
      QUALITY_GATE_PYRIGHT_CONFIG = "${qualityGateDir}/python/pyrightconfig.json";
      QUALITY_GATE_RUFF_CONFIG = "${qualityGateDir}/python/ruff.toml";
      QUALITY_GATE_TYPESCRIPT_RULES = "${qualityGateDir}/typescript/rules";
      QUALITY_GATE_OXLINT_CONFIG = "${qualityGateDir}/typescript/.oxlintrc.json";
    };

    packages = [ pkgs.nushell ];

    git-hooks.hooks = {
      quality-gate-python = languageHook {
        name = "quality-gate:python";
        files = "\\.(py|pyi)$|(^|/)(pyproject\\.toml|setup\\.py)$";
        checks = [
          [
            "format"
            "python"
            "ruff"
          ]
          [
            "lint"
            "python"
            "ruff"
          ]
          [
            "lint"
            "python"
            "complexipy"
          ]
          [
            "lint"
            "python"
            "basedpyright"
          ]
          [
            "lint"
            "python"
            "strlint"
          ]
        ];
      };

      quality-gate-go = languageHook {
        name = "quality-gate:go";
        files = "\\.go$|(^|/)(go\\.mod|go\\.sum)$";
        checks = [
          [
            "format"
            "go"
            "gofumpt"
          ]
          [
            "format"
            "go"
            "goimports"
          ]
          [
            "lint"
            "go"
            "golangci"
          ]
          [
            "lint"
            "go"
            "strlint"
          ]
          [
            "lint"
            "go"
            "vet"
          ]
          [
            "lint"
            "go"
            "build"
          ]
        ];
      };

      quality-gate-typescript = languageHook {
        name = "quality-gate:typescript";
        files = "\\.(ts|tsx|mts|cts|vue)$|(^|/)(package\\.json|tsconfig\\.json|pnpm-lock\\.yaml|package-lock\\.json)$";
        checks = [
          [
            "format"
            "typescript"
            "oxfmt"
          ]
          [
            "lint"
            "typescript"
            "oxlint"
          ]
          [
            "lint"
            "typescript"
            "react-doctor"
          ]
          [
            "lint"
            "typescript"
            "strlint"
          ]
          [
            "lint"
            "typescript"
            "typecheck"
          ]
        ];
      };
    };

    scripts.quality-gate = {
      package = pkgs.nushell;
      binary = "nu";
      exec = builtins.readFile script;
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

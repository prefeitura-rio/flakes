{
  description = "Packages for Prefeitura do Rio infrastructure";

  nixConfig = {
    extra-substituters = [
      "https://prefeitura-rio.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "prefeitura-rio.cachix.org-1:Y+SotJw1tzXRsM/a6Af2mwX8HTZjnefjsuFT0DNevX8="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-quality-gate.url = "github:nixos/nixpkgs/nixos-unstable";
    import-tree.url = "github:denful/import-tree";
  };

  outputs =
    inputs:
    let
      nixpkgs = inputs.nixpkgs;
      import-tree = inputs.import-tree;
      nixpkgsQualityGate = inputs."nixpkgs-quality-gate";
      inherit (nixpkgs) lib;

      overlays = import ./overlays.nix { inherit lib import-tree; };

      packageNames = lib.attrNames (overlays.default { } { });

      forEachSystem = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlays.default ];
        };

      qualityGatePkgsFor =
        system:
        import nixpkgsQualityGate {
          inherit system;
        };

      qualityGateFor =
        system: language:
        let
          pkgs = qualityGatePkgsFor system;
          complexipy = pkgs.callPackage ./pkgs/complexipy/_package.nix { };
          commonPackages = with pkgs; [
            ast-grep
            git
            nushell
          ];
          pythonRuntimes = pkgs.runCommand "quality-gate-python-runtimes" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.python311}/bin/python3.11 $out/bin/python3.11
            ln -s ${pkgs.python312}/bin/python3.12 $out/bin/python3.12
            ln -s ${pkgs.python313}/bin/python3.13 $out/bin/python3.13
            ln -s ${pkgs.python314}/bin/python3.14 $out/bin/python3.14
          '';
          languagePackages = {
            python = with pkgs; [
              basedpyright
              complexipy
              pythonRuntimes
              ruff
              uv
            ];
            go = with pkgs; [
              go
              gotools
              gofumpt
              golangci-lint
            ];
            typescript = with pkgs; [
              nodejs_24
              oxfmt
              oxlint
              pnpm
              typescript
            ];
          };
          qualityGatePackages =
            commonPackages
            ++ (
              if language == null then
                lib.concatLists (lib.attrValues languagePackages)
              else
                languagePackages.${language}
            );
          qualityGate = pkgs.writeShellApplication {
            name = if language == null then "quality-gate" else "quality-gate-${language}";
            runtimeInputs = qualityGatePackages;
            text = ''
              export QUALITY_GATE_NODE_22_BIN=${pkgs.nodejs_22}/bin
              export QUALITY_GATE_NODE_24_BIN=${pkgs.nodejs_24}/bin
              export QUALITY_GATE_NODE_26_BIN=${pkgs.nodejs_26}/bin
              export QUALITY_GATE_GO_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/go/rules}"}
              export QUALITY_GATE_GO_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/go/.golangci.yml}"}
              export QUALITY_GATE_PYTHON_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/python/rules}"}
              export QUALITY_GATE_PYRIGHT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/python/pyrightconfig.json}"}
              export QUALITY_GATE_RUFF_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/python/ruff.toml}"}
              export QUALITY_GATE_TYPESCRIPT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/tsconfig.quality-gate.json}"}
              export QUALITY_GATE_TYPESCRIPT_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/rules}"}
              export QUALITY_GATE_OXLINT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/.oxlintrc.json}"}
              export QUALITY_GATE_OXFMT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/.oxfmtrc.json}"}
              export QUALITY_GATE_REPORT_POLICY=${lib.escapeShellArg "${./devenv/files/quality-gate/policy/report-only.yaml}"}
              export UV_PYTHON_PREFERENCE=only-system
              export UV_PYTHON_DOWNLOADS=never
              export GOTOOLCHAIN=local
              exec ${pkgs.nushell}/bin/nu ${./devenv/files/quality-gate/quality-gate.nu} "$@"
            '';
          };
        in
        qualityGate;
      qualityGateDetect =
        system:
        let
          pkgs = qualityGatePkgsFor system;
        in
        pkgs.writeShellApplication {
          name = "quality-gate-detect";
          runtimeInputs = with pkgs; [
            git
            nushell
          ];
          text = ''
            exec ${pkgs.nushell}/bin/nu ${./devenv/files/quality-gate/quality-gate.nu} "$@"
          '';
        };
    in
    {
      inherit overlays;

      packages = forEachSystem (
        system:
        (lib.getAttrs packageNames (pkgsFor system))
        // {
          quality-gate = qualityGateFor system null;
          quality-gate-detect = qualityGateDetect system;
          quality-gate-python = qualityGateFor system "python";
          quality-gate-go = qualityGateFor system "go";
          quality-gate-typescript = qualityGateFor system "typescript";
        }
      );

      apps = forEachSystem (system: {
        quality-gate = {
          type = "app";
          program = "${qualityGateFor system null}/bin/quality-gate";
        };
        quality-gate-detect = {
          type = "app";
          program = "${qualityGateDetect system}/bin/quality-gate-detect";
        };
        quality-gate-python = {
          type = "app";
          program = "${qualityGateFor system "python"}/bin/quality-gate-python";
        };
        quality-gate-go = {
          type = "app";
          program = "${qualityGateFor system "go"}/bin/quality-gate-go";
        };
        quality-gate-typescript = {
          type = "app";
          program = "${qualityGateFor system "typescript"}/bin/quality-gate-typescript";
        };
      });
    };
}

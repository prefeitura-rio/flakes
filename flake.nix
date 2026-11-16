{
  description = "Packages for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    import-tree.url = "github:denful/import-tree";
  };

  outputs =
    {
      self,
      nixpkgs,
      import-tree,
      ...
    }:
    let
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

      qualityGateFor =
        system: language:
        let
          pkgs = pkgsFor system;
          goimports = pkgs.runCommand "goimports" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.gosimports}/bin/gosimports $out/bin/goimports
          '';
          complexipy = pkgs.callPackage ./pkgs/complexipy/_package.nix { };
          react-doctor = pkgs.callPackage ./pkgs/react-doctor/_package.nix { };
          qualityGateRevision = if self ? rev then self.rev else "dirty";
          commonPackages = with pkgs; [
            ast-grep
            nushell
          ];
          languagePackages = {
            python = with pkgs; [
              basedpyright
              complexipy
              ruff
              uv
            ];
            go = with pkgs; [
              go
              go-tools
              goimports
              gofumpt
              golangci-lint
            ];
            typescript = with pkgs; [
              nodejs
              oxfmt
              oxlint
              pnpm
              react-doctor
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
              export QUALITY_GATE_REVISION=${lib.escapeShellArg qualityGateRevision}
              export QUALITY_GATE_GO_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/go/rules}"}
              export QUALITY_GATE_GO_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/go/.golangci.yml}"}
              export QUALITY_GATE_PYTHON_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/python/rules}"}
              export QUALITY_GATE_PYRIGHT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/python/pyrightconfig.json}"}
              export QUALITY_GATE_RUFF_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/python/ruff.toml}"}
              export QUALITY_GATE_TYPESCRIPT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/tsconfig.quality-gate.json}"}
              export QUALITY_GATE_TYPESCRIPT_RULES=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/rules}"}
              export QUALITY_GATE_OXLINT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/.oxlintrc.json}"}
              export QUALITY_GATE_OXFMT_CONFIG=${lib.escapeShellArg "${./devenv/files/quality-gate/typescript/.oxfmtrc.json}"}
              exec ${pkgs.nushell}/bin/nu ${./devenv/files/quality-gate/quality-gate.nu} "$@"
            '';
          };
        in
        qualityGate;
    in
    {
      inherit overlays;

      packages = forEachSystem (
        system:
        (lib.getAttrs packageNames (pkgsFor system))
        // {
          quality-gate = qualityGateFor system null;
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

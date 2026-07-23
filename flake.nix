{
  description = "Shared files for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        {
          packages = import ./packages.nix { inherit pkgs; };

          treefmt.config = {
            projectRootFile = "flake.nix";
            programs = {
              ruff-format.enable = true;
              ruff-check.enable = true;
              nixfmt.enable = true;
              shfmt.enable = true;
              shellcheck.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              basedpyright
              (python3.withPackages (ps: [
                ps.loguru
                ps.typer
              ]))
            ];
          };
        };
    };
}

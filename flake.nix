{
  description = "Shared files for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs:
    let
      perSystem = inputs.flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
          treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";
            programs = {
              ruff-format.enable = true;
              ruff-check.enable = true;
              nixfmt.enable = true;
              shfmt.enable = true;
              shellcheck.enable = true;
            };
          };
        in
        {
          packages = import ./packages.nix { inherit pkgs; };
          formatter = treefmtEval.config.build.wrapper;
          checks.formatting = treefmtEval.config.build.check;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              basedpyright
              treefmtEval.config.build.wrapper
              (python3.withPackages (ps: [
                ps.loguru
                ps.typer
              ]))
            ];
          };
        }
      );
    in
    perSystem;
}

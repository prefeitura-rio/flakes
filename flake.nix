{
  description = "Shared files for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    nutest = {
      url = "github:vyadh/nutest/v1.2.0";
      flake = false;
    };
  };

  outputs =
    inputs:
    {
      overlays.default =
        final: _prev:
        let
          built = import ./packages.nix { pkgs = final; };
        in
        {
          prefrio = final.buildEnv {
            name = "prefrio";
            paths = [
              built.prefrio
              built.deps
            ];
          };
        };
    }
    // inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import inputs.nixpkgs { inherit system; };
        treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        };
      in
      {
        packages = import ./packages.nix { inherit pkgs; };
        formatter = treefmtEval.config.build.wrapper;

        devShells.default = pkgs.mkShell {
          NU_LIB_DIRS = "${inputs.nutest}";

          packages = with pkgs; [
            treefmtEval.config.build.wrapper
            nu-lint
            nushell
          ];
        };
      }
    );
}

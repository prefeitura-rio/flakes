{
  description = "Shared files for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, utils, ... }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        packages = import ./packages.nix { inherit pkgs; };
      in
      {
        inherit packages;
      }
    );
}

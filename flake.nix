{
  description = "Packages for Prefeitura do Rio infrastructure";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forEachSystem (system: {
        prefrio = import ./pkgs/prefrio { pkgs = nixpkgs.legacyPackages.${system}; };
      });

      overlays.default = final: _prev: {
        prefrio = import ./pkgs/prefrio { pkgs = final; };
      };
    };
}

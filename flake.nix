{
  description = "Packages for Prefeitura do Rio infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    import-tree.url = "github:denful/import-tree";
  };

  outputs =
    { nixpkgs, import-tree, ... }:
    let
      inherit (nixpkgs) lib;

      overlays = import ./overlays.nix { inherit lib import-tree; };

      packageNames = lib.attrNames (overlays.default { } { });

      forEachSystem = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlays.default ];
        };
    in
    {
      inherit overlays;

      packages = forEachSystem (system: lib.getAttrs packageNames (pkgsFor system));
    };
}

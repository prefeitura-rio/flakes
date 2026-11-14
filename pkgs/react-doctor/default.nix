{ ... }:
{
  overlays.react-doctor = final: _prev: {
    react-doctor = final.callPackage ./_package.nix { };
  };
}

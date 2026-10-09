{ lib, import-tree }:
let
  overlaysOption = {
    options.overlays = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = ''
        Overlays defined by the files of pkgs/, by name. Every .nix file under pkgs/
        is a module that sets overlays.<name>; a file or folder whose name starts
        with _ is skipped. The type is raw because overlays are functions and are
        not merged, so two files cannot define the same name.
      '';
      example = lib.literalExpression "{ hello-again = final: prev: { hello-again = final.hello; }; }";
    };
  };

  packageModules = import-tree ./pkgs;

  packageOverlays =
    (lib.evalModules {
      modules = [
        overlaysOption
        packageModules
      ];
    }).config.overlays;
in
packageOverlays
// {
  default = lib.composeManyExtensions (lib.attrValues packageOverlays);
}

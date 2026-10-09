{ pkgs }:
let
  scripts = pkgs.runCommand "prefrio-scripts" { } ''
    mkdir -p $out
    cp ${./prefrio.nu} $out/prefrio.nu
    cp ${./lib.nu} $out/lib.nu
    cp ${./tf.nu} $out/tf.nu
  '';

  gcloud = pkgs.google-cloud-sdk.withExtraComponents (
    with pkgs.google-cloud-sdk.components; [ gke-gcloud-auth-plugin ]
  );

  tools = [
    gcloud
    pkgs.kubectl
    pkgs.opentofu
    pkgs.sops
    pkgs.terragrunt
  ];

  skim = "${pkgs.nushellPlugins.skim}/bin/nu_plugin_skim";

  cli = pkgs.writeShellApplication {
    name = "prefrio";
    text = ''
      exec ${pkgs.nushell}/bin/nu --plugins '[${skim}]' ${scripts}/prefrio.nu "$@"
    '';
    runtimeInputs = tools ++ [
      pkgs.git
      pkgs.nushell
    ];
  };
in
pkgs.buildEnv {
  name = "prefrio";
  paths = [ cli ] ++ tools;
  meta.mainProgram = "prefrio";
}

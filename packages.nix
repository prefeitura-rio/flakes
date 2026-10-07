{ pkgs }:
let
  scripts = pkgs.runCommand "prefrio-scripts" { } ''
    mkdir -p $out
    cp ${./scripts/prefrio.nu} $out/prefrio.nu
    cp ${./scripts/lib.nu} $out/lib.nu
    cp ${./scripts/tf.nu} $out/tf.nu
    cp ${./scripts/project.nu} $out/project.nu
  '';
  gcloud = (
    pkgs.google-cloud-sdk.withExtraComponents (
      with pkgs.google-cloud-sdk.components; [ gke-gcloud-auth-plugin ]
    )
  );
  skim = "${pkgs.nushellPlugins.skim}/bin/nu_plugin_skim";
in
{
  deps = pkgs.buildEnv {
    name = "deps";
    paths = with pkgs; [
      gcloud
      kubectl
      opentofu
      sops
      terragrunt
    ];
  };

  prefrio = pkgs.writeShellApplication {
    name = "prefrio";
    text = ''
      workdir="$PWD"
      cd ${scripts}
      PREFRIO_WORKDIR="$workdir" exec ${pkgs.nushell}/bin/nu --plugins '[${skim}]' ${scripts}/prefrio.nu "$@"
    '';

    runtimeInputs = with pkgs; [
      gcloud
      git
      kubectl
      nushell
      opentofu
      sops
      terragrunt
    ];
  };
}

{ pkgs }:
let
  scripts = pkgs.runCommand "prefrio-scripts" { } ''
    mkdir -p $out
    cp ${./scripts/prefrio.nu} $out/prefrio.nu
    cp ${./scripts/k3s.nu} $out/k3s.nu
    cp ${./scripts/lib.nu} $out/lib.nu
    cp ${./scripts/tf.nu} $out/tf.nu
    cp ${./scripts/project.nu} $out/project.nu
  '';
  gcloud = (
    pkgs.google-cloud-sdk.withExtraComponents (with pkgs.google-cloud-sdk.components; [ gke-gcloud-auth-plugin ])
  );
in
{
  deps = pkgs.buildEnv {
    name = "deps";
    paths = with pkgs; [
      ansible
      git
      jq
      kubectl
      kubernetes-helm
      nu-lint
      nushell
      opentofu
      prek
      sops
      tailscale
      tflint
      gcloud
    ];
  };

  prefrio = pkgs.writeShellApplication {
    name = "prefrio";
    text = ''
      workdir="$PWD"
      cd ${scripts}
      PREFRIO_WORKDIR="$workdir" exec ${pkgs.nushell}/bin/nu ${scripts}/prefrio.nu "$@"
    '';

    runtimeInputs = with pkgs; [
      gcloud
      git
      jq
      kubectl
      kubernetes-helm
      nushell
      opentofu
      sops
      tailscale
    ];
  };
}

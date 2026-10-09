{
  overlays.prefrio = final: _prev: {
    prefrio =
      with final;
      let
        scripts = runCommand "prefrio-scripts" { } ''
          mkdir -p $out
          cp ${./cli.nu} $out/prefrio
          cp ${./lib.nu} $out/lib.nu
          cp ${./tf.nu} $out/tf.nu
        '';

        gcloud = google-cloud-sdk.withExtraComponents (
          with google-cloud-sdk.components; [ gke-gcloud-auth-plugin ]
        );

        tools = [
          gcloud
          kubectl
          opentofu
          sops
          terragrunt
        ];

        nu = nushell.withPlugins [ nushellPlugins.skim ];

        cli = writeShellApplication {
          name = "prefrio";
          text = ''
            exec ${nu}/bin/nu ${scripts}/prefrio "$@"
          '';
          runtimeInputs = tools ++ [
            git
            nu
          ];
        };
      in
      buildEnv {
        name = "prefrio";
        paths = [ cli ] ++ tools;
        meta = {
          description = "CLI for Terragrunt, SOPS and Kubernetes";
          homepage = "https://github.com/prefeitura-rio/flakes/tree/master/pkgs/prefrio";
          license = lib.licenses.asl20;
          mainProgram = "prefrio";
        };
      };
  };
}

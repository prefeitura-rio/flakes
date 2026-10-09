{
  overlays.prefrio = final: _prev: {
    prefrio =
      let
        scripts = final.runCommand "prefrio-scripts" { } ''
          mkdir -p $out
          cp ${./cli.nu} $out/prefrio
          cp ${./lib.nu} $out/lib.nu
          cp ${./tf.nu} $out/tf.nu
        '';

        gcloud = final.google-cloud-sdk.withExtraComponents (
          with final.google-cloud-sdk.components; [ gke-gcloud-auth-plugin ]
        );

        tools = [
          gcloud
          final.kubectl
          final.opentofu
          final.sops
          final.terragrunt
        ];

        skim = "${final.nushellPlugins.skim}/bin/nu_plugin_skim";

        cli = final.writeShellApplication {
          name = "prefrio";
          text = ''
            exec ${final.nushell}/bin/nu --plugins '[${skim}]' ${scripts}/prefrio "$@"
          '';
          runtimeInputs = tools ++ [
            final.git
            final.nushell
          ];
        };
      in
      final.buildEnv {
        name = "prefrio";
        paths = [ cli ] ++ tools;
        meta.mainProgram = "prefrio";
      };
  };
}

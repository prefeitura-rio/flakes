{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{
  overlays = [ inputs.prefrio.overlays.default ];

  env.TF_LIB = toString ./files/infra;
  env.TFLINT_CONFIG_FILE = "${./files/infra}/tflint.hcl";

  packages = [ pkgs.prefrio ];

  git-hooks.hooks = {
    ripsecrets.enable = true;
    terraform-format.enable = true;
    tflint = {
      enable = true;
      entry = lib.mkForce "${pkgs.coreutils}/bin/env TFLINT_CONFIG_FILE=${./files/infra}/tflint.hcl ${config.git-hooks.hooks.tflint.package}/bin/tflint";
    };
    tfsec = {
      enable = true;
      name = "tfsec";
      entry = "${pkgs.prefrio}/bin/prefrio tf scan";
      files = "(\\.tf|\\.tfsec/config\\.yml)$";
      language = "system";
      pass_filenames = true;
      require_serial = true;
    };
    terragrunt-format = {
      enable = true;
      name = "terragrunt hcl fmt";
      entry = "${pkgs.terragrunt}/bin/terragrunt hcl fmt --check";
      files = "\\.hcl$";
      language = "system";
      pass_filenames = false;
    };
  };
}

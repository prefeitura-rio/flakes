{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{
  overlays = [ inputs.prefrio.overlays.default ];

  env.TF_LIB = toString ./infra;
  env.TFLINT_CONFIG_FILE = "${./infra}/tflint.hcl";

  packages = [ pkgs.prefrio ];

  git-hooks.hooks = {
    ripsecrets.enable = true;
    terraform-format.enable = true;
    tflint = {
      enable = true;
      entry = lib.mkForce "${pkgs.coreutils}/bin/env TFLINT_CONFIG_FILE=${./infra}/tflint.hcl ${config.git-hooks.hooks.tflint.package}/bin/tflint";
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

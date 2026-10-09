{ pkgs, inputs, ... }:
{
  name = "flakes";

  env.NU_LIB_DIRS = "${inputs.nutest}";

  packages = with pkgs; [
    nushell
    nu-lint
    nixfmt
  ];

  scripts.run-tests.exec = ''
    nu -c 'use nutest; nutest run-tests --path prefrio/tests --fail'
  '';

  git-hooks.hooks.nixfmt.enable = true;
}

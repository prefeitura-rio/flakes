{
  pkgs,
  config,
  inputs,
  ...
}:
{
  name = "flakes";

  env.NU_LIB_DIRS = "${inputs.nutest}";

  packages = with pkgs; [
    nushell
    nu-lint
    nixfmt
  ];

  tasks = {
    "prefrio:test" = {
      cwd = "${config.devenv.root}/pkgs/prefrio";
      package = pkgs.nushell;
      exec = ''
        use nutest
        nutest run-tests --path tests
      '';
    };
    "pkgs:test".after = [
      "prefrio:test"
    ];
  };

  git-hooks.hooks.nixfmt.enable = true;
}

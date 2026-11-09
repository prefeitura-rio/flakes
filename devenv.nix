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
    ast-grep
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
    "ast-grep:test" = {
      exec = "ast-grep test --config devenv/files/infra/ast-grep/sgconfig.yml";
    };
    "pkgs:test".after = [
      "ast-grep:test"
      "prefrio:test"
    ];
  };

  git-hooks.hooks.nixfmt.enable = true;
}

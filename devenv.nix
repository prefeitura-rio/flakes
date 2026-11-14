{
  pkgs,
  config,
  inputs,
  ...
}:
let
  complexipy = pkgs.callPackage ./pkgs/complexipy/_package.nix { };
  react-doctor = pkgs.callPackage ./pkgs/react-doctor/_package.nix { };
in
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
    "complexipy:test" = {
      cwd = config.devenv.root;
      package = pkgs.nushell;
      exec = ''
        $env.PATH = ($env.PATH | prepend ${complexipy}/bin)
        nu pkgs/complexipy/tests/complexipy_test.nu
      '';
    };
    "react-doctor:test" = {
      cwd = config.devenv.root;
      package = pkgs.nushell;
      exec = ''
        $env.PATH = ($env.PATH | prepend ${react-doctor}/bin)
        nu pkgs/react-doctor/tests/react_doctor_test.nu
      '';
    };
    "pkgs:test".after = [
      "ast-grep:test"
      "prefrio:test"
      "complexipy:test"
      "react-doctor:test"
    ];
  };

  git-hooks.hooks.nixfmt.enable = true;
}

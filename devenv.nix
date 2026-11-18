{
  pkgs,
  config,
  inputs,
  ...
}:
let
  complexipy = pkgs.callPackage ./pkgs/complexipy/_package.nix { };
in
{
  name = "flakes";

  env.NU_LIB_DIRS = "${inputs.nutest}";
  # Fake tools in the self-test run under dash, the /bin/sh of Debian/Ubuntu
  # runners, so shell-specific behaviour shows up on every machine.
  env.QUALITY_GATE_TEST_SH = "${pkgs.dash}/bin/dash";

  packages = with pkgs; [
    nushell
    nu-lint
    ast-grep
    nixfmt
    uv
  ];

  tasks = {
    "quality-gate:self-test" = {
      cwd = config.devenv.root;
      package = pkgs.nushell;
      exec = ''
        use nutest
        let tests = (nutest list-tests --path tests)
        if ($tests | is-empty) {
          error make { msg: "Quality Gate self-test discovered zero tests" }
        }
        nutest run-tests --path tests --fail
      '';
    };
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
    "pkgs:test".after = [
      "ast-grep:test"
      "prefrio:test"
      "complexipy:test"
      "quality-gate:self-test"
    ];
  };

  git-hooks.hooks.nixfmt.enable = true;
}

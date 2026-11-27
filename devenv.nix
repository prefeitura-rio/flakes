{
  pkgs,
  config,
  inputs,
  ...
}:
let
  # The self-test drives the tools the apps ship. They come from the same
  # nixpkgs revision as the flake apps, so a test never runs against another
  # version than the one released; tests/quality-gate_test.nu keeps the two
  # locks equal.
  shipped = import inputs.nixpkgs-quality-gate { system = pkgs.stdenv.system; };
  complexipy = shipped.callPackage ./pkgs/complexipy/_package.nix { };
in
{
  name = "flakes";

  env.NU_LIB_DIRS = "${inputs.nutest}";
  # Fake tools in the self-test run under dash, the /bin/sh of Debian/Ubuntu
  # runners, so shell-specific behaviour shows up on every machine.
  env.QUALITY_GATE_TEST_SH = "${pkgs.dash}/bin/dash";

  packages = [
    shipped.nushell
    shipped.ast-grep
    shipped.jq
    shipped.uv
    pkgs.nu-lint
    pkgs.nixfmt
    pkgs.python3
  ];

  tasks = {
    "quality-gate:self-test" = {
      cwd = config.devenv.root;
      package = shipped.nushell;
      exec = ''
        use nutest
        let tests = (nutest list-tests --path tests)
        if ($tests | is-empty) {
          error make { msg: "Quality Gate self-test discovered zero tests" }
        }
        let report = $env.QUALITY_GATE_TEST_REPORT? | default ""
        if ($report | is-empty) {
          nutest run-tests --path tests --fail
        } else {
          # A test that never reports would still count as passing, so the
          # number of executed test cases must match the number discovered.
          try {
            nutest run-tests --path tests --fail --display terminal --report { type: "junit", path: $report }
          } catch {|error|
            if ($report | path exists) { print $"JUnit report written to ($report)" }
            error make $error
          }
          let executed = (open --raw $report | split row "<testcase" | length) - 1
          if $executed != ($tests | length) {
            error make { msg: $"Quality Gate self-test executed ($executed) of ($tests | length) discovered tests" }
          }
          print $"Quality Gate self-test executed ($executed) tests"
        }
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
      package = shipped.nushell;
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

{ pkgs }:
{
  base-deps = pkgs.buildEnv {
    name = "base-deps";
    paths = with pkgs; [
      jq
      just
      kubectl
      kubernetes-helm
      prek
      sops
      opentofu
      tflint
    ];
  };

  prefrio = pkgs.writeShellApplication {
    name = "prefrio";
    text = builtins.readFile ./scripts/prefrio.sh;
    runtimeInputs = with pkgs; [
      google-cloud-sdk
      opentofu
      sops
      jq
      git
    ];
  };

  k3s = pkgs.python3.pkgs.buildPythonApplication {
    pname = "k3s";
    version = "1.0.0";
    src = ./k3s;
    pyproject = true;
    build-system = with pkgs.python3.pkgs; [ hatchling ];
    propagatedBuildInputs = with pkgs.python3.pkgs; [
      loguru
      typer
    ];
  };
}

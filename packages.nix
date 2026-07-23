{ pkgs }:
{
  prefrio = pkgs.writeShellApplication {
    name          = "prefrio";
    runtimeInputs = with pkgs; [ google-cloud-sdk opentofu sops jq git ];
    text          = builtins.readFile ./scripts/prefrio.sh;
  };

  k3s = pkgs.python3.pkgs.buildPythonApplication {
    pname   = "k3s";
    version = "0.1.0";
    src     = ./k3s;
    pyproject = true;
    build-system          = with pkgs.python3.pkgs; [ hatchling ];
    propagatedBuildInputs = with pkgs.python3.pkgs; [ loguru typer ];
  };
}

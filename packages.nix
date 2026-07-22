{ pkgs }:
{
  prefrio = pkgs.writeShellApplication {
    name          = "prefrio";
    runtimeInputs = with pkgs; [ google-cloud-sdk opentofu sops jq procps ];
    text          = builtins.readFile ./scripts/prefrio.sh;
  };
}

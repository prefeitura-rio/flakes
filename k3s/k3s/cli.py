"""K3s infrastructure management CLI."""

from pathlib import Path
from typing import Annotated

from typer import Argument, Option, Typer

from .incus import ensure_incus
from .kubeconfig import ensure_kubeconfig
from .tailscale import validate_tailscale
from .terraform import terraform_run

app = Typer(no_args_is_help=True)


@app.command()
def apply() -> None:
    """Apply Terraform changes."""
    terraform_run("apply", [], Path("terraform"))


@app.command()
def destroy() -> None:
    """Destroy Terraform resources."""
    terraform_run("destroy", [], Path("terraform"))


@app.command(name="import")
def import_resource(
    address: Annotated[str, Argument(help="Resource address")],
    resource_id: Annotated[str, Argument(help="Resource ID")],
) -> None:
    """Import a resource into Terraform state."""
    terraform_run("import", [address, resource_id], Path("terraform"))


@app.command(name="ensure-incus")
def incus(
    force: Annotated[bool, Option("--force", help="Force token rotation")] = False,
) -> None:
    """Configure Incus remote."""
    ensure_incus(force=force)


@app.command(name="ensure-kubeconfig")
def kubeconfig() -> None:
    """Fetch and encrypt kubeconfig from the cluster."""
    ensure_kubeconfig()


@app.command(name="validate-tailscale")
def tailscale() -> None:
    """Validate Tailscale connection."""
    validate_tailscale()


def main() -> None:
    """Run the k3s CLI."""
    app()

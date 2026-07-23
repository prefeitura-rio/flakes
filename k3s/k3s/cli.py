"""K3s infrastructure management CLI."""

from pathlib import Path
from typing import Annotated

import typer

from . import ensure_incus as ensure_incus_mod
from . import ensure_kubeconfig as ensure_kubeconfig_mod
from . import terraform as terraform_mod
from . import validate_tailscale as validate_tailscale_mod

app = typer.Typer(no_args_is_help=True)


@app.command()
def apply() -> None:
    """Apply Terraform changes."""
    terraform_mod.terraform_run("apply", [], Path("terraform"))


@app.command()
def destroy() -> None:
    """Destroy Terraform resources."""
    terraform_mod.terraform_run("destroy", [], Path("terraform"))


@app.command(name="import")
def import_resource(
    address: Annotated[str, typer.Argument(help="Resource address")],
    resource_id: Annotated[str, typer.Argument(help="Resource ID")],
) -> None:
    """Import a resource into Terraform state."""
    terraform_mod.terraform_run("import", [address, resource_id], Path("terraform"))


@app.command()
def ensure_incus(
    force: Annotated[
        bool, typer.Option("--force", help="Force token rotation")
    ] = False,
) -> None:
    """Configure Incus remote."""
    ensure_incus_mod.ensure_incus(force=force)


@app.command()
def ensure_kubeconfig() -> None:
    """Fetch and encrypt kubeconfig from the cluster."""
    ensure_kubeconfig_mod.main()


@app.command()
def validate_tailscale() -> None:
    """Validate Tailscale connection."""
    validate_tailscale_mod.validate_tailscale()


def main() -> None:
    """Run the k3s CLI."""
    app()

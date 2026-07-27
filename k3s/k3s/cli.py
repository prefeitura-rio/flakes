from pathlib import Path
from typing import Annotated

from typer import Argument, Typer

from .kubeconfig import ensure_kubeconfig
from .tailscale import validate_tailscale
from .terraform import terraform_run

app = Typer(no_args_is_help=True)


@app.command()
def apply() -> None:
    terraform_run("apply", [], Path("terraform"))


@app.command()
def destroy() -> None:
    terraform_run("destroy", [], Path("terraform"))


@app.command(name="import")
def import_resource(
    address: Annotated[str, Argument(help="Resource address")],
    resource_id: Annotated[str, Argument(help="Resource ID")],
) -> None:
    terraform_run("import", [address, resource_id], Path("terraform"))


@app.command(name="ensure-kubeconfig")
def kubeconfig() -> None:
    ensure_kubeconfig()


@app.command(name="validate-tailscale")
def tailscale() -> None:
    validate_tailscale()


def main() -> None:
    app()

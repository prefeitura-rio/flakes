"""Run Terraform commands with kubeconfig and secrets injected at runtime."""

from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Literal

from loguru import logger

from .utils import die, run, sops_dir

Command = Literal["apply", "destroy", "import"]


def decrypt_tfvars(tfvars_sops: Path) -> str:
    """Decrypt a SOPS-encrypted tfvars file and return its JSON content."""
    result = run(
        ["sops", "decrypt", "--output-type", "json", str(tfvars_sops)],
        capture=True,
    )
    if not result.stdout.strip():
        die(f"Failed to decrypt {tfvars_sops}")
    return result.stdout


def terraform_run(command: Command, extra: list[str], tfdir: Path) -> None:
    """Run a Terraform command with kubeconfig and secrets injected at runtime."""
    kubeconfig_sops = sops_dir() / "kubeconfig.sops"
    tfvars_sops = tfdir / "terraform.tfvars.sops.json"
    tfvars_json = decrypt_tfvars(tfvars_sops)

    tfvars_path: Path | None = None

    try:
        with NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            tfvars_path = Path(f.name)
            _ = f.write(tfvars_json)

        sops_cmd = (
            f"KUBECONFIG={{}} tofu -chdir={tfdir} {command}"
            f" -var-file={tfvars_path}"
            f" -var=kubeconfig_path={{}}"
            f" {' '.join(extra)}"
        ).strip()

        match command:
            case "apply":
                logger.info("Applying Terraform changes...")
            case "destroy":
                logger.warning("Running Terraform destroy...")
            case "import":
                logger.info(f"Importing resource: {' '.join(extra)}")

        _ = run(["sops", "exec-file", "--no-fifo", str(kubeconfig_sops), sops_cmd])

        if command != "destroy":
            logger.success(f"{command.capitalize()} completed")
            return

        logger.success("Destroy completed")

    finally:
        if tfvars_path is not None:
            tfvars_path.unlink(missing_ok=True)

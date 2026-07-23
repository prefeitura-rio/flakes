"""Run Terraform commands with kubeconfig and secrets injected at runtime."""

from os import environ
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Literal

from .lib import die, info, run, run_binary, sops_dir, success, warning

Command = Literal["apply", "destroy", "import"]


def decrypt_incus_token() -> str:
    """Decrypt the Incus authentication token from its SOPS-encrypted file."""
    incus_token_sops = sops_dir() / "incus-token.sops"
    result = run_binary(
        ["sops", "decrypt", "--output-type", "binary", str(incus_token_sops)],
        capture=True,
    )
    token = result.stdout.strip().decode()
    if not token:
        die("Failed to decrypt Incus token — run: just rotate-incus-token")
    return token


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
    incus_token = decrypt_incus_token()
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
            f" -var=incus_token=$TF_INCUS_TOKEN"
            f" {' '.join(extra)}"
        ).strip()

        env = {**environ, "TF_INCUS_TOKEN": incus_token}

        match command:
            case "apply":
                info("Applying Terraform changes...")
            case "destroy":
                warning("Running Terraform destroy...")
            case "import":
                info(f"Importing resource: {' '.join(extra)}")

        _ = run(
            ["sops", "exec-file", "--no-fifo", str(kubeconfig_sops), sops_cmd],
            env=env,
        )

        if command != "destroy":
            success(f"{command.capitalize()} completed")
            return

        success("Destroy completed")

    finally:
        if tfvars_path is not None:
            tfvars_path.unlink(missing_ok=True)

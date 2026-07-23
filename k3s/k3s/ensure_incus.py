"""Ensure Incus remote is configured with a valid encrypted token."""

from os import environ
from pathlib import Path
from shutil import which
from socket import gethostname
from subprocess import CompletedProcess
from sys import argv
from time import time

from .lib import die, info, run, run_binary, sops_dir, success, warning

CACHE_TTL_MINUTES = 60


def parse_force() -> bool:
    """Return True if --force was passed on the command line."""
    return "--force" in argv[1:]


def incus_env() -> tuple[str, str]:
    """Return the Incus server host and user from environment variables."""
    host = environ.get("INCUS_SERVER_HOST", "")
    user = environ.get("INCUS_SERVER_USER", "")
    missing = [
        name
        for name, val in (("INCUS_SERVER_HOST", host), ("INCUS_SERVER_USER", user))
        if not val
    ]
    if missing:
        die(f"Missing required env vars: {', '.join(missing)} (run 'direnv allow')")
    return host, user


def cache_is_fresh() -> bool:
    """Return True if the Incus cache file exists and is within the TTL."""
    cache = sops_dir() / ".cache-incus"
    if not cache.exists():
        return False
    age_minutes = (time() - cache.stat().st_mtime) / 60
    return age_minutes < CACHE_TTL_MINUTES


def machine_id() -> str:
    """Return a stable machine identifier."""
    for path in [Path("/etc/machine-id"), Path("/var/lib/dbus/machine-id")]:
        if path.exists():
            return path.read_text().strip()
    return gethostname()


def client_name() -> str:
    """Return a unique client name derived from hostname and machine ID."""
    mid = machine_id()[:8]
    return f"{gethostname()}-{mid}"


def ssh_run(
    user: str,
    host: str,
    remote_cmd: str,
    *,
    capture: bool = False,
) -> CompletedProcess[str]:
    """Run a command on a remote host via SSH."""
    return run(
        [
            "ssh",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=accept-new",
            f"{user}@{host}",
            remote_cmd,
        ],
        capture=capture,
        check=False,
    )


def ensure_incus(*, force: bool = False) -> None:
    """Ensure Incus remote is configured with a valid encrypted token."""
    if not which("incus"):
        warning("incus not installed — skipping remote configuration")
        return

    d = sops_dir()
    incus_token_sops = d / "incus-token.sops"
    cache = d / ".cache-incus"

    if force:
        incus_token_sops.unlink(missing_ok=True)
        cache.unlink(missing_ok=True)

    if cache_is_fresh():
        return

    host, user = incus_env()
    name = client_name()

    incus_token_sops.unlink(missing_ok=True)
    info(f"Generating Incus token for {name} via {host}...")

    _ = ssh_run(user, host, f"incus config trust revoke-token {name}")

    result = ssh_run(user, host, f"incus config trust add {name}", capture=True)
    token = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""

    if not token or len(token) < 32:  # noqa: PLR2004
        die(f"Failed to obtain a valid token from {host}")

    d.mkdir(parents=True, exist_ok=True)

    encrypt = run_binary(
        [
            "sops",
            "encrypt",
            "--input-type",
            "binary",
            "--output-type",
            "binary",
            "--filename-override",
            str(incus_token_sops),
            "/dev/stdin",
        ],
        capture=True,
        stdin=token.encode(),
    )

    _ = incus_token_sops.write_bytes(encrypt.stdout)
    _ = incus_token_sops.chmod(0o600)

    _ = run(
        [
            "incus",
            "remote",
            "add",
            "k3s",
            f"{host}:8443",
            "--accept-certificate",
            f"--token={token}",
        ],
        check=False,
    )
    _ = run(["incus", "remote", "switch", "k3s"])

    _ = cache.touch()
    success("Incus client configured")


def main() -> None:
    """Run the ensure-incus command."""
    ensure_incus(force=parse_force())


if __name__ == "__main__":
    main()

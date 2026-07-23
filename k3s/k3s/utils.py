"""Shared subprocess and environment utilities for k3s management scripts."""

import subprocess as sp
import sys
from os import environ
from pathlib import Path
from typing import NoReturn

from loguru import logger


def sops_dir() -> Path:
    """Return the SOPS secrets directory."""
    return Path(environ.get("K3S_SOPS_DIR", ".k3s"))


def die(msg: str) -> NoReturn:
    """Log an error message and exit with code 1."""
    logger.error(msg)
    sys.exit(1)


def run(
    cmd: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    stdin: str | None = None,
    env: dict[str, str] | None = None,
) -> sp.CompletedProcess[str]:
    """Run a text-mode command and return the completed process."""
    return sp.run(
        cmd,
        text=True,
        capture_output=capture,
        check=check,
        input=stdin,
        env=env,
    )


def run_binary(
    cmd: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    stdin: bytes | None = None,
) -> sp.CompletedProcess[bytes]:
    """Run a binary-mode command and return the completed process."""
    return sp.run(cmd, capture_output=capture, check=check, input=stdin)

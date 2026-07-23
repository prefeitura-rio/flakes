"""Shared utilities for k3s management scripts."""

import sys
from os import environ
from pathlib import Path
from subprocess import CompletedProcess, run as subprocess_run
from typing import NoReturn

INFO = "\033[36m[>]\033[0m"
SUCCESS = "\033[32m[ok]\033[0m"
ERROR = "\033[31m[x]\033[0m"
WARNING = "\033[33m[!]\033[0m"


def sops_dir() -> Path:
    """Return the SOPS secrets directory."""
    return Path(environ.get("K3S_SOPS_DIR", ".k3s"))


def info(msg: str) -> None:
    """Print an informational message to stderr."""
    sys.stderr.write(f"{INFO} {msg}\n")


def success(msg: str) -> None:
    """Print a success message to stderr."""
    sys.stderr.write(f"{SUCCESS} {msg}\n")


def error(msg: str) -> None:
    """Print an error message to stderr."""
    sys.stderr.write(f"{ERROR} {msg}\n")


def warning(msg: str) -> None:
    """Print a warning message to stderr."""
    sys.stderr.write(f"{WARNING} {msg}\n")


def die(msg: str) -> NoReturn:
    """Print an error message and exit with code 1."""
    error(msg)
    sys.exit(1)


def run(
    cmd: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    stdin: str | None = None,
    env: dict[str, str] | None = None,
) -> CompletedProcess[str]:
    """Run a text-mode command and return the completed process."""
    return subprocess_run(
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
) -> CompletedProcess[bytes]:
    """Run a binary-mode command and return the completed process."""
    return subprocess_run(
        cmd,
        capture_output=capture,
        check=check,
        input=stdin,
    )

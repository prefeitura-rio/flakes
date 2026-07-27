from json import JSONDecodeError, loads
from typing import TypedDict, cast

from loguru import logger

from .utils import die, run

EXPECTED_DOMAIN = "squirrel-regulus.ts.net"


class TailscaleSelf(TypedDict, total=False):
    DNSName: str


class TailscaleStatus(TypedDict, total=False):
    Self: TailscaleSelf


def validate_tailscale() -> None:
    result = run(
        ["tailscale", "status", "--json"],
        capture=True,
        check=False,
    )

    if result.returncode != 0:
        die(f"Not connected to {EXPECTED_DOMAIN} — run: tailscale up")

    try:
        status = cast("TailscaleStatus", loads(result.stdout))
    except JSONDecodeError:
        die(f"Not connected to {EXPECTED_DOMAIN} — run: tailscale up")

    dns_name = status.get("Self", {}).get("DNSName", "")

    if EXPECTED_DOMAIN not in dns_name:
        die(f"Not connected to {EXPECTED_DOMAIN} — run: tailscale up")

    logger.success(f"Connected to {EXPECTED_DOMAIN}")


def main() -> None:
    validate_tailscale()


if __name__ == "__main__":
    main()

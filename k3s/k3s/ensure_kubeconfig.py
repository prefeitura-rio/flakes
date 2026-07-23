"""Fetch, patch, and encrypt the k3s kubeconfig from the Incus master node."""

from os import environ

from .lib import die, info, run, run_binary, sops_dir, success


def fetch_and_encrypt(cluster_name: str, hostname: str) -> None:
    """Fetch kubeconfig from the cluster master node, patch it, and encrypt with SOPS.

    Args:
        cluster_name: Incus cluster name prefix used to locate the master node.
        hostname: Hostname to substitute for 127.0.0.1 in the kubeconfig.
    """
    d = sops_dir()
    kubeconfig = d / "kubeconfig.sops"

    info(f"Fetching kubeconfig from {cluster_name}-master...")
    d.mkdir(parents=True, exist_ok=True)

    pull = run(
        [
            "incus",
            "file",
            "pull",
            f"{cluster_name}-master/etc/rancher/k3s/k3s.yaml",
            "/dev/stdout",
        ],
        capture=True,
        check=False,
    )

    if pull.returncode != 0 or not pull.stdout.strip():
        die(f"Failed to pull kubeconfig from {cluster_name}-master")

    patched = pull.stdout.replace("127.0.0.1", hostname).encode()

    encrypt = run_binary(
        [
            "sops",
            "encrypt",
            "--input-type",
            "binary",
            "--output-type",
            "binary",
            "--filename-override",
            str(kubeconfig),
            "/dev/stdin",
        ],
        capture=True,
        stdin=patched,
    )

    _ = kubeconfig.write_bytes(encrypt.stdout)
    kubeconfig.chmod(0o600)

    verify = run(
        [
            "sops",
            "exec-file",
            str(kubeconfig),
            "kubectl --kubeconfig={} get nodes",
        ],
        capture=True,
        check=False,
    )

    if verify.returncode != 0:
        die("Kubeconfig fetched but cluster unreachable")

    success(f"Kubeconfig encrypted at {kubeconfig}")


def main() -> None:
    """Fetch and encrypt kubeconfig from the cluster."""
    cluster_name = environ.get("CLUSTER_NAME", "")
    hostname = environ.get("K3S_MASTER_HOSTNAME", "k3s-master")

    if not cluster_name:
        die("CLUSTER_NAME is not set (run 'direnv allow')")

    d = sops_dir()
    (d / "kubeconfig.sops").unlink(missing_ok=True)
    fetch_and_encrypt(cluster_name, hostname)


if __name__ == "__main__":
    main()

use std/log
use ./tf.nu *
use ./lib.nu [run-command fail]

const QUOTA_PROJECT = "rj-iplanrio-dia"
const K3S_API = "https://tailscale-operator-onprem.squirrel-regulus.ts.net"

# Fetch GKE credentials for CLOUDSDK_CONTAINER_CLUSTER. Project and region come from CLOUDSDK_CORE_PROJECT and CLOUDSDK_COMPUTE_REGION.
export def --wrapped "main get-kubeconfig" [...extra: string]: nothing -> nothing {
    let cluster = $env.CLOUDSDK_CONTAINER_CLUSTER? | default null
    if $cluster == null or $cluster == "" {
        fail "Set CLOUDSDK_CONTAINER_CLUSTER to the cluster name." {
            command: get-kubeconfig
            span: (metadata $cluster).span
        }
    }

    run-command gcloud ...[
        container
        clusters
        get-credentials
        $cluster
        ...$extra
    ]
    | ignore
}

# Authenticate with Google Cloud and set the quota project.
export def "main auth" []: nothing -> nothing {
    log info "Authenticating with Google Cloud..."
    run-command gcloud ...[auth login]
    run-command gcloud ...[auth application-default login]
    run-command gcloud ...[auth application-default set-quota-project $QUOTA_PROJECT]
    log info "Authentication completed"
}

# Run kubectl against the K3s API through Tailscale, which identifies the caller. KUBE_HOST overrides the server.
export def --wrapped "main k" [...args: string]: nothing -> nothing {
    let server = $env.KUBE_HOST? | default $K3S_API
    with-env {KUBECONFIG: /dev/null} {
        run-command kubectl ...[
            --server
            $server
            --token
            unused
            ...$args
        ]
        | ignore
    }
}

# Run infrastructure operations through native namespaces.
def main []: nothing -> nothing {
    null
}

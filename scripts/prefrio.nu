use std/log
use ./tf.nu *
use ./lib.nu [run-command fail]
use ./project.nu [load-project-config]

const QUOTA_PROJECT = "rj-iplanrio-dia"
const K3S_API = "https://tailscale-operator-onprem.squirrel-regulus.ts.net"

if $env.PREFRIO_WORKDIR? != null {
    try { cd $env.PREFRIO_WORKDIR } catch {
        error make {
            msg: $"Cannot change to PREFRIO_WORKDIR: ($env.PREFRIO_WORKDIR)."
            label: {
                text: PREFRIO_WORKDIR
                span: (metadata $env.PREFRIO_WORKDIR).span
            }
        }
    }
}

# Fetch GKE credentials for the project cluster.
export def "main get-kubeconfig" [...extra: string]: nothing -> nothing {
    let config = load-project-config
    let k8s = $config.k8s? | default null

    if $k8s == null {
        fail "No k8s configuration found in the project file." {
            command: k8s
            span: (metadata $config).span
        }
    }

    if $k8s.cluster? == null { fail "Missing k8s.cluster in the project file." {command: k8s span: (metadata $k8s).span} }
    if $k8s.region? == null { fail "Missing k8s.region in the project file." {command: k8s span: (metadata $k8s).span} }
    if $config.project? == null { fail "Missing project in the project file." {command: k8s span: (metadata $config).span} }

    log info "Fetching Kubernetes credentials..."
    run-command gcloud ...[
        container
        clusters
        get-credentials
        $k8s.cluster
        --region
        $k8s.region
        --project
        $config.project
        ...$extra
    ]
    log info "Credentials configured"
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

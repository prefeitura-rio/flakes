use std/log
use ./tf.nu *
use ./lib.nu [run-command fail read-project select-environment]

const QUOTA_PROJECT = "rj-iplanrio-dia"
const K3S_API = "https://tailscale-operator-onprem.squirrel-regulus.ts.net"

# Fetch GKE credentials for a cluster of the current project, as described by its .project.json.
export def --wrapped "main get-kubeconfig" [
    --environment(-e): string # environment name; optional when the project has only one
    ...extra: string
]: nothing -> nothing {
    let project = read-project
    let selected = select-environment $project ($environment | default null)
    let cluster = $selected.cluster? | default null
    if $cluster == null or $cluster == "" {
        fail $"The selected environment of ($project.name) has no cluster in .project.json." {
            command: get-kubeconfig
            span: (metadata $selected).span
        }
    }
    let region = $selected.region?
    let location = if $region == null or $region == "" { [] } else { [--location $region] }

    run-command gcloud ...[
        container
        clusters
        get-credentials
        $cluster
        --project
        $selected.project
        ...$location
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

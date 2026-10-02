use std/log
use ./tf.nu *
use ./k3s.nu *
use ./lib.nu [run-command fail]
use ./project.nu [load-project-config]

const QUOTA_PROJECT = "rj-iplanrio-dia"

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

# Authenticate with Google Cloud and set the quota project.
export def "main auth" []: nothing -> nothing {
    log info "Authenticating with Google Cloud..."
    run-command gcloud ...[auth login]
    run-command gcloud ...[auth application-default login]
    run-command gcloud ...[auth application-default set-quota-project $QUOTA_PROJECT]
    log info "Authentication completed"
}

# Fetch GKE credentials for the project cluster.
export def "main k8s" [--prod ...extra: string]: nothing -> nothing {
    let config = if $prod { load-project-config --prod } else { load-project-config }
    let k8s = $config.k8s? | default null
    if $k8s == null {
        fail "No k8s configuration found in the project file." {
            command: k8s
            span: (metadata $config).span
        }
    }
    let cluster = $k8s.cluster? | default null
    let region = $k8s.region? | default null
    let project = $config.project? | default null
    if $cluster == null { fail "Missing k8s.cluster in the project file." {command: k8s span: (metadata $k8s).span} }
    if $region == null { fail "Missing k8s.region in the project file." {command: k8s span: (metadata $k8s).span} }
    if $project == null { fail "Missing project in the project file." {command: k8s span: (metadata $config).span} }
    log info "Fetching Kubernetes credentials..."
    run-command gcloud ...[container clusters get-credentials $cluster --region $region --project $project ...$extra]
    log info "Credentials configured"
}

# Run infrastructure operations through native namespaces.
def main []: nothing -> nothing {
    null
}

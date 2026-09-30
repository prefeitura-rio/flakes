use std/log
use ./tf.nu *
use ./k3s.nu *
use ./lib.nu [run-command]

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

# Run infrastructure operations through native namespaces.
def main []: nothing -> nothing {
    null
}

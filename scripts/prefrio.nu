use ./tf.nu *
use ./k3s.nu *

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

# Run infrastructure operations through native namespaces.
def main []: nothing -> nothing {
    null
}

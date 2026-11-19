# A runner has no global Git configuration and no Quality Gate variables. Tests
# must not lean on the identity, signing setup or settings of whoever runs them,
# so every test file that touches Git or the engine loads this module.
export-env {
    $env.GIT_CONFIG_GLOBAL = '/dev/null'
    $env.GIT_CONFIG_SYSTEM = '/dev/null'
    $env.GIT_CONFIG_NOSYSTEM = '1'
    for name in [
        CI
        QUALITY_GATE_CI
        QUALITY_GATE_MODE
        QUALITY_GATE_REPORT_UNTIL
        QUALITY_GATE_REPORT_PROJECT
        QUALITY_GATE_CHANGED_FILES
        QUALITY_GATE_ROOT
        QUALITY_GATE_REF
        QUALITY_GATE_RUN_REF
        QUALITY_GATE_RESOLVED_SHA
        QUALITY_GATE_REVISION
    ] {
        hide-env --ignore-errors $name
    }
}

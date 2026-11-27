# Quality Gate failure classification

## Current contract

Each check in the console, Markdown and JUnit reports is `finding` or `engine`.
Both block the default execution; the overall process exit code alone does not
identify the category. JUnit failure messages begin with `Category:`, which the
canary uses to reject engine failures. Successful checks are `none`.

| Phase or condition | Current classification | Evidence or limitation |
| --- | --- | --- |
| Policy, type, formatting or compilation errors | Usually `finding` | Tool-specific exit codes cannot identify every root cause. |
| Missing lockfile, declared Node version, project compiler or test script | `finding` | Explicit consumer configuration checks. |
| `uv sync`, `npm ci` or `pnpm install` fails | `engine` | All nonzero exits, including errors caused by project configuration. |
| Oxlint reports a bad central configuration | `engine` | The known error message overrides exit 1. |
| Other unexpected tool exit or an uncaught runner exception | Usually `engine` | Test runners classify any nonzero exit as `finding`. |
| Test runner reports a failing test | `finding` | A runner exit does not distinguish an assertion from an infrastructure failure. |
| Detection fails or a JUnit report is missing on a failed job | Canary treats it as unhealthy | A missing report is not evidence of a code finding. |

Go checks and tests run with cgo disabled. The reports identify project files
selected only with cgo enabled when Go can inspect the package metadata. A
failed or incomplete inspection is reported as a warning, not a finding or an
engine failure; it does not establish that all skipped files were identified.

The diagnostic records the tool and original exit code, plus captured tool
output. Engine failures receive environment-oriented guidance instead of a
code-fix command. Formatter output is retained in the reports as well as logs.
Logs and artifacts may contain tool output from the project: avoid printing
secrets or personal data and follow the repository's artifact access policy.

## Remaining design work

The classification is not a complete root-cause detector. Define and test a
tool-and-phase-specific taxonomy before adding broader rules for network,
registry authentication, missing system libraries, Git/VCS, timeouts, process
signals, malformed consumer configuration and build/test failures. Project
text and test output are untrusted: generic substrings are not enough to
classify a failure as infrastructure. Tests must also prove that real code
violations stay findings, and that fixes and messages do not expose credentials.
Track the work in QG-075 and Git/VCS in QG-069.

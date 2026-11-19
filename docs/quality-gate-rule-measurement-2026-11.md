# Quality Gate rule measurement

Measurement date: 2026-11-17.

The measurement was performed on temporary copies, before the curated policy
was applied. It is evidence for choosing rules, not a baseline that silently
changes the gate. The source repositories and sandboxes were not modified.

## Samples

| Language | Samples |
|---|---|
| Python | `python-battlegrounds`, `mcp-triagem-smtr`, `infopref-chat-api`, `data-proxy/sync` |
| Go | `go-battlegrounds`, `go-projects-template/api`, `app-rmi` (real service copy) |
| TypeScript | `typescript-battlegrounds`, `vue-battlegrounds`, `dashboard-whatsapp` |

## Findings by rule

The most frequent findings under the former broad policy were:

### Python

| Rule | Highest observed count |
|---|---:|
| `COM812` | 1,139 |
| `E501` | 626 |
| `ANN001` | 565 |
| `ANN201` | 362 |
| `PT018` | 175 |
| `TRY003` | 92 |
| `ARG001` | 89 |
| `D102` | 75 |
| `EM101` | 60 |
| `PLC0415` | 46 |
| `T201` | 45 |

These results support excluding documentation, annotation and formatter-noise
families from the mandatory floor while retaining targeted correctness,
security, import, modernization and complexity rules.

### Go

The Go sandbox produced five findings:

| Rule | Count |
|---|---:|
| `paralleltest` | 3 |
| `forbidigo` | 1 |
| `nlreturn` | 1 |

`forbidigo` remains in the curated policy. `paralleltest` and `nlreturn` are
not part of the central mandatory list.

The real `app-rmi` copy produced 427 findings. The largest groups were
`errorlint` (113), `gocritic` (89), `errcheck` (54), `misspell` (53),
`gocyclo` (38), `unparam` (33), `staticcheck` (11), `forbidigo` (11),
`whitespace` (9), `gosec` (2) and `unconvert` (1). This confirms that the
curated list is materially more actionable than the former `default: all`
policy, while retaining the most relevant groups.

### TypeScript

| Sample | Main findings |
|---|---|
| `typescript-battlegrounds` | `eslint(no-var)`, `eslint(no-debugger)`, `eslint(eqeqeq)`, `typescript(no-explicit-any)` |
| `vue-battlegrounds` | `typescript(no-explicit-any)` |
| `dashboard-whatsapp` | `typescript(no-non-null-assertion)`, `react-hooks(rules-of-hooks)`, `typescript(no-explicit-any)`, React purity/immutability findings |

The curated Oxlint policy keeps the explicit central correctness, React Hooks
and accessibility rules. Broad categories are not enabled, so a tool upgrade
cannot silently add new blocking rules.

For typecheck, the first pass with central `skipLibCheck: false` produced
third-party declaration failures in `vue-battlegrounds` (`@vitest`, Vue Test
Utils, Rollup and missing Node declarations). The central policy now uses
`skipLibCheck: true`; project source files remain typechecked while broken
external `.d.ts` files do not block the consumer.

## Policy guard

`tests/snapshots/quality-gate-policy.json` is the reviewed snapshot of the
curated rule sets. `quality-gate:self-test` compares the central Ruff,
golangci-lint, basedpyright and Oxlint policies with that snapshot. Changing a
policy requires changing the snapshot in the same reviewed change.

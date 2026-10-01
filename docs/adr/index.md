---
type: reference
title: Architecture Decision Records
---

# Architecture Decision Records

Nygard format: Context → Decision → Consequences → Alternatives considered.

One file per decision, `docs/adr/NNNN-kebab-title.md`, zero-padded and monotonically
increasing. Required frontmatter: `type: decision`, `title:`, `status:`, `date:`.

| Status | Meaning |
| --- | --- |
| `proposed` | Raised, not yet decided |
| `accepted` | In force |
| `deprecated` | No longer applies |
| `superseded` | Replaced by a later ADR |

## Records

| ADR | Title | Status | Date |
| --- | --- | --- | --- |
| [0001](0001-local-first-launcher-not-a-methodology-runtime.md) | Local-First Launcher, Not a Methodology Runtime | accepted | 2026-09-25 |
| [0002](0002-declare-model-tiers-never-auto-route.md) | Declare Model Tiers, Never Auto-Route | accepted | 2026-09-25 |
| [0003](0003-parallel-agents-via-disjoint-path-sets.md) | Parallel Agents via Disjoint Path Sets, No Git, No Worktree | accepted | 2026-09-25 |
| [0004](0004-jev-ai-is-not-adopted.md) | Jev AI Is Not Adopted | accepted | 2026-09-25 |
| [0005](0005-no-external-agent-orchestration-dependency.md) | No External Agent-Orchestration Dependency | accepted | 2026-09-25 |
| [0006](0006-vendor-ollama-tool-call-proxy.md) | Vendor the Ollama Tool-Call Proxy from `photography_ai` | accepted | 2026-09-28 |
| [0007](0007-trinity-orchestrator-runs-headless-opencode-run.md) | Trinity Orchestrator Runs Headless `opencode run`, Skills Not New Agents | accepted | 2026-09-30 |

`0007` was tested before acceptance, and its two original assumptions turned out to be
**false, silently**: `opencode run` exits 0 on success and on hard failure alike, and
`--agent general` is ignored because `general` is a subagent. Both were replaced.
Completion is read from the `reason` field of the last `step_finish` event — a crash
detector, not a task-completion detector, since a role refusing on role grounds ends on the
same event as success. That gap is closed by a role-reported sentinel
(`TRINITY-DONE` / `TRINITY-REFUSED`), whose compliance was measured in both directions.

Accepted means the decisions are made. Implementation is **done** — `scripts/trinity.sh`
and `scripts/test-trinity.sh`. One acceptance criterion could not be met as written: the
disjoint path check holds in **chain mode only**, because brahma's and vishnu's permitted
sets together cover the whole tree, so a concurrent write cannot be attributed to a role.
The orchestrator says it is not checking rather than reporting a result it cannot justify.
Recorded as a deviation in the plan. One verification item also remains open: whether a
provider failure emits a partial stream that looks complete. See
[the contract](../architecture/trinity-orchestrator/contract.md) §9.

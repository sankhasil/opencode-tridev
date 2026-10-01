---
type: reference
title: Architecture Plans
---

# Architecture Plans

Blueprint documents produced by Brahma. Each plan is an OKF bundle of its own: the plan
states WHAT and WHY, and a sibling contract file carries the HOW.

| Plan | Status | Summary |
| --- | --- | --- |
| [trinity-orchestrator/](trinity-orchestrator/plan.md) | accepted | Run the Agent Trinity headlessly via `opencode run`. Sequential chain plus a plan-guarded parallel pair. |

## Files

| Path | Purpose |
| --- | --- |
| [trinity-orchestrator/plan.md](trinity-orchestrator/plan.md) | Goals, non-goals, user stories, acceptance criteria, constitutional gates |
| [trinity-orchestrator/contract.md](trinity-orchestrator/contract.md) | Invocation, modes, role wiring, completion signal, state layout, path-check algorithm, verification checklist |

A plan becomes `accepted` when the operator has reviewed it and a matching ADR is
`accepted`. See [ADR index](../adr/index.md).

The trinity-orchestrator plan is **accepted and implemented**
(`scripts/trinity.sh`, `scripts/test-trinity.sh`). The verified and still-unknown items
are tabulated in [contract §9](trinity-orchestrator/contract.md).

**One deviation, recorded not resolved:** US3 (the disjoint path check) holds in chain
mode only. In parallel mode the check cannot attribute a write to a role, so the
orchestrator says it is not checking rather than reporting a result it cannot justify.
See *Deviation from US3* in the plan. Brahma owns whether to restate US3 or drop
`--parallel`.

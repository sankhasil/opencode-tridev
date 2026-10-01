---
type: concept
title: Trinity Orchestrator Plan
status: accepted
---

# Trinity Orchestrator

A script that runs the Agent Trinity — Brahma, Vishnu, Maheshwara — as headless
`opencode run` processes, so the handoffs happen reliably instead of depending on the
operator remembering to load three skills in order.

This plan covers **WHAT and WHY**. Contracts and algorithms live in
[contract.md](contract.md).

## Context

The Trinity is a convention in `AGENTS.md`, not code. Today the operator drives it
manually: invoke the `brahma` skill, read the plan, invoke `vishnu`, invoke
`maheshwara`. Nothing fails when a step is skipped, and nothing detects a role touching
a path it may not.

[ADR 0003](../../adr/0003-parallel-agents-via-disjoint-path-sets.md) permits exactly one
concurrent pair, Brahma ‖ Vishnu, and requires fail-closed behaviour if disjointness
cannot be established. It also records that the safety is *social, not enforced* — the
failure mode is silent. This orchestrator makes the ordering and the check real. It does
**not** add undo; there is still no git and no worktree.

## Scope

| In scope | Out of scope |
| --- | --- |
| One command per mode, two modes | Resumable/interactive mode |
| Sequential chain and the guarded parallel pair | Any pair other than Brahma ‖ Vishnu |
| A post-run disjointness check that warns | Blocking a write via tool permissions |
| Roles addressed by prompting the existing skill | New `.opencode/agent/*.md` files |
| Model selection inherited from `opencode.json` | Model routing or tier logic (ADR 0002) |
| | Worktrees, git, containers, external orchestrators (ADR 0003, ADR 0005) |

## Goals

1. **G1 — Reliable handoffs.** Running the chain produces a plan, then an implementation
   that reads that plan, then a verification that reads both, without operator
   intervention.
2. **G2 — Enforced order.** A role never starts before its predecessor has finished. The
   chain cannot skip a phase.
3. **G3 — Fail closed on concurrency.** The parallel mode refuses to run unless the
   precondition for disjointness is established. Refusal is a message and a non-zero
   exit, not an error.
4. **G4 — Detectable breach.** If a role wrote outside its permitted paths, the run says
   so explicitly instead of leaving it for the operator to notice.
5. **G5 — No new state to hold.** One script, one state directory, no daemon, nothing
   left running between sessions.

G1 is bounded by a measured limit, not by hope. The chain guarantees *order*, *clean
termination*, and — via the completion sentinel — that a role did not decline or go
silent. It does **not** guarantee the work was good, and the sentinel is a model's
self-report, not a check. Judging output remains the operator's, which is a stated
non-goal.

## Non-goals

These are refusals, not deferrals. They are written down so they decay slowly.

- **Not a replacement for the operator's judgement.** The orchestrator runs three roles
  in order. It does not decide whether a plan is good.
- **Not a safety net.** No undo, no worktree, no container. A stray edit in the main
  working tree remains unrecoverable, exactly as ADR 0003 accepted.
- **Not a general agent runner.** Two modes, three roles. No `--agent` passthrough, no
  arbitrary fan-out, no queue.
- **Not a distribution surface.** Per ADR 0001 this is a local-first launcher. The
  orchestrator does not gain an install path, a config file, or a version.

## User stories

### US1 — Run the whole chain

> As the operator, I want one command that plans, builds, and verifies, so I do not
> have to hold the handoff sequence in my head.

**Acceptance criteria**

- Given a task string, when I run the chain mode, then all three roles run in the order
  Brahma → Vishnu → Maheshwara.
- Given any role crashes, declines, or fails to report, when the chain continues, then it
  does not: the chain stops, names which role and why, and exits non-zero. None of those
  three is decided by the exit code, which is always 0.
- Given the chain completed, when it returns, then the output states, per role, whether
  its permitted-path check passed, warned, or was not applicable.

### US2 — Run the parallel pair

> As the operator, I want to re-plan and re-implement at the same time when a plan
> already exists, because those two touch different paths.

**Acceptance criteria**

- Given no plan on disk, when I run the parallel mode, then it refuses, explains that
  Vishnu would have nothing to build from, and exits non-zero without starting anything.
- Given a plan on disk, when I run the parallel mode, then Brahma and Vishnu both start,
  and neither waits for the other.
- Given the parallel mode completed, when it returns, then the disjointness check ran
  against both roles and reported per role.

### US3 — Catch a path breach

> As the operator, I want to be told when a role wrote outside its permitted paths,
> because ADR 0003 says that breach is currently silent.

> **Partially met — chain mode only.** See *Deviation from US3* below. Parallel mode cannot
> attribute a write to a role and reports that it is not checking.

**Acceptance criteria**

- Given a role modified a file outside its permitted paths, when the run ends, then the
  output names the offending role and the file. **Chain mode only.**
- Given a breach, when the run ends, then the exit code is non-zero, so a breach cannot
  pass unnoticed in a log. **Chain mode only.**
- Given no breach, when the run ends, then nothing is printed about paths. Both modes.
- Given parallel mode, when the run ends, then the output says the path check did not
  apply and why. *(Added during implementation — see deviation.)*

### Deviation from US3

Found while implementing, 2026-09-30. **US3 as written is not achievable in parallel mode.**

Brahma's permitted set is `docs/`; Vishnu's is everything *except* `docs/`. Together those
two sets cover the entire working tree, so every file either role writes is permitted for
*one* of them. In parallel mode both roles also write into that same tree at the same time,
and `find -newer` cannot say whose write it is.

The first implementation ran the per-role check anyway. It did not fail open — it failed
**wrong**: it attributed Vishnu's writes to Brahma and reported a breach on every parallel
run, which would have made `--parallel` unusable while printing a confident warning.

The implementation therefore checks paths in chain mode, where each role has the tree to
itself and attribution is sound, and in parallel mode prints that the check does not apply
rather than printing a clean result it cannot justify.

**Consequence: in parallel mode disjointness is enforced only by the role prompts.** That
is the "social, not enforced" state ADR 0003 already records, not an improvement on it.

**What would actually close this** — all rejected as out of scope for this plan:

| Option | Why not |
| --- | --- |
| Per-role worktrees or subdirectories, merge after | This is git worktree isolation, declined in ADR 0003 |
| Each role stamps and sweeps only its own window | Windows still overlap in one tree; does not attribute |
| Ask the roles to self-report which paths they wrote | The sentinel already asks them to self-report completion; trusting a second self-report for safety is worse than trusting one for progress |

Brahma should decide whether US3 is restated as chain-mode-only, or whether parallel mode
is dropped until a real isolation mechanism is accepted. Recorded rather than decided.

### US4 — Nothing left behind

> As the operator, I want no background process and no mystery state, so I can close the
> terminal and know the machine is idle.

**Acceptance criteria**

- Given a run that finished or failed, when the script exits, then no child process
  remains.
- Given a run that finished, when I look at the state directory, then it contains only
  the recorded run status and logs for that run.

## Design principles

1. **Bash, because `scripts/opencode.sh` is bash.** One language for the launcher's
   scripts. No new runtime.
2. **Roles are prompts, not new declarations.** The three roles exist as skills. The
   orchestrator passes a prompt that instructs the agent to load that skill. Adding
   `.opencode/agent/*.md` would create a second place to drift.
3. **Warn, do not block.** The check runs after the fact. Blocking writes would convert
   a social invariant into a permission, which is a different decision and would need
   its own ADR.
4. **Fail closed means refuse, not crash.** Preconditions unmet → message + non-zero
   exit. No partial start, no retry loop, no sleep.
5. **One state directory, inspectable by hand.** The operator should be able to read it
   with `cat`. No database, no JSON schema, no lockfile protocol.

## Decisions

| # | Decision | Rationale | Recorded in |
| --- | --- | --- | --- |
| D1 | Two modes, not one flag soup | A full chain and a concurrent pair are different intents with different preconditions. One flag with three values would need a truth table. | this plan |
| D2 | Parallel mode requires a plan on disk | Without it, Vishnu has no input and the pair is a race. The requirement turns "parallel" into a checkable precondition. | [ADR 0007](../../adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) |
| D3 | Roles addressed by skill prompt | No new agent files. The skill is already the definition of the role. | [ADR 0007](../../adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) |
| D4 | Post-run check, warn and exit non-zero | Detecting the breach is the requirement. Blocking the write is not, and would change ADR 0003. | this plan |
| D5 | No external orchestrator | Still declined. Nothing about the new requirement reopens it. | [ADR 0005](../../adr/0005-no-external-agent-orchestration-dependency.md) |
| D6 | Success is read from the event stream, not the exit code | Verified 2026-09-30: the exit code is 0 on success and on hard failure alike. `reason: "stop"` on the last `step_finish` is the only signal that separates them. | [contract.md §4](contract.md) |
| D7 | Omit `--agent` entirely | Verified 2026-09-30: an unknown or subagent name is silently replaced by the default agent, with exit 0. The role comes from the prompt, so the flag is not just unnecessary — depending on it to fail loudly is unsafe. | [contract.md §3](contract.md) |
| D8 | `reason: "stop"` is a crash detector, not a completion detector | Verified 2026-09-30: a role refusing on role grounds ends on `stop`, identically to success. The distinction is real and measurable, so the plan states it rather than calling the rule a success check. | [contract.md §4](contract.md) |
| D9 | Each role reports its own outcome via a sentinel line | Chosen over doing nothing (D8 leaves the chain building on nothing) and over inferring completion from touched files, which fails for a read-only finisher. Cost accepted: a model can report a success that did not happen. | [contract.md §4](contract.md), [ADR 0007](../../adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) |

## Constitutional gates

| Gate | Check | Result |
| --- | --- | --- |
| Simplicity | ≤3 components, no future-proofing | **Pass.** Two components: `scripts/trinity.sh`, a state directory. No queue, no worker, no daemon, no config file. Modes are branches in one script, not components. |
| Anti-abstraction | Framework used directly, not wrapped | **Pass.** `opencode run` is called as a CLI. No wrapper library, no agent SDK, no config abstraction over `opencode.json`. The role prompt is a string. |
| Testability | Acceptance criteria are testable | **Pass.** Each US states observable input → output → exit code. US3 is testable by making a role write a known file outside its permitted set. |

Gates pass with no exceptions recorded.

## Complexity tracking

Empty. Nothing in the plan needed a documented gate exception.

If a later change adds a queue, a worker pool, a retry policy, a config file, or a
fourth mode, that change must come back here and justify itself.

## Resolved decision: a role-reported completion sentinel

`reason: "stop"` answers "did the agent stop cleanly?". It does not answer "did the agent
do the work?" — a role refusing on role grounds was measured to end on the identical
event. The gap: a role that produces nothing useful is read as complete, the chain
proceeds, and the next role builds on nothing.

**Decision (option B, 2026-09-30): each role reports its own outcome.** The prompt ends
with an instruction to close on exactly one line — `TRINITY-DONE: <role>` or
`TRINITY-REFUSED: <reason>`. The chain continues only on `DONE`. `REFUSED` stops the
chain, and so does the absence of either line: the ambiguous case is the one that must not
pass. The crash check runs first, because a stream that never completed a turn has no
trustworthy final text.

| Option | Mechanism | Why not |
| --- | --- | --- |
| A | Crash detector only | Leaves the gap: Brahma returns a note instead of a plan, Vishnu builds on nothing |
| **B (chosen)** | Sentinel line per role | A model can report a success that did not happen. Accepted with ADR 0007 revisit trigger 5 |
| C | Reuse the path check — a role that touched no permitted file did nothing | Fails for maheshwara, which may legitimately only read and clean up |

Compliance was measured in both directions before choosing: given a task it must decline,
the model emitted `TRINITY-REFUSED` with a reason; given a task it should do, it emitted
`TRINITY-DONE` and wrote the file. One sample each — the mechanism works, and one sample
is not a reliability claim.

## Open questions for Vishnu

The two questions this plan originally carried were tested on 2026-09-30, and **both
answers were false in a way that was silent** — the mechanism reported success while
doing the wrong thing. See [contract.md §9](contract.md) for the full table.

- [x] Does `opencode run` exit non-zero on agent failure? **No — always 0.** Replaced by
      the event-stream rule: a role completed its turn only if its last `step_finish`
      carries `reason: "stop"`.
- [x] Does `--agent general` load skills? **No — the flag is ignored**, because `general`
      is a subagent and OpenCode falls back to the default agent. Omitting the flag
      entirely works: the prompt's `Load the <role> skill` call loads it correctly.
- [x] Does `reason: "stop"` separate a completed turn from a healthy refusal?
      **No — they are the same event.** Resolved by the sentinel decision above.
- [ ] Does a provider failure emit an empty stream, or a partial one that looks complete?
- [ ] Decide the state directory location. `.trinity/` at repo root is the default
      proposal; it needs a `.gitignore` entry if git is ever initialised.

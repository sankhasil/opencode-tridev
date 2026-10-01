---
type: decision
title: Trinity Orchestrator Runs Headless opencode run, Skills Not New Agents
status: accepted
date: 2026-09-30
---

# Trinity Orchestrator Runs Headless `opencode run`, Skills Not New Agents

## Context

The Agent Trinity is a convention in `AGENTS.md`, invoked as three skills. Nothing
executes the handoff sequence; the operator loads each skill in turn. Nothing detects a
role writing outside its permitted paths, which [ADR 0003](0003-parallel-agents-via-disjoint-path-sets.md)
records as the decision's real weakness — "the safety here is social, not enforced. The
failure mode is silent."

[ADR 0005](0005-no-external-agent-orchestration-dependency.md) declined any external
orchestration dependency. That decision is about *dependencies*, and nothing here reopens
it — no new runtime, no new package. What is missing is a way to sequence the three
existing skills headlessly.

OpenCode already ships the primitives. `opencode run --agent <name> "<prompt>"` runs an
agent non-interactively, and `opencode agent list` returns `build`, `compaction`,
`explore`, and `general`. The three trinity roles are **not** in that list: they exist
only as skills under `.agents/skills/`. So `opencode run --agent brahma` cannot work
today, and how the gap is bridged is a decision with lasting consequences.

A second question had to be settled first. The operator asked for the full chain in one
command *and* for the parallel pair. These conflict: Vishnu consumes Brahma's plan, so
running them concurrently in the same run leaves Vishnu with no input. The resolution
chosen is that the chain is sequential, and the parallel pair is a separate mode whose
precondition is a plan already on disk.

The full plan is [docs/architecture/trinity-orchestrator/plan.md](../architecture/trinity-orchestrator/plan.md).

## Decision

`scripts/trinity.sh` runs the trinity roles as headless `opencode run` processes, in two
modes.

**Sequential chain** — `trinity.sh <task>` runs Brahma → Vishnu → Maheshwara in order.
A role that exits non-zero stops the chain.

**Guarded parallel pair** — `trinity.sh --parallel <task>` runs Brahma ‖ Vishnu
concurrently, and **refuses unless a plan already exists on disk**, exiting 3 without
starting anything. The plan is checked once, before either process starts. There is no
polling, no sleep, no retry: a precondition that cannot be established is a refusal, not
an error to work around.

Maheshwara is never part of a concurrent pair, per ADR 0003.

**Roles are addressed by prompting the existing skill, not by declaring new agents.** No
`.opencode/agent/brahma.md` (or vishnu, maheshwara) is created. The orchestrator calls
`opencode run` with **no `--agent` flag**, passing a prompt that instructs the agent to
load the corresponding skill and states the role's permitted paths.

**Success is read from the event stream, not the exit code.** A role completed its turn if
and only if its `--format json` stream's last `step_finish` event carries `reason: "stop"`.
The orchestrator always passes `--format json` and parses it line by line. This is a crash
detector, not a task-completion detector — see Verification.

**Each role reports its own outcome.** The role prompt ends with an instruction to close on
exactly one line: `TRINITY-DONE: <role>` if the task was completed, or
`TRINITY-REFUSED: <reason>` if it was declined. The chain continues only on `DONE`.
`REFUSED` stops the chain, and so does the absence of either line — the ambiguous case is
the one that must not pass. The crash check runs first, because a stream that never
completed a turn has no trustworthy final text.

**The disjointness check runs after the fact.** File modification times are compared
across each role's run; a role that wrote outside its permitted paths is named, the
offending files are listed, and the exit code is 1. It does not block the write, and it
does not use tool permissions to prevent one.

**State is one plain-text directory**, `.trinity/`, holding the run's logs and check
result. No database, no queue, no resume token, no daemon, no config file.

## Verification, 2026-09-30

The two assumptions this ADR originally rested on were tested before acceptance. **Both
were false, and both failed silently** — reporting success while doing the wrong thing.

| Assumption | Result |
| --- | --- |
| `opencode run` exits non-zero on agent failure | **FALSE.** Exit 0 on a run that hit a hard `read` error and printed `Error: The user rejected permission`. Also 0 on success. The two are indistinguishable. |
| `opencode run --agent general` loads skills | **FALSE as written.** `! agent "general" is a subagent, not a primary agent. Falling back to default agent`, exit 0. |
| The three roles are not declared OpenCode agents | **TRUE.** `opencode agent list` returns `build`, `compaction`, `explore`, `general`. |
| A headless role can load its skill | **TRUE.** With the flag omitted, the `skill` tool returned full brahma content and the agent adopted the role. |
| A headless role can write in-tree | **TRUE.** `write` completed. Probe file deleted. |
| A headless role is confined to the working tree | **TRUE.** An out-of-tree read was auto-rejected by the `external_directory` permission. |

The silent-fallback behaviour is the notable part. Passing a role name that does not exist
does not fail — OpenCode substitutes the default agent and carries on. This is the third
silent-fallback defect in this repository, after `port_up` reporting down services as up
and the `/models` catalog overwrite dropping 33 models behind a green check. The pattern
is consistent enough to be worth naming: **a check that cannot fail is not a check.**

The replacement for the exit code is a single field. A successful run ends on
`step_finish` with `reason: "stop"`; the failed run ended on `reason: "tool-calls"`,
still mid-turn. One string, measured on both cases.

### The rule is a crash detector, not a completion detector

Tested next: can `reason: "stop"` tell a completed turn from a healthy refusal? **No.**

| Run | Last event | Actual behaviour |
| --- | --- | --- |
| Brahma asked to write `src/main/kotlin/Util.kt` | `stop` | Refused — cited the skill's "never write application code" rule, offered two options |
| `build` asked for a Kotlin file in a repo containing no Kotlin | `stop` | Refused — no `*.kt`, no `build.gradle`, asked where to put it |

Both refusals are indistinguishable from success at the event level. Reading a refusal as
success is the *safer* error — a refused role has not touched the tree, and the operator
sees why in the log — but it means the chain cannot detect a role that finished its turn
having produced nothing useful. The realistic failure: Brahma returns a one-line note
instead of a plan, Vishnu starts building on nothing, and with no git there is no recovery.

This is the fourth silent-failure shape in this repository. Two options were put to the
operator rather than chosen here:

| | Mechanism | Why not |
| --- | --- | --- |
| A | Crash detector only | Leaves the chain building on nothing when a role returns an empty result |
| **B (chosen)** | Sentinel line per role | A model can report a success that did not happen — accepted, see Consequences |
| C | Reuse the path check — a role that touched no permitted file did nothing | Fails for maheshwara, which may legitimately only read and clean up |

### Sentinel compliance, measured in both directions

A model-reported sentinel has an obvious failure mode: false compliance. Tested before
adopting it.

| Case | Result |
| --- | --- |
| Load brahma, then write `src/main/kotlin/Util.kt` | `TRINITY-REFUSED: Brahma may not write application code; Util.kt belongs to Vishnu` |
| Load brahma, then write a plan file | `TRINITY-DONE: brahma`, and the file was written with correct content |

The model chose `REFUSED` on its own, without being told which outcome was expected, and
volunteered an unprompted caveat that the probe path was not brahma's canonical location.
One sample each. This shows the mechanism works; it is not a reliability claim.

## Consequences

### Positive

- The handoffs become reliable. A role cannot start before its predecessor finishes, and
  a failed role stops the chain instead of the next role silently building on nothing.
- The silent failure in ADR 0003 becomes loud. A breach names the role and the file and
  sets a non-zero exit code, so it cannot pass unnoticed in a log.
- Zero new dependencies. `opencode run` is already installed; ADR 0005 stays in force
  untouched.
- No new place for the role definition to drift. The skill remains the single definition
  of what Brahma, Vishnu, and Maheshwara are.
- The parallel pair gains a real precondition instead of a race. "A plan must exist" is
  checkable; "wait until the plan appears" is a sleep loop pretending to be a dependency.
- Two components total: one script, one state directory. The constitutional simplicity
  gate passes with no exception.

### Negative

- **The parallel mode is nearly useless on first run.** With no plan on disk it exits 3,
  so the common case is chain-then-parallel: run the chain once to create a plan, then
  use `--parallel` for re-planning and re-implementing together. This is a two-step
  habit the operator must learn.
- **The path check attributes by mtime, not by authorship.** An operator edit in another
  terminal during a run is reported as a breach. With no VCS there is no other signal.
  This is a false positive that is deliberately preferred over the silent miss.
- **The check misses a file created and deleted mid-run.** A `find -newer` sweep cannot
  see it; a two-snapshot diff would miss it too. Accepted, because the file no longer
  exists and there is no git to restore it.
- **The role prompt is a string in a shell script.** Renaming a skill silently breaks the
  orchestrator until the string is updated. Two places to touch, not one — the cost of
  not creating agent files.
- **A breach stops the run but cannot undo it.** The script reports and exits; there is
  no recovery, exactly as ADR 0003 accepted.
- **The `reason: "stop"` rule detects crashes, not task completion.** Measured: a role
  refusing on role grounds ends on `stop`, identically to success. The sentinel closes
  the resulting gap, but only for a role that reports honestly.
- **The sentinel is a model's self-report, and a model can report a success that did not
  happen.** This is the accepted cost of the chosen option, and it is the same bug shape as
  the always-zero exit code it replaces: a signal that looks like a check. Measured
  compliance in both directions, one sample each. If it proves unreliable in practice,
  revisit trigger 5 says to **delete the sentinel rather than trust it** — the fallback is
  option A, the crash detector alone, which leaves a known gap.
- **A refusal stops the chain, which is a behaviour change from today's manual flow.** A
  role declining used to cost nothing but a re-prompt; now it ends the run with a non-zero
  exit. Deliberate — building on a refusal is how work gets lost — but it will feel
  abrupt the first time it happens.
- **`tool_use` with `status: "error"` is logged but does not stop the chain.** It is a
  reliable signal and the wrong stop condition: an agent that hits one bad read and
  recovers would be failed. Two signals, one used, is a judgement that a future reader
  will have to re-derive.
- **Low-traffic code rots.** The parallel mode is the rarer path and will be exercised
  less than the chain. Same risk ADR 0006 recorded for the vendored proxy.
- **One open assumption blocks handoff.** That `reason: "stop"` distinguishes a completed
  turn from a crash, including when the crash is a model or provider failure producing an
  empty stream. Verified on agent failure; not yet verified on provider failure.
- **The orchestrator cannot stop a role mid-write.** It learns a role failed only after
  the role has already finished. Fail-closed applies to *starting* the next role, never to
  undoing the last one.

## Revisit triggers

1. The parallel pair is requested three times in a row without a prior plan. The
   precondition is in the wrong place.
2. An agent edit loses work. Already a trigger in ADR 0003; the check does not address it.
3. `opencode run` fails to distinguish a completed turn from a crash by `reason: "stop"`.
   Verified it does distinguish those. Still open: whether a **provider** failure emits a
   partial stream that looks complete.
4. A fifth role, a second parallel pair, or a queue is requested. All three mean this is
   becoming a general agent runner, which ADR 0001 puts outside the launcher scope.
5. **The task-completion sentinel is added and proves unreliable** — a role prints
   `TRINITY-DONE` without having done the work. This is the same class of bug as the
   always-zero exit code. The response is to delete the sentinel and fall back to option
   A, not to add a second signal on top of an untrustworthy first one.
6. A role refuses in a situation the operator did not expect, more than a few times. The
   refusal-stops-the-chain rule is correct but blunt; if it is routinely wrong it becomes
   the reason the orchestrator gets abandoned.

## Alternatives considered

- **Declare `.opencode/agent/brahma.md`, `vishnu.md`, `maheshwara.md`.** Rejected. Each
  role would then be defined twice — once as a skill, once as an agent — and the two
  could drift. It also adds three files to a project whose Ponytail rules push against
  adding things. The prompt string is one line each and lives beside the code that
  depends on it. Note the verification result in the other direction: an agent name that
  does not exist is *silently substituted*, so this alternative's main advantage — a
  declared role that cannot be missed — would not have been delivered anyway without
  checking the stream for the expected skill load.
- **Rely on the exit code as the chain's stop condition.** Rejected by measurement. It is
  0 on success and 0 on hard failure. This is the alternative the plan started with, and
  it would have produced a chain that reported three green phases over a run where two
  agents had failed.
- **Infer completion from the role's touched-file set.** Rejected. The path check already
  collects it, so the cost was near zero — but a read-only maheshwara that verified and
  cleaned nothing would read as having done nothing, and the chain would stop on a
  healthy agent.
- **Merge each skill into its agent file and delete the skill.** Rejected. It removes the
  drift, but it rewrites three working skills to solve a problem that a prompt string
  does not have.
- **External orchestrator (sandcastle, or similar).** Rejected, unchanged. ADR 0005
  declined it on four recorded conflicts; orchestrating three existing skills is not one
  of them.
- **Block path breaches with tool permissions instead of checking afterwards.** Rejected.
  It would convert the invariant from social to enforced, which is a real improvement and
  a different decision. It also constrains the agent in ways the operator has not
  evaluated. This ADR deliberately detects; a follow-up may enforce.
- **Run the full chain and the parallel pair concurrently, with Vishnu polling for the
  plan file.** Rejected as a race dressed as a dependency. A checkable precondition beats
  a sleep loop.
- **Sequential only, no parallel mode.** Rejected by the operator. The path sets genuinely
  are disjoint and the permitted mode should be available.
- **A queue and worker pool over the roles.** Rejected. Three roles, one operator, one
  laptop. It is the general runner ADR 0001 excludes.

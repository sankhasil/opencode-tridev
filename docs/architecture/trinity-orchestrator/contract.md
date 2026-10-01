---
type: concept
title: Trinity Orchestrator Contract
status: accepted
---

# Trinity Orchestrator Contract

Implementation detail for [plan.md](plan.md). Read the plan first — this file assumes
the goals and non-goals there.

## 1. Invocation

```
scripts/trinity.sh <task>            # sequential chain: brahma -> vishnu -> maheshwara
scripts/trinity.sh --parallel <task> # brahma || vishnu, requires a plan on disk
```

`--parallel` is a flag, not a subcommand, because it modifies the chain rather than
selecting a different pipeline. Anything else is an argument error, printed with usage,
exit 2.

Both modes exit 0 only when every role they ran succeeded **and** the path check found no
breach. Every non-zero exit is distinguishable by code:

| Code | Meaning |
| --- | --- |
| 0 | All roles succeeded, no breach |
| 1 | A role failed, or a breach was detected |
| 2 | Usage error |
| 3 | Precondition unmet (`--parallel` with no plan on disk) |

Code 3 exists so "you asked for something impossible" never looks like "a role crashed".

## 2. The two modes

### Chain

```
brahma  ->  vishnu  ->  maheshwara
```

Strictly sequential. Each role starts only after the previous one has **succeeded** — which
means it ended on `reason: "stop"` *and* reported `TRINITY-DONE` (section 4). A failed,
refused, or silent role stops the chain immediately; later roles do not run, because a
build without a plan and a verify without a build are both meaningless.

### Parallel

```
plan on disk?  --no--> exit 3, start nothing
      |
     yes
      |
brahma  ||  vishnu
      |
  both succeeded?
      |
    breach?
```

Two processes, neither waiting for the other. There is no join barrier that waits for
one to finish before starting the other, and no polling for a plan file — the plan is
checked **once, before either process starts**.

Both roles must succeed by the section 4 rule. If either fails or refuses, the mode
exits 1.

## 3. Roles

Three roles, addressed by skill prompt. No new `.opencode/agent/*.md` files are created
(plan D3).

| Role | Permitted paths | Skill |
| --- | --- | --- |
| brahma | `docs/**` | `brahma` |
| vishnu | everything except `docs/**` | `vishnu` |
| maheshwara | everything | `maheshwara` |

Permitted paths restate the invariant in [ADR 0003](../../adr/0003-parallel-agents-via-disjoint-path-sets.md)
and exist so the path check has something to compare against. They are also stated in
each role's prompt, because a role that does not know its boundary cannot stay inside it.

### Invocation — verified 2026-09-30

**Omit the `--agent` flag entirely.** Do not pass `--agent general`, and do not pass a role
name.

Both were tried and both **silently fall back to the default `build` agent with exit 0**:

| Invocation | Observed |
| --- | --- |
| `opencode run --agent brahma "..."` | `! agent "brahma" not found. Falling back to default agent` — then ran, exit 0 |
| `opencode run --agent general "..."` | `! agent "general" is a subagent, not a primary agent. Falling back to default agent` — then ran, exit 0 |

The fallback is harmless here, because the role comes from the prompt rather than the
flag, and the run still does the right thing. It is recorded because it is the third
silent-fallback bug this repository has produced (see `port_up` in ADR 0006's journal
entry, and the `/models` catalog overwrite). **Never rely on a bad `--agent` name failing
loudly. It will not.**

Correct invocation:

```bash
opencode run --format json "<task>

Load the <role> skill and follow it exactly.
You may write only under: <permitted paths>.
Do not write anywhere else.

When you have finished, end your reply with exactly one line and nothing after it:
TRINITY-DONE: <role>          if you completed the task
TRINITY-REFUSED: <reason>     if you declined it"
```

**Verified:** this prompt makes the agent call the `skill` tool with `name: "<role>"` and
receive the full skill content. The agent then adopts the role — asked to load brahma, it
replied `LOADED` and restated its architect-only restriction. The sentinel instruction is
honoured in both directions; see section 4.

Model selection is not specified here. `opencode.json` is the source of truth
([ADR 0002](../../adr/0002-declare-model-tiers-never-auto-route.md)) and the orchestrator
must not override it.

### Permissions — verified 2026-09-30

In-tree writes work headlessly with no extra flags: a probe run wrote
`.trinity-probe/probe.txt` successfully (`write` tool, `status: completed`).

Writes **outside** the working tree are refused: the `build` agent carries
`external_directory` as `ask`, and in headless mode a permission request is
auto-rejected — `The user rejected permission to use this specific tool call.`

This is a free safety property, but a narrow one. It confines every role to the working
tree; it does **not** separate `docs/**` from code, because both are in-tree. The
disjointness check in section 6 is still the only thing covering the split that matters.

No `--auto` flag. It would remove a boundary that is currently holding.

## 4. Completion signal — verified 2026-09-30

**The exit code is not a signal. It is always 0.**

Measured on this machine, both with `--format json`:

| Run | Last event | Exit code |
| --- | --- | --- |
| Success — role loaded its skill and replied | `step_finish`, `reason: "stop"` | **0** |
| Failure — `read` on a missing path, permission auto-rejected | `step_finish`, `reason: "tool-calls"` | **0** |

A failing agent and a succeeding agent are indistinguishable by exit status. The chain's
stop condition must therefore come from the event stream.

### The rule

A role **completed** if and only if the last `step_finish` event in its `--format json`
stream carries `reason: "stop"`.

A run that ends on any other reason never completed a turn: the agent was still issuing
tool calls when it stopped, which is what a hard failure looks like. Treat every
non-`stop` ending as failed, and stop the chain.

### What "completed" does not mean — verified 2026-09-30

`reason: "stop"` detects a **crash**. It does not detect **completion of the task.** The
two are the same event, and they were measured to be indistinguishable:

| Run | Last event | Role's actual behaviour |
| --- | --- | --- |
| Brahma asked to plan something | `stop` | Did the work |
| Brahma asked to write `src/main/kotlin/Util.kt` | `stop` | **Refused** — cited the skill's "never write application code" rule and asked which of two options to take |
| `build` asked for a Kotlin file in a repo with no Kotlin | `stop` | **Refused** — no `*.kt`, no `build.gradle`, asked where to put it |

So the rule reads a healthy refusal as success. That is the *safer* of the two errors — a
refused role has not damaged the tree, and the operator reads the log and sees why — but
it means the chain cannot tell "did the work" from "declined to".

### The gap, and how it is closed

**The gap:** if a role completes its turn having produced nothing useful, the chain
proceeds to the next role anyway. The realistic case: Brahma returns a one-line note
instead of a plan, Vishnu starts building on nothing, and in a tree with no git that is how
work gets lost.

**Closed by a role-reported sentinel.** Each role is told to end its reply with exactly one
line:

```
TRINITY-DONE: <role>          the task was completed
TRINITY-REFUSED: <reason>     the role declined the task
```

The chain reads the final `text` event of the stream and classifies the role:

| Sentinel | Meaning | Chain action |
| --- | --- | --- |
| `TRINITY-DONE: <role>` | Did the work | Continue to the next role |
| `TRINITY-REFUSED: <reason>` | Declined deliberately | **Stop.** A deliberate refusal means the task is wrong for this role; the next role would build on nothing |
| Neither | Did not report | **Stop.** Fail closed — the ambiguous case is the one that must not pass |
| `reason != "stop"` | Crashed mid-turn | **Stop**, before the sentinel is even considered |

The crash check runs **first**. A stream that never completed a turn has no trustworthy
final text, so the sentinel is not consulted.

### Sentinel compliance — verified 2026-09-30

The obvious failure mode of a model-reported sentinel is false compliance: the model
prints `DONE` without having done the work. Tested both directions:

| Case | Prompt | Result |
| --- | --- | --- |
| Refusal | load brahma, then write `src/main/kotlin/Util.kt` | `TRINITY-REFUSED: Brahma may not write application code; Util.kt belongs to Vishnu` |
| Completion | load brahma, then write `.trinity-probe/plan.md` | `TRINITY-DONE: brahma`, and the file was written with correct content |

The model distinguished the two cases and chose `REFUSED` on its own, without being told
which was expected. It also volunteered a caveat that the probe path was not brahma's
canonical location — i.e. it read the instruction, not just the template.

**This is one sample each.** It shows the mechanism works, not that it is reliable. A
sentinel is a model's self-report, and a model can report a success that did not happen.
Revisit trigger 5 in ADR 0007 covers the case where it does: delete the sentinel rather
than trust it.

### Two more failure shapes

- **No JSON at all.** A provider or model error can fail before any event is emitted. An
  empty stream is a failure, not a successful run with nothing to say.
- **A `tool_use` event with `state.status == "error"`.** This is a *reliable* signal but a
  **wrong** stop condition: an agent that hits one bad read and then recovers would be
  treated as failed. Do not gate the chain on it. Log it; do not stop on it.

### Reading the stream

`--format json` emits one JSON object per line on stdout, with a `type` and a `part`. The
fields this depend on:

```
{"type":"step_finish", "part":{"reason":"stop"}}
{"type":"tool_use",    "part":{"state":{"status":"error","error":"..."}}}
```

Parse per line and ignore lines that do not parse. Do not accumulate the stream and
re-parse at the end; a run that dies mid-write would then lose its last event, which is
precisely the event carrying the verdict.

## 5. State directory

`.trinity/` at the repository root. Plain text, readable with `cat`. No database, no
JSON schema, no lockfile protocol.

```
.trinity/
  latest              # one line: mode, status, timestamp
  <run-id>/
    brahma.log
    vishnu.log
    maheshwara.log
    paths.txt         # the path check result, one line per breach
```

`run-id` is a UTC timestamp. The directory is not cleaned automatically — a run the
operator wants to inspect should survive, and there is no cost to keeping it. Add
`.trinity/` to `.gitignore` if git is ever initialised.

**Nothing else.** No PID file, no lock file, no queue, no resume token. If a state
directory is needed to resume a run, that is a new component and a new ADR.

## 6. The path check

Runs once per role, after that role exits, and again at the end of the run in parallel
mode. It is the mechanism for US3.

### How

1. Before a role starts, record the modification time of every tracked file, excluding
   `.git`, `node_modules`, `.venv`, `.devbox`, `.trinity`, and `open-code/node_modules`.
2. After the role exits, record them again.
3. A file is *touched* if it is new, or if its mtime is newer than the run start.
4. For each touched file, check membership in that role's permitted set.
5. Any non-member is a breach.

`find -newer` is sufficient for step 3 and avoids a second dependency: touch a reference
file at run start, then `find <tree> -newer <reference>`. Simpler than diffing two
snapshots and it cannot miss a file created *and* deleted mid-run, which a snapshot diff
would silently drop.

### Reporting

```
✗ BREACH  vishnu wrote outside its permitted paths
    docs/architecture/trinity-orchestrator/plan.md
    docs/index.md
```

A breach sets exit 1. Silence is the requirement when there is no breach — the check
prints nothing on the happy path.

### Limitation, stated

This detects writes. It does not attribute them. If the operator edits a file in another
terminal during the run, that file is reported as a breach. mtime is the only signal
available without a VCS, and the alternative — no check — is the silent failure ADR 0003
warns about. Accepted, not solved.

## 7. Process handling

- Child stdout/stderr go to the per-role log file under `.trinity/<run-id>/`.
- On exit, no child process remains. No `nohup`, no background survivors, nothing left
  listening. US4 is a test, not an aspiration.
- The script does not trap-and-hide. If a child is killed, the event stream ends without
  a `reason: "stop"` and section 4 classifies the role as failed.
- A breach in parallel mode does **not** attempt cleanup. There is no undo to attempt
  (ADR 0003); the script reports and stops.

## 8. Composition with the launcher

`scripts/trinity.sh` sits beside `scripts/opencode.sh` and does not replace it. It runs
*after* configuration exists, because `opencode run` reads `opencode.json`.

`trinity.sh` does not regenerate `opencode.json`. If the operator wants a fresh config,
they run the launcher first. This keeps one script owning config generation.

## 9. What was verified, and what Vishnu must still verify

### Verified on this machine, 2026-09-30

| # | Assumption | Result |
| --- | --- | --- |
| 1 | `opencode run` exits non-zero on agent failure | **FALSE.** Exit is 0 on success and on hard failure alike. Replaced by the event-stream rule in section 4. |
| 2 | `opencode run --agent general` loads skills | **FALSE as written.** `general` is a subagent, so the flag is ignored with a fallback to `build`. The prompt-based skill load *does* work when the flag is omitted entirely. |
| 3 | The three trinity roles are not declared OpenCode agents | **TRUE.** `opencode agent list` returns `build`, `compaction`, `explore`, `general` only. |
| 4 | A headless role can load its skill | **TRUE.** The `skill` tool returned full brahma content and the agent adopted the role. |
| 5 | A headless role can write in-tree | **TRUE.** `write` to `.trinity-probe/probe.txt` completed. Probe deleted. |
| 6 | A headless role is confined to the working tree | **TRUE.** An out-of-tree read was auto-rejected by the `external_directory` permission. |

The two assumptions the plan called load-bearing were **both false**, and both failures
were silent. That is why every design decision in this contract was re-derived from
measurement, and why the last one — the completion sentinel — was tested in both
directions before being adopted rather than specified and hoped for.

### Still to verify

| # | Check | How |
| --- | --- | --- |
| 3 | The `reason: "stop"` rule holds for a role that legitimately *refuses* | **TESTED 2026-09-30 — it does not, and that is fine.** A refusal ends on `stop`, same as success. The rule is a crash detector, not a task-completion detector. See section 4. |
| 2 | A provider failure produces an empty stream, not a partial one | Stop Ollama and the proxy, then run a role against the local model. Assert the empty-stream branch fires. |
| 3 | Usage errors exit 2 | `bash scripts/trinity.sh`, unknown flag, empty task. |
| 4 | `--parallel` with no plan exits 3 and starts nothing | Remove the plan, run, assert exit 3 and no child process. |
| 5 | `--parallel` with a plan starts both concurrently | Assert two overlapping children, not sequential. |
| 6 | Breach is detected and names the file | Have a role write a known file outside its permitted set. Assert the file is named and exit is 1. |
| 7 | No breach prints nothing about paths | Run a well-behaved role; assert `BREACH` is absent. |
| 8 | No survivors | After any run, assert no `opencode run` child remains. |
| 9 | `bash -n scripts/trinity.sh` | Syntax. |
| 10 | ShellCheck clean | `shellcheck scripts/trinity.sh`, per the AGENTS.md bash rules. |

Check 2 is the only remaining unknown about the stop condition — whether a provider
failure emits a partial stream that looks complete. If it does, the rule needs a second
guard, which is a new mechanism: report back rather than inventing it.

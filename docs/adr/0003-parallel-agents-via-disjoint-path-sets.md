---
type: decision
title: Parallel Agents via Disjoint Path Sets, No Git, No Worktree
status: accepted
date: 2026-09-25
---

# Parallel Agents via Disjoint Path Sets, No Git, No Worktree

## Context

The Agent Trinity has three agents: Brahma (architect, docs only), Vishnu (builder,
code), Maheshwara (finisher, verification, tests, cleanup, local deploy).

Three mechanisms for running agents side by side were available: separate processes in
the same tree, git worktrees, and an external orchestrator.

The Agent Trinity itself is not a product surface; it is a convention documented in
`AGENTS.md`, which [ADR 0001](0001-local-first-launcher-not-a-methodology-runtime.md)
scopes to this single operator. The mechanisms below are therefore judged by how little
they cost that one operator, not by how well they scale.

The operator declined the latter two, including `git init` itself. The project is
intentionally not a git repository. That is unusual enough to require a record, because
it is the most fragile decision taken so far.

## Decision

Agents do not run in parallel by default. Two exceptions are permitted, and one
condition is mandatory.

| Pair | Permitted | Condition |
| --- | --- | --- |
| Brahma ‖ Vishnu | Yes | Their path sets are disjoint |
| Brahma ‖ Maheshwara | No | Maheshwara needs exclusive tree access |
| Vishnu ‖ Maheshwara | No | Maheshwara needs exclusive tree access |

The path invariant:

- Brahma may touch `docs/**`.
- Vishnu may touch code and must not touch `docs/**`.
- Neither may run while Maheshwara runs.

Maheshwara always runs alone, because it needs the whole tree, the test suite, and
cleanup to be uncontended.

**If disjointness ever fails, parallel mode must fail closed.** Serial execution is the
fallback, not an error.

### Accepted risk

With no git and no worktree there is no undo mechanism. No `git checkout`, no reflog,
no stash, no branch to compare against. A stray agent edit in the main working tree is
unrecoverable, and a deleted file is gone.

The operator was told this explicitly and accepted it.

The mitigation considered was `git init`. It was declined. The structural argument for
declining it is that an uncommitted `git init` adds history only if something commits;
without branches, worktrees, or a commit discipline it would not have made parallel
execution safe, only given the appearance of safety. The operator's own stated reason
for declining is not recorded and should be added here if it differs.

Note that the safety here is social, not enforced. Nothing in the codebase verifies
that Vishnu stayed out of `docs/**`. The failure mode is silent, which is why the
fail-closed rule matters more than the permission.

### Revisit triggers

Any one of these reopens the decision:

1. Work is lost to an agent edit. This is the trigger that matters; a single occurrence
   is sufficient.
2. Two concurrent agents turn out to need the same file.
3. The operator wants to share the project with anyone.
4. Any ADR supersedes the disjointness invariant.

## Consequences

### Positive

- No worktree machinery, no merge step, no branch cleanup. Three fewer things to
  maintain and explain.
- Parallelism is opt-in per pair, not a global mode. There is no persistent
  orchestration state to hold in mind.
- Maheshwara stays trustworthy: it never runs against a tree being mutated.
- Smaller cognitive footprint, which matters more for a single operator than for a team.

### Negative

- No undo. Stated above; it is the real cost of this decision.
- The disjointness invariant is unenforced. A breach is detected by the operator
  noticing, not by a check.
- Maheshwara running alone serializes the verification step, which is the step that
  catches everything else.
- No commit history means no way to answer "when did this change" or to bisect a
  regression.

## Alternatives considered

- **Git worktree per agent.** Rejected. `mattpocock/sandcastle` is the reference
  implementation for this pattern. It was also rejected on merit: it requires git, so
  adopting worktrees re-opens the same declined decision about version control.
- **Full sandcastle integration.** Rejected; see
  [ADR 0005](0005-no-external-agent-orchestration-dependency.md).
- **Serialize everything.** Rejected: the operator wants Brahma ‖ Vishnu, and the
  path sets genuinely are disjoint.

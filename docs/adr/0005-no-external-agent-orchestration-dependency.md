---
type: decision
title: No External Agent-Orchestration Dependency
status: accepted
date: 2026-09-25
---

# No External Agent-Orchestration Dependency

## Context

Two projects were evaluated against this launcher. Both were declined.

| Project | License | Language | Version | Scale | Shape |
| --- | --- | --- | --- | --- | --- |
| `mattpocock/sandcastle` | MIT | TypeScript | v0.12.0 | 8.1k stars, 1,193 commits (1,025 by one author) | Orchestrates coding agents in git-worktree + container sandboxes |
| `google/ax` | Apache-2.0 | Go | v0.3.1 | 11.2k stars, ~650 commits | Declarative orchestrator for billions of agent workloads per cluster |

`sandcastle` conflicts with this launcher's integration surface on four counts, and is
dormant on a fifth:

- Trackers are GitHub Issues and Beads only. No Jira, no Linear; the string `jira` does
  not appear in its source. This launcher is Jira-first.
- MCP is explicitly rejected by the project: "An MCP server is not a substitute for a
  CLI here." This launcher's Jira integration *is* MCP (`uvx mcp-atlassian`, wired at
  `opencode.json:30-42`).
- It declined to bundle opinionated workflow templates, turning down a "superpowers"
  pack. The Agent Trinity is exactly that.
- `main` has had no commits since 2026-06-29, with 61 open PRs. Effectively dormant,
  pre-1.0, single maintainer.

`ax` is built for a different workload. It amortizes idle compute across thousands of
concurrent tasks. The operator runs one agent interactively on a laptop. Adopting it
would mean Kubernetes, Redis Streams, Agent Substrate (a non-Google-org project pinned
to untagged pseudo-versions), and `GEMINI_API_KEY` — to save the cost of a VPS. It has
no ADRs, no issue-tracker integration, and no journaling, which are the three things
this project's OKF protocol is built on. Model support is Gemini-only in code
(`internal/model/client.go`) despite documentation claiming Anthropic. It requires Agent
Substrate; there is no "ax family" project, and the axolotl is only a mascot
(`google/axolotl` returns 404).

## Decision

Adopt no external agent-orchestration dependency. The launcher stays
`scripts/opencode.sh` plus config.

Borrow two patterns from `sandcastle` and record them as future work, not as
dependencies:

1. **`.out-of-scope/`** — a directory of written non-goals, each linked to the rejected
   feature request. This is the operational form of the Ponytail rules.
2. **`CONTEXT.md`** — a ubiquitous-language file listing terms and explicitly-avoided
   synonyms.

Worth noting: `sandcastle` ships an `opencode()` agent provider, so there is a
compatibility path if either decision is ever revisited.

## Consequences

### Positive

- Zero new dependencies, runtimes, or services. The launcher keeps working when
  upstream moves.
- Jira-first and MCP-based integration stays intact, which is the actual reason both
  projects were declined.
- The OKF protocol — ADRs, journal, issue-tracker integration — stays coherent,
  because nothing else is writing into it.
- The borrowed patterns are ideas. Adopting them costs documentation, not a runtime.

### Negative

- This project reimplements what `sandcastle` already solves, and then carries the
  consequences recorded in [ADR 0003](0003-parallel-agents-via-disjoint-path-sets.md):
  no worktree isolation and no undo.
- `.out-of-scope/` is not implemented. Until it is, the Ponytail rules are aspirational
  prose and non-goals decay silently.
- `CONTEXT.md` overlaps with existing conventions — `docs/journal/decisions.md` and the
  ubiquitous-language approach used by the other skills. Borrowing it verbatim may
  duplicate documents that already exist.
- Single-maintainer dormancy cuts both ways: a future re-evaluation may find
  `sandcastle` unmaintained, or revived and no longer declined.

## Alternatives considered

- **Adopt `mattpocock/sandcastle`.** Rejected on the four conflicts above, plus
  dormancy. The reference implementation for the parallel-agent pattern it would have
  provided is recorded in
  [ADR 0003](0003-parallel-agents-via-disjoint-path-sets.md).
- **Adopt `google/ax`.** Rejected: wrong workload by three orders of magnitude, and a
  dependency chain (Kubernetes, Redis, Agent Substrate, `GEMINI_API_KEY`) heavier than
  the thing it would orchestrate.

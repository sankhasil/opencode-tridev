---
type: reference
title: Architecture Diagrams
---

# Architecture Diagrams

Diagrams are code. C4 model only. DSL is the source of truth.

- `.dsl` files live in this directory
- one workspace per file, multiple views per workspace
- render via the Structurizr CLI or Playground
- reference diagrams from docs by relative path, e.g. `![alt](diagrams/foo.png)`

## Files

| File | Workspace | Views |
| --- | --- | --- |
| [tridev.dsl](tridev.dsl) | `opencode-tridev` | `system-context`, `container-view`, `agent-protocol` |

### tridev.dsl

| View | Scope | Shows |
| --- | --- | --- |
| `system-context` | System of interest | Operator, the launcher, and the five systems it reaches, split local vs cloud by tag. |
| `container-view` | `opencode-tridev` | The devbox → `opencode.sh` → `opencode.json` → OpenCode CLI path, plus the Ollama proxy hop and the MCP server. |
| `agent-protocol` | Dynamic, `*` | The four-step protocol, with Brahma and Vishnu running in parallel over disjoint paths and Maheshwara running alone. |

Render with the Structurizr CLI:

```bash
structurizr export --workspace docs/diagrams/tridev.dsl --format png
```

The DSL was **validated** on 2026-09-28 with `structurizr.war` v2026.09.19 on Java 21:
`validate` exits 0 and all three views export to Mermaid. The CLI is kept out of
`devbox.json` deliberately — validation is occasional. PNG export still needs the
427 MB Playwright build. See [2026-09-28.md](../journal/2026-09-28.md).

### Pending update

If [ADR 0007](../adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) is
implemented, `agent-protocol` becomes wrong: it shows the operator driving all three
agents, where the orchestrator drives them. The DSL must not gain a `trinity.sh`
container before the script exists — this file already carries one modelled component
that was not real (see the Ollama proxy property below), and repeating that is how
diagrams start lying. Update the view in the same change that adds the script.

## Modelling decisions

- **Boundaries are `group`, not `boundary`.** The current Structurizr DSL has no
  `boundary` keyword; `group` is the construct that renders as a dashed boundary. The
  `Jira MCP boundary` group wraps the MCP server container, which is what makes the
  indirection to Jira visible without inventing a system element.
- **MCP is a relationship at context level, a group at container level.** In
  `system-context` there is a single `tridev -> Atlassian Jira` edge whose description
  spells out the indirection, because a system context view cannot contain containers.
  In `container-view` the real `uvx mcp-atlassian` process appears as a container inside
  the group, with the launcher's `config -> mcpServer -> Jira` chain showing who
  actually spawns it and who actually calls the API.
- **The working tree is not a separate element.** View 3 uses the `opencode-tridev`
  software system itself, because that *is* the working tree. The two accepted
  trade-offs (no git repository, no worktrees) are attached to it as element
  `properties` so they render as an annotation instead of as invented elements.
- **Tiers are declared, not routed.** `tier-1` (Ollama, local) and `tier-2`/`tier-3`
  (T-Systems, cloud) are tags only. No router element exists, because automated model
  routing was explicitly rejected.
- **The Ollama tool-call proxy is a declared dependency, not a verified component.**
  It carries a `status` property recording that `scripts/opencode.sh` starts it via
  `npm run ollama:serve` in `open-code/`, but no such script and no proxy source exist
  in the checked-in `open-code/package.json`. See the open question in the journal.

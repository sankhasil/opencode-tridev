---
type: howto
title: Developer Onboarding
---

# Developer Onboarding

Single entry point for setting up a machine to run this launcher. If a step here is wrong,
fix this document — not just the local machine.

## Prerequisites

| Tool | Version | Provided by | Required? |
| --- | --- | --- | --- |
| [devbox](https://www.jetify.com/devbox) | current | install separately | **Yes** — owns everything else |
| nodejs | 22 | `devbox.json` | Yes |
| python | 3.11 | `devbox.json` | Yes |
| uv | — | `devbox.json` | Yes — runs the Jira MCP server |
| git | — | `devbox.json` | Yes |
| curl | — | `devbox.json` | Yes |
| jq | 1.7 | `devbox.json` | **Yes** — `scripts/opencode.sh:25` and `:500` |
| ollama | any recent | brew / upstream | Optional — local tier only |

`jq` is required. Without it the launcher still runs, but `fetch_tsystems_models` bails and
the T-Systems model catalog is never refreshed, so **no tier or price labels appear**.

Ollama is optional. The default path uses `opencode/space-bunny-free` and starts no local
process — see [ADR 0002](adr/0002-declare-model-tiers-never-auto-route.md).

## Setup

```bash
# 1. Enter the reproducible environment
devbox shell

# 2. Create .env from the template and fill it in — never commit .env
cp .env.template .env

# 3. Refresh the lockfile if devbox.json changed
devbox lock
```

## Environment variables

Names only. Values live in `.env` or a secret manager, never in this repository.

| Variable | Purpose | Needed for |
| --- | --- | --- |
| `TSYSTEMS_OPENCODE_API_KEY` | T-Systems LLM Hub | Paid tiers 1–5. Not needed for tier 0 |
| `JIRA_URL` | Jira base URL | Jira MCP |
| `JIRA_USER_EMAIL` | Jira login | Jira MCP |
| `JIRA_API_TOKEN` | Jira personal access token | Jira MCP |
| `JIRA_PROJECT` | Project filter | Jira MCP scoping |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub | Optional, only if a target folder's `opencode.json` references the GitHub MCP |

### Model selection

`opencode.json` is **generated** by `scripts/opencode.sh`, but the generator now reads
`model` / `small_model` back out of it, so a hand-edited choice survives the next launch.

Precedence, highest first:

1. `DEFAULT_MODEL` / `DEFAULT_SMALL_MODEL` in `.env`
2. `model` / `small_model` already in `opencode.json`
3. Built-in default: `opencode/space-bunny-free` for both

Uncomment the vars in `.env.template` to override. For example, to work against the T-Systems
hub instead of the free tier:

```
DEFAULT_MODEL=tsystems/Qwen3.6-35B-A3B-FP8
```

Note that `DEFAULT_MODEL` takes a bare `provider/model` id — the `ollama/` prefix is added
by the launcher only for its own built-in default.

Verify Jira before first use:

```bash
curl -s "$JIRA_URL/rest/api/2/myself" -u "email:token"
```

## Run

```bash
devbox run opencode              # default: free cloud model, starts nothing local
devbox run opencode-ollama       # also auto-start Ollama + the tool-call proxy
devbox run opencode /path/to/project
```

`devbox run opencode --help` is not a thing; see `scripts/opencode.sh:245-250` for flags.

## Optional: the local tier

Only needed if you want to select the local model manually.

```bash
ollama pull hhao/qwen2.5-coder-tools:7b     # note the hhao/ namespace
devbox run opencode-ollama
```

The namespace matters. `qwen2.5-coder-tools:7b` without it returns
`model not found` from Ollama.

The tool-call proxy lives in `open-code/tools/` and listens on `:4198`, forwarding to
Ollama's native endpoint on `:11434/v1`. It exists only to rewrite bare-JSON tool calls
into real `tool_calls`; it is a pass-through when a request carries no tools. Provenance and
the one intentional deviation from upstream are in
[ADR 0006](adr/0006-vendor-ollama-tool-call-proxy.md).

Logs: `.ollama-serve.log` in the repository root.

## Agent skills

Skill bundles are pinned by `skills-lock.json` and regenerated with:

```bash
bash scripts/setup-opencode-skills.sh
```

`.agents/` is gitignored because it is a build artifact of that lockfile.

## Where to look next

| Question | Read |
| --- | --- |
| What is this thing, and what is it not? | [ADR 0001](adr/0001-local-first-launcher-not-a-methodology-runtime.md) |
| How are models chosen? | [ADR 0002](adr/0002-declare-model-tiers-never-auto-route.md) |
| When may agents run in parallel? | [ADR 0003](adr/0003-parallel-agents-via-disjoint-path-sets.md) |
| Full decision list | [adr/index.md](adr/index.md) |
| Architecture | [`diagrams/tridev.dsl`](diagrams/tridev.dsl) — 3 C4 views |
| What was decided recently, and why | [journal/decisions.md](journal/decisions.md) |

`docs/architecture.md` does not exist. The Structurizr workspace is the source of truth for
architecture; export it to PNG with the Structurizr CLI if you need images.

## Conventions worth knowing before you edit

- **Bash**: `set -euo pipefail`, quoted expansions, ShellCheck-clean. This is a bash + JSON
  project; do not introduce another language without an ADR.
- **The pricing table** in `scripts/opencode.sh:53-72` is hand-maintained. Unknown models
  render as `UNPRICED - <name>`. Do not invent EUR figures — a wrong price is worse than a
  missing one.
- **No git repository and no worktrees** in this project. See
  [ADR 0003](adr/0003-parallel-agents-via-disjoint-path-sets.md) before changing anything
  about agent concurrency.
- **There is no root `package.json`.** `devbox run` is the only entry point. Older notes
  mentioning `npm run start` are wrong.

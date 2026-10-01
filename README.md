---
type: concept
title: OpenCode (tridev) - Project Overview
---

# 🚀 OpenCode (tridev)

> The minimal, ADHD-friendly way to run AI coding assistants with full Jira integration.

A local-first wrapper around the [OpenCode CLI](https://opencode.ai): one reproducible
[devbox](https://jetify.com/devbox) environment, one launcher script, model tiers declared
up front instead of auto-routed, and vendored skills committed alongside the code that uses
them. Everything runs on your machine. No CI, no service, no dashboard.

**Plus a three-agent workflow** — 🧙‍♂️ Brahma plans, 🌌 Vishnu builds, 🔱 Maheshwara verifies,
each barred from editing the previous one's files. See [The Agent Trinity](#the-agent-trinity).

---

## Requirements

| Tool | Version | Notes |
|------|---------|-------|
| [devbox](https://jetify.com/docs/installing/devbox) | latest | Provides everything else; nothing else to install by hand |
| Ollama | optional | Only for `--ollama` mode (local model + tool calling) |

The environment pins `nodejs@22`, `python@3.11`, `uv`, `git`, `curl`, `jq@1.7` — see
[devbox.json](devbox.json). `devbox.lock` is committed, so the package set is reproducible.

---

## Setup

```bash
git clone https://github.com/sankhasil/opencode-tridev.git
cd opencode-tridev

devbox shell          # enter the pinned environment
cp .env.template .env # then fill in the values you need
```

`.env` is gitignored and never committed. Every variable is optional — leave one blank and
that integration is simply skipped. See [.env.template](.env.template) for the full list.

There is no `opencode.json` in a fresh clone. The launcher generates it on first run from
[scripts/opencode.sh](scripts/opencode.sh); it is gitignored because it embeds absolute skill
paths that are specific to your machine.

---

## Usage

```bash
devbox run opencode                             # default: free cloud model, no Ollama
devbox run opencode-ollama                      # same, plus Ollama + the tool-call proxy
devbox run opencode /path/to/project            # launch against another folder
```

Inside the `devbox shell` session these are also available as plain functions — `opencode`
and `opencode-ollama`.

There is no root `package.json`. `devbox run` is the only supported entry point.

---

## 🕉️ The Agent Trinity

This is the part that isn't a wrapper. Instead of one agent doing everything, three roles
share the work — and each one is **barred from touching the next one's files**:

| Role | Does | May write |
|------|------|-----------|
| 🧙‍♂️ **Brahma** — Architect | Spec, plan, ADRs, diagrams. Never writes code. | `docs/` only |
| 🌌 **Vishnu** — Builder | Code and tests, strictly to Brahma's plan. | Everything *except* `docs/` |
| 🔱 **Maheshwara** — Finisher | Verifies against the plan, fixes, cleans up, reports. | The whole tree |

Two properties fall out of that, and they are the point:

- **A plan exists before code does.** Vishnu's first move is to look for
  `docs/architecture/<feature>/plan.md`. No plan, no build.
- **One role cannot quietly widen its own scope.** Brahma physically cannot edit your
  source, and Vishnu cannot rewrite the blueprint he was handed.

[scripts/trinity.sh](scripts/trinity.sh) runs all three headlessly, in order:

```bash
bash scripts/trinity.sh "add retry to the Jira client"
```

```mermaid
flowchart TD
    subgraph SEQ["✅ trinity.sh &lt;task&gt; — sequential, the default"]
    direction TB
    B["🧙‍♂️ <b>Brahma</b> — Architect<br/>spec · plan · ADRs · diagrams<br/><b>writes docs/ only</b>"] -->|"blueprint ready"| V["🌌 <b>Vishnu</b> — Builder<br/>code + tests, to that plan<br/><b>writes code, never docs/</b>"] -->|"implementation complete"| M["🔱 <b>Maheshwara</b> — Finisher<br/>verify · fix · clean up · report<br/><b>whole tree</b>"]
    end

    subgraph PAR["⚡ trinity.sh --parallel — guarded"]
    direction TB
    G{"plan.md<br/>already on disk?"} -->|no| X3["⛔ exit 3<br/><i>refuses, starts nothing</i>"]
    G -->|yes| PB["🧙‍♂️ <b>Brahma</b><br/><b>docs/ only</b>"]
    G -->|yes| PV["🌌 <b>Vishnu</b><br/><b>code</b>"]
    end

    M --> OK(["✅ exit 0 — every role completed"])
    PAR --> OK

    classDef b fill:#ede7f6,stroke:#5e35b1,color:#311b92
    classDef v fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
    classDef m fill:#fce4ec,stroke:#ad1457,color:#880e4f
    classDef ok fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    classDef warn fill:#fff8e1,stroke:#f9a825,color:#e65100
    classDef gate fill:#eceff1,stroke:#546e7a,color:#263238

    class B,PB b
    class V,PV v
    class M m
    class OK ok
    class X3 warn
    class G gate
```

**Sequential is the default.** `--parallel` runs Brahma ‖ Vishnu only, and only because
their path sets are genuinely disjoint — Maheshwara is never in a concurrent pair, because
he needs the uncontended tree. The parallel mode **refuses with exit 3** unless a plan
already exists, because Vishnu needs something to build from:

```bash
bash scripts/trinity.sh "add retry to the Jira client"   # creates the plan
bash scripts/trinity.sh --parallel "now implement it"     # plan is on disk → runs
```

**A failure anywhere stops the chain.** A role that crashes or refuses its task ends the run
with exit 1. In the sequential chain, a role that also writes outside its permitted paths
has the offending files named and listed — checked *after the fact*, by comparing
modification times. It reports a breach; it cannot undo one.

**That check does not run in `--parallel` mode.** With two roles sharing one tree an mtime
sweep cannot tell whose write is whose, and since Brahma's permitted set (`docs/`) and
Vishnu's (everything else) together cover the whole tree, every file is permitted for
*someone*. The check is skipped rather than run wrong. So: **breach detection is a
sequential-mode guarantee only.**

> ⚠️ One honest caveat, recorded in
> [ADR 0003](docs/adr/0003-parallel-agents-via-disjoint-path-sets.md): the path invariant is
> **social, not enforced**. Nothing *stops* Vishnu from opening `docs/` in either mode — in
> sequential mode a breach is detected afterwards and reported; in parallel mode it is not
> detected at all. And because roles report their own outcome via a sentinel line, that
> report is a model's self-assessment, not a proof.
> [ADR 0007](docs/adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) records both
> limitations and the measurements behind them.

There is also **no git and no worktree isolation**, so a stray edit in the working tree is
unrecoverable. That trade is deliberate and documented, not an oversight.

---

## What's in the box

| Path | Purpose |
|------|---------|
| [AGENTS.md](AGENTS.md) | The instruction manual every agent session reads first |
| [scripts/opencode.sh](scripts/opencode.sh) | Launcher: reads `.env`, generates config, starts Ollama if asked, execs the CLI |
| [scripts/trinity.sh](scripts/trinity.sh) | Runs the Agent Trinity headlessly — see [above](#the-agent-trinity) |
| [open-code/tools/](open-code/tools) | Vendored Ollama tool-call proxy ([ADR 0006](docs/adr/0006-vendor-ollama-tool-call-proxy.md)) |
| [docs/adr/](docs/adr) | Seven accepted decisions, and why |
| [docs/architecture/](docs/architecture) | Trinity orchestrator design and run contract |
| [docs/diagrams/tridev.dsl](docs/diagrams/tridev.dsl) | C4 model as code |
| [opencode.json.template](opencode.json.template) | Tracked reference for the config shape (the live `opencode.json` is gitignored) |
| [.opencode/skills/](.opencode/skills) | 46 skill packages, loaded via the relative `skills.paths` entry |

`node_modules/`, `.devbox/`, `.venv/`, `.agents/` and runtime logs are gitignored and
regenerated on demand. Tracked repo size is under 1 MB.

---

## What this is not

- Not a full OpenCode.ai installation script — it wraps the CLI, it does not replace it
- Not a CI/CD pipeline
- Not production deployment ready

It is a personal development-environment wrapper.

---

# Detailed documentation

## 🏗️ Architecture Diagram

```mermaid
flowchart TD
    DEVBOX["🐚 devbox<br/>devbox.json"] --> LAUNCH

    subgraph LAUNCH["🚀 Launch sequence — scripts/opencode.sh"]
        direction TB
        L1["📖 Load .env"] --> L2["⚙️ Generate opencode.json"] --> L3["📂 Merge AGENTS.md into target"] --> L4{"--ollama?"}
        L4 -->|yes| L5["🧪 Start Ollama proxy"] --> L6["🚀 exec opencode-ai"]
        L4 -->|no| L6
    end

    subgraph CONFIG["⚙️ Configuration"]
        direction TB
        LIVE["opencode.json<br/><i>live · gitignored</i>"]
        TPL["opencode.json.template<br/><i>tracked reference</i>"]
        ENV[".env<br/><i>secrets · gitignored</i>"]
    end

    subgraph AGENT["🧠 Agent session"]
        direction TB
        A1["📜 Read AGENTS.md<br/>rules &amp; behaviour"]
        A2["🎯 Load skills<br/>.opencode/skills/"]
        A3["🔌 Connect to model"]
        A4["⚡ Interact<br/>code · Jira · files"]
        A1 --> A2 --> A3 --> A4
    end

    subgraph SKILLS["🎯 Skills"]
        direction TB
        S1["46 skills in-tree<br/>.opencode/skills/"]
        S2["superpowers<br/><i>via plugin</i>"]
    end

    subgraph MODELS["🔌 Model providers"]
        direction TB
        M1["🧠 Ollama<br/>localhost:4198"]
        M2["🔮 T-Systems Hub<br/>GLM · Claude · GPT"]
    end

    subgraph TOOLS["🧰 Tools &amp; integrations"]
        direction TB
        T1["🔍 Jira MCP<br/>mcp-atlassian"]
        T2["📦 open-code/node_modules<br/>OpenCode CLI"]
    end

    L2 -->|writes| LIVE
    LIVE -.->|shape of| TPL
    L1 -->|reads| ENV
    L6 --> T2
    T2 --> AGENT
    AGENT --> SKILLS
    AGENT --> MODELS
    AGENT --> TOOLS

    classDef cfg fill:#e8eaf6,stroke:#3949ab,color:#1a237e
    classDef skill fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    classDef model fill:#fff3e0,stroke:#ef6c00,color:#e65100
    classDef tool fill:#fce4ec,stroke:#c2185b,color:#880e4f
    classDef secret fill:#ffebee,stroke:#b71c1c,color:#b71c1c,stroke-dasharray: 4 3

    class LIVE,TPL,L1,L2 cfg
    class S1,S2,A2 skill
    class M1,M2,A3 model
    class T1,T2 tool
    class ENV secret
```

### 🔐 Authentication

| Variable | Purpose |
|----------|---------|
| `TSYSTEMS_OPENCODE_API_KEY` | Cloud AI (T-Systems Hub) |
| `JIRA_URL` | Jira server address |
| `JIRA_USER_EMAIL` | Jira login email |
| `JIRA_API_TOKEN` | Jira personal access token |
| `JIRA_PROJECT` | Filter projects (optional) |

⚠️ All secrets live in `.env` — **never** committed. See [.env.template](.env.template)
for the full list of variable *names*.

---

## 🔧 Configuration File

Located at **`opencode.json`** (regenerated from `opencode.sh` on every launch, gitignored).
The abridged shape below lives in [`opencode.json.template`](opencode.json.template); the
launcher additionally injects `provider.tsystems.models` and `mcp` from its embedded catalog:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/space-bunny-free",
  "small_model": "opencode/space-bunny-free",
  "share": "disabled",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "TIER 0 FREE - Local Ollama",
      "options": {
        "baseURL": "http://localhost:4198/v1",
        "apiKey": "ollama"
      }
    },
    "tsystems": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "T-Systems LLM Hub",
      "options": {
        "baseURL": "https://llm-server.llmhub.t-systems.net/v2",
        "apiKey": "{env:TSYSTEMS_OPENCODE_API_KEY}"
      }
    }
  }
}
```

The `opencode` provider is built in and needs no key, so it does not appear above. Both
defaults point at it, so the default path starts **no local processes** — no Ollama, no
tool-call proxy, no `--ollama` flag. Local Ollama stays in the picker for when you want
offline work or local tool-calling.

> ⚠️ The default path is therefore **not offline-capable**. `small_model` only ever runs
> title generation and summaries, which is why it costs nothing to put it on the same free
> tier — but it does mean a dropped network degrades conversation titles.

---

## 🧩 Devbox Integration

```jsonc
// devbox.json (environment setup)
{
  "packages": ["nodejs@22", "python@3.11", "uv", "git"],
  "shell": {
    "scripts": {
      "opencode": "bash scripts/opencode.sh $@",
      "opencode-ollama": "bash scripts/opencode.sh --ollama $@"
    }
  }
}
```

---

## 🗂️ Documentation (OKF)

Project follows [Open Knowledge Format](https://okf.md) for structured documentation:

| Bundle | Path | Purpose |
|--------|------|---------|
| 📖 Project docs | `docs/` | Concepts, architecture, decisions |
| 🤖 Agent knowledge | `docs/agents/` | How agents should work (not user-facing) |

```
docs/
├── index.md           # 📋 Bundle index (type: concept)
├── adr/               # 📝 Architecture Decision Records — start here
├── architecture/      # 🏛️  Component designs (Trinity orchestrator)
├── diagrams/          # 📊 Structurizr DSL (source of truth) + exports
└── journal/           # 📅 Session logs & operator profile (gitignored — personal)
```

### Decision records

| ADR | Decision |
|-----|----------|
| [0001](docs/adr/0001-local-first-launcher-not-a-methodology-runtime.md) | This is a local-first launcher, not a methodology runtime |
| [0002](docs/adr/0002-declare-model-tiers-never-auto-route.md) | Declare model tiers, never auto-route |
| [0003](docs/adr/0003-parallel-agents-via-disjoint-path-sets.md) | Parallel agents via disjoint path sets, no git, no worktree |
| [0004](docs/adr/0004-jev-ai-is-not-adopted.md) | Jev AI is not adopted |
| [0005](docs/adr/0005-no-external-agent-orchestration-dependency.md) | No external agent-orchestration dependency |
| [0006](docs/adr/0006-vendor-ollama-tool-call-proxy.md) | Vendor the Ollama tool-call proxy instead of depending on it |
| [0007](docs/adr/0007-trinity-orchestrator-runs-headless-opencode-run.md) | The Trinity orchestrator runs `opencode run` headless |

> `docs/architecture.md` does not exist. The Trinity orchestrator design lives in
> `docs/architecture/trinity-orchestrator/`, and the C4 views in `docs/diagrams/tridev.dsl`.

---

## 🚦 Model Selection

Tiers are declared, never auto-routed. The launcher picks nothing at runtime — see
[ADR 0002](docs/adr/0002-declare-model-tiers-never-auto-route.md). Every model in the
`/model` picker carries its tier and EUR price in its name.

| Tier | Provider | Model | Best For |
|------|----------|-------|----------|
| **0 FREE** | `opencode` | `space-bunny-free` | **Default**, for both `model` and `small_model` |
| **0 FREE** | `ollama` | `qwen2.5-coder-tools:7b` | Optional. Local and private. Needs `--ollama`; the only tier with working tool-calling |
| **1 BUDGET** | T-Systems | `gpt-oss-120b` | Cheapest capable work, Euro0.20/0.65 |
| **2 MODERATE** | T-Systems | `Qwen3.6-35B-A3B-FP8`, `Mistral Small 4` | Good default when you need a paid model |
| **3 PREMIUM** | T-Systems | `GLM-5.2` | 1M context at Euro1.50/3.50 |
| **4–5 HIGH** | T-Systems | `claude-opus-*`, `gpt-5.4` | Hard problems only. Euro4.95–24.75/M out |

Models missing from the pricing table display as `UNPRICED - <name>`. Nothing is guessed.

> ⚠️ The OpenCode Zen free tier is quota-limited (`FreeUsageLimitError`) and documented as
> free "for a limited time". Treat tier 0 as a convenience, not a guarantee.
> Do **not** switch to `opencode/big-pickle` — it is free but the Zen docs state its data
> may be used to train the model during the free period.

> 💡 **ADHD Tip**: Leave it on tier 0. Only escalate when something actually fails.

---

## ⚡ Commands Quick Reference

```bash
devbox run opencode                 # default model, no Ollama
devbox run opencode-ollama          # with Ollama auto-start
devbox run opencode /path/to/project

bash scripts/trinity.sh "<task>"          # brahma -> vishnu -> maheshwara
bash scripts/trinity.sh --parallel "<task>"  # brahma || vishnu, needs a plan on disk
```

Exit codes for `trinity.sh`: `0` all roles completed · `1` a role crashed, refused, or
breached its paths · `2` usage error · `3` `--parallel` with no plan on disk.

Script-level tests, runnable without the CLI:

```bash
bash scripts/test-trinity.sh
bash scripts/test-opencode-sync.sh
```

---

## 🎯 Agent Behavior

Every role follows the **Ponytail Engineering Rules** from `AGENTS.md`:

- ✅ **Smallest solution first** — Don't add features not requested
- ✅ **Use existing code** — Prefer extending over writing new
- ✅ **Minimal diffs** — Reviewable, deletable changes
- ✅ **Test behavior** — Verify before claiming complete

Each trinity role also carries its own remit on top of these — see
[The Agent Trinity](#the-agent-trinity).

---

## 🔗 Jira Integration

Requires:
1. `.env` file with credentials
2. MCP (Model Context Protocol) server
3. Jira Cloud or Data Center project

```bash
# Verify Jira connection
curl -s "$JIRA_URL/rest/api/2/myself" -u "email:token"
```

---

## 📞 Contact

- Repo: [github.com/sankhasil/opencode-tridev](https://github.com/sankhasil/opencode-tridev)
- Launcher: [scripts/opencode.sh](scripts/opencode.sh)
- Decisions: [docs/adr/](docs/adr)

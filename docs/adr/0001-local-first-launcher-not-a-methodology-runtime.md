---
type: decision
title: Local-First Launcher, Not a Methodology Runtime
status: accepted
date: 2026-09-25
---

# Local-First Launcher, Not a Methodology Runtime

## Context

`opencode-tridev` is a personal dev environment wrapper for the OpenCode CLI. Its
assets are `scripts/opencode.sh` (510 lines of bash), a generated `opencode.json`,
`devbox.json`, `AGENTS.md`, and `skills-lock.json`.

`AGENTS.md` documents a method: the Ponytail rules, OKF doc bundles, ADRs, a session
journal, and the Agent Trinity (Brahma / Vishnu / Maheshwara). Read cold, that
content supports a second framing — a "methodology runtime" or "agent OS" that other
people install and operate.

The operator was shown that framing and declined it. The README's framing was already
correct and was not changed.

## Decision

State one noun: `opencode-tridev` is a local-first launcher.

`AGENTS.md` is the instruction manual for the agent running *inside* the launcher. It
is an input to a single user, not a product surface, and it carries no distribution,
versioning, or compatibility obligation of its own.

Every future decision is judged against the launcher scope. Anything that serves a
methodology audience rather than a single operator's local session is out of scope
until an ADR says otherwise.

## Consequences

### Positive

- One noun, one job. Scope tests become a single question: does this help run OpenCode
  locally?
- Nothing to ship. There is no install path, no version matrix, no consumer to break.
- `AGENTS.md` stays prose instead of becoming a spec with downstream obligations.

### Negative

- The methodology cannot be shared. Anyone who wants the Trinity or the OKF protocol
  has to read the file; there is no product to point them at.
- `AGENTS.md` is load-bearing. Editing it changes agent behavior, so it carries the
  weight of code with none of the tooling that normally protects code.
- The docs bundle becomes the only durable record of the method, so `docs/` and the
  live behavior of `AGENTS.md` can drift. No test covers the drift.

## Alternatives considered

- **Methodology runtime / agent OS.** Rejected: scope explosion. It converts a personal
  wrapper into a product with its own install path, release cadence, and compatibility
  matrix. None of the decisions made to date were about that product.
- **Model-routing decision layer.** Rejected as the project's core job. See
  [ADR 0002](0002-declare-model-tiers-never-auto-route.md).

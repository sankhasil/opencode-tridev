---
type: reference
title: Agent Notes
---

# Agent Notes

Point-in-time findings. Research, evaluations, comparisons. Dated; not authoritative forever.

- [2026-09-25 — OpenCode: Jev feasibility + declaring model tiers](2026-09-25-opencode-jev-and-model-tiers.md) — Jev is an `EvaluationModelV4`, not a `LanguageModelV3`; OpenCode is `streamText`-only. No tier construct exists in `opencode.json`; use `model` + `small_model` + `name`.
- [2026-09-25 — OpenCode: running N instances in N git worktrees](2026-09-25-opencode-worktree-concurrency.md) — Safe. Worktrees share one `Project.ID` but get separate `project_directory` rows, sessions, snapshot repos and config scopes. Collides on: `auth.json` (unlocked read-modify-write), `opencode.db` (one SQLite file, WAL + 5s busy_timeout), the `project` row, and `log/opencode.log`. `XDG_DATA_HOME` is the only real isolation lever; `OPENCODE_PURE` only disables plugins.

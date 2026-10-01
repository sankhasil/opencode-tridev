---
type: decision
title: Declare Model Tiers, Never Auto-Route
status: accepted
date: 2026-09-25
---

# Declare Model Tiers, Never Auto-Route

## Context

Model routing was chosen as the launcher's "core job" when the question was first
pressed. That framing needed a product larger than the one
[ADR 0001](0001-local-first-launcher-not-a-methodology-runtime.md) accepts. Asking where
the router *physically lives* collapsed the answer.

`scripts/opencode.sh` runs once, before OpenCode starts, and writes a static
`opencode.json`. At that moment it has no visibility into the task. It cannot route;
it can only pre-configure.

OpenCode already performs runtime model selection, via `model`, `small_model`,
`agent.<name>.model`, the `/model` picker, and the `-m` flag. A bash pre-generator
rebuilding that would be a weaker duplicate of a mechanism that already works.

The `pricing()` table at `scripts/opencode.sh:53-72` already embeds a severity label
and a EUR price in each model's `name`, so the `/model` picker shows cost at the point
of choice.

## Decision

Extend the existing `pricing()` table. Cover every model in the fetched catalog,
prefix each name with an explicit tier, and split the `model` / `small_model` defaults.

No new routing code. No new dependencies.

Defaults: `opencode/space-bunny-free` for **both** `model` and `small_model`.

> Amended twice on 2026-09-25 during implementation, after the tier split was made
> concrete.
>
> First amendment — the `model` default is pinned to `opencode/space-bunny-free`: free, 1M
> context, 524k output, `tool_call: true`, and the OpenCode Zen docs list it as
> zero-retention with no training use. `opencode/big-pickle` was rejected for the same zero
> cost: the Zen docs state that *during its free period its collected data may be used to
> improve the model*, which is disqualifying for a repo holding a Jira token and an
> employer LLM hub key. The Zen free tier is also quota'd (`FreeUsageLimitError`) and
> documented as free "for a limited time", so neither free model is a durability
> commitment. Tiers 1–5 are the T-Systems cost bands; tier 0 is anything at zero cost.
>
> Second amendment — `small_model` moved from local Ollama to the same free cloud model.
> The original reasoning was that `small_model` only runs title generation and summaries,
> so a 7B local model suffices. Reading
> `open-code/tools/ollama-tool-call-proxy.mjs` showed that assumption carried a hidden cost:
> the proxy is a verified no-op when a request carries no tools (guards at lines 198, 263
> and 292), so `small_model` never needed it — but `scripts/opencode.sh:465` starts neither
> Ollama nor the proxy unless `--ollama` is passed, then execs OpenCode anyway. A local
> `small_model` therefore depended on two unstarted local processes and failed silently.
> Confirmed by direct test: `:11434/v1` and the proxy at `:4198/v1` return byte-identical
> results for a no-tools request. Moving `small_model` to the free tier removes the
> dependency entirely. Local Ollama remains in the picker and still needs `--ollama`.
> Accepted cost: the default path is no longer offline-capable.
>
> Third amendment — the defaults are **configuration, not code**. The first implementation
> hardcoded `opencode/space-bunny-free` into the config heredoc in `scripts/opencode.sh`.
> That was wrong twice over: the generator overwrote `opencode.json` on every launch, so the
> value was not a default but a forced overwrite, and hand-editing `opencode.json` — which
> the README invites — was silently reverted. The generator now resolves
> `model` / `small_model` as *env → existing `opencode.json` → built-in default*, so
> `opencode.json` is the source of truth for the choice and the script only supplies a
> fallback. `OLLAMA_MODEL` was split out from the old overloaded `MODEL`, which had meant
> both "the model to use" and "the model to declare in the `ollama` provider"; setting it to
> a non-local id would have produced `ollama/space-bunny-free`. The resolution block sits
> after `load_env_file`, because the old `MODEL` was assigned at line 11 — before any `.env`
> was read — which is why it could never be overridden.

Agents remain free to pick a different model at runtime, and nothing in the launcher
intervenes.

## Consequences

### Positive

- Zero new code paths. The change lands inside a table that already exists.
- Cost and tier are visible in the picker, which is where the choice is made.
- One place to edit. Adding a model means adding one table entry.
- Task flow is unchanged. The launcher stops before OpenCode starts, as it always did.

### Negative

- The table is hand-maintained and already lags the catalog. It lists 17 ids against a
  much larger T-Systems catalog, and entries are duplicated across casing — `GLM-5.2`
  and `glm-5.2` at `scripts/opencode.sh:60-61`. Coverage is a manual chore.
- Declaring tiers means the operator still reads. Nothing picks the model for them.
- `model` and `small_model` are launcher-level globals. Splitting them sets a good
  default the operator can only override by editing `opencode.json` or using `/model`.
- Tier labels are editorial, not derived. "Moderate cost" is a human judgment.

> ponytail: the pricing table is hand-maintained and still lags the catalog — it covers
> 13 ids against a much larger T-Systems catalog. This is acceptable today because
> unpriced models fall through to an explicit `UNPRICED - <name>` label and still work;
> only the tier and EUR figures are missing, and a missing price is visible rather than
> silently absent. Current limitation: EUR figures for the newer models
> (`GLM-5.3-Flash-Preview`, the `claude-*-5` generation, `GPT-5-Codex`, `Qwen3.8`) are not
> known and were deliberately not invented. Lookup is now case-insensitive via
> `ascii_downcase`, which removed four duplicate rows. Upgrade path: source prices from
> the `/models` response if T-Systems ever publishes them, so the table stops being
> hand-maintained.

## Alternatives considered

- **Runtime plugin or hook router calling a classifier.** Rejected: the most new code
  of any option considered, and OpenCode has no evaluation-model support to hang the
  classifier on.
- **Jira ingress triage.** Rejected: no ticket volume to justify a classifier.
- **Prompt-level skill.** Rejected as the primary mechanism. Model selection needs to be
  visible in config, not implied by prose. Retained as a valid complement.

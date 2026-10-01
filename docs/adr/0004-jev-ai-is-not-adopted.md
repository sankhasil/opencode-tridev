---
type: decision
title: Jev AI Is Not Adopted
status: accepted
date: 2026-09-25
---

# Jev AI Is Not Adopted

## Context

Jev (`typesafe-ai/jev`) is a real product: a proprietary, non-generative,
schema-constrained classifier from TypeSafe AI (founded 2024; founder Diogo Almeida,
ex-OpenAI, co-inventor of RLHF/InstructGPT; $40M seed led by DCVC; out of stealth
2026-09-15). Priced at $0.042 per 1M input tokens, output free, 70–500ms. Sold through
Vercel AI Gateway, Cloudflare, and OpenRouter.

One correction to the record: Vercel did **not** acquire TypeSafe. The `vercel_acq`
string in the marketing URL is Vercel's internal Google Ads campaign naming.

It was evaluated as a fast-decision layer for this launcher. Three blockers were found.

**1. Jev cannot be used as a model in OpenCode.** OpenCode calls `streamText` with an
`LanguageModelV3` chat model (`packages/opencode/src/session/llm.ts:280`). Jev is an
`EvaluationModelV4`, reached only via `experimental_evaluate`, which does not stream.
`@ai-sdk/typesafe-ai` throws `NoSuchModelError` from `languageModel()`. `models.dev/api.json`
lists 223 providers and no `typesafe-ai`, so it will not validate against the
`opencode.json` schema.

The failure would be silent until request time: `output: 0` is falsy, so
`maxOutputTokens()` rewrites it to 32000. The misconfiguration would look like it worked.

**2. The marketing copy is false.** The quoted pitch was:

> Offload System 1 logic to Jev AI. Save reasoning models for code synthesis. Jev
> provides deterministic, sub-second classification, scoring, and safety checks.

Not found in any primary source. "Sub-second" and the System 1 framing are legitimate.
"Deterministic" is contradicted by TypeSafe's own limitations doc: state written to steer
the model can move the answer, and a question and its negation are documented returning
0.72 and 0.47. "Save reasoning models for code synthesis" is unsupported — Jev never
generates code. The advertised *safety checks* use is the one its vendor, Pydantic,
LangChain, and VentureBeat all warn against building on.

**3. It is cloud-only.** No weights, no self-host option. That conflicts with
local-first, and a Jira or diff classifier would send confidential company data to a
startup days out of stealth.

The only viable vehicle would be a custom tool under `.opencode/tools/*.ts` — new code,
a new secret, a new permission rule, for a workload that does not exist today.

## Decision

Do not adopt Jev.

Status is **parked, not permanently rejected**. Revisit only when both conditions hold:

1. A real, recurring classification workload exists, and
2. the confidentiality question is resolved.

Neither condition is met today.

## Consequences

### Positive

- No new code, no new secret, no company data leaving the machine.
- The evaluation is recorded, so it is not repeated from scratch.
- Parking preserves the option at zero maintenance cost.

### Negative

- If a classification workload does appear, the integration is a from-scratch build, not
  a config change. Someone will have to redo the `EvaluationModelV4` / `languageModel()`
  analysis.
- Real opportunity cost: the product is cheap and fast, and both properties are
  relevant to a launcher that juggles ~40 cloud models.
- "Parked" invites re-litigation without new evidence unless the two triggers above are
  honored as written.
- Absence from `models.dev` means this cannot be revisited by editing config at all. It
  requires upstream support in OpenCode, or the custom tool path.

## Alternatives considered

- **Use Jev as the model.** Rejected: impossible in three independent ways — wrong
  interface type, non-streaming, and absent from `models.dev`.
- **Wrap Jev as a custom tool at `.opencode/tools/*.ts`.** Rejected for now: new code,
  new secret, new permission rule, no workload to justify any of the three.
- **Use a local classifier on Ollama.** Rejected on the same YAGNI basis that produced
  the parking decision. Note the irony: this is the option local-first would otherwise
  favor, and it is declined only because there is nothing to classify.

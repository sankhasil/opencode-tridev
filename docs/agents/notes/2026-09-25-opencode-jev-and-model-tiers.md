---
type: reference
title: "OpenCode: Jev feasibility + declaring model tiers"
---

# OpenCode: Jev feasibility + declaring model tiers

Research date: 2026-09-25.

**Repo note:** the OpenCode source repo is now **`anomalyco/opencode`** (was `sst/opencode`). Docs banner: "New OpenCode v2 is now available". All source citations below are from commit `adee738` (`dev`, 2026-09-25).

**Jev:** it is an `EvaluationModelV4`, a *different model interface* from `LanguageModelV4`, reached only via `experimental_evaluate()`.

---

## Question 1 — Can OpenCode use Jev as a model?

### 1.1 How does OpenCode call models?

**`streamText`**, unconditionally, on the default path.

Source: `packages/opencode/src/session/llm.ts`

```
9:  import { streamText, wrapLanguageModel, type ModelMessage, type Tool } from "ai"
```

```
276:  // Default runtime path: AI SDK owns provider execution and tool dispatch;
277:  // LLMAISDK.toLLMEvents below normalizes fullStream parts for the processor.
278:  return {
279:    type: "ai-sdk" as const,
280:    result: streamText({
```

There is an opt-in second runtime ("native") behind `flags.experimentalNativeLlm`, over the `@opencode-ai/llm` package — it is also stream-shaped (`session/llm.ts:226-253`, `session/llm/native-runtime.ts:30-31`).

`generateObject` / `streamObject` are imported, but for **exactly one built-in feature**: generating an agent config from a natural-language description. `packages/opencode/src/agent/agent.ts:7,416,420,435`:

```
7:   import { generateObject, streamObject, type ModelMessage } from "ai"
...
404:  content: `Create an agent configuration based on this request: "${input.description}". ...
416: } satisfies Parameters<typeof generateObject>[0]
```

That is not a general structured-output path and cannot be pointed at an arbitrary model.

Pinned SDK versions (root `package.json` → `workspaces.catalog`, and `packages/opencode/package.json`):

| Package | Version |
|---|---|
| `ai` | `6.0.168` |
| `@ai-sdk/provider` | `3.0.16` |
| `@ai-sdk/openai-compatible` | `2.0.41` |

So OpenCode is on **AI SDK v6 / `LanguageModelV3`** — confirmed by `llm.ts:329`, `specificationVersion: "v3" as const`.

Docs: <https://opencode.ai/docs/models>, <https://opencode.ai/docs/providers>

> "OpenCode uses the [AI SDK](https://ai-sdk.dev/) and [Models.dev](https://models.dev) to support **75+ LLM providers** and it supports running local models."

### 1.2 Any support for a classification / evaluation model?

**No.** Full-tree grep of `packages/opencode/src` for `experimental_evaluate|classification|classifier` returns **zero matches**. There is no `evaluationModel` call, no `EvaluationModel` type, and no evaluation-specific code path.

The AI SDK side confirms evaluation is a separate model capability, not a language model:

<https://ai-sdk.dev/docs/ai-sdk-core/evaluation>

> "This API and the evaluation model specification are experimental and may change in patch releases."

> "Registry language/image middleware does not wrap evaluation models."

> "Evaluation currently returns one complete result for one shared state. **It does not stream answers**, perform multilabel classification, or batch unrelated states."

And the provider package is explicit that Jev is *not* a language model. `@ai-sdk/typesafe-ai@3.0.6` exports only `evaluationModel()`; its `languageModel()` **throws**:

`node_modules/@ai-sdk/typesafe-ai/dist/index.js`

```js
213:    evaluationModel: (modelId) => new EvaluationTypeSafeAiModel(modelId, {
219:    languageModel: (modelId) => {
220:      throw new NoSuchModelError({ modelId, modelType: "languageModel" });
```

Endpoint it targets (`index.js:130`): `` url: `${this.config.baseURL}/systemone` ``, base `https://api.typesafe.ai/v1` (`index.js:203`).

### 1.3 Minimum requirements for a usable model

| Requirement | Verdict | Evidence |
|---|---|---|
| Must be a chat/generate language model | **Yes** | `streamText({ model: language, ... })` — `llm.ts:280,325` |
| Must support streaming | **Yes** | `result.fullStream` is normalized into `LLMEvent`s — `llm.ts:276-277`; native runtime also returns a stream |
| Must support tool calling | **No** (but assumed) | `title` agent runs with `tools: {}` — `session/prompt.ts:228`. Capability **defaults to true**: `toolcall: model.tool_call ?? existingModel?.capabilities.toolcall ?? true` — `provider/provider.ts:1529` |
| Must have non-zero max output tokens | **No** | see below |
| `limit.output: 0` hides it from the picker | **No** | picker filter is status-only — `provider/provider.ts:1360-1366` |

**On max output tokens** — a zero-output model is not rejected, it is silently rewritten:

`provider/transform.ts:18,1481-1482`

```ts
export const OUTPUT_TOKEN_MAX = 32_000
...
export function maxOutputTokens(model: Provider.Model, outputTokenMax = OUTPUT_TOKEN_MAX): number {
  return Math.min(model.limit.output, outputTokenMax) || outputTokenMax
}
```

`Math.min(0, 32000)` → `0` → falsy → falls through to `32000`. So a `limit.output: 0` entry gets a 32k output budget. There is **no validation gate** that would stop a Jev-shaped entry from being declared and appearing in `/models` — the request would just fail at runtime, because the endpoint is not a chat endpoint.

**Picker filter** (`provider/provider.ts:1360-1366`) excludes only `status: "deprecated"` and `status: "alpha"` (unless experimental models are enabled). Output limits are not considered.

### 1.4 Arbitrary `baseURL` + OpenAI-compatible provider?

**Yes** — <https://opencode.ai/docs/providers#custom-provider>

> "**npm**: AI SDK package to use, `@ai-sdk/openai-compatible` for OpenAI-compatible providers (for `/v1/chat/completions`). If your provider/model uses `/v1/responses`, use `@ai-sdk/openai`."

> "**limit.context**: Maximum input tokens the model accepts. **limit.output**: Maximum tokens the model can generate."

**Could `typesafe-ai/jev` be pointed at that way? No.** Three independent blockers:

1. Jev is not an OpenAI-compatible chat endpoint — it is `POST /v1/systemone`, and `@ai-sdk/typesafe-ai` hard-throws from `languageModel()`.
2. Version skew: `@ai-sdk/typesafe-ai@3.0.6` requires `@ai-sdk/provider@4.0.18`; OpenCode pins `@ai-sdk/provider@3.0.16` (`LanguageModelV3`).
3. No catalog entry. `models.dev/api.json` has 223 providers and **no `typesafe-ai` / `jev`**; the string `jev` does not appear in `models.dev/model-schema.json` either, so `typesafe-ai/jev` will not even validate against the `$ref` on `model` / `small_model` in `config.json`.

**Escape hatch (theoretical, not viable).** `npm` is an arbitrary string and OpenCode installs it at runtime — `provider/provider.ts:1843-1847`:

```ts
if (model.api.npm.startsWith("file://")) return model.api.npm
const item = await Npm.add(model.api.npm)
```

So you *could* author a package exporting a `LanguageModelV3` that speaks the Jev `/v1/systemone` protocol. That means hand-writing a shim the AI SDK team already wrote and deliberately walled off, on a provider major version behind `@ai-sdk/typesafe-ai`. Not worth it.

### 1.5 Mechanisms for a one-off, non-chat call

| Mechanism | Doc | Suitability for a classifier |
|---|---|---|
| **Custom tools** (`.opencode/tools/*.ts`) | <https://opencode.ai/docs/custom-tools> | **Best.** Runs arbitrary code in-process; the model invokes it like `read` or `bash`; output is plain tool text. No model needed. |
| **Plugins** | <https://opencode.ai/docs/plugins> | Right when you must *intercept* rather than be *called* — e.g. gate `tool.execute.before`, or rewrite `chat.params`. Can also register tools. |
| **MCP servers** | <https://opencode.ai/docs/mcp-servers> | Right only if a third party already exposes Jev as an MCP server. The operator already runs a `jira` MCP server. |
| **Agents / subagents** | <https://opencode.ai/docs/agents> | Wrong vehicle — a subagent is still a chat loop over a language model. Useful only to give the classifier call a dedicated prompt/session. |
| **Commands** | <https://opencode.ai/docs/commands> | Invocation sugar, not a transport. Can pin `model` per command but cannot call a non-chat endpoint. |
| **Hooks** | `packages/opencode/src/plugin/index.ts` (`Hooks`) | Interception only. Relevant names: `tool.execute.before`, `tool.execute.after`, `chat.params`, `chat.message`, `experimental.provider.small_model`. |

Recommended shape: a custom tool `.opencode/tools/classify.ts` that does a plain `fetch()` to `https://api.typesafe.ai/v1/systemone` (or, if you already run the AI SDK, `experimental_evaluate` from `ai@7` — note this would be a *separate* `ai` install from OpenCode's own `ai@6`). No provider entry, no model entry, nothing in `opencode.json` beyond permissions.

---

## Question 2 — Declaring model tiers in `opencode.json`

### 2.1 Is there a "tier" / "profile" / "preset" concept?

**No.** The `Config` definition in <https://opencode.ai/config.json> contains no `tier`, `profile`, `preset`, `group`, or `alias` key, and it is closed:

```json
"Config": { "type": "object", "properties": { ... }, "additionalProperties": false }
```

`ProviderConfig` is likewise `"additionalProperties": false`. There is no grouping construct anywhere in the schema.

### 2.2 What grouping / switching mechanisms *do* exist?

| Mechanism | Schema path | Notes |
|---|---|---|
| Default model | `model` | "Model to use in the format of provider/model, eg anthropic/claude-2" |
| **Small model** | `small_model` | "Small model to use for tasks like title generation in the format of provider/model" |
| Per-agent model | `agent.<name>.model` | `AgentConfig.model`. Includes the built-in hidden agents `title`, `summary`, `compaction` |
| Per-agent variant | `agent.<name>.variant` | "Default model variant for this agent (applies only when using the agent's configured model.)" |
| Per-command model | `command.<name>.model` | |
| Picker | `/models` | |
| CLI flag | `--model` / `-m` | Highest load priority — <https://opencode.ai/docs/models#loading-models> |
| Picker filtering | `provider.<name>.whitelist` / `.blacklist` | <https://opencode.ai/docs/providers#hiding-models> |
| Variants | `provider.<p>.models.<m>.variants` + `variant_cycle` keybind | <https://opencode.ai/docs/keybinds> |

Load priority for the default model (`/docs/models#loading-models`): `--model`/`-m` → config `model` → last used model → first model by internal priority.

### 2.3 Aliases, picker visibility, and price metadata?

- **Picker-visible entries: yes.** The `models` map key *is* the id that shows up in `/models`. Declaring an entry creates a selectable model. Doc: "The model name will be displayed in the model selection list."
- **Price label: yes, via `name`.** `name` is the display string. There is no separate label field, and **no arbitrary metadata** — the model entry is `"additionalProperties": false`.
- **`cost` is a first-class field** for real pricing: `cost.input`, `cost.output`, `cost.cache_read`, `cost.cache_write`, and `cost.context_over_200k.{input,output,cache_read,cache_write}` (all default to `0` — `provider/provider.ts:1546-1554`).
- **Alias: no.** There is no alias indirection. "Aliasing" is done by putting the label in `name` and pointing `model`/`small_model`/agents at the real `provider/model` id.

> The operator's existing config already uses the correct mechanism: `"name": "Claude Opus 4.8 (Very high cost, Euro4.95/Euro24.75)"`.

### 2.4 Is there small-model auto-fallback?

**Yes, with a three-step chain.** `Provider.getSmallModel` — `packages/opencode/src/provider/provider.ts:1939-2006`:

1. `cfg.small_model`, if set (`:1942-1947`).
2. Plugin hook `experimental.provider.small_model` (`:1953-1964`).
3. Family priority within the active provider (`:1971-2003`):
   - `opencode*` providers → `["gpt-nano"]`
   - `github-copilot` → `["gpt-mini", "gemini-flash", "gpt-nano", "claude-haiku"]`
   - everything else → `["gemini-flash", "gpt-nano", "claude-haiku"]`

```ts
2048: const smallModelFamilyPriority = ["gemini-flash", "gpt-nano", "claude-haiku"]
```

Consumers: `session/prompt.ts:220` (session title generation) and `server/routes/instance/httpapi/handlers/project-copy.ts:31`. Title generation runs the hidden `title` agent with `small: true` and `tools: {}` (`session/prompt.ts:218-240`).

The `title` / `summary` / `compaction` agents are real, hidden, primary agents defined at `agent/agent.ts:219-264`, and each accepts its own `model` via `agent.<name>.model` (`agent/agent.ts:281`), which **overrides** `getSmallModel`.

There is **no** automatic *fallback on failure* — this is a static "which model for chores" selector, not a retry ladder.

### 2.5 Exact fields in `provider.<name>.models.<modelId>`

From `https://opencode.ai/config.json`, verbatim and complete (`additionalProperties: false`):

`id`, `name`, `family`, `release_date`, `attachment`, `reasoning`, `temperature`, `tool_call`, `interleaved` (bool | `"reasoning"` | `"reasoning_content"` | `"reasoning_text"` | `{ field: <same enum> }`), `cost` (`input`, `output`, `cache_read`, `cache_write`, `context_over_200k`), `limit` (`context`, `input`, `output` — **`context` and `output` are required if `limit` is present**), `modalities` (`input[]`/`output[]` from `text`/`audio`/`image`/`video`/`pdf`), `experimental`, `status` (`alpha`|`beta`|`deprecated`|`active`), `provider` (`npm`, `api`), `options`, `headers`, `variants` (each `{ disabled }`).

Defaults applied at load time — `provider/provider.ts:1524-1560`:

| Field | Default when omitted |
|---|---|
| `tool_call` | **`true`** |
| `temperature` / `reasoning` / `attachment` | `false` |
| `modalities.input.text` / `output.text` | `true` |
| `status` | `active` |
| `api.npm` | `@ai-sdk/openai-compatible` |
| `limit.context` | `0` |
| `limit.output` | `0` |
| `cost.*` | `0` |

**Gotcha:** because `limit` defaults to `0`/`0`, a bare model entry gets a 32k output budget (per §1.3) and a **0-token context window**, which feeds the compaction/overflow math in `session/overflow.ts:16-19`. Always set `limit.context` and `limit.output` explicitly.

---

## Bottom line

### (a) Can Jev be used as an OpenCode model? — **No.**

Not partial. Every OpenCode model path is a `LanguageModelV3` chat/generate loop driven by `streamText`; Jev is an `EvaluationModelV4` reached only through `experimental_evaluate`, does not stream, and its own SDK provider throws from `languageModel()`. `limit.output: 0` will *not* stop you declaring it and it *will* appear in `/models` — the failure is at request time, which is the worst place to find out.

**Correct vehicle: a custom tool.** `.opencode/tools/classify.ts`, plain `fetch()` to `https://api.typesafe.ai/v1/systemone`, gated with a `permission.classify` rule. Zero `opencode.json` model/provider entries. If Jev is ever exposed over MCP, an MCP server is the alternative. A plugin is only warranted to *intercept* tool calls rather than be called.

### (b) Minimal correct way to declare three tiers in `opencode.json`

There is no tier construct. The smallest correct expression uses the three things that actually exist: `model` (the pick), `small_model` (the chore model), and `name` (the label the picker shows).

```jsonc
{
  "$schema": "https://opencode.ai/config.json",

  // Tier 2 (cheap) — default working model.
  "model": "tsystems/gemini-3.5-flash",

  // Tier 1 (local) — chores only: titles, summaries, compaction.
  "small_model": "ollama/hhao/qwen2.5-coder-tools:7b",

  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Tier 1 - Local (free)",
      "options": { "baseURL": "http://localhost:4198/v1", "apiKey": "ollama" },
      "models": {
        "hhao/qwen2.5-coder-tools:7b": {
          "name": "TIER 1 LOCAL - Qwen2.5 Coder 7B (free)",
          "limit": { "context": 32768, "output": 8192 }
        }
      }
    },
    "tsystems": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "T-Systems LLM Hub",
      "options": {
        "baseURL": "https://llm-server.llmhub.t-systems.net/v2",
        "apiKey": "{env:TSYSTEMS_OPENCODE_API_KEY}"
      },
      "models": {
        "gemini-3.5-flash": {
          "name": "TIER 2 CHEAP - Gemini 3.5 Flash (Euro1.49/Euro8.91)",
          "limit": { "context": 1048576, "output": 65536 }
        },
        "claude-opus-5": {
          "name": "TIER 3 PREMIUM - Claude Opus 5 (Euro4.95/Euro24.75)",
          "limit": { "context": 1000000, "output": 128000 }
        }
      }
    }
  }
}
```

Notes on why each line is load-bearing:

- `TIER n — <label>` prefix in `name` is the **only** place a tier label can live. `additionalProperties: false` on the model entry means there is no metadata field to add.
- Declare **only the three tier models** under `tsystems`. The current config lists ~40 models, which defeats the point of a tier. `provider.<name>.whitelist` is an alternative if you want to keep the full list available.
- `small_model` currently points at the *same* 7B model as `model`, so titles and summaries already cost the local tier. That is already correct — keep it, and make `model` the cheap hosted tier.
- Set `limit` explicitly on every entry (§2.5 gotcha).
- Switching tiers at runtime is the `/models` picker or `-m <provider/model>`. If you want a *named* switch, a markdown command in `~/.config/opencode/command/` is cheaper than any config mechanism — there is no profile feature to reach for.
- Do **not** put `typesafe-ai/jev` or embedding/whisper models in the same tier list as chat models. Non-chat models can be declared (they will show in the picker) but cannot be driven.

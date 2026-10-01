---
type: decision
title: Vendor the Ollama Tool-Call Proxy from photography_ai
status: accepted
date: 2026-09-28
---

# Vendor the Ollama Tool-Call Proxy from `photography_ai`

## Context

`opencode.json` declares an `ollama` provider pointing at `http://localhost:4198/v1`, and
`scripts/opencode.sh:468-470` starts that endpoint with `npm run ollama:serve` from
`open-code/`. Three things did not line up:

- `open-code/package.json` defined **no scripts at all** — 58 bytes and a single
  `opencode-ai` dependency.
- Neither `open-code/ollama-serve.sh` nor `open-code/ollama-tool-call-proxy.mjs` existed.
  A repo-wide search for the proxy source returned nothing.
- Port `:4198` was nonetheless live, served by
  `PersonalCodes/fotography_ai/opencode-ui/tools/ollama-tool-call-proxy.mjs` — a Vue web-UI
  project in a different repository.

So the local model tier depended on a process owned by an unrelated project. `--ollama`,
advertised in `devbox.json` and documented in the README, could not work. It appeared to
work only because that other process happened to be running.

The proxy is not a bridge to something Ollama lacks. Its own upstream is Ollama's native
OpenAI-compatible endpoint (`tools/ollama-tool-call-proxy.mjs:40`). It exists solely because
`qwen2.5-coder` emits tool calls as bare JSON text, which an OpenAI-compatible client cannot
execute.

## Decision

Vendor all three files from `fotography_ai/opencode-ui/tools/` into `open-code/tools/` and
add `ollama:serve` / `ollama:stop` to `open-code/package.json`. Each vendored file carries a
two-line provenance header naming the source repository and date.

Use a shell `&` rather than upstream's `concurrently -k`:

```
"ollama:serve": "bash tools/ollama-serve.sh & node tools/ollama-tool-call-proxy.mjs"
```

## Consequences

### Positive

- `open-code/` is self-contained. Nothing outside this repository serves a port it depends on.
- `--ollama` works, and `scripts/opencode.sh:474-481` can now poll for readiness and find it.
- Three files copied unmodified, verified free of hardcoded paths, absolute paths, and secrets.
- The source was plain and portable: configuration is `process.env` with working defaults
  (`PORT`, `OLLAMA_URL`).

### Negative

- The copy is now maintained by hand and can drift from `photography_ai`. There is no
  upstream for this repository, only a sibling checkout.
- The provenance header says "unmodified otherwise", which is true of the three files but
  **not** of the npm script, which was written fresh and deliberately differs from upstream.
- The default path no longer needs the proxy at all
  ([ADR 0002](0002-declare-model-tiers-never-auto-route.md)), so this code is exercised only
  when the operator manually selects the local tier. Low-traffic code rots.
- Vendoring draws a line from this repository to another. If `fotography_ai` is deleted, the
  code here still works; the reverse is untrue.

> ponytail: the vendored copy is byte-identical to upstream and hand-synced. That is
> acceptable today because the only intentional divergence is in `package.json`, not in the
> proxy itself, so a re-vendor is a three-file copy. Current limitation: any fix made in
> `fotography_ai` does not propagate. Upgrade path: if the two projects diverge, promote the
> proxy to its own repository and depend on it, or drop the local tier entirely — the
> default path no longer needs it.

## Alternatives considered

- **Document the cross-project dependency instead of vendoring.** Rejected: it leaves the
  local tier broken on any machine where `fotography_ai` has not been run, and encodes an
  invisible coupling in a README.
- **Drop the local tier.** Rejected at the time. It is now viable — see
  [ADR 0002](0002-declare-model-tiers-never-auto-route.md) — and remains the cleanest option
  if the local tier stops being used.
- **Write a new proxy.** Rejected: working code already existed. Writing a replacement would
  be strictly more code for no behavioural gain.
- **Add `concurrently` as a dependency and copy upstream's script verbatim.** Rejected: a new
  dependency for one `&`, and `-k` kills Ollama when the proxy exits, which contradicts
  `scripts/opencode.sh:453` — "Started once, left running across sessions."

## Verification

Exercised on port `4200` so the live `:4198` was left untouched. Both paths behaved:

- no-tools request — passed through unchanged, `content: 'OK'`, `finish_reason: stop`
- one tool offered (`write`) with a directive prompt — rewritten to
  `finish_reason: tool_calls` with a real `{"name":"write","arguments":{...}}` payload; the
  proxy's own log recorded `tools offered (1): write` and `rewrote=tool-call`

`bash -n` on both shell scripts, `node --check` on the proxy, and `open-code/package.json`
parsed as valid JSON.

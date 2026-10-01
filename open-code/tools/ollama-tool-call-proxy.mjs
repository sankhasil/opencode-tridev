#!/usr/bin/env node
// Vendored from PersonalCodes/fotography_ai/opencode-ui (git repo: photography_ai),
// 2026-09-28. Unmodified otherwise. Kept in sync by hand; no upstream for this project.
//
// Ollama tool-call proxy.
//
// Some local models (qwen2.5-coder) emit tool calls as bare JSON *text* instead
// of a proper `tool_calls` field, so an OpenAI-compatible client (opencode) sees
// only text and never executes the tool. This proxy sits between the client and
// ollama: when a request carries tools and the model responds with one or more
// `{"name": ..., "arguments": ...}` JSON objects (possibly embedded in prose or
// fenced blocks), it rewrites the response into a real `tool_calls` payload.
// Everything else passes through untouched.
//
// Runtime requirement: start ollama with tools/ollama-serve.sh (sets
// OLLAMA_CONTEXT_LENGTH=16384). The default 4096 context truncates opencode's
// ~15k-token agent prompt, and truncated models stop emitting parseable tool
// calls entirely.
//
// ponytail: the whole upstream response is buffered so a text stream can be
// rewritten into tool_calls. Consequence: no incremental streaming to the
// client; the reply arrives in one burst after the model finishes. Revisit with
// a tail-rewriting stream if incremental output becomes necessary.
//
// 7B-class models occasionally answer "create this file" prompts with prose
// (or even a fake refusal) instead of a tool call, so when tools are offered AND
// the latest user turn looks directive, a short system instruction is appended
// telling the model to reply with a bare JSON tool-call object. Positioned last
// so recency keeps it in the model's window even when the long agent prompt
// pushes context limits. The nudge is skipped on plain chat turns so the model
// can answer conversationally instead of being forced into ONLY-JSON.

import { createServer } from 'node:http'
import { pathToFileURL } from 'node:url'

const TOOL_CALL_NUDGE =
  'When a request requires file operations, edits, or shell commands, respond with ONLY a JSON tool call object: {"name":"<tool>","arguments":{...}}. No prose, no file contents in chat, and never claim the tool is unavailable.'

const PORT = Number(process.env.PORT ?? 4198)
const UPSTREAM = process.env.OLLAMA_URL ?? 'http://localhost:11434/v1'

function log(message) {
  console.error(`[ollama-proxy] ${message}`)
}

// Scan text for every valid tool-call object, tolerating arbitrary prose and
// fenced blocks around them. Each '{' starts a candidate; brace-count
// (string-aware) finds its matching '}' and JSON.parse decides if it is a tool
// call. Returns an array of { name, arguments } — possibly several when the
// model emitted multiple calls in one reply. The old lastIndexOf('}') slice
// broke whenever trailing prose followed valid JSON.
export function extractToolCalls(s) {
  const calls = []
  let start = s.indexOf('{')
  while (start !== -1) {
    let depth = 0
    let inString = false
    let escaped = false
    let matched = -1
    for (let i = start; i < s.length; i++) {
      const c = s[i]
      if (inString) {
        if (escaped) escaped = false
        else if (c === '\\') escaped = true
        else if (c === '"') inString = false
        continue
      }
      if (c === '"') inString = true
      else if (c === '{') depth++
      else if (c === '}') {
        depth--
        if (depth === 0) { matched = i; break }
      }
    }
    if (matched === -1) break
    let parsed
    try {
      parsed = JSON.parse(s.slice(start, matched + 1))
    } catch {
      start = s.indexOf('{', start + 1)
      continue
    }
    if (typeof parsed.name === 'string' && parsed.name && parsed.arguments !== undefined && parsed.arguments !== null) {
      let argsString
      if (typeof parsed.arguments === 'string') {
        argsString = parsed.arguments
      } else {
        try {
          argsString = JSON.stringify(parsed.arguments)
        } catch {
          start = s.indexOf('{', matched + 1)
          continue
        }
      }
      calls.push({ name: parsed.name, arguments: argsString })
      start = s.indexOf('{', matched + 1)
    } else {
      start = s.indexOf('{', start + 1)
    }
  }
  return calls
}

// Extract every tool call from a JSON-text response. Returns an array of
// { name, arguments }; empty when the text contains no tool-call object.
export function parseToolCalls(text) {
  if (!text) return []
  let s = text.trim()
  s = s.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/i, '')
  return extractToolCalls(s)
}

// Detect plain-text commands that should be wrapped as bash tool calls.
// ponytail: fallback for models (qwen) that emit commands as prose instead of JSON.
export function detectPlainTextCommand(text, allowedToolNames) {
  if (!text || !allowedToolNames.has('bash')) return []
  const s = text.trim().replace(/```[\s\S]*?```/g, '').trim()
  if (!s || s.length > 500) return []
  if (s.startsWith('{') || s.startsWith('[')) return []
  const commonCommands = /^(free|top|htop|ps|df|du|ls|cat|grep|find|echo|pwd|whoami|date|uname|uptime|mount|ifconfig|ip|netstat|ss|lsof|jobs|fg|bg|kill|killall|pkill|nice|nohup|screen|tmux|vim|nano|less|more|head|tail|wc|sort|uniq|cut|tr|sed|awk|curl|wget|ssh|scp|rsync|git|npm|yarn|pnpm|node|python|python3|pip|java|javac|make|cmake|gcc|g\+\+|clang|rustc|cargo|go|ruby|perl|php|lua|r|julia| octave|spark|docker|podman|kubectl|helm|terraform|ansible|aws|gcloud|az|doctl|heroku|vercel|netlify)(\s|$)/i
  if (commonCommands.test(s)) {
    return [{ name: 'bash', arguments: JSON.stringify({ command: s }) }]
  }
  return []
}

// Action verbs that signal the user wants a file/shell operation rather than a
// chat reply. Best-effort steer for when to inject the tool-call nudge.
const ACTION_HINTS = [
  'write', 'create', 'edit', 'modify', 'update', 'append', 'save', 'new file',
  'delete', 'remove', 'rename', 'move', 'todowrite',
  'run', 'execute', 'command', 'shell', 'bash', 'script',
  'read', 'show', 'cat', 'search', 'find', 'grep', 'list', 'ls',
]

// Pull the text of the last user turn, tolerating both string and multimodal
// content-part arrays (OpenAI format).
export function lastUserText(messages) {
  if (!Array.isArray(messages)) return ''
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (m?.role !== 'user') continue
    if (typeof m.content === 'string') return m.content
    if (Array.isArray(m.content)) {
      return m.content
        .filter((p) => p && p.type === 'text')
        .map((p) => p.text ?? '')
        .join('\n')
    }
    return ''
  }
  return ''
}

// Decide whether the latest user turn actually expects a tool call. True when an
// offered tool name is named explicitly, or a generic action verb appears. Used
// to inject the nudge only on directive turns, leaving plain chat conversational.
export function wantsToolCall(requestBody) {
  const tools = requestBody.tools
  if (!Array.isArray(tools) || tools.length === 0) return false
  const text = lastUserText(requestBody.messages ?? []).toLowerCase()
  if (!text) return false
  const toolNames = tools.map((t) => (t.function?.name ?? t.name ?? '').toLowerCase()).filter(Boolean)
  if (toolNames.some((n) => n && text.includes(n))) return true
  return ACTION_HINTS.some((h) => text.includes(h))
}

// Log which tools OpenCode actually offered on this request. Ground truth for
// "was this tool name really available, or did the model hallucinate it" —
// this reflects exactly what the client sent, before the model or this proxy
// touches it. Set DEBUG_TOOLS=1 to also dump full schemas (name + description
// + parameters); left off by default since that's a lot of output per request.
function logTools(requestBody) {
  const tools = requestBody.tools
  if (!Array.isArray(tools) || tools.length === 0) return
  const names = tools.map((t) => t.function?.name ?? t.name ?? '?')
  log(`tools offered (${names.length}): ${names.join(', ')}`)
  if (process.env.DEBUG_TOOLS === '1') {
    log(`full schemas:\n${JSON.stringify(tools, null, 2)}`)
  }
}

function makeChunk({ id, created, model, delta, finishReason, usage }) {
  const chunk = {
    id,
    object: 'chat.completion.chunk',
    created,
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason ?? null }],
  }
  if (usage) chunk.usage = usage
  return `data: ${JSON.stringify(chunk)}\n\n`
}

// Rewrite a buffered SSE stream when the assistant produced a bare tool-call
// JSON object. Returns the rewritten stream, or null to pass through unchanged.
function rewriteStream(body, hadTools, allowedToolNames) {
  if (!hadTools) return null
  const lines = body.split('\n')
  let content = ''
  let id = ''
  let model = ''
  let created = 0
  let usage = null
  let toolCallSeen = false

  for (const line of lines) {
    if (!line.startsWith('data:')) continue
    const payload = line.slice(5).trim()
    if (payload === '[DONE]') continue
    let chunk
    try {
      chunk = JSON.parse(payload)
    } catch {
      continue
    }
    if (chunk.usage) usage = chunk.usage
    if (!chunk.choices || chunk.choices.length === 0) continue
    id ||= chunk.id
    model ||= chunk.model
    created ||= chunk.created
    const choice = chunk.choices[0]
    if (choice.delta?.content) content += choice.delta.content
    if (choice.delta?.tool_calls?.length) toolCallSeen = true
  }

  if (toolCallSeen) return null
  let toolCalls = parseToolCalls(content).filter(tc => allowedToolNames.has(tc.name))
  if (toolCalls.length === 0) {
    toolCalls = detectPlainTextCommand(content, allowedToolNames)
  }
  if (toolCalls.length === 0) {
    if (process.env.DEBUG_TOOLS === '1') {
      log(`skip rewrite: content not a bare tool-call object. content=${JSON.stringify(content)}`)
    } else {
      log(`skip rewrite: content not a bare tool-call object (len=${content.length})`)
    }
    return null
  }

  const base = { id: id || `chatcmpl-${Date.now()}`, created: created || Math.floor(Date.now() / 1000), model: model || 'ollama' }
  const out = [
    makeChunk({ ...base, delta: { role: 'assistant', content: '' } }),
    makeChunk({
      ...base,
      delta: {
        tool_calls: toolCalls.map((tc, index) => ({
          index,
          id: `call_${Math.random().toString(36).slice(2, 10)}`,
          type: 'function',
          function: { name: tc.name, arguments: tc.arguments },
        })),
      },
    }),
    makeChunk({ ...base, delta: {}, finishReason: 'tool_calls', usage }),
    'data: [DONE]\n\n',
  ]
  return out.join('')
}

// Rewrite a non-streamed JSON response the same way.
function rewriteJson(body, hadTools, allowedToolNames) {
  if (!hadTools || !body.choices?.length) return null
  const message = body.choices[0].message
  if (message?.tool_calls?.length) return null
  if (typeof message?.content !== 'string') return null
  let toolCalls = parseToolCalls(message.content).filter(tc => allowedToolNames.has(tc.name))
  if (toolCalls.length === 0) {
    toolCalls = detectPlainTextCommand(message.content, allowedToolNames)
  }
  if (toolCalls.length === 0) return null
  message.content = null
  message.tool_calls = toolCalls.map((tc) => ({
    id: `call_${Math.random().toString(36).slice(2, 10)}`,
    type: 'function',
    function: { name: tc.name, arguments: tc.arguments },
  }))
  body.choices[0].finish_reason = 'tool_calls'
  return body
}

const server = createServer(async (req, res) => {
  if (req.url !== '/v1/chat/completions') {
    res.statusCode = 404
    res.end('not found')
    return
  }
  let raw = ''
  try {
    for await (const chunk of req) raw += chunk
    const requestBody = JSON.parse(raw)
    const hadTools = Array.isArray(requestBody.tools) && requestBody.tools.length > 0
    const allowedToolNames = new Set((requestBody.tools ?? []).map(t => t.function?.name ?? t.name).filter(Boolean))
    const streaming = requestBody.stream === true

    logTools(requestBody)

    if (hadTools && wantsToolCall(requestBody) && Array.isArray(requestBody.messages)) {
      requestBody.messages = [...requestBody.messages, { role: 'system', content: TOOL_CALL_NUDGE }]
      raw = JSON.stringify(requestBody)
    }

    const upstream = await fetch(`${UPSTREAM}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': req.headers['content-type'] ?? 'application/json',
        ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
      },
      body: raw,
    })

    if (!upstream.ok) {
      res.statusCode = upstream.status
      res.end(await upstream.text())
      return
    }

    let rewrote = false
    if (streaming) {
      res.statusCode = upstream.status
      res.setHeader('content-type', 'text/event-stream')
      res.setHeader('cache-control', 'no-cache')
      if (!hadTools) {
        for await (const chunk of upstream.body) res.write(chunk)
        res.end()
      } else {
        const upstreamBody = await upstream.text()
        const rewritten = rewriteStream(upstreamBody, hadTools, allowedToolNames)
        rewrote = rewritten !== null
        res.end(rewritten ?? upstreamBody)
      }
    } else {
      const upstreamBody = JSON.parse(await upstream.text())
      const rewritten = rewriteJson(upstreamBody, hadTools, allowedToolNames)
      rewrote = rewritten !== null
      res.statusCode = upstream.status
      res.setHeader('content-type', 'application/json')
      res.end(JSON.stringify(rewritten ?? upstreamBody))
    }
    log(`${streaming ? 'stream' : 'json'} ${hadTools ? 'tools' : 'chat'} model=${requestBody.model ?? '?'}${rewrote ? ' rewrote=tool-call' : ''}`)
  } catch (error) {
    log(`error: ${String(error)}`)
    res.statusCode = 500
    res.end(JSON.stringify({ error: { message: String(error) } }))
  }
})

const isMain = import.meta.url === pathToFileURL(process.argv[1] ?? '').href
if (isMain) {
  server.listen(PORT, '127.0.0.1', () => {
    log(`listening on http://127.0.0.1:${PORT} -> ${UPSTREAM}`)
  })
}

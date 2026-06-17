# `explore` MCP tool — subagent workaround for weak local models

**Date:** 2026-06-17
**Status:** approved (design), implementing

## Problem

Lean mode trims `Task` out of the tool set. We tried re-admitting it
(`LLMM_SUBAGENTS=1`) to let the model isolate exploration in a fresh subagent
context. It works mechanically (the tool is reachable under `--bare`), but
Qwen3-Coder-Next **will not emit `Task` calls** — orchestration/delegation is
absent from its fine-tuning. It narrates "I'll use Task" then calls `Read`
instead, or confabulates a config step to "enable" it. Prompt hardening (top
placement + a literal worked example) got it to *talk* about `Task` but never
to *call* it.

The model **does** reliably call MCP tools (it proactively calls the scratchpad
`checkpoint`/`recall` — request/response shape it has seen). So we expose the
exploration capability through the channel it actually uses: an MCP tool.

## Design

A stdio MCP server `explore_server.py` exposing one tool:

```
explore(question: str, paths: list[str] = []) -> str
```

v1 = **hint-guided read + one summary call** (fork 1 = A):

1. If `paths` is given, expand them (files/globs, relative to repo root) and
   read them. Otherwise extract salient terms from `question` and grep the repo
   (`rg`, falling back to `grep -rIl`) for matching files.
2. Concatenate the matches under a char budget (≤8 files, ≤4K chars/file,
   ≤14K total) — these bulky tokens live **only in the server process**.
3. Make **one** `/v1/chat/completions` call to the already-running llama-server
   (`http://127.0.0.1:$LLMM_PORT`, model `$alias`) asking for a concise 3–5 line
   answer that cites file paths.
4. Return the answer, capped at ~1600 chars.

Net effect: the main session spends a tiny tool call + a short answer instead of
loading many files into its small window — the context-isolation benefit of a
subagent, through a channel the model will use.

### Server topology (fork 2 = A)

A **separate** `explore_server.py`, distinct from `scratchpad_server.py`.
Single responsibility; explore needs `--base-url`/`--model` the scratchpad
doesn't; scratchpad stays untouched and always-on. Both are listed in the same
per-session `.llmm/mcp.<id>.json`, each conditionally.

### `LLMM_SUBAGENTS` semantics (mutually exclusive)

- `0` (default) → wire `explore` into `mcp.json`; prepend `prompts/lean-explore.md`
  to the lean prompt. No `Task`.
- `1` → add `Task` to `--tools`; prepend `prompts/lean-subagent.md`. No `explore`.

The scratchpad MCP wiring is decoupled from the `--mcp-config` flag so explore
can be active even when `LLMM_SCRATCHPAD=0` (and vice-versa). `--settings`
(Stop/SessionStart hooks) remains scratchpad-only.

### Calling the local model

llama-server is launched with `--jinja` and serves the OpenAI-compatible
`/v1/chat/completions`. explore POSTs there with `"model": "<alias>"`. The main
generation is paused awaiting the tool result and `--parallel 1` serialises
requests, so the second in-flight call is safe. On connection failure/timeout
explore returns a short "unavailable; read files yourself" message so the model
can fall back rather than the tool crashing.

## Out of scope (possible v2)

- Fork-1 option B: a fully isolated sub-session (`explore` spawns its own
  `claude --bare` with Read/Grep/Glob). Heavyweight; revisit only if v1's
  keyword/hint retrieval proves too shallow.
- Embedding/semantic retrieval instead of keyword grep.

## Verification

- `explore_server.py` imports and the tool runs against a stub endpoint.
- `claude::write_mcp_json` emits valid JSON with the right servers for each
  `(scratchpad, explore)` combination.
- Launch wiring: default lean wires `explore` + prepends `lean-explore.md`;
  `LLMM_SUBAGENTS=1` wires `Task` + `lean-subagent.md` and drops `explore`;
  `LLMM_SCRATCHPAD=0` drops `--settings` but keeps `--mcp-config` (explore).

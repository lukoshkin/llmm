# `explore` MCP tool — subagent workaround for weak local models

**Date:** 2026-06-17
**Status:** validated — shipped and confirmed live. The local Qwen3-Coder-Next emits
`explore` calls on its own (unlike `Task`) and passes sensible `paths` hints unprompted;
the server returns an accurate summary.

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

## v2 — agent mode (implemented; not yet validated live)

Fork-1 option B is available behind `LLMM_EXPLORE_MODE=agent` (default
`retrieval`). The mode is transparent to the caller — the `explore(question,
paths)` signature is unchanged — and only switches the server's strategy:

- `retrieval` (v1): gather + one summary call, as above.
- `agent` (v2): spawn a nested headless `claude -p` in the repo root with
  `--bare --strict-mcp-config --output-format text --tools Read Grep Glob
  --permission-mode default` and a terse read-only explorer system prompt, env
  pointed at the local server. The local model drives its own tool loop in an
  isolated process; stdout is captured and capped.

The `claude` path is resolved at launch (where PATH is known) and baked into the
explore server's `mcp.json` args (`--mode`, `--claude-bin`).

### Safety / robustness (added after code review)

- **Never reaches the real API.** Routing is by `ANTHROPIC_BASE_URL`; the child
  env forces the local server plus dummy creds (`ANTHROPIC_API_KEY=llama-cpp`).
  A `_is_loopback()` guard refuses to spawn unless the base URL is
  `127.0.0.1`/`localhost`/`::1`/`0.0.0.0` — a misconfig fails closed (falls back
  to retrieval), it can never silently call `api.anthropic.com`.
- **Read containment.** `--permission-mode default` (not `bypassPermissions`):
  in headless `-p` there is no prompt to answer, so reads outside the working dir
  are denied while in-repo reads proceed — confining the child to `ROOT` without
  a hard allowlist. `default` mode replacing `bypass` still needs **live
  confirmation** that in-repo reads actually proceed unattended (the open item
  below). Agent mode additionally refuses to run when `ROOT` is `$HOME` or `/`.
- **No recursion.** `--strict-mcp-config` with no `--mcp-config` → the child has
  no MCP servers, so `explore` cannot re-arm itself.
- **Timeout coordination.** `AGENT_TIMEOUT=240s` is kept below the parent's MCP
  tool-call timeout, which llmm raises to `MCP_TOOL_TIMEOUT=300000` in
  `claude::launch`, so the child is reaped before the parent abandons the call
  and leaves an orphan on the single `--parallel 1` slot. (No `--max-turns` in
  this CLI build, so the subprocess timeout is the only bound.)
- **Diagnosable, not silent.** Every fallback path logs a one-line reason (and a
  stderr tail on nonzero exit) to the server's stderr via `_log()`, so a dead or
  degraded agent mode is visible in Claude Code's MCP logs instead of masquerading
  as working retrieval.

### Open items to confirm on real hardware

1. Does `--permission-mode default` let the headless child read in-repo files
   unattended? If it instead denies/stalls, switch to `bypassPermissions` plus a
   generated `--settings` deny rule for paths outside `ROOT`.
2. Does the local model sustain a useful multi-step Read/Grep/Glob loop end to
   end, or stall? This is the capability question agent mode exists to answer.

Rationale for trying it: the `Task` failure was the model refusing to *emit a
delegation call*; inside the sub-session it only needs to *use read tools*, which
it does.

## Out of scope

- Embedding/semantic retrieval instead of keyword grep.

## Verification

- `explore_server.py` imports and the tool runs against a stub endpoint.
- `claude::write_mcp_json` emits valid JSON with the right servers for each
  `(scratchpad, explore)` combination.
- Launch wiring: default lean wires `explore` + prepends `lean-explore.md`;
  `LLMM_SUBAGENTS=1` wires `Task` + `lean-subagent.md` and drops `explore`;
  `LLMM_SCRATCHPAD=0` drops `--settings` but keeps `--mcp-config` (explore).

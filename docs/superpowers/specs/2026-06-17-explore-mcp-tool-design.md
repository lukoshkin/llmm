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
  --permission-mode bypassPermissions` and a forceful read-only explorer system
  prompt, env pointed at the local server. The local model drives its own tool
  loop in an isolated process; stdout is captured and capped.

The `claude` path is resolved at launch (where PATH is known) and baked into the
explore server's `mcp.json` args (`--mode`, `--claude-bin`).

### Safety / robustness (added after code review)

- **Never reaches the real API.** Routing is by `ANTHROPIC_BASE_URL`; the child
  env forces the local server plus dummy creds (`ANTHROPIC_API_KEY=llama-cpp`).
  A `_is_loopback()` guard refuses to spawn unless the base URL is
  `127.0.0.1`/`localhost`/`::1`/`0.0.0.0` — a misconfig fails closed (falls back
  to retrieval), it can never silently call `api.anthropic.com`.
- **Read containment (weakened tradeoff).** Started on `--permission-mode
  default` (headless = no prompt → out-of-repo reads denied), but the first live
  run showed the child never reached a read at all (see finding below), so it was
  switched to `bypassPermissions` to let the read-only tools run unattended. That
  removes v1's hard `_in_root` confinement: `Read` can take absolute paths outside
  `ROOT`. The remaining limits are the loopback + `$HOME`/`/` guards and the
  local-only model. A settings-based read deny-rule is the follow-up if agent mode
  is kept.
- **No recursion.** `--strict-mcp-config` with no `--mcp-config` → the child has
  no MCP servers, so `explore` cannot re-arm itself.
- **Timeout coordination.** The MCP tool-call timeout was **observed at 120s** and
  not raised by `MCP_TOOL_TIMEOUT=300000` (kept best-effort), so `AGENT_TIMEOUT` is
  set to **90s — below 120s** — as the real bound: the child is reaped and we fall
  back to retrieval before the parent abandons the call and leaves an orphan on the
  single `--parallel 1` slot. (No `--max-turns` in this CLI build.)
- **Diagnosable, not silent.** Every fallback path logs a one-line reason (and a
  stderr tail on nonzero exit) to the server's stderr via `_log()`, so a dead or
  degraded agent mode is visible in Claude Code's MCP logs instead of masquerading
  as working retrieval.

### Live run #1 finding (2026-06-17)

The premise — "inside the sub-session it only needs to *use* read tools, which it
does" — did **not** hold on the first run. The nested model returned a narrated
`Task(...)` code block as text instead of calling Grep/Glob/Read — reproducing the
exact Task-refusal that killed the built-in `Task` approach, now one level down. It
never reached a read (so permission mode was moot), and the parent killed the call
at the 120s MCP timeout. Fixes applied for run #2: `AGENT_TIMEOUT=90` (clean
fallback under the 120s ceiling); a much more forceful system prompt ("there is NO
Task tool; your first action must be a real Grep/Glob call, never narrate");
`bypassPermissions` to remove the read-permission variable.

### Open items

1. Does the hardened prompt get the nested model to actually call Grep/Glob/Read
   instead of narrating `Task(...)`? If run #2 still narrates, agent mode is a dead
   end for this model and retrieval stays the only strategy.
2. If reads do happen, add a settings-based deny-rule to restore `_in_root`-grade
   containment under `bypassPermissions`.

## Out of scope

- Embedding/semantic retrieval instead of keyword grep.

## Verification

- `explore_server.py` imports and the tool runs against a stub endpoint.
- `claude::write_mcp_json` emits valid JSON with the right servers for each
  `(scratchpad, explore)` combination.
- Launch wiring: default lean wires `explore` + prepends `lean-explore.md`;
  `LLMM_SUBAGENTS=1` wires `Task` + `lean-subagent.md` and drops `explore`;
  `LLMM_SCRATCHPAD=0` drops `--settings` but keeps `--mcp-config` (explore).

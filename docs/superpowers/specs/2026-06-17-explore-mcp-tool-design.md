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
  --permission-mode default --settings <repo-confined allow-list>` and a forceful
  read-only explorer system prompt, env pointed at the local server. The local
  model drives its own tool loop in an isolated process; stdout is captured and
  capped.

The `claude` path is resolved at launch (where PATH is known) and baked into the
explore server's `mcp.json` args (`--mode`, `--claude-bin`).

### Safety / robustness (added after code review)

- **Never reaches the real API.** Routing is by `ANTHROPIC_BASE_URL`; the child
  env forces the local server plus dummy creds (`ANTHROPIC_API_KEY=llama-cpp`).
  A `_is_loopback()` guard refuses to spawn unless the base URL is
  `127.0.0.1`/`localhost`/`::1`/`0.0.0.0` — a misconfig fails closed (falls back
  to retrieval), it can never silently call `api.anthropic.com`.
- **Read containment.** `--permission-mode default` + a generated `--settings`
  allow-list scoping **all three** read tools to `ROOT`
  (`Read(<ROOT>/**)`, `Grep(<ROOT>/**)`, `Glob(<ROOT>/**)` — Grep/Glob also take a
  path, so leaving them unscoped would let the model search/enumerate outside the
  repo). In headless `-p` there is no prompt, so calls under `ROOT` are
  pre-approved while anything outside is unmatched → denied. A hallucinated
  absolute path (the model guesses training-data paths like `/Users/danny/…`) is
  denied rather than read. Plus the loopback + `$HOME`/`/` guards. The exact
  path-specifier syntax is unverified (open item) but fails **safe**: wrong syntax
  → unmatched → denied, never open.
- **No recursion.** `--strict-mcp-config` with no `--mcp-config` → the child has
  no MCP servers, so `explore` cannot re-arm itself.
- **Bounded under the 120s ceiling.** The MCP tool-call timeout is **observed at
  120s** and not raised by `MCP_TOOL_TIMEOUT` (kept best-effort). The whole
  `explore()` call must finish under it *including* a retrieval fallback, so two
  enforced timeouts bound it: `AGENT_TIMEOUT=70s` (subprocess kill) +
  `AGENT_FALLBACK_ASK_TIMEOUT=35s` (fallback HTTP) + overhead ≈ 110s < 120s. (No
  `--max-turns` in this CLI build, so the subprocess timeout is the turn bound.)
- **Diagnosable, not silent.** Every fallback path logs a one-line reason (and a
  stderr tail on nonzero exit) to the server's stderr via `_log()`.

### Live findings (2026-06-17)

Across several real runs the nested model is **high-variance**, not a flat
failure:

- **Worked:** one call read the real files (`README.md`, `lib/server.zsh`,
  `lib/claude.zsh`, hooks, `install.sh`, …) and produced an accurate, file-citing
  answer in **64s** — finishing on its own under the cap.
- **Failed:** other calls narrated a `Task(...)` block as text (the same refusal
  that killed built-in `Task`), or looped on a bad path until the timeout.
- **Recurring quirk:** it guesses absolute training-data paths
  (`/Users/danny/…`, `/usr/local/google/…`) before recovering — the motivation
  for both the repo-confined allow-list and the "use relative paths, never Read a
  directory, be efficient (~8 calls)" prompt hardening.

Conclusion: agent mode is viable but unreliable and slow; `retrieval` stays the
default and agent mode is an opt-in experiment.

**Why the `Task(...)`-as-text reflex (and the prompt fix).** The model never
actually *invokes* `Task` — it emits `Task(...)` as plain **text**, because the
structured tool-call format for `Task` was never in its fine-tuning (only the
textual shape was). Crucially, the only place "Task" reached the nested session
was *our own* system prompt forbidding it ("there is NO Task tool, never write
`Task(...)`") — and on a 3B-active model, naming the token primes it more than the
negation suppresses it ("don't think of an elephant"). The sub-agent prompt was
rewritten **purely positive**, naming only Grep/Glob/Read and containing no
"Task"/"subagent"/"never" vocabulary at all, to stop feeding the cue. Expected to
reduce — not necessarily eliminate — the reflex, since "explore the codebase" is
itself a trigger.

### Open items

1. Does the repo-confined allow-list (`--permission-mode default` + `--settings`)
   actually let in-repo `Read`/`Grep`/`Glob` proceed unattended in headless `-p`?
   If they get denied (symptom: agent always returns empty → falls back), the
   path-specifier syntax for one of the three tools is wrong — adjust it, or fall
   back to an OS sandbox (`sandbox-exec`) binding only `ROOT` readable. Per-tool
   scoping for Grep/Glob in particular is unverified.
2. Can the 120s MCP tool-call ceiling be raised at all (right env var / per-server
   `timeout`)? If yes, give the agent more room; if not, it stays fallback-heavy.

## Out of scope

- Embedding/semantic retrieval instead of keyword grep.

## Verification

- `explore_server.py` imports and the tool runs against a stub endpoint.
- `claude::write_mcp_json` emits valid JSON with the right servers for each
  `(scratchpad, explore)` combination.
- Launch wiring: default lean wires `explore` + prepends `lean-explore.md`;
  `LLMM_SUBAGENTS=1` wires `Task` + `lean-subagent.md` and drops `explore`;
  `LLMM_SCRATCHPAD=0` drops `--settings` but keeps `--mcp-config` (explore).

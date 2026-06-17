# Context Management for Weak Local LLMs — Design Spec

**Date:** 2026-06-17
**Status:** Revised after spec review — bug fixes + sectioned scratchpad + opt-in subagents

**Phasing:**
- **Phase 1 (core, this spec's body):** scratchpad MCP (`checkpoint`/`recall`) + Stop hook +
  SessionStart compact recovery + opt-in `Task` subagents.
- **Phase 2:** PostToolUse tool-output truncation (`updatedToolOutput`).
- **Phase 3+:** temperature/sampling config, `--cache-reuse`, repo-map priming, re-read
  suppression.

## Context

Weak local LLMs (e.g. Qwen3-Coder-Next) have a ~67K practical context ceiling before
autocompaction. They take more iterations to reach conclusions than Sonnet/Opus, burning
tokens on wasteful preprocessing and Q&A loops. When compaction fires, the LLM restarts
nearly blind — losing all intermediate findings. The current workaround (user manually
warning the LLM at ~90% context) is fragile: the LLM often ignores it or is already past
the threshold.

**Goal:** Automate context preservation with zero user intervention, using four mechanisms:
a Stop hook for threshold detection, a sectioned-scratchpad MCP server (`checkpoint` +
`recall`) for structured saves and on-demand reads, a SessionStart compact hook that
re-injects only the always-on sections, and opt-in `Task` subagents that run bounded
exploration in an isolated context window so it never bloats the main session.

---

## Architecture

```
llmm launch
  ├── generates LLMM_SESSION_ID (timestamp: 20260617_143201)
  ├── writes .llmm/hooks.json   (session ID + max tokens baked in)
  ├── writes .llmm/mcp.json     (session ID baked in)
  └── invokes: claude --bare --settings .llmm/hooks.json --mcp-config .llmm/mcp.json ...

Every turn ends
  └── Stop hook fires (lib/hooks/stop.sh)
        ├── reads transcript JSONL → gets last input_tokens
        └── if tokens > LLMM_SCRATCHPAD_PCT% of CLAUDE_CODE_MAX_CONTEXT_TOKENS:
              returns additionalContext: "CHECKPOINT REQUIRED: context at X%."

LLM discovers something  OR  receives CHECKPOINT REQUIRED
  └── calls checkpoint(section, content, mode) MCP tool
        └── scratchpad_server.py merges into one section of .llmm/{session_id}.md
  └── (on demand) calls recall(section)
        └── returns just that section's body — no whole-file dump

Autocompaction fires → new session starts
  └── SessionStart hook (compact matcher) fires (lib/hooks/session_start.sh)
        └── echoes ONLY ## Status + ## Open questions → injected into context
              (other sections pulled later via recall)

Optional: bounded read-only exploration
  └── main session calls Task (general-purpose subagent)
        └── subagent burns exploration tokens in ITS OWN window,
            returns a short conclusion → main session checkpoint()s it
```

**Key fact:** `--bare` disables auto-discovery only. Explicitly passed `--settings` and
`--mcp-config` are still loaded. This is how we re-enable just these two pieces without
pulling in the full superpowers framework.

---

## Scratchpad Format

File: `.llmm/<session_id>.md` (persists in project dir across sessions, not deleted on exit).
Section headers are **stable, fixed `## ` lines** so the server splits sections by header in
pure Python — no jq, no fragile parsing. The six headers are a closed set.

```markdown
## Task
One-line: what we're doing and why          ← replace-mode, always injected

## Status
Current step. What the next action is.       ← replace-mode, always injected

## Findings
- path/to/file:line — what it does           ← append-mode, on-demand (recall)

## Decisions
- Chose A over B because [constraint]         ← append-mode, on-demand

## Dead ends
- Tried X — doesn't work because Y            ← append-mode, on-demand

## Open questions
- Does Z handle edge case W?                  ← append-mode, always injected
```

**Always-on vs on-demand.** `Task` + `Status` + `Open questions` are small and define
"where am I, what's next, what's unresolved" — the SessionStart compact hook re-injects
exactly these after compaction. `Findings` / `Decisions` / `Dead ends` can grow large, so
they are *not* auto-injected; the model (or the user) pulls them with `recall(section)`
when relevant. This keeps post-compaction recovery cheap while leaving full detail
retrievable.

The **Dead ends** section is the highest-value on-demand section: without it the LLM
re-explores the same wrong paths, re-burning tokens. Direct the model to `recall("dead_ends")`
before any retry.

---

## Components

### New files

**`lib/hooks/stop.sh`** — Stop hook (~45 lines shell):
- Read hook JSON from stdin with `jq`.
- **Loop guard (bug #1):** if `stop_hook_active == true` in the input, emit nothing and
  exit 0. A Stop hook that returns `additionalContext` *blocks the stop and forces Claude
  to continue*; without this guard it re-fires every turn above threshold → infinite loop.
- Extract `transcript_path`; read the **last** record's `usage.input_tokens` without
  slurping the whole file (bug #7 — `jq -s` is O(n) per turn, O(n²) per session):
  ```sh
  tokens=$(tail -n 50 "$transcript_path" | jq -r 'select(.usage.input_tokens?) | .usage.input_tokens' | tail -n1)
  ```
  (Scan the tail; the assistant message with usage is among the last records.)
- Compare against `$CLAUDE_CODE_MAX_CONTEXT_TOKENS` × `$LLMM_SCRATCHPAD_PCT`%.
- If above threshold, write to stdout:
  ```json
  {"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "CHECKPOINT REQUIRED: context at X%. Call checkpoint(section,content,mode) for any unsaved Findings/Decisions/Dead ends/Status now, before any other action."}}
  ```
- Exit 0 in all cases (non-blocking).

**`lib/hooks/session_start.sh`** — SessionStart compact hook (~15 lines shell):
- Accept session ID as `$1`; read `.llmm/$1.md` from `$LLMM_CWD` (or current dir).
- Echo **only the `## Status` and `## Open questions` sections** to stdout (awk between
  headers), not the whole file — keeps recovery cheap. Append a one-line hint:
  "Other sections available via recall(findings|decisions|dead_ends)."
- If the file doesn't exist, exit silently.

**`lib/hooks/scratchpad_server.py`** — MCP server (~90 lines Python):
- Uses `mcp` package (single dep). Accepts `--session-id` and `--scratchpad-dir`.
- Section model: the six fixed headers above; split/join file by `^## ` lines.
- **Tool `checkpoint(section, content, mode)`** — `section` is one of the six (validated);
  `mode` is `append` (default) or `replace`. `append` adds `content` as new line(s) under
  the section; `replace` swaps the section body. Read-modify-write a single section — the
  model never re-sends the whole scratchpad (bug #2). Creates the file with all six empty
  headers on first call. Terse description: "Save progress to one scratchpad section.
  mode=append for findings/decisions/dead_ends/open_questions, replace for task/status."
- **Tool `recall(section)`** — returns just that section's body (or the section list if
  given an unknown/empty arg). Terse description: "Read one scratchpad section on demand
  (e.g. dead_ends before retrying)."
- Both tool descriptions kept tight to bound MCP context cost (~target <500 tokens total).

### Changed files

**`config.default.zsh`** — add three knobs:
```zsh
LLMM_SCRATCHPAD=1        # enable scratchpad system in lean mode (default on)
LLMM_SCRATCHPAD_PCT=85   # % of context window that triggers CHECKPOINT REQUIRED
LLMM_SUBAGENTS=0         # re-admit the Task tool for isolated exploration (default off)
```
Note `LLMM_SCRATCHPAD_PCT` must sit *below* Claude Code's autocompaction trigger so the
checkpoint fires before compaction (see Open Implementation Risks).

**`lib/claude.zsh`** (`claude::launch` function) — when lean mode + `LLMM_SCRATCHPAD=1`:
1. `LLMM_SESSION_ID=$(date +%Y%m%d_%H%M%S)`
2. `mkdir -p .llmm`
3. Generate `.llmm/hooks.json`:
   ```json
   {
     "hooks": {
       "Stop": [{"hooks": [{"type": "command", "command": "LLMM_SESSION_ID=<id> LLMM_SCRATCHPAD_PCT=<pct> CLAUDE_CODE_MAX_CONTEXT_TOKENS=<n> LLMM_CWD=<cwd> <hooks_dir>/stop.sh"}]}],
       "SessionStart": [{"matcher": "compact", "hooks": [{"type": "command", "command": "<hooks_dir>/session_start.sh <id>"}]}]
     }
   }
   ```
4. Generate `.llmm/mcp.json`. Invoke through `uv run --with mcp` so the `mcp` import
   resolves in an ephemeral env (bug #3 — `uv tool install mcp` makes an isolated CLI, not
   an importable module for a bare `python3`):
   ```json
   {
     "mcpServers": {
       "scratchpad": {
         "command": "uv",
         "args": ["run", "--with", "mcp", "python3", "<hooks_dir>/scratchpad_server.py", "--session-id", "<id>", "--scratchpad-dir", "<cwd>/.llmm"]
       }
     }
   }
   ```
5. Tool list: base lean tools + the scratchpad MCP. If `LLMM_SUBAGENTS=1`, add `Task` to
   `--tools` so the model can spawn an isolated exploration subagent.
6. Append to claude invocation: `--settings .llmm/hooks.json --mcp-config .llmm/mcp.json`
7. **Concurrency (bug #6):** namespace the generated configs per session —
   `.llmm/hooks.<id>.json` / `.llmm/mcp.<id>.json` — so a second session in the same repo
   doesn't clobber the first, and the `trap` only removes its own. Use a finer session id
   (e.g. `date +%Y%m%d_%H%M%S`-plus-`$$`) to avoid 1-second collisions.
8. `trap 'rm -f .llmm/hooks.<id>.json .llmm/mcp.<id>.json' EXIT` (scratchpad `.md` stays).

**`prompts/lean-coder.md`** — append after the existing tool-use rules:
```
- checkpoint(section, content, mode): after each significant finding, save it to the
  matching scratchpad section (findings/decisions/dead_ends/open_questions use mode=append;
  task/status use mode=replace). Save one section per call; never re-send the whole pad.
  On a CHECKPOINT REQUIRED message, save all unsaved progress before any other action.
- recall(section): pull a section back when you need it — especially recall("dead_ends")
  before retrying an approach, so you don't repeat a known failure.
```
If `LLMM_SUBAGENTS=1`, also append:
```
- Task: for a bounded read-only investigation, dispatch a subagent. It explores in its own
  context and returns a short answer — keeping your window clean. Record its conclusion with
  checkpoint(). Use only for self-contained lookups, not for edits.
```

### Subagent re-admission (`Task`) — opt-in, `LLMM_SUBAGENTS=1`

Adds `Task` back to the lean `--tools` set. Value: a bounded exploration runs in the
subagent's *own* context window; only the conclusion returns to the main session, which
`checkpoint`s it — exploration tokens never bloat the main window. This is the
poor-man's-subagent pattern lean mode dropped.

Caveats / risks:
- The subagent is the **same local model** sharing the same ~67K ceiling and is slow — fine
  for "find/where/which" lookups, not for long edit sequences.
- Under `--bare`, agent auto-discovery is off. `Task` must fall back to the built-in
  `general-purpose` agent — **verify it's available under `--bare`** before relying on it;
  if not, this knob is inert and the spec degrades gracefully (scratchpad still works).
- `Task`'s tool description adds ~1–2K tokens; worth it only when it displaces larger
  exploration. Default off for that reason.

### Dependency: `mcp` Python package

`scratchpad_server.py` imports `mcp`. Invoke via `uv run --with mcp python3 …` (see
`mcp.json` above) so the dep resolves in an ephemeral env on each launch — no global install,
no project-dep pollution, consistent with the project's `uv tool run` convention. `install.sh`
only needs to ensure `uv` is present (it already does for the toolchain).

### `.gitignore`

`install.sh` (or first `llmm` run) appends `.llmm/` to the project `.gitignore` if absent.
Scratchpad files are ephemeral session state, not project history.

---

## Verification

1. **Smoke test:** `llmm` in any project → confirm `.llmm/hooks.<id>.json` +
   `.llmm/mcp.<id>.json` exist during session, deleted on exit, `.llmm/<id>.md` absent until
   first checkpoint call. Launch a second session in the same repo concurrently → confirm
   neither clobbers the other's config (bug #6).

2. **Checkpoint merge:** Call `checkpoint("findings", "...", "append")` twice → confirm both
   lines persist under `## Findings` (no overwrite, bug #2). Call
   `checkpoint("status", "...", "replace")` → confirm `## Status` body is swapped, other
   sections untouched.

3. **Recall:** Call `recall("dead_ends")` → confirm it returns only that section's body, not
   the whole file.

4. **Threshold trigger + loop guard:** Set `LLMM_SCRATCHPAD_PCT=1` → confirm next turn's
   Stop hook returns `CHECKPOINT REQUIRED`. Then confirm it does **not** re-fire endlessly:
   with `stop_hook_active=true` the hook emits nothing (bug #1).

5. **Compact recovery:** Invoke `lib/hooks/session_start.sh <id>` → confirm it echoes **only**
   `## Status` + `## Open questions` (not Findings/Decisions/Dead ends). Trigger a real
   compaction and confirm the resumed context contains those sections plus the recall hint.

6. **Subagent isolation (if `LLMM_SUBAGENTS=1`):** confirm `Task` appears in the tool list and
   resolves to `general-purpose` under `--bare`; dispatch a lookup and confirm the main
   transcript gains only the short conclusion, not the subagent's intermediate steps. If
   `Task` is unavailable under `--bare`, confirm the session still runs (knob inert).

7. **End-to-end:** Run a real lean session through an autocompaction event. Check `.llmm/<id>.md`
   has meaningful sectioned findings and the resumed session references Status/Open questions
   and can `recall` the rest.

---

## Open Implementation Risks

- **JSONL token field path:** `usage.input_tokens` is the assumed field for the last-message
  token count in Claude Code's transcript format. Verify against an actual transcript before
  finalizing `stop.sh`; adjust the `jq` filter if the schema differs.
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` availability:** confirmed set by llmm lean mode; the
  Stop hook command bakes it in explicitly so it's available regardless of hook env
  inheritance.
- **Autocompaction trigger point (`LLMM_SCRATCHPAD_PCT` calibration):** the scheme only works
  if 85% fires before Claude Code compacts. The README notes autocompaction floors near 100K
  with a ~33% reserve, so the effective trigger relative to `CLAUDE_CODE_MAX_CONTEXT_TOKENS`
  must be measured once on a real session and `LLMM_SCRATCHPAD_PCT` set safely below it.
- **`Task` under `--bare`:** unverified whether the built-in `general-purpose` agent is
  reachable when agent auto-discovery is disabled. Verify before depending on `LLMM_SUBAGENTS`;
  the rest of the spec is independent of it.
- **Stop hook forces an unattended turn (intentional):** because returning `additionalContext`
  blocks the stop, hitting the threshold makes Claude auto-continue and checkpoint *without*
  the user's next message. This is the desired safety behavior, stated here so it isn't
  mistaken for a bug.

## Phase 2 — Tool-output truncation (PostToolUse)

Huge tool results are the biggest silent context-killer on a 67K window — a `Read` of a
2000-line file, a `Grep` with 500 hits, a `cat` of a lockfile. Claude Code's
`hookSpecificOutput.updatedToolOutput` (now supported for **all** tools, not just MCP)
*replaces what Claude sees* while the tool's real effects/telemetry are preserved. This
stops bloat at the source rather than recovering from it — plausibly a bigger win than the
scratchpad. Reuses the per-session `hooks.<id>.json` this spec already generates.

**Wiring** — add to the generated hooks file:
```json
"PostToolUse": [{"matcher": "Read|Bash|Grep|Glob",
  "hooks": [{"type": "command", "command": "<hooks_dir>/truncate.py"}]}]
```

**`lib/hooks/truncate.py`** — pure stdlib (no `mcp` dep, runs under bare `python3`):
- Read hook JSON on stdin (`tool_name`, `tool_input`, `tool_response`).
- Measure response size (lines + bytes). Under threshold → emit nothing, exit 0 → Claude
  sees the original untouched.
- Over threshold → emit `hookSpecificOutput.updatedToolOutput` with a **head + tail** slice
  and a middle elision marker that tells the model how to get the rest:
  `… ✂ 1,840 lines elided. Re-read this region with Read(offset, limit), or narrow with Grep.`

**Per-tool output shaping** (replacement must match the original shape exactly):
- **Bash** → `{stdout, stderr, interrupted, isImage}`; truncate `stdout`, keep `stderr`
  whole (errors are small and matter); leave non-zero-exit output intact.
- **Read** → numbered-line string; slice by lines, preserve line numbers so the `offset`
  advice is accurate.
- **Grep** → keep first N matches, append `… +M more matches; add a tighter pattern/path`.
- **Glob** → keep first N paths.
- **Never touch:** images (`isImage`) and anything already small.

**Config** (`config.default.zsh`):
```zsh
LLMM_TRUNCATE=1               # enable PostToolUse truncation (lean only)
LLMM_TRUNCATE_MAX_LINES=200   # over this, head+tail slice kicks in
LLMM_TRUNCATE_HEAD=120
LLMM_TRUNCATE_TAIL=40
```

**Risk — per-tool shapes (verify before enabling beyond Bash):** only Bash's output shape
is documented (`{stdout, stderr, interrupted, isImage}`). Read/Grep/Glob shapes are not; a
mismatched `updatedToolOutput` may be rejected. Implementation step zero: dump a real
transcript's `tool_response` for each tool and shape the replacement to match. Until
confirmed per tool, gate truncation to **Bash only** (known-safe) and expand incrementally.

**Caveat — blind edits:** truncating a `Read` could tempt the model to `Edit` a string from
the elided region. The elision marker must say "re-read the exact region with
Read(offset, limit) before editing it"; the lean prompt's existing read-before-edit rule
backs this up.

**Verification:**
1. `Read` a >2000-line file → confirm Claude's context gets head+tail+marker, not the whole
   file; confirm the file on disk is unchanged.
2. `Grep` with hundreds of hits → confirm first-N + "+M more" marker.
3. A small `Read`/`Bash` → confirm output passes through untouched (hook emits nothing).
4. `Bash` returning a non-zero exit with short stderr → confirm stderr is preserved intact.
5. Shape check: confirm Claude Code accepts each tool's `updatedToolOutput` without error
   (this is the gate for enabling Read/Grep/Glob beyond Bash).

## Phase 3+ — Out of scope for now (roadmap `## Later`)

These improve weak-model operation but are separate from context management. Add a config
knob for each (e.g. `LLMM_TEMP`, `LLMM_SAMPLING_*`, `LLMM_CACHE_REUSE`, `LLMM_REPO_MAP`).

- **Temperature + sampling configuration (#8):** expose sampling via config and pass to
  `server::build_args`. Two tiers:
  - *Pin-able today:* `top_k` / `min_p` / `repeat_penalty` — Claude Code does **not** send
    these, so a server default applies. Low values cut invalid-tool-call retries.
  - *Temperature caveat:* Claude Code sends `temperature` per request, and llama.cpp honors
    the request value over the server `--temp` default — so a server-side `LLMM_TEMP` may be
    ignored. Follow-up must first verify whether Claude Code actually sends it on this path;
    if so, pin it via a thin local proxy that clamps/overrides the field before forwarding to
    llama.cpp (the same proxy could inject Anthropic-style cache hints). Don't claim
    server-side temp works until measured.
- **`--cache-reuse` (#10):** add to the server args for partial KV reuse after mid-prompt
  edits; the single-slot prefix cache already gives free reuse for a byte-stable prefix.

- **Repo-map / context priming (#7) — flagged important:** a weak model burns many early
  turns just learning the repo layout. Generate a compact map once and inject it so those
  discovery iterations drop to ~zero.
  - *Two authors, one format.* The map can be authored two ways, and the consumer side must
    treat both identically:
    1. **Strong-model-authored** — a capable paid model (Opus/Sonnet in a normal session)
       composes a high-quality map once; far better than anything the local model produces.
    2. **llmm-generated** — a cheap local pass for when no strong-model map exists:
       `git ls-files` + `tree -L 2` for structure, plus a one-line purpose per key file (top
       docstring/comment, or `ctags` symbols).
    Both write the **same canonical artifact** (`.llmm/repo-map.md`) with the same section
    layout, so the injection path is author-agnostic — it reads the file, never cares who
    wrote it. Define the format once (a fixed header skeleton both producers fill) so a
    strong-model map and a local map are drop-in interchangeable.
  - *Don't clobber the better map.* Auto-generation only runs when `.llmm/repo-map.md` is
    absent (or on explicit `llmm --remap`). A strong-model-authored map is never overwritten
    by the cheap pass. A small frontmatter marker (e.g. `source: strong | source: llmm`)
    records provenance and protects a hand/strong map from auto-regen; `--remap` forces a
    local rebuild regardless.
  - *Cost cap:* whichever author, cap output (~150 lines / ~2K tokens) so priming never costs
    more than it saves.
  - *Injection:* reuse the SessionStart hook path — emit the map on `startup`/`resume`
    matchers (not just `compact`), alongside the scratchpad's Status section.
  - *Caching + staleness:* project-dir scoped like the scratchpad. For an llmm-generated map,
    regenerate when stale (mtime older than newest tracked file). A strong-model map is
    treated as authoritative and only refreshed on explicit `--remap`.
  - *Open question for its own design pass:* granularity (whole repo vs. just the subtree the
    task touches) and whether to let the model request a deeper map of a path on demand
    (a `mapdir(path)` MCP tool mirroring `recall`).

- **PostToolUse output truncation, re-read suppression:** larger context-source reductions
  captured for a later phase.

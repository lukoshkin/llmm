# llmm — running Claude Code on a local LLM

`llmm` is a small zsh tool that runs a local [`llama.cpp`](https://github.com/ggml-org/llama.cpp)
server (Qwen3-Coder-Next) and launches the Claude Code CLI against it, pointed at
the local server via `ANTHROPIC_BASE_URL`.

This README is the **"why and how"** — what had to be adapted to make a weak local
model usable inside Claude Code, and what was learned trying different models on
real hardware. For **install, commands, and config keys**, see the `## llmm`
section of [`../README.md`](../README.md). The full design rationale lives in
[`../../../docs/superpowers/specs/`](../../../docs/superpowers/specs/) (the
`llmm-local-llm-manager` and `llmm-lean-local-llm-adaptation` specs) with
task-by-task plans alongside them.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lukoshkin/llmm/master/install.sh | bash
```

`install.sh` builds `llama-server` from source and wires up the `llmm` command. It
is idempotent and self-managing (`llmm update` / `llmm update --local`).

### Prerequisites

**Required before install** (the installer hard-fails without these):

- **git** and **curl** — clone/build and model downloads.
- **cmake** — builds `llama.cpp` (`brew install cmake`, or `apt/dnf install cmake`).
- **A C/C++ toolchain** — macOS: `xcode-select --install`; Linux: `build-essential`
  / `gcc`+`g++`.
- **zsh** — `llmm` runs under zsh at runtime (the installer warns if it's missing).

**Auto-installed if absent** (the installer sets these up; failures degrade gracefully):

- **uv** (Astral) — used to install **`hf`** (the `huggingface_hub` CLI) for model
  downloads, and to run the MCP helper servers (`uv run --with mcp`). If uv can't be
  installed, model pulls fall back to llama.cpp's built-in `--hf-repo` download.

**Optional:**

- **fzf** — nicer `llmm pick`; without it you get a numbered menu.
- **Backend toolkits (Linux)** — `--backend cuda` needs the CUDA toolkit (`nvcc`);
  `--backend vulkan` needs the Vulkan SDK. macOS uses **Metal** automatically.

---

## The problem: Claude Code expects a frontier model and a huge window

Claude Code is built for Sonnet/Opus over a 200K–1M token window. Pointed at a
local server it works, but two things fight you:

1. **Fixed overhead crowds out a small window.** On a 48 GB Mac the practical
   context ceiling is ~32K comfortable / 72K borderline (the 80B-A3B weights stay
   resident). Against a ~72K window, Claude Code's *fixed* cost is roughly:
   built-in tools **~24K** + MCP tool schemas **~17K** + system prompt **~3–4K** +
   memory **~4.5K** + skills **~4K** ≈ **~50K of 64K** before any real work.
   Compaction only reclaims *conversation* tokens, never this fixed overhead — so
   the fix is to cut the overhead, not to compact harder.

2. **Claude Code mis-sizes the window and over-assumes capability.** For a custom
   endpoint it classifies the model as 1M-context (the `[1m]` tag) and never
   compacts before the local server overflows. And behaviour encoded in the
   *default system prompt* (plan mode, tool etiquette, refusals) is tuned for
   frontier models — a 3B-active local model under-follows it.

## The adaptation: a "lean" launch profile (default on)

All of it funnels through one seam — `lib/claude.zsh` / `claude::launch` — plus
some server-side trims. `llmm --full` opts out; `llmm --lean` forces it.

| Lever | What lean does | Why |
|-------|----------------|-----|
| **Built-in tools** | `--tools Bash Read Edit Write Grep Glob TodoWrite ExitPlanMode` | Drops the built-in Task/subagents, web, notebooks, LSP, etc. — the bulk of the ~24K tool overhead. Exploration is delegated through an MCP `explore` tool instead (see [Delegated exploration](#delegated-exploration)). |
| **MCP** | `--strict-mcp-config` with no `--mcp-config` → all MCP dropped (opt back in via `LLMM_MCP_CONFIG`) | Recovers ~17K of schemas; context7's doc dumps also swamp a small window. |
| **Skills/hooks/LSP/plugins/auto-memory** | `--bare` | Removes the rest of the framework overhead. |
| **System prompt** | `--system-prompt-file prompts/lean-coder.md` (replace, not append) | A terse, Qwen-tuned prompt (~500 words) instead of the ~3–4K default. Because the replacement drops everything the default prompt carried, it **re-adds the bits worth keeping explicitly** — notably a plan-mode contract (investigate read-only → write the plan to `docs/plans/<task>.md` → `ExitPlanMode` → wait for approval). |
| **Window awareness** | `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` (drops the `[1m]` tag) + `CLAUDE_CODE_MAX_CONTEXT_TOKENS` / `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Tell Claude Code the real window so it compacts in time. See the limitation below. |
| **Server RAM** | `--ctx-checkpoints 8` (vs upstream 32 × ~75 MiB) and `--parallel 1` | A single conversation that compacts doesn't need 32 KV checkpoints or 4 slots; frees ~1.8 GB on a memory-bound box. |

**Net effect:** fixed overhead drops from ~50K to **~1.8K measured** (system prompt
~0.6K, tools ~1.2K, no MCP/memory/skills), leaving essentially the whole local
window for actual work.

## Delegated exploration

Exploring a codebase ("find where X is configured", "trace how Y works") is exactly
the work that floods a small window — many `Read`/`Grep` calls whose bulky output
lives in context long after it's useful. Frontier Claude solves this with the `Task`
tool: spin up a subagent with its own context, let it explore, get back a short
answer. We wanted the same for the local model. It didn't work out as planned, and
the workaround is worth documenting.

**1. We tried `Task` first.** Re-admitting the built-in `Task` tool is mechanically
fine under `--bare` — the tool is reachable and the subagent runs. But
**Qwen3-Coder-Next will not emit `Task` calls.** Delegation/orchestration is absent
from its fine-tuning, so it narrates "I'll use the Task tool…" and then calls `Read`
itself anyway, or even confabulates a config step to "enable" subagents (there is
nothing to enable). Prompt hardening — putting the rule first, with a literal worked
`Task(...)` example — got it to *talk* about `Task` but never to *call* it. This is a
model capability gap, not a wiring bug.

**2. The workaround: an MCP `explore` tool.** The same model *reliably* calls MCP
tools — it proactively uses the scratchpad `checkpoint`/`recall` because their
request/response shape is in-distribution. So we expose exploration through that
channel. `explore(question, paths=[])` runs a small stdio MCP server
(`lib/hooks/explore_server.py`) that:

- gathers context **in its own process** — reads the `paths` you hint (files/globs),
  or greps the repo for terms from the question, under a char budget; then
- makes **one** call to the already-running `llama-server` and returns a concise
  3–5 line answer that cites files.

The bulky file contents never enter the main session — you spend a tiny tool call
plus a short answer instead of a dozen `Read`s.

**Two strategies — `LLMM_EXPLORE_MODE`** (transparent to the model; the
`explore(question, paths)` signature is identical either way):

| `LLMM_EXPLORE_MODE` | How the server answers |
|---------------------|------------------------|
| `retrieval` *(default)* | Greps/reads under a char budget, then **one** local-model summary call. Fast, predictable, one round-trip. |
| `agent` | Spawns a **nested headless `claude -p`** with read-only tools (`Read`/`Grep`/`Glob`, no MCP) so the local model drives its own exploration loop in an isolated subprocess; its answer is captured. Runs under `--permission-mode default` (headless = no prompt, so out-of-repo reads are denied while in-repo reads proceed), pinned to the local server, and refuses to run against `$HOME`/`/`. Slower (several round-trips on a slow local model) but can chase multi-hop questions retrieval can't. Falls back to `retrieval` if `claude` is missing or the run errors/times out (the reason is logged to the MCP server's stderr). |

`agent` mode is the interesting experiment: the original `Task` failure was the
model refusing to *emit a delegation call*, but inside the sub-session it only has
to *use read tools* — which it does fine. Whether the local model can sustain a
useful agentic loop end-to-end is the open question worth trying.

**The `LLMM_SUBAGENTS` switch** (default `0`) picks between the two, mutually
exclusively:

| `LLMM_SUBAGENTS` | What you get |
|------------------|--------------|
| `0` *(default)* | The `explore` MCP tool is wired in and the lean prompt is prepended with explore-usage guidance. No `Task`. |
| `1` | The built-in `Task` tool is re-admitted (`--tools … Task`) with the Task-usage addendum instead, and `explore` is dropped. Kept as an opt-in for stronger local models that *can* drive `Task`. |

(`explore` is independent of the scratchpad: `LLMM_SCRATCHPAD=0` turns off the
checkpoint hooks but leaves `explore` wired when subagents are off.)

## Known limitations

- **Auto-compact window floor (~100K).** Claude Code v2.1.x floors the auto-compact
  window at ~100K and reserves a fixed ~33% buffer, so on a sub-100K server the
  `MAX_CONTEXT_TOKENS` / `AUTO_COMPACT_WINDOW` / `PCT_OVERRIDE` env vars are **inert**
  (only `DISABLE_1M_CONTEXT` takes effect). `/context` shows a 100K window and
  compaction fires at ~67K — slightly beyond the borderline of a 72K server,
  leaving a small safe buffer (~5K). **Treat ~65K as the practical ceiling** and
  `/compact` manually if you near it. The env vars are kept because
  they *do* apply once the window exceeds ~100K (e.g. a 128K-ctx box).
- **Plan mode is prompt-enforced.** A weak local model follows the plan-mode
  contract less reliably than Sonnet/Opus. For heavy planning, `llmm --full` or a
  frontier model is better.
- **Rewind needs git + a fresh session.** Claude Code's file checkpoints don't
  survive a store-backed `/resume`, and want a git working tree. Start fresh
  (`llmm`, not `/resume`) inside a repo for `/rewind` to work.

---

## Hardware

Apple M5 Pro, **48 GB** unified memory, Metal backend. An 80B-A3B MoE keeps
**~36 GB resident** regardless of quant, leaving only a few GB for KV cache — which
is what pins the context ceiling at ~32K comfortable / 64K borderline and keeps the
machine at ~99% RAM in a real session. A 64 GB+ box could run 128K comfortably.

## Models tried on this hardware

All run through `llama.cpp` via `llmm` unless noted. Speeds and feel are subjective
field notes on *this* 48 GB machine, not benchmarks.

| Model | Runtime | First reply | Throughput | Feel | Notes |
|-------|---------|-------------|------------|------|-------|
| `qwen3.6:35b-mlx` | **Ollama** (MLX) | quick | quick enough | felt **dumb** | ⚠️ *Not a fair comparison:* the lean adaptations (tool trim, MCP off, slim prompt) were **not** applied here — it ran with Claude Code's full overhead, which a 35B model handles poorly. |
| Qwen3-Coder-Next **UD-Q4_K_M** | llama.cpp | **~20 min** | faster after warmup, still slower than the Ollama MLX model | felt **smarter** | Download not much larger than Q3, but needs more RAM. Required `--no-warmup` (and `--no-mmap`, relevance unclear) just to start. |
| Qwen3-Coder-Next **UD-Q3_K_XL** | llama.cpp | **~20 min** | ≈ same as Q4_K_M after warmup | — | Despite being 3-bit, the first-token latency is as bad as the 4-bit build. |
| Qwen3-Coder-Next **UD-Q3_K_M** ✅ *(default)* | llama.cpp | **1–2 min** | **~300–1000 tok/s prompt eval** vs ~30 tok/s for the two above; higher generation speed too | smart enough | Much faster on every axis; the chosen default. |

**Why `UD-Q3_K_M` wins so decisively.** The ~10–30× gap in prompt-processing speed
(hundreds of tok/s vs ~30) and the 20 min → 1–2 min first-reply collapse are the
classic signature of a model that *fits in fast (Metal) memory* versus ones that
spill. `UD-Q4_K_M` and `UD-Q3_K_XL` are large enough that, with KV cache on top,
they push past what stays resident on 48 GB — forcing paging/partial offload that
tanks prompt eval and explains the `--no-warmup`/`--no-mmap` requirement just to
boot. `UD-Q3_K_M` lands under that line, so it runs on the GPU end-to-end. The
takeaway: on a memory-bound Mac, the *quant that fits with headroom* beats a nominally
"better" but larger quant by a wide margin — bits-per-weight matters far less than
staying off the swap.

> The Ollama `qwen3.6:35b-mlx` result is the open question: it was fast but felt
> dumb *with full Claude Code overhead*. Re-running it under the lean profile
> (trimmed tools, no MCP, slim prompt) would be the fair test — it may well be the
> better daily driver if a smaller, faster model is enough once the context isn't
> wasted on framework overhead.

---

## See also

- [`../README.md`](../README.md) — install, commands, config keys, storage layout.
- `prompts/lean-coder.md` — the slim system prompt; `prompts/lean-explore.md` /
  `prompts/lean-subagent.md` — the delegation addenda for the two `LLMM_SUBAGENTS` modes.
- `lib/claude.zsh` — the lean/full launch seam.
- `lib/hooks/explore_server.py` — the MCP `explore` server (delegated exploration).
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design and build history.

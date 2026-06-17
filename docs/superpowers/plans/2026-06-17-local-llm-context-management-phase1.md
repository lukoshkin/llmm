# Local-LLM Context Management — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give weak local LLMs a session-scoped, structured scratchpad that survives autocompaction — written via an MCP `checkpoint`/`recall` tool, force-triggered by a Stop hook near the context threshold, and re-injected after compaction by a SessionStart hook — plus an opt-in `Task` subagent for isolated exploration.

**Architecture:** `llmm` launches Claude Code with `--bare`; Phase 1 re-enables exactly two pieces via explicit flags that survive `--bare`: `--settings <per-session hooks.json>` and `--mcp-config <per-session mcp.json>`, both generated at launch with the session id baked in. A small stdio MCP server (`scratchpad_server.py`) reads/writes a sectioned Markdown file `.llmm/<id>.md`; a Stop hook detects the token threshold and forces a checkpoint; a SessionStart `compact` hook re-injects the always-on sections.

**Tech Stack:** zsh (launcher + hooks + test harness), POSIX sh + `jq` (hooks), Python 3 stdlib + `mcp` package via `uv run --with mcp` (MCP server). Tests run with `zsh tests/harness.zsh`.

---

## File Structure

**Create:**
- `lib/hooks/scratchpad_core.py` — pure-stdlib section parse/merge/read logic (testable without `mcp`).
- `lib/hooks/scratchpad_server.py` — thin MCP wrapper exposing `checkpoint` + `recall`, delegating to core.
- `lib/hooks/stop.sh` — Stop hook: loop-guard, read last `input_tokens`, force checkpoint over threshold.
- `lib/hooks/session_start.sh` — SessionStart compact hook: echo `## Status` + `## Open questions`.
- `tests/scratchpad_core_test.py` — Python unit tests for the core logic.
- `tests/test_scratchpad.zsh` — harness wrapper that runs the Python tests and asserts exit 0.
- `tests/test_hooks.zsh` — pipes JSON into `stop.sh` / `session_start.sh` and asserts stdout.

**Modify:**
- `config.default.zsh` — add `LLMM_SCRATCHPAD`, `LLMM_SCRATCHPAD_PCT`, `LLMM_SUBAGENTS`.
- `lib/claude.zsh` — session id + JSON writers; wire `--settings`/`--mcp-config`; opt-in `Task`; trap cleanup; `.gitignore` append.
- `tests/test_claude.zsh` — fix the now-stale `--mcp-config` assertion; add scratchpad + subagent assertions; test the writers.
- `prompts/lean-coder.md` — document `checkpoint` / `recall`.

---

## Scratchpad file contract (canonical, shared by all components)

Fixed header set, in this order. Section bodies are everything between one `## ` line and the next.

```markdown
## Task

## Status

## Findings

## Decisions

## Dead ends

## Open questions
```

Tool-arg keys → headers: `task→Task`, `status→Status`, `findings→Findings`, `decisions→Decisions`, `dead_ends→Dead ends`, `open_questions→Open questions`.

---

## Task 1: Scratchpad core logic (pure Python)

**Files:**
- Create: `lib/hooks/scratchpad_core.py`
- Create: `tests/scratchpad_core_test.py`
- Create: `tests/test_scratchpad.zsh`

- [ ] **Step 1: Write the failing Python tests**

Create `tests/scratchpad_core_test.py`:

```python
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib", "hooks"))

import scratchpad_core as sc


def check(cond, label):
    if not cond:
        print(f"FAIL: {label}")
        check.failures += 1
    check.total += 1


check.failures = 0
check.total = 0

# empty_doc has all six headers in order
doc = sc.empty_doc()
order = [doc.index(f"## {h}") for h in
         ["Task", "Status", "Findings", "Decisions", "Dead ends", "Open questions"]]
check(order == sorted(order), "empty_doc headers present and ordered")

# append adds a bullet and preserves prior content
doc = sc.merge(doc, "findings", "a.py:1 — does X", "append")
doc = sc.merge(doc, "findings", "b.py:2 — does Y", "append")
body = sc.read_section(doc, "findings")
check("a.py:1 — does X" in body and "b.py:2 — does Y" in body, "append accumulates findings")

# replace swaps only the targeted section
doc = sc.merge(doc, "status", "step 1: exploring", "replace")
doc = sc.merge(doc, "status", "step 2: editing", "replace")
check(sc.read_section(doc, "status").strip() == "step 2: editing", "replace swaps status")
check("a.py:1 — does X" in sc.read_section(doc, "findings"), "replace leaves findings intact")

# unknown section is rejected
try:
    sc.merge(doc, "bogus", "x", "append")
    check(False, "unknown section raises")
except ValueError:
    check(True, "unknown section raises")

print(f"ran {check.total} checks, {check.failures} failure(s)")
sys.exit(1 if check.failures else 0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/scratchpad_core_test.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'scratchpad_core'`.

- [ ] **Step 3: Implement the core**

Create `lib/hooks/scratchpad_core.py`:

```python
"""Pure-stdlib parse/merge/read for the sectioned scratchpad. No mcp dependency."""
from __future__ import annotations

HEADERS = ["Task", "Status", "Findings", "Decisions", "Dead ends", "Open questions"]
KEY_TO_HEADER = {
    "task": "Task",
    "status": "Status",
    "findings": "Findings",
    "decisions": "Decisions",
    "dead_ends": "Dead ends",
    "open_questions": "Open questions"
}


def _header(section: str) -> str:
    if section not in KEY_TO_HEADER:
        raise ValueError(f"unknown section: {section!r}; valid: {sorted(KEY_TO_HEADER)}")
    return KEY_TO_HEADER[section]


def empty_doc() -> str:
    return "\n\n".join(f"## {h}\n" for h in HEADERS) + "\n"


def parse_sections(text: str) -> dict[str, str]:
    sections: dict[str, str] = {h: "" for h in HEADERS}
    current: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        if line.startswith("## "):
            if current is not None:
                sections[current] = "\n".join(buf).strip("\n")
            header = line[3:].strip()
            current = header if header in sections else None
            buf = []
        elif current is not None:
            buf.append(line)
    if current is not None:
        sections[current] = "\n".join(buf).strip("\n")
    return sections


def render(sections: dict[str, str]) -> str:
    parts = []
    for h in HEADERS:
        body = sections.get(h, "").strip("\n")
        parts.append(f"## {h}\n{body}".rstrip() + "\n")
    return "\n".join(parts) + "\n"


def merge(text: str, section: str, content: str, mode: str) -> str:
    header = _header(section)
    sections = parse_sections(text)
    content = content.strip()
    if mode == "replace":
        sections[header] = content
    elif mode == "append":
        existing = sections[header].strip("\n")
        bullet = content if content.startswith("- ") else f"- {content}"
        sections[header] = f"{existing}\n{bullet}".strip("\n") if existing else bullet
    else:
        raise ValueError(f"mode must be 'append' or 'replace', got {mode!r}")
    return render(sections)


def read_section(text: str, section: str) -> str:
    return parse_sections(text)[_header(section)]
```

- [ ] **Step 4: Run the Python tests to verify they pass**

Run: `python3 tests/scratchpad_core_test.py`
Expected: `ran 7 checks, 0 failure(s)` and exit 0.

- [ ] **Step 5: Add the harness wrapper so `tests/harness.zsh` picks it up**

Create `tests/test_scratchpad.zsh`:

```zsh
# Run the scratchpad core Python unit tests through the zsh harness.
typeset _sp_out _sp_rc
_sp_out="$(python3 "$LLMM_ROOT/tests/scratchpad_core_test.py" 2>&1)"; _sp_rc=$?
assert_rc 0 "$_sp_rc" "scratchpad_core python tests pass"
[[ $_sp_rc == 0 ]] || print -u2 "$_sp_out"
```

- [ ] **Step 6: Run the full harness**

Run: `zsh tests/harness.zsh`
Expected: ends with `0 failure(s)`.

- [ ] **Step 7: Commit**

```bash
git add lib/hooks/scratchpad_core.py tests/scratchpad_core_test.py tests/test_scratchpad.zsh
git commit -m "scratchpad: sectioned parse/merge/read core + tests"
```

---

## Task 2: MCP server wrapper (`checkpoint` + `recall`)

**Files:**
- Create: `lib/hooks/scratchpad_server.py`

No automated unit test (MCP stdio transport needs the runtime); verified by a smoke import in Step 3 and end-to-end in Task 9. The logic it relies on is already tested in Task 1.

- [ ] **Step 1: Implement the server**

Create `lib/hooks/scratchpad_server.py`:

```python
"""Stdio MCP server exposing checkpoint + recall over a sectioned scratchpad file."""
from __future__ import annotations

import argparse
import os

from mcp.server.fastmcp import FastMCP

import scratchpad_core as sc

parser = argparse.ArgumentParser()
parser.add_argument("--session-id", required=True)
parser.add_argument("--scratchpad-dir", required=True)
args = parser.parse_args()

PATH = os.path.join(args.scratchpad_dir, f"{args.session_id}.md")
mcp = FastMCP("scratchpad")


def _read() -> str:
    if os.path.exists(PATH):
        with open(PATH, encoding="utf-8") as fh:
            return fh.read()
    return sc.empty_doc()


def _write(text: str) -> None:
    os.makedirs(args.scratchpad_dir, exist_ok=True)
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(text)


@mcp.tool()
def checkpoint(section: str, content: str, mode: str = "append") -> str:
    """Save progress to one scratchpad section. mode=append for findings/decisions/dead_ends/open_questions, replace for task/status."""
    _write(sc.merge(_read(), section, content, mode))
    return f"saved to {section}"


@mcp.tool()
def recall(section: str = "") -> str:
    """Read one scratchpad section on demand (e.g. dead_ends before retrying). Empty arg lists section names."""
    if not section:
        return ", ".join(sc.KEY_TO_HEADER)
    return sc.read_section(_read(), section) or f"(section {section} is empty)"


if __name__ == "__main__":
    mcp.run()
```

- [ ] **Step 2: Verify the `mcp` package is importable on demand**

Run: `uv run --with mcp python3 -c "import mcp.server.fastmcp; print('ok')"`
Expected: prints `ok` (downloads `mcp` into an ephemeral env on first run).

> If `FastMCP` is not at `mcp.server.fastmcp` in the resolved `mcp` version, run
> `uv run --with mcp python3 -c "import mcp, pkgutil; print([m.name for m in pkgutil.iter_modules(mcp.__path__)])"`
> and adjust the import path. This is the one version-sensitive line.

- [ ] **Step 3: Smoke-test the server boots and finds the core**

Run: `uv run --with mcp python3 -c "import sys; sys.argv=['x','--session-id','t','--scratchpad-dir','/tmp/llmmsp']; sys.path.insert(0,'lib/hooks'); exec(open('lib/hooks/scratchpad_server.py').read().split('if __name__')[0]); print(checkpoint('findings','x.py:1 — y','append')); print(recall('findings'))"`
Expected: prints `saved to findings` then a body containing `- x.py:1 — y`; `/tmp/llmmsp/t.md` exists.

- [ ] **Step 4: Commit**

```bash
git add lib/hooks/scratchpad_server.py
git commit -m "scratchpad: MCP server with checkpoint + recall tools"
```

---

## Task 3: Stop hook (threshold + loop guard)

**Files:**
- Create: `lib/hooks/stop.sh`
- Create: `tests/test_hooks.zsh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_hooks.zsh`:

```zsh
typeset _hd="$LLMM_ROOT/lib/hooks"
typeset _tmp; _tmp="$(mktemp -d)"

# --- stop.sh: a transcript over threshold forces a checkpoint ---
typeset _tr="$_tmp/transcript.jsonl"
print -r -- '{"type":"assistant","message":{"usage":{"input_tokens":60000}}}' > "$_tr"
typeset _in _out
_in="{\"stop_hook_active\":false,\"transcript_path\":\"$_tr\"}"
_out="$(print -r -- "$_in" | CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 LLMM_SCRATCHPAD_PCT=85 "$_hd/stop.sh")"
assert_contains "$_out" "CHECKPOINT REQUIRED" "stop hook fires over threshold"
assert_contains "$_out" "Stop" "stop hook tags the Stop event"

# --- stop.sh: under threshold emits nothing ---
print -r -- '{"type":"assistant","message":{"usage":{"input_tokens":1000}}}' > "$_tr"
_out="$(print -r -- "$_in" | CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 LLMM_SCRATCHPAD_PCT=85 "$_hd/stop.sh")"
assert_eq "$_out" "" "stop hook silent under threshold"

# --- stop.sh: loop guard — stop_hook_active=true emits nothing even over threshold ---
print -r -- '{"type":"assistant","message":{"usage":{"input_tokens":60000}}}' > "$_tr"
_in="{\"stop_hook_active\":true,\"transcript_path\":\"$_tr\"}"
_out="$(print -r -- "$_in" | CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 LLMM_SCRATCHPAD_PCT=85 "$_hd/stop.sh")"
assert_eq "$_out" "" "stop hook respects loop guard"

# NOTE: Task 4 appends more cases below this point; keep the final `rm -rf "$_tmp"`
# as the last line of this file.
rm -rf "$_tmp"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zsh tests/harness.zsh`
Expected: FAIL — `stop hook fires over threshold` (script missing, output empty).

- [ ] **Step 3: Implement `stop.sh`**

Create `lib/hooks/stop.sh` (then `chmod +x`):

```sh
#!/usr/bin/env sh
# Stop hook: near the context threshold, force a checkpoint before autocompaction.
input=$(cat)

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$active" = "true" ] && exit 0   # loop guard: do not re-fire after we forced a continue

tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

max=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-0}
pct=${LLMM_SCRATCHPAD_PCT:-85}
[ "$max" -gt 0 ] 2>/dev/null || exit 0

# Last prompt-token count = current context size proxy. Scan only the tail (bounded cost).
# Field path is version-sensitive — try .message.usage.input_tokens then .usage.input_tokens.
tokens=$(tail -n 80 "$tp" | jq -rs 'map(.message.usage.input_tokens? // .usage.input_tokens? | numbers) | last // 0')
[ -n "$tokens" ] || tokens=0

thr=$(( max * pct / 100 ))
if [ "$tokens" -ge "$thr" ]; then
  used=$(( tokens * 100 / max ))
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"CHECKPOINT REQUIRED: context at %d%%. Call checkpoint(section,content,mode) for any unsaved Findings/Decisions/Dead ends/Status now, before any other action."}}\n' "$used"
fi
exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x lib/hooks/stop.sh`

- [ ] **Step 5: Run the harness to verify it passes**

Run: `zsh tests/harness.zsh`
Expected: the three stop-hook assertions pass; overall `0 failure(s)`.

- [ ] **Step 6: Commit**

```bash
git add lib/hooks/stop.sh tests/test_hooks.zsh
git commit -m "scratchpad: Stop hook forces checkpoint near threshold (loop-guarded)"
```

---

## Task 4: SessionStart compact hook

**Files:**
- Create: `lib/hooks/session_start.sh`
- Modify: `tests/test_hooks.zsh`

- [ ] **Step 1: Add the failing test**

Append to `tests/test_hooks.zsh` (before the final `rm -rf "$_tmp"`; move that `rm` to the very end):

```zsh
# --- session_start.sh: echoes ONLY Status + Open questions ---
typeset _sdir="$_tmp/.llmm"; mkdir -p "$_sdir"
cat > "$_sdir/sess1.md" <<'MD'
## Task
build X

## Status
step 2: editing foo.py

## Findings
- foo.py:10 — secret sauce

## Decisions
- chose A

## Dead ends
- tried B

## Open questions
- does C hold?
MD
typeset _ss
_ss="$("$_hd/session_start.sh" "$_sdir" sess1)"
assert_contains "$_ss" "step 2: editing foo.py" "session_start emits Status"
assert_contains "$_ss" "does C hold?" "session_start emits Open questions"
assert_not_contains "$_ss" "secret sauce" "session_start omits Findings"
assert_not_contains "$_ss" "tried B" "session_start omits Dead ends"
assert_contains "$_ss" "recall(" "session_start hints at recall"
```

- [ ] **Step 2: Run to verify it fails**

Run: `zsh tests/harness.zsh`
Expected: FAIL — `session_start emits Status` (script missing).

- [ ] **Step 3: Implement `session_start.sh`**

Create `lib/hooks/session_start.sh` (then `chmod +x`):

```sh
#!/usr/bin/env sh
# SessionStart (compact) hook: re-inject only the always-on sections after compaction.
# Args: <scratchpad-dir> <session-id>
dir=$1
id=$2
f="$dir/$id.md"
[ -f "$f" ] || exit 0

awk '
  /^## / { keep = ($0 == "## Status" || $0 == "## Open questions") }
  keep { print }
' "$f"

printf '\nOther sections available on demand via recall(findings|decisions|dead_ends).\n'
exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x lib/hooks/session_start.sh`

- [ ] **Step 5: Run the harness**

Run: `zsh tests/harness.zsh`
Expected: all session-start assertions pass; `0 failure(s)`.

- [ ] **Step 6: Commit**

```bash
git add lib/hooks/session_start.sh tests/test_hooks.zsh
git commit -m "scratchpad: SessionStart compact hook re-injects Status + Open questions"
```

---

## Task 5: Config knobs

**Files:**
- Modify: `config.default.zsh`

- [ ] **Step 1: Add the knobs**

In `config.default.zsh`, after the `LLMM_COMPACT_PCT` block, add:

```zsh
# Scratchpad: session-scoped structured findings file that survives autocompaction.
# Re-enables a Stop hook + a tiny MCP server under lean mode (via explicit --settings /
# --mcp-config, which survive --bare). On by default in lean mode.
LLMM_SCRATCHPAD=${LLMM_SCRATCHPAD:-1}
# % of the context window at which the Stop hook forces a checkpoint. Keep BELOW the
# autocompaction trigger so the save lands before compaction fires.
LLMM_SCRATCHPAD_PCT=${LLMM_SCRATCHPAD_PCT:-85}
# Re-admit the Task tool for isolated read-only exploration subagents. Off by default:
# adds ~1-2K tokens of tool description and depends on general-purpose being reachable
# under --bare (verify before relying on it).
LLMM_SUBAGENTS=${LLMM_SUBAGENTS:-0}
```

- [ ] **Step 2: Verify it sources cleanly**

Run: `zsh -c 'source config.default.zsh && print "$LLMM_SCRATCHPAD $LLMM_SCRATCHPAD_PCT $LLMM_SUBAGENTS"'`
Expected: `1 85 0`

- [ ] **Step 3: Commit**

```bash
git add config.default.zsh
git commit -m "config: add LLMM_SCRATCHPAD, LLMM_SCRATCHPAD_PCT, LLMM_SUBAGENTS knobs"
```

---

## Task 6: claude.zsh — session id + JSON writers

**Files:**
- Modify: `lib/claude.zsh`
- Modify: `tests/test_claude.zsh`

- [ ] **Step 1: Add failing tests for the writers**

Append to `tests/test_claude.zsh`:

```zsh
# --- session id is non-empty and shell-safe ---
typeset _sid; _sid="$(claude::session_id)"
assert_eq "$([[ -n "$_sid" && "$_sid" != *[^A-Za-z0-9_]* ]] && print ok)" ok "session id is safe"

# --- write_hooks_json produces a valid hooks file wired to the hook scripts ---
typeset _wd; _wd="$(mktemp -d)/.llmm"; mkdir -p "$_wd"
typeset _hf; _hf="$(claude::write_hooks_json "$_wd" testid 65536 85)"
assert_eq "$([[ -f "$_hf" ]] && print yes)" yes "hooks json written"
typeset _hj; _hj="$(cat "$_hf")"
assert_contains "$_hj" "stop.sh" "hooks json wires stop.sh"
assert_contains "$_hj" "session_start.sh" "hooks json wires session_start.sh"
assert_contains "$_hj" '"matcher": "compact"' "hooks json uses compact matcher"
assert_contains "$_hj" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536" "hooks json bakes max tokens"
assert_contains "$_hj" "LLMM_SCRATCHPAD_PCT=85" "hooks json bakes pct"

# --- write_mcp_json points uv at the scratchpad server with session args ---
typeset _mf; _mf="$(claude::write_mcp_json "$_wd" testid)"
typeset _mj; _mj="$(cat "$_mf")"
assert_contains "$_mj" "scratchpad_server.py" "mcp json points at server"
assert_contains "$_mj" "--with" "mcp json uses uv run --with mcp"
assert_contains "$_mj" "--session-id" "mcp json passes session id"
```

- [ ] **Step 2: Run to verify it fails**

Run: `zsh tests/harness.zsh`
Expected: FAIL — `command not found: claude::session_id`.

- [ ] **Step 3: Implement the helpers**

In `lib/claude.zsh`, after `claude::compact_pct()` (before `claude::launch`), add:

```zsh
# claude::session_id -> shell-safe unique-ish id for this launch.
claude::session_id() { print -r -- "$(date +%Y%m%d_%H%M%S)_$$"; }

# claude::write_hooks_json <scratchpad_dir> <id> <ctx> <pct> -> prints the file path.
claude::write_hooks_json() {
  local dir="$1" id="$2" ctx="$3" pct="$4"
  local hd="$LLMM_ROOT/lib/hooks" f="$1/hooks.$2.json"
  cat > "$f" <<JSON
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "LLMM_SCRATCHPAD_PCT=$pct CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx $hd/stop.sh"}]}],
    "SessionStart": [{"matcher": "compact", "hooks": [{"type": "command", "command": "$hd/session_start.sh $dir $id"}]}]
  }
}
JSON
  print -r -- "$f"
}

# claude::write_mcp_json <scratchpad_dir> <id> -> prints the file path.
claude::write_mcp_json() {
  local dir="$1" id="$2"
  local hd="$LLMM_ROOT/lib/hooks" f="$1/mcp.$2.json"
  cat > "$f" <<JSON
{
  "mcpServers": {
    "scratchpad": {
      "command": "uv",
      "args": ["run", "--with", "mcp", "python3", "$hd/scratchpad_server.py", "--session-id", "$id", "--scratchpad-dir", "$dir"]
    }
  }
}
JSON
  print -r -- "$f"
}
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `zsh tests/harness.zsh`
Expected: the writer assertions pass; `0 failure(s)`.

- [ ] **Step 5: Commit**

```bash
git add lib/claude.zsh tests/test_claude.zsh
git commit -m "claude: session id + hooks/mcp config writers"
```

---

## Task 7: claude.zsh — wire scratchpad into launch + opt-in Task

**Files:**
- Modify: `lib/claude.zsh` (the lean branch of `claude::launch`, lines ~45-64)
- Modify: `tests/test_claude.zsh` (fix the stale `--mcp-config` assertion; add new cases)

- [ ] **Step 1: Fix the now-stale assertion and add failing tests**

In `tests/test_claude.zsh`, **replace** the line:

```zsh
assert_not_contains "$out" "ARG --mcp-config" "lean omits --mcp-config when LLMM_MCP_CONFIG unset"
```

with (scratchpad is now default-on and supplies its own `--mcp-config`):

```zsh
# Scratchpad is default-on: it adds --settings and its own --mcp-config.
assert_contains "$out" "ARG --settings" "lean wires scratchpad --settings"
assert_contains "$out" "ARG --mcp-config" "lean wires scratchpad --mcp-config"
assert_contains "$out" ".llmm/hooks." "lean settings path points at .llmm"
assert_contains "$out" ".llmm/mcp." "lean mcp path points at .llmm"

# Disabling the scratchpad removes both wires.
typeset out_ns
out_ns="$(LLMM_SCRATCHPAD=0 LLMM_DRYRUN=1 claude::launch a 11111 1 65536 2>&1)"
assert_not_contains "$out_ns" "ARG --settings" "LLMM_SCRATCHPAD=0 drops --settings"
assert_not_contains "$out_ns" "ARG --mcp-config" "LLMM_SCRATCHPAD=0 drops --mcp-config"

# Subagents opt-in adds Task; default keeps it off (line 28 already asserts default-off).
typeset out_sa
out_sa="$(LLMM_SUBAGENTS=1 LLMM_DRYRUN=1 claude::launch a 11111 1 65536 2>&1)"
assert_contains "$out_sa" "ARG Task" "LLMM_SUBAGENTS=1 re-admits Task"
```

- [ ] **Step 2: Run to verify it fails**

Run: `zsh tests/harness.zsh`
Expected: FAIL — `lean wires scratchpad --settings` (not yet wired).

- [ ] **Step 3: Wire the lean branch**

In `lib/claude.zsh`, **replace** this block (currently lines ~61-63):

```zsh
    cargs+=(--tools "${CLAUDE_LEAN_TOOLS[@]}")
    # --system-prompt-file is a flag, so it terminates the variadic --tools list.
    cargs+=(--system-prompt-file "$prompt")
```

with:

```zsh
    # Scratchpad: generate per-session hooks + mcp config and wire them in. These
    # explicit flags survive --bare. Default-on; LLMM_SCRATCHPAD=0 opts out.
    if [[ "${LLMM_SCRATCHPAD:-1}" == 1 ]]; then
      local sid scratch hooks mcp
      sid="$(claude::session_id)"
      scratch="$PWD/.llmm"
      hooks="$scratch/hooks.$sid.json"
      mcp="$scratch/mcp.$sid.json"
      if [[ -z "${LLMM_DRYRUN:-}" ]]; then
        mkdir -p "$scratch"
        claude::write_hooks_json "$scratch" "$sid" "$ctx" "$pct" >/dev/null
        claude::write_mcp_json "$scratch" "$sid" >/dev/null
        grep -qxF '.llmm/' .gitignore 2>/dev/null || \
          { [[ -d .git || -f .gitignore ]] && print -- '.llmm/' >> .gitignore; }
        trap "rm -f ${(q)hooks} ${(q)mcp}" EXIT
      fi
      cargs+=(--settings "$hooks" --mcp-config "$mcp")
    fi
    # Tool list: lean core, plus Task when subagents are opted in.
    local -a leantools=("${CLAUDE_LEAN_TOOLS[@]}")
    [[ "${LLMM_SUBAGENTS:-0}" == 1 ]] && leantools+=(Task)
    cargs+=(--tools "${leantools[@]}")
    # --system-prompt-file is a flag, so it terminates the variadic --tools list.
    cargs+=(--system-prompt-file "$prompt")
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `zsh tests/harness.zsh`
Expected: all assertions pass; `0 failure(s)`. (Confirm no leftover `.llmm/` was created by the dry-run cases — there should be none, since writes are gated on `LLMM_DRYRUN` being unset.)

- [ ] **Step 5: Commit**

```bash
git add lib/claude.zsh tests/test_claude.zsh
git commit -m "claude: wire scratchpad settings/mcp into lean launch + opt-in Task"
```

---

## Task 8: Lean prompt — document checkpoint/recall

**Files:**
- Modify: `prompts/lean-coder.md`

`Task` is intentionally NOT documented here (off by default; referencing an absent tool would confuse a weak model). The `<700 words` test at `tests/test_claude.zsh:8` must stay green.

- [ ] **Step 1: Add the tool guidance**

In `prompts/lean-coder.md`, under the `# Tools` list, after the `ExitPlanMode` bullet, add:

```markdown
- checkpoint(section, content, mode): after each significant finding, save it to the matching scratchpad section. Use mode=append for findings/decisions/dead_ends/open_questions, mode=replace for task/status. Save one section per call; never re-send the whole pad. On a "CHECKPOINT REQUIRED" message, save all unsaved progress before doing anything else.
- recall(section): pull a saved section back when you need it — especially recall("dead_ends") before retrying an approach, so you do not repeat a known failure.
```

- [ ] **Step 2: Verify word count still under 700**

Run: `wc -w < prompts/lean-coder.md`
Expected: a number `< 700`.

- [ ] **Step 3: Run the harness (the prompt test reads this file)**

Run: `zsh tests/harness.zsh`
Expected: `lean prompt non-empty and < 700 words` passes; `0 failure(s)`.

- [ ] **Step 4: Commit**

```bash
git add prompts/lean-coder.md
git commit -m "prompt: document checkpoint/recall scratchpad tools"
```

---

## Task 9: End-to-end verification

**Files:** none (manual run against a live local server).

- [ ] **Step 1: Full unit suite green**

Run: `zsh tests/harness.zsh`
Expected: `0 failure(s)`.

- [ ] **Step 2: Launch a real lean session and confirm wiring**

Run: `llmm` in a scratch git repo, then in a second terminal:
`ls .llmm/`
Expected: `hooks.<id>.json` and `mcp.<id>.json` exist while the session runs; `.llmm/` is in `.gitignore`.

- [ ] **Step 3: Exercise checkpoint + recall**

In the session, ask: "Read README, then call checkpoint to record one finding, then recall findings."
Expected: `.llmm/<id>.md` appears with the finding under `## Findings`; the model's `recall` returns it. Quit the session; confirm `hooks.<id>.json`/`mcp.<id>.json` are deleted (trap) but `.llmm/<id>.md` remains.

- [ ] **Step 4: Force the threshold**

Relaunch with `LLMM_SCRATCHPAD_PCT=1 llmm`. After the first substantive turn:
Expected: the next turn carries a `CHECKPOINT REQUIRED` instruction (model proactively calls `checkpoint`); it does NOT loop forever (loop guard).

- [ ] **Step 5: Confirm compaction recovery**

Drive the session until autocompaction fires (or set a tiny `--ctx`). After compaction:
Expected: the resumed context contains the `## Status` and `## Open questions` text plus the `recall(...)` hint, and the model can continue without re-exploring.

- [ ] **Step 6 (only if `LLMM_SUBAGENTS=1`): verify Task under --bare**

Relaunch with `LLMM_SUBAGENTS=1 llmm` and ask for a bounded lookup ("which file configures the port?").
Expected: `Task` is available and resolves to the built-in `general-purpose` agent; the main transcript gains only the short conclusion. If `Task` errors under `--bare`, record it — the knob stays off and Phase 1 is unaffected.

- [ ] **Step 7: Update the spec's open risks**

In `docs/superpowers/specs/2026-06-17-local-llm-context-management-design.md`, under "Open Implementation Risks", note the two empirical results found during Steps 4-6: the actual transcript token-field path (`.message.usage.input_tokens` vs `.usage.input_tokens`) and whether `Task` is reachable under `--bare`. Commit:

```bash
git add docs/superpowers/specs/2026-06-17-local-llm-context-management-design.md
git commit -m "spec: record measured token-field path and --bare Task availability"
```

---

## Self-Review notes

- **Spec coverage:** scratchpad format (Task 1), `checkpoint`/`recall` per-section merge (Tasks 1-2), Stop hook + loop guard + tail-read (Task 3), SessionStart compact injecting only Status/Open questions (Task 4), per-session config files + concurrency-safe names + trap (Tasks 6-7), `uv run --with mcp` invocation (Tasks 2, 6), opt-in `Task` (Tasks 5, 7), `.gitignore` (Task 7), prompt guidance (Task 8), all verification items (Task 9). Sampling/cache/repo-map are explicitly Phase 3+ and out of this plan.
- **Version-sensitive points flagged inline:** the `mcp.server.fastmcp` import path (Task 2 Step 2) and the transcript token-field path (Task 3 + Task 9 Step 7).
- **Type/name consistency:** `checkpoint(section, content, mode)`, `recall(section)`, `KEY_TO_HEADER`, `merge`, `read_section`, `empty_doc`, `claude::session_id`, `claude::write_hooks_json`, `claude::write_mcp_json` are used identically across tasks.

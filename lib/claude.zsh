#!/usr/bin/env zsh
# claude.zsh — launch Claude Code pointed at the local server.
# Two modes:
#   full — today's behavior (default system prompt, all tools, all MCP).
#   lean — minimal session for a weak local model: no MCP, trimmed tools, --bare,
#          a slim replacement system prompt, and a context window the size of the
#          real local window so auto-compaction triggers before the server overflows.

# Built-in tools kept in lean mode (the irreducible coding core).
typeset -ga CLAUDE_LEAN_TOOLS=(Bash Read Edit Write Grep Glob TodoWrite ExitPlanMode)

# claude::lean_prompt -> path to the lean system-prompt file (override or repo default).
# Dies if the resolved file is missing (bad override / broken install).
claude::lean_prompt() {
  local p="${LLMM_SYSTEM_PROMPT:-$LLMM_ROOT/prompts/lean-coder.md}"
  [[ -f "$p" ]] || ui::die "lean system prompt not found: $p"
  print -r -- "$p"
}

# claude::compact_pct -> validated auto-compact threshold percentage (integer 1..99).
claude::compact_pct() {
  local pct="${LLMM_COMPACT_PCT:-80}"
  if [[ "$pct" != <-> ]] || (( pct < 1 || pct > 99 )); then
    ui::die "LLMM_COMPACT_PCT must be an integer 1..99, got: $pct"
  fi
  print -r -- "$pct"
}

# claude::session_id -> shell-safe unique-ish id for this launch.
claude::session_id() { print -r -- "$(date +%Y%m%d_%H%M%S)_$$"; }

# claude::write_hooks_json <scratchpad_dir> <id> <ctx> <pct> -> prints the file path.
claude::write_hooks_json() {
  local dir="$1" id="$2" ctx="$3" pct="$4"
  local hd="$LLMM_ROOT/lib/hooks" f="$1/hooks.$2.json"
  [[ -L "$f" ]] && ui::die "refusing to write through symlink: $f"
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
  [[ -L "$f" ]] && ui::die "refusing to write through symlink: $f"
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

# claude::reap_stale <scratchpad_dir> -> remove ephemeral hooks/mcp config files whose
# owning llmm process (the PID is the session id's last field) is no longer running.
# Needed because launch exec()s claude, so the EXIT trap that would delete this session's
# files never fires; reaping dead-PID files at the next launch keeps .llmm from growing.
# A live concurrent session keeps its own files; the persistent scratchpad .md is untouched.
claude::reap_stale() {
  local dir="$1" f pid
  for f in "$dir"/hooks.*.json(N) "$dir"/mcp.*.json(N); do
    pid="${${f:t:r}##*_}"
    [[ "$pid" == <-> ]] && ! kill -0 "$pid" 2>/dev/null && rm -f "$f"
  done
}

# claude::launch <alias> <port> <lean> <ctx> [claude args...]
# lean: 1 = lean session, 0 = full. ctx: effective context window (config::ctx_size).
# With LLMM_DRYRUN set, prints the assembled env/args (one per line) and returns
# instead of exec-ing — used by the test suite.
claude::launch() {
  local alias="$1" port="$2" lean="$3" ctx="$4"; shift 4
  local -a cenv cargs
  cenv=(
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port"
    ANTHROPIC_API_KEY="llama-cpp"
    ANTHROPIC_AUTH_TOKEN="llama-cpp"
    ANTHROPIC_DEFAULT_SONNET_MODEL="$alias"
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$alias"
    ANTHROPIC_DEFAULT_OPUS_MODEL="$alias"
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
  )
  # Pin the model on the CLI in both modes: --model outranks the user's
  # ~/.claude/settings.json `model` key (which --bare does NOT suppress), so a global
  # pin like "opus[1m]" can't leak its label or 1M tag into an llmm session. Every
  # llmm session targets the local server (which ignores the model name); this just
  # makes the session self-describe as the local alias, not the inherited default.
  cargs+=(--model "$alias")
  if [[ "$lean" == 1 ]]; then
    # Validate before building so bad config fails loudly and early.
    local prompt pct
    prompt="$(claude::lean_prompt)" || exit 1
    pct="$(claude::compact_pct)" || exit 1
    cenv+=(
      CLAUDE_CODE_DISABLE_1M_CONTEXT=1
      CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx"
      CLAUDE_CODE_AUTO_COMPACT_WINDOW="$ctx"
      CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$pct"
    )
    cargs+=(--bare --strict-mcp-config)
    if [[ -n "${LLMM_MCP_CONFIG:-}" ]]; then
      [[ -f "$LLMM_MCP_CONFIG" ]] || ui::die "LLMM_MCP_CONFIG not found: $LLMM_MCP_CONFIG"
      cargs+=(--mcp-config "$LLMM_MCP_CONFIG")
    fi
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
        claude::reap_stale "$scratch"   # exec() below kills any EXIT trap; reap here instead
        claude::write_hooks_json "$scratch" "$sid" "$ctx" "$pct" >/dev/null
        claude::write_mcp_json "$scratch" "$sid" >/dev/null
        grep -qxF '.llmm/' .gitignore 2>/dev/null || \
          { [[ -d .git || -f .gitignore ]] && print -- '.llmm/' >> .gitignore; }
      fi
      cargs+=(--settings "$hooks" --mcp-config "$mcp")
    fi
    # Tool list: lean core, plus Task when subagents are opted in.
    local -a leantools=("${CLAUDE_LEAN_TOOLS[@]}")
    [[ "${LLMM_SUBAGENTS:-0}" == 1 ]] && leantools+=(Task)
    cargs+=(--tools "${leantools[@]}")
    # --system-prompt-file is a flag, so it terminates the variadic --tools list.
    cargs+=(--system-prompt-file "$prompt")
  fi
  if [[ -n "${LLMM_DRYRUN:-}" ]]; then
    local x
    for x in "${cenv[@]}";  do print -r -- "ENV $x"; done
    for x in "${cargs[@]}"; do print -r -- "ARG $x"; done
    for x in "$@";          do print -r -- "ARG $x"; done
    return 0
  fi
  exec env "${cenv[@]}" claude "${cargs[@]}" "$@"
}

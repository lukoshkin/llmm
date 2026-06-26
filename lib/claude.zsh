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

# claude::subagent_addendum -> path to the Task-usage guidance appended to the lean
# prompt only when LLMM_SUBAGENTS=1 (kept out of the base prompt so it never names an
# absent tool). Override with LLMM_SUBAGENT_PROMPT.
claude::subagent_addendum() {
  local p="${LLMM_SUBAGENT_PROMPT:-$LLMM_ROOT/prompts/lean-subagent.md}"
  [[ -f "$p" ]] || ui::die "subagent prompt addendum not found: $p"
  print -r -- "$p"
}

# claude::explore_addendum -> path to the explore-tool guidance prepended to the lean
# prompt when subagents are off (LLMM_SUBAGENTS != 1, the default). The weak local model
# will not emit Task calls but does call MCP tools, so explore is the delegation channel
# it actually uses. Override with LLMM_EXPLORE_PROMPT.
claude::explore_addendum() {
  local p="${LLMM_EXPLORE_PROMPT:-$LLMM_ROOT/prompts/lean-explore.md}"
  [[ -f "$p" ]] || ui::die "explore prompt addendum not found: $p"
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

# claude::checkpoint_pct -> validated stop-hook checkpoint-reminder threshold (integer 1..99).
# Fires before autoCompact so the model can save progress. Default 60 (well below autoCompact).
# Override with LLMM_CHECKPOINT_PCT.
claude::checkpoint_pct() {
  local pct="${LLMM_CHECKPOINT_PCT:-60}"
  if [[ "$pct" != <-> ]] || (( pct < 1 || pct > 99 )); then
    ui::die "LLMM_CHECKPOINT_PCT must be an integer 1..99, got: $pct"
  fi
  print -r -- "$pct"
}

# claude::session_id -> shell-safe unique-ish id for this launch.
# Returns a UUID for Claude Code's --session-id flag.
claude::session_id() { print -r -- "$(uuidgen | tr '[:upper:]' '[:lower:]')"; }

# claude::write_hooks_json <scratchpad_dir> <id> <ctx> <checkpoint_pct> -> prints the file path.
# checkpoint_pct: when the Stop-hook checkpoint reminder fires (% of ctx window; should be < compact pct).
claude::write_hooks_json() {
  local dir="$1" id="$2" ctx="$3" checkpoint_pct="$4"
  local hd="$LLMM_ROOT/lib/hooks" f="$1/hooks.$2.json"
  [[ -L "$f" ]] && ui::die "refusing to write through symlink: $f"
  cat > "$f" <<JSON
{
  "autoCompactWindow": $ctx,
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "LLMM_SCRATCHPAD_PCT=$checkpoint_pct CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx $hd/stop.sh"}]}],
    "SessionStart": [{"matcher": "compact", "hooks": [{"type": "command", "command": "$hd/session_start.sh $dir $id"}]}],
    "PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "$hd/post_tool_use.sh"}]}]
  }
}
JSON
  print -r -- "$f"
}

# claude::write_mcp_json <dir> <id> <want_scratch> <want_explore> <port> <alias> [mode] [claude_bin]
# Emits the per-session MCP config with each server included independently, and prints
# the file path. The scratchpad server (checkpoint/recall) and the explore server are
# gated separately so either can be on without the other. Repo root for explore is the
# parent of the .llmm dir. mode is the explore strategy (retrieval|agent, default
# retrieval); claude_bin is the claude path the agent mode spawns (empty -> server's PATH).
claude::write_mcp_json() {
  local dir="$1" id="$2" want_scratch="$3" want_explore="$4" port="$5" alias="$6"
  local mode="${7:-retrieval}" claude_bin="${8:-}"
  local hd="$LLMM_ROOT/lib/hooks" f="$dir/mcp.$id.json" root="${dir:h}"
  [[ -L "$f" ]] && ui::die "refusing to write through symlink: $f"
  local -a entries
  if [[ "$want_scratch" == 1 ]]; then
    entries+=('    "scratchpad": {
      "command": "uv",
      "args": ["run", "--with", "mcp", "python3", "'"$hd"'/scratchpad_server.py", "--session-id", "'"$id"'", "--scratchpad-dir", "'"$dir"'"]
    }')
  fi
  if [[ "$want_explore" == 1 ]]; then
    entries+=('    "explore": {
      "command": "uv",
      "args": ["run", "--with", "mcp", "python3", "'"$hd"'/explore_server.py", "--base-url", "http://127.0.0.1:'"$port"'", "--model", "'"$alias"'", "--root", "'"$root"'", "--mode", "'"$mode"'", "--claude-bin", "'"$claude_bin"'"]
    }')
  fi
  cat > "$f" <<JSON
{
  "mcpServers": {
${(pj:,\n:)entries}
  }
}
JSON
  print -r -- "$f"
}

# claude::reap_stale <scratchpad_dir> -> remove ephemeral hooks/mcp/pid files whose
# owning process is no longer running. Reads the PID from pid.<uuid>.txt rather than
# parsing the filename, because UUIDs don't embed PIDs. The persistent scratchpad .md
# is left untouched so the next session can resume it.
claude::reap_stale() {
  local dir="$1"
  local -a pid_files=("$dir"/pid.*.txt(N))
  local pid_file sid pid
  for pid_file in "${pid_files[@]}"; do
    pid="$(<"$pid_file")"
    [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null && continue
    sid="${${pid_file:t}#pid.}"
    sid="${sid%.txt}"
    rm -f "$dir/hooks.$sid.json" "$dir/mcp.$sid.json" "$dir/pid.$sid.txt"
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
    # ANTHROPIC_BASE_URL only redirects inference; telemetry/error-reporting/feedback hit
    # their own hardcoded endpoints and would still ship usage/prompt-adjacent data off a
    # session meant to be fully local. Disable those three. NOT the autoupdater: that is a
    # benign version check, a current CLI is worth keeping, and this env is scoped to the
    # llmm-launched claude only — suppressing it would freeze the CLI for anyone who runs
    # Claude exclusively through llmm. (The umbrella CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    # would also kill DISABLE_AUTOUPDATER, so we set the three individually instead.)
    DISABLE_TELEMETRY=1
    DISABLE_ERROR_REPORTING=1
    DISABLE_FEEDBACK_COMMAND=1
  )
  # Pin the model on the CLI in both modes: --model outranks the user's
  # ~/.claude/settings.json `model` key (which --bare does NOT suppress), so a global
  # pin like "opus[1m]" can't leak its label or 1M tag into an llmm session. Every
  # llmm session targets the local server (which ignores the model name); this just
  # makes the session self-describe as the local alias, not the inherited default.
  cargs+=(--model "$alias")
  # Skip --name when continuing: --continue/-c can grab any recent session
  # (including non-llmm ones) and would permanently rename it.
  # HH:MM:SS suffix distinguishes concurrent sessions from the same folder.
  local _is_continue=0
  for _a in "$@"; do [[ "$_a" == --continue || "$_a" == -c ]] && _is_continue=1 && break; done
  (( _is_continue )) || cargs+=(--name "$(basename "$PWD")-$(date +%H:%M:%S)")
  if [[ "$lean" == 1 ]]; then
    # Validate before building so bad config fails loudly and early.
    local prompt pct cpct
    prompt="$(claude::lean_prompt)" || exit 1
    pct="$(claude::compact_pct)" || exit 1
    cpct="$(claude::checkpoint_pct)" || exit 1
    cenv+=(
      CLAUDE_CODE_DISABLE_1M_CONTEXT=1
      CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx"
      CLAUDE_CODE_AUTO_COMPACT_WINDOW="$ctx"
      CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$pct"
      # Best-effort raise of the MCP tool-call timeout for slow local-model tools. NOTE:
      # observed not honored in the current CLI build (the client still timed out explore
      # at 120s), so explore_server's AGENT_TIMEOUT is set BELOW 120s as the real bound
      # rather than relying on this. Kept in case a future build honors it.
      MCP_TOOL_TIMEOUT=300000
    )
    cargs+=(--bare --strict-mcp-config)
    if [[ -n "${LLMM_MCP_CONFIG:-}" ]]; then
      [[ -f "$LLMM_MCP_CONFIG" ]] || ui::die "LLMM_MCP_CONFIG not found: $LLMM_MCP_CONFIG"
      cargs+=(--mcp-config "$LLMM_MCP_CONFIG")
    fi
    # MCP servers (explicit flags survive --bare). Two independent servers:
    #   scratchpad (checkpoint/recall)  — on unless LLMM_SCRATCHPAD=0
    #   explore     (delegated search)  — on unless subagents are opted in (LLMM_SUBAGENTS=1),
    #                                      since Task replaces it there
    # They share one per-session mcp.json; --settings (Stop/SessionStart hooks) is
    # scratchpad-only. The whole block engages if either server is wanted.
    local want_scratch=0 want_explore=0
    [[ "${LLMM_SCRATCHPAD:-1}" == 1 ]] && want_scratch=1
    [[ "${LLMM_SUBAGENTS:-0}" != 1 ]] && want_explore=1
    if (( want_scratch || want_explore )); then
      local sid scratch mcp emode cbin
      # When resuming an existing session, reuse its UUID so the scratchpad persists
      # across relaunches. Claude rejects --session-id alongside --resume unless
      # --fork-session is also present, so omit it and let --resume own the identity.
      local _resume_sid="" _has_fork=0 _skip_sid=0 _j
      for (( _j = 1; _j <= $#; _j++ )); do
        case "${@[_j]}" in
        --fork-session) _has_fork=1 ;;
        --resume|-r)    (( _j + 1 <= $# )) && _resume_sid="${@[_j+1]}" ;;
        --continue|-c)  _skip_sid=1 ;;
        esac
      done
      (( _has_fork )) && _resume_sid="" && _skip_sid=0
      if [[ -n "$_resume_sid" ]]; then
        sid="$_resume_sid"
      elif (( _skip_sid )); then
        # --continue/-c: find the most recent scratchpad UUID so it persists.
        # Don't pass --session-id; --continue owns the session identity.
        local _recent_md
        _recent_md="$(ls -t "$PWD/.llmm"/*.md 2>/dev/null | head -1)"
        if [[ -n "$_recent_md" ]]; then
          sid="${${_recent_md:t}%.md}"
        else
          sid="$(claude::session_id)"
        fi
      else
        sid="$(claude::session_id)"
        cargs+=(--session-id "$sid")
      fi
      scratch="$PWD/.llmm"
      mcp="$scratch/mcp.$sid.json"
      emode="${LLMM_EXPLORE_MODE:-retrieval}"
      # agent mode spawns a nested headless claude; resolve its path now (PATH is known
      # here, not necessarily inside the uv-run MCP server). Harmless when unused.
      cbin="$(command -v claude 2>/dev/null)"
      if [[ -z "${LLMM_DRYRUN:-}" ]]; then
        mkdir -p "$scratch"
        claude::reap_stale "$scratch"   # exec() below kills any EXIT trap; reap here instead
        claude::write_mcp_json "$scratch" "$sid" "$want_scratch" "$want_explore" "$port" "$alias" "$emode" "$cbin" >/dev/null
        # Store Claude's PID for session activity detection
        print -r -- $$ > "$scratch/pid.$sid.txt"
      fi
      cargs+=(--mcp-config "$mcp")
      # Auto-approve only the llmm-owned MCP tools so they never prompt: whole-server
      # rules (mcp__<server>) cover every tool the server exposes (checkpoint/recall,
      # explore). This is a permission allow-list, not a tool restriction — built-in
      # tools (Bash/Edit/Write) keep their normal prompting. Survives --bare (explicit flag).
      local -a mcpallow
      (( want_scratch )) && mcpallow+=(mcp__scratchpad)
      (( want_explore )) && mcpallow+=(mcp__explore)
      cargs+=(--allowedTools "${mcpallow[@]}")
      if (( want_scratch )); then
        local hooks="$scratch/hooks.$sid.json"
        [[ -z "${LLMM_DRYRUN:-}" ]] && claude::write_hooks_json "$scratch" "$sid" "$ctx" "$cpct" >/dev/null
        cargs+=(--settings "$hooks")
        cargs+=(--plugin-dir "$LLMM_ROOT/lib/claude-commands")
        cenv+=(LLMM_SCRATCHPAD_FILE="$scratch/$sid.md")
      fi
    fi
    # Tool list: lean core, plus Task when subagents are opted in.
    local -a leantools=("${CLAUDE_LEAN_TOOLS[@]}")
    [[ "${LLMM_SUBAGENTS:-0}" == 1 ]] && leantools+=(Task)
    cargs+=(--tools "${leantools[@]}")
    # System prompt. The base lean prompt must never name an absent tool, so the
    # delegation guidance is a separate addendum prepended inline (top placement = max
    # salience for a weak model; --system-prompt is a flag, so it still terminates the
    # variadic --tools list above). Subagents on -> Task addendum; otherwise -> explore
    # addendum (the MCP-channel delegation the model actually uses).
    if [[ "${LLMM_SUBAGENTS:-0}" == 1 ]]; then
      cargs+=(--system-prompt "$(<"$(claude::subagent_addendum)")"$'\n\n'"$(<"$prompt")")
    else
      cargs+=(--system-prompt "$(<"$(claude::explore_addendum)")"$'\n\n'"$(<"$prompt")")
    fi
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

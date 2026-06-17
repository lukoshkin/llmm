source "$LLMM_LIB/ui.zsh"
source "$LLMM_LIB/config.zsh"
source "$LLMM_LIB/claude.zsh"

# The lean prompt ships, is non-empty, and is economical (< 700 words).
assert_eq "$([[ -f "$LLMM_ROOT/prompts/lean-coder.md" ]] && print yes)" yes "lean prompt file ships"
typeset _pw=$(wc -w < "$LLMM_ROOT/prompts/lean-coder.md")
assert_eq "$(( _pw > 0 && _pw < 700 ))" 1 "lean prompt non-empty and < 700 words"

# --- lean build (no MCP opt-in) ---
typeset out
out="$(LLMM_DRYRUN=1 claude::launch myalias 11111 1 65536 2>&1)"
assert_contains "$out" "ENV ANTHROPIC_BASE_URL=http://127.0.0.1:11111" "lean sets base url"
assert_contains "$out" "ENV ANTHROPIC_DEFAULT_SONNET_MODEL=myalias" "lean sets alias env"
assert_contains "$out" "ENV CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1" "lean keeps beta disable"
assert_contains "$out" "ENV CLAUDE_CODE_DISABLE_1M_CONTEXT=1" "lean disables 1M-context detection"
assert_contains "$out" "ENV CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536" "lean sets model context size"
assert_contains "$out" "ENV CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536" "lean sets real window"
assert_contains "$out" "ENV CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80" "lean default compact pct"
assert_contains "$out" "ARG --bare" "lean passes --bare"
assert_contains "$out" "ARG --strict-mcp-config" "lean passes --strict-mcp-config"
# --model pins the local alias on the CLI so a user-settings model pin (e.g.
# opus[1m]) can't leak into the lean session (--bare does not suppress it).
assert_contains "$out" "ARG --model" "lean pins the model on the CLI"
assert_contains "$out" "ARG myalias" "lean --model is the local alias"
assert_contains "$out" "ARG --tools" "lean passes --tools"
assert_contains "$out" "ARG Bash" "lean keeps Bash"
assert_contains "$out" "ARG TodoWrite" "lean keeps TodoWrite"
assert_contains "$out" "ARG ExitPlanMode" "lean keeps ExitPlanMode for plan mode"
# Default lean (subagents off) prepends the explore addendum inline, not the base
# prompt via --system-prompt-file.
assert_not_contains "$out" "ARG --system-prompt-file" "default lean uses inline --system-prompt (explore addendum on top)"
assert_contains "$out" "explore(" "default lean injects the explore-tool guidance"
# Scratchpad is default-on: it adds --settings and its own --mcp-config.
assert_contains "$out" "ARG --settings" "lean wires scratchpad --settings"
assert_contains "$out" "ARG --mcp-config" "lean wires scratchpad --mcp-config"
assert_contains "$out" ".llmm/hooks." "lean settings path points at .llmm"
assert_contains "$out" ".llmm/mcp." "lean mcp path points at .llmm"

# Disabling the scratchpad drops the hooks (--settings) but explore (default-on) still
# wires --mcp-config. Both wires drop only when explore is also off (subagents on).
typeset out_ns
out_ns="$(LLMM_SCRATCHPAD=0 LLMM_DRYRUN=1 claude::launch a 11111 1 65536 2>&1)"
assert_not_contains "$out_ns" "ARG --settings" "LLMM_SCRATCHPAD=0 drops --settings"
assert_contains "$out_ns" "ARG --mcp-config" "LLMM_SCRATCHPAD=0 keeps --mcp-config (explore)"
typeset out_none
out_none="$(LLMM_SCRATCHPAD=0 LLMM_SUBAGENTS=1 LLMM_DRYRUN=1 claude::launch a 11111 1 65536 2>&1)"
assert_not_contains "$out_none" "ARG --settings" "scratchpad+explore both off drops --settings"
assert_not_contains "$out_none" "ARG --mcp-config" "scratchpad+explore both off drops --mcp-config"

# Subagents opt-in (LLMM_SUBAGENTS=1) swaps explore for Task: adds Task to --tools,
# prepends the Task addendum (worked example) inline, and drops the explore guidance.
typeset out_sa
out_sa="$(LLMM_SUBAGENTS=1 LLMM_DRYRUN=1 claude::launch a 11111 1 65536 2>&1)"
assert_contains "$out_sa" "ARG Task" "LLMM_SUBAGENTS=1 re-admits Task"
assert_contains "$out_sa" "subagent_type" "subagents-on injects the worked Task example"
assert_contains "$out_sa" "Task tool" "subagents-on guidance names the Task tool"
assert_not_contains "$out_sa" "ARG --system-prompt-file" "subagents-on uses inline --system-prompt (addendum on top)"
assert_not_contains "$out_sa" "explore(" "subagents-on drops the explore guidance"
assert_not_contains "$out" "subagent_type" "default lean omits Task guidance entirely"
assert_not_contains "$out" "ARG Task" "default lean drops Task/subagents"
assert_not_contains "$out" "ARG WebSearch" "lean drops WebSearch"

# --- full build: none of the lean flags, no window env ---
out="$(LLMM_DRYRUN=1 claude::launch myalias 11111 0 65536 2>&1)"
assert_not_contains "$out" "ARG --bare" "full omits --bare"
assert_not_contains "$out" "ARG --strict-mcp-config" "full omits --strict-mcp-config"
assert_not_contains "$out" "ARG --system-prompt-file" "full keeps default system prompt"
assert_not_contains "$out" "ENV CLAUDE_CODE_MAX_CONTEXT_TOKENS" "full omits model context env"
assert_not_contains "$out" "ENV CLAUDE_CODE_AUTO_COMPACT_WINDOW" "full omits window env"
# Model-pin insulation applies in both modes: full is also a local session.
assert_contains "$out" "ARG --model" "full pins the model on the CLI too"
assert_contains "$out" "ARG myalias" "full --model is the local alias"
assert_contains "$out" "ENV ANTHROPIC_BASE_URL=http://127.0.0.1:11111" "full still sets base url"

# --- extra claude args are forwarded in both modes ---
out="$(LLMM_DRYRUN=1 claude::launch myalias 11111 1 65536 --resume 2>&1)"
assert_contains "$out" "ARG --resume" "lean forwards extra args"

# --- LLMM_MCP_CONFIG opt-in re-admits --mcp-config <path> ---
typeset _mcp="$(mktemp)"; print '{}' > "$_mcp"
out="$(LLMM_MCP_CONFIG="$_mcp" LLMM_DRYRUN=1 claude::launch a 1 1 100 2>&1)"
assert_contains "$out" "ARG --mcp-config" "mcp opt-in adds --mcp-config"
assert_contains "$out" "ARG $_mcp" "mcp opt-in passes the path"
rm -f "$_mcp"

# --- LLMM_COMPACT_PCT override flows through ---
out="$(LLMM_COMPACT_PCT=70 LLMM_DRYRUN=1 claude::launch a 1 1 100 2>&1)"
assert_contains "$out" "ENV CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70" "compact pct override flows"

# --- validation: each bad input dies (rc 1). Subshell so ui::die can't kill the harness. ---
assert_rc 1 "$( (LLMM_COMPACT_PCT=150 LLMM_DRYRUN=1 claude::launch a 1 1 100) >/dev/null 2>&1; print $? )" "bad compact pct dies"
assert_rc 1 "$( (LLMM_COMPACT_PCT=abc LLMM_DRYRUN=1 claude::launch a 1 1 100) >/dev/null 2>&1; print $? )" "non-integer compact pct dies"
assert_rc 1 "$( (LLMM_SYSTEM_PROMPT=/no/such/prompt.md LLMM_DRYRUN=1 claude::launch a 1 1 100) >/dev/null 2>&1; print $? )" "missing prompt override dies"
assert_rc 1 "$( (LLMM_MCP_CONFIG=/no/such/mcp.json LLMM_DRYRUN=1 claude::launch a 1 1 100) >/dev/null 2>&1; print $? )" "missing mcp config dies"

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

# --- write_mcp_json includes each server independently and stays valid JSON ---
# both servers on
typeset _mf; _mf="$(claude::write_mcp_json "$_wd" testid 1 1 11111 myalias)"
typeset _mj; _mj="$(cat "$_mf")"
assert_contains "$_mj" "scratchpad_server.py" "mcp json points at scratchpad server"
assert_contains "$_mj" "explore_server.py" "mcp json points at explore server"
assert_contains "$_mj" "--with" "mcp json uses uv run --with mcp"
assert_contains "$_mj" "--session-id" "mcp json passes session id"
assert_contains "$_mj" "127.0.0.1:11111" "explore entry carries the server base url"
assert_contains "$_mj" "myalias" "explore entry carries the model alias"
assert_eq "$(python3 -m json.tool "$_mf" >/dev/null 2>&1 && print ok)" ok "both-server mcp json is valid"
# scratchpad only
_mf="$(claude::write_mcp_json "$_wd" sconly 1 0 11111 a)"; _mj="$(cat "$_mf")"
assert_contains "$_mj" "scratchpad_server.py" "scratchpad-only includes scratchpad"
assert_not_contains "$_mj" "explore_server.py" "scratchpad-only omits explore"
assert_eq "$(python3 -m json.tool "$_mf" >/dev/null 2>&1 && print ok)" ok "scratchpad-only mcp json is valid"
# explore only
_mf="$(claude::write_mcp_json "$_wd" exonly 0 1 11111 a)"; _mj="$(cat "$_mf")"
assert_contains "$_mj" "explore_server.py" "explore-only includes explore"
assert_not_contains "$_mj" "scratchpad_server.py" "explore-only omits scratchpad"
assert_eq "$(python3 -m json.tool "$_mf" >/dev/null 2>&1 && print ok)" ok "explore-only mcp json is valid"

# --- reap_stale removes dead-PID configs, keeps live-PID configs + the scratchpad .md ---
# (launch exec()s claude, so the EXIT trap never fires; reap_stale is the real cleanup.)
typeset _rd; _rd="$(mktemp -d)/.llmm"; mkdir -p "$_rd"
print x > "$_rd/hooks.20200101_000000_999999999.json"   # dead/impossible pid
print x > "$_rd/mcp.20200101_000000_999999999.json"
print x > "$_rd/hooks.20200101_000000_$$.json"           # this shell's live pid
print x > "$_rd/sess.md"
claude::reap_stale "$_rd"
assert_eq "$([[ -f "$_rd/hooks.20200101_000000_999999999.json" ]] && print y || print n)" n "reap removes dead-pid hooks"
assert_eq "$([[ -f "$_rd/mcp.20200101_000000_999999999.json" ]] && print y || print n)" n "reap removes dead-pid mcp"
assert_eq "$([[ -f "$_rd/hooks.20200101_000000_$$.json" ]] && print y || print n)" y "reap keeps live-pid hooks"
assert_eq "$([[ -f "$_rd/sess.md" ]] && print y || print n)" y "reap keeps scratchpad md"

# --- writers refuse to follow a pre-planted symlink (symlink-clobber guard) ---
typeset _lt; _lt="$(mktemp)"
ln -s "$_lt" "$_rd/hooks.evil.json"
assert_rc 1 "$( (claude::write_hooks_json "$_rd" evil 65536 85) >/dev/null 2>&1; print $? )" "write_hooks_json refuses symlink target"
assert_eq "$(cat "$_lt")" "" "symlink target left untouched"
rm -f "$_lt" "$_rd/hooks.evil.json"

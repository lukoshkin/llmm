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

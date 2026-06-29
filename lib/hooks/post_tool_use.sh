#!/usr/bin/env sh
# PostToolUse hook: nudge the model to checkpoint before context pressure forces compaction.
# - Write: always nudge (findings just landed on disk).
# - Bash:  nudge only when context >= LLMM_SCRATCHPAD_PCT (same threshold as stop.sh).
input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

if [ "$tool" = "Write" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"If this write produced findings, a status change, or a decision worth preserving across compaction, call checkpoint() now."}}\n'
  exit 0
fi

# Bash path: only fire when context is building toward the compaction threshold.
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

max=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-0}
pct=${LLMM_SCRATCHPAD_PCT:-85}
[ "$max" -gt 0 ] 2>/dev/null || exit 0

# NOTE: input_tokens is from the last completed assistant message (start of
# current turn); actual live count may be higher in a long tool-call chain.
tokens=$(tail -n 80 "$tp" | jq -rs '[.[] | select(.type == "assistant") | ((.message.usage.input_tokens // .usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // .usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // .usage.cache_creation_input_tokens // 0))] | last // 0')
[ -n "$tokens" ] || tokens=0

thr=$((max * pct / 100))
if [ "$tokens" -ge "$thr" ]; then
  used=$((tokens * 100 / max))
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"CHECKPOINT RECOMMENDED: context at %d%%. If you have unsaved findings, decisions, or status, call checkpoint() before continuing."}}\n' "$used"
fi
exit 0

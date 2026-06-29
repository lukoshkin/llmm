#!/usr/bin/env sh
# Stop hook: near the context threshold, force a checkpoint before autocompaction.
input=$(cat)

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$active" = "true" ] && exit 0 # loop guard: do not re-fire after we forced a continue

tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

max=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-0}
pct=${LLMM_SCRATCHPAD_PCT:-85}
[ "$max" -gt 0 ] 2>/dev/null || exit 0

# Last prompt-token count = current context size proxy. Scan only the tail (bounded cost).
# Field path is version-sensitive — try .message.usage.input_tokens then .usage.input_tokens.
tokens=$(tail -n 80 "$tp" | jq -rs '[.[] | select(.type == "assistant") | ((.message.usage.input_tokens // .usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // .usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // .usage.cache_creation_input_tokens // 0))] | last // 0')
[ -n "$tokens" ] || tokens=0

thr=$((max * pct / 100))
if [ "$tokens" -ge "$thr" ]; then
  used=$((tokens * 100 / max))
  # continue:true prevents Claude from stopping so it can act on the message.
  # The loop guard (stop_hook_active) ensures this fires only once per stop attempt.
  printf '{"continue":true,"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"CHECKPOINT REQUIRED: context at %d%%. Call checkpoint(section,content,mode) for any unsaved Findings/Decisions/Dead ends/Status now, before any other action."}}\n' "$used"
fi
exit 0

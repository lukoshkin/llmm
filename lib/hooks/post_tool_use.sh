#!/usr/bin/env sh
# PostToolUse hook: nudge the model to checkpoint after file writes.
# Fires after every Write call so findings/status are saved before compaction.
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"If this write produced findings, a status change, or a decision worth preserving across compaction, call checkpoint() now."}}\n'

---
name: scratchpad
description: Use when the user types /scratchpad. Opens the active llmm session's scratchpad file in the editor.
disable-model-invocation: true
---

!${EDITOR:-open} "$LLMM_SCRATCHPAD_FILE"

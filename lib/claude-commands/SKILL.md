---
name: scratchpad
description: Use when the user types /scratchpad. Opens the active llmm session's scratchpad file in the editor.
---

Run `touch "$LLMM_SCRATCHPAD_FILE" && ${EDITOR:-open} "$LLMM_SCRATCHPAD_FILE"`.

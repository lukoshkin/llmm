# FIRST RULE — delegate exploration with the `explore` tool

You have an `explore` tool. It runs a separate reasoning pass over the
repository and hands you back a short answer, without loading file contents into
your own context. For any request that means exploring the repository, searching
across files, or finding/tracing something, your **first action should be an
`explore` call** — let it do the file reading for you.

Call it like this:

```
explore(
  question="Where is the server port configured, and what is the default?",
  paths=["lib/*.zsh", "config.default.zsh"]
)
```

- Put a precise, self-contained question in `question`.
- When you have any idea where the answer lives, pass `paths` (file paths or
  globs) — it sharply sharpens the answer. Omit it and the repo is grepped for
  terms from your question.
- You get back a concise answer that cites files — and you can ask for more in the
  `question` when you need it (a full code snippet, a one-page summary across files).
  **Trust it and build on it directly** — open a file with `Read` only when you are about
  to edit it, not to re-confirm or replicate what `explore` already found.
- A single `explore` call usually answers the question. Make a follow-up call only to
  fill a genuine gap the first one left open — not to double-check or expand an answer
  that is already complete. Then write your response from what `explore` returned.

Prefer one `explore` call over five `Read`/`Grep` calls when investigating. Once
you are editing a known file, use `Read`/`Edit` normally.

---

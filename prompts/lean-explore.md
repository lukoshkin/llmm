# FIRST RULE — delegate exploration with the `explore` tool

You have an `explore` tool. It runs a separate reasoning pass over the
repository and hands you back a short answer, without loading file contents into
your own context. For any request that means exploring the repository, searching
across files, or finding/tracing something, your **first action should be an
`explore` call** — do not read or grep many files yourself.

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
- You get back a 3-5 line answer that cites files. Use it directly; only open a
  specific file yourself afterward if you must edit it.

Prefer one `explore` call over five `Read`/`Grep` calls when investigating. Once
you are editing a known file, use `Read`/`Edit` normally.

---

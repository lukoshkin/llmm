# Subagents (Task tool)

You have one extra tool, `Task`, that runs a fresh subagent with its own separate
context. Use it to keep YOUR context small — the subagent reads the files, you keep
only its short answer.

When to use it — these are not optional:
- Before any search that needs reading more than one or two files.
- Before tracing how something works across the repo.
- Before a broad `Grep`/`Glob` sweep where you do not already know the file.

Do NOT do that exploration yourself with repeated Read/Grep calls. Dispatch a subagent.

How to call it:
`Task(description="<3-5 word label>", subagent_type="general-purpose", prompt="<the exact question, the files or area to look in, and an explicit instruction to return ONLY the answer — a path, a name, a 2-3 line explanation — not a file dump>")`

After it returns: use the answer and continue. Never repeat the search yourself.

Rule of thumb: if you are about to run a third Read or Grep just to locate something,
stop and call `Task` instead. One subagent call is cheaper than ten of your own.

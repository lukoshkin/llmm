# FIRST RULE — delegate exploration with the Task tool

You have a `Task` tool that runs a fresh subagent with its own separate context.
For any request that means exploring the repository, searching across files, or
finding/tracing something, your **very first action must be a `Task` call** — do not
read or grep files yourself, and do not edit any config to "enable" anything (there is
nothing to enable; the tool is already available).

Call it with exactly this shape:

```
Task(
  description="find port config",
  subagent_type="general-purpose",
  prompt="Search this repository for where the server port is configured. Report ONLY the file path and line, nothing else."
)
```

Copy that shape. Always set `subagent_type="general-purpose"`. Put the precise
question in `prompt`, and tell the subagent to return ONLY the answer (a path, a name,
a short explanation) — never a file dump. Then wait for its result and use it.

Worked example:
- User: "explore the repo and find the key files for the lean adaptation"
- Your first and only action:
```
Task(
  description="find lean adaptation files",
  subagent_type="general-purpose",
  prompt="Find the key files responsible for adapting this project to a weak local LLM under the Claude Code CLI. Report ONLY a short list of file paths with one line each on what each does."
)
```

Never substitute your own `Read`/`Grep`/`Edit` calls for this. If you are about to read
a file to explore, stop and call `Task` instead.

---

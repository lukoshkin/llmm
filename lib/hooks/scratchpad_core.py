"""Pure-stdlib parse/merge/read for the sectioned scratchpad. No mcp dependency."""

from __future__ import annotations

import re

HEADERS = ["Task", "Status", "Findings", "Decisions", "Dead ends", "Open questions"]
KEY_TO_HEADER = {
    "task": "Task",
    "status": "Status",
    "findings": "Findings",
    "decisions": "Decisions",
    "dead_ends": "Dead ends",
    "open_questions": "Open questions",
}

# Weak models improvise section names ("task_status", "Summary", "dead-ends"). Map
# common synonyms onto the six canonical keys so a checkpoint lands somewhere sensible
# instead of failing. Unrecognized names fall back to "findings" (see resolve_section).
_ALIASES = {
    "goal": "task",
    "objective": "task",
    "plan": "task",
    "state": "status",
    "progress": "status",
    "current": "status",
    "summary": "status",
    "update": "status",
    "finding": "findings",
    "discovery": "findings",
    "discoveries": "findings",
    "note": "findings",
    "notes": "findings",
    "learning": "findings",
    "learnings": "findings",
    "observation": "findings",
    "observations": "findings",
    "result": "findings",
    "results": "findings",
    "decision": "decisions",
    "choice": "decisions",
    "choices": "decisions",
    "deadend": "dead_ends",
    "deadends": "dead_ends",
    "failure": "dead_ends",
    "failures": "dead_ends",
    "failed": "dead_ends",
    "blocker": "dead_ends",
    "blockers": "dead_ends",
    "question": "open_questions",
    "questions": "open_questions",
    "todo": "open_questions",
    "todos": "open_questions",
    "open": "open_questions",
}


def resolve_section(section: str) -> str:
    """Map a possibly-improvised section name onto a canonical key. Never raises:
    normalize case/separators, try the canonical keys, then the alias table, then a
    compound name like "task_status" (take the last recognized token — compound names
    usually name the category last), and finally fall back to "findings"."""
    norm = re.sub(r"[^a-z0-9]+", "_", section.strip().lower()).strip("_")
    if norm in KEY_TO_HEADER:
        return norm
    if norm in _ALIASES:
        return _ALIASES[norm]
    resolved = None
    for tok in norm.split("_"):
        if tok in KEY_TO_HEADER:
            resolved = tok
        elif tok in _ALIASES:
            resolved = _ALIASES[tok]
    return resolved or "findings"


def resolve_mode(mode: str) -> str:
    """Map a mode string onto 'append' or 'replace'; default to the safer 'append'
    so a fumbled mode never overwrites or crashes."""
    m = mode.strip().lower()
    return "replace" if m in ("replace", "overwrite", "set", "reset") else "append"


def _header(section: str) -> str:
    return KEY_TO_HEADER[resolve_section(section)]


def empty_doc() -> str:
    return "\n\n".join(f"## {h}\n" for h in HEADERS) + "\n"


def parse_sections(text: str) -> dict[str, str]:
    sections: dict[str, str] = {h: "" for h in HEADERS}
    current: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        if line.startswith("## "):
            if current is not None:
                sections[current] = "\n".join(buf).strip("\n")
            header = line[3:].strip()
            current = header if header in sections else None
            buf = []
        elif current is not None:
            buf.append(line)
    if current is not None:
        sections[current] = "\n".join(buf).strip("\n")
    return sections


def render(sections: dict[str, str]) -> str:
    parts = []
    for h in HEADERS:
        body = sections.get(h, "").strip("\n")
        parts.append(f"## {h}\n{body}".rstrip() + "\n")
    return "\n".join(parts) + "\n"


def merge(text: str, section: str, content: str, mode: str) -> str:
    header = _header(section)
    sections = parse_sections(text)
    content = content.strip()
    if resolve_mode(mode) == "replace":
        sections[header] = content
    else:
        existing = sections[header].strip("\n")
        bullet = content if content.startswith("- ") else f"- {content}"
        sections[header] = f"{existing}\n{bullet}".strip("\n") if existing else bullet
    return render(sections)


def read_section(text: str, section: str) -> str:
    return parse_sections(text)[_header(section)]

"""Pure-stdlib parse/merge/read for the sectioned scratchpad. No mcp dependency."""

from __future__ import annotations

HEADERS = ["Task", "Status", "Findings", "Decisions", "Dead ends", "Open questions"]
KEY_TO_HEADER = {
    "task": "Task",
    "status": "Status",
    "findings": "Findings",
    "decisions": "Decisions",
    "dead_ends": "Dead ends",
    "open_questions": "Open questions"
}


def _header(section: str) -> str:
    if section not in KEY_TO_HEADER:
        raise ValueError(
            f"unknown section: {section!r}; valid: {sorted(KEY_TO_HEADER)}"
        )
    return KEY_TO_HEADER[section]


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
    if mode == "replace":
        sections[header] = content
    elif mode == "append":
        existing = sections[header].strip("\n")
        bullet = content if content.startswith("- ") else f"- {content}"
        sections[header] = f"{existing}\n{bullet}".strip("\n") if existing else bullet
    else:
        raise ValueError(f"mode must be 'append' or 'replace', got {mode!r}")
    return render(sections)


def read_section(text: str, section: str) -> str:
    return parse_sections(text)[_header(section)]

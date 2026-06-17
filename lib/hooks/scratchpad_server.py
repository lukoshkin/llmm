"""Stdio MCP server exposing checkpoint + recall over a sectioned scratchpad file."""
from __future__ import annotations

import argparse
import os

from mcp.server.fastmcp import FastMCP

import scratchpad_core as sc

parser = argparse.ArgumentParser()
parser.add_argument("--session-id", required=True)
parser.add_argument("--scratchpad-dir", required=True)
args = parser.parse_args()

PATH = os.path.join(args.scratchpad_dir, f"{args.session_id}.md")
mcp = FastMCP("scratchpad")


def _read() -> str:
    if os.path.exists(PATH):
        with open(PATH, encoding="utf-8") as fh:
            return fh.read()
    return sc.empty_doc()


def _write(text: str) -> None:
    os.makedirs(args.scratchpad_dir, exist_ok=True)
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(text)


@mcp.tool()
def checkpoint(section: str, content: str, mode: str = "append") -> str:
    """Save progress to one scratchpad section. mode=append for findings/decisions/dead_ends/open_questions, replace for task/status."""
    _write(sc.merge(_read(), section, content, mode))
    return f"saved to {section}"


@mcp.tool()
def recall(section: str = "") -> str:
    """Read one scratchpad section on demand (e.g. dead_ends before retrying). Empty arg lists section names."""
    if not section:
        return ", ".join(sc.KEY_TO_HEADER)
    return sc.read_section(_read(), section) or f"(section {section} is empty)"


if __name__ == "__main__":
    mcp.run()

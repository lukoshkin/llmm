"""Stdio MCP server exposing `explore`: offload a codebase question to the local
model in an isolated process so the bulky retrieval tokens never enter the main
session's context.

v1 = hint-guided read (or keyword grep) + one chat-completion call. The weak local
model reliably calls MCP tools but will not emit Task calls, so this gives it the
context-isolation benefit of a subagent through the channel it actually uses.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import urllib.error
import urllib.request

from mcp.server.fastmcp import FastMCP

parser = argparse.ArgumentParser()
parser.add_argument(
    "--base-url", required=True, help="llama-server base, e.g. http://127.0.0.1:11111"
)
parser.add_argument("--model", required=True, help="model alias the server answers to")
parser.add_argument("--root", default=os.getcwd(), help="repo root to search")
args = parser.parse_args()

BASE_URL = args.base_url.rstrip("/")
MODEL = args.model
ROOT = os.path.abspath(args.root)
ROOT_REAL = os.path.realpath(ROOT)

MAX_FILES = 8
MAX_FILE_CHARS = 4000
BUDGET = 14000
ANSWER_CAP = 1600
TIMEOUT = 120

_STOP = {
    "the",
    "a",
    "an",
    "and",
    "or",
    "of",
    "to",
    "in",
    "is",
    "are",
    "how",
    "what",
    "where",
    "which",
    "does",
    "do",
    "for",
    "with",
    "this",
    "that",
    "it",
    "on",
    "find",
    "get",
    "use",
    "used",
    "uses",
    "from",
    "into",
    "when",
    "why",
    "who",
}

mcp = FastMCP("explore")


def _terms(question: str) -> list[str]:
    words = re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", question)
    return [w for w in dict.fromkeys(words) if w.lower() not in _STOP][:8]


def _in_root(path: str) -> bool:
    """True only if path (symlinks resolved) is ROOT or lives under it. Confines every
    read to the repo so a hint like '/etc/passwd', '../../x', or a symlink pointing
    outside ROOT cannot exfiltrate files into the explore summary."""
    rp = os.path.realpath(path)
    return rp == ROOT_REAL or rp.startswith(ROOT_REAL + os.sep)


def _expand_paths(paths: list[str]) -> list[str]:
    out: list[str] = []
    for p in paths:
        if os.path.isabs(p):
            continue  # hints are repo-relative; ignore absolute escapes
        matches = glob.glob(os.path.join(ROOT, p), recursive=True)
        out.extend(matches if matches else [os.path.join(ROOT, p)])
    return [p for p in dict.fromkeys(out) if os.path.isfile(p) and _in_root(p)]


def _grep_files(terms: list[str]) -> list[str]:
    if not terms:
        return []
    pattern = "|".join(re.escape(t) for t in terms)
    rg = shutil.which("rg")
    if rg:
        cmd = [rg, "-l", "-i", "-e", pattern, ROOT]
    else:
        cmd = [
            "grep",
            "-rIl",
            "-i",
            "-E",
            "--exclude-dir=.git",
            "--exclude-dir=.llmm",
            "--exclude-dir=node_modules",
            pattern,
            ROOT,
        ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    hits = [ln for ln in res.stdout.splitlines() if ln.strip() and _in_root(ln)]
    return hits[:MAX_FILES]


def _gather(question: str, paths: list[str]) -> str:
    files = (_expand_paths(paths) if paths else _grep_files(_terms(question)))[
        :MAX_FILES
    ]
    chunks: list[str] = []
    used = 0
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                body = fh.read(MAX_FILE_CHARS)
        except OSError:
            continue
        block = f"### {os.path.relpath(f, ROOT)}\n{body}"
        if used + len(block) > BUDGET:
            block = block[: BUDGET - used]
        chunks.append(block)
        used += len(block)
        if used >= BUDGET:
            break
    return "\n\n".join(chunks)


def _ask(question: str, context: str) -> str:
    system = (
        "You are a code-exploration assistant. Answer the question using ONLY the "
        "repository context provided. Be concise: 3-5 lines max, cite file paths. If "
        "the context does not contain the answer, say so plainly."
    )
    user = f"Question: {question}\n\nRepository context:\n{context or '(no matching files found)'}"
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": 400,
        "temperature": 0.2,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{BASE_URL}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        out = json.load(resp)
    return out["choices"][0]["message"]["content"].strip()


@mcp.tool()
def explore(question: str, paths: list[str] | None = None) -> str:
    """Offload a codebase question to a fresh, isolated reasoning pass so the bulky file
    contents never enter your context. Pass `paths` (files or globs) when you know roughly
    where to look — it sharply improves the answer; otherwise the repo is grepped for terms
    from your question. Returns a short (3-5 line) answer. Use this INSTEAD of reading many
    files yourself when exploring or searching the codebase."""
    context = _gather(question, paths or [])
    try:
        answer = _ask(question, context)
    except (urllib.error.URLError, TimeoutError) as e:
        return f"explore unavailable ({e}); fall back to reading files yourself."
    return answer[:ANSWER_CAP]


if __name__ == "__main__":
    mcp.run()

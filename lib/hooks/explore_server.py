"""Stdio MCP server exposing `explore`: offload a codebase question to an isolated
process so the bulky retrieval tokens never enter the main session's context. The weak
local model reliably calls MCP tools but will not emit Task calls, so this gives it the
context-isolation benefit of a subagent through the channel it actually uses.

Two strategies, picked by --mode (transparent to the caller — the tool signature is the
same either way):

  retrieval (v1, default): hint-guided read (or keyword grep) + one chat-completion call.
  agent     (v2): spawn a nested headless `claude -p` with read-only tools, letting the
                  local model drive its own Read/Grep/Glob loop; capture its answer.
                  Falls back to retrieval if claude is unavailable or the run fails.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse

from mcp.server.fastmcp import FastMCP

parser = argparse.ArgumentParser()
parser.add_argument(
    "--base-url", required=True, help="llama-server base, e.g. http://127.0.0.1:11111"
)
parser.add_argument("--model", required=True, help="model alias the server answers to")
parser.add_argument("--root", default=os.getcwd(), help="repo root to search")
parser.add_argument("--mode", default="retrieval", choices=("retrieval", "agent"))
parser.add_argument(
    "--claude-bin", default="", help="claude path for agent mode (empty -> PATH)"
)
args = parser.parse_args()

BASE_URL = args.base_url.rstrip("/")
MODEL = args.model
ROOT = os.path.abspath(args.root)
ROOT_REAL = os.path.realpath(ROOT)
MODE = args.mode
CLAUDE_BIN = args.claude_bin or shutil.which("claude") or ""

MAX_FILES = 8
MAX_FILE_CHARS = 6000  # raised: grep-with-context output can be longer than raw head
CONTEXT_LINES = 20  # lines of surrounding context per grep hit in _read_relevant
GREP_MAX_MATCHES = 3  # max hits per file when doing in-file grep
BUDGET = 14000
ANSWER_CAP = 4000
TIMEOUT = 120
# The parent's MCP tool-call timeout is observed to be 120s (MCP_TOOL_TIMEOUT did not
# raise it in this CLI build). The whole explore() call must finish under it, INCLUDING a
# retrieval fallback after the agent is killed. Both bounds are enforced timeouts:
#   AGENT_TIMEOUT (subprocess kill) + AGENT_FALLBACK_ASK_TIMEOUT (fallback HTTP) + overhead
#   = 70 + 35 + slack  ~= 110s < 120s, guaranteed.
AGENT_TIMEOUT = 70
AGENT_FALLBACK_ASK_TIMEOUT = 35
# Cap the real-file listing seeded into the agent prompt so it grounds in actual paths
# instead of hallucinating training-data ones, without blowing the small nested window.
REPO_FILES_MAX = 200
REPO_FILES_BUDGET = 6000

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


def _read_relevant(f: str, terms: list[str]) -> str:
    """Extract relevant sections of f by grepping for terms with surrounding context.
    Falls back to reading from the start when terms produce no hits in the file."""
    if terms:
        pattern = "|".join(re.escape(t) for t in terms)
        rg = shutil.which("rg")
        cmd = (
            [rg, "-n", "-C", str(CONTEXT_LINES), "-m", str(GREP_MAX_MATCHES), "-i", "-e", pattern, f]
            if rg
            else ["grep", "-n", "-C", str(CONTEXT_LINES), "-i", "-E", pattern, f]
        )
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.stdout.strip():
            return res.stdout[:MAX_FILE_CHARS]
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            return fh.read(MAX_FILE_CHARS)
    except OSError:
        return ""


def _gather(question: str, paths: list[str]) -> str:
    terms = _terms(question)
    files = (_expand_paths(paths) if paths else _grep_files(terms))[:MAX_FILES]
    chunks: list[str] = []
    used = 0
    for f in files:
        body = _read_relevant(f, terms)
        if not body:
            continue
        block = f"### {os.path.relpath(f, ROOT)}\n{body}"
        if used + len(block) > BUDGET:
            block = block[: BUDGET - used]
        chunks.append(block)
        used += len(block)
        if used >= BUDGET:
            break
    return "\n\n".join(chunks)


def _ask(question: str, context: str, timeout: int = TIMEOUT) -> str:
    system = (
        "You are a code-exploration assistant. Answer the question using ONLY the "
        "repository context provided, citing file paths. "
        "Reply in plain prose — do NOT output Python, shell, pseudocode, or any "
        "function-call syntax such as explore(...), Task(...), or similar constructs. "
        "Default to a few lines; when the question asks for a code excerpt or a broad "
        "summary, reproduce the actual code from the context — up to roughly a page. "
        "If the context does not contain the answer, say so in one sentence."
    )
    user = f"Question: {question}\n\nRepository context:\n{context or '(no matching files found)'}"
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": 1000,
        "temperature": 0.2,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{BASE_URL}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        out = json.load(resp)
    return out["choices"][0]["message"]["content"].strip()


def _retrieval(question: str, paths: list[str], ask_timeout: int = TIMEOUT) -> str:
    """v1: gather context in-process, one summary call. ask_timeout is tightened when this
    runs as an agent-mode fallback so the whole explore() stays under the 120s ceiling."""
    context = _gather(question, paths)
    try:
        answer = _ask(question, context, ask_timeout)
    except (urllib.error.URLError, TimeoutError) as e:
        return f"explore unavailable ({e}); fall back to reading files yourself."
    return answer[:ANSWER_CAP]


# Explicit prohibition is included despite the risk that naming it primes small models:
# the alternative (no prohibition) produces worse failures (pseudocode echoed as answers).
_AGENT_SYSTEM = (
    "You are a read-only code-exploration assistant with three tools: Grep, Glob, and Read. "
    "Investigate by calling them directly — your first action is a Grep or Glob call to "
    "locate the relevant files, then Read the few that matter. Use paths relative to the "
    "current directory (e.g. `lib/server.zsh`); to list or search a directory, use Glob or "
    "Grep, not Read. Work efficiently — about 8 tool calls at most — then stop and reply "
    "with only the final answer in plain prose, citing the file paths. "
    "Do NOT output Python, shell, pseudocode, or any function-call syntax in your final reply. "
    "Default to a few lines; when the question asks for a code excerpt or a broad summary, "
    "reproduce the actual code — up to roughly a page."
)

_AGENT_SETTINGS_PATH = ""


def _agent_settings() -> str:
    """Write (once) a settings file confining the child's reads to ROOT. All three read
    tools are scoped — Read/Grep/Glob each take a path, so leaving Grep/Glob unscoped
    would let the model search/enumerate outside ROOT. With --permission-mode default in
    headless -p, a call outside ROOT is unmatched and denied (no prompt to approve it).
    NOTE: the path-specifier syntax for Grep/Glob is not verified against this CLI build;
    if it is wrong it fails SAFE (unmatched -> denied), never open — but in-repo Grep/Glob
    must be live-verified to still work (open item in the spec)."""
    global _AGENT_SETTINGS_PATH
    if _AGENT_SETTINGS_PATH:
        return _AGENT_SETTINGS_PATH
    cfg = {
        "permissions": {
            "allow": [f"Read({ROOT}/**)", f"Grep({ROOT}/**)", f"Glob({ROOT}/**)"]
        }
    }
    d = os.path.join(ROOT, ".llmm")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "explore-agent-settings.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh)
    _AGENT_SETTINGS_PATH = p
    return p


def _repo_files() -> str:
    """A capped listing of the repo's real, relative file paths. Seeded into the agent
    prompt so the model reads existing files instead of guessing training-data paths like
    /home/user/github/...; `git ls-files` (tracked files only), with a glob fallback."""
    try:
        res = subprocess.run(
            ["git", "-C", ROOT, "ls-files"], capture_output=True, text=True, timeout=10
        )
        files = res.stdout.split() if res.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        files = []
    if not files:
        hits = glob.glob(os.path.join(ROOT, "**", "*"), recursive=True)
        files = [
            os.path.relpath(p, ROOT)
            for p in hits
            if os.path.isfile(p) and ".git/" not in p and "/.llmm/" not in p
        ]
    listing = "\n".join(sorted(files)[:REPO_FILES_MAX])
    return listing[:REPO_FILES_BUDGET]


def _log(msg: str) -> None:
    """Surface a one-line reason on the server's stderr (visible in Claude Code's MCP
    logs) so a failing/degraded agent mode is diagnosable instead of silent."""
    print(f"[explore agent] {msg}", file=sys.stderr, flush=True)


def _is_loopback(base_url: str) -> bool:
    """Only spawn the nested session against a local server. This is the hard guarantee
    that agent mode talks to the local model, never api.anthropic.com."""
    return urlparse(base_url).hostname in ("127.0.0.1", "localhost", "::1", "0.0.0.0")


def _agent(question: str, paths: list[str]) -> str:
    """v2: spawn a nested headless `claude -p` that drives its own read-only tool loop in
    an isolated process. Falls back to retrieval (logging why) if it can't run safely."""
    if not CLAUDE_BIN:
        _log("no claude binary; using retrieval")
        return _retrieval(question, paths)
    if not _is_loopback(BASE_URL):
        _log(f"refusing non-loopback base url {BASE_URL!r}; using retrieval")
        return _retrieval(question, paths)
    if ROOT_REAL == os.path.realpath(os.path.expanduser("~")) or ROOT_REAL == os.sep:
        _log(f"refusing to explore broad root {ROOT_REAL!r}; using retrieval")
        return _retrieval(question, paths)
    fb = AGENT_FALLBACK_ASK_TIMEOUT  # tightened so agent + fallback stays under 120s
    prompt = question
    prompt += f"\n\nYour working directory is the project root: {ROOT}"
    listing = _repo_files()
    if listing:
        prompt += (
            "\n\nThese are the repository's files (relative to that root). Read only from "
            "this list, using each path exactly as shown:\n" + listing
        )
    if paths:
        prompt += "\n\nStart from: " + ", ".join(paths)
    # Force the local endpoint + dummy creds so the child cannot reach the real API:
    # routing is by base url, and the key is a placeholder that would fail elsewhere.
    env = dict(os.environ)
    env.update(
        ANTHROPIC_BASE_URL=BASE_URL,
        ANTHROPIC_API_KEY="llama-cpp",
        ANTHROPIC_AUTH_TOKEN="llama-cpp",
        ANTHROPIC_DEFAULT_SONNET_MODEL=MODEL,
        ANTHROPIC_DEFAULT_OPUS_MODEL=MODEL,
        ANTHROPIC_DEFAULT_HAIKU_MODEL=MODEL,
        CLAUDE_CODE_DISABLE_1M_CONTEXT="1",
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1",
    )
    # --permission-mode default + a generated --settings allow-list scoped to ROOT: in
    # headless -p, reads under ROOT are pre-approved (no prompt) while reads outside ROOT
    # are unmatched and denied — confining the child without bypassing permissions, so a
    # hallucinated absolute path is denied rather than read. --output-format text pins
    # stdout to a bare answer; --strict-mcp-config with no --mcp-config means the child has
    # no MCP servers (no recursion back into explore).
    cmd = [
        CLAUDE_BIN,
        "-p",
        prompt,
        "--bare",
        "--strict-mcp-config",
        "--settings",
        _agent_settings(),
        "--output-format",
        "text",
        "--tools",
        "Read",
        "Grep",
        "Glob",
        "--model",
        MODEL,
        "--permission-mode",
        "default",
        "--system-prompt",
        _AGENT_SYSTEM,
    ]
    try:
        res = subprocess.run(
            cmd,
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=AGENT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        _log(f"timed out after {AGENT_TIMEOUT}s; using retrieval")
        return _retrieval(question, paths, fb)
    answer = res.stdout.strip()
    if res.returncode != 0 or not answer:
        tail = " | ".join((res.stderr or "").strip().splitlines()[-3:])
        _log(f"exit={res.returncode} empty={not answer}; stderr: {tail}")
        return _retrieval(question, paths, fb)
    return answer[:ANSWER_CAP]


@mcp.tool()
def explore(question: str, paths: list[str] | None = None) -> str:
    """Offload a codebase question to a fresh, isolated reasoning pass so the bulky file
    contents never enter your context. Pass `paths` (files or globs) when you know roughly
    where to look — it sharply improves the answer; otherwise the repo is grepped for terms
    from your question. Returns a concise answer by default — ask for a code snippet or a
    fuller summary in your question when you need one. Use this INSTEAD of reading many
    files yourself when exploring or searching the codebase."""
    paths = paths or []
    return _agent(question, paths) if MODE == "agent" else _retrieval(question, paths)


if __name__ == "__main__":
    mcp.run()

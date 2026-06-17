"""Standalone checks for explore_server's retrieval helpers and HTTP error fallback.
Stubs the `mcp` package so the module imports without it installed. Run:
    python3 tests/explore_server_test.py
"""

import importlib.util
import json
import os
import sys
import types
import urllib.error

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _load():
    fastmcp = types.ModuleType("mcp.server.fastmcp")

    class FastMCP:
        def __init__(self, *a, **k):
            pass

        def tool(self, *a, **k):
            return lambda fn: fn

        def run(self):
            pass

    fastmcp.FastMCP = FastMCP
    sys.modules["mcp"] = types.ModuleType("mcp")
    sys.modules["mcp.server"] = types.ModuleType("mcp.server")
    sys.modules["mcp.server.fastmcp"] = fastmcp
    sys.argv = [
        "explore_server.py",
        "--base-url",
        "http://127.0.0.1:11111",
        "--model",
        "myalias",
        "--root",
        REPO,
    ]
    path = os.path.join(REPO, "lib", "hooks", "explore_server.py")
    spec = importlib.util.spec_from_file_location("explore_server", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check(cond, label):
    if not cond:
        print(f"FAIL: {label}")
        check.failures += 1
    check.total += 1


check.failures = 0
check.total = 0

es = _load()

# salient terms drop stopwords, keep identifiers, dedupe, cap at 8
terms = es._terms("how does the LLMM_PORT default get configured for the server")
check("LLMM_PORT" in terms, "keeps identifier term")
check("how" not in terms and "the" not in terms, "drops stopwords")
check(len(terms) <= 8, "caps term count")

# explicit path hints expand and read; the gathered block is headed by the rel path
files = es._expand_paths(["config.default.zsh", "lib/*.zsh"])
check(any(f.endswith("config.default.zsh") for f in files), "expands a literal path")
check(any(f.endswith("claude.zsh") for f in files), "expands a glob")
ctx = es._gather("where is LLMM_PORT set", ["config.default.zsh"])
check(ctx.startswith("### config.default.zsh"), "gathered block carries a path header")
check("LLMM_PORT" in ctx, "gathered block contains file content")

# path hints are confined to ROOT: absolute, ../ escape, and symlink-out are all rejected
check(es._expand_paths(["/etc/passwd"]) == [], "absolute path hint rejected")
check(es._expand_paths(["../../../../etc/passwd"]) == [], "parent-escape hint rejected")
_evil = os.path.join(REPO, "_explore_escape_link")
try:
    if not os.path.lexists(_evil):
        os.symlink("/etc/passwd", _evil)
    check(
        es._expand_paths(["_explore_escape_link"]) == [], "symlink-out-of-root rejected"
    )
    check(es._in_root(os.path.join(REPO, "README.md")), "in-root path accepted")
    check(not es._in_root("/etc/passwd"), "out-of-root path rejected")
finally:
    if os.path.islink(_evil):
        os.unlink(_evil)

# keyword grep (no hints) returns existing files, bounded
g = es._grep_files(es._terms("server build_args alias port"))
check(bool(g) and all(os.path.isfile(f) for f in g), "grep returns real files")
check(len(g) <= es.MAX_FILES, "grep result respects MAX_FILES")

# gather honors the char budget
big = es._gather("anything", ["lib/*.zsh", "lib/hooks/*.py", "*.md"])
check(len(big) <= es.BUDGET + es.MAX_FILE_CHARS, "gather stays near the budget")

# a connection failure returns a fallback string instead of raising
es.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(
    urllib.error.URLError("connection refused")
)
out = es.explore("anything", ["config.default.zsh"])
check(out.startswith("explore unavailable"), "URLError yields a fallback message")

# _is_loopback gates the nested spawn to a local server
check(es._is_loopback("http://127.0.0.1:11111"), "127.0.0.1 is loopback")
check(es._is_loopback("http://localhost:8080"), "localhost is loopback")
check(not es._is_loopback("https://api.anthropic.com"), "remote host is not loopback")

# agent mode (v2): capture the constructed command and assert the safety-critical flags
es.MODE = "agent"
es.CLAUDE_BIN = "/fake/claude"
captured: dict = {}


def _fake_run(cmd, **k):
    captured["cmd"] = cmd
    captured["cwd"] = k.get("cwd")
    return types.SimpleNamespace(
        stdout="lib/server.zsh: server lifecycle.\n", returncode=0, stderr=""
    )


es.subprocess.run = _fake_run
ans = es._agent("trace the server lifecycle", ["lib/server.zsh"])
check(ans[:14] == "lib/server.zsh", "agent mode returns the sub-session answer")
cmd = captured["cmd"]
check("--strict-mcp-config" in cmd, "agent cmd disables MCP discovery")
check(
    "--mcp-config" not in cmd, "agent cmd passes no mcp-config (no explore recursion)"
)
check(cmd[cmd.index("--output-format") + 1] == "text", "agent cmd pins text output")
check(
    cmd[cmd.index("--permission-mode") + 1] == "default",
    "agent cmd uses default perms (not bypass)",
)
check("bypassPermissions" not in cmd, "agent cmd does not bypass permissions")
check(captured["cwd"] == es.ROOT, "agent runs in the repo root")
# a settings file confines reads to ROOT (allow Read under ROOT + Grep/Glob)
sp = cmd[cmd.index("--settings") + 1]
_rules = json.load(open(sp))["permissions"]["allow"]
check(f"Read({es.ROOT}/**)" in _rules, "agent settings allow Read only under ROOT")
check("Grep" in _rules and "Glob" in _rules, "agent settings allow Grep/Glob")
os.remove(sp)
es._AGENT_SETTINGS_PATH = ""

# nonzero exit falls back to retrieval (which fails on the patched urlopen -> fallback msg)
es.subprocess.run = lambda *a, **k: types.SimpleNamespace(
    stdout="", returncode=1, stderr="boom"
)
check(
    es._agent("q", []).startswith("explore unavailable"),
    "agent failure falls back to retrieval",
)

# loopback + broad-root guards must short-circuit BEFORE spawning the child
spawned = {"n": 0}


def _no_spawn(*a, **k):
    spawned["n"] += 1
    return types.SimpleNamespace(stdout="x", returncode=0, stderr="")


es.subprocess.run = _no_spawn
_saved_base = es.BASE_URL
es.BASE_URL = "https://api.anthropic.com"
out = es._agent("q", [])
check(spawned["n"] == 0, "non-loopback base url never spawns the agent")
check(out.startswith("explore unavailable"), "non-loopback falls back to retrieval")
es.BASE_URL = _saved_base

_saved_root = es.ROOT_REAL
es.ROOT_REAL = os.path.realpath(os.path.expanduser("~"))
out = es._agent("q", [])
check(spawned["n"] == 0, "broad root ($HOME) never spawns the agent")
check(out.startswith("explore unavailable"), "broad root falls back to retrieval")
es.ROOT_REAL = _saved_root

# no claude binary -> straight to retrieval fallback, never spawns
es.CLAUDE_BIN = ""
check(
    es._agent("q", []).startswith("explore unavailable"),
    "missing claude falls back to retrieval",
)

print(f"ran {check.total} checks, {check.failures} failure(s)")
sys.exit(1 if check.failures else 0)

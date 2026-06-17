import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib", "hooks"))

import scratchpad_core as sc


def check(cond, label):
    if not cond:
        print(f"FAIL: {label}")
        check.failures += 1
    check.total += 1


check.failures = 0
check.total = 0

# empty_doc has all six headers in order
doc = sc.empty_doc()
order = [doc.index(f"## {h}") for h in
         ["Task", "Status", "Findings", "Decisions", "Dead ends", "Open questions"]]
check(order == sorted(order), "empty_doc headers present and ordered")

# append adds a bullet and preserves prior content
doc = sc.merge(doc, "findings", "a.py:1 — does X", "append")
doc = sc.merge(doc, "findings", "b.py:2 — does Y", "append")
body = sc.read_section(doc, "findings")
check("a.py:1 — does X" in body and "b.py:2 — does Y" in body, "append accumulates findings")

# replace swaps only the targeted section
doc = sc.merge(doc, "status", "step 1: exploring", "replace")
doc = sc.merge(doc, "status", "step 2: editing", "replace")
check(sc.read_section(doc, "status").strip() == "step 2: editing", "replace swaps status")
check("a.py:1 — does X" in sc.read_section(doc, "findings"), "replace leaves findings intact")

# improvised section names resolve to a canonical key instead of raising
check(sc.resolve_section("Status") == "status", "case/whitespace normalized")
check(sc.resolve_section("dead-ends") == "dead_ends", "separators normalized")
check(sc.resolve_section("Summary") == "status", "alias maps to canonical")
check(sc.resolve_section("questions") == "open_questions", "alias plural maps")
check(sc.resolve_section("task_status") == "status", "compound takes last known token")
check(sc.resolve_section("bogus") == "findings", "unknown falls back to findings")

# an unknown section never raises; its content lands in the fallback section
doc = sc.merge(doc, "task_status", "wrote it as a combo", "replace")
check("wrote it as a combo" in sc.read_section(doc, "status"), "combo content lands in status")
doc = sc.merge(doc, "bogus", "stray note", "append")
check("stray note" in sc.read_section(doc, "findings"), "unknown content lands in findings")

# a fumbled mode never raises; it defaults to append
doc = sc.merge(doc, "decisions", "chose X", "add")
check("chose X" in sc.read_section(doc, "decisions"), "unknown mode defaults to append")

print(f"ran {check.total} checks, {check.failures} failure(s)")
sys.exit(1 if check.failures else 0)

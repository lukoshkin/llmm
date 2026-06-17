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

# unknown section is rejected
try:
    sc.merge(doc, "bogus", "x", "append")
    check(False, "unknown section raises")
except ValueError:
    check(True, "unknown section raises")

print(f"ran {check.total} checks, {check.failures} failure(s)")
sys.exit(1 if check.failures else 0)

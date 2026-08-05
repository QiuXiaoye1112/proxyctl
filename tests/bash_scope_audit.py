#!/usr/bin/env python3
"""Fail on Bash declarations that reference an earlier variable in the same
local/declare/typeset/readonly command.

Bash expands every RHS before the declaration command executes. Therefore:
    local a="$1" b="$a"
does NOT make b see the newly assigned local a; it sees an outer a or fails
under `set -u`. This exact class caused multiple ProxyCTL interactive bugs.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DECL_RE = re.compile(r"^\s*(?:local|declare|typeset|readonly)\b")
ASSIGN_RE = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=")
REF_RE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|([A-Za-z_][A-Za-z0-9_]*))")


def logical_lines(path: pathlib.Path):
    buf = ""
    start = 0
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip()
        if not buf:
            start = lineno
        buf += line
        if line.endswith("\\"):
            buf = buf[:-1] + " "
            continue
        yield start, buf
        buf = ""
    if buf:
        yield start, buf


def refs(text: str) -> set[str]:
    out: set[str] = set()
    for m in REF_RE.finditer(text):
        out.add(m.group(1) or m.group(2))
    return out


problems: list[str] = []
for path in sorted(ROOT.rglob("*.sh")):
    # Git internals/vendor-like directories are not project shell artifacts.
    if ".git" in path.parts:
        continue
    for lineno, stmt in logical_lines(path):
        if not DECL_RE.match(stmt):
            continue
        assignments = list(ASSIGN_RE.finditer(stmt))
        prior: list[str] = []
        for i, match in enumerate(assignments):
            name = match.group(1)
            rhs_end = assignments[i + 1].start() if i + 1 < len(assignments) else len(stmt)
            rhs = stmt[match.end():rhs_end]
            bad = sorted(set(prior) & refs(rhs))
            if bad:
                rel = path.relative_to(ROOT)
                problems.append(
                    f"{rel}:{lineno}: declaration of {name} references earlier same-command variable(s): "
                    + ", ".join(bad)
                )
            prior.append(name)

if problems:
    print("Unsafe Bash same-command declaration dependencies detected:", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    print("Declare/assign on separate commands instead.", file=sys.stderr)
    sys.exit(1)

print("Bash declaration scope audit: OK")

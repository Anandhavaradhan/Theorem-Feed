#!/usr/bin/env python3
"""Builds mobile/assets/graph/graph_seed_v1.json from the readable source files.

    python3 tools/build_graph_seed.py

Validates: unique names (case-insensitive), every `requires` target exists, no
self-edges, no prerequisite cycles, pool entries exist and are math, 300–500
concepts, 50–100 pool theorems.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / "mobile" / "assets" / "graph" / "graph_seed_v1.json"
SOURCES = [("math", "graph_source_math.txt"), ("physics", "graph_source_physics.txt"), ("cs", "graph_source_cs.txt")]
TYPES = {"theorem", "definition", "formula", "technique", "concept"}


def lines(path):
    for n, raw in enumerate((ROOT / path).read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if line and not line.startswith("#"):
            yield n, line


def main():
    errors = []
    concepts, by_lower = [], {}
    for subject, path in SOURCES:
        for n, line in lines(path):
            # Descriptions may contain '|' (|x|, P(A | B)), so split from both ends:
            # name | aliases | type | <description…> | requires
            parts = line.split("|")
            if len(parts) < 5:
                errors.append(f"{path}:{n}: expected at least 5 fields, got {len(parts)}")
                continue
            name, aliases, ctype = (p.strip() for p in parts[:3])
            requires = parts[-1].strip()
            desc = "|".join(parts[3:-1]).strip()
            if ctype not in TYPES:
                errors.append(f"{path}:{n}: bad type {ctype!r}")
            if name.lower() in by_lower:
                errors.append(f"{path}:{n}: duplicate concept {name!r}")
            entry = {
                "canonical_name": name,
                "aliases": [a.strip() for a in aliases.split(";") if a.strip()],
                "type": ctype,
                "subject": subject,
                "description": desc,
                "in_theorem_pool": False,
                "requires": [r.strip() for r in requires.split(";") if r.strip()],
            }
            by_lower[name.lower()] = entry
            concepts.append(entry)

    for c in concepts:
        for r in c["requires"]:
            if r.lower() not in by_lower:
                errors.append(f"{c['canonical_name']}: unknown prerequisite {r!r}")
            elif r.lower() == c["canonical_name"].lower():
                errors.append(f"{c['canonical_name']}: requires itself")
        c["requires"] = [by_lower[r.lower()]["canonical_name"] for r in c["requires"] if r.lower() in by_lower]

    # Alias collisions (normalised like the app's matcher) make concept lookup ambiguous.
    import re
    def norm(x):
        x = re.sub(r"['’]s\b", "", x.lower()).replace("'", "").replace("’", "")
        return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]+", " ", x)).strip()
    owner = {}
    for c in concepts:
        for nm in [c["canonical_name"], *c["aliases"]]:
            k = norm(nm)
            if k in owner and owner[k] != c["canonical_name"]:
                errors.append(f"name/alias {nm!r} of {c['canonical_name']!r} collides with {owner[k]!r}")
            owner.setdefault(k, c["canonical_name"])

    # Cycle check (prerequisites must form a DAG).
    state = {}
    def visit(name, stack):
        s = state.get(name)
        if s == 1:
            errors.append("prerequisite cycle: " + " -> ".join(stack + [name]))
            return
        if s == 2:
            return
        state[name] = 1
        for r in by_lower[name.lower()]["requires"]:
            visit(r, stack + [name])
        state[name] = 2
    for c in concepts:
        visit(c["canonical_name"], [])

    pool_order = 0
    for n, line in lines("theorem_pool.txt"):
        name, latex = [p.strip() for p in line.split("|", 1)]
        c = by_lower.get(name.lower())
        if c is None:
            errors.append(f"theorem_pool.txt:{n}: unknown concept {name!r}")
            continue
        if c["subject"] != "math":
            errors.append(f"theorem_pool.txt:{n}: {name!r} is not math")
        if c["in_theorem_pool"]:
            errors.append(f"theorem_pool.txt:{n}: {name!r} listed twice")
        pool_order += 1
        c["in_theorem_pool"] = True
        c["pool_order"] = pool_order
        c["latex"] = latex

    if not 300 <= len(concepts) <= 500:
        errors.append(f"expected 300–500 concepts, got {len(concepts)}")
    if not 50 <= pool_order <= 100:
        errors.append(f"expected 50–100 pool theorems, got {pool_order}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"version": 1, "concepts": concepts}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    by_subject = {s: sum(c["subject"] == s for c in concepts) for s, _ in SOURCES}
    edges = sum(len(c["requires"]) for c in concepts)
    print(f"wrote {OUT.relative_to(ROOT.parent)}: {len(concepts)} concepts {by_subject}, {edges} prerequisite edges, {pool_order} pool theorems")


if __name__ == "__main__":
    main()

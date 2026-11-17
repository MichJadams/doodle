#!/usr/bin/env python3
"""Scan Odin's core/ library and emit src/model/core_tree.odin as a flat row table.

Applies the structural reductions that only depend on file contents:
  - prune folders with no .odin anywhere beneath, test-only, and example/tests dirs
  - platform tags from path + #+build parsing (runtime filters by ODIN_OS)
  - collapse single-child chains (intrusive/list)
  - sink internal sub-packages (imported only within their parent subtree) under
    a dimmed "internals" group

Bucketing (big menus -> alpha ranges) and usage-first ordering are done at RUNTIME
in the model package, since they depend on counts/user state.
"""
import os, re, sys

CORE = sys.argv[1] if len(sys.argv) > 1 else r"C:\Odin\core"
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(__file__), "..", "src", "model", "core_tree.odin")

OS_NAMES = {"windows","linux","darwin","freebsd","openbsd","netbsd","haiku",
            "essence","wasi","js","orca","android","unix"}
SKIP_DIRS = {"tests", "examples", "example"}

build_re = re.compile(r'^\s*#\+build\s+(.+?)\s*$')
import_re = re.compile(r'^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"')


def odin_files(folder):
    try:
        return [f for f in os.listdir(folder)
                if f.endswith(".odin") and os.path.isfile(os.path.join(folder, f))]
    except OSError:
        return []


def non_test(files):
    return [f for f in files if not f.endswith("_test.odin")]


def parse_platform(folder, files):
    """Approximate allowed-OS set. '' means builds everywhere."""
    nt = non_test(files)
    if not nt:
        return ""
    allowed = set()
    any_unconstrained = False
    for f in nt:
        constrained = False
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if not line.startswith("#+"):
                        if line.strip() and not line.startswith("//") and not line.startswith("package"):
                            break  # constraints must be at top
                    m = build_re.match(line)
                    if m:
                        constrained = True
                        for tok in re.split(r"[,\s]+", m.group(1)):
                            tok = tok.strip().lower()
                            neg = tok.startswith("!")
                            name = tok[1:] if neg else tok
                            if name in OS_NAMES and not neg:
                                allowed.add(name)
        except OSError:
            pass
        if not constrained:
            any_unconstrained = True
    if any_unconstrained or not allowed:
        return ""
    return ",".join(sorted(allowed))


def parse_imports(folder, files):
    out = set()
    for f in files:
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    m = import_re.match(line)
                    if m and m.group(1).startswith("core:"):
                        out.add(m.group(1))
        except OSError:
            pass
    return out


class Node:
    def __init__(self, name, rel):
        self.name = name
        self.rel = rel  # e.g. "text/regex" ("" for root)
        self.importable = False
        self.platform = ""
        self.children = {}  # name -> Node
        self.dim = False

    @property
    def path(self):
        return "core:" + self.rel if self.importable else ""


IMPORTERS = {}  # "core:foo" -> set of importer rel-ids ("core:bar")


def scan(folder, rel):
    name = os.path.basename(folder) if rel else "core"
    node = Node(name, rel)
    files = odin_files(folder)
    nt = non_test(files)
    node.importable = len(nt) > 0
    node.platform = parse_platform(folder, files)
    if files:
        imps = parse_imports(folder, files)
        myid = "core:" + rel
        for imp in imps:
            IMPORTERS.setdefault(imp, set()).add(myid)
    try:
        subs = sorted(d for d in os.listdir(folder)
                      if os.path.isdir(os.path.join(folder, d)))
    except OSError:
        subs = []
    for d in subs:
        if d in SKIP_DIRS or d.startswith("."):
            continue
        child = scan(os.path.join(folder, d), (rel + "/" + d) if rel else d)
        if child is not None:
            node.children[d] = child
    # prune: keep only if importable or has surviving children
    if not node.importable and not node.children:
        return None
    return node


def collapse(node):
    for c in list(node.children.values()):
        collapse(c)
    # collapse a non-importable group with exactly one child
    while (not node.importable) and len(node.children) == 1:
        (only,) = node.children.values()
        node.name = node.name + "/" + only.name
        node.rel = only.rel
        node.importable = only.importable
        node.platform = only.platform or node.platform
        node.children = only.children


def sink_internals(node):
    for c in node.children.values():
        sink_internals(c)
    if not node.children:
        return
    prefix = "core:" + node.rel
    internal = []
    for name, c in node.children.items():
        if not c.importable:
            continue
        importers = IMPORTERS.get(c.path, set())
        if importers and all(i == prefix or i.startswith(prefix + "/") for i in importers):
            internal.append(name)
    # only sink if it meaningfully declutters (2+), keep regex-style groups tidy
    if len(internal) >= 2:
        for name in internal:
            node.children[name].dim = True
        bucket = Node("internals", node.rel + "/_internals")
        bucket.dim = True
        for name in internal:
            bucket.children[name] = node.children.pop(name)
        node.children["internals"] = bucket


ROWS = []


def emit(node, depth, top=False):
    kids = sorted(node.children.values(), key=lambda n: (n.dim, n.name.lower()))
    if top:
        for k in kids:
            emit(k, depth)
        return
    if node.importable and kids:
        ROWS.append((depth, node.name, "", node.platform, node.dim))
        ROWS.append((depth + 1, "import " + node.name, node.path, node.platform, node.dim))
        for k in kids:
            emit(k, depth + 1)
    elif kids:
        ROWS.append((depth, node.name, "", node.platform, node.dim))
        for k in kids:
            emit(k, depth + 1)
    else:
        ROWS.append((depth, node.name, node.path, node.platform, node.dim))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    root = scan(CORE, "")
    collapse(root)
    sink_internals(root)
    emit(root, 0, top=True)

    lines = []
    lines.append("package model")
    lines.append("")
    lines.append("// AUTO-GENERATED by tools/gen_core_tree.py -- do not edit by hand.")
    lines.append("// Flat depth-indented rows describing the importable core tree.")
    lines.append("")
    lines.append("CoreRow :: struct { depth: int, label: string, path: string, platform: string, dim: bool }")
    lines.append("")
    lines.append("CORE_ROWS := [?]CoreRow{")
    for d, label, path, plat, dim in ROWS:
        lines.append('\t{%d, "%s", "%s", "%s", %s},' % (
            d, esc(label), esc(path), esc(plat), "true" if dim else "false"))
    lines.append("}")
    lines.append("")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("rows:", len(ROWS))
    print("written:", os.path.abspath(OUT))


if __name__ == "__main__":
    main()

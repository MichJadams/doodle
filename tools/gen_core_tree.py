#!/usr/bin/env python3
"""Scan Odin's built-in collections (core:, base:, vendor:) and emit
src/model/core_tree.odin: one flat row table per collection (CORE_ROWS,
BASE_ROWS, VENDOR_ROWS) for the Import menu, plus IMPORT_NAMES.

Applies the structural reductions that only depend on file contents:
  - prune folders with no .odin anywhere beneath, test-only, example/tests dirs,
    `package main` folders (tools/demos), and base:builtin (documentation only)
  - platform tags from path + #+build parsing (runtime filters by ODIN_OS)
  - collapse single-child chains (intrusive/list)
  - sink internal sub-packages (imported only within their parent subtree) under
    a dimmed "internals" group

IMPORT_NAMES lists the packages whose folder name isn't an identifier
(vendor:lua/5.4): Odin can only import those with an explicit name, so Doodle
always inserts them as `import <name> "<path>"`.

Bucketing (big menus -> alpha ranges) and usage-first ordering are done at RUNTIME
in the model package, since they depend on counts/user state. The `shared:`
collection is user-specific and is listed at runtime too (src/model/collections.odin).

Usage: python tools/gen_core_tree.py [ODIN_ROOT] [OUT_FILE]
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odin_collections import (ODIN_ROOT, COLLECTIONS, SKIP_DIRS, NOT_IMPORTABLE,
                              collection_root, import_path, is_program, import_name,
                              package_platform, ident_re, has_file_scope_panic)

ROOT = sys.argv[1] if len(sys.argv) > 1 else ODIN_ROOT
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "src", "model", "core_tree.odin")

import_re = re.compile(r'^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"')


def odin_files(folder):
    try:
        return [f for f in os.listdir(folder)
                if f.endswith(".odin") and os.path.isfile(os.path.join(folder, f))]
    except OSError:
        return []


def non_test(files):
    return [f for f in files if not f.endswith("_test.odin")]


def parse_imports(folder, files):
    out = set()
    for f in files:
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    m = import_re.match(line)
                    if m and ":" in m.group(1):
                        out.add(m.group(1))
        except OSError:
            pass
    return out


class Node:
    def __init__(self, collection, name, rel):
        self.collection = collection
        self.name = name
        self.rel = rel  # e.g. "text/regex" ("" for root)
        self.importable = False
        self.platform = ""
        self.children = {}  # name -> Node
        self.dim = False

    @property
    def path(self):
        return import_path(self.collection, self.rel) if self.importable else ""


IMPORTERS = {}  # "core:foo" -> set of importer paths ("core:bar")
IMPORT_NAMES = {}  # path -> import name, for folders that aren't identifiers


def scan(collection, folder, rel):
    name = os.path.basename(folder) if rel else collection
    node = Node(collection, name, rel)
    files = odin_files(folder)
    nt = non_test(files)
    path = import_path(collection, rel)
    node.importable = (len(nt) > 0 and rel != "" and path not in NOT_IMPORTABLE
                       and not is_program(folder, nt) and not has_file_scope_panic(folder, nt))
    if node.importable:
        node.platform = package_platform(folder, files, path)
        if not ident_re.match(os.path.basename(folder)):
            IMPORT_NAMES[path] = import_name(path)
    if files:
        for imp in parse_imports(folder, files):
            IMPORTERS.setdefault(imp, set()).add(path)
    try:
        subs = sorted(d for d in os.listdir(folder)
                      if os.path.isdir(os.path.join(folder, d)))
    except OSError:
        subs = []
    for d in subs:
        if d in SKIP_DIRS or d.startswith("."):
            continue
        child = scan(collection, os.path.join(folder, d), (rel + "/" + d) if rel else d)
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


def group_platform(node):
    """A group whose packages all build on the same platforms gets that tag, so
    e.g. vendor:darwin is hidden on Windows as a whole."""
    for c in node.children.values():
        group_platform(c)
    if node.importable or not node.children:
        return
    plats = {c.platform for c in node.children.values()}
    if len(plats) == 1:
        node.platform = plats.pop()


def sink_internals(node):
    for c in node.children.values():
        sink_internals(c)
    if not node.children:
        return
    prefix = import_path(node.collection, node.rel)
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
        bucket = Node(node.collection, "internals", node.rel + "/_internals")
        bucket.dim = True
        for name in internal:
            bucket.children[name] = node.children.pop(name)
        node.children["internals"] = bucket


def emit(node, depth, rows, top=False):
    kids = sorted(node.children.values(), key=lambda n: (n.dim, n.name.lower()))
    if top:
        for k in kids:
            emit(k, depth, rows)
        return
    if node.importable and kids:
        rows.append((depth, node.name, "", node.platform, node.dim))
        rows.append((depth + 1, "import " + node.name, node.path, node.platform, node.dim))
        for k in kids:
            emit(k, depth + 1, rows)
    elif kids:
        rows.append((depth, node.name, "", node.platform, node.dim))
        for k in kids:
            emit(k, depth + 1, rows)
    else:
        rows.append((depth, node.name, node.path, node.platform, node.dim))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    tables = []
    for collection in COLLECTIONS:
        root = scan(collection, collection_root(collection, ROOT), "")
        rows = []
        if root is not None:
            collapse(root)
            sink_internals(root)
            group_platform(root)
            emit(root, 0, rows, top=True)
        tables.append((collection.upper() + "_ROWS", collection, rows))

    lines = []
    lines.append("package model")
    lines.append("")
    lines.append("// AUTO-GENERATED by tools/gen_core_tree.py -- do not edit by hand.")
    lines.append("// Flat depth-indented rows describing the importable packages of each")
    lines.append("// built-in collection (core:, base:, vendor:).")
    lines.append("")
    lines.append("CoreRow :: struct { depth: int, label: string, path: string, platform: string, dim: bool }")
    for table, collection, rows in tables:
        lines.append("")
        lines.append("%s := [?]CoreRow{" % table)
        for d, label, path, plat, dim in rows:
            lines.append('\t{%d, "%s", "%s", "%s", %s},' % (
                d, esc(label), esc(path), esc(plat), "true" if dim else "false"))
        lines.append("}")
        print("%s rows: %d" % (table, len(rows)))
    lines.append("")
    lines.append("// Packages whose folder name isn't an identifier: the name to import them as.")
    lines.append("ImportName :: struct { path: string, name: string }")
    lines.append("")
    lines.append("IMPORT_NAMES := [?]ImportName{")
    for path in sorted(IMPORT_NAMES):
        lines.append('\t{"%s", "%s"},' % (esc(path), esc(IMPORT_NAMES[path])))
    lines.append("}")
    lines.append("")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("written:", os.path.abspath(OUT))


if __name__ == "__main__":
    main()

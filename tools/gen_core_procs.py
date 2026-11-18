#!/usr/bin/env python3
"""Scan Odin's core/ library and emit src/model/core_procs.odin with ALL procedures.

Collects both top-level and foreign-block procedure declarations from importable 
core packages, tracking source file and foreign block.
Excludes test-only packages, example/tests directories, _test.odin files, 
private procedures (names starting with _), and main procedures.
"""
import os, re, sys

CORE = sys.argv[1] if len(sys.argv) > 1 else r"C:\Odin\core"
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(__file__), "..", "src", "model", "core_procs.odin")

SKIP_DIRS = {"tests", "examples", "example"}

# Match top-level proc declarations: identifier at column 0 followed by :: proc
# Handles: foo :: proc(, foo :: proc{, foo :: proc "c" (
proc_re = re.compile(r'^([A-Za-z_]\w*)\s*::\s*proc\b')

# Match foreign block start: foreign <lib> {
foreign_re = re.compile(r'^\s*foreign\s+(\w+)\s*\{')

# Match procedure inside foreign block (indented)
foreign_proc_re = re.compile(r'^\s+([A-Za-z_]\w*)\s*::\s*proc\b')


def odin_files(folder):
    """Return non-test .odin files in folder."""
    try:
        return [f for f in os.listdir(folder)
                if f.endswith(".odin") 
                and not f.endswith("_test.odin")
                and os.path.isfile(os.path.join(folder, f))]
    except OSError:
        return []


def scan_procs(filepath, basename):
    """Extract procedures from a single .odin file.
    
    Returns list of (file_stem, block_name, proc_name) tuples.
    - file_stem: basename without .odin extension
    - block_name: foreign library name or "" for top-level
    - proc_name: procedure name
    """
    procs = []
    file_stem = basename[:-5] if basename.endswith(".odin") else basename
    
    try:
        with open(filepath, encoding="utf-8", errors="ignore") as f:
            in_foreign = False
            foreign_lib = ""
            brace_depth = 0
            
            for line in f:
                # Check for foreign block start
                if not in_foreign:
                    m = foreign_re.match(line)
                    if m:
                        foreign_lib = m.group(1)
                        in_foreign = True
                        brace_depth = 1
                        continue
                
                # If inside foreign block, track braces and capture procs
                if in_foreign:
                    # Count braces to track block end
                    brace_depth += line.count("{") - line.count("}")
                    
                    # Check for procedure declaration
                    m = foreign_proc_re.match(line)
                    if m:
                        name = m.group(1)
                        if not name.startswith("_") and name != "main":
                            procs.append((file_stem, foreign_lib, name))
                    
                    # Exit foreign block when braces balance
                    if brace_depth <= 0:
                        in_foreign = False
                        foreign_lib = ""
                        brace_depth = 0
                else:
                    # Top-level procedure (column 0)
                    m = proc_re.match(line)
                    if m:
                        name = m.group(1)
                        if not name.startswith("_") and name != "main":
                            procs.append((file_stem, "", name))
    except OSError:
        pass
    
    return procs


def scan_folder(folder):
    """Extract all procedures from all .odin files in folder.
    
    Returns list of (file_stem, block_name, proc_name) tuples.
    """
    procs = []
    for fname in odin_files(folder):
        filepath = os.path.join(folder, fname)
        procs.extend(scan_procs(filepath, fname))
    return procs


def collect_all(root):
    """Recursively collect (path, file, block, name) tuples from core packages."""
    results = []
    
    def walk(folder, rel):
        # Skip test-only and example directories
        base = os.path.basename(folder)
        if base in SKIP_DIRS or base.startswith("."):
            return
        
        # Check if this folder is importable (has non-test .odin files)
        files = odin_files(folder)
        if files:
            path = "core:" + rel if rel else "core"
            procs = scan_folder(folder)
            for file_stem, block, name in procs:
                results.append((path, file_stem, block, name))
        
        # Recurse into subdirectories
        try:
            subdirs = sorted(d for d in os.listdir(folder)
                           if os.path.isdir(os.path.join(folder, d)))
        except OSError:
            subdirs = []
        
        for subdir in subdirs:
            if subdir not in SKIP_DIRS and not subdir.startswith("."):
                subrel = (rel + "/" + subdir) if rel else subdir
                walk(os.path.join(folder, subdir), subrel)
    
    walk(root, "")
    return results


def main():
    tuples = collect_all(CORE)
    
    # Deduplicate by (path, file, block, name)
    unique = {}
    for path, file, block, name in tuples:
        key = (path, file, block, name)
        unique[key] = None
    
    # Sort by (path, file, block, name)
    sorted_entries = sorted(unique.keys())
    
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("package model\n\n")
        f.write("// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.\n\n")
        f.write("CoreProc :: struct { path: string, file: string, block: string, name: string }\n\n")
        f.write("CORE_PROCS := [?]CoreProc{\n")
        for path, file, block, name in sorted_entries:
            f.write(f'\t{{"{path}", "{file}", "{block}", "{name}"}},\n')
        f.write("}\n")
    
    print(f"Generated {len(sorted_entries)} proc entries -> {OUT}")


if __name__ == "__main__":
    main()

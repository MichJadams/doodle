#!/usr/bin/env python3
"""Shared by gen_core_procs.py and gen_core_tree.py: where Odin's built-in
collections live and which of their folders are importable packages.

Collections scanned (import path = "<collection>:<relative path>"):
  core   - the standard library
  base   - intrinsics, runtime, sanitizer (base:builtin only documents the
           predeclared identifiers and can't be imported, so it is skipped)
  vendor - bundled third-party bindings (sdl2, OpenGL, vulkan, raylib, ...)
The `shared` collection is user-specific and is listed at runtime instead.
"""
import os, re, sys

ODIN_ROOT = os.environ.get("ODIN_ROOT") or r"C:\Odin"

COLLECTIONS = ("core", "base", "vendor")

# Folders that never hold importable packages.
SKIP_DIRS = {"tests", "examples", "example", "_gen"}

# Import paths that exist on disk but can't be imported.
NOT_IMPORTABLE = {"base:builtin"}

package_re = re.compile(r'^\s*package\s+([A-Za-z_]\w*)', re.M)
ident_re = re.compile(r'^[A-Za-z_]\w*$')


def collection_root(collection, odin_root=None):
    return os.path.join(odin_root or ODIN_ROOT, collection)


def import_path(collection, rel):
    return collection + ":" + rel if rel else collection


def package_name(folder, files):
    """The `package` name declared by the first non-test file ("" if none).
    Comments are skipped: doc.odin files often show `package main` examples."""
    for f in sorted(files):
        if f.endswith("_test.odin"):
            continue
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        m = package_re.search(strip_comments(text))
        if m:
            return m.group(1)
    return ""


def strip_comments(text):
    """`text` without // and (nested) /* */ comments; string literals are kept."""
    out = []
    i, n, depth = 0, len(text), 0
    while i < n:
        two = text[i:i + 2]
        if depth:
            if two == "/*":
                depth += 1
                i += 2
            elif two == "*/":
                depth -= 1
                i += 2
            else:
                if text[i] == "\n":
                    out.append("\n")
                i += 1
        elif two == "/*":
            depth = 1
            i += 2
        elif two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text[i] in "\"`":
            q = text[i]
            j = i + 1
            while j < n and text[j] != q:
                j += 2 if (text[j] == "\\" and q == '"') else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


panic_re = re.compile(r'^#panic\s*\(', re.M)


def has_file_scope_panic(folder, files):
    """Does a non-test file of the package hold a file-scope `#panic(...)`
    (column 0)? Such packages refuse to be imported (vendor:libc "has been
    moved", deprecated core:path), so the Import menu leaves them out."""
    for f in files:
        if not f.endswith(".odin") or f.endswith("_test.odin"):
            continue
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        # Only files that build on Windows count (core:os panics on js/wasm only).
        build_lines = []
        for line in text.split("\n"):
            s = line.strip()
            if s.startswith("#+build"):
                build_lines.append(s[len("#+build"):])
            if s.startswith("package "):
                break
        if windows_score_for_file(f, build_lines) == 0:
            continue
        if panic_re.search(strip_comments(text)):
            return True
    return False


def is_program(folder, files):
    """A `package main` folder is a program (tools/, demos), not a library."""
    return package_name(folder, files) == "main"


def import_name(path):
    """The name an import of `path` is referred to by. Odin uses the folder name,
    which must then be an identifier; for folders that aren't (`lua/5.4`,
    `libc-shim`) an alias is required, and this is the one Doodle suggests."""
    rel = path.split(":", 1)[-1]
    parts = rel.split("/")
    last = parts[-1]
    if ident_re.match(last):
        return last
    if re.match(r'^[0-9][0-9._]*$', last) and len(parts) >= 2 and ident_re.match(parts[-2]):
        return parts[-2]  # vendor:lua/5.4 -> lua
    name = re.sub(r'\W', '_', last)
    return name if ident_re.match(name) else "_" + name


def windows_score_for_file(fname, build_lines):
    """How much a file is meant for Windows: 2 = Windows-only, 1 = any OS,
    0 = some other OS only. From the file name suffix and #+build tags."""
    stem = fname[:-5] if fname.endswith(".odin") else fname
    parts = stem.split("_")
    others = {"linux", "darwin", "freebsd", "openbsd", "netbsd", "haiku", "essence",
              "wasi", "js", "orca", "android", "unix", "posix", "freestanding", "bsd"}
    if "windows" in parts[1:]:
        return 2
    if any(p in others for p in parts[1:]):
        return 0
    if not build_lines:
        return 1
    best = None
    for line in build_lines:
        toks = [t.strip().lower() for t in re.split(r'[,\s]+', line) if t.strip()]
        pos = [t for t in toks if not t.startswith("!")]
        neg = [t[1:] for t in toks if t.startswith("!")]
        if "windows" in neg:
            return 0
        os_pos = [t for t in pos if t in others or t == "windows"]
        if "windows" in os_pos:
            best = 2
        elif os_pos and best is None:
            best = 0
    return 1 if best is None else best


# ---- Platform tags (which ODIN_OS a package builds for) ----

OS_NAMES = {"windows", "linux", "darwin", "freebsd", "openbsd", "netbsd", "haiku",
            "essence", "wasi", "js", "orca", "android", "unix"}
UNIX_LIKE = "linux,darwin,freebsd,openbsd,netbsd"
build_re = re.compile(r'^\s*#\+build\s+(.+?)\s*$')

# Folder prefix -> platform, authoritative over #+build tags (those are often
# broader than the folder suggests). Matched against "<collection>:<rel>".
PATH_PLATFORMS = [
    ("core:sys/windows", "windows"),
    ("core:sys/linux", "linux"),
    ("core:sys/darwin", "darwin"),
    ("core:sys/freebsd", "freebsd"),
    ("core:sys/openbsd", "openbsd"),
    ("core:sys/netbsd", "netbsd"),
    ("core:sys/haiku", "haiku"),
    ("core:sys/android", "android"),
    ("core:sys/wasm/js", "js"),
    ("core:sys/wasm/wasi", "wasi"),
    ("vendor:darwin", "darwin"),
    ("vendor:android", "android"),
    ("vendor:windows", "windows"),
    ("vendor:directx", "windows"),
    ("vendor:wasm", "js"),
    ("vendor:x11", "linux,freebsd,openbsd,netbsd"),
]
# Fallback when #+build says nothing.
PATH_PLATFORM_FALLBACKS = [
    ("core:sys/posix", UNIX_LIKE),
    ("core:sys/unix", UNIX_LIKE),
    ("core:sys/kqueue", "darwin,freebsd,netbsd,openbsd"),
    ("core:sys/valgrind", "linux,freebsd"),
]


def _prefix_match(path, table):
    for prefix, plat in table:
        if path == prefix or path.startswith(prefix + "/"):
            return plat
    return None


def package_platform(folder, files, path):
    """Approximate allowed-OS set for the package at `path` ("" = builds everywhere)."""
    nt = [f for f in files if f.endswith(".odin") and not f.endswith("_test.odin")]
    if not nt:
        return ""
    plat = _prefix_match(path, PATH_PLATFORMS)
    if plat is not None:
        return plat
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
    if allowed and not any_unconstrained:
        return ",".join(sorted(allowed))
    return _prefix_match(path, PATH_PLATFORM_FALLBACKS) or ""


def builds_on_windows(platform):
    return platform == "" or "windows" in platform.split(",")

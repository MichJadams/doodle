#!/usr/bin/env python3
"""Scan Odin's core/ library and emit src/model/core_procs.odin with ALL procedures.

Collects both top-level and foreign-block procedure declarations from importable
core packages, tracking source file and foreign block, plus each procedure's
signature:
  req      - number of required parameters (no default value, not variadic)
  variadic - takes a `..T` parameter (or is a proc group whose members' arity varies)
  params   - the parameter list text, e.g. "hWnd: HWND, lpText: LPCWSTR" ("" = unknown)
  ret      - the return type text, e.g. "INT" ("" = none or unknown)
Excludes test-only packages, example/tests directories, _test.odin files,
private procedures (names starting with _), and main procedures.

Also emits src/model/core_types.odin: the type declarations of each package
(struct/enum/union/bit_set/distinct/aliases like `LPCWSTR :: wstring`) with what
they refer to, for the Type fill menu and for checking which fills fit a slot.

And src/model/core_consts.odin: the constants of each package (MB_OK, WM_PAINT, ...)
with their kind: untyped "#int"/"#float"/"#string"/"#rune"/"#bool", an explicit type
("DWORD"), or "?" when it can't be told - for the "Constant" fill menu.

Usage: python tools/gen_core_procs.py [CORE_DIR] [OUT_FILE] [TYPES_OUT_FILE] [CONSTS_OUT_FILE]
"""
import os, re, sys

CORE = sys.argv[1] if len(sys.argv) > 1 else r"C:\Odin\core"
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(__file__), "..", "src", "model", "core_procs.odin")
TYPES_OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
    os.path.dirname(__file__), "..", "src", "model", "core_types.odin")
CONSTS_OUT = sys.argv[4] if len(sys.argv) > 4 else os.path.join(
    os.path.dirname(__file__), "..", "src", "model", "core_consts.odin")

SKIP_DIRS = {"tests", "examples", "example"}

# Match top-level proc declarations: identifier at column 0 followed by :: proc
# Handles: foo :: proc(, foo :: proc{, foo :: proc "c" (, foo :: #force_inline proc(
proc_re = re.compile(r'^([A-Za-z_]\w*)\s*::\s*(?:#force_(?:no_)?inline\s+)?proc\b')

# Match foreign block start: foreign <lib> {
foreign_re = re.compile(r'^\s*foreign\s+(\w+)\s*\{')

# Match procedure inside foreign block (indented)
foreign_proc_re = re.compile(r'^\s+([A-Za-z_]\w*)\s*::\s*proc\b')

# Top-level alias of a compiler intrinsic: `name :: intrinsics.something`
intrinsic_alias_re = re.compile(r'^([A-Za-z_]\w*)\s*::\s*intrinsics\.(\w+)\s*(?://.*)?$')

# Known signatures of intrinsics that core packages re-export under another name.
INTRINSIC_SIGS = {
    # sys/windows: L :: intrinsics.constant_utf16_cstring -> L("text") is a cstring16
    "constant_utf16_cstring": ("value: string", "cstring16"),
}

# After `proc`: optional calling convention string, then `(` (signature) or `{` (group).
after_proc_re = re.compile(r'\s*(?:"[^"]*"\s*)?([({])')

MAX_SIG_LINES = 60

# Typed constant: `Name : Type : value` at column 0.
typed_const_re = re.compile(r'^([A-Za-z_]\w*)\s*:\s*([^:=]+?)\s*:\s*(.+?)\s*$')
number_re = re.compile(r'^[-+]?(0[xXbBoOzZ][0-9a-fA-F_]+|[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9]+)?)[ijk]?$')
call_or_lit_re = re.compile(r'^([A-Za-z_][\w.]*)\s*[({]')  # T(...) cast or T{...} literal
word_re = re.compile(r'[A-Za-z_]\w*')
NOT_CONSTANTS = ('#config', '#load', '#directory', '#file', '#line', '#location', '#procedure',
                 '#force_inline', '#force_no_inline', 'proc', '#type', 'struct', 'enum', 'union',
                 'nil', '---')
EXPR_KEYWORDS = {'size_of', 'align_of', 'offset_of', 'len', 'cap', 'min', 'max', 'abs', 'clamp',
                 'type_of', 'typeid_of', 'cast', 'transmute', 'auto_cast', 'true', 'false'}

# Top-level constant-or-type declaration: `Name :: <rhs>` at column 0.
decl_re = re.compile(r'^([A-Za-z_]\w*)\s*::\s*(.+?)\s*$')
ident_re = re.compile(r'^[A-Za-z_]\w*$')
qualified_re = re.compile(r'^[A-Za-z_]\w*\.([A-Za-z_]\w*)$')

BUILTIN_TYPES = {
    "int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
    "i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
    "i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be",
    "uintptr", "f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
    "complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256",
    "bool", "b8", "b16", "b32", "b64", "string", "cstring", "string16", "cstring16",
    "rune", "byte", "rawptr", "typeid", "any",
}
TYPE_KEYWORDS = ("struct", "enum", "union", "bit_set", "bit_field", "distinct")
TYPE_DIRECTIVES = ("#type", "#soa", "#simd", "#sparse", "#row_major", "#column_major")


def odin_files(folder):
    """Return non-test .odin files in folder."""
    try:
        return [f for f in os.listdir(folder)
                if f.endswith(".odin")
                and not f.endswith("_test.odin")
                and f != "example.odin"  # demo code shipped inside some packages (e.g. fmt)
                and os.path.isfile(os.path.join(folder, f))]
    except OSError:
        return []


def strip_line_comment(line):
    """Drop a trailing // comment (ignoring // inside string literals)."""
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == '\\' and quote != '`':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'`':
            quote = c
        elif c == '/' and line[i + 1:i + 2] == '/':
            return line[:i]
        i += 1
    return line


def norm_ws(s):
    return ' '.join(s.split())


def balanced_text(lines, start_line, start_col):
    """Text strictly inside the bracket opened at lines[start_line][start_col].

    Returns (text, end_line, end_col) where end_* is the closing bracket, or None.
    """
    depth = 0
    out = []
    quote = None
    for li in range(start_line, min(len(lines), start_line + MAX_SIG_LINES)):
        line = strip_line_comment(lines[li])
        col = start_col if li == start_line else 0
        i = col
        while i < len(line):
            c = line[i]
            if quote:
                if c == '\\' and quote != '`':
                    out.append(line[i:i + 2])
                    i += 2
                    continue
                if c == quote:
                    quote = None
            elif c in '"\'`':
                quote = c
            elif c in '([{':
                depth += 1
                if depth == 1:
                    i += 1
                    continue
            elif c in ')]}':
                depth -= 1
                if depth == 0:
                    return ''.join(out), li, i
            out.append(c)
            i += 1
        out.append(' ')
    return None  # unbalanced / too long


def return_text(lines, li, col):
    """The return type after a proc's parameter list (`-> T`), or ""."""
    rest = []
    for k in range(li, min(len(lines), li + 6)):
        line = strip_line_comment(lines[k])
        seg = line[col:] if k == li else line
        rest.append(seg)
        if '{' in seg or '---' in seg:
            break
    text = ' '.join(rest)
    arrow = text.find('->')
    if arrow < 0:
        return ""
    ret = text[arrow + 2:]
    for stop in ('---', ' where ', '{'):
        i = ret.find(stop)
        if i >= 0:
            # a `{` inside `(a: T, b: U)` named results is impossible; but `struct{..}` returns are rare
            ret = ret[:i]
    ret = norm_ws(ret)
    if ret == "!":
        return ""  # `-> !` = diverging
    # A single named result `(n: int)` is just `int`.
    if ret.startswith('(') and ret.endswith(')'):
        parts = split_top_level(ret[1:-1])
        if len(parts) == 1:
            p = parts[0]
            colon = p.find(':')
            ret = p[colon + 1:].strip() if colon >= 0 and p[colon:colon + 2] != ':=' else p
            eq = ret.find('=')
            if eq >= 0:
                ret = ret[:eq].strip()
    return ret


def split_top_level(s):
    """Split on commas not nested in brackets or string literals."""
    parts, cur, depth, quote = [], [], 0, None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            if c == '\\' and quote != '`':
                cur.append(s[i:i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'`':
            quote = c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    parts.append(''.join(cur))
    return [p.strip() for p in parts if p.strip()]


def param_arity(param_text):
    """(required, variadic) for the text inside a proc's parameter parens.

    Mirrors model.param_arity in src/model/calls.odin:
      `a, b: int`        -> 2 required (grouped names each count)
      `x := 1`           -> optional (has a default)
      `args: ..any`      -> variadic
    """
    req, variadic = 0, False
    for p in split_top_level(param_text):
        colon = p.find(':')
        if colon >= 0 and p[colon:colon + 2] == ':=':
            continue  # name := default
        typ = p[colon + 1:].strip() if colon >= 0 else p
        if typ.startswith('..') or '#c_vararg' in p:
            variadic = True
            continue
        if colon >= 0 and '=' in typ:
            continue  # name: T = default
        req += 1
    return req, variadic


def signature_after(lines, li, match_end):
    """Parse what follows `proc` at lines[li][match_end:].

    Returns ('sig', req, variadic, params, ret) or ('group', [member names]) or None.
    """
    m = after_proc_re.match(lines[li], match_end)
    if not m:
        return None
    col = m.start(1)
    span = balanced_text(lines, li, col)
    if span is None:
        return None
    inner, end_line, end_col = span
    if m.group(1) == '(':
        req, variadic = param_arity(inner)
        return ('sig', req, variadic, norm_ws(inner), return_text(lines, end_line, end_col + 1))
    return ('group', [n.split('.')[-1].strip() for n in split_top_level(inner)])


def classify_decl(rhs):
    """Is `Name :: rhs` a type declaration?

    Returns ('type', kind, target) for a definite type, ('alias', 'alias', target)
    when rhs is a bare identifier that is a type only if `target` is (resolved per
    package), or None for constants / procs / anything else. `target` is what the
    type refers to ("" for struct/enum/union/bit_set/bit_field).
    """
    rhs = norm_ws(strip_line_comment(rhs))
    if not rhs:
        return None
    word = re.split(r'[\s{(\[#]', rhs, maxsplit=1)[0]
    if word == 'distinct':
        return ('type', 'distinct', rhs[len('distinct'):].strip())
    if word in TYPE_KEYWORDS:
        return ('type', word, "")
    if rhs.startswith(TYPE_DIRECTIVES):
        return ('type', 'alias', rhs)
    if rhs.startswith(('[', '^', 'map[', 'matrix[')):
        # `[4]f32` is a type; `[4]f32{1, 2, 3, 4}` is a constant.
        return None if '{' in rhs else ('type', 'alias', rhs)
    if ident_re.match(rhs):
        return ('type', 'alias', rhs) if rhs in BUILTIN_TYPES else ('alias', 'alias', rhs)
    m = qualified_re.match(rhs)
    if m:
        # `c.uint` / `runtime.Allocator`: a type if it names a builtin or CamelCase;
        # ALL_CAPS (`win32.SOME_FLAG`) is a constant.
        t = m.group(1)
        if t in BUILTIN_TYPES or (t[0].isupper() and any(ch.islower() for ch in t)):
            return ('type', 'alias', rhs)
    return None


def scan_procs(filepath, basename):
    """Extract procedures (and type declarations) from a single .odin file.

    Returns list of (file_stem, block_name, name, sig) tuples, where sig is the
    signature_after() result, ('decl', status, kind, target) for a type
    declaration, or None when it couldn't be parsed.
    """
    procs = []
    file_stem = basename[:-5] if basename.endswith(".odin") else basename

    try:
        with open(filepath, encoding="utf-8", errors="ignore") as f:
            lines = f.read().split('\n')
    except OSError:
        return procs

    in_foreign = False
    foreign_lib = ""
    brace_depth = 0

    for li, line in enumerate(lines):
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
                    procs.append((file_stem, foreign_lib, name, signature_after(lines, li, m.end())))

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
                    procs.append((file_stem, "", name, signature_after(lines, li, m.end())))
                continue
            # Alias of a compiler intrinsic, e.g. `L :: intrinsics.constant_utf16_cstring`
            # (sys/windows). Callable; signature known only for intrinsics in INTRINSIC_SIGS.
            m = intrinsic_alias_re.match(line)
            if m and not m.group(1).startswith("_"):
                known = INTRINSIC_SIGS.get(m.group(2))
                sig = None
                if known:
                    req, variadic = param_arity(known[0])
                    sig = ('sig', req, variadic, known[0], known[1])
                procs.append((file_stem, "", m.group(1), sig))
                continue
            # Type declaration (struct/enum/distinct/alias...), else a constant.
            m = decl_re.match(line)
            if m and not m.group(1).startswith("_"):
                c = classify_decl(m.group(2))
                if c:
                    procs.append((file_stem, "", m.group(1), ('decl',) + c))
                else:
                    rhs = norm_ws(strip_line_comment(m.group(2)))
                    if rhs and not rhs.startswith(NOT_CONSTANTS):
                        procs.append((file_stem, "", m.group(1), ('const', '', rhs)))
                continue
            m = typed_const_re.match(line)
            if m and not m.group(1).startswith("_") and not m.group(2).strip().startswith(('proc', '#')):
                procs.append((file_stem, "", m.group(1), ('const', norm_ws(m.group(2)), norm_ws(strip_line_comment(m.group(3))))))

    return procs


def scan_folder(folder):
    """Extract all procedures from all .odin files in folder.

    Returns list of (file_stem, block_name, proc_name, sig) tuples.
    """
    procs = []
    for fname in odin_files(folder):
        filepath = os.path.join(folder, fname)
        procs.extend(scan_procs(filepath, fname))
    return procs


def resolve_types(decls):
    """decls: [(file, name, ('decl', status, kind, target))] for one package.

    Returns [(file, name, kind, target)] for declarations that are types. An alias
    `A :: B` is a type when B is a type declared in the same package (resolved to
    a fixed point), so `MB_ICONINFORMATION :: MB_ICONASTERISK` (a constant) is
    dropped while `LPCWSTR :: wstring` (wstring :: cstring16) is kept.
    """
    is_type = {name for _, name, d in decls if d[1] == 'type'}
    changed = True
    while changed:
        changed = False
        for _, name, d in decls:
            if d[1] == 'alias' and name not in is_type and d[3] in is_type:
                is_type.add(name)
                changed = True
    return [(file, name, d[2], d[3]) for file, name, d in decls if name in is_type]


def const_kinds(consts, type_names):
    """consts: [(file, name, explicit_type, rhs)] for one package -> {name: kind}.

    kind: "#int" / "#float" / "#string" / "#rune" / "#bool" (untyped constants),
    a type name ("DWORD") for typed ones (`X : DWORD : 1`, `X :: DWORD(1)`), or "?".
    References to other constants (`MB_ICONINFORMATION :: MB_ICONASTERISK`,
    `A :: B | C`) take their kind, resolved to a fixed point.
    """
    kinds = {}
    rhs_of = {}
    for _, name, explicit, rhs in consts:
        rhs_of[name] = rhs
        if explicit:
            kinds[name] = explicit

    def literal_kind(rhs):
        r = rhs.strip()
        while r.startswith('(') and r.endswith(')'):
            r = r[1:-1].strip()
        if number_re.match(r):
            return '#float' if ('.' in r or ('e' in r.lower() and not r.lower().startswith('0x'))) else '#int'
        if r.startswith(('"', '`')):
            return '#string'
        if r.startswith("'"):
            return '#rune'
        if r in ('true', 'false'):
            return '#bool'
        m = call_or_lit_re.match(r)
        if m and (m.group(1) in type_names or m.group(1) in BUILTIN_TYPES):
            return m.group(1)  # DWORD(5), Foo{...}
        return None

    changed = True
    while changed:
        changed = False
        for name, rhs in rhs_of.items():
            if name in kinds:
                continue
            k = literal_kind(rhs)
            if k is None:
                # An expression of other constants / numbers: A | B, ~DWORD(0), 1 << 3, size_of(T)
                if '"' in rhs or "'" in rhs or '`' in rhs:
                    continue
                parts = [w for w in word_re.findall(rhs) if w not in EXPR_KEYWORDS
                         and w not in type_names and w not in BUILTIN_TYPES]
                typed = [m.group(1) for m in re.finditer(r'([A-Za-z_]\w*)\s*\(', rhs)
                         if m.group(1) in type_names or m.group(1) in BUILTIN_TYPES]
                if typed:
                    k = typed[0]
                elif all(w in kinds for w in parts) and parts:
                    sub = {kinds[w] for w in parts}
                    named = [x for x in sub if not x.startswith('#') and x != '?']
                    if named:
                        k = named[0]
                    elif sub <= {'#int', '#float', '#rune'}:
                        k = '#float' if '#float' in sub else '#int'
                    else:
                        k = '?' if len(sub) > 1 else sub.pop()
                elif not parts and re.search(r'[0-9]', rhs):
                    k = '#int'  # e.g. `1 << 3`, `size_of(u32) * 2`
                else:
                    continue  # depends on something not resolved (yet)
            kinds[name] = k
            changed = True
    return {name: kinds.get(name, '?') for name in rhs_of}


def resolve_sigs(procs):
    """Map each proc name in one package to (req, variadic, params, ret).

    Proc groups take the smallest required count of their members, and count as
    variadic if any member is variadic or the members' arities differ; their
    params are unknown ("") and ret is "?" (unknown; "" means no return value).
    Unparseable signatures default to (0, True, "", "?").
    """
    sigs = {}
    for _, _, name, sig in procs:
        if sig and sig[0] == 'sig':
            prev = sigs.get(name)
            cur = (sig[1], sig[2], sig[3], sig[4])
            if prev is None:
                sigs[name] = cur
            elif prev != cur:  # same name, different signature (e.g. per-OS files)
                if prev[:3] == cur[:3]:
                    # Same parameters; differing return spelling -> keep params, ret unknown.
                    sigs[name] = prev if prev[3] == cur[3] else prev[:3] + ("?",)
                else:
                    sigs[name] = (min(prev[0], cur[0]), True, "", "?")
    groups = {name: sig[1] for _, _, name, sig in procs if sig and sig[0] == 'group'}

    def group_sig(name, seen):
        if name in sigs:
            return sigs[name]
        if name not in groups or name in seen:
            return None
        seen.add(name)
        members = [a for a in (group_sig(m, seen) for m in groups[name]) if a]
        if not members:
            return None
        req = min(a[0] for a in members)
        variadic = any(a[1] for a in members) or len({a[0] for a in members}) > 1
        return (req, variadic, "", "?")

    out = {}
    for _, _, name, _ in procs:
        out[name] = group_sig(name, set()) or (0, True, "", "?")
    return out


def collect_all(root):
    """Recursively collect proc tuples (path, file, block, name, req, variadic, params, ret)
    and type tuples (path, file, kind, name, target) from core packages."""
    results = []
    types = []
    consts = []

    def walk(folder, rel):
        # Skip test-only and example directories
        base = os.path.basename(folder)
        if base in SKIP_DIRS or base.startswith("."):
            return

        # Check if this folder is importable (has non-test .odin files)
        files = odin_files(folder)
        if files:
            path = "core:" + rel if rel else "core"
            scanned = scan_folder(folder)
            decls = [(f, n, sig) for f, _, n, sig in scanned if sig and sig[0] == 'decl']
            procs = [t for t in scanned if not (t[3] and t[3][0] in ('decl', 'const'))]
            resolved_types = resolve_types(decls)
            type_names = {name for _, name, _, _ in resolved_types}
            for file_stem, name, kind, target in resolved_types:
                types.append((path, file_stem, kind, name, target))
            # Constants: `X :: value`, `X : T : value`, plus aliases that turned out not
            # to be types (`MB_ICONINFORMATION :: MB_ICONASTERISK`).
            cdecls = [(f, n, sig[1], sig[2]) for f, _, n, sig in scanned if sig and sig[0] == 'const']
            cdecls += [(f, n, '', sig[3]) for f, n, sig in decls if sig[1] == 'alias' and n not in type_names]
            proc_names = {n for _, _, n, _ in procs}
            # Drop proc aliases (`emit_x :: emit_x_r_r_r`): callable, not constant values.
            cdecls = [c for c in cdecls if c[1] not in proc_names and c[3] not in proc_names]
            ckinds = const_kinds(cdecls, type_names)
            for file_stem, name, _, _ in cdecls:
                consts.append((path, file_stem, name, ckinds[name]))
            sigs = resolve_sigs(procs)
            for file_stem, block, name, _ in procs:
                results.append((path, file_stem, block, name) + sigs[name])

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
    return results, types, consts


def odin_str(s):
    """An Odin string literal for s."""
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    tuples, types, consts = collect_all(CORE)

    # Deduplicate by (path, file, block, name)
    unique = {}
    for path, file, block, name, req, variadic, params, ret in tuples:
        unique[(path, file, block, name)] = (req, variadic, params, ret)

    # Sort by (path, file, block, name)
    sorted_keys = sorted(unique.keys())

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("package model\n\n")
        f.write("// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.\n\n")
        f.write("// req = required parameter count; variadic = accepts any number of extra args;\n")
        f.write("// params = parameter list text; ret = return type text (\"\" = no return value, \"?\" = unknown).\n")
        f.write("CoreProc :: struct { path: string, file: string, block: string, name: string, req: int, variadic: bool, params: string, ret: string }\n\n")
        f.write("CORE_PROCS := [?]CoreProc{\n")
        for key in sorted_keys:
            path, file, block, name = key
            req, variadic, params, ret = unique[key]
            f.write(f'\t{{"{path}", "{file}", "{block}", "{name}", {req}, {"true" if variadic else "false"}, {odin_str(params)}, {odin_str(ret)}}},\n')
        f.write("}\n")

    print(f"Generated {len(sorted_keys)} proc entries -> {OUT}")

    types = sorted(set(types))
    with open(TYPES_OUT, "w", encoding="utf-8") as f:
        f.write("package model\n\n")
        f.write("// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.\n\n")
        f.write("// Type declarations per core package. kind = struct/enum/union/bit_set/\n")
        f.write("// bit_field/distinct/alias; target = what a distinct/alias refers to.\n")
        f.write("CoreType :: struct { path: string, file: string, kind: string, name: string, target: string }\n\n")
        f.write("CORE_TYPES := [?]CoreType{\n")
        for path, file, kind, name, target in types:
            f.write(f'\t{{"{path}", "{file}", "{kind}", "{name}", {odin_str(target)}}},\n')
        f.write("}\n")
    print(f"Generated {len(types)} type entries -> {TYPES_OUT}")

    consts = sorted(set(consts))
    with open(CONSTS_OUT, "w", encoding="utf-8") as f:
        f.write("package model\n\n")
        f.write("// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.\n\n")
        f.write("// Constants per core package. kind = \"#int\"/\"#float\"/\"#string\"/\"#rune\"/\"#bool\"\n")
        f.write("// for untyped constants, a type name for typed ones, \"?\" when unknown.\n")
        f.write("CoreConst :: struct { path: string, file: string, name: string, kind: string }\n\n")
        f.write("CORE_CONSTS := [?]CoreConst{\n")
        for path, file, name, kind in consts:
            f.write(f'\t{{"{path}", "{file}", "{name}", {odin_str(kind)}}},\n')
        f.write("}\n")
    print(f"Generated {len(consts)} constant entries -> {CONSTS_OUT}")


if __name__ == "__main__":
    main()

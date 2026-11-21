#!/usr/bin/env python3
"""Scan Odin's built-in collections (core:, base:, vendor:) and emit the package
tables in src/model/:

core_procs.odin  CORE_PROCS - every public procedure, with its signature:
  req      - number of required parameters (no default value, not variadic)
  variadic - takes a `..T` parameter (or is a proc group whose members' arity varies)
  params   - the parameter list text, e.g. "hWnd: HWND, lpText: LPCWSTR" ("" = unknown)
  ret      - the return type text, e.g. "INT" ("" = none or unknown)
  Includes procedures in foreign blocks, bodiless declarations (base:intrinsics,
  `name :: proc(...) -> T ---`) and proc-typed globals whose type is a proc type
  of the same package (vendor:vulkan `CreateInstance: ProcCreateInstance`).

core_types.odin  CORE_TYPES - the type declarations of each package
  (struct/enum/union/bit_set/distinct/aliases like `LPCWSTR :: wstring`) with what
  they refer to, for the Type fill menu and for checking which fills fit a slot.

core_consts.odin CORE_CONSTS - the constants of each package (MB_OK, WM_PAINT, ...)
  with their kind: untyped "#int"/"#float"/"#string"/"#rune"/"#bool", an explicit
  type ("DWORD"), or "?" when it can't be told - for the "Constant" fill menu.

core_fields.odin CORE_FIELDS - one row per field of every struct (field access,
  struct literals). core_enums.odin CORE_ENUM_MEMBERS - one row per enum member.

Declarations count when they are at file scope, including inside top-level
`when` blocks (OpenGL, sdl2). When a name is declared several times in a file
(per-OS `when` branches) the Windows variant wins, else the first one; struct
and enum declarations are picked the same way across a package's files.
Excluded: test files, tests/examples dirs, `package main` folders, vendor
packages that don't build on Windows (darwin/*, android/*, x11, egl, wasm; they
are still listed, platform-tagged, in the Import menu), `#+private`
files, `@(private)` declarations, names starting with `_`, and `main`.

Usage: python tools/gen_core_procs.py [ODIN_ROOT]
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odin_collections import (ODIN_ROOT, COLLECTIONS, SKIP_DIRS, NOT_IMPORTABLE,
                              collection_root, import_path, is_program,
                              windows_score_for_file, package_platform, builds_on_windows)

ROOT = sys.argv[1] if len(sys.argv) > 1 else ODIN_ROOT
MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "model")
OUT = os.path.join(MODEL_DIR, "core_procs.odin")
TYPES_OUT = os.path.join(MODEL_DIR, "core_types.odin")
CONSTS_OUT = os.path.join(MODEL_DIR, "core_consts.odin")
FIELDS_OUT = os.path.join(MODEL_DIR, "core_fields.odin")
ENUMS_OUT = os.path.join(MODEL_DIR, "core_enums.odin")

# Proc declaration (matched at the start of a file-scope statement):
# foo :: proc(, foo :: proc{, foo :: proc "c" (, foo :: #force_inline proc(
proc_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*(?:#force_(?:no_)?inline\s+)?proc\b')

# Foreign block start: foreign <lib> {
foreign_re = re.compile(r'foreign\s+(?!import\b)(\w+)\s*\{')

# Alias of a compiler intrinsic: `name :: intrinsics.something`
intrinsic_alias_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*intrinsics\.(\w+)\s*$')

# A global whose type is named: `CreateInstance: ProcCreateInstance` (vendor:vulkan).
proc_var_re = re.compile(r'([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)\s*$')

# `Name :: #type proc ...` (a proc type).
proc_type_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*#type\s+proc\b')

# `Name :: struct ...` / `Name :: distinct struct ...` / `Name :: enum ...`
struct_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*(?:distinct\s+)?struct\b')
enum_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*(?:distinct\s+)?enum\b')

# Attributes in front of a declaration: @(private), @(require_results), @private
attr_re = re.compile(r'@(?:\((?:[^()]|\([^()]*\))*\)|[A-Za-z_]\w*)\s*')

# Known signatures of intrinsics that core packages re-export under another name.
INTRINSIC_SIGS = {
    # sys/windows: L :: intrinsics.constant_utf16_cstring -> L("text") is a cstring16
    "constant_utf16_cstring": ("value: string", "cstring16"),
}

# After `proc`: optional calling convention string, then `(` (signature) or `{` (group).
after_proc_re = re.compile(r'\s*(?:"[^"]*"\s*)?([({])')

MAX_SIG_LINES = 60

# Typed constant: `Name : Type : value`.
typed_const_re = re.compile(r'([A-Za-z_]\w*)\s*:\s*([^:=]+?)\s*:\s*(.+?)\s*$')
number_re = re.compile(r'^[-+]?(0[xXbBoOzZ][0-9a-fA-F_]+|[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9]+)?)[ijk]?$')
call_or_lit_re = re.compile(r'^([A-Za-z_][\w.]*)\s*[({]')  # T(...) cast or T{...} literal
word_re = re.compile(r'[A-Za-z_]\w*')
NOT_CONSTANTS = ('#config', '#load', '#directory', '#file', '#line', '#location', '#procedure',
                 '#force_inline', '#force_no_inline', 'proc', '#type', 'struct', 'enum', 'union',
                 'nil', '---')
EXPR_KEYWORDS = {'size_of', 'align_of', 'offset_of', 'len', 'cap', 'min', 'max', 'abs', 'clamp',
                 'type_of', 'typeid_of', 'cast', 'transmute', 'auto_cast', 'true', 'false'}

# Constant-or-type declaration: `Name :: <rhs>`.
decl_re = re.compile(r'([A-Za-z_]\w*)\s*::\s*(.+?)\s*$')
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


def blank_comments(text):
    """`text` with every comment replaced by spaces (newlines kept), so line
    numbers and columns still match. Odin block comments nest."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            i = j + 1
        elif c == '`':
            j = text.find('`', i + 1)
            i = n if j < 0 else j + 1
        elif c == '/' and text[i + 1:i + 2] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c == '/' and text[i + 1:i + 2] == '*':
            depth, j = 1, i + 2
            while j < n and depth > 0:
                if text[j] == '/' and text[j + 1:j + 2] == '*':
                    depth += 1
                    j += 2
                elif text[j] == '*' and text[j + 1:j + 2] == '/':
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


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


next_decl_re = re.compile(r'\s*(?:@|[A-Za-z_]\w*\s*::)')


def return_text(lines, li, col):
    """The return type after a proc's parameter list (`-> T`), or ""."""
    rest = []
    for k in range(li, min(len(lines), li + 6)):
        line = strip_line_comment(lines[k])
        seg = line[col:] if k == li else line
        # A bodiless declaration (`foo :: proc() -> T` in base:intrinsics) ends at
        # its line: don't run on into the next declaration.
        if k > li and (not seg.strip() or next_decl_re.match(seg)):
            break
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
        # A polymorphic struct / union keeps its parameter list as its target
        # (`struct($T: typeid)` -> "($T: typeid)"): it can't be used bare.
        rest = rhs[len(word):].lstrip()
        if word in ('struct', 'union') and rest.startswith('('):
            depth = 0
            for i, ch in enumerate(rest):
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        return ('type', word, rest[:i + 1])
            return ('type', word, "(?)")
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
        # `c.uint`: a builtin type. Any other `pkg.Name` is decided once every
        # package is scanned (resolve_cross_aliases): a proc there
        # (`CreateWindow :: glfw.CreateWindow` in vendor:glfw), a type, or a
        # constant.
        if m.group(1) in BUILTIN_TYPES:
            return ('type', 'alias', rhs)
        return ('xalias', 'alias', rhs)
    return None


def heuristic_cross_alias(rhs):
    """The old guess for `pkg.Name` when the target package isn't known:
    CamelCase is a type, anything else (ALL_CAPS) a constant."""
    t = rhs.split('.')[-1]
    return 'type' if t[0].isupper() and any(ch.islower() for ch in t) else 'const'


import_re = re.compile(r'^\s*import\s+(?:([A-Za-z_]\w*)\s+)?"([^"]+)"')


def folder_import_path(folder):
    """The import path ("core:sys/windows") of an absolute package folder, or None."""
    folder = os.path.normcase(os.path.normpath(folder))
    for collection in COLLECTIONS:
        root = os.path.normcase(os.path.normpath(collection_root(collection, ROOT)))
        if folder == root:
            return None
        if folder.startswith(root + os.sep):
            return import_path(collection, os.path.relpath(folder, root).replace(os.sep, '/'))
    return None


def file_imports(text, folder):
    """{alias: import path} for a file's `import [alias] "path"` lines. Relative
    imports (`"bindings"`, `"../sdl2"`) resolve against the file's folder."""
    out = {}
    for line in text.split('\n'):
        m = import_re.match(line)
        if not m:
            continue
        path = m.group(2)
        if ':' not in path:
            resolved = folder_import_path(os.path.join(folder, path))
            if resolved is None:
                continue
            path = resolved
        alias = m.group(1) or re.split(r'[:/]', path)[-1]
        out[alias] = path
    return out


# ---- File-scope tracking ----

def combine_scores(a, b):
    """Windows preference of a declaration nested in two conditions."""
    if a == 0 or b == 0:
        return 0
    return 2 if 2 in (a, b) else 1


def when_cond_score(cond):
    """(score, is_not_windows) for a `when` condition: 2 = Windows-only, 0 = another OS."""
    if re.search(r'ODIN_OS\s*==\s*\.Windows\b', cond):
        return 2, False
    if re.search(r'ODIN_OS\s*!=\s*\.Windows\b', cond):
        return 0, True
    if re.search(r'ODIN_OS\s*==\s*\.\w+', cond):
        return 0, False
    return 1, False


def scope_lines(text):
    """For each line of comment-blanked `text`: (status, score, foreign_id), where
    status is 'file' (file scope, maybe inside top-level `when` blocks), 'foreign'
    (directly inside a file-scope `foreign lib {` block) or None (anywhere else,
    including inside parens, brackets and multi-line strings); score is the
    Windows preference of the enclosing `when` branches; foreign_id is the line
    the foreign block opened on."""
    lines = text.split('\n')
    info = []
    stack = []        # entries: (kind, score, foreign_id); kind in when/foreign/other/paren
    chains = {}       # depth -> [(score, is_not_windows)] of the current when/else chain
    in_string = None  # '`' while inside a multi-line raw string
    for li, line in enumerate(lines):
        status = None
        if in_string is None:
            kinds = [k for k, _, _ in stack]
            if all(k == 'when' for k in kinds):
                status = 'file'
            elif kinds[-1:] == ['foreign'] and all(k == 'when' for k in kinds[:-1]):
                status = 'foreign'
        score = 1
        fid = None
        for k, s, f in stack:
            score = combine_scores(score, s)
            if k == 'foreign':
                fid = f
        info.append((status, score, fid))
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if in_string:
                j = line.find('`', i)
                if j < 0:
                    break
                in_string = None
                i = j + 1
                continue
            if c in '"\'':
                j = i + 1
                while j < n and line[j] != c:
                    j += 2 if line[j] == '\\' else 1
                i = j + 1
                continue
            if c == '`':
                j = line.find('`', i + 1)
                if j < 0:
                    in_string = '`'
                    break
                i = j + 1
                continue
            if c in '([':
                stack.append(('paren', 1, None))
            elif c in ')]':
                if stack:
                    stack.pop()
            elif c == '{':
                kind, sc, f = 'other', 1, None
                if all(k == 'when' for k, _, _ in stack):
                    header = attr_re.sub('', line[:i].strip().lstrip('}').strip())
                    depth = len(stack)
                    m = re.match(r'(else\s+)?when\b(.*)$', header)
                    if m:
                        cs = when_cond_score(m.group(2))
                        if m.group(1):
                            chains.setdefault(depth, []).append(cs)
                        else:
                            chains[depth] = [cs]
                        kind, sc = 'when', cs[0]
                    elif re.match(r'else\b', header):
                        chain = chains.get(depth, [])
                        if any(s == 2 for s, _ in chain):
                            sc = 0
                        elif any(ne for _, ne in chain):
                            sc = 2
                        kind = 'when'
                    elif foreign_re.match(header + '{'):
                        kind, f = 'foreign', li
                stack.append((kind, sc, f))
            elif c == '}':
                if stack:
                    stack.pop()
            i += 1
    return lines, info


def body_text(text, pos):
    """The text inside the first `{...}` at or after `pos` (skipping `(...)`
    parameter lists, e.g. `struct($T: typeid) {`), or None."""
    n = len(text)
    depth = 0
    i = pos
    start = None
    while i < n:
        c = text[i]
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            i = j + 1
            continue
        if c == '`':
            j = text.find('`', i + 1)
            i = n if j < 0 else j + 1
            continue
        if start is None:
            if c in '([':
                depth += 1
            elif c in ')]':
                depth -= 1
            elif c == '{' and depth == 0:
                start = i + 1
                depth = 1
            elif c in ';}' and depth == 0:
                return None
        else:
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
                if depth == 0:
                    return text[start:i]
        i += 1
    return None


tag_re = re.compile(r'\s*("(?:[^"\\]|\\.)*"|`[^`]*`)$')


def parse_bit_field_members(body):
    """[(name, type, False)] for the `name: Type | bits` members of a bit_field body."""
    out = []
    for part in split_top_level(body):
        p = norm_ws(part)
        colon = p.find(':')
        if colon < 0:
            continue
        name = p[:colon].strip()
        typ = p[colon + 1:].split('|', 1)[0].strip()
        if ident_re.match(name) and name != '_' and typ:
            out.append((name, typ, False))
    return out


def promoted_inline_fields(typ):
    """The fields a `using x: <anonymous type>` promotes: an inline
    `struct [#raw_union|#packed|#align(N)] {...}` (recursively) or a
    `bit_field T {...}`. None when typ isn't such an inline type."""
    if '{' not in typ:
        return None
    inner = body_text(typ, 0)
    if inner is None:
        return None
    if re.match(r'struct\b', typ):
        return parse_struct_fields(inner)
    if re.match(r'bit_field\b', typ):
        return parse_bit_field_members(inner)
    return None


def parse_struct_fields(body):
    """[(name, type, using)] for the fields in a struct body, in order.

    Padding / anonymous fields named `_` are never listed (they can't be named
    in a selector or a literal). The fields promoted by a `using` of an inline
    anonymous struct / raw_union / bit_field (`using _: struct #raw_union {...}`
    in OVERLAPPED, `using _: bit_field DWORD {...}` in DCB) are listed as plain
    rows in its place: Odin accepts them as `x.Offset` and in `T{Offset = 1}`.
    A `using _: NamedType` stays as a carrier row (Doodle expands its fields
    and never offers `_` itself)."""
    out, pending = [], []
    for part in split_top_level(body):
        p = norm_ws(part)
        using = False
        while True:
            if p.startswith('#subtype '):
                p = p[len('#subtype '):].strip()
            elif p.startswith('using '):
                using = True
                p = p[len('using '):].strip()
            else:
                break
        colon = p.find(':')
        if colon < 0:
            if ident_re.match(p):
                pending.append(p)
            continue
        name = p[:colon].strip()
        typ = tag_re.sub('', p[colon + 1:].strip()).strip()
        if not ident_re.match(name):
            pending = []
            continue
        promoted = promoted_inline_fields(typ) if using else None
        if re.search(r'\b(struct|union)\b', typ) and '{' in typ:
            typ = '?'  # anonymous nested struct / union
        if name == '_' and '{' in typ:
            typ = '?'
        for nm in pending + [name]:
            if nm == '_' and (not using or promoted is not None or typ == '?'):
                continue  # padding, or an anonymous carrier flattened below
            out.append((nm, typ, using and promoted is None))
        pending = []
        if promoted:
            out.extend(promoted)
    return out


def parse_enum_members(body):
    out = []
    for part in split_top_level(body):
        name = part.split('=', 1)[0].strip()
        if ident_re.match(name):
            out.append(name)
    return out


def scan_file(filepath, basename):
    """Extract declarations from one .odin file.

    Returns (procs, records, proc_types) where procs is a list of
    (file_stem, block_name, name, sig) tuples: sig is the signature_after()
    result, ('decl', status, kind, target) for a type declaration,
    ('const', type, rhs) for a constant, ('procvar', type_name) for a global of a
    named type, or None when it couldn't be parsed. records is a list of
    ('struct' | 'enum', name, score, rows); proc_types maps proc type names to
    their signature.
    """
    file_stem = basename[:-5] if basename.endswith(".odin") else basename
    try:
        with open(filepath, encoding="utf-8", errors="ignore") as f:
            raw = f.read().replace('\r\n', '\n')
    except OSError:
        return [], [], {}

    build_lines = []
    for line in raw.split('\n'):
        s = line.strip()
        if s.startswith('#+private'):
            return [], [], {}  # nothing in here is visible to importers
        if s.startswith('#+build'):
            build_lines.append(s[len('#+build'):])
        if s.startswith('package '):
            break
    file_score = windows_score_for_file(basename, build_lines)

    text = blank_comments(raw)
    imports = file_imports(text, os.path.dirname(filepath))
    lines, info = scope_lines(text)
    line_starts = [0]
    for line in lines:
        line_starts.append(line_starts[-1] + len(line) + 1)

    found = []          # (name, kind, score, payload) in source order
    records = []
    proc_types = {}
    private_foreign = set()
    pending_attrs = ''

    for li, line in enumerate(lines):
        status, when_score, fid = info[li]
        if status is None:
            continue
        stripped = line.strip()
        if not stripped:
            continue
        off = len(line) - len(line.lstrip())
        attrs = ''
        while True:
            m = attr_re.match(line, off)
            if not m:
                break
            attrs += m.group(0)
            off = m.end()
        if off >= len(line.rstrip()):
            pending_attrs += attrs  # attribute line in front of a declaration
            continue
        attrs = pending_attrs + attrs
        pending_attrs = ''
        private = 'private' in attrs
        score = combine_scores(file_score, when_score)

        if status == 'foreign':
            if fid in private_foreign:
                continue
            m = proc_re.match(line, off)
            if m:
                name = m.group(1)
                if not name.startswith("_") and name != "main" and not private:
                    lib = foreign_lib_name(lines[fid]) if fid is not None else ""
                    found.append((name, 'proc', score, (lib, signature_after(lines, li, m.end()))))
            continue

        # File scope.
        if foreign_re.match(line, off) or re.match(r'foreign\s+\w+\s*$', line[off:].rstrip()):
            if private:
                # the block starts on this line (or the next): its members follow
                private_foreign.add(li)
                private_foreign.add(li + 1)
            continue
        m = proc_re.match(line, off)
        if m:
            name = m.group(1)
            if not name.startswith("_") and name != "main" and not private:
                found.append((name, 'proc', score, ("", signature_after(lines, li, m.end()))))
            continue
        if private:
            continue
        # Alias of a compiler intrinsic, e.g. `L :: intrinsics.constant_utf16_cstring`
        # (sys/windows). Callable; signature known only for intrinsics in INTRINSIC_SIGS.
        m = intrinsic_alias_re.match(line, off)
        if m and not m.group(1).startswith("_"):
            known = INTRINSIC_SIGS.get(m.group(2))
            sig = None
            if known:
                req, variadic = param_arity(known[0])
                sig = ('sig', req, variadic, known[0], known[1])
            found.append((m.group(1), 'proc', score, ("", sig)))
            continue
        m = proc_type_re.match(line, off)
        if m and not m.group(1).startswith("_"):
            sig = signature_after(lines, li, m.end())
            if sig and sig[0] == 'sig':
                proc_types.setdefault(m.group(1), sig)
        for rx, kind in ((struct_re, 'struct'), (enum_re, 'enum')):
            m = rx.match(line, off)
            if m and not m.group(1).startswith("_"):
                body = body_text(text, line_starts[li] + m.end())
                if body is not None:
                    rows = parse_struct_fields(body) if kind == 'struct' else parse_enum_members(body)
                    records.append((kind, m.group(1), score, rows))
        # Type declaration (struct/enum/distinct/alias...), else a constant.
        m = decl_re.match(line, off)
        if m and not m.group(1).startswith("_"):
            c = classify_decl(m.group(2))
            if c and c[0] == 'xalias':
                # `Name :: pkg.Target`: remember which package `pkg` is here.
                ref = c[2].split('.')[0]
                found.append((m.group(1), 'decl', score, ('decl',) + c + (imports.get(ref, ''),)))
            elif c:
                found.append((m.group(1), 'decl', score, ('decl',) + c))
            else:
                rhs = norm_ws(m.group(2))
                if rhs and not rhs.startswith(NOT_CONSTANTS):
                    found.append((m.group(1), 'const', score, ('const', '', rhs)))
            continue
        m = typed_const_re.match(line, off)
        if m and not m.group(1).startswith("_") and not m.group(2).strip().startswith(('proc', '#')):
            found.append((m.group(1), 'const', score, ('const', norm_ws(m.group(2)), norm_ws(m.group(3)))))
            continue
        m = proc_var_re.match(line, off)
        if m and not m.group(1).startswith("_"):
            found.append((m.group(1), 'procvar', score, ('procvar', m.group(2))))

    # One declaration per name and kind in this file: the Windows variant of
    # per-OS `when` branches, else the first.
    best = {}
    for idx, (name, kind, score, payload) in enumerate(found):
        key = (name, kind, payload[0] if kind == 'proc' else "")
        if key not in best or score > found[best[key]][2]:
            best[key] = idx
    procs = []
    for idx in sorted(best.values()):
        name, kind, score, payload = found[idx]
        if kind == 'proc':
            procs.append((file_stem, payload[0], name, payload[1]))
        else:
            procs.append((file_stem, "", name, payload))
    return procs, [(k, n, s, r, file_stem) for k, n, s, r in records], proc_types


def foreign_lib_name(line):
    m = re.search(r'foreign\s+(\w+)', line)
    return m.group(1) if m else ""


def scan_folder(folder):
    """All declarations of the package in `folder` (see scan_file)."""
    procs, records, proc_types = [], [], {}
    for fname in sorted(odin_files(folder)):
        p, r, t = scan_file(os.path.join(folder, fname), fname)
        procs.extend(p)
        records.extend(r)
        for k, v in t.items():
            proc_types.setdefault(k, v)
    return procs, records, proc_types


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


# Cross-package aliases `Name :: pkg.Target`, decided after every package is
# scanned: (path, file, name, rhs, target_path).
DEFERRED = []


def collect_package(folder, path, results, types, consts, structs, enums):
    """Add the declarations of one package (import path `path`) to the tables."""
    scanned, records, proc_types = scan_folder(folder)
    # Globals of a proc type (`CreateInstance: ProcCreateInstance`) are callable.
    resolved = []
    for f, block, n, sig in scanned:
        if sig and sig[0] == 'procvar':
            if sig[1] in proc_types:
                resolved.append((f, block, n, proc_types[sig[1]]))
            continue
        resolved.append((f, block, n, sig))
    scanned = resolved
    decls = [(f, n, sig) for f, _, n, sig in scanned if sig and sig[0] == 'decl' and sig[1] != 'xalias']
    for f, _, n, sig in scanned:
        if sig and sig[0] == 'decl' and sig[1] == 'xalias':
            DEFERRED.append((path, f, n, sig[3], sig[4]))
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
    # Aliases of procs in this package (`A :: SomeProc`) are callable with the
    # target's signature (chains resolved to a fixed point).
    alias_procs = {n: (f, sig[3]) for f, n, sig in decls if sig[1] == 'alias' and n not in type_names}
    changed = True
    while changed:
        changed = False
        for n, (f, target) in alias_procs.items():
            if n not in sigs and target in sigs:
                sigs[n] = sigs[target]
                results.append((path, f, "", n) + sigs[target])
                changed = True
    # Struct fields / enum members: one declaration per name (Windows first).
    for kind, table in (('struct', structs), ('enum', enums)):
        best = {}
        for k, name, score, rows, _ in records:
            if k != kind:
                continue
            if name not in best or score > best[name][0]:
                best[name] = (score, rows)
        for name, (_, rows) in best.items():
            table[(path, name)] = rows


def walk_collection(collection, root, visit):
    """Call visit(folder, path) for every importable package folder."""
    def walk(folder, rel):
        files = odin_files(folder)
        path = import_path(collection, rel)
        if files and rel and path not in NOT_IMPORTABLE and not is_program(folder, files):
            # Doodle runs on Windows: vendor bindings that can't build there
            # (darwin/*, android/*, x11, egl, wasm) would only add dead weight.
            if collection != "vendor" or builds_on_windows(package_platform(folder, files, path)):
                visit(folder, path)
        try:
            subdirs = sorted(d for d in os.listdir(folder)
                             if os.path.isdir(os.path.join(folder, d)))
        except OSError:
            subdirs = []
        for subdir in subdirs:
            if subdir not in SKIP_DIRS and not subdir.startswith("."):
                walk(os.path.join(folder, subdir), (rel + "/" + subdir) if rel else subdir)
    walk(root, "")


def resolve_cross_aliases(results, types, consts):
    """Decide each deferred `Name :: pkg.Target` from what `pkg` declares: a
    proc there makes Name a proc of the aliasing package (with the target's
    signature), a type a type alias, a constant a constant of the same kind.
    Unknown targets (package not scanned) fall back to the CamelCase guess."""
    proc_sig = {(r[0], r[3]): r[4:] for r in results}
    type_of = {(t[0], t[3]) for t in types}
    const_kind = {(c[0], c[2]): c[3] for c in consts}
    pending = list(DEFERRED)
    changed = True
    while pending and changed:
        changed = False
        rest = []
        for path, f, name, rhs, target in pending:
            key = (target, rhs.split('.')[-1])
            if key in proc_sig:
                results.append((path, f, "", name) + proc_sig[key])
                proc_sig[(path, name)] = proc_sig[key]
            elif key in type_of:
                types.append((path, f, 'alias', name, rhs))
                type_of.add((path, name))
            elif key in const_kind:
                consts.append((path, f, name, const_kind[key]))
                const_kind[(path, name)] = const_kind[key]
            else:
                rest.append((path, f, name, rhs, target))
                continue
            changed = True
        pending = rest
    for path, f, name, rhs, target in pending:
        if heuristic_cross_alias(rhs) == 'type':
            types.append((path, f, 'alias', name, rhs))
        else:
            consts.append((path, f, name, '?'))


def collect_all(odin_root):
    """Proc tuples (path, file, block, name, req, variadic, params, ret), type tuples
    (path, file, kind, name, target), const tuples (path, file, name, kind), and
    {(path, struct name): [(field, type, using)]}, {(path, enum name): [member]}."""
    results, types, consts, structs, enums = [], [], [], {}, {}
    for collection in COLLECTIONS:
        walk_collection(collection, collection_root(collection, odin_root),
                        lambda folder, path: collect_package(folder, path, results, types,
                                                             consts, structs, enums))
    resolve_cross_aliases(results, types, consts)
    return results, types, consts, structs, enums


def odin_str(s):
    """An Odin string literal for s."""
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def write_table(out_path, header_lines, decl, table, rows):
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("package model\n\n")
        f.write("// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.\n\n")
        for line in header_lines:
            f.write("// " + line + "\n")
        f.write(decl + "\n\n")
        f.write(table + " := [?]" + decl.split(" ::", 1)[0] + "{\n")
        for row in rows:
            f.write("\t{" + row + "},\n")
        f.write("}\n")


def b(v):
    return "true" if v else "false"


def main():
    tuples, types, consts, structs, enums = collect_all(ROOT)

    # Deduplicate by (path, file, block, name), sorted.
    unique = {}
    for path, file, block, name, req, variadic, params, ret in tuples:
        unique[(path, file, block, name)] = (req, variadic, params, ret)
    rows = []
    for key in sorted(unique):
        path, file, block, name = key
        req, variadic, params, ret = unique[key]
        rows.append(f'"{path}", "{file}", "{block}", "{name}", {req}, {b(variadic)}, {odin_str(params)}, {odin_str(ret)}')
    write_table(OUT, [
        "Procedures of the core:, base: and vendor: packages.",
        "req = required parameter count; variadic = accepts any number of extra args;",
        "params = parameter list text; ret = return type text (\"\" = no return value, \"?\" = unknown).",
    ], "CoreProc :: struct { path: string, file: string, block: string, name: string, req: int, variadic: bool, params: string, ret: string }",
        "CORE_PROCS", rows)
    print(f"Generated {len(rows)} proc entries -> {OUT}")

    rows = [f'"{path}", "{file}", "{kind}", "{name}", {odin_str(target)}'
            for path, file, kind, name, target in sorted(set(types))]
    write_table(TYPES_OUT, [
        "Type declarations per package (core:, base:, vendor:). kind = struct/enum/union/bit_set/",
        "bit_field/distinct/alias; target = what a distinct/alias refers to.",
    ], "CoreType :: struct { path: string, file: string, kind: string, name: string, target: string }",
        "CORE_TYPES", rows)
    print(f"Generated {len(rows)} type entries -> {TYPES_OUT}")

    rows = [f'"{path}", "{file}", "{name}", {odin_str(kind)}'
            for path, file, name, kind in sorted(set(consts))]
    write_table(CONSTS_OUT, [
        "Constants per package (core:, base:, vendor:). kind = \"#int\"/\"#float\"/\"#string\"/\"#rune\"/\"#bool\"",
        "for untyped constants, a type name for typed ones, \"?\" when unknown.",
    ], "CoreConst :: struct { path: string, file: string, name: string, kind: string }",
        "CORE_CONSTS", rows)
    print(f"Generated {len(rows)} constant entries -> {CONSTS_OUT}")

    rows = [f'"{path}", "{tname}", "{name}", {odin_str(typ)}, {b(using)}'
            for (path, tname) in sorted(structs)
            for name, typ, using in structs[(path, tname)]]
    write_table(FIELDS_OUT, [
        "Struct fields per package (core:, base:, vendor:), grouped by (path, type_name),",
        "fields in declaration order. type = the field's type as written (\"?\" = an",
        "anonymous nested struct/union); using_field = declared `using name: T`.",
    ], "CoreField :: struct { path: string, type_name: string, name: string, type: string, using_field: bool }",
        "CORE_FIELDS", rows)
    print(f"Generated {len(rows)} struct field entries ({len(structs)} structs) -> {FIELDS_OUT}")

    rows = [f'"{path}", "{tname}", "{name}"'
            for (path, tname) in sorted(enums)
            for name in enums[(path, tname)]]
    write_table(ENUMS_OUT, [
        "Enum members per package (core:, base:, vendor:), in declaration order.",
    ], "CoreEnumMember :: struct { path: string, type_name: string, name: string }",
        "CORE_ENUM_MEMBERS", rows)
    print(f"Generated {len(rows)} enum member entries ({len(enums)} enums) -> {ENUMS_OUT}")


if __name__ == "__main__":
    main()

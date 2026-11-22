#!/usr/bin/env python3
"""Analyze, search, replay and verify Doodle trace recordings (bin/traces/<stamp>/).

The file formats (input.log, events.jsonl) are described in docs/TRACE.md.
A <trace> argument is `last` (newest), a stamp (20261120-234400Z), a folder or
input.log path, or `all` where noted.

Usage:
  python -I tools/trace.py list [--limit N]
  python -I tools/trace.py report <trace|all> [--top N]
  python -I tools/trace.py find <trace|all> [predicates] [--first] [--limit N]
  python -I tools/trace.py show <trace> [--around F] [--from F --to F] [--context N]
  python -I tools/trace.py verify <trace|all> [--exe PATH] [--timeout S]
  python -I tools/trace.py replay <trace> [--until F] [--speed X] [--takeover] [--exact] [--exit-at-end]
  python -I tools/trace.py script <name> <steps...> [--projects DIR] [--open REL] [--shot PNG] [--run]
Every subcommand also takes --traces DIR (default: <repo>/bin/traces).

find predicates (ANDed; text matches are case-insensitive):
  --menu-all-prefix S  a visible list whose non-empty items ALL start with S
  --menu-title S       title contains S        --item S   some visible item contains S
  --scr NAME           screen is NAME          --sel S    highlighted item contains S
  --press COMBO        e.g. LT+B, RT+Y, A, Up  --mode S   pre/post mode contains S
  --leaf S             highlighted code text   --text S   stt / project_name mark text
  --expr PY            Python expression; `r` = the record dict, `s` = the screen
                       state after it (act post, or the list / last state). Uses
                       eval(), so only run it on your own recordings.
                       e.g. --expr "r['k']=='act' and s.get('nodes',0) > 40"

Button meanings (report / show) come from BINDINGS below. The editor part follows
the layout each recording started with (meta keymap); edit the table
when the key layout changes.
"""
import argparse, builtins, json, os, re, subprocess, sys, time
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACES_DIR = os.path.join(REPO, "bin", "traces")
EXE = os.path.join(REPO, "bin", "doodle.exe" if os.name == "nt" else "doodle")
EXE_SHOWN = r"bin\doodle.exe" if os.name == "nt" else "bin/doodle"

# Keyboard -> gamepad (docs/TRACE.md; handle_key in src/app/main.odin).
# q / e arrive as LT / RT entries already.
KEY_MAP = {
    "w": "Up", "a": "Left", "s": "Down", "d": "Right",
    "Up": "Up", "Down": "Down", "Left": "Left", "Right": "Right",
    "Return": "A", "Space": "A", "Backspace": "B", "Escape": "B",
    "x": "X", "y": "Y", "r": "RB", "t": "LB",
}
DPAD = ("Up", "Down", "Left", "Right")
OPPOSITE = {"Up": "Down", "Down": "Up", "Left": "Right", "Right": "Left"}
TEXT_SCREENS = ("save_dialog", "rename")     # letter keys type text here
TYPED_RE = re.compile(r"^[a-z0-9.\-]$")       # filename-safe keys (main.odin)
TYPED_KEYS = ("Backspace",)                    # in text screens: deletes a char
PICK_PRESSES = ("pad:A", "key:Return", "key:Space")

# ======================= BINDINGS: the meaning table ========================
# context -> {combo: action}. A context is a screen (pre.scr), or
# "screen[mode]" for a mode in pre.mode, or "screen[dot]" when the cursor is on
# a dot. Specific contexts win over the plain screen. "Dpad" stands for any of
# Up/Down/Left/Right; an exact combo ("LT+Left") wins over "LT+Dpad".
# Update this when bindings change. "editor" is the DEFAULT layout: the Key
# Layout page makes it user-configurable (doodle_keys.tsv next to doodle.exe;
# src/model/keymap.odin KEYMAP_DEFAULT), so a run with a changed layout means
# something else by these combos.
BINDINGS = {
    "editor": {
        "LT+A": "edit", "LT+B": "delete", "LT+Y": "docs", "LT+X": "talk (hold)",
        "LT+Left": "IDE menu",
        "A": "select", "B": "back to main menu", "Y": "change", "Dpad": "move cursor",
        "RT+A": "copy", "RT+B": "file navigation", "RT+Y": "save-as",
        "RT+X": "run list", "RT+Dpad": "walk code tree",
        "RB": "run favorite", "LB": "run tests",
    },
    "editor[dot]": {"A": "add (on a dot)"},
    "editor[dictating]": {"Down": "word break"},
    "main_menu": {"A": "pick", "B": "quit", "Dpad": "move"},
    "menu": {"A": "pick", "B": "back", "Dpad": "move"},
    "filenav": {
        "A": "open file / drop into folder", "B": "up a level / exit", "Y": "search", "X": "new file",
        "LT+X": "rename", "LT+B": "delete", "RT+B": "previous file",
        "Up": "move", "Down": "move", "Left": "move / up a level", "Right": "move",
    },
    "filenav_search": {"A": "open", "B": "end search", "Dpad": "move"},
    "filenav_delete": {"A": "confirm delete", "B": "cancel delete"},
    "projects": {"A": "open project", "B": "back", "Dpad": "move"},
    "new_project": {"A": "create here / add a folder", "B": "back", "X": "remove folder (asks)", "Dpad": "move"},
    "new_project_folder": {"A": "open folder / use it", "B": "cancel", "Left": "up a level", "Right": "open folder",
                           "Up": "move", "Down": "move"},
    "run": {"A": "run command", "B": "close", "Y": "toggle favorite", "Dpad": "move"},
    "run_templates": {"A": "pick template", "B": "back", "Dpad": "move"},
    "docs": {"Up": "scroll", "Down": "scroll", "Left": "page up", "Right": "page down",
             "A": "close", "B": "close", "Y": "close"},
    "key_layout": {"A": "change button / assign", "B": "done / cancel", "X": "clear button",
                   "Y": "reset all (asks)", "Dpad": "move", "LT": "jump to LT card", "RT": "jump to RT card"},
    "save_dialog": {"A": "save", "B": "cancel", "X": "dictate name (hold)"},
    "rename": {"A": "rename", "B": "cancel", "X": "dictate name (hold)"},
}
# =============================================================================

AB_WINDOW = 1.5        # A then B within this many seconds = picked wrong
READD_WINDOW = 3.0     # delete then re-add at the same line
STT_WINDOW = 10.0      # repeated dictation on the same field
OSC_MIN = 3            # alternating opposite d-pad moves in a row
B_RUN_MIN = 3          # consecutive B presses


# ---------------------------------------------------------------- loading

def is_stamp(name):
    return bool(name) and name[0].isdigit()


def stamps(root):
    if not os.path.isdir(root):
        return []
    return sorted((n for n in os.listdir(root)
                   if is_stamp(n) and os.path.isdir(os.path.join(root, n))), reverse=True)


def resolve(arg, root, allow_all=False):
    """Trace folders for `arg` (newest first)."""
    if arg == "all":
        if not allow_all:
            sys.exit("trace.py: `all` isn't allowed here")
        return [os.path.join(root, s) for s in stamps(root)]
    if arg in ("last", "latest"):
        for s in stamps(root):
            d = os.path.join(root, s)
            if any(os.path.exists(os.path.join(d, f)) for f in ("input.log", "events.jsonl")):
                return [d]
        sys.exit("trace.py: no recordings in " + root)
    if os.path.isfile(arg):
        return [os.path.dirname(os.path.abspath(arg))]
    for d in (arg, os.path.join(root, arg)):
        if os.path.isdir(d):
            return [os.path.abspath(d)]
    sys.exit("trace.py: no such trace: " + arg)


def load_events(d):
    """Records of events.jsonl ([] if missing). Bad / truncated lines are skipped."""
    out = []
    try:
        with open(os.path.join(d, "events.jsonl"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("k"), str):
                    if r["k"] == "act":
                        for side in ("pre", "post"):
                            if not isinstance(r.get(side), dict):
                                r[side] = {}
                        if not isinstance(r.get("press"), list):
                            r["press"] = []
                    out.append(r)
    except OSError:
        pass
    return out


def load_input(d):
    """Summary of input.log: meta, last t, presses, frames with presses, clean end."""
    info = {"meta": {}, "t": 0.0, "presses": 0, "frames": 0, "end": False, "ok": False}
    try:
        with open(os.path.join(d, "input.log"), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return info
    info["ok"] = bool(lines) and lines[0].strip().startswith("doodle-trace")
    pressed = set()
    for line in lines[1:]:
        p = line.split(" ")
        if p[0] == "meta" and len(p) >= 2:
            info["meta"][p[1]] = " ".join(p[2:])
        elif p[0] == "end":
            info["end"] = True
        elif len(p) >= 3:
            try:
                if p[1] == "t":
                    info["t"] = float(p[2])
                elif p[1] in ("btn", "key") and len(p) >= 4 and p[3] == "1":
                    info["presses"] += 1
                    pressed.add(p[0])
            except ValueError:
                pass
    info["frames"] = len(pressed)
    return info


def meta_of(events):
    return events[0] if events and events[0].get("k") == "meta" else {}


def acts(events):
    return [r for r in events if r["k"] == "act"]


# ---------------------------------------------------------------- presses

def classify(p, pre, post):
    """(kind, name) of one press: button / trigger / release / typed / other."""
    b = str(p.get("b", ""))
    if b.endswith("-up"):
        return "release", b
    scr = pre.get("scr", "")
    texty = scr in TEXT_SCREENS
    if b in ("LT", "RT"):
        if texty and pre.get("title") != post.get("title"):
            return "typed", "q" if b == "LT" else "e"   # q / e typed into the text
        return "trigger", b
    if b.startswith("key:"):
        k = b[4:]
        if texty and (TYPED_RE.match(k) or k in TYPED_KEYS):
            return "typed", k
        if k in KEY_MAP:
            return "button", KEY_MAP[k]
        return "other", b
    if b.startswith("pad:"):
        return "button", b[4:]
    return "other", b


def combo_of(mods, name):
    return mods + "+" + name if mods else name


def press_info(a):
    """Normalized presses of an act."""
    info = {"buttons": [], "reps": 0, "triggers": [], "typed": [], "other": [], "releases": []}
    pre, post = a["pre"], a["post"]
    for p in a["press"]:
        if not isinstance(p, dict):
            continue
        kind, name = classify(p, pre, post)
        if kind == "release":
            info["releases"].append(name.replace("pad:", "").replace("key:x-up", "X-up"))
            continue
        if p.get("rep"):
            info["reps"] += 1
            continue
        mods = str(p.get("mods") or "")
        if kind == "button":
            info["buttons"].append((combo_of(mods, name), name, mods))
        elif kind == "trigger":
            info["triggers"].append(name)
        elif kind == "typed":
            info["typed"].append(name)
        else:
            info["other"].append(combo_of(mods, name))
    return info


def contexts(state):
    scr = state.get("scr", "")
    out = [scr + "[" + m + "]" for m in str(state.get("mode", "")).split(",") if m]
    if state.get("dot"):
        out.append(scr + "[dot]")
    return out + [scr]


def binding(state, combo):
    """(context, key, action) for combo on this screen, or (None, None, None)."""
    mods, _, name = combo.rpartition("+")
    keys = [combo] + ([combo_of(mods, "Dpad")] if name in DPAD else [])
    for ctx in contexts(state):
        table = BINDINGS.get(ctx, {})
        for k in keys:
            if k in table:
                return ctx, k, table[k]
    return None, None, None


def action(state, combo):
    return binding(state, combo)[2] or combo + " (unbound)"


# The editor's bindings come from the Key Layout page. A recording carries the
# layout it started with (input.log `meta keymap`, the doodle_keys.tsv format);
# use_layout() swaps it into BINDINGS["editor"] while that recording is analyzed.
DEFAULT_EDITOR = dict(BINDINGS["editor"])
LAYOUT_ACTIONS = {
    "edit": "edit", "delete": "delete", "change": "change", "docs": "docs", "copy": "copy",
    "save_as": "save-as", "run_list": "run list", "files": "file navigation",
    "run_favorite": "run favorite", "run_tests": "run tests", "talk": "talk (hold)",
    "ide_menu": "IDE menu", "walk_prev": "walk: previous", "walk_next": "walk: next",
    "walk_in": "walk: in", "walk_out": "walk: out", "format_file": "format file",
    "prev_file": "previous file", "key_layout": "key layout",
}
LAYOUT_BANKS = {"lt": "LT+", "plain": "", "rt": "RT+"}
LAYOUT_BUTTONS = {"up": "Up", "down": "Down", "left": "Left", "right": "Right",
                  "a": "A", "b": "B", "x": "X", "y": "Y"}


def unesc(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            i += 1
            c = {"s": " ", "t": "\t", "n": "\n", "r": "\r"}.get(s[i], s[i])
        out.append(c)
        i += 1
    return "".join(out)


def use_layout(d):
    """Point BINDINGS["editor"] at the layout recording `d` started with."""
    BINDINGS["editor"] = dict(DEFAULT_EDITOR)
    text = unesc(load_input(d)["meta"].get("keymap", ""))
    if not text.startswith("doodle-keys"):
        return  # recorded before the Key Layout page: the defaults
    table = {"A": "select", "B": "back to main menu", "Dpad": "move cursor",
             "RB": "run favorite", "LB": "run tests"}  # fixed
    for line in text.splitlines()[1:]:
        p = line.split("\t")
        if len(p) != 3 or line.startswith("#"):
            continue
        bank, btn, act = LAYOUT_BANKS.get(p[0]), LAYOUT_BUTTONS.get(p[1]), LAYOUT_ACTIONS.get(p[2])
        if bank is not None and btn and act:
            table[bank + btn] = act
    BINDINGS["editor"] = table


# ---------------------------------------------------------------- formatting

def clean(s):
    return re.sub(r"\s+", " ", str(s)).strip()


def where(state):
    scr = state.get("scr", "?")
    if scr == "menu":
        return "menu: " + " > ".join(clean(x) for x in list(state.get("trail") or []) + [state.get("title", "")])
    if scr == "editor":
        f = state.get("file", "")
        return "editor: %sL%s" % (f + " " if f not in ("", ".") else "", state.get("line", 0))
    if state.get("title"):
        return scr + ": " + clean(state["title"])
    return scr


def table(rows, header=None, indent="  "):
    rows = [[str(c) for c in r] for r in rows]
    if header:
        rows.insert(0, list(header))
    if not rows:
        return
    w = [max(len(r[i]) for r in rows if i < len(r)) for i in range(max(map(len, rows)))]
    for r in rows:
        print(indent + "  ".join(c.ljust(w[i]) if i < len(r) - 1 else c for i, c in enumerate(r)).rstrip())


def stamp_of(d):
    return os.path.basename(os.path.normpath(d))


def replay_target(d):
    """What to pass to --replay: the stamp when the exe would find it, else the path."""
    default = os.path.normcase(os.path.abspath(TRACES_DIR))
    if os.path.normcase(os.path.abspath(os.path.dirname(os.path.normpath(d)))) == default:
        return stamp_of(d)
    return os.path.abspath(d)


def section(title):
    print("\n== " + title)


# ---------------------------------------------------------------- list

def cmd_list(args):
    root = args.traces
    rows = []
    for s in stamps(root)[:args.limit]:
        d = os.path.join(root, s)
        ev, inp = load_events(d), load_input(d)
        meta, al = meta_of(ev), acts(ev)
        start = meta.get("start_unix", inp["meta"].get("start_unix", 0))
        try:
            start = float(start)
        except (TypeError, ValueError):
            start = 0
        when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(start)) if start > 0 else "-"
        if ev:
            dur = max([r.get("t", 0) for r in ev if isinstance(r.get("t"), (int, float))] or [0])
            pressed = [press_info(a) for a in al]
            n_act = sum(1 for a in al if a["press"])
            n_press = sum(len(p["buttons"]) + len(p["triggers"]) + len(p["typed"]) + len(p["other"])
                          for p in pressed)
            files = {a["post"].get("file", "") for a in al} - {"", "."}
            ended = any(r["k"] == "mark" and r.get("what") == "end" for r in ev) or inp["end"]
        else:
            dur, n_act, n_press, files, ended = inp["t"], inp["frames"], inp["presses"], set(), inp["end"]
        derived = meta.get("derived_from") or inp["meta"].get("derived_from", "")
        note = "" if ev else " (no events.jsonl)"
        rows.append([s, when, "%.1fs" % dur, n_act, n_press, len(files) or "-",
                     derived or "-", ("yes" if ended else "NO") + note])
    if not rows:
        print("no recordings in " + root)
        return 0
    table(rows, ["stamp", "started (local)", "dur", "acts", "presses", "files", "derived_from", "clean end"])
    return 0


# ---------------------------------------------------------------- report

def analyze(events, stamp):
    """Everything report needs, for one trace (merged by Counter addition)."""
    z = {"combo": Counter(), "by_scr": defaultdict(Counter), "reps": 0, "typed": Counter(),
         "trig_mod": Counter(), "trig_pull": Counter(), "other": Counter(), "actions": Counter(),
         "bound": Counter(), "picks": Counter(), "submenus": Counter(), "cost": Counter(),
         "pos": {}, "time": Counter(), "mistakes": defaultdict(list), "backout_menus": Counter()}
    chain = None            # {"start": f, "cost": n, "picked": bool}
    prev_t, prev_btn = 0.0, None   # prev_btn = (combo, scr, t, f)
    osc, brun, deletes = [], [], []
    last_post, last_stt = {}, None
    for r in events:
        if r["k"] == "mark":
            what = r.get("what")
            if what == "diverged":
                z["mistakes"]["replay diverged"].append((stamp, r.get("f"), clean(r.get("text", ""))))
            elif what == "stt":
                key = (last_post.get("scr"), last_post.get("line"), last_post.get("field"), last_post.get("title"))
                t = r.get("t", 0)
                if last_stt and last_stt[0] == key and t - last_stt[1] <= STT_WINDOW:
                    z["mistakes"]["repeated dictation"].append(
                        (stamp, r.get("f"), "again after %.1fs: %r" % (t - last_stt[1], r.get("text", ""))))
                last_stt = (key, t)
            continue
        if r["k"] != "act":
            continue
        a, pre, post = r, r["pre"], r["post"]
        f, t, scr = a.get("f", 0), a.get("t", 0.0), pre.get("scr", "?")
        last_post = post
        if isinstance(t, (int, float)):
            z["time"][scr] += max(0.0, t - prev_t)
            prev_t = t
        pi = press_info(a)
        z["reps"] += pi["reps"]
        z["typed"].update({scr: len(pi["typed"])} if pi["typed"] else {})
        z["other"].update(pi["other"])
        z["trig_pull"].update(pi["triggers"])
        for combo, name, mods in pi["buttons"]:
            z["combo"][combo] += 1
            z["by_scr"][scr][combo] += 1
            for m in mods.split("+"):
                if m:
                    z["trig_mod"][m] += 1
            ctx, key, act = binding(pre, combo)
            z["actions"][(scr, act or combo + " (unbound)")] += 1
            if ctx:
                z["bound"][(ctx, key)] += 1
            # A then B on the same screen
            if combo == "B" and prev_btn and prev_btn[0] == "A" and prev_btn[1] == scr and t - prev_btn[2] <= AB_WINDOW:
                z["mistakes"]["A then B (picked wrong?)"].append(
                    (stamp, prev_btn[3], "%s, B %.2fs later at f%s" % (where(pre), t - prev_btn[2], f)))
            # B runs
            if combo == "B":
                brun.append(f)
            else:
                if len(brun) >= B_RUN_MIN:
                    z["mistakes"]["%d+ B presses in a row" % B_RUN_MIN].append((stamp, brun[0], "%d x B through f%s" % (len(brun), brun[-1])))
                brun = []
            # d-pad oscillation
            if name in DPAD and osc and osc[-1][2] == scr and osc[-1][0] == combo_of(mods, OPPOSITE[name]):
                osc.append((combo, f, scr))
            else:
                if len(osc) >= OSC_MIN:
                    z["mistakes"]["d-pad oscillation"].append(
                        (stamp, osc[0][1], "%s: %s" % (osc[0][2], " ".join(c for c, _, _ in osc))))
                osc = [(combo, f, scr)] if name in DPAD else []
            prev_btn = (combo, scr, t, f)
            # delete then re-add at the same line
            if scr == "editor" and act == "delete":
                deletes.append((t, pre.get("line"), f))
        if a.get("edit") and not any(c == "LT+B" for c, _, _ in pi["buttons"]):
            for dt, line, df in deletes:
                if 0 < t - dt <= READD_WINDOW and post.get("line") == line:
                    z["mistakes"]["delete then re-add"].append((stamp, df, "line %s, re-added at f%s" % (line, f)))
                    deletes = []
                    break
        deletes = [d for d in deletes if t - d[0] <= READD_WINDOW]
        combos = [c for c, _, _ in pi["buttons"]]
        is_pick = scr == "menu" and any(p.get("b") in PICK_PRESSES and not p.get("mods") and not p.get("rep")
                                        for p in a["press"] if isinstance(p, dict))
        # menu chains
        if scr != "menu" and post.get("scr") == "menu":
            chain = {"start": f, "cost": 0, "picked": False, "title": post.get("title", "")}
        if scr == "menu" and chain is None:
            chain = {"start": f, "cost": 0, "picked": False, "title": pre.get("title", "")}
        if scr == "menu" and chain:
            chain["cost"] += len(pi["buttons"])
        if is_pick:
            path = " > ".join(clean(x) for x in list(pre.get("trail") or []) + [pre.get("title", ""), pre.get("sel", "")] if clean(x))
            deeper = post.get("scr") == "menu" and len(post.get("trail") or []) > len(pre.get("trail") or [])
            if deeper:
                z["submenus"][path] += 1
            else:
                z["picks"][path] += 1
                z["cost"][path] += chain["cost"] if chain else 1
                z["pos"][path] = (pre.get("idx", 0), pre.get("n", 0), clean(pre.get("sel", "")))
                if chain:
                    chain["picked"] = True
                if post.get("scr") == "menu":   # a follow-up menu: a new chain
                    chain = {"start": f, "cost": 0, "picked": False, "title": post.get("title", "")}
        if scr == "menu" and post.get("scr") != "menu":
            if chain and not chain["picked"] and "B" in combos:
                z["mistakes"]["menu backed out without a pick"].append(
                    (stamp, chain["start"], "%s, %d presses, out at f%s" % (clean(chain["title"]), chain["cost"], f)))
                z["backout_menus"][clean(chain["title"])] += 1
            chain = None
        # save dialog cancelled
        if scr in TEXT_SCREENS and post.get("scr") not in TEXT_SCREENS and "B" in combos:
            z["mistakes"]["save dialog cancelled"].append((stamp, f, "%s %r" % (scr, pre.get("title", ""))))
    if len(osc) >= OSC_MIN:
        z["mistakes"]["d-pad oscillation"].append((stamp, osc[0][1], "%s: %s" % (osc[0][2], " ".join(c for c, _, _ in osc))))
    if len(brun) >= B_RUN_MIN:
        z["mistakes"]["%d+ B presses in a row" % B_RUN_MIN].append((stamp, brun[0], "%d x B through f%s" % (len(brun), brun[-1])))
    return z


def merge(a, b):
    for k, v in b.items():
        if isinstance(v, Counter):
            a[k] += v
        elif k == "by_scr":
            for s, c in v.items():
                a[k][s] += c
        elif k == "mistakes":
            for s, l in v.items():
                a[k][s] += l
        elif k == "pos":
            a[k].update(v)
        else:
            a[k] += v
    return a


def cmd_report(args):
    dirs = resolve(args.trace, args.traces, allow_all=True)
    z, used = None, []
    for d in reversed(dirs):
        use_layout(d)
        ev = load_events(d)
        if not acts(ev):
            continue
        used.append(stamp_of(d))
        one = analyze(ev, stamp_of(d))
        z = one if z is None else merge(z, one)
    if z is None:
        print("no events.jsonl with actions in: " + ", ".join(stamp_of(d) for d in dirs))
        return 0
    top = args.top
    skipped = len(dirs) - len(used)
    print("report over %d trace(s): %s%s" % (len(used), ", ".join(used[-5:]) + (" ..." if len(used) > 5 else ""),
                                           "  (%d skipped: no actions in events.jsonl)" % skipped if skipped else ""))

    section("(a) Button usage (presses by combo; auto-repeats skipped)")
    total = sum(z["combo"].values())
    table([[c, n, "%.0f%%" % (100.0 * n / total)] for c, n in z["combo"].most_common(top)], ["combo", "presses", "share"])
    print("  total %d presses, %d auto-repeats skipped" % (total, z["reps"]))
    print("  triggers as modifier: " + (", ".join("%s %d" % kv for kv in sorted(z["trig_mod"].items())) or "none")
          + "   (trigger pulls: " + (", ".join("%s %d" % kv for kv in sorted(z["trig_pull"].items())) or "none") + ")")
    if z["typed"]:
        print("  typed characters: " + ", ".join("%s %d" % kv for kv in z["typed"].most_common()))
    if z["other"]:
        print("  other keys: " + ", ".join("%s %d" % kv for kv in z["other"].most_common(top)))
    print("  by screen:")
    for scr, c in sorted(z["by_scr"].items(), key=lambda kv: -sum(kv[1].values())):
        print("    %-14s %4d  %s" % (scr, sum(c.values()), "  ".join("%s %d" % kv for kv in c.most_common(8))))

    section("(b) What the presses meant (ranked)")
    table([[scr, act, n] for (scr, act), n in z["actions"].most_common(top)], ["screen", "action", "count"])

    section("(c) Menu picks")
    if not z["picks"] and not z["submenus"]:
        print("  none")
    else:
        rows = []
        for path, n in z["picks"].most_common(top):
            idx, size, sel = z["pos"].get(path, (0, 0, ""))
            avg = z["cost"][path] / n
            rows.append([n, "%.1f" % avg, "%.0f" % (n * avg), "%s/%s" % (idx, size), path])
        head = ["count", "avg cost", "count*cost", "idx/n", "path"]
        if rows:
            print("  final picks by count (cost = presses inside the menus to get there):")
            table(rows, head, "    ")
            rows.sort(key=lambda r: -float(r[2]))
            print("  frequent and expensive (count x avg cost):")
            table(rows[:top], head, "    ")
        else:
            print("  no final picks")
        if z["submenus"]:
            print("  submenus opened: " + ", ".join("%s (%d)" % kv for kv in z["submenus"].most_common(top)))

    section("(d) Time per screen")
    tt = sum(z["time"].values()) or 1
    table([[s, "%.1fs" % v, "%.0f%%" % (100 * v / tt)] for s, v in z["time"].most_common()], ["screen", "time", "share"])

    section("(e) Mistake signals (replay: %s --replay <stamp> --until <frame>)" % EXE_SHOWN)
    if not z["mistakes"]:
        print("  none")
    for kind, items in sorted(z["mistakes"].items(), key=lambda kv: -len(kv[1])):
        print("  %s: %d" % (kind, len(items)))
        for st, f, note in items[:top]:
            print("    %s f%-6s %s" % (st, f, note))
        if len(items) > top:
            print("    ... %d more" % (len(items) - top))

    section("(f) Suggestions")
    for s in suggestions(z) or ["nothing stands out yet; record more sessions"]:
        print("  - " + s)
    return 0


def suggestions(z):
    out = []
    ranked = sorted(z["picks"], key=lambda p: -z["cost"][p])
    for path in ranked[:2]:
        n = z["picks"][path]
        avg = z["cost"][path] / n
        if avg >= 3 or n >= 3:
            label = path.rsplit(" > ", 1)[-1]
            first = "your most used" if path == ranked[0] else "also a frequent"
            out.append("`%s` is %s final menu pick (%d times, avg %.1f presses, item %s/%s of its menu) "
                       "- consider a button, pinning it, or the recent section"
                       % (label, first, n, avg, z["pos"][path][0], z["pos"][path][1]))
    for combo, n in z["combo"].most_common():
        if "+" in combo and n >= 3:
            scr = max(z["by_scr"], key=lambda s: z["by_scr"][s][combo])
            act = binding({"scr": scr}, combo)[2]
            out.append("%s%s used %d times - it's on a trigger combo; if it's a core action consider "
                       "a single-button binding or swapping it with a rarely used one"
                       % (combo, " (" + scr + ": " + act + ")" if act else "", n))
            break
    if z["backout_menus"]:
        m, n = z["backout_menus"].most_common(1)[0]
        out.append("menu `%s` was backed out of without a pick %d time(s) - check its labels / order" % (m, n))
    osc = len(z["mistakes"].get("d-pad oscillation", []))
    if osc >= 2:
        out.append("d-pad oscillation %d times - overshooting in lists; consider wrap-around, paging or "
                   "putting frequent items first" % osc)
    uses = {k: z["bound"][("editor", k)] for k in BINDINGS["editor"]}
    never = [k for k in uses if not uses[k]]
    if never:
        out.append("never used: " + ", ".join("%s (%s)" % (k, BINDINGS["editor"][k]) for k in never)
                   + " - %d of %d editor bindings; candidates to rebind" % (len(never), len(uses)))
    rare = sorted((k for k in uses if uses[k]), key=lambda k: uses[k])[:4]
    if rare and len(rare) < len(uses) - len(never):
        out.append("least-used editor bindings: " + ", ".join(
            "%s (%s, %d)" % (k, BINDINGS["editor"][k], uses[k]) for k in rare))
    return out


# ---------------------------------------------------------------- find / show

def states(events):
    """(record, state before, its list items, state after, its list items) for
    every record. Items are None when no list is visible."""
    list_at = {}
    for r in events:
        if r["k"] == "list":
            list_at[r.get("f")] = r
    cur_list, last, last_items = None, {}, None
    for r in events:
        k = r["k"]
        if k == "act":
            post = r["post"]
            lr = list_at.get(r.get("f"))
            if lr is None or not same_screen(lr, post):
                lr = cur_list if cur_list is not None and same_screen(cur_list, post) else None
            items = lr.get("items") if lr is not None else None
            yield r, last, last_items, post, items
            last, last_items = post, items
        elif k == "list":
            cur_list = r
            s = dict(last)
            items = r.get("items") or []
            idx = r.get("idx", 0)
            s.update(scr=r.get("scr", ""), title=r.get("title", ""), trail=r.get("trail") or [],
                     idx=idx, n=len(items), sel=items[idx] if isinstance(idx, int) and 0 <= idx < len(items) else "")
            yield r, s, items, s, items
            last, last_items = s, items
        else:
            yield r, last, last_items, last, last_items


def same_screen(lr, s):
    return (lr.get("scr") == s.get("scr") and lr.get("title") == s.get("title")
            and list(lr.get("trail") or []) == list(s.get("trail") or []))


def has(hay, needle):
    return needle.lower() in str(hay).lower()


def matches(args, r, s, items):
    if args.menu_all_prefix is not None:
        labels = [str(x) for x in (items or []) if str(x).strip()]
        p = args.menu_all_prefix.lower()
        if not labels or not all(x.strip().lower().startswith(p) for x in labels):
            return False
    if args.menu_title is not None and not has(s.get("title", ""), args.menu_title):
        return False
    if args.item is not None and not any(has(x, args.item) for x in (items or [])):
        return False
    if args.scr is not None and s.get("scr") != args.scr:
        return False
    if args.sel is not None and not has(s.get("sel", ""), args.sel):
        return False
    if args.mode is not None and not has(s.get("mode", ""), args.mode):
        return False
    if args.leaf is not None and not has(s.get("leaf", ""), args.leaf):
        return False
    if args.press is not None:
        if r["k"] != "act" or args.press.lower() not in [c.lower() for c, _, _ in press_info(r)["buttons"]]:
            return False
    if args.text is not None:
        if r["k"] != "mark" or r.get("what") not in ("stt", "project_name") or not has(r.get("text", ""), args.text):
            return False
    if args.expr is not None:
        try:
            if not eval(args.expr, {"__builtins__": builtins}, {"r": r, "s": s}):
                return False
        except Exception:
            return False
    return True


def cmd_find(args):
    dirs = resolve(args.trace, args.traces, allow_all=True)
    shown = 0
    for d in dirs:
        use_layout(d)
        ev = load_events(d)
        if not ev:
            continue
        st, target = stamp_of(d), replay_target(d)
        group = None   # consecutive matching records -> one line
        hits = []
        for r, pre, pre_items, post, post_items in states(ev):
            if r["k"] == "meta":
                continue
            # A press happened on the screen before it; anything else is judged
            # by the screen after the record.
            on_pre = r["k"] == "act" and args.press is not None
            s, items = (pre, pre_items) if on_pre else (post, post_items)
            if matches(args, r, s, items):
                if group is not None:
                    group[4] = r.get("f")
                    group[5] += 1
                else:
                    group = [r, s, items, on_pre, r.get("f"), 0]
                    hits.append(group)
            else:
                group = None
        for r, s, items, on_pre, last_f, more in hits:
            if shown >= args.limit:
                print("... (--limit %d reached)" % args.limit)
                return 0
            shown += 1
            f = r.get("f", 0)
            what = r["k"] + (":" + str(r.get("what")) if r["k"] == "mark" else "")
            trail = " > ".join(clean(x) for x in s.get("trail") or [])
            print("%s f%-6s %7.2fs  %-6s scr=%s title=%r trail=[%s] sel=%r" % (
                st, f, r.get("t", 0) or 0, what, s.get("scr", ""), clean(s.get("title", "")), trail, clean(s.get("sel", ""))))
            if r["k"] == "act":
                print("      " + describe(r))
            if items is not None and (r["k"] == "list" or args.menu_all_prefix or args.item):
                print("      items(%d): %s" % (len(items), ", ".join(clean(x) for x in items[:12]) + (" ..." if len(items) > 12 else "")))
            if r["k"] == "mark":
                print("      text: %r" % r.get("text", ""))
            if more:
                print("      (+%d more matching records through f%s)" % (more, last_f))
            if on_pre:
                print("      %s --replay %s --until %s   (just before the press; F7 steps into it)" % (EXE_SHOWN, target, f - 1))
            else:
                print("      %s --replay %s --until %s" % (EXE_SHOWN, target, f))
            if args.first:
                return 0
    if shown == 0:
        print("no matches")
    return 0


def describe(a):
    """`combos  -> meaning` for one act."""
    pre, post = a["pre"], a["post"]
    pi = press_info(a)
    parts, out = [], []
    for combo, name, mods in pi["buttons"]:
        parts.append(combo)
        act = action(pre, combo)
        is_pick = pre.get("scr") in ("menu", "main_menu") and combo == "A"
        if is_pick:
            deeper = post.get("scr") == "menu" and len(post.get("trail") or []) > len(pre.get("trail") or [])
            out.append('pick "%s" (%s)' % (clean(pre.get("sel", "")), "opens submenu" if deeper else "final"))
        else:
            out.append(act)
    if pi["typed"]:
        parts.append("type " + "".join(pi["typed"]))
        out.append("text %r -> %r" % (pre.get("title", ""), post.get("title", "")))
    parts += pi["triggers"] + pi["other"] + pi["releases"]
    if pi["reps"]:
        parts.append("(+%d rep)" % pi["reps"])
    res = []
    if post.get("scr") != pre.get("scr") or (post.get("scr") == "menu" and where(post) != where(pre)):
        res.append("now " + where(post))
    elif post.get("sel") != pre.get("sel") and post.get("sel"):
        res.append('"%s"' % clean(post["sel"]))
    if a.get("edit"):
        res.append("edit, %s lines" % post.get("nodes", "?"))
    if post.get("scr") == "editor" and post.get("line") != pre.get("line"):
        res.append("line %s" % post.get("line"))
    text = " ".join(parts) or "(state change)"
    if out:
        text += "  -> " + "; ".join(out)
    if res:
        text += "  [" + ", ".join(res) + "]"
    return text


def cmd_show(args):
    d = resolve(args.trace, args.traces)[0]
    use_layout(d)
    ev = load_events(d)
    if not ev:
        print("%s: no events.jsonl" % stamp_of(d))
        return 0
    lines = []   # (f, text, is_act)
    for r in ev:
        f, t = r.get("f", 0), r.get("t", 0) or 0
        if r["k"] == "act":
            lines.append((f, "f%-6s %7.2fs  [%s]  %s" % (f, t, where(r["pre"]), describe(r)), True))
        elif r["k"] == "list":
            items = r.get("items") or []
            lines.append((f, "%s list %s (%d%s): %s%s" % (" " * 17, where(r), len(items),
                          ", %d recent" % r["recent"] if r.get("recent") else "",
                          ", ".join(clean(x) for x in items[:12]), " ..." if len(items) > 12 else ""), False))
        elif r["k"] == "mark":
            lines.append((f, "f%-6s %7.2fs  * %s %r" % (f, t, r.get("what"), r.get("text", "")), False))
    if not lines:
        print("no records")
        return 0
    lo, hi = args.from_, args.to
    mark = None
    if args.around is not None:
        mark = min(range(len(lines)), key=lambda i: (abs(lines[i][0] - args.around), not lines[i][2]))
        act_idx = [i for i, l in enumerate(lines) if l[2]]
        pos = min(range(len(act_idx)), key=lambda j: abs(act_idx[j] - mark)) if act_idx else 0
        lo_i = act_idx[max(0, pos - args.context)] if act_idx else 0
        hi_i = act_idx[min(len(act_idx) - 1, pos + args.context)] if act_idx else len(lines) - 1
        while hi_i + 1 < len(lines) and not lines[hi_i + 1][2]:
            hi_i += 1
        sel = range(lo_i, hi_i + 1)
    else:
        sel = [i for i, l in enumerate(lines) if (lo is None or l[0] >= lo) and (hi is None or l[0] <= hi)]
    meta = meta_of(ev)
    print("%s%s" % (stamp_of(d), "  (derived from %s @%s)" % (meta["derived_from"], meta.get("derived_until"))
                    if meta.get("derived_from") else ""))
    for i in sel:
        print((">> " if i == mark else "   ") + lines[i][1])
    return 0


# ---------------------------------------------------------------- verify / replay

RESULT_RE = re.compile(r"trace: RESULT (\S+) frames=(\d+) reached=(\d+)")


def cmd_verify(args):
    dirs = [d for d in resolve(args.trace, args.traces, allow_all=True)
            if os.path.exists(os.path.join(d, "input.log"))]
    if not dirs:
        print("no recordings with input.log")
        return 0
    if not os.path.exists(args.exe):
        sys.exit("trace.py: no exe at %s (build.bat first)" % args.exe)
    print("replaying %d recording(s); each briefly opens a Doodle window" % len(dirs), flush=True)
    rows, bad = [], 0
    for d in reversed(dirs):
        t0 = time.time()
        try:
            p = subprocess.run([args.exe, "--replay", os.path.abspath(d), "--exit-at-end"], cwd=REPO,
                               capture_output=True, text=True, errors="replace", timeout=args.timeout)
            m = RESULT_RE.search(p.stderr or "")
            if m:
                res, frames, reached = m.group(1), m.group(2), m.group(3)
            else:
                tail = (p.stderr or "").strip().splitlines()[-1:] or ["no RESULT line"]
                res, frames, reached = "failed (exit %s: %s)" % (p.returncode, tail[0][:60]), "-", "-"
        except subprocess.TimeoutExpired:
            res, frames, reached = "failed (timeout %ss)" % args.timeout, "-", "-"
        except OSError as e:
            res, frames, reached = "failed (%s)" % e, "-", "-"
        if res != "matched":
            bad += 1
        rows.append([stamp_of(d), res, frames, reached, "%.1fs" % (time.time() - t0)])
    table(rows, ["stamp", "result", "frames", "reached", "time"])
    print("%d ok, %d not ok" % (len(rows) - bad, bad))
    return 1 if bad else 0


def cmd_replay(args):
    d = resolve(args.trace, args.traces)[0]
    extra = []
    if args.until is not None:
        extra += ["--until", str(args.until)]
    if args.speed is not None:
        extra += ["--speed", "%g" % args.speed]
    if args.takeover:
        extra.append("--takeover")
    if args.exact:
        extra.append("--exact")
    if args.exit_at_end:
        extra.append("--exit-at-end")
    print(" ".join([EXE_SHOWN if args.exe == EXE else args.exe, "--replay", replay_target(d)] + extra), flush=True)
    if not os.path.exists(args.exe):
        sys.exit("trace.py: no exe at %s (build.bat first)" % args.exe)
    return subprocess.call([args.exe, "--replay", os.path.abspath(d)] + extra, cwd=REPO)


# ---------------------------------------------------------------- script

PAD_BUTTONS = ("A", "B", "X", "Y", "Up", "Down", "Left", "Right", "LB", "RB", "Start", "Back")
SDL_KEYS = {"Return": 13, "Escape": 27, "Backspace": 8, "Space": 32, "Tab": 9,
            "Up": 0x40000052, "Down": 0x40000051, "Left": 0x40000050, "Right": 0x4000004F}


def script_lines(tokens):
    """input.log frame lines for a script of gamepad presses (see cmd_script)."""
    out, f = [], 10

    def frame(*recs):
        nonlocal f
        out.append("%d t %.4f" % (f, f / 60.0))
        out.extend("%d %s" % (f, r) for r in recs)
        f += 1

    for tok in tokens:
        if tok.startswith("wait:"):
            f += int(tok[5:])
            continue
        if tok.startswith("text:"):  # keyboard typing (save / rename dialog)
            for ch in tok[5:]:
                k = 32 if ch == " " else ord(ch.lower())
                frame("key %d 1" % k)
                frame("key %d 0" % k)
                f += 2
            continue
        if tok.startswith("key:"):
            name = tok[4:]
            k = SDL_KEYS.get(name, ord(name[0]) if len(name) == 1 else None)
            if k is None:
                sys.exit("trace.py: unknown key " + name)
            frame("key %d 1" % k)
            frame("key %d 0" % k)
            f += 3
            continue
        hold = tok.startswith("hold:")  # hold:LT+X:30 = hold for 30 frames (talk)
        body = tok[5:] if hold else tok
        frames_held = 1
        if hold and body.count(":"):
            body, n = body.rsplit(":", 1)
            frames_held = int(n)
        parts = body.split("+")
        trig, btn = parts[:-1], parts[-1]
        axes = {"LT": "LTrigger", "RT": "RTrigger"}
        if btn in axes:  # a bare trigger pull
            trig, btn = trig + [btn], None
        if btn is not None and btn not in PAD_BUTTONS:
            sys.exit("trace.py: unknown button %r in %r (use %s, LT+X, text:..., key:..., wait:N)"
                     % (btn, tok, " ".join(PAD_BUTTONS)))
        for t in trig:
            if t not in axes:
                sys.exit("trace.py: unknown trigger %r in %r" % (t, tok))
        if trig:
            frame(*("axis %s 1.0000" % axes[t] for t in trig))
            f += 1
        if btn:
            frame("btn %s 1" % btn)
            f += frames_held - 1
            frame("btn %s 0" % btn)
        else:
            f += frames_held
        if trig:
            frame(*("axis %s 0.0000" % axes[t] for t in trig))
        f += 4
    return out


def cmd_script(args):
    """Write a replayable fixture from a script of presses; optionally run it."""
    import shutil
    name = re.sub(r"[^A-Za-z0-9_.-]", "-", args.name)
    d = os.path.join(args.traces, "script-" + name)
    if os.path.isdir(d):
        shutil.rmtree(d)
    projects = os.path.join(d, "snapshot", "projects")
    if args.projects:
        shutil.copytree(args.projects, projects, ignore=shutil.ignore_patterns(".git", "bin", "*.exe"))
    else:
        os.makedirs(projects)
    tokens = []
    for t in args.steps:
        tokens += t.split()
    lines = ["doodle-trace 1", "meta start_unix %d" % int(time.time()),
             "meta projects " + os.path.abspath(args.projects or projects).replace(" ", "\\s"),
             "meta start_file " + (os.path.join(projects, args.open).replace(" ", "\\s") if args.open else ""),
             "meta start_rel " + (args.open.replace("\\", "/").replace(" ", "\\s") if args.open else ""),
             "meta stt 0", "meta snapshot_ok 1", "meta roots", "0 t 0", "0 size %d %d" % tuple(args.size)]
    lines += script_lines(tokens)
    with open(os.path.join(d, "input.log"), "w", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote " + d)
    if not args.run and not args.shot:
        print("replay: %s --replay script-%s" % (EXE_SHOWN, name))
        return 0
    cmd = [args.exe, "--replay", d, "--exit-at-end"]
    if args.shot:
        cmd += ["--screenshot", os.path.abspath(args.shot)]
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=args.timeout)
    for line in r.stderr.splitlines():
        if line.startswith("trace:"):
            print(line)
    return 0


# ---------------------------------------------------------------- main

def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--traces", default=argparse.SUPPRESS, help="traces folder (default: <repo>/bin/traces)")
    ap = argparse.ArgumentParser(description="Doodle trace analysis (see docs/TRACE.md).")
    ap.add_argument("--traces", default=TRACES_DIR, help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", parents=[common], help="recent recordings")
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("report", parents=[common], help="button / menu / mistake analytics")
    p.add_argument("trace")
    p.add_argument("--top", type=int, default=15)
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("find", parents=[common], help="search records; prints replay commands")
    p.add_argument("trace")
    for name in ("menu-all-prefix", "menu-title", "item", "scr", "sel", "press", "mode", "leaf", "text", "expr"):
        p.add_argument("--" + name)
    p.add_argument("--first", action="store_true", help="stop at the first match")
    p.add_argument("--limit", type=int, default=50)
    p.set_defaults(fn=cmd_find)

    p = sub.add_parser("show", parents=[common], help="human-readable timeline")
    p.add_argument("trace")
    p.add_argument("--around", type=int)
    p.add_argument("--from", dest="from_", type=int)
    p.add_argument("--to", type=int)
    p.add_argument("--context", type=int, default=10, help="acts each side of --around")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("verify", parents=[common], help="replay and check fingerprints")
    p.add_argument("trace")
    p.add_argument("--exe", default=EXE)
    p.add_argument("--timeout", type=float, default=120)
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("replay", parents=[common], help="launch a replay")
    p.add_argument("trace")
    p.add_argument("--until", type=int)
    p.add_argument("--speed", type=float)
    p.add_argument("--takeover", action="store_true")
    p.add_argument("--exact", action="store_true")
    p.add_argument("--exit-at-end", action="store_true")
    p.add_argument("--exe", default=EXE)
    p.set_defaults(fn=cmd_replay)

    p = sub.add_parser("script", parents=[common], help="make a replayable fixture from a script of presses")
    p.add_argument("name", help="fixture name: written to <traces>/script-<name>")
    p.add_argument("steps", nargs="+", help="presses, e.g. A Down RT+B LT+Y text:hello key:Return wait:30 hold:LT+X:40")
    p.add_argument("--projects", help="folder to use as the projects folder (copied into the snapshot)")
    p.add_argument("--open", help="file to open at startup, relative to --projects")
    p.add_argument("--size", type=int, nargs=2, default=[1280, 800], metavar=("W", "H"))
    p.add_argument("--run", action="store_true", help="replay it now (exits at the end)")
    p.add_argument("--shot", help="replay it now and save a PNG of the final screen here")
    p.add_argument("--exe", default=EXE)
    p.add_argument("--timeout", type=float, default=120)
    p.set_defaults(fn=cmd_script)

    args = ap.parse_args()
    args.traces = os.path.abspath(args.traces)
    sys.exit(args.fn(args) or 0)


if __name__ == "__main__":
    main()

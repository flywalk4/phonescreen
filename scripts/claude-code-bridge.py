#!/usr/bin/env python3
"""Optional bridge from Claude Code to the Qwovi "Claude Code" widget.

The widget works without it (it reads Claude Code's session logs: activity and token counts). The bridge adds
the official plan limits in % with reset times, and exact working / waiting state from hooks.

    python3 scripts/claude-code-bridge.py install     # hook into ~/.claude/settings.json (backup first)
    python3 scripts/claude-code-bridge.py status      # what the widget currently sees
    python3 scripts/claude-code-bridge.py uninstall   # remove everything this script added

What it adds (and nothing else):
  * a status line wrapper: Claude Code gives status line commands `rate_limits.five_hour` / `seven_day`
    (used_percentage, resets_at — Pro/Max plans, after the first reply in a session). The wrapper saves that to
    ~/.claude/qwovi/status.json, then runs your previous status line command with the same input, so
    your status line looks exactly as before;
  * hooks that record whether Claude is working, waiting for you, or idle, per session, in
    ~/.claude/qwovi/state.json (next to your existing hooks, not instead of them).
The widget reads those two files when present (read-only, like the session logs).
"""
import json
import os
import shutil
import sys
import time

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, ".claude", "qwovi")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
MARK = "/.claude/qwovi/"
PREVIOUS = os.path.join(DIR, "previous-statusline.json")

HOOKS = {
    # event: state it means
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Notification": "waiting",
    "PermissionRequest": "waiting",
    "Stop": "idle",
    "SessionEnd": "ended",
}
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PermissionRequest"}

STATUSLINE = r'''#!/usr/bin/env python3
# Qwovi: saves Claude Code's rate limits for the widget, then shows your previous status line.
import json, os, subprocess, sys, time
D = os.path.expanduser("~/.claude/qwovi")
raw = sys.stdin.read()
try:
    data = json.loads(raw)
    path = os.path.join(D, "status.json")
    try:
        old = json.load(open(path))
    except Exception:
        old = {}
    limits = data.get("rate_limits") or old.get("rate_limits")  # only present after the first reply
    snap = {
        "at": time.time(),
        "session_id": data.get("session_id"),
        "model": (data.get("model") or {}).get("display_name"),
        "rate_limits": limits,
        "limits_at": time.time() if data.get("rate_limits") else old.get("limits_at"),
    }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f)
    os.replace(tmp, path)
except Exception:
    pass
try:
    previous = json.load(open(os.path.join(D, "previous-statusline.json"))).get("command")
except Exception:
    previous = None
if previous:
    try:
        out = subprocess.run(previous, shell=True, input=raw, capture_output=True, text=True, timeout=5).stdout
        sys.stdout.write(out)
    except Exception:
        pass
else:
    try:
        rl = (json.loads(raw).get("rate_limits") or {})
        parts = [f"{k}: {int(v.get('used_percentage', 0))}%" for k, v in (("5h", rl.get("five_hour") or {}), ("week", rl.get("seven_day") or {})) if v]
        print(" · ".join(parts))
    except Exception:
        print("")
'''

STATE = r'''#!/usr/bin/env python3
# Qwovi: records whether Claude Code is working / waiting / idle, per session.
import json, os, sys, time
D = os.path.expanduser("~/.claude/qwovi")
state = sys.argv[1] if len(sys.argv) > 1 else "idle"
try:
    event = json.loads(sys.stdin.read() or "{}")
except Exception:
    event = {}
path = os.path.join(D, "state.json")
try:
    data = json.load(open(path))
except Exception:
    data = {}
sessions = data.get("sessions", {})
sid = event.get("session_id") or "default"
now = time.time()
if state == "ended":
    sessions.pop(sid, None)
else:
    sessions[sid] = {"state": state, "at": now, "cwd": event.get("cwd")}
sessions = {k: v for k, v in sessions.items() if now - v.get("at", 0) < 86400}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"sessions": sessions, "at": now}, f)
os.replace(tmp, path)
'''


def load_settings():
    try:
        with open(SETTINGS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_settings(s):
    tmp = SETTINGS + ".qwovi.tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)


def ours(command) -> bool:
    return isinstance(command, str) and MARK in command


def install():
    os.makedirs(DIR, exist_ok=True)
    for name, body in (("statusline.py", STATUSLINE), ("state.py", STATE)):
        p = os.path.join(DIR, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)

    s = load_settings()
    if os.path.exists(SETTINGS):
        backup = os.path.join(DIR, f"settings.backup-{time.strftime('%Y%m%d-%H%M%S')}.json")
        shutil.copy2(SETTINGS, backup)
        print(f"backup: {backup}")

    wrapper = f'python3 "{os.path.join(DIR, "statusline.py")}"'
    current = s.get("statusLine")
    if current and not ours(current.get("command")):
        with open(PREVIOUS, "w") as f:
            json.dump(current, f)
        print(f"your status line is kept and will show as before: {current.get('command')}")
    s["statusLine"] = {**(current if current and not ours(current.get('command')) else {}), "type": "command", "command": wrapper}

    hooks = s.setdefault("hooks", {})
    for event, state in HOOKS.items():
        entries = hooks.setdefault(event, [])
        if any(ours(h.get("command")) for e in entries for h in e.get("hooks", [])):
            continue
        entry = {"hooks": [{"type": "command", "command": f'python3 -S "{os.path.join(DIR, "state.py")}" {state}', "timeout": 5}]}
        if event in TOOL_EVENTS:
            entry["matcher"] = "*"
        entries.append(entry)
    save_settings(s)
    print("done: the bridge is installed. Limits appear after Claude's first reply in a session (Pro/Max plans).")


def uninstall():
    s = load_settings()
    if ours((s.get("statusLine") or {}).get("command")):
        try:
            with open(PREVIOUS) as f:
                s["statusLine"] = json.load(f)
            print("the status line is back as it was")
        except FileNotFoundError:
            s.pop("statusLine", None)
    hooks = s.get("hooks", {})
    for event in list(hooks):
        kept = []
        for entry in hooks[event]:
            entry["hooks"] = [h for h in entry.get("hooks", []) if not ours(h.get("command"))]
            if entry["hooks"]:
                kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        s.pop("hooks", None)
    save_settings(s)
    print("the bridge is removed from ~/.claude/settings.json (files in ~/.claude/qwovi/ can be deleted by hand)")


def status():
    s = load_settings()
    print("status line:", "bridge" if ours((s.get("statusLine") or {}).get("command")) else "not connected")
    print("hooks:", ", ".join(e for e, en in s.get("hooks", {}).items() if any(ours(h.get("command")) for x in en for h in x.get("hooks", []))) or "none")
    for name in ("status.json", "state.json"):
        p = os.path.join(DIR, name)
        if os.path.exists(p):
            age = time.time() - os.path.getmtime(p)
            print(f"{name}: updated {int(age)} s ago")
            print("  ", open(p).read()[:400])
        else:
            print(f"{name}: missing")


if __name__ == "__main__":
    {"install": install, "uninstall": uninstall, "status": status}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()

#!/usr/bin/env python3
"""dino.dock - window action helper (called by Dock.qml via Quickshell.execDetached).

Hyprland 0.56 routes every IPC `dispatch` through its Lua evaluator. All
window-targeted actions use the DOCUMENTED Lua dispatch API with exact
window selectors (https://wiki.hypr.land/Configuring/Basics/Dispatchers/):
  hl.dsp.focus({ window = "address:0x..." })                            -> focus
  hl.dsp.window.move({ window = "address:0x...", workspace = "special:scratchpad" })  -> minimize
  hl.dsp.window.fullscreen({ window = "address:0x...", mode = 0, layout_aware = true }) -> maximize (bar-respecting)
  hl.dsp.window.fullscreen({ window = "address:0x...", mode = 1, layout_aware = true }) -> real fullscreen
  hl.dsp.window.alter_zorder({ window = "address:0x...", mode = "top" }) -> raise above floats

The socket's `dispatch` command wraps the expression in hl.dispatch() itself,
so the Lua sent here must NOT include an outer hl.dispatch() call.

Usage: dock_helper.py <action> <pids-csv> <class>
  actions: minimize | restore | togglemax
Matching: a window matches if its pid is in <pids-csv>, or its class equals
<class> (case-insensitive); falls back to substring match on class.
Exit codes: 0 ok, 2 bad args, 3 no matching window, 4 ipc failed.
"""
import json
import os
import socket
import subprocess
import sys


def _sock_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    his = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    base = os.path.join(runtime, "hypr")
    candidates = []
    if his:
        candidates.append(os.path.join(base, his, ".socket.sock"))
    try:
        for name in sorted(os.listdir(base)):
            if not name.startswith("."):
                candidates.append(os.path.join(base, name, ".socket.sock"))
    except OSError:
        pass
    for p in candidates:
        if os.path.exists(p):
            return p
    raise FileNotFoundError("hyprland ipc socket not found")


def ipc(lua):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(4)
    s.connect(_sock_path())
    s.sendall(("dispatch " + lua + "\n").encode())
    try:
        out = s.recv(8192).decode(errors="replace").strip()
    except socket.timeout:
        out = "timeout"
    s.close()
    return out


def hypr_clients():
    out = subprocess.run(["hyprctl", "-j", "clients"],
                         capture_output=True, text=True, timeout=6).stdout
    try:
        return json.loads(out or "[]")
    except ValueError:
        return []


def active_ws_id():
    try:
        out = subprocess.run(["hyprctl", "-j", "activeworkspace"],
                             capture_output=True, text=True, timeout=6).stdout
        return int(json.loads(out or "{}").get("id", -1))
    except Exception:
        return -1


def sel(addr):
    # exact window selector per the Dispatchers docs; hyprctl addresses are
    # plain "0x..." hex strings.
    return "address:" + str(addr)


def lua_minimize(addr):
    return ("hl.dsp.window.move({ window = \"" + sel(addr) +
            "\", workspace = \"special:scratchpad\" })")


def lua_focus(addr):
    return "hl.dsp.focus({ window = \"" + sel(addr) + "\" })"


def lua_restore(addr, ws):
    return ("hl.dsp.window.move({ window = \"" + sel(addr) +
            "\", workspace = \"" + str(ws) + "\", follow = false })")


def lua_fullscreen(addr, mode):
    return ("hl.dsp.window.fullscreen({ window = \"" + sel(addr) +
            "\", mode = " + str(mode) + ", layout_aware = true })")


def lua_raisetop(addr):
    return ("hl.dsp.window.alter_zorder({ window = \"" + sel(addr) +
            "\", mode = \"top\" })")


def main():
    args = sys.argv[1:]
    if len(args) < 1:
        print("usage: dock_helper.py <minimize|restore|togglemax|geometry> <pids-csv> <class>")
        return 2
    action = args[0]

    if action == "geometry":
        # {"activeWorkspace": id, "clients": [...]} — the dock picks the hovered
        # app's visible window (on the active workspace) and grabs it with a
        # region screenshot for the hover preview card.
        try:
            act = subprocess.run(["hyprctl", "-j", "activeworkspace"],
                                 capture_output=True, text=True, timeout=5)
            active_ws = json.loads(act.stdout or "{}").get("id", -1)
        except Exception:
            active_ws = -1
        out = []
        for c in hypr_clients():
            ws = c.get("workspace") or {}
            out.append({
                "class": c.get("class", ""),
                "pid": c.get("pid", 0),
                "address": c.get("address", ""),
                "at": c.get("at", [0, 0]),
                "size": c.get("size", [0, 0]),
                "mapped": bool(c.get("mapped", True)),
                "hidden": bool(c.get("hidden", False)),
                "floating": bool(c.get("floating", False)),
                "workspace": ws.get("id", -1),
            })
        print(json.dumps({"activeWorkspace": active_ws, "clients": out}))
        return 0

    pidset = set()
    for p in (args[1] if len(args) > 1 else "").split(","):
        p = p.strip()
        if p.isdigit():
            pidset.add(int(p))
    cls = (args[2] if len(args) > 2 else "").strip().lower()

    matched = []
    for c in hypr_clients():
        if c.get("class") in ("", None):
            continue
        if not c.get("mapped", True):
            continue
        if c.get("pid") in pidset:
            matched.append(c)
        elif cls and (c.get("class", "").lower() == cls or
                      (len(cls) > 3 and cls in c.get("class", "").lower())):
            matched.append(c)
    if not matched:
        print("nomatch")
        return 3

    def report(tag, r):
        print(f"{tag}: {r}")
        return 0 if r.startswith("ok") else 4

    if action == "minimize":
        rc = 0
        for c in matched:
            r = ipc(lua_minimize(c["address"]))
            print(f"minimize {c['address'][-4:]}: {r}")
            if not r.startswith("ok"):
                rc = 4
        return rc

    # restore / togglemax operate on the most recently focused matching window
    target = min(matched, key=lambda c: c.get("focusHistoryID", 1 << 30))
    addr = target["address"]

    if action == "restore":
        # bring the window back onto the workspace the user is actually on:
        # move it out of the scratchpad first, then focus it. NOTE: do NOT
        # alter_zorder after focusing — that dispatcher STEALS focus
        # (verified live); focusing a tiled window already raises it.
        ws = active_ws_id()
        if ws is not None and ws >= 0:
            r1 = ipc(lua_restore(addr, ws))
        else:
            r1 = "ok(no-ws)"
        r2 = ipc(lua_focus(addr))
        return report("restore", r2 if r2.startswith("ok") else r1)

    if action == "togglemax":
        fs = int(target.get("fullscreen") or 0)
        wsname = str((target.get("workspace") or {}).get("name") or "")
        on_special = wsname.startswith("special:")
        if on_special:
            report("reveal", ipc(lua_focus(addr)))
            r = ipc(lua_fullscreen(addr, 0))
        elif fs == 2:
            r = ipc(lua_fullscreen(addr, 0))
        elif fs == 1:
            r = ipc(lua_fullscreen(addr, 1))
        else:
            r = ipc(lua_fullscreen(addr, 0))
        print(f"togglemax {addr[-4:]} (fs was {fs}): {r}")
        return 0 if r.startswith("ok") else 4

    print(f"unknown action: {action}")
    return 2


if __name__ == "__main__":
    sys.exit(main())

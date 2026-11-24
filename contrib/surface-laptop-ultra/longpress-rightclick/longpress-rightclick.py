#!/usr/bin/env python3
"""Long-press left button -> right click.

Grabs every touchpad/mouse that has BTN_LEFT, re-emits its events through a
uinput clone, and holds back each left press. Outcomes:
  - released before HOLD_MS          -> normal left click
  - pointer moves more than the slop -> normal left press (drag/select works)
  - held still for HOLD_MS           -> right click; the left press never reaches apps
Multi-finger clickpad presses pass straight through (libinput's clickfinger).

Env: LPRC_HOLD_MS (default 600), LPRC_SLOP_MM (touchpad, default 2.0),
     LPRC_SLOP_COUNTS (mouse, default 10).
"""
from contextlib import closing
import glob
import os
import selectors
import time

import evdev
from evdev import UInput, ecodes as e

HOLD = int(os.environ.get("LPRC_HOLD_MS", "600")) / 1000
SLOP_MM = float(os.environ.get("LPRC_SLOP_MM", "2.0"))
SLOP_COUNTS = int(os.environ.get("LPRC_SLOP_COUNTS", "10"))
PHYS = "longpress-rightclick"
MULTI_TOOLS = (e.BTN_TOOL_DOUBLETAP, e.BTN_TOOL_TRIPLETAP, e.BTN_TOOL_QUADTAP, e.BTN_TOOL_QUINTTAP)


def wanted(dev):
    if dev.phys == PHYS:
        return False
    caps = dev.capabilities()
    keys = caps.get(e.EV_KEY, [])
    if e.BTN_LEFT not in keys or e.BTN_TOOL_PEN in keys or e.BTN_STYLUS in keys:
        return False
    absc = [a[0] if isinstance(a, tuple) else a for a in caps.get(e.EV_ABS, [])]
    return e.ABS_MT_POSITION_X in absc or e.REL_X in caps.get(e.EV_REL, [])


class Dev:
    def __init__(self, path):
        self.src = evdev.InputDevice(path)
        i = self.src.info
        self.ui = UInput.from_device(
            self.src, name=self.src.name, vendor=i.vendor, product=i.product,
            version=i.version, bustype=i.bustype, phys=PHYS,
            input_props=self.src.input_props())
        self.src.grab()
        self.touchpad = e.EV_ABS in self.src.capabilities()
        if self.touchpad:
            res = self.src.absinfo(e.ABS_X).resolution or 10
            self.slop = SLOP_MM * res
        else:
            self.slop = SLOP_COUNTS
        self.tools = set()
        self.state = "idle"  # idle | pending | swallow
        self.deadline = None
        self.x = self.y = None  # latest touch position
        self.ox = self.oy = None  # position at press
        self.dx = self.dy = 0

    def close(self):
        for f in (self.src.ungrab, self.src.close, self.ui.close):
            try:
                f()
            except OSError:
                pass

    def emit_left(self):
        self.ui.write(e.EV_KEY, e.BTN_LEFT, 1)
        self.ui.syn()

    def moved(self):
        if self.touchpad:
            if self.ox is None or self.x is None:
                return False
            return abs(self.x - self.ox) > self.slop or abs(self.y - self.oy) > self.slop
        return abs(self.dx) > self.slop or abs(self.dy) > self.slop

    def handle_frame(self, frame):
        out = []
        release = False
        for ev in frame:
            if ev.type == e.EV_KEY and ev.code in MULTI_TOOLS:
                (self.tools.add if ev.value else self.tools.discard)(ev.code)
            elif ev.type == e.EV_ABS and ev.code == e.ABS_X:
                self.x = ev.value
            elif ev.type == e.EV_ABS and ev.code == e.ABS_Y:
                self.y = ev.value
            elif ev.type == e.EV_REL and ev.code == e.REL_X:
                self.dx += ev.value
            elif ev.type == e.EV_REL and ev.code == e.REL_Y:
                self.dy += ev.value

            if ev.type == e.EV_KEY and ev.code == e.BTN_LEFT:
                if ev.value == 1 and self.state == "idle" and not self.tools:
                    self.state = "pending"
                    self.deadline = time.monotonic() + HOLD
                    self.dx = self.dy = 0
                    self.ox = self.oy = None  # set from this frame's position below
                    continue  # hold the press back
                if ev.value == 0 and self.state != "idle":
                    release = True
                    if self.state == "swallow":
                        self.state = "idle"
                        continue
                    self.emit_left()  # quick click: press now, release below
                    self.state = "idle"
                if ev.value == 2:
                    continue
            out.append(ev)

        if self.state == "pending" and self.ox is None:
            self.ox, self.oy = self.x, self.y  # position arrived in the press frame
        if self.state == "pending" and not release and (self.moved() or self.tools):
            self.emit_left()  # drag or late second finger: real left press
            self.state = "idle"
        for ev in out:
            self.ui.write_event(ev)

    def tick(self, vmouse):
        if self.state == "pending" and time.monotonic() >= self.deadline:
            self.state = "swallow"
            for v in (1, 0):
                vmouse.write(e.EV_KEY, e.BTN_RIGHT, v)
                vmouse.syn()


def main():
    vmouse = UInput({e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT], e.EV_REL: [e.REL_X, e.REL_Y]},
                    name="longpress-rightclick", phys=PHYS)
    sel = selectors.DefaultSelector()
    devs = {}
    frames = {}
    ignored = {}
    next_scan = 0
    while True:
        now = time.monotonic()
        if now >= next_scan:
            next_scan = now + 3
            paths = glob.glob("/dev/input/event*")
            for missing in ignored.keys() - paths:
                del ignored[missing]
            for path in paths:
                if path in devs:
                    continue
                try:
                    # Closing an evdev fd can block this forwarding loop on an RCU
                    # grace period. Probe a rejected device only once per lifetime.
                    identity = os.readlink("/sys/class/input/" + os.path.basename(path))
                    if ignored.get(path) == identity:
                        continue
                    with closing(evdev.InputDevice(path)) as probe:
                        ok = wanted(probe)
                    if not ok:
                        ignored[path] = identity
                        continue
                    d = Dev(path)
                    devs[path] = d
                    frames[path] = []
                    sel.register(d.src, selectors.EVENT_READ, path)
                    print(f"grabbed {path}: {d.src.name}", flush=True)
                except OSError:
                    pass
        deadlines = [d.deadline for d in devs.values() if d.state == "pending"]
        timeout = min([next_scan] + deadlines) - time.monotonic()
        for key, _ in sel.select(max(0, timeout)):
            path = key.data
            d = devs[path]
            try:
                for ev in d.src.read():
                    if ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
                        d.handle_frame(frames[path])
                        frames[path] = []
                        d.ui.syn()
                    elif ev.type != e.EV_SYN or ev.code != e.SYN_DROPPED:
                        frames[path].append(ev)
            except OSError:
                print(f"lost {path}", flush=True)
                sel.unregister(d.src)
                d.close()
                del devs[path], frames[path]
        for d in devs.values():
            d.tick(vmouse)


if __name__ == "__main__":
    main()

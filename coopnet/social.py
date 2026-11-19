"""Friend list traffic between coopnet instances (channel 1, apart from the game).

Status (`who` -> `state`) is only answered for ids the mod has approved; friend
requests (`req`, `ok`, `no`, `bye`) are passed to the mod from anyone, since
that is how two players become friends. Nothing here ever chooses the game peer.
"""
import re

import steam

_STEAM_ID = re.compile(r"^\d{17}$")
_PROFILE = re.compile(r"steamcommunity\.com/profiles/(\d{17})/?$", re.IGNORECASE)
_UDP = re.compile(r"^udp:\d{1,5}$")


def parse_id(text):
    text = (text or "").strip()
    if _STEAM_ID.match(text) or _UDP.match(text):
        return text
    m = _PROFILE.search(text)
    if m:
        return m.group(1)
    sid = steam.decode_code(text)
    return str(sid) if sid else None


def _clean(s):
    return (s or "").replace("|", "/").replace("\n", " ").replace("\r", " ")


class Social:
    def __init__(self, version=""):
        self.version = version
        self.mode, self.world = "menu", ""
        self.approved = set()
        self.peer_fn = lambda: None

    def command(self, args):
        """Lua commands; returns (packets [(to_id, bytes)], lines for Lua)."""
        cmd = args[0]
        if cmd == "approved":
            self.approved = set(filter(None, (args[1] if len(args) > 1 else "").split(",")))
            return [], []
        if cmd == "state":
            self.mode = args[1] if len(args) > 1 and args[1] else "menu"
            self.world = args[2] if len(args) > 2 else ""
            if len(args) > 3 and args[3]:
                self.version = args[3]
            return [], []
        if cmd in ("ask", "qsend") and len(args) < (2 if cmd == "ask" else 3):
            return [], []
        if cmd == "ask":
            return [(i, b"who") for i in filter(None, args[1].split(","))], []
        if cmd == "qsend":
            return [(args[1], "|".join(args[2:]).encode("utf-8"))], []
        return [], [f"steam|0|error|okänt kommando {cmd}"]

    def _state(self, asker):
        mode = self.mode
        peer = self.peer_fn()
        if mode == "host" and peer is not None and str(peer) != asker:
            mode = "full"
        return f"state|{mode}|{_clean(self.world)}|{_clean(self.version)}".encode("utf-8")

    def incoming(self, sender, data):
        parts = data.decode("utf-8", "replace").split("|")
        kind = parts[0]
        if kind == "who":
            return ([(sender, self._state(sender))], []) if sender in self.approved else ([], [])
        if kind == "state":
            if sender not in self.approved:
                return [], []
            mode, world, version = (_clean(p) for p in (parts[1:] + ["", "", ""])[:3])
            return [], [f"steam|0|friendstate|{sender}|{mode}|{world}|{version}"]
        if kind == "req":
            return [], [f"steam|0|request|{sender}|{_clean(parts[1] if len(parts) > 1 else '')}"]
        if kind == "ok":
            return [], [f"steam|0|accepted|{sender}"]
        if kind == "no":
            return [], [f"steam|0|declined|{sender}"]
        if kind == "bye":
            return [], [f"steam|0|removed|{sender}"]
        return [], []

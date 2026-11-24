"""Bridge between the CoopSync Lua mod (two append-only files) and the other player.

Lua writes lines to out.log and reads in.log. Most lines are passed through to
the peer as they are; `sendfile|<path>|<name>` sends a whole file, which the
other side writes into the save folder and announces with `savefile|<path>`.
"""
import argparse
import os
import socket
import sys
import time

import report
import saves
import social
import transfer
import update

DEFAULT_SAVEDIR = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Voyage", "Saved", "SaveGames", "Coop")
RESEND_AFTER = 1.0
GUARD_EVERY = 2.0
CHUNKS_PER_LOOP = 200


GAME_EXE = "VoyageSteam-Win64-Shipping.exe"


def game_running():
    import subprocess
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/NH"], capture_output=True, encoding="mbcs", errors="replace",
                         text=True, creationflags=0x08000000).stdout  # CREATE_NO_WINDOW
    return GAME_EXE[:25].lower() in out.lower()  # tasklist cuts names at 25 characters


def process_alive(pid):
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    k.GetExitCodeProcess(h, ctypes.byref(code))
    k.CloseHandle(h)
    return code.value == 259  # STILL_ACTIVE


def open_game(pid=None):
    """Handle to the game, kept open so its exit code can be read after it ends."""
    import ctypes
    import subprocess
    if pid is None:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/NH", "/FO", "CSV"], capture_output=True,
                             encoding="mbcs", errors="replace", text=True, creationflags=0x08000000).stdout
        fields = [line.split('","') for line in out.splitlines() if GAME_EXE.lower() in line.lower()]
        if not fields:
            return None
        pid = int(fields[0][1])
    k = ctypes.windll.kernel32
    k.OpenProcess.restype = ctypes.c_void_p
    return k.OpenProcess(0x1000, False, pid) or None  # PROCESS_QUERY_LIMITED_INFORMATION


def game_exit_code(handle):
    import ctypes
    code = ctypes.c_ulong()
    if not ctypes.windll.kernel32.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code)) or code.value == 259:
        return None
    return code.value


def left_mouse_down():
    import ctypes
    # Bit 0 = pressed since the last call: catches clicks shorter than one poll
    # (remote desktop tools send down and up together).
    return bool(ctypes.windll.user32.GetAsyncKeyState(0x01) & 0x8001)


class UdpLink:
    """Test bench link. Friend-list traffic (channel 1 on Steam) travels as
    lines starting with q|, addressed udp:<port> on the peer's host."""

    def __init__(self, listen, peer):
        host, port = peer.rsplit(":", 1)
        self.peer = (host, int(port))
        self.my_id = f"udp:{listen}"
        self.q = []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", listen))
        self.sock.setblocking(False)

    def peer_id(self):
        return f"udp:{self.peer[1]}"

    def hello_lines(self):
        return [f"steam|0|me|{self.my_id}|".encode()]

    def send(self, data, reliable=True):
        self.sock.sendto(data, self.peer)

    def send_q(self, to_id, data):
        try:
            port = int(str(to_id).split(":", 1)[1])
        except (IndexError, ValueError):
            return
        self.sock.sendto(b"q|" + data, (self.peer[0], port))

    def receive(self):
        out = []
        while True:
            try:
                pkt, addr = self.sock.recvfrom(65535)
            except BlockingIOError:
                return out
            except ConnectionResetError:
                continue
            if pkt.startswith(b"q|"):
                self.q.append((f"udp:{addr[1]}", pkt[2:]))
            else:
                out.append(pkt)

    def receive_q(self):
        q, self.q = self.q, []
        return q

    def tick(self):
        pass


class Outgoing:
    """One file being sent; chunks are resent until the peer acks them."""

    def __init__(self, path, name):
        self.lines = transfer.chunks(path, name)
        self.name = name
        self.tid, _, self.n = transfer.parse(self.lines[0])
        self.sent_at = {}

    def due(self, now):
        for i, line in enumerate(self.lines):
            if line is not None and now - self.sent_at.get(i, -RESEND_AFTER) >= RESEND_AFTER:
                yield i, line

    def ack(self, i):
        self.lines[i] = None

    def done(self):
        return all(line is None for line in self.lines)


class Bridge:
    def __init__(self, io_dir, link, savedir, lan=None):
        self.link = link
        # Game traffic goes over Steam (or the bench's UDP) unless the mod
        # hosts or joins on the LAN; friend-list traffic always uses link.
        self.lan = lan
        self.game = link
        self.out_path = os.path.join(io_dir, "out.log")
        self.in_path = os.path.join(io_dir, "in.log")
        for p in (self.out_path, self.in_path):
            open(p, "wb").close()
        self.out_offset = 0
        self.out_file = None
        self.rx = transfer.Receiver(savedir)
        os.makedirs(savedir, exist_ok=True)
        self.saves = saves.Saves(savedir)
        self.guarding = False
        self.last_guard = 0.0
        self.outgoing = []
        self.reported = {}
        self.sent = self.received = 0
        # The mod's menu buttons swallow clicks before the game sees them, so
        # the mouse button is read here and the mod pairs it with hover.
        self.mouse_down = left_mouse_down
        self.mouse_was = False
        self.social = social.Social()
        self.social.peer_fn = lambda: self.game.peer_id() if hasattr(self.game, "peer_id") else None
        self.updater = None
        self.reporter = report.Sender(report.load_webhook(), report.Paths(io_dir, os.environ.get("LOCALAPPDATA", "")), time.time())

    def to_lua(self, lines):
        with open(self.in_path, "ab") as f:
            f.write(b"".join(line + b"\n" for line in lines))

    def read_lua(self):
        # The size comes from an open handle: os.path.getsize reads the
        # directory entry, which Windows updates late while the game holds the
        # file open, and messages waited up to 2 s.
        if self.out_file is None:
            self.out_file = open(self.out_path, "rb")
        f = self.out_file
        size = f.seek(0, os.SEEK_END)
        if size < self.out_offset:
            self.out_offset = 0
        if size <= self.out_offset:
            return []
        f.seek(self.out_offset)
        data = f.read(size - self.out_offset)
        end = data.rfind(b"\n") + 1
        self.out_offset += end
        return data[:end].splitlines()

    def control(self, args):
        """steam|<seq>|<cmd>|... from Lua; returns lines for Lua."""
        link, cmd = self.link, args[0]
        if cmd == "lanhost" and self.lan:
            self.lan.host(*(args[1:4] + ["", "", ""])[:3])
            self.game = self.lan
            return []
        if cmd == "join" and len(args) > 1 and args[1].startswith("lan:") and self.lan:
            self.lan.join(args[1][4:])
            self.game = self.lan
            return []
        if cmd == "leave":
            if self.lan:
                self.lan.leave()
            # The bench's UDP peer is fixed; Steam's is whoever comes next.
            if not isinstance(link, UdpLink) and hasattr(link, "peer"):
                link.peer = None
            self.game = link
            return []
        if cmd == "join" and self.game is self.lan:
            self.game = link
        if cmd in ("approved", "state", "ask", "qsend"):
            packets, lines = self.social.command(args)
            for to_id, data in packets:
                link.send_q(to_id, data)
            return lines
        if cmd == "whoami":
            return [l.decode("utf-8") for l in link.hello_lines()]
        if cmd == "resolve":
            text = args[1] if len(args) > 1 else ""
            return [f"steam|0|resolved|{social.parse_id(text) or ''}|{text}"]
        if cmd == "clipid":
            import clip
            clip.write(link.my_id)
            return [f"steam|0|clippedid|{link.my_id}"]
        if cmd == "presence":
            if hasattr(link, "presence"):
                link.presence(args[1] if len(args) > 1 else "", args[2] if len(args) > 2 else "")
            return []
        if cmd == "name":
            name = link.name(args[1]) if hasattr(link, "name") else ""
            return [f"steam|0|name|{args[1]}|{(name or '').replace('|', '/')}"]
        if cmd in ("clip", "readclip"):
            import clip
            import steam
            if cmd == "clip":
                code = steam.encode_code(link.me) if hasattr(link, "me") else ""
                clip.write(code)
                return [f"steam|0|clipped|{code}"]
            sid = steam.decode_code(clip.read())
            return [f"steam|0|clipcode|{sid}"] if sid else ["steam|0|clipbad"]
        if not hasattr(link, "friends"):
            return [f"steam|0|error|{cmd} kräver Steam"]
        if cmd == "friends":
            return [f"steam|0|friend|{fid}|{name.replace('|', '/')}" for fid, name in link.friends()] + ["steam|0|friendsdone"]
        if cmd == "invite":
            ok = link.invite(int(args[1]), f"-coopJoin={link.me}")
            return [f"steam|0|invited|{args[1]}|{1 if ok else 0}"]
        if cmd == "join":
            link.join(int(args[1]))
            return []
        if cmd == "status":
            out = []
            for sid in filter(None, args[1].split(",")):
                name, online = link.status(int(sid))
                out.append(f"steam|0|status|{sid}|{name.replace('|', '/')}|{1 if online else 0}")
            return out
        return [f"steam|0|error|okänt kommando {cmd}"]

    def save_command(self, args):
        cmd = args[0]
        if cmd == "list":
            return [f"save|0|world|{n}|{int(t)}" for n, t in self.saves.worlds()] + ["save|0|listdone"]
        if cmd == "splist":
            return [f"save|0|sp|{n}|{int(t)}" for n, t in self.saves.sp_slots()] + ["save|0|spdone"]
        if cmd == "import":
            try:
                return [f"save|0|imported|{self.saves.import_slot(int(args[1]))}"]
            except (OSError, ValueError) as e:
                return [f"save|0|error|{e}"]
        if cmd == "delete":
            try:
                self.saves.delete(args[1])
                return [f"save|0|deleted|{args[1]}"]
            except (OSError, ValueError) as e:
                return [f"save|0|error|{e}"]
        if cmd == "rename":
            try:
                self.saves.rename(args[1], args[2])
                return [f"save|0|renamed|{args[1]}|{args[2].strip()}"]
            except (OSError, ValueError) as e:
                return [f"save|0|error|{e}"]
        if cmd == "guard":
            self.guarding = args[1] == "on"
            if self.guarding:
                self.saves.guard_on()
            else:
                self.saves.guard_check()
                self.saves.guard_off()
            return [f"save|0|guard|{args[1]}"]
        return [f"save|0|error|okänt kommando {cmd}"]

    def check_guard(self, now, lua_lines):
        if not self.guarding or now - self.last_guard < GUARD_EVERY:
            return
        self.last_guard = now
        try:
            touched = self.saves.guard_check()
        except OSError as e:
            # The game may still be writing; the next check gets it.
            print(f"coopnet: vakt väntar: {e}", flush=True)
            return
        if touched:
            print(f"coopnet: vakten återställde {touched}", flush=True)
            lua_lines.append(f"save|0|guarded|{len(touched)}".encode())

    def from_lua(self, line):
        if line.startswith(b"update|"):
            if self.updater:
                self.updater.command(line.decode("utf-8").split("|")[2:])
            return
        if line.startswith(b"report|"):
            self.reporter.command(line.decode("utf-8").split("|")[2:])
            return
        if line.startswith(b"save|"):
            self.to_lua([r.encode("utf-8") for r in self.save_command(line.decode("utf-8").split("|")[2:])])
            return
        if line.startswith(b"steam|"):
            reply = self.control(line.decode("utf-8").split("|")[2:])
            if reply:
                self.to_lua([r.encode("utf-8") for r in reply])
            return
        if line.startswith(b"sendfile|"):
            _, _, path, name = line.decode("utf-8").split("|", 3)
            try:
                self.outgoing.append(Outgoing(path, name))
                print(f"coopnet: skickar {path} som {name}", flush=True)
            except OSError as e:
                self.to_lua([f"fileerror|0|{e}".encode("utf-8")])
            return
        self.game.send(line, reliable=not line.startswith(b"pos|"))
        self.sent += 1

    def from_peer(self, pkt, lua_lines):
        if pkt.startswith(b"file|"):
            tid, i, n = transfer.parse(pkt)
            self.game.send(f"fileack|{tid}|{i}".encode())
            done = self.rx.feed(pkt)
            if done:
                lua_lines.append(f"savefile|0|{done}".encode("utf-8"))
                print(f"coopnet: tog emot {done}", flush=True)
                return
            got = self.rx.progress(tid)
            if got:
                step = max(1, got[1] // 20)
                if got[0] // step != self.reported.get(tid, -1):
                    self.reported[tid] = got[0] // step
                    lua_lines.append(f"fileprogress|0|{got[0]}|{got[1]}".encode())
            return
        if pkt.startswith(b"fileack|"):
            _, tid, i = pkt.decode().split("|")
            for o in self.outgoing:
                if o.tid == tid:
                    o.ack(int(i))
            return
        lua_lines.append(pkt)
        self.received += 1

    def pump_files(self, now, lua_lines):
        budget = CHUNKS_PER_LOOP
        for o in list(self.outgoing):
            if o.done():
                self.outgoing.remove(o)
                lua_lines.append(f"filesent|0|{o.name}".encode("utf-8"))
                continue
            for i, line in o.due(now):
                if budget <= 0:
                    return
                self.game.send(line)
                o.sent_at[i] = now
                budget -= 1

    def step(self):
        for line in self.read_lua():
            self.from_lua(line)
        lua_lines = []
        if self.game is not self.link:
            self.link.receive()  # Steam's channel 0 is drained, not used
        for pkt in self.game.receive():
            self.from_peer(pkt, lua_lines)
        for sender, data in self.link.receive_q():
            packets, lines = self.social.incoming(sender, data)
            for to_id, reply in packets:
                self.link.send_q(to_id, reply)
            lua_lines.extend(line.encode("utf-8") for line in lines)
        self.pump_files(time.monotonic(), lua_lines)
        self.check_guard(time.monotonic(), lua_lines)
        down = self.mouse_down()
        if down != self.mouse_was:
            self.mouse_was = down
            lua_lines.append(b"mouse|0|1" if down else b"mouse|0|0")
        if hasattr(self.link, "take_events"):
            lua_lines.extend(self.link.take_events())
        if self.updater:
            lua_lines.extend(self.updater.take_events())
        lua_lines.extend(self.reporter.take_events())
        if self.lan:
            self.lan.tick()
            lua_lines.extend(e.encode("utf-8") for e in self.lan.take_events())
        if lua_lines:
            self.to_lua(lua_lines)
        self.link.tick()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="CoopSync io folder")
    ap.add_argument("--savedir", default=DEFAULT_SAVEDIR)
    ap.add_argument("--udp", action="store_true", help="plain UDP (test bench) instead of Steam")
    ap.add_argument("--listen", type=int)
    ap.add_argument("--peer", help="host:port of the other coopnet (UDP)")
    ap.add_argument("--dll", help="steam_api64.dll (Steam)")
    ap.add_argument("--gamepid", type=int, help="exit when this process ends")
    ap.add_argument("--watchgame", action="store_true", help="exit when no game process is left")
    args = ap.parse_args()
    args.dir, args.savedir = os.path.abspath(args.dir), os.path.abspath(args.savedir)
    if args.dll:
        args.dll = os.path.abspath(args.dll)

    os.makedirs(args.dir, exist_ok=True)
    if not args.udp:
        # Started with start /B its output went nowhere; the bench redirects it itself.
        log_path = os.path.join(args.dir, "coopnet.log")
        try:
            if os.path.exists(log_path):
                os.replace(log_path, os.path.join(args.dir, "coopnet.prev.log"))
            sys.stdout = sys.stderr = open(log_path, "w", encoding="utf-8", buffering=1)
        except OSError:
            pass  # held by a coopnet that has not quit yet; the log is a help, not a need
    try:
        game = open_game(args.gamepid)
    except (OSError, ValueError, IndexError):
        game = None
    with open(os.path.join(args.dir, "coopnet.pid"), "w") as f:
        f.write(str(os.getpid()))
    leftover = saves.Saves(args.savedir).recover_leftover() if os.path.isdir(args.savedir) else []
    if leftover:
        print(f"coopnet: återställde singleplayer-filer från förra sessionen: {leftover}", flush=True)
    if args.udp:
        link = UdpLink(args.listen, args.peer)
    else:
        import steam
        try:
            link = steam.SteamLink(args.dll, args.dir)
        except steam.SteamUnavailable as e:
            with open(os.path.join(args.dir, "in.log"), "ab") as f:
                f.write(f"steam|0|error|{e}\n".encode("utf-8"))
            print(f"coopnet: Steam saknas: {e}", flush=True)
            sys.exit(2)
    import lan
    try:
        lan_link = lan.LanLink()
    except OSError as e:
        lan_link = None
        print(f"coopnet: LAN saknas: {e}", flush=True)
    bridge = Bridge(args.dir, link, args.savedir, lan=lan_link)
    bridge.to_lua(link.hello_lines())
    try:
        if report.recover_unsaved(bridge.reporter.paths):
            print("coopnet: förra körningen sparades aldrig, last byggd av prev-loggarna", flush=True)
    except OSError as e:
        print(f"coopnet: förra körningens loggar gick inte att spara: {e}", flush=True)
    pending = bridge.reporter.pending() if bridge.reporter.webhook else b"report|0|disabled"
    if pending:
        bridge.to_lua([pending])
    # Next to the built exe: <mod>\coopnet\coopnet.exe; the source folder has no update.ini.
    # UDP is the bench and Spelstartare's split screen, where player 2 runs from a
    # mirror (H:\TLC-sp2): an update there would install into the mirror.
    mod_dir = None if args.udp else os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[0])))
    bridge.updater = update.Updater(mod_dir)
    bridge.updater.check()
    print(f"coopnet: {args.dir} ({'udp' if args.udp else 'steam'})", flush=True)

    last_report = last_alive = time.monotonic()
    while True:
        bridge.step()
        now = time.monotonic()
        if now - last_alive > 3:
            last_alive = now
            with open(os.path.join(args.dir, "coopnet.alive"), "w") as f:
                f.write(str(int(time.time())))
            gone = (args.gamepid and not process_alive(args.gamepid)) or (args.watchgame and not game_running())
            if gone:
                code = game_exit_code(game) if game else None
                r = bridge.reporter
                try:
                    info = report.snapshot(r.paths, r.paths.last_dir, r.session_start, code, sorted(r.names))
                    print(f"coopnet: sessionen sparad i {r.paths.last_dir} (krasch: {'ja' if info['crashed'] else 'nej'}, exitkod {code})", flush=True)
                except OSError as e:
                    print(f"coopnet: sessionen gick inte att spara: {e}", flush=True)
                bridge.saves.recover_leftover()
                r.wait(60)
                print("coopnet: spelet har stängts, avslutar", flush=True)
                bridge.updater.install()
                return
        if now - last_report > 10:
            print(f"coopnet: skickat {bridge.sent}, mottaget {bridge.received}", flush=True)
            last_report = now
        # Each loop is a file seek and a socket poll; 2 ms keeps the wait
        # between the game and the link short without busy-looping.
        time.sleep(0.002)


if __name__ == "__main__":
    main()

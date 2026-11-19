"""LAN link for coopnet: game traffic over UDP on the local network, without
Steam, and servers found by broadcast.

A host binds the game port and announces `TLCLAN|<world>|<name>|<version>|<port>`
every ANNOUNCE_EVERY seconds; the first one to send `hello|` becomes its guest,
and nothing from anyone else counts as game traffic. Everyone listens on the
announce port (shared with SO_REUSEADDR, so two copies on one machine work) and
reports servers to the mod as `steam|0|lanserver|<ip:port>|<world>|<name>|<version>`.
"""
import socket
import time

GAME_PORT = 47020
ANNOUNCE_PORT = 47021
ANNOUNCE_EVERY = 2.0
# A guest silent this long can be replaced by a new one saying hello (the
# guest restarted its game and comes back from another port).
PEER_QUIET = 10.0
PREFIX = b"TLCLAN|"


def _clean(s):
    return (s or "").replace("|", "/").replace("\n", " ").replace("\r", " ")


class LanLink:
    def __init__(self, game_port=GAME_PORT, listen_port=ANNOUNCE_PORT, announce_to=("255.255.255.255", ANNOUNCE_PORT)):
        self.game_port = game_port
        self.announce_to = announce_to
        self.sock = None
        self.peer = None
        self.peer_heard = 0.0
        self.hosting = None
        self.last_announce = 0.0
        self.events = []
        self.disc = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.disc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.disc.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.disc.bind(("", listen_port))
        self.disc.setblocking(False)

    def _bind(self, port):
        if self.sock:
            return
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # A second copy on the same machine takes the next free port.
        for p in ([port + i for i in range(10)] if port else [0]):
            try:
                self.sock.bind(("0.0.0.0", p))
                break
            except OSError:
                continue
        self.sock.setblocking(False)

    def port(self):
        return self.sock.getsockname()[1] if self.sock else None

    def host(self, world, name, version):
        self._bind(self.game_port)
        self.peer = None
        self.hosting = (_clean(world), _clean(name), _clean(version))
        self.last_announce = 0.0

    def join(self, addr):
        ip, port = addr.rsplit(":", 1)
        # A name (Tailscale's MagicDNS) is resolved once: the host's packets
        # are matched on its address.
        try:
            ip = socket.gethostbyname(ip)
        except OSError:
            self.events.append(f"steam|0|joinfail|{_clean(addr)}")
            return
        self._bind(0)
        self.hosting = None
        self.peer = (ip, int(port))

    def leave(self):
        self.hosting = None
        self.peer = None
        if self.sock:
            self.sock.close()
            self.sock = None

    def peer_id(self):
        return None if self.peer is None else f"lan:{self.peer[0]}:{self.peer[1]}"

    def send(self, data, reliable=True):
        if self.sock and self.peer:
            try:
                self.sock.sendto(data, self.peer)
            except OSError:
                pass

    def receive(self):
        out = []
        while self.sock:
            try:
                pkt, addr = self.sock.recvfrom(65535)
            except BlockingIOError:
                break
            except (ConnectionResetError, OSError):
                continue
            now = time.monotonic()
            if (self.hosting and pkt.startswith(b"hello|") and addr != self.peer
                    and (self.peer is None or now - self.peer_heard > PEER_QUIET)):
                self.peer = addr
                self.events.append(f"steam|0|peer|lan:{addr[0]}:{addr[1]}")
            if addr == self.peer:
                self.peer_heard = now
                out.append(pkt)
        return out

    def receive_q(self):
        return []

    def tick(self):
        now = time.monotonic()
        if self.hosting and self.sock and now - self.last_announce >= ANNOUNCE_EVERY:
            self.last_announce = now
            world, name, version = self.hosting
            msg = PREFIX + f"{world}|{name}|{version}|{self.port()}".encode("utf-8")
            try:
                self.disc.sendto(msg, self.announce_to)
            except OSError:
                pass
        while True:
            try:
                pkt, addr = self.disc.recvfrom(2048)
            except BlockingIOError:
                return
            except (ConnectionResetError, OSError):
                continue
            if not pkt.startswith(PREFIX):
                continue
            parts = pkt[len(PREFIX):].decode("utf-8", "replace").split("|")
            if len(parts) != 4 or not parts[3].isdigit():
                continue
            world, name, version, port = (_clean(p) for p in parts)
            self.events.append(f"steam|0|lanserver|{addr[0]}:{port}|{world}|{name}|{version}")

    def take_events(self):
        ev, self.events = self.events, []
        return ev

    def close(self):
        self.leave()
        self.disc.close()

"""Self-update from the public GitHub releases.

Only active when update.ini sits in the mod folder (the installer and the
manual zip write it; the Nexus zip leaves it out, Nexus forbids updaters).
The check and the download run in a thread; the installer runs after the game
has closed, silently, and starts the game again through Steam.
"""
import configparser
import hashlib
import json
import os
import pathlib
import tempfile
import threading
import urllib.request

API = "https://api.github.com/repos/Bemno/Caretakers-Multiplayer/releases/latest"
AGENT = "Caretakers-Multiplayer-updater"
SETUP_PREFIX = "Caretakers-Multiplayer-Setup-"


def parse_version(text):
    try:
        return tuple(int(p) for p in text.strip().lstrip("v").split("."))
    except ValueError:
        return None


def read_ini(path):
    cp = configparser.ConfigParser()
    if not cp.read(path, encoding="utf-8") or not cp.has_section("update"):
        return None
    return dict(cp["update"])


def pick_setup(release):
    for a in release.get("assets", []):
        if a.get("name", "").startswith(SETUP_PREFIX) and a["name"].endswith(".exe"):
            digest = a.get("digest") or ""
            if digest.startswith("sha256:"):
                return a["browser_download_url"], digest[7:].lower(), a.get("size", 0)
    return None


def game_dir(mod_dir):
    # <game>\Voyage\Binaries\Win64\ue4ss\Mods\CoopSync
    return pathlib.Path(mod_dir).parents[5]


class Updater:
    def __init__(self, mod_dir, fetch=None):
        self.mod_dir = mod_dir
        ini = read_ini(os.path.join(mod_dir, "update.ini")) if mod_dir else None
        self.enabled = bool(ini) and ini.get("enabled", "1") != "0"
        self.version = parse_version(ini.get("version", "")) if ini else None
        self.fetch = fetch or self._fetch
        self.events = []
        self.lock = threading.Lock()
        self.latest = None
        self.asset = None
        self.ready = None       # downloaded and verified installer
        self.busy = False

    def _fetch(self, url, dest=None, progress=None):
        req = urllib.request.Request(url, headers={"User-Agent": AGENT, "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            if dest is None:
                return r.read()
            total = int(r.headers.get("Content-Length") or 0)
            got = 0
            with open(dest, "wb") as f:
                while True:
                    block = r.read(256 * 1024)
                    if not block:
                        break
                    f.write(block)
                    got += len(block)
                    if progress:
                        progress(got, total)

    def _emit(self, line):
        with self.lock:
            self.events.append(line.encode("utf-8"))

    def take_events(self):
        with self.lock:
            out, self.events = self.events, []
        return out

    def _run(self, fn):
        if self.busy:
            return
        self.busy = True

        def wrap():
            try:
                fn()
            except Exception as e:  # network, disk: report and let the player retry
                self._emit(f"update|0|error|{str(e).replace('|', '/')}")
                print(f"coopnet: uppdatering: {e}", flush=True)
            finally:
                self.busy = False
        threading.Thread(target=wrap, daemon=True).start()

    def check(self):
        if not self.enabled or not self.version:
            return
        self._run(self._check)

    def _check(self):
        release = json.loads(self.fetch(API))
        latest = parse_version(release.get("tag_name", ""))
        asset = pick_setup(release)
        if not latest or not asset:
            return
        print(f"coopnet: senaste version {latest}, egen {self.version}", flush=True)
        if latest > self.version:
            self.latest, self.asset = latest, asset
            self._emit(f"update|0|available|{'.'.join(map(str, latest))}")

    def download(self):
        if self.asset and not self.ready:
            self._run(self._download)

    def _download(self):
        url, sha, size = self.asset
        version = ".".join(map(str, self.latest))
        dest = pathlib.Path(tempfile.gettempdir()) / f"{SETUP_PREFIX}{version}.exe"
        step = [-1]

        def progress(got, total):
            pct = int(100 * got / (total or size or 1))
            if pct // 5 != step[0]:
                step[0] = pct // 5
                self._emit(f"update|0|progress|{pct}")
        self.fetch(url, dest, progress)
        h = hashlib.sha256()
        with open(dest, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        if h.hexdigest() != sha:
            dest.unlink(missing_ok=True)
            raise ValueError("checksum mismatch")
        self.ready = str(dest)
        self._emit(f"update|0|ready|{version}")

    def command(self, args):
        if args and args[0] == "get":
            self.download()
        elif args and args[0] == "check":
            self.check()

    def install(self):
        """Called after the game has closed: elevated silent install, then the
        installer starts the game through Steam (runasoriginaluser)."""
        if not self.ready:
            return False
        import ctypes
        params = f'/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RESTARTGAME=1 /DIR="{game_dir(self.mod_dir)}"'
        r = ctypes.windll.shell32.ShellExecuteW(None, "runas", self.ready, params, None, 0)
        print(f"coopnet: installerar {self.ready}: {r}", flush=True)
        return r > 32

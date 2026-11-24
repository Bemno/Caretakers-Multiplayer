"""Bug reports: the logs of the last session are copied when the game closes
(the next start overwrites UE4SS.log), and a report is packed, cleaned of
personal details and posted to a Discord webhook."""
import glob
import hashlib
import io
import json
import os
import re
import shutil
import threading
import time
import urllib.request
import uuid
import zipfile

TAIL = 3_000_000
LIMIT = 9_500_000   # Discord takes 10 MB per webhook call
TEXT_EXT = (".log", ".txt", ".xml", ".runtime-xml", ".json", ".ini")
MIN_GAP = 60
AGENT = "CaretakersMultiplayer (https://github.com/Bemno/Caretakers-Multiplayer)"
USER_RE = re.compile(r"[A-Za-z]:[\\/]+users[\\/]+[^\\/\s\"'<>|]+", re.I)
SID_RE = re.compile(r"7656119\d{10}")
CRASH_ID_RE = re.compile(r"<(MachineId|LoginId|EpicAccountId|UserName)>[^<]*</\1>")
IP_RE = re.compile(r"(?<![\d.])(?!0\.0\.0\.0|127\.)(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")


class Paths:
    def __init__(self, io_dir, localappdata):
        io_dir = os.path.abspath(io_dir)
        self.io_name = os.path.basename(io_dir)
        self.io_dir = io_dir
        self.mod_dir = os.path.dirname(os.path.dirname(io_dir))
        self.ue4ss_dir = os.path.dirname(os.path.dirname(self.mod_dir))
        self.ue4ss_log = os.path.join(self.ue4ss_dir, "UE4SS.log")
        self.coopsync_log = os.path.join(self.mod_dir, f"coopsync_{self.io_name}.log")
        self.coopnet_log = os.path.join(io_dir, "coopnet.log")
        # Each start moves the last run's log here (main.lua, coopnet.py).
        self.coopsync_prev = os.path.join(self.mod_dir, f"coopsync_{self.io_name}.prev.log")
        self.coopnet_prev = os.path.join(io_dir, "coopnet.prev.log")
        self.crashes = os.path.join(localappdata, "Voyage", "Saved", "Crashes")
        reports = os.path.join(self.mod_dir, "reports", self.io_name)
        self.last_dir = os.path.join(reports, "last")
        self.now_dir = os.path.join(reports, "now")


def crashed(exit_code, crash_dir, ue4ss_dump):
    return bool(crash_dir or ue4ss_dump) or exit_code not in (None, 0)


def _newest(paths, since):
    fresh = [p for p in paths if os.path.getmtime(p) >= since]
    return max(fresh, key=os.path.getmtime) if fresh else None


def snapshot(paths, dest, since, exit_code=None, names=()):
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest, exist_ok=True)
    for src in (paths.ue4ss_log, paths.coopsync_log, paths.coopnet_log):
        try:
            shutil.copy2(src, dest)
        except OSError:
            pass
    crash = _newest(glob.glob(os.path.join(paths.crashes, "UECC-*")), since) if os.path.isdir(paths.crashes) else None
    if crash:
        shutil.copytree(crash, os.path.join(dest, "crash"), dirs_exist_ok=True)
    dump = _newest(glob.glob(os.path.join(paths.ue4ss_dir, "crash_*.dmp")), since)
    if dump:
        shutil.copy2(dump, dest)
    info = {"time": time.time(), "since": since, "exit_code": exit_code,
            "crashed": crashed(exit_code, crash, dump),
            "crash_dir": os.path.basename(crash) if crash else None, "sent": False,
            "names": list(names)}
    with open(os.path.join(dest, "info.json"), "w", encoding="utf-8") as f:
        json.dump(info, f)
    return info


def recover_unsaved(paths):
    """The last run ended without a snapshot (power cut, coopnet killed): its
    logs, moved aside at this start, become last. UE4SS.log is gone by then."""
    prev = [p for p in (paths.coopsync_prev, paths.coopnet_prev) if os.path.exists(p)]
    if not prev:
        return None
    # No snapshot at all: the first start after updating from a version
    # without reports, not a crash.
    try:
        with open(os.path.join(paths.last_dir, "info.json"), encoding="utf-8") as f:
            saved_at = json.load(f).get("time", 0)
    except (OSError, ValueError):
        return None
    # coopnet writes its last lines just after the snapshot.
    newest = max(os.path.getmtime(p) for p in prev)
    if newest <= saved_at + 30:
        return None
    shutil.rmtree(paths.last_dir, ignore_errors=True)
    os.makedirs(paths.last_dir, exist_ok=True)
    for p in prev:
        shutil.copy2(p, paths.last_dir)
    info = {"time": time.time(), "since": None, "exit_code": None, "crashed": True,
            "crash_dir": None, "sent": False, "partial": True}
    with open(os.path.join(paths.last_dir, "info.json"), "w", encoding="utf-8") as f:
        json.dump(info, f)
    return info


def scrub(text, names):
    text = USER_RE.sub("<user>", text)
    text = SID_RE.sub(lambda m: "sid-" + hashlib.sha256(m.group().encode()).hexdigest()[:8], text)
    text = CRASH_ID_RE.sub(r"<\1></\1>", text)
    text = IP_RE.sub("<ip>", text)
    for i, name in enumerate(names):
        if len(name) >= 3:
            text = text.replace(name, f"<player{i + 1}>")
    return text


def build_zip(src_dir, names, limit=LIMIT):
    """The report as a zip, and the dumps left out to stay under the limit."""
    texts, dumps = [], []
    for root, _, files in os.walk(src_dir):
        for name in sorted(files):
            path = os.path.join(root, name)
            arc = os.path.relpath(path, src_dir).replace(os.sep, "/")
            if name.lower().endswith(TEXT_EXT):
                with open(path, "rb") as f:
                    f.seek(max(0, os.path.getsize(path) - TAIL))
                    data = f.read()
                texts.append((arc, scrub(data.decode("utf-8", "replace"), names).encode("utf-8")[-TAIL:]))
            else:
                dumps.append((arc, path))

    def pack(with_dumps):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for arc, data in texts:
                z.writestr(arc, data)
            for arc, path in with_dumps:
                z.write(path, arc)
        return buf.getvalue()

    data = pack(dumps)
    if len(data) <= limit or not dumps:
        return data, []
    return pack([]), [arc for arc, _ in dumps]


def load_webhook():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webhook.txt")
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return os.environ.get("COOPNET_WEBHOOK") or None


def http_post(url, body, content_type):
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": content_type, "User-Agent": AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        r.read()


def multipart(payload, filename, data):
    boundary = uuid.uuid4().hex
    head = (f'--{boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\n'
            f'Content-Type: application/json\r\n\r\n{json.dumps(payload)}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="{filename}"\r\n'
            'Content-Type: application/zip\r\n\r\n').encode("utf-8")
    return head + data + f"\r\n--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def _thread(fn):
    t = threading.Thread(target=fn, daemon=True)
    t.start()
    return t


class Sender:
    """report|<seq>|send|<id>|<now|last>|<names>|<header>|<text> and
    report|<seq>|dismiss and report|<seq>|names|<a,b> from Lua; answers report|0|sent|failed|disabled."""

    def __init__(self, webhook, paths, session_start, post=http_post, spawn=_thread, clock=time.monotonic):
        self.webhook, self.paths, self.session_start = webhook, paths, session_start
        self.post, self.spawn, self.clock = post, spawn, clock
        self.events, self.lock = [], threading.Lock()
        self.done_ids, self.last_send = set(), None
        self.threads = []
        # Every name seen this session; a "last" report is sent after the
        # other player has left and Lua no longer knows theirs.
        self.names = set()

    def _event(self, line):
        with self.lock:
            self.events.append(line.encode("utf-8"))

    def take_events(self):
        with self.lock:
            out, self.events = self.events, []
        return out

    def _info_path(self):
        return os.path.join(self.paths.last_dir, "info.json")

    def _last_info(self):
        try:
            with open(self._info_path(), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _mark_sent(self):
        info = self._last_info()
        if info:
            info["sent"] = True
            with open(self._info_path(), "w", encoding="utf-8") as f:
                json.dump(info, f)

    def pending(self):
        info = self._last_info()
        if not info or info.get("sent"):
            return None
        return f"report|0|pending|{1 if info.get('crashed') else 0}|{int(info.get('time', 0))}".encode()

    def wait(self, timeout):
        """Lets a report sent just before the game closed finish uploading."""
        end = time.monotonic() + timeout
        for t in self.threads:
            if t is not None:
                t.join(max(0, end - time.monotonic()))

    def command(self, args):
        if args[:1] == ["dismiss"]:
            self._mark_sent()
            return
        if args[:1] == ["names"] and len(args) > 1:
            self.names.update(n for n in args[1].split(",") if n)
            return
        if args[:1] != ["send"] or len(args) < 6:
            return
        rid, which, names, header, text = args[1], args[2], args[3], args[4], "|".join(args[5:])
        if not re.fullmatch(r"[\w-]{1,40}", rid):
            return
        if not self.webhook:
            self._event("report|0|disabled")
            return
        if rid in self.done_ids:
            return
        # The other game's request comes with the report it belongs to.
        peer = which == "peer"
        now = self.clock()
        if not peer and self.last_send is not None and now - self.last_send < MIN_GAP:
            self._event(f"report|0|failed|{rid}|too soon")
            return
        self.done_ids.add(rid)
        if not peer:
            self.last_send = now
        which = "now" if peer else which
        self.threads = [t for t in self.threads if t is not None and t.is_alive()]
        self.threads.append(self.spawn(lambda: self._send(rid, which, [n for n in names.split(",") if n], header, text)))

    def _send(self, rid, which, names, header, text):
        try:
            if which == "last" and not os.path.isdir(self.paths.last_dir):
                which = "now"
            if which == "last":
                src, info = self.paths.last_dir, self._last_info() or {}
            else:
                src = self.paths.now_dir
                info = snapshot(self.paths, src, self.session_start)
            names = names + [n for n in sorted(self.names) + info.get("names", []) if n not in names]
            data, dropped = build_zip(src, names)
            role = (re.search(r"role=(\w+)", header) or [None, self.paths.io_name])[1]
            content = (f"**Bug report {rid}** ({which}, crash: {'yes' if info.get('crashed') else 'no'})\n"
                       f"{scrub(header, names)}\n> {scrub(text.strip(), names) or '(no text)'}")
            if dropped:
                content += f"\nLeft out (too big): {', '.join(dropped)}"
            body, ctype = multipart({"content": content[:2000], "allowed_mentions": {"parse": []}},
                                    f"report-{rid}-{role}.zip", data)
            self.post(self.webhook, body, ctype)
        except Exception as e:  # network, disk, Discord: the player only needs to know it failed
            self.done_ids.discard(rid)
            self.last_send = None
            print(f"coopnet: felrapport {rid} misslyckades: {e}", flush=True)
            detail = re.sub(r"[|\r\n]+", "/", str(e))[:120]
            self._event(f"report|0|failed|{rid}|{detail}")
            return
        if which == "last":
            self._mark_sent()
        print(f"coopnet: felrapport {rid} skickad ({len(data)} byte)", flush=True)
        self._event(f"report|0|sent|{rid}")

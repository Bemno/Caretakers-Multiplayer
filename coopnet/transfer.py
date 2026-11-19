"""Save file transfer over the line-based link: the file is cut into base64
chunks that each fit one UDP datagram, and the receiver only exposes the file
once every chunk is in and the hash of the whole matches."""
import base64
import hashlib
import os
import uuid

RAW_CHUNK = 900


def chunks(path, name):
    data = open(path, "rb").read()
    digest = hashlib.sha1(data).hexdigest()
    tid = uuid.uuid4().hex[:8]
    safe = os.path.basename(name.replace("\\", "/"))
    n = max(1, (len(data) + RAW_CHUNK - 1) // RAW_CHUNK)
    return [
        f"file|{tid}|{i}|{n}|{digest}|{safe}|".encode() + base64.b64encode(data[i * RAW_CHUNK:(i + 1) * RAW_CHUNK])
        for i in range(n)
    ]


def parse(line):
    """(tid, index, count) of a chunk line, or None."""
    parts = line.split(b"|", 6)
    if len(parts) != 7 or parts[0] != b"file":
        return None
    return parts[1].decode(), int(parts[2]), int(parts[3])


class Receiver:
    def __init__(self, dest_dir):
        self.dest_dir = dest_dir
        self.pending = {}

    def feed(self, line):
        parts = line.split(b"|", 6)
        if len(parts) != 7 or parts[0] != b"file":
            return None
        tid, i, n, digest, name = parts[1].decode(), int(parts[2]), int(parts[3]), parts[4].decode(), parts[5].decode()
        entry = self.pending.setdefault(tid, {"n": n, "digest": digest, "name": name, "parts": {}})
        entry["parts"][i] = base64.b64decode(parts[6])
        if len(entry["parts"]) < entry["n"]:
            return None
        del self.pending[tid]
        data = b"".join(entry["parts"][k] for k in range(entry["n"]))
        if hashlib.sha1(data).hexdigest() != entry["digest"]:
            return None
        os.makedirs(self.dest_dir, exist_ok=True)
        final = os.path.join(self.dest_dir, os.path.basename(entry["name"]))
        tmp = final + ".part"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, final)
        return final

    def progress(self, tid):
        entry = self.pending.get(tid)
        return (len(entry["parts"]), entry["n"]) if entry else None

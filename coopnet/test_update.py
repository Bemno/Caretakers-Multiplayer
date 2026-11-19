import hashlib
import json
import time

import update

SETUP = b"MZ fake installer"


def release(tag, data=SETUP, digest=None):
    return {"tag_name": tag, "assets": [
        {"name": "Caretakers-Multiplayer-0.9.0-manual.zip", "browser_download_url": "zip", "digest": "sha256:00"},
        {"name": f"Caretakers-Multiplayer-Setup-{tag[1:]}.exe", "browser_download_url": "setup", "size": len(data),
         "digest": digest or "sha256:" + hashlib.sha256(data).hexdigest()},
    ]}


def fake(rel, data=SETUP):
    def fetch(url, dest=None, progress=None):
        if dest is None:
            return json.dumps(rel).encode()
        with open(dest, "wb") as f:
            f.write(data)
        progress(len(data), len(data))
    return fetch


def mod(tmp_path, version="0.2.5", enabled="1"):
    d = tmp_path / "Voyage" / "Binaries" / "Win64" / "ue4ss" / "Mods" / "CoopSync"
    d.mkdir(parents=True)
    if version:
        (d / "update.ini").write_text(f"[update]\nversion={version}\nenabled={enabled}\n")
    return d


def events(u):
    for _ in range(200):
        if not u.busy:
            break
        time.sleep(0.01)
    return [e.decode() for e in u.take_events()]


def test_newer_release_is_offered_and_downloaded(tmp_path):
    u = update.Updater(mod(tmp_path), fake(release("v0.3.0")))
    u.check()
    assert events(u) == ["update|0|available|0.3.0"]
    u.command(["get"])
    ev = events(u)
    assert ev[-1] == "update|0|ready|0.3.0" and "update|0|progress|100" in ev
    assert open(u.ready, "rb").read() == SETUP


def test_same_or_older_is_quiet(tmp_path):
    u = update.Updater(mod(tmp_path), fake(release("v0.2.5")))
    u.check()
    assert events(u) == []


def test_no_ini_means_no_check(tmp_path):
    called = []
    u = update.Updater(mod(tmp_path, version=None), lambda *a, **k: called.append(a))
    u.check()
    assert not u.enabled and called == []


def test_disabled_ini(tmp_path):
    u = update.Updater(mod(tmp_path, enabled="0"), fake(release("v9.0.0")))
    u.check()
    assert events(u) == []


def test_bad_checksum_is_refused(tmp_path):
    u = update.Updater(mod(tmp_path), fake(release("v0.3.0", digest="sha256:" + "0" * 64)))
    u.check()
    events(u)
    u.command(["get"])
    assert events(u)[-1].startswith("update|0|error|checksum")
    assert u.ready is None


def test_game_dir(tmp_path):
    assert update.game_dir(mod(tmp_path)) == tmp_path

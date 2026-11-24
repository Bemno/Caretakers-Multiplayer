import json
import os
import time

import report


def _game(tmp_path, session):
    win64 = tmp_path / "Win64"
    mod = win64 / "ue4ss" / "Mods" / "CoopSync"
    io_dir = mod / "io" / "main"
    io_dir.mkdir(parents=True)
    (win64 / "ue4ss" / "UE4SS.log").write_text(f"ue4ss {session}\n")
    (mod / "coopsync_main.log").write_text(f"coopsync {session}\n")
    (io_dir / "coopnet.log").write_text(f"coopnet {session}\n")
    local = tmp_path / "local"
    (local / "Voyage" / "Saved" / "Crashes").mkdir(parents=True, exist_ok=True)
    return report.Paths(str(io_dir), str(local))


def _age(path, seconds):
    t = time.time() - seconds
    os.utime(path, (t, t))


def test_snapshot_copies_logs_and_overwrites_previous(tmp_path):
    p = _game(tmp_path, "one")
    report.snapshot(p, p.last_dir, time.time() - 60)
    (tmp_path / "Win64" / "ue4ss" / "Mods" / "CoopSync" / "coopsync_main.log").write_text("coopsync two\n")
    os.remove(os.path.join(p.ue4ss_dir, "UE4SS.log"))
    report.snapshot(p, p.last_dir, time.time() - 60)
    assert sorted(os.listdir(p.last_dir)) == ["coopnet.log", "coopsync_main.log", "info.json"]
    with open(os.path.join(p.last_dir, "coopsync_main.log")) as f:
        assert f.read() == "coopsync two\n"


def test_snapshot_picks_crash_dir_after_since(tmp_path):
    p = _game(tmp_path, "one")
    old = os.path.join(p.crashes, "UECC-old")
    new = os.path.join(p.crashes, "UECC-new")
    for d in (old, new):
        os.makedirs(d)
        with open(os.path.join(d, "CrashContext.runtime-xml"), "w") as f:
            f.write(d)
    _age(old, 3600)
    info = report.snapshot(p, p.last_dir, time.time() - 60)
    assert info["crashed"] is True
    assert info["crash_dir"] == "UECC-new"
    assert os.listdir(os.path.join(p.last_dir, "crash")) == ["CrashContext.runtime-xml"]


def test_snapshot_takes_new_ue4ss_dump(tmp_path):
    p = _game(tmp_path, "one")
    for name, age in (("crash_old.dmp", 3600), ("crash_new.dmp", 0)):
        path = os.path.join(p.ue4ss_dir, name)
        with open(path, "wb") as f:
            f.write(b"dmp")
        _age(path, age)
    info = report.snapshot(p, p.last_dir, time.time() - 60)
    assert info["crashed"] is True
    assert "crash_new.dmp" in os.listdir(p.last_dir)
    assert "crash_old.dmp" not in os.listdir(p.last_dir)


def test_crashed_from_exit_code():
    assert report.crashed(0, None, None) is False
    assert report.crashed(None, None, None) is False
    assert report.crashed(1, None, None) is True
    assert report.crashed(0xC0000005, None, None) is True
    assert report.crashed(0, "UECC-x", None) is True


def test_snapshot_writes_info(tmp_path):
    p = _game(tmp_path, "one")
    since = time.time() - 60
    report.snapshot(p, p.last_dir, since, exit_code=0)
    with open(os.path.join(p.last_dir, "info.json")) as f:
        info = json.load(f)
    assert info["crashed"] is False and info["sent"] is False and info["since"] == since


def test_scrub_user_paths():
    win = "C:\\" + "Us" + "ers\\Kalle\\AppData\\x"
    assert report.scrub(win, []) == "<user>\\AppData\\x"
    assert report.scrub("c:/" + "us" + "ers/kalle/AppData", []) == "<user>/AppData"


def test_scrub_steam_id_stable():
    a = report.scrub("join 76561190000000001", [])
    b = report.scrub("from 76561190000000001.", [])
    assert "76561190000000001" not in a + b
    assert a.split()[-1] == b.split()[-1].rstrip(".")
    assert a.split()[-1].startswith("sid-") and len(a.split()[-1]) == 12


def test_scrub_names_and_crash_ids():
    assert report.scrub("Bemno joined, Ox left", ["Bemno", "Ox"]) == "<player1> joined, Ox left"
    xml = "<MachineId>97528F</MachineId><LoginId>abc</LoginId><EpicAccountId>16</EpicAccountId>"
    assert report.scrub(xml, []) == "<MachineId></MachineId><LoginId></LoginId><EpicAccountId></EpicAccountId>"


def _report_dir(tmp_path):
    d = tmp_path / "last"
    d.mkdir()
    (d / "UE4SS.log").write_text("path C:\\" + "Us" + "ers\\Kalle\\x\nlast line\n")
    return d


def test_build_zip_drops_dump_over_limit(tmp_path):
    import io
    import zipfile
    d = _report_dir(tmp_path)
    (d / "crash_1.dmp").write_bytes(os.urandom(2_000_000))
    data, dropped = report.build_zip(str(d), [], limit=1_000_000)
    names = zipfile.ZipFile(io.BytesIO(data)).namelist()
    assert names == ["UE4SS.log"] and dropped == ["crash_1.dmp"]
    data, dropped = report.build_zip(str(d), [])
    assert "crash_1.dmp" in zipfile.ZipFile(io.BytesIO(data)).namelist() and dropped == []


def test_build_zip_tails_and_scrubs_logs(tmp_path):
    import io
    import zipfile
    d = _report_dir(tmp_path)
    (d / "crash").mkdir()
    (d / "crash" / "CrashContext.runtime-xml").write_text("<LoginId>x</LoginId>")
    (d / "big.log").write_bytes(b"x" * 5_000_000 + b"\nthe end\n")
    z = zipfile.ZipFile(io.BytesIO(report.build_zip(str(d), [])[0]))
    big = z.read("big.log")
    assert len(big) <= report.TAIL and big.endswith(b"the end\n")
    assert b"Kalle" not in z.read("UE4SS.log")
    assert z.read("crash/CrashContext.runtime-xml") == b"<LoginId></LoginId>"


class FakePost:
    def __init__(self, fail=None):
        self.calls, self.fail = [], fail

    def __call__(self, url, body, content_type):
        if self.fail:
            raise self.fail
        self.calls.append((url, body, content_type))


def _sender(tmp_path, post, webhook="https://discord.test/hook"):
    p = _game(tmp_path, "one")
    return report.Sender(webhook, p, time.time() - 60, post=post, spawn=lambda f: f()), p


SEND = ["send", "20261123-101500-ab12", "now", "Bemno,Ox", "version=0.2.15 role=host link=steam peer=connected", "the boat flew"]


def test_sender_posts_multipart(tmp_path):
    post = FakePost()
    s, _ = _sender(tmp_path, post)
    s.command(SEND)
    assert s.take_events() == [b"report|0|sent|20261123-101500-ab12"]
    url, body, ctype = post.calls[0]
    assert url == "https://discord.test/hook" and ctype.startswith("multipart/form-data; boundary=")
    payload = json.loads(body.split(b'Content-Type: application/json\r\n\r\n')[1].split(b"\r\n--")[0])
    assert "20261123-101500-ab12" in payload["content"] and "the boat flew" in payload["content"]
    assert "role=host" in payload["content"] and payload["allowed_mentions"] == {"parse": []}
    assert b'filename="report-20261123-101500-ab12-host.zip"' in body
    assert b"Bemno" not in body


def test_sender_failure_and_rate_limit(tmp_path):
    import urllib.error
    s, _ = _sender(tmp_path / "a", FakePost(fail=urllib.error.URLError("offline")))
    s.command(SEND)
    ev = s.take_events()
    assert len(ev) == 1 and ev[0].startswith(b"report|0|failed|20261123-101500-ab12|")
    post = FakePost()
    s, _ = _sender(tmp_path / "b", post)
    s.command(SEND)
    s.command(SEND)
    s.command(["send", "other-id"] + SEND[2:])
    assert len(post.calls) == 1
    assert s.take_events()[1:] == [b"report|0|failed|other-id|too soon"]


def test_sender_without_webhook(tmp_path):
    s, _ = _sender(tmp_path, FakePost(), webhook=None)
    s.command(SEND)
    assert s.take_events() == [b"report|0|disabled"]


def test_sender_empty_text(tmp_path):
    post = FakePost()
    s, _ = _sender(tmp_path, post)
    s.command(SEND[:5] + [""])
    assert b"(no text)" in post.calls[0][1]


def test_last_report_pending_sent_and_dismiss(tmp_path):
    post = FakePost()
    s, p = _sender(tmp_path, post)
    assert s.pending() is None
    report.snapshot(p, p.last_dir, time.time() - 60, exit_code=1)
    assert s.pending().startswith(b"report|0|pending|1|")
    s.command(["send", "id-1", "last", "", "role=guest", "it crashed"])
    assert s.take_events() == [b"report|0|sent|id-1"] and s.pending() is None
    assert b"crash: yes" in post.calls[0][1]
    report.snapshot(p, p.last_dir, time.time() - 60, exit_code=1)
    s.command(["dismiss"])
    assert s.pending() is None


def test_recover_unsaved_previous_run(tmp_path):
    p = _game(tmp_path, "one")
    report.snapshot(p, p.last_dir, time.time() - 600, exit_code=0)
    with open(os.path.join(p.last_dir, "info.json")) as f:
        info = json.load(f)
    info["time"] = time.time() - 300
    with open(os.path.join(p.last_dir, "info.json"), "w") as f:
        json.dump(info, f)
    assert report.recover_unsaved(p) is None
    for path in (p.coopsync_prev, p.coopnet_prev):
        with open(path, "w") as f:
            f.write("unsaved run\n")
    info = report.recover_unsaved(p)
    assert info["crashed"] is True and info["partial"] is True
    assert sorted(os.listdir(p.last_dir)) == ["coopnet.prev.log", "coopsync_main.prev.log", "info.json"]
    assert report.recover_unsaved(p) is None


def test_recover_unsaved_ignores_prev_older_than_snapshot(tmp_path):
    p = _game(tmp_path, "one")
    with open(p.coopsync_prev, "w") as f:
        f.write("old run\n")
    _age(p.coopsync_prev, 600)
    report.snapshot(p, p.last_dir, time.time() - 60, exit_code=0)
    assert report.recover_unsaved(p) is None


def test_send_last_without_snapshot_uses_now(tmp_path):
    post = FakePost()
    s, p = _sender(tmp_path, post)
    s.command(["send", "id-2", "last", "", "role=menu", "no snapshot"])
    assert s.take_events() == [b"report|0|sent|id-2"]
    assert os.path.isdir(p.now_dir)


def test_recover_without_any_snapshot_is_not_a_crash(tmp_path):
    p = _game(tmp_path, "one")
    with open(p.coopsync_prev, "w") as f:
        f.write("log from a version without reports\n")
    assert report.recover_unsaved(p) is None
    assert not os.path.exists(p.last_dir)


def test_snapshot_when_old_dir_cannot_be_removed(tmp_path, monkeypatch):
    p = _game(tmp_path, "one")
    os.makedirs(p.last_dir)
    monkeypatch.setattr(report.shutil, "rmtree", lambda *a, **k: None)
    info = report.snapshot(p, p.last_dir, time.time() - 60, exit_code=0)
    assert info["crashed"] is False


def test_sender_wait_finishes_send_in_flight(tmp_path):
    import threading
    started = threading.Event()

    def slow_post(url, body, ctype):
        started.set()
        time.sleep(0.3)

    p = _game(tmp_path, "one")
    s = report.Sender("https://discord.test/hook", p, time.time() - 60, post=slow_post)
    s.command(SEND)
    started.wait(2)
    s.wait(5)
    assert s.take_events() == [b"report|0|sent|20261123-101500-ab12"]


def test_failure_detail_has_no_newline(tmp_path):
    s, _ = _sender(tmp_path, FakePost(fail=OSError("line one\nline two|x")))
    s.command(SEND)
    ev = s.take_events()[0]
    assert b"\n" not in ev and ev.count(b"|") == 4


def test_bad_report_id_is_refused(tmp_path):
    post = FakePost()
    s, _ = _sender(tmp_path, post)
    s.command(["send", 'x"\r\nevil'] + SEND[2:])
    assert post.calls == [] and s.take_events() == []


def test_peer_request_skips_the_gap_once_per_id(tmp_path):
    post = FakePost()
    s, _ = _sender(tmp_path, post)
    s.command(SEND)
    s.command(["send", "peer-id", "peer"] + SEND[3:])
    s.command(["send", "peer-id", "peer"] + SEND[3:])
    assert len(post.calls) == 2
    assert s.take_events() == [b"report|0|sent|20261123-101500-ab12", b"report|0|sent|peer-id"]


def test_scrub_ip_addresses():
    assert report.scrub("ansluter till 192.168.1.20:47020", []) == "ansluter till <ip>:47020"
    assert report.scrub("lyssnar 0.0.0.0 och 127.0.0.1", []) == "lyssnar 0.0.0.0 och 127.0.0.1"
    assert report.scrub("version 0.2.14", []) == "version 0.2.14"


def test_last_report_scrubs_names_seen_last_session(tmp_path):
    import io
    import zipfile
    post = FakePost()
    s, p = _sender(tmp_path, post)
    with open(p.coopsync_log, "a") as f:
        f.write("gast Oxford anslot\n")
    s.command(["names", "Bemno,Oxford"])
    report.snapshot(p, p.last_dir, time.time() - 60, exit_code=1, names=sorted(s.names))
    s2 = report.Sender("https://discord.test/hook", p, time.time(), post=post, spawn=lambda f: f())
    s2.command(["send", "id-3", "last", "Bemno,", "role=menu", "it crashed"])
    body = post.calls[0][1]
    z = zipfile.ZipFile(io.BytesIO(body[body.index(b"PK\x03\x04"):body.rindex(b"\r\n--")]))
    assert b"Oxford" not in z.read("coopsync_main.log")

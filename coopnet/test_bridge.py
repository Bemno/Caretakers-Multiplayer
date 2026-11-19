import os
import random
import time

import coopnet


class LossyLink(coopnet.UdpLink):
    def __init__(self, listen, peer, loss):
        super().__init__(listen, peer)
        self.loss = loss
        self.rng = random.Random(listen)

    def send(self, data, reliable=True):
        if self.rng.random() >= self.loss:
            super().send(data, reliable)


def _pair(tmp_path, loss=0.0):
    a_dir, b_dir = tmp_path / "a", tmp_path / "b"
    a_dir.mkdir()
    b_dir.mkdir()
    a = coopnet.Bridge(str(a_dir), LossyLink(47101, "127.0.0.1:47102", loss), str(tmp_path / "save_a"))
    b = coopnet.Bridge(str(b_dir), LossyLink(47102, "127.0.0.1:47101", loss), str(tmp_path / "save_b"))
    return a, b


def _run(a, b, until, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        a.step()
        b.step()
        if until():
            return True
        time.sleep(0.002)
    return False


def _lua(bridge, line):
    with open(bridge.out_path, "ab") as f:
        f.write(line.encode("utf-8") + b"\n")


def _in(bridge):
    return open(bridge.in_path, "rb").read().decode("utf-8")


def test_lines_pass_through(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "door|1|x|y")
    assert _run(a, b, lambda: "door|1|x|y" in _in(b))
    a.link.sock.close()
    b.link.sock.close()


def test_file_over_lossy_udp(tmp_path):
    a, b = _pair(tmp_path, loss=0.3)
    src = tmp_path / "w.sav"
    src.write_bytes(os.urandom(600_000))
    _lua(a, f"sendfile|7|{src}|_klient.sav")
    assert _run(a, b, lambda: "savefile|0|" in _in(b) and "filesent|0|_klient.sav" in _in(a))
    assert (tmp_path / "save_b" / "_klient.sav").read_bytes() == src.read_bytes()
    assert "fileprogress|0|" in _in(b)
    a.link.sock.close()
    b.link.sock.close()


def test_missing_file_reports_error(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, f"sendfile|1|{tmp_path / 'finns-inte.sav'}|x.sav")
    a.step()
    assert "fileerror|0|" in _in(a)
    a.link.sock.close()
    b.link.sock.close()


class FakeSteam(coopnet.UdpLink):
    me = 76561190000000001

    def __init__(self, listen, peer):
        super().__init__(listen, peer)
        self.invited, self.joined = [], None

    def friends(self):
        return [(111, "Kompis"), (222, "Annan|namn")]

    def invite(self, fid, connect):
        self.invited.append((fid, connect))
        return True

    def join(self, sid):
        self.joined = sid

    def status(self, sid):
        return {111: ("Kompis", True), 333: ("Borta", False)}.get(sid, ("?", False))

    def take_events(self):
        return []


def _steam_bridge(tmp_path):
    d = tmp_path / "s"
    d.mkdir()
    return coopnet.Bridge(str(d), FakeSteam(47111, "127.0.0.1:47112"), str(tmp_path / "save"))


def test_steam_friends_and_invite(tmp_path):
    b = _steam_bridge(tmp_path)
    _lua(b, "steam|1|friends")
    _lua(b, "steam|2|invite|111")
    _lua(b, "steam|3|join|222")
    b.step()
    out = _in(b)
    assert "steam|0|friend|111|Kompis" in out
    assert "steam|0|friend|222|Annan/namn" in out
    assert "steam|0|friendsdone" in out
    assert b.link.invited == [(111, "-coopJoin=76561190000000001")]
    assert "steam|0|invited|111|1" in out
    assert b.link.joined == 222
    b.link.sock.close()


def test_steam_status_of_recent_hosts(tmp_path):
    b = _steam_bridge(tmp_path)
    _lua(b, "steam|1|status|111,333")
    b.step()
    out = _in(b)
    assert "steam|0|status|111|Kompis|1" in out
    assert "steam|0|status|333|Borta|0" in out
    b.link.sock.close()


def test_steam_clipboard_roundtrip(tmp_path):
    import clip
    old = clip.read()
    try:
        b = _steam_bridge(tmp_path)
        _lua(b, "steam|1|clip")
        b.step()
        assert clip.read().startswith("TLC-")
        _lua(b, "steam|2|readclip")
        b.step()
        assert "steam|0|clipcode|76561190000000001" in _in(b)
        clip.write("inget här")
        _lua(b, "steam|3|readclip")
        b.step()
        assert "steam|0|clipbad" in _in(b)
        b.link.sock.close()
    finally:
        clip.write(old or "")


def test_steam_commands_on_udp_report_error(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "steam|1|friends")
    a.step()
    assert "steam|0|error|" in _in(a)
    a.link.sock.close()
    b.link.sock.close()


def test_save_commands(tmp_path):
    import saves
    sid = "76561190000000001"
    root = tmp_path / "SaveGames"
    (root / sid).mkdir(parents=True)
    (root / sid / f"{sid}_5.sav").write_bytes(b"fem")
    (root / sid / f"{sid}_AutoSave_0.sav").write_bytes(b"spelare")
    d = tmp_path / "io"
    d.mkdir()
    b = coopnet.Bridge(str(d), coopnet.UdpLink(47121, "127.0.0.1:47122"), str(root / "Coop"))
    _lua(b, "save|1|splist")
    _lua(b, "save|2|import|5")
    _lua(b, "save|3|list")
    _lua(b, "save|4|guard|on")
    _lua(b, "save|6|delete|finns-inte")
    b.step()
    out = _in(b)
    assert "save|0|sp|5|" in out and "save|0|spdone" in out
    assert "save|0|error|" in out
    name = out.split("save|0|imported|")[1].split("\n")[0]
    assert f"save|0|world|{name}|" in out and "save|0|listdone" in out
    (root / sid / f"{sid}_AutoSave_0.sav").write_bytes(b"autosparning i coop")
    b.last_guard = 0
    b.step()
    assert (root / sid / f"{sid}_AutoSave_0.sav").read_bytes() == b"spelare"
    assert "save|0|guarded|" in _in(b)
    _lua(b, f"save|8|rename|{name}|Huset")
    _lua(b, "save|7|delete|Huset")
    _lua(b, "save|5|guard|off")
    b.step()
    assert f"save|0|renamed|{name}|Huset" in _in(b)
    assert "save|0|deleted|Huset" in _in(b)
    assert not (root / "Coop" / f"{name}.sav").exists()
    assert not (root / "Coop" / saves.VAULT).exists()
    b.link.sock.close()


def test_mouse_button_changes_reach_lua(tmp_path):
    d = tmp_path / "m"
    d.mkdir()
    b = coopnet.Bridge(str(d), coopnet.UdpLink(47131, "127.0.0.1:47132"), str(tmp_path / "save"))
    states = iter([False, True, True, False])
    b.mouse_down = lambda: next(states)
    for _ in range(4):
        b.step()
    assert _in(b).splitlines() == ["mouse|0|1", "mouse|0|0"]
    b.link.sock.close()


def test_friend_status_over_udp(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "steam|1|approved|udp:47102")
    _lua(a, "steam|2|state|host|testvard|0.3")
    _lua(b, "steam|1|approved|udp:47101")
    _lua(b, "steam|2|ask|udp:47101")
    assert _run(a, b, lambda: "steam|0|friendstate|udp:47101|host|testvard|0.3" in _in(b))
    a.link.sock.close()
    b.link.sock.close()


def test_unapproved_gets_nothing(tmp_path):
    a, b = _pair(tmp_path)
    _lua(b, "steam|1|approved|udp:47101")
    _lua(b, "steam|2|ask|udp:47101")
    assert not _run(a, b, lambda: "friendstate" in _in(b), seconds=1)
    a.link.sock.close()
    b.link.sock.close()


def test_request_over_udp(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "steam|1|qsend|udp:47102|req|Kalle")
    assert _run(a, b, lambda: "steam|0|request|udp:47101|Kalle" in _in(b))
    a.link.sock.close()
    b.link.sock.close()


def test_q_never_reaches_lua_as_game_line(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "steam|1|qsend|udp:47102|bye")
    _lua(a, "door|2|x")
    assert _run(a, b, lambda: "door|2|x" in _in(b))
    assert "\nq|" not in "\n" + _in(b)
    assert "steam|0|removed|udp:47101" in _in(b)
    a.link.sock.close()
    b.link.sock.close()


def test_my_id_and_resolve_on_udp(tmp_path):
    a, b = _pair(tmp_path)
    assert a.link.my_id == "udp:47101"
    _lua(a, "steam|1|resolve| udp:47102 ")
    _lua(a, "steam|2|resolve|hej")
    a.step()
    out = _in(a)
    assert "steam|0|resolved|udp:47102| udp:47102 " in out
    assert "steam|0|resolved||hej" in out
    a.link.sock.close()
    b.link.sock.close()


def test_lan_host_and_join(tmp_path):
    import lan
    a_dir, b_dir = tmp_path / "a", tmp_path / "b"
    a_dir.mkdir()
    b_dir.mkdir()
    a = coopnet.Bridge(str(a_dir), coopnet.UdpLink(47141, "127.0.0.1:47142"), str(tmp_path / "sa"),
                       lan=lan.LanLink(game_port=47240, listen_port=47251, announce_to=("127.0.0.1", 47252)))
    b = coopnet.Bridge(str(b_dir), coopnet.UdpLink(47142, "127.0.0.1:47141"), str(tmp_path / "sb"),
                       lan=lan.LanLink(game_port=0, listen_port=47252, announce_to=("127.0.0.1", 47251)))
    try:
        _lua(a, "steam|1|lanhost|hemma|Bemno|0.3")
        assert _run(a, b, lambda: "steam|0|lanserver|127.0.0.1:47240|hemma|Bemno|0.3" in _in(b))
        _lua(b, "steam|2|join|lan:127.0.0.1:47240")
        _lua(b, "hello|3|0.3||Gast")
        assert _run(a, b, lambda: "hello|3|0.3||Gast" in _in(a))
        _lua(a, "welcome|4|0.3")
        assert _run(a, b, lambda: "welcome|4|0.3" in _in(b))
        _lua(a, "steam|5|leave")
        _run(a, b, lambda: False, seconds=0.3)
        assert a.game is a.link and a.lan.peer is None
    finally:
        for x in (a, b):
            x.link.sock.close()
            x.lan.close()


def test_whoami_repeats_my_id(tmp_path):
    a, b = _pair(tmp_path)
    _lua(a, "steam|1|whoami")
    a.step()
    assert "steam|0|me|udp:47101|" in _in(a)
    a.link.sock.close()
    b.link.sock.close()

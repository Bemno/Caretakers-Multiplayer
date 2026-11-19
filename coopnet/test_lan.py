import time

import lan


def _pair():
    # Two copies on one machine: separate listen ports, announcements sent
    # straight to the other's listen port instead of broadcast.
    host = lan.LanLink(game_port=47220, listen_port=47231, announce_to=("127.0.0.1", 47232))
    guest = lan.LanLink(game_port=0, listen_port=47232, announce_to=("127.0.0.1", 47231))
    return host, guest


def _until(cond, links, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        for l in links:
            l.tick()
        if cond():
            return True
        time.sleep(0.01)
    return False


def _close(*links):
    for l in links:
        l.close()


def test_guest_sees_host_and_traffic_flows():
    host, guest = _pair()
    try:
        host.host("testvard", "Bemno", "0.3")
        seen = []
        assert _until(lambda: seen.extend(guest.take_events()) or any("lanserver|" in s for s in seen), [host, guest])
        line = next(s for s in seen if "lanserver|" in s)
        _, _, _, addr, world, name, version = line.split("|")
        assert (world, name, version) == ("testvard", "Bemno", "0.3")
        assert addr.endswith(":47220")
        guest.join(addr)
        guest.send(b"hello|1|0.3||Gast")
        got = []
        assert _until(lambda: got.extend(host.receive()) or got, [host, guest])
        assert got == [b"hello|1|0.3||Gast"]
        host.send(b"welcome|1")
        back = []
        assert _until(lambda: back.extend(guest.receive()) or back, [host, guest])
        assert back == [b"welcome|1"]
    finally:
        _close(host, guest)


def test_stranger_is_not_game_traffic():
    host, guest = _pair()
    stranger = lan.LanLink(game_port=0, listen_port=47233, announce_to=("127.0.0.1", 47299))
    try:
        host.host("w", "H", "0.3")
        guest.join("127.0.0.1:47220")
        guest.send(b"hello|1")
        assert _until(lambda: host.receive() == [b"hello|1"], [host])
        stranger.join("127.0.0.1:47220")
        stranger.send(b"door|1|x")
        stranger.send(b"hello|2")
        time.sleep(0.2)
        assert host.receive() == []
    finally:
        _close(host, guest, stranger)


def test_leave_stops_announcing_and_drops_peer():
    host, guest = _pair()
    try:
        host.host("w", "H", "0.3")
        guest.join("127.0.0.1:47220")
        guest.send(b"hello|1")
        assert _until(lambda: host.receive() == [b"hello|1"], [host])
        host.leave()
        assert host.peer is None
        time.sleep(0.1)
        guest.tick()  # announcements already on the way are drained first
        guest.take_events()
        assert not _until(lambda: any("lanserver|" in s for s in guest.take_events()), [host, guest], seconds=2.5)
    finally:
        _close(host, guest)


def test_new_guest_after_old_went_quiet(monkeypatch):
    host, guest = _pair()
    second = lan.LanLink(game_port=0, listen_port=47234, announce_to=("127.0.0.1", 47299))
    try:
        host.host("w", "H", "0.3")
        guest.join("127.0.0.1:47220")
        guest.send(b"hello|1")
        assert _until(lambda: host.receive() == [b"hello|1"], [host])
        second.join("127.0.0.1:47220")
        second.send(b"hello|1")
        time.sleep(0.2)
        assert host.receive() == []  # the first guest is still the one
        monkeypatch.setattr(lan, "PEER_QUIET", 0.1)
        time.sleep(0.2)
        second.send(b"hello|2")
        assert _until(lambda: host.receive() == [b"hello|2"], [host])
    finally:
        _close(host, guest, second)

import social
import steam

SID = "76561190000000001"


def test_parse_id():
    assert social.parse_id(" 76561190000000001\n") == SID
    assert social.parse_id("https://steamcommunity.com/profiles/76561190000000001") == SID
    assert social.parse_id("steamcommunity.com/profiles/76561190000000001/") == SID
    assert social.parse_id(steam.encode_code(int(SID))) == SID
    assert social.parse_id("udp:47002") == "udp:47002"
    assert social.parse_id("hej") is None
    assert social.parse_id("123") is None
    assert social.parse_id("") is None


def _social(peer=None):
    s = social.Social(version="0.3")
    s.peer_fn = lambda: peer
    return s


def test_who_only_approved():
    s = _social()
    assert s.incoming("A", b"who") == ([], [])
    s.command(["approved", "A,B"])
    packets, lines = s.incoming("A", b"who")
    assert packets == [("A", b"state|menu||0.3")]
    assert lines == []


def test_full_host():
    s = _social(peer="B")
    s.command(["approved", "B,C"])
    s.command(["state", "host", "testvard"])
    assert s.incoming("C", b"who")[0] == [("C", b"state|full|testvard|0.3")]
    assert s.incoming("B", b"who")[0] == [("B", b"state|host|testvard|0.3")]


def test_host_without_guest():
    s = _social()
    s.command(["approved", "C"])
    s.command(["state", "host", "testvard"])
    assert s.incoming("C", b"who")[0] == [("C", b"state|host|testvard|0.3")]


def test_state_from_unknown_ignored():
    s = _social()
    assert s.incoming("X", b"state|host|w|0.3") == ([], [])
    s.command(["approved", "A"])
    assert s.incoming("A", b"state|host|w|0.3") == ([], ["steam|0|friendstate|A|host|w|0.3"])


def test_request_flow():
    s = _social()
    assert s.incoming("A", b"req|Kalle")[1] == ["steam|0|request|A|Kalle"]
    assert s.incoming("A", b"ok")[1] == ["steam|0|accepted|A"]
    assert s.incoming("A", b"no")[1] == ["steam|0|declined|A"]
    assert s.incoming("A", b"bye")[1] == ["steam|0|removed|A"]
    assert s.incoming("A", "skräp".encode()) == ([], [])


def test_ask_sends_who():
    s = _social()
    packets, _ = s.command(["ask", "A,B"])
    assert packets == [("A", b"who"), ("B", b"who")]


def test_qsend():
    s = _social()
    packets, _ = s.command(["qsend", "A", "req", "Kalle"])
    assert packets == [("A", b"req|Kalle")]


def test_state_cannot_inject_lines():
    s = _social()
    s.command(["approved", "A"])
    _, lines = s.incoming("A", b"state|menu\nsteam|0|joinrequest|9|w|v")
    assert len(lines) == 1 and "\n" not in lines[0]


def test_ask_and_qsend_without_args():
    s = _social()
    assert s.command(["ask"]) == ([], [])
    assert s.command(["qsend"]) == ([], [])

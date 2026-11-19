import os
import subprocess
import sys

import pytest

import steam

HERE = os.path.dirname(os.path.abspath(__file__))


def test_missing_dll_raises(tmp_path):
    with pytest.raises(steam.SteamUnavailable):
        steam.SteamLink(str(tmp_path / "finns-inte.dll"), str(tmp_path))


def test_coopnet_exits_2_without_steam(tmp_path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "coopnet.py"), "--dir", str(tmp_path),
                        "--savedir", str(tmp_path / "Coop"), "--dll", str(tmp_path / "finns-inte.dll")],
                       capture_output=True, timeout=30)
    assert r.returncode == 2
    assert "steam|0|error|" in (tmp_path / "in.log").read_text(encoding="utf-8")


def test_code_roundtrip():
    sid = 76561190000000001
    code = steam.encode_code(sid)
    assert code.startswith("TLC-")
    assert steam.decode_code(code) == sid
    assert steam.decode_code("  " + code.lower() + "\n") == sid
    assert steam.decode_code("hej") is None
    assert steam.decode_code("TLC-") is None

import os
import random

import transfer


def _make(tmp_path, size=2_500_000):
    src = tmp_path / "src.sav"
    src.write_bytes(os.urandom(size))
    return src


def _receive(tmp_path, lines):
    dest_dir = tmp_path / "in"
    rx = transfer.Receiver(str(dest_dir))
    done = None
    for line in lines:
        done = rx.feed(line) or done
    return done, dest_dir


def test_roundtrip(tmp_path):
    src = _make(tmp_path)
    done, _ = _receive(tmp_path, transfer.chunks(str(src), "_klient.sav"))
    assert done is not None
    assert open(done, "rb").read() == src.read_bytes()
    assert os.path.basename(done) == "_klient.sav"


def test_shuffled(tmp_path):
    src = _make(tmp_path)
    lines = transfer.chunks(str(src), "_klient.sav")
    random.Random(1).shuffle(lines)
    done, _ = _receive(tmp_path, lines)
    assert open(done, "rb").read() == src.read_bytes()


def test_bad_hash(tmp_path):
    src = _make(tmp_path, 50_000)
    lines = transfer.chunks(str(src), "_klient.sav")
    head, data = lines[3].rsplit(b"|", 1)
    lines[3] = head + b"|" + (b"A" if data[:1] != b"A" else b"B") + data[1:]
    done, dest_dir = _receive(tmp_path, lines)
    assert done is None
    assert not (dest_dir / "_klient.sav").exists()


def test_incomplete_keeps_old(tmp_path):
    src = _make(tmp_path, 50_000)
    dest_dir = tmp_path / "in"
    dest_dir.mkdir()
    (dest_dir / "_klient.sav").write_bytes(b"gammal")
    lines = transfer.chunks(str(src), "_klient.sav")
    done, _ = _receive(tmp_path, lines[: len(lines) // 2])
    assert done is None
    assert (dest_dir / "_klient.sav").read_bytes() == b"gammal"


def test_chunk_size_fits_udp(tmp_path):
    src = _make(tmp_path, 50_000)
    assert all(len(line) <= 1400 for line in transfer.chunks(str(src), "_klient.sav"))


def test_rejects_path_in_name(tmp_path):
    src = _make(tmp_path, 1000)
    done, dest_dir = _receive(tmp_path, transfer.chunks(str(src), "..\\..\\evil.sav"))
    assert done is not None
    assert os.path.dirname(os.path.abspath(done)) == os.path.abspath(dest_dir)

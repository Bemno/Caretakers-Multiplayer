import os
import time

import saves

SID = "76561190000000001"


def _tree(tmp_path):
    root = tmp_path / "SaveGames"
    sp = root / SID
    sp.mkdir(parents=True)
    store = tmp_path / saves.STORE
    store.mkdir()
    for n in (0, 1, 5):
        (sp / f"{SID}_{n}.sav").write_bytes(b"sp%d" % n)
    (sp / f"{SID}_AutoSave_0.sav").write_bytes(b"spelarens autosave")
    backups = tmp_path / "SaveGameBackups" / SID
    backups.mkdir(parents=True)
    (backups / f"{SID}_AutoSave_0_2026-11-09_21_57_09.sav").write_bytes(b"gammal backup")
    (store / "a.sav").write_bytes(b"a")
    (store / "_klient.sav").write_bytes(b"k")
    return saves.Saves(str(root / "Coop"))


def test_list_worlds_hides_client_copy(tmp_path):
    s = _tree(tmp_path)
    assert [name for name, _ in s.worlds()] == ["a"]


def test_list_singleplayer_slots(tmp_path):
    s = _tree(tmp_path)
    assert [n for n, _ in s.sp_slots()] == [0, 1, 5]


def test_delete_moves_world_aside(tmp_path):
    s = _tree(tmp_path)
    s.delete("a")
    assert s.worlds() == []
    kept = os.listdir(os.path.join(s.store, saves.TRASH))
    assert len(kept) == 1 and kept[0].startswith("a_")


def test_delete_refuses_client_copy_and_paths(tmp_path):
    import pytest
    s = _tree(tmp_path)
    (tmp_path / saves.STORE / "sub").mkdir()
    (tmp_path / saves.STORE / "sub" / "b.sav").write_bytes(b"b")
    for bad in ("_klient", "../a", "sub\\b", "sub/b", "finns-inte"):
        with pytest.raises((ValueError, FileNotFoundError)):
            s.delete(bad)
    assert [n for n, _ in s.worlds()] == ["a"]
    assert (tmp_path / saves.STORE / "sub" / "b.sav").exists()


def test_rename_world(tmp_path):
    s = _tree(tmp_path)
    s.rename("a", "Huset")
    assert [n for n, _ in s.worlds()] == ["Huset"]


def test_rename_refuses_taken_and_bad_names(tmp_path):
    import pytest
    s = _tree(tmp_path)
    (tmp_path / saves.STORE / "b.sav").write_bytes(b"b")
    for old, new in (("a", "b"), ("a", "../x"), ("a", ""), ("a", "_klient"), ("finns-inte", "c")):
        with pytest.raises((ValueError, FileNotFoundError, FileExistsError)):
            s.rename(old, new)
    assert sorted(n for n, _ in s.worlds()) == ["a", "b"]


def test_import_copies_and_leaves_original(tmp_path):
    s = _tree(tmp_path)
    name = s.import_slot(5)
    assert name.endswith("_import")
    assert (tmp_path / saves.STORE / f"{name}.sav").read_bytes() == b"sp5"
    assert (tmp_path / "SaveGames" / SID / f"{SID}_5.sav").read_bytes() == b"sp5"


def test_import_twice_same_minute_gets_new_name(tmp_path):
    s = _tree(tmp_path)
    assert s.import_slot(5) != s.import_slot(5)


def test_guard_restores_autosave_and_backups(tmp_path):
    s = _tree(tmp_path)
    s.guard_on()
    sp = tmp_path / "SaveGames" / SID
    backups = tmp_path / "SaveGameBackups" / SID
    time.sleep(0.05)
    (sp / f"{SID}_AutoSave_0.sav").write_bytes(b"coop skrev har")
    (sp / f"{SID}_AutoSave_1.sav").write_bytes(b"ny autosave")
    old_backup = backups / f"{SID}_AutoSave_0_2026-11-09_21_57_09.sav"
    old_backup.unlink()
    (backups / f"{SID}_AutoSave_0_2026-11-10_19_05_28.sav").write_bytes(b"ny backup")
    restored = s.guard_check()
    assert restored
    assert (sp / f"{SID}_AutoSave_0.sav").read_bytes() == b"spelarens autosave"
    assert not (sp / f"{SID}_AutoSave_1.sav").exists()
    assert old_backup.read_bytes() == b"gammal backup"
    assert sorted(os.listdir(backups)) == [old_backup.name]
    assert (sp / f"{SID}_1.sav").read_bytes() == b"sp1"


def test_guard_restores_singleplayer_slots_saved_from_the_game_menu(tmp_path):
    s = _tree(tmp_path)
    s.guard_on()
    sp = tmp_path / "SaveGames" / SID
    time.sleep(0.05)
    (sp / f"{SID}_1.sav").write_bytes(b"coop-varlden over spelarens plats")
    (sp / f"{SID}_4.sav").write_bytes(b"ny plats fran coop")
    s.guard_check()
    assert (sp / f"{SID}_1.sav").read_bytes() == b"sp1"
    assert not (sp / f"{SID}_4.sav").exists()


def test_guard_leaves_untouched_files_alone(tmp_path):
    s = _tree(tmp_path)
    s.guard_on()
    assert s.guard_check() == []


def test_guard_survives_restart_and_off_cleans_up(tmp_path):
    s = _tree(tmp_path)
    s.guard_on()
    sp = tmp_path / "SaveGames" / SID
    (sp / f"{SID}_AutoSave_0.sav").write_bytes(b"coop skrev har")
    s2 = saves.Saves(str(tmp_path / "SaveGames" / "Coop"))
    assert s2.recover_leftover()
    assert (sp / f"{SID}_AutoSave_0.sav").read_bytes() == b"spelarens autosave"
    assert not (tmp_path / saves.STORE / ".vakt").exists()
    assert s2.recover_leftover() == []


def test_worlds_are_outside_savegames_between_sessions(tmp_path):
    s = _tree(tmp_path)
    coop = tmp_path / "SaveGames" / "Coop"
    assert not coop.exists()
    # The guest receives a new client copy before the session starts.
    coop.mkdir()
    (coop / "_klient.sav").write_bytes(b"ny kopia")
    s.guard_on()
    assert (coop / "a.sav").read_bytes() == b"a"
    assert (coop / "_klient.sav").read_bytes() == b"ny kopia"
    assert [n for n, _ in s.worlds()] == ["a"]
    (coop / "a.sav").write_bytes(b"a sparad")
    backups = tmp_path / "SaveGameBackups" / "Coop"
    backups.mkdir(parents=True)
    (backups / "a_2026.sav").write_bytes(b"spelets kopia")
    s.guard_off()
    assert not coop.exists()
    assert not backups.exists()
    store = tmp_path / saves.STORE
    assert (store / "a.sav").read_bytes() == b"a sparad"
    assert (store / "_klient.sav").read_bytes() == b"ny kopia"
    assert (store / saves.BACKUPS / "a_2026.sav").exists()
    assert [n for n, _ in s.worlds()] == ["a"]


def test_leftover_session_moves_worlds_out_and_old_vault_along(tmp_path):
    s = _tree(tmp_path)
    s.guard_on()
    sp = tmp_path / "SaveGames" / SID
    (sp / f"{SID}_1.sav").write_bytes(b"skrivet i coop")
    s2 = saves.Saves(str(tmp_path / "SaveGames" / "Coop"))
    s2.recover_leftover()
    assert (sp / f"{SID}_1.sav").read_bytes() == b"sp1"
    assert not (tmp_path / "SaveGames" / "Coop").exists()
    assert (tmp_path / saves.STORE / "a.sav").exists()

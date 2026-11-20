"""Multiplayer worlds, imports from singleplayer slots, and the guard that keeps
a multiplayer session from changing singleplayer files.

Between sessions the worlds live in Saved/CoopWorlds, outside SaveGames, so
singleplayer never sees them: the game's "last save" (Continue) picked the
multiplayer client copy (2026-11-19). A session moves them into SaveGames/Coop,
where the game loads and saves them as slot "Coop/<name>", and its end moves
them out again, with the backups the game made of them.

The game's autosave writes <steamid>/<steamid>_AutoSave_N.sav and rotates
SaveGameBackups/<steamid>/, and its save menu writes the numbered singleplayer
slots. The guard copies all those files to CoopWorlds/.vakt when a session
starts and puts them back whenever they change. The copy lives on disk so a
crash mid-session can be undone the next time coopnet starts."""
import json
import os
import re
import shutil
import time

CLIENT = "_klient"
VAULT = ".vakt"
TRASH = ".borttagna"
BACKUPS = ".kopior"
STORE = "CoopWorlds"


def _move_all(src, dst, skip=()):
    """Moves everything in src into dst, replacing files of the same name."""
    if not os.path.isdir(src):
        return
    os.makedirs(dst, exist_ok=True)
    # On the test bench both games' coopnet share the folder; the other one may
    # have moved it away between the check and the listing.
    try:
        names = os.listdir(src)
    except FileNotFoundError:
        return
    for f in names:
        if f in skip:
            continue
        a, b = os.path.join(src, f), os.path.join(dst, f)
        if os.path.isdir(a):
            _move_all(a, b)
            shutil.rmtree(a, ignore_errors=True)
        else:
            os.replace(a, b)


class Saves:
    def __init__(self, coop_dir, store_dir=None):
        self.coop = coop_dir
        self.root = os.path.dirname(coop_dir)
        saved = os.path.dirname(self.root)
        self.backup_root = os.path.join(saved, "SaveGameBackups")
        self.store = store_dir or os.path.join(saved, STORE)
        self.vault = os.path.join(self.store, VAULT)
        self.in_session = False
        os.makedirs(self.store, exist_ok=True)
        # The guard's copy lived in Coop/.vakt before the worlds moved out.
        old_vault = os.path.join(coop_dir, VAULT)
        if os.path.isdir(old_vault) and not os.path.isdir(self.vault):
            shutil.move(old_vault, self.vault)

    def cur(self):
        """Where the worlds are now: SaveGames/Coop during a session, else the store."""
        return self.coop if self.in_session else self.store

    def _ids(self):
        if not os.path.isdir(self.root):
            return []
        return [d for d in os.listdir(self.root) if d.isdigit() and os.path.isdir(os.path.join(self.root, d))]

    def worlds(self):
        out = []
        d = self.cur()
        for f in os.listdir(d) if os.path.isdir(d) else []:
            name, ext = os.path.splitext(f)
            if ext == ".sav" and name != CLIENT:
                out.append((name, os.path.getmtime(os.path.join(d, f))))
        return sorted(out, key=lambda w: -w[1])

    def sp_slots(self):
        out = []
        for sid in self._ids():
            for f in os.listdir(os.path.join(self.root, sid)):
                m = re.fullmatch(re.escape(sid) + r"_(\d+)\.sav", f)
                if m:
                    out.append((int(m.group(1)), os.path.getmtime(os.path.join(self.root, sid, f))))
        return sorted(out)

    def import_slot(self, index):
        for sid in self._ids():
            src = os.path.join(self.root, sid, f"{sid}_{index}.sav")
            if os.path.isfile(src):
                base = time.strftime("%Y-%m-%d_%H%M") + "_import"
                name, n = base, 2
                while os.path.exists(os.path.join(self.cur(), name + ".sav")):
                    name, n = f"{base}{n}", n + 1
                shutil.copy2(src, os.path.join(self.cur(), name + ".sav"))
                return name
        raise FileNotFoundError(f"plats {index} finns inte")

    def _path(self, name):
        """The file of a world, after checking the name cannot leave Coop/."""
        if name == CLIENT or not re.fullmatch(r'[^\\/:*?"<>|.][^\\/:*?"<>|]*', name):
            raise ValueError(f"ogiltigt namn {name!r}")
        return os.path.join(self.cur(), name + ".sav")

    def _existing(self, name):
        path = self._path(name)
        if not os.path.isfile(path):
            raise FileNotFoundError(f"{name} finns inte")
        return path

    def rename(self, old, new):
        src, dst = self._existing(old), self._path(new.strip())
        if os.path.exists(dst):
            raise FileExistsError(f"{new} finns redan")
        os.rename(src, dst)

    def delete(self, name):
        """Moves a world to Coop/.borttagna instead of erasing it, so a wrong
        click can be undone by hand."""
        src = self._existing(name)
        trash = os.path.join(self.store, TRASH)
        os.makedirs(trash, exist_ok=True)
        shutil.move(src, os.path.join(trash, f"{name}_{time.strftime('%Y%m%d_%H%M%S')}.sav"))

    # --- guard -----------------------------------------------------------

    def _watched(self):
        """Absolute paths of every file the guard protects, as they are now."""
        files = []
        for sid in self._ids():
            d = os.path.join(self.root, sid)
            # Every singleplayer file: the game's own save menu writes numbered
            # slots, and the autosave always goes to AutoSave_N.
            files += [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".sav")]
            b = os.path.join(self.backup_root, sid)
            if os.path.isdir(b):
                files += [os.path.join(b, f) for f in os.listdir(b)]
        return files

    def _watched_dirs(self):
        dirs = []
        for sid in self._ids():
            dirs.append((os.path.join(self.root, sid), ".sav"))
            dirs.append((os.path.join(self.backup_root, sid), ""))
        return dirs

    def guard_on(self):
        if not os.path.exists(os.path.join(self.vault, "manifest.json")):
            os.makedirs(self.vault, exist_ok=True)
            manifest = {}
            for i, path in enumerate(self._watched()):
                copy = os.path.join(self.vault, f"{i}.sav")
                shutil.copy2(path, copy)
                st = os.stat(path)
                manifest[path] = {"copy": copy, "size": st.st_size, "mtime": st.st_mtime}
            manifest["_dirs"] = self._watched_dirs()
            with open(os.path.join(self.vault, "manifest.json"), "w", encoding="utf-8") as f:
                json.dump(manifest, f)
        else:
            self.guard_check()
        # The client copy is not moved in: the guest has just received a new one.
        _move_all(self.store, self.coop, skip=(VAULT, TRASH, BACKUPS, CLIENT + ".sav"))
        self.in_session = True

    def guard_check(self):
        """Puts protected files back; returns the paths it touched."""
        mpath = os.path.join(self.vault, "manifest.json")
        if not os.path.exists(mpath):
            return []
        with open(mpath, encoding="utf-8") as f:
            manifest = json.load(f)
        dirs = manifest.pop("_dirs")
        touched = []
        for path, info in manifest.items():
            if os.path.exists(path):
                st = os.stat(path)
                if st.st_size == info["size"] and st.st_mtime == info["mtime"]:
                    continue
            shutil.copy2(info["copy"], path)
            touched.append(path)
        for d, marker in dirs:
            if not os.path.isdir(d):
                continue
            for f in os.listdir(d):
                path = os.path.join(d, f)
                if marker in f and path not in manifest:
                    os.remove(path)
                    touched.append(path)
        return touched

    def guard_off(self):
        """Ends a session: the worlds, the client copy and the game's backups of them
        leave SaveGames, and the singleplayer guard is dropped."""
        _move_all(self.coop, self.store)
        shutil.rmtree(self.coop, ignore_errors=True)
        _move_all(os.path.join(self.backup_root, "Coop"), os.path.join(self.store, BACKUPS))
        shutil.rmtree(os.path.join(self.backup_root, "Coop"), ignore_errors=True)
        shutil.rmtree(self.vault, ignore_errors=True)
        self.in_session = False

    def recover_leftover(self):
        touched = self.guard_check()
        self.guard_off()
        return touched

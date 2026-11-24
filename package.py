"""Builds the release files into dist/. Run by the GitHub Actions release workflow, and by publish.py --dry.

py -3.13 package.py X.Y.Z

UE4SS is not stored in the repo: the official release is downloaded and its SHA-256 checked,
so the installer carries the exact files from github.com/UE4SS-RE/RE-UE4SS.
"""
import hashlib, os, pathlib, shutil, subprocess, sys, tempfile, urllib.request, zipfile

ROOT = pathlib.Path(__file__).resolve().parent
DIST = ROOT / "dist"
UE4SS_URL = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v4.0.0/UE4SS_v4.0.0.zip"
UE4SS_SHA256 = "251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45"
UE4SS_DIR = ROOT / "installer" / "ue4ss"
SCRIPTS = ROOT / "mod" / "CoopSync" / "Scripts"
COOPNET = ROOT / "mod" / "CoopSync" / "coopnet"
MOD = "Voyage/Binaries/Win64/ue4ss/Mods/CoopSync"
ISCC = [
    r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    r"C:\Program Files\Inno Setup 6\ISCC.exe",
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Inno Setup 6", "ISCC.exe"),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch_ue4ss():
    cache = pathlib.Path(tempfile.gettempdir()) / UE4SS_URL.rsplit("/", 1)[1]
    if not cache.exists() or sha256(cache) != UE4SS_SHA256:
        print("Downloading", UE4SS_URL)
        urllib.request.urlretrieve(UE4SS_URL, cache)
    if sha256(cache) != UE4SS_SHA256:
        sys.exit(f"UE4SS download does not match the pinned SHA-256: {cache}")
    shutil.rmtree(UE4SS_DIR, ignore_errors=True)
    with zipfile.ZipFile(cache) as z:
        z.extractall(UE4SS_DIR)


def build_coopnet():
    """Nuitka standalone, not PyInstaller: PyInstaller exes got the upload quarantined on Nexus."""
    work = pathlib.Path(tempfile.gettempdir()) / "coopnet-build"
    subprocess.run([sys.executable, "-m", "nuitka", "--standalone", "--assume-yes-for-downloads",
                    "--windows-console-mode=disable", f"--output-dir={work}", "--output-filename=coopnet.exe",
                    str(ROOT / "coopnet" / "coopnet.py")], check=True)
    shutil.rmtree(COOPNET, ignore_errors=True)
    shutil.copytree(work / "coopnet.dist", COOPNET)
    # CI passes the bug report webhook as a secret; it is never in the repo.
    if os.environ.get("REPORT_WEBHOOK"):
        (COOPNET / "webhook.txt").write_text(os.environ["REPORT_WEBHOOK"].strip(), encoding="utf-8")


def build_installer(version):
    iscc = next((p for p in ISCC if os.path.exists(p)), None)
    if not iscc:
        sys.exit("Inno Setup (ISCC.exe) not found")
    subprocess.run([iscc, f"/DAppVersion={version}", str(ROOT / "installer" / "caretakerz.iss")], check=True)
    return DIST / f"Caretakers-Multiplayer-Setup-{version}.exe"


def write_mod(z):
    for p in SCRIPTS.glob("*.lua"):
        z.write(p, f"{MOD}/Scripts/{p.name}")
    for p in COOPNET.rglob("*"):
        if p.is_file():
            z.write(p, f"{MOD}/coopnet/{p.relative_to(COOPNET).as_posix()}")
    z.write(ROOT / "installer" / "enabled.txt", f"{MOD}/enabled.txt")


def build_zip(version):
    """The mod only, laid out to extract into the game folder. UE4SS is installed separately from its official release."""
    path = DIST / f"Caretakers-Multiplayer-{version}-manual.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        write_mod(z)
        # Turns on the in-game updater; the Nexus zip leaves it out (Nexus forbids updaters).
        z.writestr(f"{MOD}/update.ini", f"[update]\nversion={version}\n")
    return path


def build_nexus_zip(version):
    path = DIST / f"Caretakers-Multiplayer-{version}-nexus.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        write_mod(z)
    return path


def write_sums(files):
    path = DIST / "SHA256SUMS.txt"
    path.write_text("".join(f"{sha256(f)}  {f.name}\n" for f in files), encoding="ascii")
    return path


def main(version):
    DIST.mkdir(exist_ok=True)
    # Shown on the Multiplayer page.
    (SCRIPTS / "release.lua").write_text(f'return "{version}"\n', encoding="ascii")
    fetch_ue4ss()
    build_coopnet()
    files = [build_installer(version), build_zip(version)]
    files.append(write_sums(files))
    nexus = build_nexus_zip(version)
    for f in files + [nexus]:
        print("Built:", f)
    return files


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

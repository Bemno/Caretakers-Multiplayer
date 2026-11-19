"""Writes the GitHub release text: the CHANGELOG section, install steps and how to verify the files.

python .github/release_notes.py X.Y.Z notes.md

With VT_API_KEY set, each file is also uploaded to VirusTotal and linked.
"""
import json, os, pathlib, re, sys, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "Bemno/Caretakers-Multiplayer"

INSTALL = """**Install**
1. Download `Caretakers-Multiplayer-Setup-{v}.exe` and run it.
2. Windows may say *Windows protected your PC*. The mod is free and not code signed, so Windows doesn't know it yet. Click **More info**, then **Run anyway**.
3. If the game folder isn't found, pick the one with `Voyage.exe`.
4. Start the game and click **Multiplayer**. Both players need the same version.

**Manual install** (no installer): install [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) into `Voyage\\Binaries\\Win64`, then extract `Caretakers-Multiplayer-{v}-manual.zip` into the game folder (the one with `Voyage.exe`) and let it merge the `Voyage` folder."""

VERIFY = """**Verify the download**
These files were built by GitHub Actions from the source code in this repo at tag `v{v}` ([build log]({run})). Nothing is built on a private computer. The installer carries the official, unmodified UE4SS v4.0.0, downloaded and checked against its SHA-256 during the build.

| File | SHA-256 |{vt_head}
|---|---|{vt_sep}
{rows}

Check that a file came from this repo's build (needs the [GitHub CLI](https://cli.github.com)):
```
gh attestation verify Caretakers-Multiplayer-Setup-{v}.exe --repo {repo}
```"""


def changelog_section(version):
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(rf"^## {re.escape(version)}\b.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"CHANGELOG.md has no section for {version}")
    return m.group(1).strip()


def virustotal(path, key):
    boundary = uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{path.name}\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request("https://www.virustotal.com/api/v3/files", data=body, method="POST", headers={
        "x-apikey": key, "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        json.load(r)


def main(version, out):
    sums = [line.split("  ", 1) for line in (ROOT / "dist" / "SHA256SUMS.txt").read_text().splitlines()]
    key = os.environ.get("VT_API_KEY")
    rows = []
    for digest, name in sums:
        row = f"| `{name}` | `{digest}` |"
        if key:
            try:
                virustotal(ROOT / "dist" / name, key)
                row += f" [scan](https://www.virustotal.com/gui/file/{digest}) |"
            except Exception as e:
                print(f"VirusTotal upload failed for {name}: {e}", file=sys.stderr)
                row += " |"
        rows.append(row)
    run = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{REPO}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    verify = VERIFY.format(v=version, run=run, repo=REPO, rows="\n".join(rows),
                           vt_head=" VirusTotal |" if key else "", vt_sep="---|" if key else "")
    text = "\n\n".join([changelog_section(version), INSTALL.format(v=version), verify]) + "\n"
    pathlib.Path(out).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

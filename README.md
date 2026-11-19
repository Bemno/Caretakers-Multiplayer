# Caretakers Multiplayer: co-op mod for The Last Caretaker (beta)

Made out of love for The Last Caretaker. Built for my two kids; perhaps someone else would like to give it a try.

Beta: tested with 2 players, not much yet over Steam between two computers. Expect bugs. Testers and feedback are very welcome.

Unofficial fan mod, not affiliated with the developers of The Last Caretaker.

## Download and install

Get the latest version under [Releases](https://github.com/Bemno/Caretakers-Multiplayer/releases/latest).

- **Installer:** run `Caretakers-Multiplayer-Setup-x.y.z.exe`. It finds the game through Steam's library list. Windows may say *Windows protected your PC* because the mod is not code signed. Click **More info**, then **Run anyway**.
- **Manual:** install [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) into `Voyage\Binaries\Win64`, then extract `Caretakers-Multiplayer-x.y.z-manual.zip` into the game folder (the one with `Voyage.exe`).

Start the game and click **Multiplayer**. Both players need the same version.

## Is it safe? What is in the download

It's fair to be careful with a mod that ships an exe and a DLL. Here is everything in it, and how to check it yourself.

| File | What it is |
|---|---|
| `dwmapi.dll`, `ue4ss\UE4SS.dll` and the rest of `ue4ss\` | [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v4.0.0, the standard open source mod loader for Unreal Engine games (MIT). `dwmapi.dll` is how UE4SS loads itself into the game. The files are the official release, unmodified: the build downloads them and checks the SHA-256 (`package.py`). They are not stored in this repo. |
| `ue4ss\Mods\CoopSync\Scripts\*.lua` | The mod itself, plain Lua you can read: [`mod/CoopSync/Scripts`](mod/CoopSync/Scripts). It runs inside the game through UE4SS and syncs players, the boat, doors, items, power, building and so on. |
| `ue4ss\Mods\CoopSync\coopnet\coopnet.exe` (and the files next to it) | The network helper: [`coopnet/`](coopnet), Python compiled to an exe with [Nuitka](https://nuitka.net) so you don't need Python installed. The Lua mod starts it and talks to it through two text files. Details below. |
| `Caretakers-Multiplayer-Setup-x.y.z.exe` | The installer, made with [Inno Setup](https://jrsoftware.org/isinfo.php) from [`installer/caretakerz.iss`](installer/caretakerz.iss). |

**What coopnet does, and nothing else:**

- Sends game messages to the other player through Steam's own networking (`SteamNetworkingMessages` in the game's `steam_api64.dll`), or with LAN play over UDP ports 47020 (game) and 47021 (finding servers on the local network).
- Sends the host's save file to the guest when you join, and keeps a copy of your singleplayer saves while a multiplayer session runs, so multiplayer never changes them (`saves.py`).
- Reads and writes the clipboard for *Copy invite* (`clip.py`).
- Checks this repo's latest release on GitHub for the in-game update button (`update.py`). The installer it downloads is checked against the SHA-256 GitHub reports before it runs.

It does not collect or send anything else, and it has no other servers.

**How to check a download:**

- Every release is built by [GitHub Actions](.github/workflows/release.yml) from the source in this repo at the release tag. The build log is public, and the release notes link to it.
- Each release lists SHA-256 checksums (also in `SHA256SUMS.txt`).
- Each file has a signed build attestation from GitHub. With the [GitHub CLI](https://cli.github.com):
  ```
  gh attestation verify Caretakers-Multiplayer-Setup-x.y.z.exe --repo Bemno/Caretakers-Multiplayer
  ```
  This proves the file was built by this repo's workflow and not changed afterwards.

## Privacy

The mod only talks to the other player you choose to play with (through Steam, or directly on your LAN or by IP), and to GitHub to check for a newer release of this mod. It sends no data to the developer or anyone else. To turn off the update check, delete `update.ini` in `Voyage\Binaries\Win64\ue4ss\Mods\CoopSync`.

## Code signing policy

The installer is not code signed yet; an application for free signing by SignPath Foundation is pending.

- Releases are built only by the [release workflow](.github/workflows/release.yml) from the source in this repo.
- Committer, reviewer and approver: [Bemno](https://github.com/Bemno), the only maintainer. Changes from others (pull requests) are reviewed before they are merged, and every release is approved by hand.
- The repository account uses two-factor authentication.

## Build it yourself

Windows, Python 3.13 and [Inno Setup 6](https://jrsoftware.org/isinfo.php):

```
py -3.13 -m pip install nuitka==4.3.5 pytest==9.2.0
py -3.13 -m pytest -q coopnet
py -3.13 package.py 0.0.0
```

The files end up in `dist\`.

## Known issues

- Only 2 players.
- Join from the main menu, not from inside a running world.
- Item charge and wear are not synced.

## Feedback

Bug reports, ideas and finding someone to play with: [Discord](https://discord.gg/X2AnHgQB2X), or open an issue here. Contact: bemno@tutamail.com

## License

MIT, see [LICENSE](LICENSE). Includes UE4SS (MIT) in the release files.

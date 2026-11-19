# Changelog

## 0.2.8 — 2026-11-19

Mooring, the recycler and saves: the boat is pulled in to the quay like in singleplayer, the recycler's output lands properly for both players, and multiplayer and singleplayer saves are now kept fully apart.

- Mooring: the lines pull the boat in to the quay and turn it straight; it slides along the quay and stops before the hull touches it
- A moored boat no longer takes damage, shakes for the other player or is thrown off when let go
- Anchors stay up while the boat is moored, for 30 s after, and when it gets throttle
- The boat keeps its speed when the other player takes the helm
- Recycler output no longer hangs in the air or bounces around for the other player
- Things that come to rest in mid-air are no longer stuck there
- A box built by one player now sits on the boat for the other player too
- Items with the same save id in both games no longer move or remove each other
- Multiplayer worlds are kept outside the game's save folder between sessions, so Continue in singleplayer never loads a multiplayer world
- The save terminal and save list can't touch singleplayer saves during multiplayer
- Looking at the other player's head to share power works again

## 0.2.7 — 2026-11-19

Mooring, the recycler and saves: the boat is pulled in to the quay like in singleplayer, the recycler's output lands properly for both players, and multiplayer and singleplayer saves are now kept fully apart.

- Mooring: the lines pull the boat in to the quay and turn it straight; it slides along the quay and stops before the hull touches it
- A moored boat no longer takes damage, shakes for the other player or is thrown off when let go
- Anchors stay up while the boat is moored, for 30 s after, and when it gets throttle
- The boat keeps its speed when the other player takes the helm
- Recycler output no longer hangs in the air or bounces around for the other player
- Things that come to rest in mid-air are no longer stuck there
- A box built by one player now sits on the boat for the other player too
- Items with the same save id in both games no longer move or remove each other
- Multiplayer worlds are kept outside the game's save folder between sessions, so Continue in singleplayer never loads a multiplayer world
- The save terminal and save list can't touch singleplayer saves during multiplayer
- Looking at the other player's head to share power works again

## 0.2.6 — 2026-11-18

The mod can now update itself: when a new version is out, an update button shows up in the main menu. Run this installer once by hand; after that, updates come from inside the game.

- New: "Update multiplayer to x.y.z" button under Multiplayer in the main menu when a newer release is on GitHub
- The update is downloaded and checked against GitHub's checksum, then the game closes, the installer runs silently (Windows asks for permission once) and the game starts again through Steam
- Only the installer and the manual zip check for updates; the Nexus download does not

## 0.2.5 — 2026-11-18

First full release: the boat now holds still for both players, and the other player looks and acts much more like a real player. Online play over Steam between two computers is still untested, so feedback is very welcome.

- Things on the boat no longer shake or bounce, and the whole boat no longer trembles for the player who isn't driving
- The recycler on the boat no longer throws the boat around or tears loose
- Anchors follow the boat for both players; the boat no longer lurches when the other player takes the helm
- Moving a mooring line along the quay pulls the boat there
- Mooring lines work for both players: no stiff lines, no shaking, no boat racing off
- The boat no longer shook or flew off at full throttle
- The steering wheel no longer turns sideways for the other player
- Boat paint shows the same for both players
- The other player's backpack, paint colour, weapons and tools show in the right colours
- The electric pistol in the other player's hand: aiming pose, power cable and lightning
- The other player no longer floats above the ground
- Flying the photo drone no longer turns the other player into the drone
- A dot with the other player's name, up to 300 m
- The shark no longer hunts players who leave it alone
- No more endless night swarm creatures from the sea
- New: join a host by IP address or name (also over Tailscale/VPN)

## 0.2.0 — 2026-11-18

Beta update: the other player now moves like a real player, and a moored boat lies still at the quay. Still a beta for 2 players, not yet tested over Steam between two computers; feedback is very welcome.

- The other player is animated: walking and running in every direction, sprinting, crouching, jumping and falling, swimming, diving, climbing ladders and building with their hands
- The power socket on the other player's chest stays on the body instead of trailing behind
- A moored boat no longer rides the waves; it lies still at the quay for both players, also while the grinder runs
- The boat can no longer tip over and sink when the other player takes it over or casts off
- The boat no longer drifts away for the guest while it is moored
- coopnet is no longer a single packed exe, which some virus scanners flagged by mistake
- New manual install: a zip you extract into the game folder, for those who would rather not run an installer
- Menu buttons react more reliably, also when the game runs in a split screen

## 0.1.1 — 2026-11-17

Beta fix: the installer now finds The Last Caretaker in any Steam library folder. Still a beta for 2 players, not yet tested over Steam between two computers; feedback is very welcome.

- The installer looks through all your Steam library folders and picks the one that has the game, instead of trusting an old registry entry that could point to the wrong drive
- If it still guesses wrong you can pick the folder yourself; it checks that the game is there

## 0.1.0 — 2026-11-17

First public beta of CaretakerZ, an unofficial co-op mod for The Last Caretaker. This build is for beta testing with 2 players only. Online play over Steam has NOT been tested between two computers yet (LAN has only been tested with two copies of the game on one PC), so expect bugs. Everyone is more than welcome to try it and send feedback: crashes, desyncs, anything that feels off.

- Multiplayer menu in the main menu: host a new world online (Steam) or on LAN, load your multiplayer worlds, invite to clipboard
- Player name at the top of the multiplayer menu, shown to the other player
- Friend list: add a friend by Steam id or invite code, both accept, then you see each other's status (in the menu, hosting) even when set to invisible in Steam, and can join from the list
- LAN: servers on your network show up in the multiplayer menu
- If the host quits or loses connection, the guest gets a dialog: wait for the host (rejoins when it is back) or quit
- Multiplayer worlds are saved separately from your singleplayer saves; singleplayer saves and autosaves are protected during a session
- Synced: players, the boat, doors, power and cables, building, items, inventories, weather, ocean loot, sharks and swarm creatures, machines, repairs
- Known issues: the moored boat can move more than in singleplayer; join from the main menu, not from inside a running world; item charge and wear are not synced; only 2 players
- Back up your saves before testing (%LOCALAPPDATA%\Voyage\Saved\SaveGames)

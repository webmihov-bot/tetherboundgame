# TETHERBOUND

1-4 player co-op physics extraction prototype for Godot 4.3+ (Forward+).
Everything is generated in code: meshes, shaders, animation, UI and audio. There are no imported assets.

## Run it

1. Open Godot 4.3 or newer (tested on 4.3 and 4.7.2), choose **Import**, and select `project.godot` in this folder.
2. Press **F5**.
3. Pick **Solo Mode** to try it alone, or **Host World** and have friends **Join** with your IP.

## Controls

| Key | Action |
| --- | --- |
| W A S D / arrows | Move |
| Mouse | Look |
| Space | Jump. With a taut cable it also fires the catapult |
| Left Shift | Magnetic anchor. Hold on the ground to lock; press in the air to slam down |
| Q / E | Reel the cable in / out |
| Left Ctrl | Dash (at the helm: descend) |
| X | Release the cable: drops every wrap so it runs straight again |
| F | Interact: take or leave the helm, board the Ark |
| Esc | Free the mouse (shows **Leave session**) |

## How to play

Solo Mode starts an interactive tutorial the first time: twelve short steps that advance as you do each thing (move, jump, dash, anchor, reel, catapult, ring the monoliths, take a core, fly the Ark). Press **T** to skip it, or to replay it later. While it runs the storm is frozen and the monolith puzzle has no time limit.

- You spawn on **the Ark**. Jump off onto the island below. Press **F** near the Ark to climb back aboard.
- Everyone is on one cable: Ark → player 1 → player 2 → ... The HUD bar shows your tension: cyan is slack, violet is charged, red is about to overload.
- **Slingshot:** two players hold Shift, the one between them walks back until the cable is violet, then jumps.
- **Chain reaction:** if someone falls, the cable drags the rest. Whoever anchors first holds the squad. An anchor held at critical tension for about two seconds overloads and lets go.
- **Golden Resonance Ruins:** wrap the cable around each of the three tuning-fork monoliths and pull (or reel in with Q) to ring it. Ring all three within 45 seconds and the island's Harmonic Core surfaces.
- **Obsidian Spires:** low gravity, and lightning charges the cable. Wrap a slumbering titan and keep the cable taut for about a second to topple it and free its core.
- Touch a core to collect it. Each core pushes the storm back; five cores stabilize the frequency. If the storm reaches 100% everyone is recalled to the Ark.
- Stand at the gold-lit pedestal at the Ark's bow and press **F** to fly it: WASD to steer, Space up, Ctrl down. The cable to the Ark is about 50 m at full stretch, so the Ark has to come with you.

## Multiplayer

- **Host World** opens UDP port 7777 and puts you in the game. Up to 4 players.
- **Join via IP** accepts `ip`, `ip:port`, or an invite code.
- **Copy Invite Code** encodes your *local* IPv4 and port (for example `TB-1HGE9P5-5ZL`). It works for people who can reach that address: the same network, a VPN such as Tailscale or ZeroTier, or a router with UDP 7777 forwarded. For internet play without a VPN, forward the port and share your public IP instead.
- All players must run the same Godot version as the host or server.

### Dedicated server

```
godot --headless --path . -- --server --port=7777
```

Running headless starts a dedicated server automatically. Options: `--port=`, `--seed=`, and for clients `--join=ip[:port]` and `--name=`. The port can also be set with the `TETHERBOUND_PORT` environment variable.

### Docker

```
docker compose up -d --build
```

This builds an image that downloads Godot and runs this folder headless on UDP 7777. Set `GODOT_VERSION` in `docker-compose.yml` to the version your players use (default 4.7.2).

## Project layout

```
project.godot                  input map, 60 Hz physics, Forward+, MSAA 4x, shader globals
scenes/Main.tscn               world environment (SDFGI, volumetric fog, glow, ACES), all systems
scenes/Player.tscn             CharacterBody3D + spring-arm camera + MultiplayerSynchronizer
scenes/ArkBase.tscn            the flying base + MultiplayerSynchronizer
scenes/HUD.tscn, MainMenu.tscn UI roots (built in code by their scripts)
scripts/NetworkManager.gd      autoload: host / join / solo / dedicated server, lobby, invite codes
scripts/Main.gd                shared game state: storm, cores, puzzles, titans, lightning
scripts/PlayerController.gd    movement, anchor, dash, helm, procedural body, animation, scarf
scripts/TetherSystem.gd        cable forces, catapult, wrapping, Verlet rope, ribbon mesh
scripts/WorldGenerator.gd      seeded chunked islands, biomes, monoliths, titans, cores, foliage
scripts/ArkBase.gd             server-driven Ark, piloting
scripts/Atmosphere.gd          animated sky, post-processing, motes, wind streaks, horizon debris
scripts/Fx.gd                  particle bursts, shock rings, lightning bolts
scripts/ProceduralSoundscape.gd real-time synth: drone, bass arp, chimes, rumble, effects
scripts/HUD.gd, MainMenu.gd    HUD and glass menu
shaders/cel_toon_pbr.gdshader  banded diffuse, hard specular, rim, fresnel glow
shaders/energy_tether.gdshader cyan → violet → red plasma cable
shaders/wind_grass_foliage.gdshader  wind + player-reactive grass and floating shards
shaders/island_terrain.gdshader  strata, ground patches and pulsing energy veins
shaders/drift_sky.gdshader     nebula, stars, aurora and the storm eye
shaders/glass_panel.gdshader   blurred glass for the menu
Dockerfile, docker-compose.yml dedicated server
```

## How the networking works

- **Server-owned** (host, or the dedicated server): the Ark's position and pilot, storm level, core count, solved puzzles, toppled titans, lightning strikes, spawning. Clients send requests; the server validates and broadcasts.
- **Owner-simulated:** each player simulates their own Resonator and replicates position, velocity, anchor, reel and tension. Cable forces are computed locally from the other players' replicated state. This keeps movement responsive without client-side prediction, but it is not cheat-proof.
- **Not sent at all:** terrain. Every peer generates identical islands from the shared seed.

## Tuning

Most feel values are exported at the top of the scripts: cable lengths and stiffness in `TetherSystem.gd`; speed, jump, dash and catapult power in `PlayerController.gd`; `view_radius` in `WorldGenerator.gd` (2 = a 5×5 block of chunks; lower it, or turn off SDFGI in `Main.tscn`, on slower GPUs).

## Known limits of this prototype

- The cable never breaks; at critical tension anchors overload instead.
- Titans stand still until toppled. They do not walk or attack.
- Cable wrapping is approximate (contact points around a body's vertical axis) and each peer computes its own wraps.
- The Ark passes through terrain.

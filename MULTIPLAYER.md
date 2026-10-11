# VOXELCRAFT — Multiplayer design

**Status: the first slice is built.** Host-and-play, the handshake and block-edit
synchronisation all work over a real ENet socket (see §8). Terrain is **not** streamed:
because `terrain.gd` is seed-deterministic, a client builds the same world from the host's
seed and only the *edit diff* travels — the simplification §9 predicted. What is still
open: remote player avatars (§6), host-authoritative mobs and drops (§6), server-side
commands (§7b), and the chunk-streaming path of §4 for a client that cannot generate.

The point of this document is to fix the *architecture* before a line of netcode is
written, because the shape of the answer changes a lot of what `world.gd`,
`player.gd` and `main.gd` are allowed to assume. The current build is a single-player
game in which `world.gd` **is** the authority: it owns the voxel data, applies edits
immediately and never asks anyone. Multiplayer means introducing a seam where there is
none today.

---

## 1. Goals and non-goals

**Goals**

* Host-and-play: one player hosts, others join by IP, no dedicated server needed.
* Small co-op worlds — 2 to 8 players.
* Block edits and entities stay consistent for everyone.
* The host is the source of truth. No client-side authority.
* Reuse the existing world/mesh/terrain code. Multiplayer must not fork worldgen.

**Non-goals (for v1)**

* Dedicated headless servers, matchmaking, NAT punch-through, account systems.
* Anti-cheat beyond basic sanity checks.
* Region hand-off / seamless host migration.
* Player-versus-player combat balance.

---

## 2. Transport

Godot's built-in high-level multiplayer: `ENetMultiplayerPeer` over UDP.

* Host: `ENetMultiplayerPeer.create_server(port, max_clients)` →
  `multiplayer.multiplayer_peer = peer`.
* Client: `ENetMultiplayerPeer.create_client(ip, port)`.
* Reliable-ordered is the default and is what block edits and inventory use.
* Unreliable is used for the 20 Hz position stream (§6), where a late packet is
  worthless — the next one supersedes it.

The lobby is a small screen off the title menu: *Host Game* / *Join Game (IP)*,
plus a player-name field. A join hands the client the world seed and the host's
settings (game mode, day length, render distance cap) before any chunks are sent.

---

## 3. The authority seam

Today, `world.gd` mutates the chunk dictionary directly. Multiplayer needs a single
choke point, and that choke point now exists:

```
world.set_block(x, y, z, id, record)     a *request*: the only entry point callers use
   -> world.authority.request_edit(world, pos, id, record)
        -> world.apply_edit(pos, id, record)   the actual mutation
        -> authority.on_applied(pos, id)       "it is real, tell the network"
world.block_changed(pos, id)             emitted by apply_edit, after the fact
```

* `world.Authority` is the single-player implementation: the request *is* the
  change.
* `apply_edit` is the only place a chunk's blocks change outside worldgen. Worldgen
  (`_gen_chunk`) and save loading (`load_edits`) write bytes directly and
  deliberately bypass the seam — they are not requests, they are the world being
  built.
* `set_block` filters before the seam: an edit with no chunk loaded, or one that
  would change nothing, never reaches the authority. Without that a client would
  ship a packet every frame the mouse button is held.
* A plant sitting on a block that gets broken is applied as part of the *same*
  edit, not as a second request, because it is a consequence of that change rather
  than an independent one.

**Multiplayer is then a subclass.**

* **Host** implements it as "apply immediately, then broadcast" — which is exactly
  the base class behaviour plus a broadcast in `on_applied`, so the host can ship
  the single-player implementation and it is still correct.
* **Client** implements it as "apply optimistically to my own copy so placing feels
  instant, tell the host, and reconcile when the host confirms or rejects" — it
  overrides `request_edit` to predict locally and remember the cell, and resolves it
  when the authoritative `on_applied` arrives (matching, so nothing changes) or a
  rejection arrives (undo).

That is the one invasive refactor, and it is done and tested **single-player**
first, so the seam is proven before any packet is sent. The hand test installs a
recording authority over a synthetic chunk and asserts that a requested change
reaches it, comes back applied, carries its derived plant removal in one request,
and that a no-op sends nothing.

---

## 4. Chunk streaming

Do **not** send meshes. Send block bytes; let each client mesh locally with its own
existing `_mesh_job`. Meshes are big, machine-specific and already reproducible.

* The server owns worldgen and the edit log.
* A client asks for a chunk column it needs (the same set the streaming code already
  computes from render distance).
* The server replies with the sections that column actually has — the sparse
  `{section → PackedByteArray}` the world stores, so absent sections are not sent at all
  — plus the list of edits in it. The client applies edits on top and meshes normally.
* Chunks are sent on a **budget** (a few per second per client) so a joiner streams
  the world in progressively instead of stalling on one huge burst.
* `terrain.gd` stays deterministic and shared: given the same seed, a client could
  generate the chunk itself. Sending the bytes is still simpler and avoids
  generation-cost divergence, but "client generates, server only sends the edit
  diff" is the obvious bandwidth optimisation to keep in the back pocket.

Bandwidth estimate: a column is only as big as the sections it actually holds — a
typical generated one is 4 sections of 4 KB, ~16 KB raw, and it compresses well. Note
what this does *not* do: it is unchanged by the world being 384 blocks tall, because the
extra height is absent sections and absent sections are never sent. A column that has
been built in does grow, and a buried solid section is the obvious thing to RLE first.

---

## 5. Block edits

The hot path, and the one that must feel instant.

1. Client mines a block. It applies the removal to **its own** chunk immediately and
   plays the break effects, then sends `edit_request(pos, id)` reliable-ordered.
2. Host validates: is the block within reach of that player's server-side position,
   is the block actually there, is the target not another player's protected claim
   (n/a in v1)? If it passes, the host applies it and broadcasts
   `edit_confirm(pos, id, tick)` to everyone **including the requester**.
3. If it fails, the host sends `edit_reject(pos, server_id)` to the requester, which
   snaps the block back.

Late joiners get the authoritative state, not the events: on join the host sends the
saved edit diff (the same `edits.bin` structure the save system already uses) before
streaming chunks. There is therefore no need to replay history.

Conflict rule: **last write wins, ordered by the host's tick.** Two players placing
at the same cell resolve deterministically at the host, and both clients end up
agreeing because both apply the same confirmed stream.

---

## 6. Entities

Players, mobs and dropped items.

* **Remote players** are the existing `player_model.gd` humanoid driven by a
  transform stream, no physics. Interpolate between the last two network transforms
  with a ~100 ms buffer so movement looks smooth despite 20 Hz updates. Head yaw and
  the arm-swing flag ride along so you can see someone else mining.
* **Mobs** are simulated **on the host only**. It streams mob transforms at a lower
  rate (5–10 Hz, they move slowly) and spawn/despawn events. Clients do not run the
  mob AI. This kills duplicate-spawn and desync bugs at the cost of host CPU.
* **Dropped items** are host-authoritative too: the host decides who picks up a drop
  (first request wins), then broadcasts the removal and the inventory grant as two
  events. Items are otherwise streamed like mobs.

Position streaming at 20 Hz with interpolation and a short extrapolation window is
the standard compromise: cheap, and the interpolation buffer hides packet jitter.

---

## 7. What each file has to change

| File | Change |
| --- | --- |
| `world.gd` | ~~Route every voxel write through the authority interface~~ **done** (§3); still to do: add "apply a chunk received from the network" beside the existing load path. Meshing is unchanged. |
| `player.gd` | Split "the local player" from "a remote avatar". The local one keeps input, physics and stats; the remote one is pose + interpolation only. |
| `mobs.gd` | Gate AI behind `multiplayer.is_server()`; on clients, apply streamed transforms instead of simulating. |
| `main.gd` | A `Mode.NETWORK` state; don't run the save writer as the sole authority on clients; send/receive initial world handshake. |
| `terrain.gd` | No change — it must stay pure and seed-deterministic. That is what makes client-side meshing agree with the host. |
| new `net.gd` | Autoload: peer setup, RPC definitions, tick counter, the authority implementations. |
| new `net_lobby` UI | Host/Join screen off the title menu. |

---

## 7b. The command and permission layer (already built)

`commands.gd` is written with this document in mind even though it currently only
runs locally. It is a registry, not a match statement:

```
register(name, usage, help, level, handler, aliases)   -> Commands.register
execute_line("/give stone 7")                          -> the chat box's path
run_command("give stone 7")                            -> the terminal's path
```

The three levels are `LEVEL_ANY` (0), `LEVEL_OP` (1) and `LEVEL_ADMIN` (2), and
`Commands.level` is the *sender's* level. Today it is set from the world's
"allow cheats" flag in `main.gd::_set_cheats`; with netcode the only change is that
the server sets it per connection instead of once, and `_dispatch` stays as it is:

```
if not cheats_enabled and level_needed > LEVEL_ANY:  refuse
if level_needed > sender_level:                      refuse "needs a higher permission level"
handler.call(args)
```

Everything else about the multiplayer design is unchanged by this layer, with two
consequences worth stating:

* **Commands must become server-side.** `/give`, `/gamemode`, `/time` and `/tp`
  mutate authoritative state, so in multiplayer the client sends the line and the
  server runs it and broadcasts the result (or the refusal). The handler bodies
  already only touch `player`, `world`, `sky` and `hud` through bound references, so
  the same code runs on the server against the *sender's* player object.
* **Chat and commands share one input box.** `execute_line` deliberately refuses
  lines without a leading `/`, so a client can route every submission through
  "command if `/`, broadcast message otherwise" without ambiguity.

Player bans, whitelists and per-player op levels are the natural next additions, and
they slot in as a `level` lookup plus one more refusal branch.

---

## 8. Order of work

1. ~~**Authority seam, single-player.** Add the interface, host implementation only,
   prove the game is unchanged with `--selftest` / `--handtest`.~~ **Done** — see §3.
   `world.Authority` is installed by default, `set_block` is now a request, and the
   hand test proves the seam routes, applies and filters.
2. ~~**Peer + handshake.** Host/join, exchange seed and settings, no world yet.~~
   **Done** — `net.gd` (autoload) owns the `ENetMultiplayerPeer`, the `_hello` / `_welcome`
   handshake and the two authority classes; the title menu's **MULTIPLAYER** screen hosts
   or joins by IP.
3. **Chunk streaming.** Skipped in favour of the §9 simplification: the client regenerates
   terrain from the shared seed, so there is nothing to stream. Still open for a client
   that cannot generate (a very large render distance, or a non-shared seed).
4. ~~**Block edits.** The predict / confirm / reject loop. This is the core feature.~~
   **Done, minus rejection** — `Net.ClientAuthority` predicts locally and asks the host;
   `Net.HostAuthority` applies and broadcasts; the joiner is handed the accumulated
   `serialize_edits()` diff. With no server-side reach check yet there is nothing to
   reject, so the rollback branch is not written.
5. **Remote player avatars.**
6. **Host-authoritative mobs and drops.**
7. Polish: name tags, a player list, and the render-distance/bandwidth knobs. Chat,
   commands and the op levels already exist (§7b) — the work here is routing them
   through the server instead of running them locally.

Each step should be shippable and testable on its own; anything that cannot be
verified without two machines gets a headless two-peer self-test (two `MultiplayerPeer`
instances in one process over `localhost`) added to the harness.

---

## 9. Deliberate simplifications for v1

* No client-side worldgen — the host sends chunk bytes. Simpler to get right.
* No server-side movement validation beyond reach checks for edits.
* No chunk unloading policy beyond "stop sending what the client says it no longer
  needs".
* No NAT traversal: IP + port, same LAN or a forwarded port. Document it, don't solve
  it here.
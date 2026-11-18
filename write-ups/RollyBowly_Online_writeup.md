# Rolly Bowly Online: Backyard Brawl
CSC 476 Game Development, Project 4 (networked multiplayer)

Rolly Bowly Online is the networked version of my Rolly Bowly game (Project 3). Every player defends
their own backyard. You bowl your rolly polly through marching ants, and every STRIKE, SPARE or big
combo throws a rack of ants into another player's backyard. The last house standing wins.

---

## 1. How to run it

### From the menu
1. Start the game. The first screen asks for a **Name**, a **Server IP** and a **Port** (default 9999).
2. Pick one:
   - **HOST & PLAY** runs the server on this computer and plays from it too. The menu and the lobby
     show this computer's LAN address(es) so the other players know what to type.
   - **JOIN** connects to the IP and port you typed.
   - **SERVER ONLY** runs a dedicated server that doesn't play. It stays on the lobby screen and
     shows the live scoreboard and chat for the whole match. It also has a **START NOW** button.
   - **PLAY SOLO** plays the original single-player game.
3. In the lobby, everyone presses **READY**. When 2–8 players are all ready, a 3-second countdown
   starts and everyone drops into their backyard together.

The name, IP and port you used last are saved in `user://net.cfg`.

### From the command line
Put arguments after `--`:

| Purpose | Command |
|---|---|
| Dedicated server on port 7777 | `RollyBowlyOnline.exe -- --server --port=7777` |
| Dedicated server with no window | `godot --headless -- --server --port=7777` |
| Host and play | `RollyBowlyOnline.exe -- --host --port=7777 --name=Liam` |
| Join | `RollyBowlyOnline.exe -- --join=192.168.1.20 --port=7777 --name=Sam` |
| Allow a 1-player match (testing) | add `--allow-solo` (on automatically when run from the editor) |

### Testing on one computer
In Godot, use **Debug ▸ Customize Run Instances**, enable multiple instances, set it to 3 or 4 and
press Play. Make one instance HOST & PLAY and have the others JOIN `127.0.0.1`.

---

## 2. How to play

**Goal:** keep your mushroom house standing longer than everyone else.

| Action | Mouse / keyboard | Controller |
|---|---|---|
| Aim and launch | press anywhere, drag back, let go (slingshot) | hold A, aim with the stick, let go |
| Stop mid-roll | click while rolling | A while rolling |
| Turn the camera | Q / E | LB / RB |
| Chat | Enter or T to type, Enter to send, Esc to stop | – |
| Choose your attack target | Tab, or click a name on the scoreboard | – |

**Your backyard**
- Ants march on your house in waves. Each wave is bigger than the last, and helmeted soldier ants
  join from wave 3 and come after your rolly polly.
- Bowl them over while you're rolled up. When you're unrolled, ants can bite you.
- You're **out** when the house is eaten or the rolly polly loses all its hearts.

**Attacking (what makes it multiplayer)**

| You bowl… | They get… |
|---|---|
| a **STRIKE** (a whole group in one roll) | **Soldiers:** a group of 3–5 worker ants escorted by 1–2 helmeted soldiers |
| a **SPARE** (a group cleared on the second roll) | **Sprinters:** 3 small, blue, very fast ants |
| a **4+ ant combo** in one roll | **A queen:** a big purple ant that takes 3 hits and lays a new ant every 5 seconds until she's bowled over, plus (combo − 4) workers |

Ants you send march into the target's backyard with **your name floating over them**.

**Defending: BLOCK.** When someone sends you ants, an **INCOMING!** banner and a 3-second countdown
appear first. If you earn any attack (STRIKE, SPARE or 4+ combo) during the countdown, you **block**
the attack that would land soonest and nothing spawns. Blocking uses up your attack.

**Hitting back: COUNTER-BOWL.** If you **STRIKE** a group that another player sent you, the attack goes
straight back to that player, **doubled**: their 3 sprinters return as 6, their queen returns as two.
Each group can only be bounced once, but the doubled group can be counter-bowled again, which turns
into a duel. The server caps the size of attacks, so it can't grow forever.

When you earn an attack, the game handles it in this order: **block** if anything is incoming,
otherwise **counter-bowl** if it was a STRIKE on a sent group, otherwise **send** it to your target.

**Targets** (Tab cycles through them): **Random** (default), **Leader** (the highest score still alive),
**Revenge** (whoever last attacked you), or one specific player. The red arrow on the scoreboard
shows your current target.

**Winning:** when only one house is left, that player wins. Players are ranked by the order they were
knocked out. When you're out, press **WATCH** on the results book to keep following the scoreboard and
chat. Eight seconds after the winner is decided, everyone goes back to the lobby, where the last
match's standings are shown.

---

## 3. How the server and client work

### Architecture: "own backyard, shared pressure"
Each player's game runs its **own** backyard simulation locally: ant AI, rolly polly physics, power-ups,
combos. No 3D objects are synchronised over the network. The server only handles a few small game
events, and it is authoritative for all of them:

```
        client A                         SERVER (host or dedicated)                    client B
  ──────────────────                ─────────────────────────────────            ──────────────────
  register(name)        ───────▶    roster, colours, unique names     ───────▶   set_roster(players)
  chat(text)            ───────▶    validate + relay                  ───────▶   chat(name, text, colour)
  ready(true)           ───────▶    all ready & ≥2? countdown 3,2,1   ───────▶   countdown(n)
                                    start_match(seed, roster)         ───────▶   change scene -> backyard
  stats{score,wave,hp}  ──4 Hz──▶   store, rebroadcast                ───────▶   stats(id, …) -> scoreboard
  attack{ants}, target  ───────▶    clamp each type, pick target      ───────▶   incoming(from, attack) -> 3 s warning -> ants spawn
  block(from, attack)   ───────▶    feed: "B BLOCKED A's 3 sprinters" ───────▶   chat feed
  eliminated(reason)    ───────▶    assign place, check for winner    ───────▶   eliminated(id, place)
                                    match_over(winner) … 8 s …        ───────▶   back_to_lobby
```

The client never decides what happens to another player. It **asks** (`attack`, `eliminated`), and
the server checks the request (is this player still alive, is each ant type within its cap
in `ATTACK_CAPS`, is the target valid) before it tells the right peer. Blocking and counter-bowling
are decided on the defender's own machine, because the defender is the only one who knows whether
the ants have landed yet. A counter-bowl is just an attack with an explicit target, and the server
caps it like any other.

### Why this design
- **Bandwidth:** one small stats dictionary, four times a second, per player, sent only when it
  changes. Physics never leaves the machine, so lag can't make a ball desync or teleport, and the
  game handles 8 players on ordinary Wi-Fi.
- **Responsiveness:** your own rolls feel exactly like single-player because they *are* local. Only
  the effects you send to others travel over the network, and a 1.2-second "INCOMING!" warning
  hides the network delay.
- **Fairness and variety:** the server sends every client the same random `seed` at the start of the
  match, so everyone faces the same opening waves. Each match uses a new seed, and the human
  attacks make every game different.

### The code (all in `res://net/`)

| File | What it does |
|---|---|
| `network.gd` (autoload **Net**) | All networking: ENet host/join/leave, the roster, ready-up countdown, chat relay, stats relay, attack routing, eliminations and winner, and returning to the lobby. It's an autoload, so it lives at `/root/Net` on every machine and RPCs always find the same node path, whatever scene each player is in. |
| `connect_menu.gd/.tscn` | Main scene. Takes the name, IP and port, offers HOST & PLAY, JOIN, SERVER ONLY and PLAY SOLO, and reads command-line arguments. |
| `lobby.gd/.tscn` | Roster with READY state, how-to-play, last match results, chat. The dedicated server stays here during the match. |
| `mp_hud.gd` | Added to the backyard by `main.gd` when online. Holds the scoreboard and chat, sends stats, and turns combo events into a block, a counter-bowl or an attack. Runs the 3-second incoming countdown, handles targeting, and reports elimination or victory. |
| `queen_brood.gd` | Attached to a queen ant. Every few seconds she lays an ant next to her, until she's knocked over (max 6). |
| `scoreboard.gd` | Everyone's name, colour, score, wave, house health bar and bug hearts (or their place once out). |
| `chat_box.gd` | Chat log plus input line. BBCode is escaped, and messages are limited to 200 characters. |
| `net_ui.gd` | Shared look: Fredoka font, the UI pack's buttons, paper panels. |

**RPC conventions in `network.gd`**
- `_srv_*` functions are `@rpc("any_peer", "call_remote")`. Clients call them with `rpc_id(1, …)`, and
  the host calls them directly (`_to_server()`). They find the caller with
  `multiplayer.get_remote_sender_id()` (0 means the host itself, see `_sender()`).
- Every other RPC is `@rpc("authority", "call_local")`. Only the server may call them, and
  `call_local` makes them run on the host/dedicated server too.
- Chat, roster, attacks and eliminations use **reliable** RPCs. Stats use **unreliable_ordered**,
  because a newer stats packet replaces a lost one anyway.

**Changes to the Project 3 game**

| File | Change |
|---|---|
| `scripts/main.gd` | When online, seeds the RNG and adds the online HUD. New `spawn_incoming()` builds sent ants (rack + soldiers, sprinters, queens), tags them with the sender for counter-bowls, and adds name tags. New `spawn_mob_at()` for the queen's eggs. `_spawn_row()` now returns the ants it made. New inspector group *Multiplayer ants* (sprinter speed, queen size/hits/laying rate). |
| `scripts/combo.gd` | New signal `attack_earned(attack, reason, struck)`, emitted on STRIKE, SPARE and 4+ combos. |
| `scripts/game_ui.gd` | No pause button online. The results book shows your place or "YOU WIN!". PLAY AGAIN becomes WATCH online. QUIT goes to the connect menu. |
| `scripts/pause_menu.gd` | Pausing is disabled online (the other players keep going). QUIT goes to the connect menu. |
| `scripts/title_screen.gd` | Skipped in online matches (the lobby replaces it). |
| `scripts/camera_rig.gd` | Q and E don't turn the camera while you type in the chat. |
| `project.godot` | `Net` autoload. The main scene is now `net/connect_menu.tscn`. |

### Book patterns used
This project is built from the networking patterns in *The Essential Guide to Creating Multiplayer
Games with Godot 4.0*: `ENetMultiplayerPeer` server and client (ch. 1), a lobby that gathers players
(ch. 3), chat over reliable RPCs (ch. 4), and the server starting the match for every client, sending
the RPC *before* changing scene as the errata describes (ch. 5). The login database from ch. 2 isn't
used, because players only enter a display name. All the visuals, the game and the art are my own
Rolly Bowly.

---

## 4. Requirements checklist

| Requirement | How it's met |
|---|---|
| Works on one computer and on a LAN | ENet over UDP, with the IP and port entered in the menu. Works with several instances on one computer (127.0.0.1) or across a LAN (the host's LAN IP). |
| 2 to n players, n ≥ 4 | `MAX_PLAYERS = 8`, `MIN_PLAYERS = 2` |
| See the progress of other players | Live scoreboard: score, wave, house HP bar, bug hearts, placement. Chat feed of every attack and knockout. |
| Act while others act | Everyone plays at the same time in their own backyard. Nothing is turn-based. |
| Own graphics if a book example is used | All Rolly Bowly art and UI. Only the networking patterns come from the book. |
| Chat during play | Chat panel in the lobby and in game (Enter to type). |
| Fun to play more than once | Random wave angles, power-ups, and attacks that depend on what humans do. Three attack types, blocking and counter-bowl duels, and the targeting choices (Leader / Revenge / specific player) change the strategy each match. |
| Configure server port, client IP and port at run time | Menu fields plus `--port`, `--join`, `--ip` and `--server` command-line arguments. |
| Windows, Mac and Linux builds | Export presets for Windows Desktop, Linux and macOS. |

---

## 5. Playtesting results
*(Phase II LAN playtest: fill in after the session.)*

- **Date / setting:**
- **Players and machines:** (e.g., 4 players: 2 Windows, 1 Mac, 1 Linux, on the classroom Wi-Fi)
- **Matches played / average length:**
- **What players enjoyed:**
- **What confused players:**
- **Bugs found:**
- **Balance notes:** (Were strikes too strong? Is a 3 s block window too short or too long? Did counter-bowl duels get out of hand? Did someone get dog-piled with Leader targeting?)
- **Changes made because of playtesting:**

---

## 6. Known limitations / future work
- ENet doesn't work in a Web export, so online play is desktop only. The Web build is still single-player.
- If the host quits, the match ends for everyone. A dedicated server avoids this.
- Other players' backyards appear as numbers and bars, not live views. A small top-down mini-map of
  each backyard would be a good next step.

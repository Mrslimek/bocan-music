# Music Share MVP — Peer Test Protocol (v1)

Shared contract for the macOS and Android apps. Both apps MUST implement this document
field-for-field. If you believe it has a genuine defect, report it instead of deviating.
Design influences (what was borrowed and what was rejected) are discussed in
docs/SEGUE_STUDY.md and docs/ARCHITECTURE.md.

Changelog: 2026-10-31 — added the optional `command` type (remote playback control;
see §6). Wire version `v` stays `1`: the extension relies on the existing
tolerant-receiver rules, so v1 peers without command support interoperate unchanged.
Changelog: 2026-10-31 (2) — added the optional **shared session** extension
(see §8): `trackHash`/`playbackId` on `state_update`, the single-active-device
invariant, `session_conflict` detection, and the recommended pause-on-peer-active
policy. Players own policy; the protocol owns state and violation detection.
Changelog: 2026-11-02 — **playback-mode extension**: five new optional `command`
actions (`repeat_off` | `repeat_all` | `repeat_one` | `shuffle_on` | `shuffle_off`)
and two optional `state_update` fields (`shuffle`: bool, `repeat`: `off`|`all`|`one`)
so peers can control AND observe each other's queue modes. All optional under the
tolerant-receiver rules; v1 peers interoperate unchanged.

## 1. Topology

- Full peer-to-peer mesh of direct connections on one local network. No server, hub, or relay.
- Every peer runs (a) an mDNS advertiser + browser, (b) one WebSocket (WS) server, and
  (c) acts as a WS client toward peers it dials.
- No audio, files, or payloads beyond control/simulated-state JSON. Protocol is
  platform-neutral so a Linux peer can be added later without protocol changes.

## 2. Discovery (mDNS / DNS-SD)

- Service type: `_musicshare._tcp` (registration domain `local.`).
- TXT record keys (all UTF-8 strings):
  - `id`   — persistent device id, UUID v4 lowercase
  - `name` — human-readable device name (≤ 128 bytes; recommend ≤ 63)
  - `v`    — protocol version = `1`
- The SRV record carries the host and the TCP port of the peer's WS server (dynamic port).
- Announce as soon as the WS server is listening; keep the service registered until
  shutdown. On clean shutdown: unregister, send `goodbye` to connected peers, close.
- A discovered peer becomes `gone` when the OS reports the service removed, or when no
  re-announcement has been observed for 60 s.
- Discovery is NOT proof a connection is possible. Discovery state and connection state
  are always tracked and displayed separately.

## 3. Connection establishment

Role rule (automatic discovery only):

- After resolving a peer (host + port), compare device ids byte-wise (lexicographic):
  - `myId < peerId` → I dial `ws://host:port` (caller).
  - `myId > peerId` → I wait for that peer to dial me (callee).
- Manual connect (UI / CLI `host:port`) overrides the rule: whoever entered the address
  is the caller, regardless of id ordering.
- At most ONE connection per peer id. Before a dial completes or a new socket is accepted,
  close any existing socket for that peer id — the newest wins (duplicate/simultaneous
  dial protection). Log the replacement on both sides where visible.
- One dial attempt per peer in flight at a time.

Handshake:

- On socket open, the caller immediately sends `hello`.
- The callee answers with `hello_ack` (carrying its own identity fields).
- Caller reports `connected` only after receiving `hello_ack`. Callee reports `connected`
  after sending `hello_ack`.
- Timeouts (5 s each, measured from socket open):
  - Caller: no `hello_ack` → close with code 4002, mark attempt `failed (handshake
    timeout)`. This is a timeout, not proof the remote device is down.
  - Callee: no `hello` → close with code 4002, log `handshake_timeout`.
- Immediately after the handshake completes, EACH peer sends its current `state_update`
  (same `seq`, no increment) so the other side has a fresh state snapshot.

Close codes (diagnostic convention; receivers always log code + reason):

- 1000 — normal closure (sent after `goodbye`)
- 4002 — handshake timeout
- 4003 — superseded by a newer connection for the same peer id
- 1011 — unexpected internal error before clean close

## 4. Keepalive and failure detection

- Every 5 s send a JSON `ping` to each connected peer.
- If the matching `pong` has not arrived within 10 s → close, mark the peer
  `unreachable (keepalive timeout; remote state unknown)`, start the reconnect schedule.
- RTT (ms) = `pong.ts` − `ping.ts` (clocks are comparable only within one peer;
  additionally log the local send→receive delta where cheap).

## 5. Reconnection

- After failure/disconnect, retry with delays 1.5 s, 3 s, 6 s, 12 s, 24 s, capped at
  30 s, each ±20 % jitter. Reset after success. Stop when the peer is `gone`; resume the
  schedule if it reappears.

## 6. Messages

One JSON text frame per message. Common envelope fields:

| field   | type   | meaning                                  |
|---------|--------|------------------------------------------|
| v       | int    | protocol version, always 1               |
| type    | string | message type (see below)                 |
| id      | string | unique message id, UUID v4               |
| from    | string | sender device id                         |
| ts      | number | sender clock, unix milliseconds          |
| replyTo | string | optional — `id` of the message this answers |

Type-specific fields are flattened into the envelope.

### hello
```json
{"v":1,"type":"hello","id":"7f6c…","from":"a1b2…","ts":1710000000000,
 "name":"Mac mini","platform":"macos","appVersion":"0.1.0"}
```

### hello_ack
Like `hello`, plus `replyTo` = the `hello.id`, and the callee's own `name`, `platform`,
`appVersion`.

### ping / pong
Envelope only. `pong` carries `replyTo` = the answered `ping.id`.

### state_update
```json
{"v":1,"type":"state_update","id":"…","from":"…","ts":…,
 "track":"Fake Track 01","status":"playing","positionSec":123.4,"seq":17}
```
- `status`: `playing` | `paused` | `stopped`
- `seq`: per-device monotonic counter, starts at 1 each app run, +1 per state change.
  It exists to expose conflicting/out-of-order updates.
- Receivers store the latest arrival per peer and display it. If `seq` ≤ last seen `seq`
  from that peer, ALSO log `state_conflict` (both seqs + receipt times). No resolution
  policy is applied — the newest arrival is displayed and the anomaly is recorded.
- Optional session fields `trackHash` and `playbackId` (§8) ride on this message when
  the peer implements the shared-session extension.
- Optional playback-mode fields (added 2026-11-02): `shuffle` (bool) and `repeat`
  (`off` | `all` | `one`) — the sender's current queue modes. Send them when the
  player has such modes; omit them otherwise. Receivers that implement the modes
  store the latest values per peer so their UI can reflect the remote player
  truthfully; all other receivers ignore them.

### test
```json
{"v":1,"type":"test","id":"…","from":"…","ts":…,"text":"hi from mac"}
```

### command  (optional v1 extension, added 2026-10-31)
Remote playback control, fire-and-forget:
```json
{"v":1,"type":"command","id":"…","from":"…","ts":…,
 "action":"pause","positionSec":42.5}
```
- `action` ∈ `play` | `pause` | `toggle` | `stop` | `seek` | `next` | `previous` |
  `repeat_off` | `repeat_all` | `repeat_one` | `shuffle_on` | `shuffle_off`.
  `positionSec` (number, seconds) is REQUIRED for `seek` and otherwise ignored.
  The `repeat_*` / `shuffle_*` actions (added 2026-11-02) set the target's queue
  modes; their effect is observable through the target's `state_update`
  `shuffle`/`repeat` fields.
- No reply message. The effect is observable through the target's subsequent
  `state_update` broadcast (senders must not assume success from silence).
- Receivers apply the command to their local player only if the local user has not
  disabled remote control. Unsupported or disabled → log `command_ignored`
  (`action=… reason=unsupported|disabled`), never disconnect.
- Commands are never relayed, echoed, or answered with `command` messages (no loops).
- Because §6's receiver rules already ignore unknown types, peers without command
  support interoperate unchanged; senders must tolerate silence.

### goodbye
Best-effort, sent before an intentional close:
```json
{"v":1,"type":"goodbye","id":"…","from":"…","ts":…,"reason":"app_shutdown"}
```
`reason` ∈ `app_shutdown` | `user_close` | `manual`.

### Receiver rules (both platforms)

- Unknown `type` → log `message_unknown`, ignore, do NOT disconnect.
- Missing/invalid required fields → log `message_malformed`, ignore.
- `id` already seen within the last 128 received ids from that peer → log
  `message_duplicate`, ignore.

## 8. Shared session (optional v1 extension)

For devices whose users keep **identical music libraries** (e.g. synced externally).
Lets a user hand playback to another device: "Hallelujah" playing on the mac can be
resumed on the phone, at the same position, from the phone's own copy of the file.
Players own policy; the protocol owns session state and violation detection.

### Track identity

- `trackHash` — lowercase hex SHA-256 **of the audio file's bytes** (tags included;
  synced libraries are byte-identical). Devices implementing this extension hash
  their library files lazily and cache by (path, size, mtime).
- `playbackId` — UUID v4 identifying one continuous playback stint: fresh on every
  track start and on every takeover; a pause→resume of the same stint keeps it.
- Both fields are OPTIONAL on `state_update`. Absent `trackHash` = the peer does not
  participate in the session extension; session features are disabled toward it.

### Single-active invariant

At most one device among {self + connected session-capable peers} has
`status == "playing"` at any time. The invariant is *observed, not enforced*: every
device evaluates it continuously from the state it sees and self-reports.

### Takeover flow (reference)

1. The user on device B taps "resume here" while peer A is active.
2. B resolves A's latest `trackHash` against its local index:
   - found → B starts local playback of that file at A's last-known `positionSec`,
     with a fresh `playbackId`, and broadcasts `state_update` (`playing`) immediately;
   - not found → B fails locally with a `library_unsynced` error (surfaced to the
     user). B stays silent; a silent takeover attempt means it did not happen.
3. A receives B's `state_update` (`playing`) while itself playing and applies its
   **pause-on-peer-active policy** (recommended default, player-implemented): pause
   itself. The protocol does not require this policy — but our two reference players
   implement it.

### session_conflict (violation event)

If a device observes ≥2 playing devices among {self + connected session-capable
peers} for longer than a 2 s handoff grace (legal takeovers overlap briefly), it
emits a local `session_conflict` event naming the involved device ids, logs it, and
surfaces it to the user. The protocol never auto-resolves a conflict — resolution
belongs to the player implementation. Typical cause: a connection dropped, both
sides started playing, the connection returned.

## 7. Structured logging

Both apps log JSON lines with at least: `ts` (ISO-8601 incl. ms), `level`, `event`,
`localId`, and where applicable `remoteId`, `localAddr`, `remoteAddr`, `elapsedDiscoveryMs`
(since discovery start), `elapsedConnMs` (since dial started), `rttMs`, `error`, `detail`.

Event vocabulary:

```
app_start app_stop discovery_start discovery_stop announce permission_request
permission_granted permission_denied net_change peer_found peer_lost connect_attempt
connect_ok connect_failed connect_timeout handshake_sent handshake_ack handshake_timeout
disconnect reconnect_scheduled ping_sent pong_recv keepalive_timeout rtt state_sent
state_recv state_conflict msg_sent msg_recv message_duplicate message_unknown
message_malformed error
```

Required measurements (both platforms, log at info level):

- app_start → discovery live
- app_start → first peer_found
- peer_found → connect_attempt
- connect_attempt → connect_ok (total connection establishment time)
- ping_sent → pong_recv (RTT)
- last successful pong → keepalive_timeout (failure detection latency)

## 8. Out of scope for v1

Audio, file transfer, message relay, encryption/identity verification, NAT/WAN traversal,
background services, conflict-resolution policy, playback synchronization.
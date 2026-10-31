# ADR-097: Presence - the peer protocol (mDNS + WebSocket)

> Depends on: `ADR-004` (nothing), `ADR-067` (the lifecycle + Bonjour patterns it
> mirrors). Touches **Playback** (a per-subscriber state fan-out), **UI**,
> **App**. The wire contract is frozen: `docs/design-spec/PROTOCOL.md` (copied
> from the Music Share protocol repo; canonical source there, do not diverge).

## Goal

Implement the P2P "presence" protocol in Bòcan: every running Bòcan advertises
itself over mDNS (`_musicshare._tcp`), discovers other Bòcan peers on the LAN,
connects over a WebSocket, keeps the connection alive with a 5 s ping / 10 s
pong budget, and shares what each side is playing (track, artist, status,
position). A macOS peer and an Android peer speak the same contract; the
contract is field-for-field normative for both.

## Outcome shape

```
Modules/Presence/Sources/Presence/
  PresenceEngine.swift            // public actor: lifecycle, manual connect
  PresenceEngine+Connections.swift // dial, accept, adoption, close/reconnect
  PresenceEngine+State.swift      // receiver rules, own-state policy, discovery, publishing
  PresenceEngine+Tick.swift       // housekeeping tick, churn defenses, expiry
  PresenceEngine+Testing.swift    // internal test hooks
  PresenceConfig.swift            // contract constants (injectable for tests)
  BackoffSchedule.swift           // 1.5 -> 30 s ladder, +-20% jitter
  PresenceIdentity.swift          // persisted device id + injected name closure
  PeerDirectory.swift             // snapshot types + per-subscriber fan-out
  Wire/PresenceMessage.swift      // envelope + typed message payloads
  Wire/WireCodec.swift            // JSON encode/decode + receiver rules
  Connection/PeerConnection.swift // per-connection actor: handshake, keepalive, latch
  Connection/PeerConnection+Wire.swift
  Transport/NWWSSocket.swift      // WSTransport over NWConnection + WS options
  Transport/PresenceListener.swift// NWListener + Bonjour service + permission browser
  Discovery/PresenceBrowser.swift // NWBrowser browse with TXT records
  Playback/PlaybackTap.swift      // QueuePlayer fan-out -> PresencePlaybackState
Modules/Playback/Sources/Playback/
  PlaybackTapSnapshot.swift       // (PlaybackState, QueueItem?) for non-UI observers
```

The DAG gains `Playback -> Presence` and `UI -> Presence`; Presence imports
Playback, AudioEngine (for `PlaybackState`) and Observability. It never imports
AppKit: the device name arrives as an injected `@Sendable () -> String`
closure (the SyncServer pattern).

## Decisions

### One connection actor per socket; liveness state dies with it

The reference MVP's worst measured defects (its defects 2, 10 and 11) were all
stale-liveness bugs: outstanding-ping bookkeeping that survived the transport
it belonged to, so a fresh handshake inherited a stale budget and was judged
dead on its first tick. Here, every piece of per-connection liveness state
(outstanding-ping map, last-pong time, ping clock) lives inside the
`PeerConnection` actor and is cleared at every handshake completion. When a
socket dies, is superseded, or is watchdog-closed, the actor is discarded with
its state; the engine keeps only per-peer session facts (seq memory, RTT,
backoff). A one-shot teardown latch makes every keepalive/timeout decision
idempotent: after it fires, ticks are no-ops and the socket closes exactly
once, and late transport events cannot produce a second death.

### Network.framework on both ends (not URLSessionWebSocketTask)

`URLSessionWebSocketTask` cannot send custom close codes (4002/4003), which the
contract requires. Both the listener's accepted sockets and outgoing dials use
`NWConnection` with `NWProtocolWebSocket.Options`; `CloseCode.applicationCode`
covers the 4xxx range. The listener advertises `_musicshare._tcp` through the
listener's own `service` (one lifecycle for port and advertisement), plus the
SyncServer's permission-prompt browser trick: a sandboxed advertise-only server
is never prompted, so a companion browse of our own service type is what makes
the advertisement publish at all.

### Discovery stays on NWBrowser; TXT records carry the tie-break id

On this SDK, `NWBrowser.Result.Metadata.bonjour(NWTXTRecord)` delivers the TXT
record with every browse result, so the device id needed for the smaller-id-
dials tie-break is available without a separate resolve step (the MVP needed a
NetService resolve). Because NWBrowser only reports set *changes*, a fresh
browse pass every 45 s refreshes each peer's announcement clock; the 60 s
expiry backstop then only fires for genuinely vanished services. Churn
defenses follow the MVP's measured fixes: a 2.5 s removal debounce, a
healthy-socket guard (a CONNECTED socket with a pong inside 15 s is never
marked gone from a discovery hint), expiry excluding connected peers and never
sending goodbye, and announce refresh on every valid message.

### Transport events flow through one ordered pump

Socket callbacks hop into the connection actor through an internal
`AsyncStream` drained by a single consumer task. Creating one unstructured Task
per event does not preserve ordering across actor hops, and a handshake can
then race its own `hello_ack`; the pump makes socket events first-come,
first-served by construction.

### Own-state policy: broadcast on change, refresh position at most every 10 s

The playback tap maps `QueuePlayer`'s fan-out (playing/paused/else ->
playing/paused/stopped, `QueueItem.title` -> `track`, `artistName` -> the
`artist` extension field, polled `currentTime` -> `positionSec`). Track,
artist and status changes broadcast immediately (+1 seq, contract section 6);
position drift while playing re-broadcasts at most every 10 s. Every broadcast
bumps the seq, so a receiver never sees a non-advancing seq (which the
contract counts as a conflict). The post-handshake snapshot intentionally
re-sends the current seq, which the contract's receivers log as a conflict:
the MVP measured this as intended noise.

### Receiver rules, verbatim

Unknown `type`, malformed frames and duplicate ids (128-message window per
peer) are logged and ignored; none of them disconnect. `goodbye` suppresses
reconnection until the peer is seen again (goodbye = gone, contract section 5);
`state_conflict` is recorded, newest arrival displayed, no resolution policy.

### Testing and the transport fallback (amended 2026-10-31)

First written against a wrong diagnosis (a Local Network grant keyed on the
runner binary's code identity); the amendment below supersedes it after the
root cause was measured. The test design it produced - capability probes that
degrade instead of failing, and protocol coverage that does not depend on the
broken path - survives the correction unchanged.

## Amendment 2026-10-31: the NW listen path is broken on this macOS build; BSD + NetService fallback

## Root cause (measured)

On this machine (macOS 26.2/27.2-era build, 26B123), `NWListener` fails at
`start` with `POSIXErrorCode(rawValue: 22): Invalid argument` in every
configuration probed: plain TCP with no options, with the Presence
`WSParameters`, with Bonjour service registration, fixed port and ephemeral
`.any`, loopback and any-interface. `NWConnection` with
`NWProtocolWebSocket` options cannot even open TCP to a local server
(`waiting` POSIX 50, no bytes leave), while on the same machine and from the
same processes:

- POSIX BSD socket/bind/listen/accept work.
- `NWConnection` plain-TCP client dials work.
- CLI `dns-sd` browsing works.
- Foundation `NetService`/`NetServiceBrowser` advertise, resolve and browse
  work - the MusicShareMVP reference peer has run for days as bare unbundled
  binaries on exactly this stack, advertising, being discovered and dialled.

An earlier theory (this ADR's first cut) attributed the EINVAL to the macOS
Local Network grant following the runner binary's code identity. That was a
misattribution: the same failure shape appears in processes that hold grants,
and the Foundation/BSD stack works without any grant.

## Fallback design

`PresenceConfig.transportStack` selects the stack:
`.networkFramework` (primary), `.bsdSocket` (fallback), `.automatic`
(default: run NW, fall back on failure).

- **Listener**: `PresenceListener.start` runs the NW listener and races its
  readiness against a 2 s probe window; `.failed` or a probe timeout tears
  the NW listener down and starts `BSDWSServer` - a POSIX
  socket/bind/listen on an ephemeral port, accepting via a
  `DispatchSourceRead`, handing each descriptor to a server-role
  `BSDWSSocket`.
- **WebSocket over BSD**: `BSDWSSocket` implements the minimal RFC 6455
  server and client on POSIX sockets on dedicated threads: HTTP upgrade
  handshake with `Sec-WebSocket-Accept` (CryptoKit SHA-1 + base64, pinned to
  the RFC's test vector in tests), masked client frames and unmasked server
  frames, ping/pong, the close handshake, and simple text fragmentation via
  `WSMessageAssembler`. The frames interoperate with Network.framework's WS
  client (verified) and with the MVP's RFC server.
- **Discovery**: the BSD stack advertises and browses with Foundation
  `NetService`/`NetServiceBrowser` on a private run-loop thread
  (`NetServicePresence`), same TXT record (id/name/v), same 45 s fresh-browse
  refresh, same resolve-to-announcement shape as `PresenceBrowser`. Its own
  browse of `_musicshare._tcp` is what raises the Local Network prompt on the
  fallback stack.
- **Dials**: the engine's dial follows the effective stack - `NWConnection`
  (WS options) on NW, `BSDWSSocket.client` (POSIX connect + upgrade request,
  masked frames) on BSD. NetService announcements carry the resolved
  host/port for the BSD dial path.
- **Decision surface**: the engine reads the listener's effective stack and
  routes discovery and dials accordingly; `.automatic` resolves at start and
  never changes afterwards. Both stacks implement the same `WSTransport`
  seam, so `PeerConnection` (handshake, keepalive, liveness) is
  stack-agnostic.

## Verification after the amendment

- `listenerLoopbackOverBSDSockets`: two engines over real loopback sockets
  (BSD server + BSD client dial): handshake, state both ways, ping/pong with
  RTT, clean goodbye, zero reconnect. Runs everywhere; no escape hatch.
- `networkListenerLoopbackWhenBindable`: the same session over the NW stack,
  recording a known issue where the NW listen path is broken.
- `WSFrameCodecTests`: masked/unmasked frames, 16-bit lengths, truncation,
  oversize, fragmentation with interleaved control frames, close codes, and
  the RFC 6455 `Sec-WebSocket-Accept` test vector.
- `PresenceListenerFallbackTests`: `.automatic` resolves to a working stack
  (NW where it binds, BSD where it does not), the forced BSD stack binds.
- Reference interop: the launched MVP discovered the engine over mDNS,
  tie-break elected the MVP (smaller id), it dialled the engine's BSD server
  over its own client, and the full session - hello/hello_ack, state both
  ways, smoke test, pings with RTT, and goodbye on the MVP's graceful
  shutdown with zero reconnect - ran between the two implementations.

## Amendment 2026-10-31 (2): the `command` extension (remote playback control)

The contract gained an optional `command` type (PROTOCOL.md section 6,
changelog 2026-10-31): `{"v":1,"type":"command","action":"play|pause|toggle|
stop|seek|next|previous","positionSec":42.5}`, fire-and-forget, no reply, the
effect observable through the target's next `state_update`; positionSec is
required for seek; receivers log `command_ignored
(action=..., reason=unsupported|disabled)` for anything they do not apply and
never disconnect, relay or echo. The wire version stays 1.

Implementation:

- **Wire**: `PresenceMessage.command(PresenceCommand)`; the raw action string
  is preserved through decoding so foreign actions surface as
  `command_ignored reason=unsupported` (the tolerant-receiver rule), not as
  malformed frames. `seek` without `positionSec` is malformed per section 6's
  missing-required-field rule. Unknown `type`s still fall through
  `message_unknown`, so v1 peers without command support interoperate
  unchanged.
- **Receiver**: `PresenceEngine.applyInboundCommand` runs the gate then the
  injected executor (`controlEnabled: () -> Bool`,
  `commandExecutor: (PresenceCommandAction, Double?) async -> Bool`), logging
  `command_recv` on acceptance and `command_ignored` with
  `reason=disabled|unsupported` otherwise. Commands are never relayed or
  answered.
- **Sender**: `PresenceEngine.sendCommand(peerID:action:positionSec:)` logs
  `command_sent`; always allowed, regardless of the local gate.
- **App mapping** (buildGraph executor, onto QueuePlayer): play -> play();
  pause -> pause(); toggle -> togglePlayPause() (new public wrapper over the
  media-key path, so remote toggles match media-key semantics including the
  `.failed` state emission); stop -> pause() + seek(0), because
  QueuePlayer.stop() would eject the current track and clear Up Next, which
  is not what a remote stop means (mapping documented at the executor);
  seek -> seek(to: positionSec); next/previous -> the queue operations with
  their CUE-marker and restart-threshold semantics.
- **Gate**: `presence.controlEnabled` (default on, registered), toggled in
  Settings -> Presence ("Allow peers to control playback"); read live per
  inbound command. Outbound commands are unaffected by the gate.
- **UI**: the Peers window gains per-row play/pause/stop buttons (greyed out
  unless the peer is connected) sending `command` frames; the Debug Presence
  window shows `command_sent` / `command_recv` / `command_ignored` lines.

## Amendment 2026-10-31 (3): the shared session (takeover handoff)

The contract gained the optional shared-session extension (PROTOCOL.md
section 8): `state_update` carries optional `trackHash` (lowercase-hex SHA-256
of the audio file's bytes) and `playbackId` (UUID v4 of one continuous
playback stint - fresh on every track start and every takeover, kept across a
pause-to-resume). Absent `trackHash` = the peer does not participate in the
session extension; session features are disabled toward it. At most one device
among {self + connected session-capable peers} plays at a time - observed, not
enforced; a two-or-more overlap longer than the 2 s handoff grace is a local
`session_conflict` naming the device ids, never auto-resolved. Players own
policy; the protocol owns state and violation detection.

Implementation:

- **Track identity reuses `tracks.content_hash`**: that column already holds
  the lowercase-hex SHA-256 of the audio file's bytes (CryptoKit-streamed by
  `ContentHashService` through the track's security-scoped bookmark), which is
  exactly the contract's `trackHash`. The contract's "(path, size, mtime)"
  caching prescription maps onto Bòcan's existing mechanisms: the digest is
  persisted and never recomputed for an unchanged file, a changed file's
  re-import resets it to NULL (the scanner's conflict path is the staleness
  signal), and the background backfill is the incremental builder - lazy,
  off-the-hot-path. `TrackHashIndex` (Library) is the session face:
  `hash(trackID:)` (persisted digest, hashing lazily on first use) and
  `track(forHash:)` (the resolver; nil = the contract's `library_unsynced`).
- **Wire**: `PresencePlaybackState` carries optional `trackHash`/`playbackId`;
  absent stays absent on the wire (non-capable peers interoperate unchanged).
- **Stint rules** (`applyOwnState`): entering `.playing` with a track hash
  different from the current stint's (or without a stint) mints a fresh UUID;
  a pause-to-resume of the same track keeps it; a paused/stopped peer keeps
  reporting its last stint so peers can resolve a handoff source. The handoff
  UI calls `beginPlaybackStint()` before starting local playback, because a
  takeover of the same track must still be a new stint.
- **Takeover signal**: on a received session-capable `playing` state whose
  `playbackId` differs from the last seen one, the engine logs
  `presence.session.peer_active` (`<- peer active: name - track @pos`) and
  fires `onPeerBecameActive`. The App's policy is section 8's recommended
  default: pause-on-peer-active (only when this Mac is itself playing, logged
  as `presence.session.auto_paused`). The engine never mutates playback.
- **Violation detection**: every tick the engine evaluates the invariant;
  `sessionConflictGrace` (default 2 s) bounds the legal handoff overlap, and
  `presence.session_conflict` fires once per episode naming the device ids
  (callback `onSessionConflict` for player-level surfacing). Nothing is ever
  auto-resolved.
- **UI**: the Peers window shows "Play here" on a session-capable peer's row
  (enabled while connected): it resolves the peer's `trackHash` locally,
  starts the local copy at the peer's position (`beginPlaybackStint` +
  `loadAndPlay` + `seek` + `play`), and surfaces `library_unsynced` ("Library
  not synced") locally - silent on the wire, per the contract. Handoff
  attempts and conflicts log through `.presence`, so the Debug Presence
  window shows them in human-readable form.

## App wiring

`App/BocanApp.swift` constructs the engine (and the Settings and Peers view
models) in `buildGraph` unconditionally, starts it only when
`presence.enabled` is on (default off), re-advertises after wake, and
`AppShutdown.perform()` stops it (goodbye + unregister) inside the quit
budget. `Resources/Info.plist` gains `_musicshare._tcp` under
`NSBonjourServices` and a broader `NSLocalNetworkUsageDescription`. The
`Makefile` gains `test-presence`.

## Consequences

- The debug log of the engine is the UI for the Debug Presence window: every
  protocol event flows through `AppLogger.make(.presence)` with direction
  arrows and key fields (`-> state_update to X: track=..., status=...`).
- `artist` is a Bòcan extension field; receivers that do not know it ignore it
  per the contract's ignore-unknown rule.
- Manual connect (`connectManual(host:port:)`) exists for tests and future UI;
  the caller-role override matches contract section 3.

## Amendment 2026-10-31 (4): the shared session on the main window surface

- Connection and session are different axes in the main window too: an active
  peer connection is not an active shared stint, and losing connectivity never
  silently switches the strip back to local. A disconnected stint renders its
  last-known state with `Color.warningTint` ("last known from <peer>"), and
  "Take over here" stays legal while unreachable or gone (section 8's conflict
  machinery covers the overlap).
- Transport dispatch branches only in the main window's wrappers
  (`NowPlayingViewModel.sessionPlayPause/sessionScrub/sessionNext/
  sessionPrevious`): remote-connected stint -> `command` to the stint peer;
  otherwise the plain local methods. The existing `playPause`/`scrub`/`next`/
  `previous` keep their local semantics unchanged.
- Mini player, menu bar and media keys remain 100% local: they call the local
  methods directly and hold zero session/Presence references.
- Position display dead-reckons in the view only (lastKnown.positionSec +
  elapsed while the peer reports playing); `SessionView.LastKnown` stays the
  single authoritative pair and nothing is written back.
- The conflict banner mirrors the engine's conflict episodes: it cites the
  device names, never auto-dismisses, and never auto-resolves.

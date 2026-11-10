# Description

Code review 6 (2026-11-10) of the extension: all of `SplitPipeProxy` and the parts of `Shared` it uses. Findings of
[review 4](2026-11-06-review-4-security.md) (probe URL, `bucket == 0`, port 53, UDP checks by the first address, relay
cap, relay after `stopProxy`) and of [review 5](2026-11-10-review-5-network-reconnect.md) are not repeated.

Checked and found fine: lock ordering (no nested acquisition in opposite order), reuse of a flow's `ObjectIdentifier`
(the `recordID` comparison closes the race), backpressure in `TCPRelay` (a read waits for the write in both
directions), IP list lookup and range merging. The guess that a connection by name bound to a utun fails on DNS was not
confirmed: two hours of relay errors contain IP addresses only.

# Implementation

## Step 1: serious

[x] **UDP: a separate source port per destination** (`SplitPipeProxy/UDPRelay.swift`). Every destination got its own
   `NWConnection` — its own socket and local port (from the code; not measured on a live flow). STUN saw one port while the peer got packets from another, so direct P2P (calls, WebRTC, torrents) did not
   work for apps with a rule, and a datagram from an address the app had not sent to yet was dropped. Fix:
   `UDPSockets` — unconnected BSD sockets, one per address family and binding (interface or system route: DNS and,
   with "LAN via system", local addresses go by the system route), `sendto` / `recvfrom`; names are resolved by the
   system resolver. Checked outside the extension: unit tests on loopback and a STUN probe bound to utun4 (the same
   mapped port from two servers). Binding to en1 needs root behind the kill switch and was not checked; nothing is
   verified inside the extension on a real machine.
[x] **"Abort connections when the rule changes" also switched off aborts on network changes**
   (`TransparentProxyProvider.swift`, `reevaluate`). With `abortOnChange == false` nothing was re-evaluated:
   "Default" connections opened through en1 while the VPN was reconnecting stayed outside its kill switch, and the ones
   bound to a recreated utun hung until a timeout. Fix: the setting covers rule changes only; a changed binding always
   aborts.
[x] **Nagle on the relay's outgoing TCP connection** (`TCPRelay.swift`). `TCP_NODELAY` set by the app on its own
   socket did not reach ours: delays on small writes for SSH, games, RPC. Fix: `noDelay = true`.
[ ] **"Direct" falls back while the helper holds its routes** (`decide`, `directMode == .unavailable`). After
   review 5 the helper returns the routes only when the tunnel passes traffic: up to 5 s on a link blink and 15 s on a
   VPN restart (it was about 0.7 s). With the fallback "Default" the app goes through the VPN for that time and is
   switched back afterwards; with "Block" it is paused. Decide: wait in the extension (like `pending`) instead of
   falling back, or shorten the hold.
[ ] **A dead VPN is invisible to the extension**: the interface exists, so the route is "available", the fallback
   never triggers and every connection waits for the 30 s timeout. The helper's watchdog (review 5) sees it but does
   not tell the extension.

## Step 2: medium

[ ] **`stats.json` is rewritten whole once a minute** (`TrafficStats.swift`, `save`): 30 days of hourly rows per app
   and route. Estimated megabytes per write; the file is in root's container and its size was not checked. Fix: write
   only the fine and the current hourly buckets often, the rest once an hour.
[x] **Address string built for every datagram** (`UDPRelay.swift`, `stats.seen(remote: endpoint.display)`). Fixed
   with the UDP rewrite: once per flow.
[ ] **A record differs from where the connection went** (`open`): local addresses and DNS go by the system route,
   but the binding, the feed label and the statistics keep the rule's interface. Such connections are aborted for
   nothing when the interface disappears and are counted on the wrong route.
[ ] **The network snapshot every 15 s reads the whole process list** and opens several SCDynamicStore sessions even
   when nothing changes.
[ ] **Every status poll** builds a dictionary over all relays and carries up to 1000 `unruledApps`, even when the
   screen asked only for the network.

## Step 3: minor

[ ] `configProblem` is not cleared on a second `startProxy` with a readable configuration.
[ ] Timers and monitors keep running when `setTunnelNetworkSettings` fails.
[ ] `unruledSeen` is dropped whole at 1000 entries.
[ ] An ordinary RST from a server is logged as an error (88 in two hours).
[ ] `InterfaceRegistry.stop()` keeps the interface list; `probe` does not compare the interface index.

## Step 4: live verification

[ ] UDP through the extension on a real machine: a call or WebRTC app with a "Direct" and a VPN rule (one source port
   for STUN and the peer), DNS, QUIC, a LAN destination with "LAN via system".
[ ] A VPN reconnect with "Abort connections when the rule changes" off: "Default" connections move back to the VPN.

# Description

Fixes from code review 2 (2026-10-19). Done on 2026-10-19 before this plan: the helper pf rule is `flags any no state`
(item 1), connections by the system route are bound to the default route's interface (P0).

# Implementation

## Step 1: P1

[x] **Extension heartbeat for the helper** (done 2026-10-21, see [review 3](2026-10-20-review-3-fixes.md)): the app is
   closed and the system stopped the proxy — the helper holds the pf bypass and scoped routes forever. The extension
   touches `heartbeat` next to `stats.json` every 15 s and deletes it in `stopProxy`; the helper, when `enabled` and the
   heartbeat is older than 60 s, removes pf and the routes ("extension not responding").
[x] **Loopback, multicast, broadcast:** `excludedNetworkRules` for `127.0.0.0/8` and `::1`; `isLocal` gets
   `224.0.0.0/4`, `255.255.255.255`, `ff00::/8`. Check whether NE hands over loopback flows (`curl localhost` from a
   "Direct" app). 2026-10-21: `excludedNetworkRules` for `127.0.0.0/8` and `::1`; `isLocal` also covers `127/8`,
   `224/4`, `255.255.255.255`, `ff00::/8`, `::1`, `100.64/10` (CGNAT, Tailscale). Not verified live.
[x] **Do not remove scoped routes on a VPN-gone timer** (30 s), only when SplitPipe is turned off and the physical
   interface changes: a VPN reconnect longer than 30 s caused two "Direct" drops instead of none. 2026-10-21: timer
   removed — routes are removed only when SplitPipe is turned off, the physical interface changes, or configd removes
   the scoped `default`.
[x] **The "Default" relay replaces the connection owner** for other firewalls (Little Snitch, LuLu), `nettop` and pf by
   user: all connections are `dev.splitpipe.app.proxy` (root). Decide: document it in known limitations, or for
   `RouteID.system` without binding hand the flow back to the system and switch by a helper reset. 2026-10-21: kept for
   instant switching, documented in [known limitations](../known-limitations.md).

## Step 2: P2 — network and extension

Done 2026-10-23 except the last item; not verified live.

[x] `ConnectionResetter` works only because Amnezia's rules are `no state`: with a pf state entry `block return` does not
   fire (another VPN client). Document it; check `pfctl -ss` in `cleanup()`. Documented in known limitations; after a
   reset the helper looks for the connections in `pfctl -ss` and logs which won't be reset.
[x] `cleanup()` walks the descriptors of all processes every 15 s — walk only pids with blocked connections and all of
   them rarely. Walks only pids where connections were found; a full pass is not needed — TCP rules are now removed on
   the first packet, and a socket handed to another process simply won't be reset.
[x] 4-tuple reuse after a reset: a new connection with the same port falls under the rule for up to 30 min — remove the
   rule on the first RST (counter in `pfctl -vsr`). TCP only: ICMP unreachable does not close a UDP socket, its rule
   lives until the socket closes.
[x] `ManagedApps.contains` requires `/Applications/` in the path — apps from `~/Downloads`, DerivedData, Steam,
   JetBrains Toolbox are not managed. Now any `.app/Contents/MacOS/` except system paths (`ManagedApps.isSystem`:
   `/System/Library`, `/Library/Apple`, `/usr`, and the same in cryptexes). The same filter for menu bar apps in Running
   (`AppModel.isUserApp`).
[x] IPv6 exit only by `::/0`, `::/1`, `8000::/1` — WireGuard with `2000::/3` counts as "no IPv6". Count as an exit a route
   with prefix ≤ 3 covering `2001::` (`NetworkState.covers2001`).
[x] TCP keepalive in the relay (`NWProtocolTCP.Options`: `enableKeepalive`, `keepaliveIdle = 60`) — idle connections
   (IMAP IDLE, WebSocket) die on NAT.
[x] `Probe` treats `.waiting` as a failure at once — wait 5 s like the relay.
[x] `record()` on every system flow (hot path, `lock` and `order.removeFirst()`) — `.passed` is recorded only for
   processes inside a `.app`, without rules and "Manage all apps" nothing is recorded; old records are removed in
   batches.
[x] `RouteMonitor.drain`: on `ENOBUFS` events are lost until the timer — call `onEvent?(nil)`, `SO_RCVBUF` 256 KB.
[x] A UDP flow is closed whole after 60 s of silence — 5 min for the flow, 60 s for individual peers.
[x] `startIfStopped()` after an extension replacement tries once — 3 attempts 2 s apart, also on `.invalid` (after
   re-reading the configuration; review 3).
[ ] Investigate if it happens outside a reconnect: `tcp 192.168.1.250:22 … Network is unreachable` (2026-10-18 23:40,
   LAN, `lanViaSystem`, root) — `route -n get`, `pfctl -sr` at the moment of failure.

## Step 3: P2 — the rest

Done 2026-10-23.

[x] `Guardian.tick()` runs `pfctl` three times — `checkAnchorEffective` at most every 5 s (immediately after an anchor
   reload and 3 s after a VPN change).
[x] `addRoutes`: `File exists` also contains `add net` — check `terminationStatus` (`Guardian.execute`).
[x] Rename `HelperStatus.scopedRoute` to `directUsable` (means "Direct works", including `.system`). The JSON keeps the
   old key: app and helper of different versions understand each other.
[x] `AppModel.init` silently adds the app to Login Items on first launch — now only after onboarding: the "You're All
   Set" screen has the checkbox "Open SplitPipe at login" (this is "Start at boot").
[x] Makefile: `EXTENSION_VERSION` by mtime — in a git repo `git log -1 --format=%ct -- SplitPipeProxy Shared`, without
   git or with uncommitted changes in those folders — by mtime as before.

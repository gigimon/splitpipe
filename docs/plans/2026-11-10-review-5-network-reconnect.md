# Description

Code review 5 (2026-11-10) of the network module, focused on one symptom: Amnezia stays in "reconnecting" after sleep
until it is reconnected by hand. Checked against the code and against the logs of the incident of 2026-11-09.
Background: the incident history in [system notes](../system-notes.md).

## Incident 2026-11-09 21:43 → 22:59

The tunnel died not on the user's wake (22:58:52) but 76 minutes earlier, during a background wake:

- 20:19–21:43 — the tunnel works, no timeouts.
- 21:43:23.748 — Amnezia removes `0/1` through utun4 (quick reconnect on the same utun).
- 21:43:23.776 — the helper starts removing its routes; 21:43:24.031 — done, 283 ms after the event (28 ms for the
  network snapshot, 255 ms for two `/sbin/route` runs on a waking system; usually 15–27 ms).
- In those 283 ms Amnezia removed and re-added all its routes. Kernel order: Amnezia deleted the host route to its
  server → we deleted `0/1` → Amnezia added the host route, `0/1`, `128/1` → we deleted `128/1`. Our `0/1` (the server
  62.182.x is inside it) was still there while the host route was missing — the window from system notes.
- 21:43:24 → 22:59:57 — every connection through utun4 ends in `connect timeout`. Amnezia ignores its own triggers
  ("Reconnect triggered on Reconnecting during inappropriate state; ignoring slot"). The helper does nothing useful
  during a dozen wakes: all its triggers fire only at the moment the VPN reconnects.
- 21:56:10–21:56:23 — neither our routes nor our pf rule were present (false "proxy not running") and the tunnel did
  not revive: once dead, removing the routes is not enough.
- 22:59:57 — manual reconnect, the tunnel works at once.

What exactly breaks in the kernel is still not established: the next incident needs `route get` to the server at the
moment of the stall (step 2 collects it).

# Implementation

## Step 1: remove routes fast enough

[x] **Route removal takes up to 283 ms** (`SplitPipeHelper/main.swift`, `dropRoutes`). The "early" trigger takes a
   full `NetworkState.current()` with VPN detection and then runs `/sbin/route` twice. Fix: `RouteSocket.deleteScoped`
   writes `RTM_DELETE` to the routing socket (no fork), the routes to remove come from the last snapshot; `/sbin/route`
   stays as a fallback when the write fails. The message format is checked with `RTM_GET` against a live table
   (finds the scoped `PROTO2` routes); the delete itself needs root and is not verified live.
[x] **`logPFOnVPNChange` blocks the helper queue** — five `pfctl` runs exactly when the VPN reconnects, delaying the
   early triggers. Fix: the dump runs on a background queue.
[x] **`RTM_DELETE` through an already destroyed utun is dropped** (`Shared/NetworkState.swift`, `RouteMessage`;
   `Shared/RouteMonitor.swift`, `parse`): `if_indextoname` returns nil and the message becomes `.ignored`. Fix: the
   name comes from the monitor's index table, which keeps names of detached interfaces.

## Step 2: detect a dead tunnel

[x] **Nothing notices a tunnel that passes no traffic.** `tick()` sees "VPN holds the default route, routes present"
   and is satisfied. Fix: a watchdog in the helper samples the VPN utun packet counters every 5 s; packets go in and
   nothing comes out for 30 s of uptime → one reaction per stall: a diagnostic dump to the log (`route get` to the VPN
   server, plain and scoped; the routing table), event `routesDropped(.tunnelStalled)` in History, our routes removed
   and held until traffic returns (at most 15 s).
[ ] **Notification "VPN passes no traffic"** in the app (the event is in History only).
[ ] **Feed from the extension**: share of timed-out connections through a VPN route as a second signal.

## Step 3: no false "proxy not running" after sleep

[x] **Heartbeat freshness uses the wall clock** (`proxyRunning`), the extension timer runs on uptime. After every
   sleep longer than a minute the helper flushed the pf rule and the routes, logged an error and re-armed 2–14 s
   later, inside the VPN's own reconnect window. Fix: the heartbeat is also fresh while less than `heartbeatMaxAge`
   of uptime has passed since the helper last saw it fresh.

## Step 4: put routes back only when the tunnel works

[x] **"Host route is back" was taken for "the VPN has reconnected"**: routes returned 0.2–0.4 s later, before the
   handshake (21:44:13.341, with the network just coming up). Fix: one hold state (`Hold`): wait for the VPN host
   route, then for packets coming out of the tunnel; limits 15 s (VPN restart, wake) and 5 s (link blink).
[x] **The wait for the host route was re-armed after it had already returned** (21:43:39: 15 s without "Direct").
   Every trigger set it, and kernel events and SCDynamicStore callbacks arrive out of order with the routing socket.
   Fix: the helper tracks VPN host routes from routing socket events; a trigger waits for the host route only while
   there is none.
[x] **`scheduleTick` debounce**: a later event shortened a requested 1 s pause to 0.5 s (22:28:07.322 → 07.996), and
   a stream of events postponed reconciliation without a limit. Fix: the minimum pause lives in `Hold`; a pending tick
   is never postponed more than 2 s from the first request.
[x] **Silent triggers**: a trigger that found no routes of ours logged nothing. Fix: every trigger is logged.

## Step 5: sleep and wake

[x] **The helper does not know about sleep**; removal before sleep relied on "link down", which does not always come
   (21:56:39, 22:54:37 — routes survived the sleep). Fix: `PowerMonitor` (`IORegisterForSystemPower`): routes are
   removed before sleep, after wake they return through the same hold.

## Step 6: other findings, not done

[ ] `scheduleNetworkRefresh` in the extension has the same unbounded debounce.
[ ] A rule by path or by responsible app is applied to a VPN client: `VPNCatalog.isClient` is checked only for a
   direct signing id match (`Shared/Messages.swift`, `match`). Overlaps with review 4, "VPN client match".
[ ] `UDPRelay.receive` stops reading on error but keeps the peer for up to 60 s.
[ ] `NetworkState` opens a new SCDynamicStore session per call, several per snapshot.

## Step 7: live verification

[ ] Sleep and wake, DarkWake, Wi-Fi roaming and a quick Amnezia reconnect on a real machine with the new helper:
   routes removed through the routing socket (helper log: "сняты маршруты" without `route` pids), no "proxy not
   running" after wake, routes back only after tunnel traffic.
[ ] A stalled tunnel: the watchdog event and the diagnostic dump appear.

# Final Steps

[ ] Update [system notes](../system-notes.md) with the 2026-11-09 incident and the new triggers after live
   verification.

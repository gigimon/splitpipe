# Description

Fixes from code review 3 (2026-10-20); review item numbers in parentheses. Priorities are ours, not the review's.
Items 4.3, 4.4, 4.5, 4.8, 4.9 and 4.10 were checked against the code on 2026-10-20 and confirmed. What overlaps with
[review 2](2026-10-19-review-2-fixes.md) is not repeated here. Disagreements are marked **Disagree**.

# Implementation

## Step 1: P0 — safety and network loss

[x] **Helper lifecycle** (4.3, extends the review 2 heartbeat). 2026-10-21: the extension writes `heartbeat` into its
   root container (`/var/root/Library/Containers/dev.splitpipe.app.proxy/Data/Library/Application Support/`) at start
   and every 10 s, deletes it in `stopProxy`; the helper reads it without restrictions (checked). `enabled` in
   `helper.json` is now an intent: the bypass and routes are held only while the heartbeat is younger than 60 s; without
   it the bypass is removed, event `proxyNotRunning`, recheck every 5 s. If the container is unreadable — fallback by the
   extension process. Before exiting (binary replaced, app removed, `restart`, SIGTERM/SIGINT) the helper removes the
   anchor, the routes and the connection reset rules. Checked: on an extension replacement the new helper did not arm
   the bypass until the proxy started (00:06:34 → 00:06:35.7); on a helper replacement — cleanup and re-arming in
   ~1.3 s. SIGTERM checked 2026-10-23 15:48 (`sudo launchctl kill TERM system/dev.splitpipe.helper`): the helper removed
   the pf rule and routes through en1 in 0.2 s, launchd (`KeepAlive`) started a new one at once, and it re-armed the
   bypass by the fresh heartbeat in 0.8 s. Not verified: the extension dying without `stopProxy`.
[x] **Send the helper the intent, not the session status** (4.4). 2026-10-21: the app sends `proxy.wantsRunning`
   (`bypassWanted`) instead of `connected || connecting`; whether the proxy runs, the helper sees itself by the
   heartbeat — on `.reasserting` the bypass is not removed, on a failed start it is not armed.
[x] **XPC timeouts** (4.5). 2026-10-21: `ProxyController.send()` — a reply or nil on timeout (5 s, probe/stun 20 s),
   `ResumeOnce` guarantees a single resume, the timeout is logged (`category: app`); `restartIfOutdated()` — with an XPC
   error handler and a 5 s timeout. Not verified on a real hang.
[x] **Fail-open extension configuration** (4.10). 2026-10-21: unreadable `rules` set the flag `rulesUnreadable` instead
   of "no rules"; the extension keeps the last good configuration (`config.json` in the container, written on
   `setConfig`) and uses it on failure; what happened goes to `ProviderStatus.configProblem`, and the app resends the
   rules. Diagnostics has "Rules in the extension": a comparison with the app and a resend. Not verified on a really
   corrupted configuration.

## Step 2: P1 — false drops and fallback

[x] **ifindex as the interface identity** (4.8). `IPv4Route` throws away `rtm_index`, binding is built from the
   `NWInterface` registry. Our bug from 2026-10-19: `defaultVia` without the interface in the registry is just a name,
   and `system:utun4` → `system:utun4#12` drops "Default" connections en masse. Keep ifindex in
   `IPv4Route`/`NetworkState`, bind by it; no `NWInterface` — "not ready yet", not an immediate fallback.
   2026-10-21: `defaultVia` by `if_nametoindex` (kernel), not by the registry; an `NWInterface` whose index does not
   match the kernel's (a stale utun) is not used. 2026-10-23: ifindex in `IPv4Route` (`rtm_index`) and in the
   `NetworkState.indexes` snapshot, binding by it (`NetworkState.binding`); an interface the kernel knows but the
   `NWInterface` registry doesn't yet is `.pending`: a new connection waits for it up to 2 s, open ones are not dropped;
   if it doesn't appear — fallback, and that binding is not waited for again until the registry changes.
   `ProviderStatus.interfaces` — names with indexes; "Routes in the Extension" in diagnostics warns if the registry lags.
   Not verified live.
[x] **Gateway of scoped routes** (4.7). `SplitRoute` has no gateway, `addRoutes` checks only `(interface, upper)`: a
   router change with the same address or `RTM_CHANGE` of `default` leaves routes with the old gateway. Keep the
   gateway, compare it with `physicalGateway` on every tick, mark `routesStale` on `RTM_CHANGE` too; count `ours` in
   `present`. Close to the investigated stale-routes-after-sleep story — same symptoms. 2026-10-21: `SplitRoute.gateway`;
   on every reconciliation the gateway of our routes is compared with `physicalGateway`, on mismatch they are recreated
   ("en1 gateway changed to …"). Recreating on any `RTM_CHANGE` was not done: configd changes flags without a gateway
   change.
[x] **Rules on a VPN client** (4.9). A rule by signing id is matched before the `VPNCatalog.isClient` exclusion:
   AmneziaVPN is visible in Running, and a rule on it would redirect the VPN's own connection — a loop or a dead tunnel.
   Ignore such rules in the extension and don't allow picking them in the UI (or "Default"/"Block" with a warning).
   2026-10-21: the extension does not apply a rule to a `VPNCatalog.isClient` process (the flow goes to the system); VPN
   clients are removed from the app list.
[x] **One `sysctl` failure = "no network and no VPN"** (4.6). `routeMessages()` returns `[]` on error,
   `VPNDetection.processes()` returns `nil`: VPN rules go to the fallback (often `block`), `reevaluate()` drops all VPN
   relays. Retry `NET_RT_DUMP` with a bigger buffer, keep the previous `NetworkState` on error. 2026-10-21: `NET_RT_DUMP`
   is retried up to 3 times on `ENOMEM`; `NetworkState.read()` returns nil on failure: the extension and the helper keep
   the previous state. If the process list is not visible, the extension keeps the previous recognition of tunnels that
   still exist.
[x] **Kill switch by the working address and only with a VPN** (4.2). Partly done 2026-10-19: "blocking" only after a
   repeated failure, recheck after sleep/enable/VPN change. Left: do the local check with the same URL that worked
   through the extension (now always `Config.traceURL` = `1.1.1.1`, blocked by the ISP); `.blocking`/`.bypassed` only
   with a connected VPN; the main signal is the helper's `anchorEffective`. **Disagree** with "`.none` is almost
   unreachable": with a VPN kill switch the local request must not get through, and without a VPN `.none` is set on a
   normal success; the only problem is the choice of address. 2026-10-21: the local check uses the URL that answered
   through the extension; without a VPN holding the default route the state is `.none` or `.unknown`, not
   `.bypassed`/`.blocking`. 2026-10-23: `anchorEffective` is the main signal: if the helper rule is not in effect,
   "blocking" is set at once without a repeated check; a failure through the extension too while the rule is in effect is
   the network, not the kill switch (`.unknown`); a change of `anchorEffective` triggers a "Direct" recheck.
[x] **`physical` can be `nil`** (4.1). Agree: check `IFF_RUNNING`, log where `physical` came from and why it is gone.
   **Disagree** with the conclusion and the remedy: the window 2026-10-19 11:44:09–11:44:12 is not a VPN reconnect but a
   real Wi-Fi loss during DarkWake (configd removed `default` together with the link), and `physical == nil` is correct
   there — "Direct" really did not work. A TTL for the "last valid physical" of 5–10 s would hide real network losses
   and break the route recreation that relies on this signal (`routesStale`). Only a short (1–2 s) smoothing of the
   `directMode` change in the extension is acceptable. 2026-10-21: addresses only for interfaces with `IFF_RUNNING`.
   2026-10-23: `NetworkState.physicalVia` — where `physical` came from (`primary`, `default`, `scoped default`) or why
   it is missing; in the extension's network summary and the helper log on every change
   (`physical: en1 → - (none: primary utun4 is tunnel, no default route)`).

## Step 3: P2 — robustness and performance

Done 2026-10-23, not verified live.

[x] Drops on a flapping VPN — don't drop if the binding came back within 1–2 s. **Disagree** with a general drop
   debounce: it widens the window in which "Default" connections live through en1 past the kill switch (the P0 fix from
   review 2). So only for interface-bound ones ("Direct", VPN): a lost binding is waited out for 2 s (`flapGrace`,
   `ActiveRelay.staleSince`), if it came back the same — no drop; system relays and rule changes drop at once.
[x] `pushed` is set before delivery, `Task`s in `serialized` can run out of order — a desired config with a revision,
   coalescing, acknowledgement. `ProxyController.push` synchronously sets the desired configuration and revision; in the
   operation queue one delivery at a time takes the latest; without `.ok` from the extension — retry in 2 s.
[x] `startIfStopped` does not start on `.invalid` (review 2 has the retries; merge). Done 2026-10-23 together.
[x] `ProviderStatus` carries all rules, `NetworkState` and 400 records every 1–2 s; `Dictionary.match` walks the keys on
   every flow — a prefix index; plus `record()` from review 2. Polling is `statusParts`: no rules, all connections only
   for Connections, for Apps — the last 8 of the selected app, other screens — none; the full `status` is for
   diagnostics. `match` walks prefixes of the signing id itself (`a.b.c` → `a.b` → `a`) instead of iterating keys.
[x] Helper: `run()` without a timeout; `guard enabled` before `NetworkState.current()` (processes are scanned for
   nothing while SplitPipe is off); `checkAnchorEffective` less often — from review 2. `pfctl` and `route` are killed
   after 15 s (`Guardian.commandTimeout`); while SplitPipe is off the network snapshot skips VPN detection
   (`detectVPNs: false`).
[x] `VPNDetection`: the cache of utun owners by tunnel name — key with ifindex (`utun4#12`); the fallback by process name
   is ambiguous with two utuns — stays a known limitation.
[x] `ConnectionReset`: the `pfctl -E` token only in memory (confirmed) — now also in
   `/Library/Application Support/SplitPipe/pf-token`; a new helper releases one left by the previous. After loading the
   reset rules — a check that the anchor is called (`anchorEffect`), otherwise an error in the log.
[x] A `path:` rule trusts the path, not the signature: a binary in the user's folder can be replaced. A conscious
   trade-off — documented in limitations. cdhash is not checked: it changes with every `brew upgrade` and rebuild, and
   the rule would silently stop working.
[x] The "Default" filter in Connections is almost always empty: `FlowRecord.route` is the actual route, not the rule.
   `FlowRecord.ruleRoute` and `actualRoute`: "Default" by rule, other routes by the actual one.
[x] `RouteMonitor.drain`: `ENOBUFS` and `SO_RCVBUF` (review 2); a parsing test including the new `newIPv4Address`:
   target `SplitPipeTests` (`make test`) — routing socket messages (`/1` routes, host, scoped, truncated,
   `RTM_NEWADDR`/`RTM_DELADDR`), `covers2001`, `match`, `ManagedApps`, STUN.
[x] Daily statistics buckets by `Calendar.current` in a root process. **Disagree** with the priority: a root daemon's
   time zone is the system one, same as the user's; they diverge only on a time zone change — P3. Done anyway: the app
   asks for hourly buckets and builds days in its own time zone.

## Step 4: P3 — tests and hygiene

[~] **Test target** (`SplitPipeTests`, `make test`, 43 tests as of 2026-10-23: routing socket parsing, IPv6, `match`,
   `ManagedApps`, STUN, IP lists, event journals, `splitpipe://` links and durations; missing — `decide`, `Fallback`,
   `anchorEffect`, `NetworkState`): `ProviderConfig.match`, `decide`/`binding`, `Fallback` chains, `RouteMonitor.parse`
   and `newIPv4Address`, `anchorEffect`, STUN parsing, `NetworkState.directMode`/`defaultRoute` — on fixtures of routing
   tables and `pfctl` output. Everything else is checked by hand and by logs.
[ ] **One `RouteResolver` in Shared** (4.11): `AppModel.resolve` and `decide` diverge ("system without a route",
   requiring `NWInterface`, LAN/IPv6/QUIC only in the extension). Agree, but after the tests — otherwise it is a core
   refactoring without a safety net.
[x] Git (the Makefile already derives `EXTENSION_VERSION` from it — see review 2).
[~] Team id `BL65NHTRYD` is hardcoded in `Config.appGroup` and the XPC requirements, while entitlements use
   `$(TeamIdentifierPrefix)`. 2026-10-23: the App Group comes from Info.plist (`SPAppGroup`); the XPC requirements
   (`HelperConfig`) still use the team id.
[x] ~~App Group is unused — remove it.~~ 2026-10-23: now it is needed — the app passes state to the widget and Control
   Center through it (both run as the user, the container is shared). **Disagree** with "use it for the heartbeat": the
   extension runs as root, its group container is not the app's (see the routing core plan); the heartbeat goes through
   the extension's root container, which the helper reads.
[ ] The `app-proxy-provider-systemextension` entitlement for distribution (also in the
   [convenience plan](2026-10-16-convenience.md)).
[ ] Remove `Config.locale` (dead code).

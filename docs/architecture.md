# Architecture

SplitPipe is a macOS app for per-app traffic routing: for each app you choose the route its traffic takes (a VPN,
Wi-Fi/Ethernet directly, or block). Main scenario: **AmneziaVPN holds the default route and a kill switch, selected
apps go around it directly.**

## What works (2026-10-19)

- **Interception and routing.** A `NETransparentProxyProvider` extension intercepts the TCP and UDP traffic of apps and
  sends it according to the rule: through an interface (`requiredInterface`), by the system route, or blocks it. Rules
  store the route role (`direct`, `vpn:<key>`); the extension finds the interfaces itself and recomputes them when the
  network changes, even while the app is closed.
- **Who a rule applies to:** an app by signing id (helper processes by bundle id prefix), a command-line program by the
  binary path (`path:/usr/bin/curl`), a process without its own rule gets the rule of its responsible app (WebKit, XPC
  services). With "Manage all apps", connections of apps without a rule are handled by the extension too.
- **Bypassing the Amnezia kill switch for "Direct"** — a root helper (`SMAppService.daemon`): while SplitPipe is on, it
  holds the pf rule `com.apple/splitpipe` and scoped `0/1` + `128.0/1` routes through the physical interface, restores
  them, keeps a "who changed the routes" log and the pf state, checks that our anchor is in effect; resets connections
  opened before SplitPipe.
- **Two-click install:** onboarding (extension → proxy → helper), automatic activation and enabling, extension and
  helper update on app update, "Start at boot" (Login Items, no window).
- **App** (SwiftUI, macOS 26+, Russian or English UI depending on the system language): Apps (+ Programs), Routes (TCP
  and UDP checks, external IP and country), Connections, Statistics, Diagnostics, History, menu bar, settings window.
- **Statistics** of traffic per app and route for an hour / today / 7 / 30 days — counted by the extension.

## Components

```
SplitPipe.app (SwiftUI)
 ├─ AppModel            apps, routes, rules, effective route, config for the extension, Dock / menu bar
 ├─ ProxyController     system extension (activation, replacement), NETransparentProxyManager; all operations serialized
 ├─ HelperController    helper registration (SMAppService.daemon), XPC, restart of an outdated helper
 ├─ Routing / RouteChecks  route cards; "Test Connection": HTTP trace + STUN through the extension; kill switch by fact
 ├─ Diagnostics         checks with "Fix" buttons; debug launch arguments (-SP…)
 ├─ Onboarding          first-run steps based on the real system state
 ├─ Localization        `Locale.app` (UI language + system region), helper event texts, route names from the feed
 ├─ Localizable.xcstrings  UI strings: keys are Russian text, translations to English
 ├─ Stats               statistics periods and totals (data comes from the extension)
 ├─ AppSettings         settings, launch at login, rules import/export, full removal
 └─ Views               Main, Apps, Routes, Connections, Stats, Diagnostics, Settings, Onboarding, MenuBar, Components

Shared (app, extension, helper)
 ├─ NetworkState        route role → interface: getifaddrs, routing table (IPv4/IPv6) and processes via sysctl
 ├─ VPNDetection        who owns a utun: Network Extension services (SCDynamicStore), amneziawg-go / wireguard-go / openvpn
 ├─ RouteMonitor        routing socket events (PF_ROUTE) with the sender pid
 ├─ Probe               HTTP(S) and STUN through a given interface (name resolved by the system resolver, connect by IP)
 ├─ Messages            ProviderConfig (rules with roles), ProviderRequest/Reply, FlowRecord, StatRow
 └─ HelperProtocol      helper XPC protocol, HelperStatus (not needed by the extension, but lives in Shared)

dev.splitpipe.app.proxy.systemextension (NETransparentProxyProvider, root, sandbox)
 ├─ handleNewFlow / handleNewUDPFlow  rule → decision (interface / system / block), relay
 ├─ OwnerResolver       audit token → pid, path, responsible app
 ├─ TCPRelay / UDPRelay  NWConnection ↔ flow, traffic counters
 ├─ network             NetworkState on route and interface events; binding changed — connections are dropped
 ├─ TrafficStats        statistics (5 min × 2 h, hour × 30 days), file in the extension container
 └─ messages: setConfig, status, probe, stun, abort, stats, resetStats

dev.splitpipe.helper (LaunchDaemon from the app, root, no sandbox)
 ├─ Guardian            pf rule + scoped 0/1, 128.0/1 through the physical interface; route and pf log; anchorEffective
 ├─ ConnectionResetter  reset of connections bypassing the extension: pf block return in anchor com.apple/splitpipe-reset
 ├─ HelperEvent         what was done / why it failed, as codes (`HelperEvents` in the same JSON as HelperStatus); the
 │                      file is collected by the app too, which builds the text in the UI language
 └─ XPC: setEnabled, status, resetConnections, restart

SplitPipeWidgets (WidgetKit extension, user)
 └─ status widget and Control Center toggle; state comes from the app through the App Group
```

Rules store the route role, not the interface. The app, the extension and the helper turn a role into an interface
with the same code (`NetworkState`): "Direct" is the main physical interface, a VPN is found by the client key
(`amnezia`, `wireguard`, `openvpn`, `ne:<service id>`), unrecognized ones by the name `utunN`. "Default" is the system
route; the feed and the statistics record where the traffic actually went.

See also: [development notes](development.md), [system notes](system-notes.md),
[known limitations](known-limitations.md), [plans](plans/PLANS.md).

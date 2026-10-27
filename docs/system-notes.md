# System notes

Facts about macOS and AmneziaVPN found while building SplitPipe, and incidents that were investigated.

## Facts about the system and Amnezia

- AmneziaVPN desktop is not a Network Extension: a root service `AmneziaVPN-service` + `amneziawg-go` → `utunN`, routes
  `0/1` + `128.0/1` and a host route to its server through the physical interface. It does not register its utun name:
  we detect it by the `amneziawg-go` process and by the utun holding the default route.
- Amnezia reconnect: `AmneziaVPN-service` removes and re-adds only its own `0/1`, `128.0/1` and the host route to the
  server (helper log). A quick one takes a fraction of a second on the same utun4; a full one (utun disappears) takes
  seconds. It does not touch our scoped routes through en1. On reconnect it re-enables pf
  (`/Library/Application Support/AmneziaVPN/pf/pf.token`).
- The Amnezia kill switch is the pf anchors `amn/*` (a port of the PIA firewall): `100.blockAll`, `200.allowVPN`
  (utun0..30), `250.blockIPv6`, `310.blockDNS` (DNS only to `<dnsaddr>`), `300.allowLAN`, `110.allowNets`. It works
  while Amnezia is connected or reconnecting; a normal disconnect removes it. Usually `anchor "com.apple/*"` in the main
  ruleset comes **before** `anchor "amn/*"`; in the "reconnecting" state our bypass did not work (see
  [live verification](plans/2026-10-17-live-verification.md)).
- `ENETUNREACH` (`Network is unreachable`) when binding to en1 is pf (the kill switch), not routes.
  `ENETDOWN` (`Network is down`) means there is no route in the interface scope (scoped).
- Without a scoped route on the physical interface, binding to it does not work while a VPN holds `0/1` + `128.0/1`.
  The system scoped `default` disappears (after a reboot it was already gone) — the helper adds its own scoped `0/1` +
  `128.0/1` (`RTF_PROTO2`): VPN client monitors would take a second `default` for a gateway change.
- Amnezia's system DNS is `172.29.172.254` inside the tunnel, it does not answer AAAA. Browsers (Opera, Chrome)
  resolve by themselves.
- A VPN utun without a Network Extension has no DNS of its own: resolving a name with `requiredInterface = utun4`
  gives `Network is down`.
- IPv6: only the system utun0–3 have a `::/0` route; en1 (behind the kill switch) and utun4 (Amnezia) do not.
- The ISP blocks 1.1.1.1 (through en1 — `Network is unreachable`), www.cloudflare.com is reachable. ifconfig.me returns
  403 for the home IP. The "Direct" external IP differs between services (ipify vs Cloudflare).
- Extension sandbox: `sysctl` `NET_RT_DUMP` and `KERN_PROC_ALL`, `proc_pidpath` of other processes,
  `responsibility_get_pid_responsible_for_pid`, SCDynamicStore work; `route` / `ps` / `pfctl` and `proc_pidfdinfo` of
  other processes do not. The extension's (root) App Group is `/private/var/root/Library/Group Containers/…`, not
  shared with the app.
- Every app has its own `com.apple.WebKit.Networking`; the responsible process is the app itself.
- The mask in `rt_msghdr` is stored truncated (`sa_len` 0 for default, 5 for `/1`).

## Investigated incidents

- **Amnezia stuck in "reconnecting" after sleep or a Wi-Fi reconnect** until SplitPipe is turned off (2026-10-19,
  reproduced twice: sleep and Wi-Fi off). Amnezia restarts `amneziawg-go` on wake (`wakeup`, DarkWake included) and on
  a BSSID change. In the same second configd removes `default` through en1, Amnezia removes its server `/32`. The kernel
  does **not** remove our scoped `0/1` + `128.0/1` through en1. While the `/32` is missing, a host route to the server is
  cloned from our `128.0/1` (`route get`: `PROTO2, WASCLONED, IFSCOPE`); it stays after the network returns and takes
  the address from Amnezia's `/32`. The `amneziawg-go` handshake never reaches en1 (tcpdump: not a single packet in
  30 s). Removing the pf rule did not help, removing our routes fixed it at once.
  2026-10-19 12:09: the helper marks the routes for recreation when the physical interface disappears or configd removes
  `default` through it, and recreates them when the network is back (deleting them removes the clones too). Checked
  12:11: Wi-Fi off and on, routes recreated 0.5 s after the network returned, Amnezia connected by itself.
  2026-10-19 20:01 it happened again **without** a network loss: roaming between mesh access points (BSSID change), the
  en1 link blinked, DHCP (INIT-REBOOT) set the same 192.168.1.60 again, configd did not remove `default` — recreation
  did not trigger. Amnezia reconnected on the BSSID change and removed the `/32` for 0.2 s; relays through en1
  immediately got `Can't assign requested address` (routes held the old address). `ifi_lastchange` of Wi-Fi does not
  change — not usable. 20:07: the helper also recreates the routes when the VPN client **re-adds the host route to its
  server** through the physical interface (present in all three failures).
  2026-10-20 18:20, after a long sleep: not enough. Wake at 18:19:57, DHCP set the address again at 18:20:12, relays
  through our (stale) routes got `connect timeout`; Amnezia reconnected at 18:20:28, the first handshake of the new
  `amneziawg-go` went through the stale route and was lost, the helper recreated the routes 0.6 s later — too late: the
  WireGuard retry came in 5 s, Amnezia gave up after 4.4 s. The next attempt (after "Cancel") succeeded at once — the
  routes were fresh. 18:51: `RouteMonitor` parses `RTM_NEWADDR` (IPv4, `RTA_IFA`), the helper recreates the routes as
  soon as the physical interface gets an address, ~14 s before Amnezia reconnects.
  2026-10-22 12:36, Wi-Fi roaming without sleep: the BSSID changed (12:36:52.48), the link blinked, DHCP INIT-REBOOT set
  the same address — `RTM_NEWADDR` did **not** arrive, no recreation. Amnezia restarted `amneziawg-go` (utun4 removed at
  12:36:53.05), its only handshake socket (`192.168.1.60:52352`, NE: `provider rejected` — not ours) was created at
  12:36:53.222 — 6 ms before its own routes and 0.7 s before our recreation on the host route. That socket never
  recovered after the recreation: all relays through utun4 got `connect timeout` 46/min for 86 minutes; on the second
  link blink (13:56:59) Amnezia ignored its own reconnect ("Reconnect triggered on Reconnecting during inappropriate
  state"). Manual disconnect/connect (14:03:18–20): the first socket (14:03:19.066) was again created before the
  recreation and dead, Amnezia recreated utun4, the second one (19.920) — after the recreation (19.739) — worked. The
  pattern across all three sockets: a handshake socket created while our routes were stale never recovers, one created
  after works.
  Fix: the helper removes its routes **immediately** on the event instead of recreating them on reconciliation:
  `RTM_IFINFO` (change of `IFF_UP|IFF_RUNNING` of the physical interface) and `State:/Network/Interface/<if>/Link` from
  SCDynamicStore (configd publishes it on the same kernel event), and also removal of the VPN utun or its address
  (`RTM_IFINFO` without a name / `RTM_DELADDR`); it adds them again when the VPN re-adds the host route to its server
  (waiting at most 15 s — a Network Extension VPN does not add a host route and does not need our routes). While the
  routes are missing, the handshake goes through the regular `default` via en1.
  2026-10-22 18:10 it happened again with this version: when roaming, the driver sends only `LINK_ON` without
  `LINK_OFF` — configd logged "link status active", but `Active` in `State:/Network/Interface/en1/Link` did not change,
  nor did the `IFF_UP|IFF_RUNNING` flags in `RTM_IFINFO`; `RTM_DELADDR`/`RTM_IFINFO` about utun4 were parsed when utun4
  was already gone, and the helper did not know the name by index. Only the late host-route trigger fired (41.364 vs the
  handshake at 40.682) — the tunnel was dead for 38 minutes until a manual reconnect; there the `RTM_DELADDR` trigger
  was in time (21.588), the handshake (23.058) went without our routes and worked on the first try. Now there are three
  early triggers, all synchronous in the event handler: (1) the VPN client removed its `0/1` (`RTM_DELETE` of an
  unscoped prefix ≤ 1 through utun) — 50 ms before `amneziawg-go` restarts and 200 ms before the handshake, present in
  both incidents; (2) the kernel event socket (`PF_SYSTEM`, `SYSPROTO_EVENT`, `KernelEventMonitor`):
  `KEV_DL_LINK_ON/OFF`, `KEV_DL_IF_DETACHING/DETACHED`, 802.11 `BSSID_CHANGED`/`LINK_CHANGED` — the same source configd
  and airportd use, arrives ~0.5 s before the restart when roaming; (3) `RouteMonitor` remembers interface names by
  index (`if_nameindex` at start). After a removal on link/roaming the routes are added fresh on the reconciliation 1 s
  later, after a removal on VPN restart — after its host route (at most 15 s). Not verified on live roaming — see
  [live verification](plans/2026-10-17-live-verification.md).
- **`routeMode=1` / `appsRouteMode=2` in Amnezia settings** (2026-10-19, from the `amnezia-client` sources,
  `client/core/utils/routeModes.h`): `routeMode` is split tunneling by site: 0 — everything through the VPN,
  **1 — only listed sites through the VPN**, 2 — everything except listed sites. `appsRouteMode` is per app: 0 — all,
  1 — only listed, **2 — all except listed apps**. They apply only when `Conf/sitesSplitTunnelingEnabled` /
  `Conf/appsSplitTunnelingEnabled` are on, and with an empty list they reduce to 0. Site mode 1: Amnezia removes its
  default route and adds only the site routes through utun. Per-app split on desktop is only "except"
  (`vpnDisabledApps`) and actually works only on Windows (split tunnel driver) and Android; on macOS the list is not
  applied, so `appsRouteMode=2` has no effect.
- **~0.5 s window on Amnezia reconnect** (2026-10-18 22:45): "Default" connections opened while Amnezia had removed its
  routes go through en1 (the extension is root, bypassing the kill switch) and die with `Network is down` ~12 s after
  the VPN returns. 2026-10-19: connections by the system route have the default route's interface in their `binding` —
  when the VPN returns they are dropped at once and reconnect through utun. Notes in the same window: connections
  through utun4 were closed by the server, no leak.
- **Incident 2026-10-18 18:25–18:29 (reboot):** DNS timeouts right after the first enabling of `onDemandRules` and a
  series of stop/start during an extension replacement. On-demand start removed; all proxy configuration operations are
  serialized.
- **After sleep on 2026-10-17 → "Network is down" for "Direct":** the scoped route was gone — now the helper holds it,
  and without it "Direct" falls back immediately.
- **1.1.1.1 unreachable through en1** — blocked by the ISP; the check takes the IP and country from the Cloudflare trace
  by name.
- **IPv6 hung for 5 s** on interface-bound connections — now it is rejected at once if there is no IPv6 route.
- **Amnezia reconnect on the same utun4** (2026-10-17, 22:45): our routes and pf rule untouched, the helper did not have
  to step in; Claude (`vpn:amnezia`, fallback — block) was blocked in the window without the VPN.
- VPN detection in the extension, routes by role, command-line programs and WebKit through "Direct", "Direct" after
  installing the pf rule — checked on real traffic (2026-10-17/18).

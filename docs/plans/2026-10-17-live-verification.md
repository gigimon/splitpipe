# Description

Things built but not yet verified on a real machine, and open questions. Each item says what to check and what the
expected result is. Done items stay for the record.

# Implementation

## Step 1: Network events and the kill switch bypass

[ ] **Amnezia in "reconnecting" overrides our kill switch bypass** (2026-10-18 23:41): 391 × `Network is unreachable`
   through en1 with the pf rule in place. Cause (code review 2, item 1): `keep state` defaults to `flags S/SA` — the rule
   matched only SYN, the other packets went by the state table; while Amnezia kept pf off (reconnecting) there were no
   states, and after `pfctl -E` packets of open connections hit its `block out all`. 2026-10-19 00:35: the helper rule is
   `flags any no state`, like Amnezia's; the helper replaced the old rule itself. Check on the next Amnezia reconnect or
   with `sudo pfctl -F states`: no `unreachable` in the extension log. Amnezia hanging in "reconnecting" after sleep
   turned out to have another cause — see the next item.
[ ] Recreating scoped routes after **sleep** (DarkWake): checked on Wi-Fi off on 2026-10-19 12:11, see
   [system notes](../system-notes.md) — "Amnezia stuck in reconnecting".
[x] Recreating when the route to the VPN server returns: in the log on 2026-10-20 18:20:29 "VPN re-added the route to
   the server — recreating routes".
[ ] Recreating on `RTM_NEWADDR` (2026-10-20 18:51): after sleep or Wi-Fi off the helper log shows "en1 address assigned
   again — recreating routes" before Amnezia reconnects; Amnezia connects on the first try. On roaming with the same
   address (INIT-REBOOT) `RTM_NEWADDR` does not arrive (2026-10-22 12:36).
[ ] **Removing routes on roaming / VPN restart** (2026-10-22 19:xx, second version): on Wi-Fi roaming the helper log
   shows "en1: Wi-Fi access point changed — removing routes, will add fresh ones" (kernel event) and/or "VPN utun4
   removed the default route — removing routes, will re-add after the VPN host route" **before** the NE log shows
   `New flow … app = amneziawg-go`; then "route through en1 restored" ~0.2 s after Amnezia's `route add …/32`; Amnezia
   connects on the first try, no series of `connect timeout` through utun4 in the extension log. If roaming happens
   without a VPN restart, routes come back in 1 s.
[ ] Failure after sleep (2026-10-17): the VPN (Amnezia, Outline) connects but there is no internet until reboot. The
   SplitPipe proxy was off at the time — a link with SplitPipe is not proven. The pf rule and scoped route were set by
   hand back then. Most likely the same cause as above: the scoped route through en1 survived sleep.
[ ] Who removes the en1 scoped route (it disappeared on 2026-10-17 between 12:43 and 13:16 and after the 18:29
   reboot). The helper now adds its own and logs route changes with pids — the next time it disappears it will be
   visible.
[ ] Recomputing routes when Amnezia reconnects with a new `utunN` and on Wi-Fi ↔ Ethernet (including with the app
   closed); route checks on network change; network change for the pf rule.
[ ] Code review 3 fixes from 2026-10-23: waiting for the `NWInterface` of a new utun, 2 s without drops when "Direct"
   flaps, kill switch by `anchorEffective`, config delivery retries, pf token after a helper restart.
[ ] Code review 2 fixes from 2026-10-23 on real traffic: relay keepalive, UDP 5 min, reset on first RST, apps outside
   `/Applications` under "Manage all apps", IPv6 through `2000::/3`.

## Step 2: Clients and traffic

[ ] Outline and WireGuard on a real connection.
[ ] Telegram (UDP calls), QUIC in Opera through "Direct"; Safari live.
[ ] Routing options on real traffic: local addresses, QUIC block, disabling connection drops.
[ ] Google Drive live: traffic of the main process and the File Provider (`com.google.drivefs.fpext`) goes by the
   `com.google.drivefs` rule in Connections.
[ ] Statistics survive an **extension** restart (the app restart on 2026-10-19 00:23 did not affect it: the extension had
   been running since 00:08 — the statistics and `stats.json` are its own).

## Step 3: App features

[ ] "Start at boot" on a real reboot: SplitPipe starts without a window and enables the proxy.
[ ] Rules import/export, reset, "Remove SplitPipe completely".
[ ] Onboarding steps in the "waiting" and "error" states (everything is already set up on this machine); Dock and menu
   bar toggles.
[ ] Temporary route (all four durations, "Revert now", revert after a SplitPipe restart) and notifications (VPN
   disconnected/back, kill switch, proxy stopped, temporary route ended) — built on 2026-10-23, not run.
[ ] Event history: helper and extension events after sleep and with the app closed appear in History after it starts;
   event translations.
[ ] IP lists: ipdeny RU as "Direct" with the VPN as default — an app without a rule goes to Russian addresses through
   en1, to the rest through the VPN; update by URL and file edit; lists after an extension restart.
[ ] New apps: notification buttons (with the "Banners" style they are in the "Options" menu), first enabling without a
   flood of questions, "Ask Again".
[ ] Bypass watcher: an app opened before SplitPipe was enabled shows "bypassing SplitPipe", after "Drop Connections"
   the rows disappear; no false positives for apps going through the extension.
[ ] Automation: a link from Safari asks for confirmation, from Shortcuts it doesn't; a link while SplitPipe is closed
   (doesn't it open an extra window?); actions in Shortcuts and Spotlight; route menu by hotkey at the pointer.
[ ] Widget and Control Center: the widget can be added and updates; the toggle turns SplitPipe on and off without a
   confirmation dialog, including with the app closed (launches it).

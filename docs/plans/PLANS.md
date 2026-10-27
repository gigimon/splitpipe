# Plans

Feature plans of SplitPipe; each links to its implementation plan. `[x]` done, `[~]` partly done, `[ ]` not started.
Background: [architecture](../architecture.md), [development notes](../development.md),
[system notes](../system-notes.md), [known limitations](../known-limitations.md).

## Prototype and UI — [plan](2026-10-16-prototype-and-ui.md)

- [x] Interception prototype (Opera, Amnezia kill switch bypass).
- [x] Design prototype, icon, main window with Apps / Routes / Connections / Diagnostics, settings window.
- [x] Russian and English UI, one main window, menu bar extra, onboarding.

## Two-click install — [plan](2026-10-16-easy-install.md)

- [x] Extension activation and self-update, auto-enable, "Start at boot" via Login Items.
- [x] Root helper (`SMAppService.daemon`): pf bypass, scoped routes, self-restart on update.
- [x] Reset of connections opened before SplitPipe.

## Routing core — [plan](2026-10-16-routing-core.md)

- [x] Per-rule fallback, "Block" route, local addresses, IPv6 and DNS handling.
- [x] Routes by role, several VPNs, role → interface resolution in the extension itself.
- [x] Manage all apps, command-line programs, WebKit and XPC services, menu bar apps.
- [x] Route checks with external IP over TCP and UDP, kill switch detection.
- [ ] Global kill switch.

## DNS and domain rules — [plan](2026-10-16-dns-and-domain-rules.md)

- [ ] Per-app DNS (`NEDNSProxyProvider`).
- [ ] Rules by domain and subnet, priority domain > app > default.

## Extra routes — [plan](2026-10-16-extra-routes.md)

- [ ] SOCKS5/HTTP upstream as a route.
- [x] "Disable QUIC" option.

## Convenience — [plan](2026-10-16-convenience.md)

- [x] Statistics, rules import/export, temporary routes, notifications.
- [ ] Profiles (by Wi-Fi SSID / VPN state).
- [ ] Distribution: Developer ID, notarization, Sparkle.

## Live verification — [plan](2026-10-17-live-verification.md)

- [ ] Network events (sleep, roaming, VPN reconnect) with the helper and the extension on a real machine.
- [ ] Other VPN clients and real traffic (Outline, WireGuard, Telegram, QUIC).
- [ ] Features built but not run live (temporary routes, notifications, feature pack 2026-10-23).

## Code review 2 fixes — [plan](2026-10-19-review-2-fixes.md)

- [x] P1: extension heartbeat, loopback/multicast, scoped routes lifetime, relay owner trade-off.
- [~] P2: network and extension fixes (one open investigation), helper and Makefile fixes.

## Code review 3 fixes — [plan](2026-10-20-review-3-fixes.md)

- [x] P0: helper lifecycle, intent instead of session status, XPC timeouts, fail-open config.
- [x] P1: ifindex identity, scoped route gateway, rules on VPN clients, `sysctl` failures, kill switch signal.
- [x] P2: flap grace, config delivery revisions, status polling, helper timeouts, pf token.
- [~] P3: test target, one `RouteResolver`, team id cleanup, dead code.

## Feature pack 2026-10-23 — [plan](2026-10-23-feature-pack.md)

- [x] **Event history**: helper, extension and app each keep a journal of events (codes); the app merges them into
      one feed (section History), including what happened while the app was closed.
- [x] **IP-list rules**: plain-text CIDR lists from a URL or a local file, managed by the app; each list has a route
      rule; apply to apps without their own rule; ordered, first match wins.
- [x] **Rules for new apps**: off / ask / assign route; "ask" is a notification with Default / Direct / Via VPN.
- [x] **Bypass watcher**: established TCP sockets in processes of apps with a rule = traffic bypassing SplitPipe;
      shown in Connections, on the app and as a notification.
- [x] **Automation**: `splitpipe://` URL scheme with confirmation, App Intents for Shortcuts, global hotkeys
      (KeyboardShortcuts) for on/off and the route menu of the frontmost app.
- [x] **Widget and Control Center**: Control Center toggle and a status widget via the App Group.

## Backlog

Ideas from the 2026-10-23 brainstorm that were not picked for the feature pack. No plans yet.

**Reliability and security**
- [ ] Per-app leak check: external IP, country, DNS resolver and WebRTC/STUN by the app's actual route against the
      expected one ("Telegram should go through Amnezia, but DNS goes to the ISP").
- [ ] Blocking by schedule or until unblocked (parental control, "no social networks until 18:00").

**Routes**
- [ ] Automatic route choice by availability: a chain (Amnezia → Outline → Direct) with a latency check instead of one
      fallback.
- [ ] A route for devices on the local network (sharing the VPN or the direct exit through Internet Sharing).

**Convenience**
- [ ] Rule templates: "banks and Gosuslugi — direct", "streaming — through the VPN" (together with domain rules).

**Observability**
- [ ] Traffic limits and quotas: "at most 5 GB a day through the VPN", a warning about heavy traffic through a paid
      exit.
- [ ] App network profile: which hosts and countries it talks to, how much and by which route — a hint which rule to
      give it.

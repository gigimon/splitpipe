Build a **working interactive prototype** (not a set of static screens) of the SplitPipe macOS app.
The prototype is a single web app that simulates the macOS desktop: a menu bar with the SplitPipe icon, the main app
window, and the settings window. Everything is clickable, state changes and is reflected consistently everywhere
(main window, menu bar popover, settings). Data is fake and kept in memory.
Interface language: Russian (the app now ships in Russian and English, picked by the system language).

# Product

SplitPipe is a macOS utility that routes traffic per app. For each app, the user chooses where its traffic goes:
through a specific VPN, directly via Wi-Fi/Ethernet bypassing the VPN, whatever the system decides,
or blocked. The user is technically savvy: they keep a VPN on all the time (AmneziaVPN with a kill switch),
but some apps (bank, Gosuslugi, Yandex Music, Telegram) must go direct, and work apps go through the work VPN.

Tone: calm, native macOS, no "hacker" aesthetic. References: Little Snitch, Raycast, macOS System Settings.
Dense but tidy information, clear statuses.

# Constraints (the prototype will later be ported to SwiftUI)

- Use only what maps naturally onto native macOS 15+ controls: `NavigationSplitView` (sidebar + content
  + optional inspector on the right), `Table`/`List`, pop-up button with a menu and groups, toggle, segmented control
  (only for 2–3 fixed options), `MenuBarExtra` (popover under the menu bar icon), `Settings` window.
- System font (SF Pro), monospaced (SF Mono) for IP addresses and interfaces. SF Symbols-style icons.
- System materials (translucent sidebar and popover), light and dark themes.
- Main window from 760×520, popover about 340 px wide.

# Data model

## Routes
A route is where traffic is sent. There can be many routes; each VPN is a **separate route**
(not a single shared "VPN" option).

| id | Name | Group | Interface | Local IP | External IP | Initial status |
|---|---|---|---|---|---|---|
| direct | Direct (Wi-Fi) | Direct | en1 | 192.168.1.60 | 203.0.113.10 | connected |
| amnezia | Amnezia VPN | VPN | utun4 | 10.8.1.1 | 198.51.100.20 | connected, holds the default route |
| work | WireGuard "Work" | VPN | utun6 | 10.20.0.14 | 192.0.2.30 | connected |
| office | OpenVPN Office | VPN | — | — | — | disconnected |

- "Direct" is a role-based route: "the primary physical connection". When switching Wi-Fi ↔ Ethernet it stays
  available; only the label (Wi-Fi / Ethernet), interface (en1 / en0), and local IP change.
- VPN names are detected automatically from the VPN client; they can be renamed on the "Routes" screen.
- Plus two special options: **Default** (whatever the system decides; currently Amnezia VPN, because it holds
  the default route; if there is no VPN, Direct) and **Block**.
- A color and icon for each type: VPN, Direct, Default, Block. A disconnected route is shown in gray.

## Rules
A rule: app → route + an **"if route is unavailable"** setting:
- **Block** (default for VPN routes);
- **Use the default route** (default for "Direct"). Hint: "If the VPN has a kill switch enabled,
  this effectively means 'via VPN or blocked'";
- **Fallback route: [pick from the route list]**.

Initial data:

| App | Running | Route | If unavailable |
|---|---|---|---|
| Opera | yes | Direct | default |
| Telegram | yes | Direct | default |
| Safari | yes | Default | — |
| Slack | yes | WireGuard "Work" | block |
| Jira (Electron) | no | WireGuard "Work" | fallback: OpenVPN Office |
| 1C:Enterprise | no | OpenVPN Office | block |
| Yandex Music | yes | Direct | default |
| Steam | no | Block | — |
| Xcode | yes | Default | — |
| Spotify, Zoom, Notion, Mail | some | no rule | — |

App icons are simple generated rounded squares with a letter or symbol in the brand color, no real logos.

## Effective route (prototype logic, must be consistent everywhere)
1. Take the route from the rule (or "Default" if there is no rule).
2. If the route is unavailable, apply "if unavailable": block / default / fallback (recursively; the fallback may also be unavailable → block).
3. "Default" = Amnezia VPN if it is connected; otherwise "Direct".
4. If the **global kill switch** is on and the resulting "Default" route turns out not to be a VPN, the app is blocked.
   The kill switch does not affect apps with an explicit "Direct" route.
5. Each app row shows both the selected route and the actual one, if they differ:
   "WireGuard 'Work' unavailable → blocked" or "OpenVPN Office unavailable → via Amnezia VPN".

## Connections
Live feed: every 1–2 seconds new fake connections appear from running apps:
time, app, address (`185.26.182.90:443`, `149.154.167.51:443`…), TCP/UDP, actual route (colored badge),
traffic volume (grows for active ones). Blocked connections are visible too, with a "Blocked" badge.
When an app's rule changes, its active connections are "dropped" (disappear with a mark) and new ones appear on the new route.

# What the prototype must include

## Desktop
Fake wallpaper, macOS menu bar at the top (clock, a few system icons), the SplitPipe icon. The icon changes with state:
all good / warning (route unavailable) / kill switch blocking / SplitPipe off.
The main window can be closed and reopened from the popover; the settings window opens as a separate window.

## 1. Onboarding (first launch)
3 steps with progress; at each step the user only confirms a system prompt:
1. "Allow the network extension": an "Open Settings" button → simulated toggle in a fake System Settings window
   (Login Items & Extensions → Network Extensions → SplitPipe); once enabled, the step becomes "done".
2. "Allow the proxy configuration": simulated system dialog "SplitPipe would like to add proxy configurations" → Allow.
3. "Allow the background helper (needed to work alongside the VPN kill switch)": simulated toggle in Login Items.
Step states: pending / waiting for confirmation / done / error with a "Retry" button (the error can be triggered from the simulation panel).
Final "Done" screen → go to "Apps".

## 2. Main window: sidebar with sections "Apps", "Routes", "Connections", "Diagnostics"

### Apps (main screen)
- List: icon, name, bundle id (small), "running" badge, route control, and the actual route when it differs.
- **The route control is a single pop-up**, not a segmented control. Collapsed: colored icon + current route name.
  Expanded, grouped:
  ```
  Default
  ── DIRECT ──
  Wi-Fi / Ethernet
  ── VPN ──
  Amnezia VPN          ✓
  WireGuard "Work"
  OpenVPN Office (disconnected)   ← gray, but selectable
  ──────────
  Block
  ```
- Search, filters "Running" / "With rules" / "All".
- Selecting an app opens an **inspector** on the right: route, "if route is unavailable" (three options; "fallback" has
  a route pop-up), current actual route, the app's recent connections, a "Drop connections" button.
- Empty state (the "Reset rules" button in the simulation panel): "Select an app to route its traffic around the VPN".

### Routes
Cards grouped into "Direct" and "VPN": name (rename on click), interface, local and external IP,
status, how many apps use the route, a "Check" button (checking animation → external IP).
For a disconnected VPN: "disconnected, 1 app blocked, 1 on fallback route".
A block: "Amnezia kill switch detected — bypass for SplitPipe configured ✓".

### Connections
Live table (see above), grouped by app with collapsible groups, route filter, feed pause.

### Diagnostics
A "Run checks" button: checks run one after another with animation, statuses ✅ ⚠️ ❌, problems have a "Fix" button:
- Network extension: running;
- Background helper: running;
- Amnezia VPN: connected, holds the default route;
- Amnezia kill switch: on, bypass for SplitPipe installed;
- Direct (Wi-Fi): external IP 203.0.113.10;
- Amnezia VPN: external IP 198.51.100.20; WireGuard "Work": 192.0.2.30;
- OpenVPN Office: ❌ disconnected;
- DNS: 10.8.1.1 (via VPN) — ⚠️ "'Direct' apps resolve addresses through the VPN" → "Fix" opens Settings → DNS.
Results depend on the current simulation state.

## 3. Settings (separate window, tabs or sidebar)
- **General:** launch at login, menu bar and Dock icon, notifications
  ("VPN disconnected, 3 apps blocked").
- **Kill switch:** mode `Off` / `While any VPN is connected` / `Always`; "Allow local network";
  explanation: "Direct" apps keep working. If the VPN client already has its own kill switch, a hint
  "Amnezia kill switch is active — ours duplicates it".
- **Routing:** route for new apps; default "if unavailable" behavior (separately for VPN and for "Direct");
  "Drop connections when a rule changes"; "Local network always direct"; IPv6: allow / reject immediately;
  "Disable QUIC for redirected apps".
- **DNS:** for "Direct" apps: ISP DNS / custom server / DNS-over-HTTPS (address field).
- **Checks:** IP lookup service URL (`https://api.ipify.org`), route check frequency.
- **Advanced:** log level, "Export diagnostics", import and export rules, "Reset rules",
  "Uninstall SplitPipe completely" (extension, helper, pf rules) — with a confirmation dialog.
Settings actually affect the prototype: the kill switch mode changes the effective route logic, "Drop connections" affects the feed, etc.

## 4. Menu bar popover
- Overall status, a "SplitPipe enabled" toggle, kill switch indicator (off / armed / blocking).
- The active app (the simulation panel lets you choose which app is "in the foreground") with the same route pop-up.
- 5–6 apps with rules, each with a quick pop-up.
- Banner on problems: "WireGuard 'Work' disconnected — Slack blocked".
- At the bottom: "Open SplitPipe", "Settings…", "Quit".

# Simulation panel

A separate floating panel **outside the macOS simulation** (clearly different in style, collapsible) to show states:
- connect / disconnect each VPN (Amnezia, WireGuard "Work", OpenVPN Office);
- switch the physical connection Wi-Fi ↔ Ethernet ↔ no network;
- Amnezia kill switch on/off;
- "First launch" (run onboarding again), "Error at an onboarding step";
- "Extension disabled by user" (the app shows a "not allowed" state with a fix button);
- foreground app;
- light / dark theme;
- "Reset rules" (empty state).

All changes must be reflected immediately in the main window, popover, menu bar icon, connection feed, and diagnostics.

# Key scenarios that must work end to end
1. First launch → 3-step onboarding → app list.
2. Opera: "Default" → "Direct": in the feed, Opera's old connections are dropped, new ones appear with the "Direct" badge.
3. Disconnect WireGuard "Work" in the simulation panel → Slack is blocked (menu bar icon shows a warning,
   banner in the popover), Jira falls back to OpenVPN Office, and since that is also disconnected, it is blocked.
4. Disconnect Amnezia with the global kill switch set to `Always` → Safari and Xcode ("Default") are blocked,
   Opera and Telegram ("Direct") keep working, the icon shows "kill switch blocking".
5. Switch the active app's route from the popover.
6. Diagnostics: find the DNS problem → "Fix" → Settings opens at DNS.

# Visual system
Describe and apply: route colors (VPN, Direct, Default, Block, unavailable), status badges, route icons,
menu bar icon states, light and dark themes. Design an app icon: a pipe or stream that splits in two.

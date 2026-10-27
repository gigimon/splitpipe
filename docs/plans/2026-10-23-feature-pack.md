# Description

Six features for SplitPipe chosen in the 2026-10-23 brainstorm: event history, IP-list rules, rules for new apps,
bypass watcher, automation (URL scheme, Shortcuts, hotkeys), widget and Control Center. Steps go from foundation
(event history, which the other features write to) to UI-only add-ons.

## General decisions

- Language and stack as in the rest of the project: Swift (Swift 5 language mode), SwiftUI, macOS 26+, XcodeGen
  (`project.yml`), `make build` / `make test`.
- Frameworks: NetworkExtension (existing transparent proxy), UserNotifications (existing `Notifier`), App Intents
  (Shortcuts), WidgetKit (widget and Control Center control), ServiceManagement (existing helper).
- First external dependency: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) via SPM in
  `project.yml` (shortcut recorder and global hotkeys without the Accessibility permission).
- Components keep their roles: the **app** owns settings, downloads, notifications and UI; the **extension**
  (root, sandboxed) only decides and relays; the **helper** (root) only does pf/routes/resets. Nothing new is
  downloaded by the extension or the helper.
- Events from the extension and the helper are codes (like `HelperEvent`), text is built by the app in the UI
  language.
- Wire compatibility: new `ProviderRequest` cases and XPC methods must fail gracefully against an older extension or
  helper (they are replaced on app update, but a mismatch window exists). New fields in shared Codable types are
  optional.
- Every user-visible string goes to `Localizable.xcstrings` with an English translation.
- UI strings in Russian are the source language (keys), as in the rest of the app.

## Decisions per feature

- **Event history** — each component keeps its own journal (helper, extension, app); the app merges them into one
  feed. Covers the time when the app was closed (sleep, reboot).
- **IP lists** — plain-text CIDR format (one subnet or address per line, IPv4 and IPv6, `#` comments). Sources: URL
  (auto-update daily + "Update" button) or a local file (watched for changes). Downloaded and parsed by the app, sent
  to the extension as compiled ranges; the extension stores them in its container.
  - Applied only to apps **without their own rule** (needs "Manage all apps"). Priority: app rule > IP list >
    route for apps without a rule.
  - Each list has a regular `AppRule` (route + "if unavailable"), as if the list were an app.
  - Lists are ordered by the user (drag to reorder); the first matching list wins.
- **New apps** — setting: off / ask / assign route X (X chosen from current routes). "Ask" posts a notification
  "New app: <name>" with buttons **Default** (no rule, remembered as seen), **Direct**, **Via <VPN>** (one per connected
  VPN, at most two, the one holding the default route first). Until answered, the app goes by the route for apps
  without a rule.
- **Bypass watcher** — show only (no automatic reset): a row "bypassing SplitPipe" in Connections, a badge on the app,
  a notification. Detection: an `Established` TCP socket inside the process of an app with a rule. Sockets intercepted
  by the transparent proxy are `Closed` in the app process — the real connection belongs to the extension (checked
  2026-10-23 with `nettop` on Opera).
- **Automation** — URL scheme + App Intents + hotkeys:
  - Actions: on / off / toggle SplitPipe; route of the frontmost app or any app (bundle id or name), permanent or
    temporary; revert a temporary route.
  - Read-only queries: route of an app, state, connected VPNs.
  - URLs not coming from Shortcuts need a confirmation dialog.
  - Hotkeys (unassigned by default): toggle SplitPipe; route menu for the frontmost app at the mouse pointer.
- **Widget and Control Center** — a Control Center toggle (SplitPipe on/off) and a desktop / Notification Center
  widget: status, connected VPNs, problems ("Amnezia disconnected — 2 apps blocked"), traffic today. State goes through
  the App Group shared by the app and the widget extension (both run as the user).

# Implementation

## Step 1: Event history (foundation)

[x] Shared model `SPEvent`: id, date, source (app / extension / helper), severity, kind — a Codable enum with
   parameters (codes, no text). Ring buffer type with persistence (JSON, last 30 days, at most ~5000 events).
[x] Extension journal in its container (`events.json`): proxy start/stop with reason, network changes (default route,
   VPN appeared/disappeared, physical interface lost/returned with `physicalVia`), flows aborted by a network change,
   configuration unreadable / last good used, interface wait timeout. New `ProviderRequest.events(after:)`.
[x] Helper journal in `/Library/Application Support/SplitPipe/events.json`: every `did`/`fail` (`HelperEvent`), route
   drops with reason (roaming, link, VPN restart), proxy not running, start and exit (signal, binary replaced).
   New XPC method `events(after:reply:)`; an old helper without it is handled as "no events".
[x] App journal: VPN down/up with affected apps, kill switch blocking, proxy stopped, temporary routes, rule changes,
   new-app decisions, bypass detected (later steps write here).
[x] App `EventLog`: merges the three sources (dedupe by source + id), persists, polls extension and helper every
   30 s and when the history is open.
[x] UI: sidebar section "History" — list with time, source, severity, text; filters by source and severity; search;
   export to text. Add the history to the diagnostics export.
[x] Translations for all event texts.

## Step 2: IP-list rules

[x] Model `IPList` (in the app): id, name, source (URL / file), last update, entry count, invalid-line count, error,
   enabled, `AppRule`. Ordered array in settings.
[x] Parser: IPv4/IPv6 CIDR and single addresses, `#` and `;` comments (whole-line and inline), blank lines; invalid lines
   counted, not fatal. Normalize to sorted, merged ranges (IPv4 as `UInt32` pairs, IPv6 as 128-bit pairs).
[x] Sources: URL download (URLSession, ETag / If-Modified-Since, daily + manual), local file (watch with
   `DispatchSource` file events). Keep the last good copy if a download or parse fails.
[x] Delivery: new `ProviderRequest.setLists` with packed binary ranges + list rules; lists revision in
   `ProviderConfig` and in `ProviderStatus` so the app resends on mismatch. The extension stores lists in its
   container and loads them in `startProxy`.
[x] Extension matching: only for flows of apps without their own rule (`managed`), remote address in the lists in
   order (binary search), first hit → its `AppRule` through the existing `decide`. Flows addressed by hostname have no
   IP yet — lists do not apply (documented limitation). `ActiveRelay` keeps the matched list, `reevaluate` re-checks
   on list changes.
[x] Feed: the route label of a flow gets the list name ("Direct · RU"); a separate "by list" filter — not done.
[x] UI: settings tab "Lists" — table with drag-to-reorder, add from URL or file, enable toggle, route and fallback
   pickers (`RouteControl`), update button, status line (entries, updated, error). Warning when "Manage all apps" is
   off.
[x] Unit tests for the parser and the range lookup (`Tests/IPListsTests.swift`). Also checked by hand on the ipdeny RU list:
   8664 lines → 7412 ranges in 16 ms.

## Step 3: Rules for new apps

[x] Setting `newApps`: off / ask / route X (X from current routes: Direct, connected VPNs, Block, Default).
[x] Extension reports apps without a rule it has seen (`ProviderStatus.unruledApps`: id → last seen), only real apps
   (path inside `.app`, not system, not VPN clients).
[x] App keeps the persisted set of known apps. When the feature is turned on, everything currently seen becomes known
   (no notification burst). New = seen, not known, no rule.
[x] Mode "route X": set the rule right away, write an event.
[x] Mode "ask": notification category with actions Default / Direct / Via <VPN> (≤ 2 VPNs, the one holding the default
   route first; categories registered per VPN set); the response sets the rule or marks the app as known; an event
   either way. Unanswered notifications stay; the app is asked once.
[x] Settings UI in "Routing": mode picker; list of known apps without a rule with "forget" (ask again).

## Step 4: Bypass watcher

[x] Move socket enumeration from `ConnectionResetter` into Shared (`SocketScanner`): established TCP to non-local
   addresses, without DNS, per pid, plus responsible-process lookup.
[x] App scan every 15 s while SplitPipe is on: running apps with a rule whose route is not Default, their helper
   processes (responsible pid). Skip 30 s after enabling SplitPipe or a rule change (the helper is resetting then).
   Respect "local addresses via system route".
[x] Check UDP: whether intercepted connected UDP sockets look different from bypassing ones; include UDP only if they do.
   Not confirmed (no intercepted UDP sockets to compare on 2026-10-23) — TCP only. TCP confirmed: all 24 TCP sockets of
   proxied Opera are `CLOSED`.
[x] Results: rows "bypassing SplitPipe" in Connections (own style), a badge and count in the app row and inspector with the
   existing "Abort connections", a notification at most once per app per hour, an event.

## Step 5: Automation (URL scheme, Shortcuts, hotkeys)

[x] Command layer in the app shared by all entry points: toggle / on / off, set route (app, route, duration),
   revert temporary route, query app route and state. App resolution by bundle id or display name; route resolution
   by id (`direct`, `vpn:amnezia`, `default`, `block`) or route name.
[x] URL scheme `splitpipe://` (`toggle`, `on`, `off`, `route?app=&via=&for=15m|1h|quit|vpn`, `revert?app=`):
   `CFBundleURLTypes` in Info.plist, handler in `AppDelegate`. Confirmation dialog unless the sender (Apple Event
   sender pid → bundle id) is Shortcuts or our own widget.
[x] App Intents: `ToggleSplitPipe`, `SetAppRoute` (AppEntity, RouteEntity, optional duration), `RevertTemporaryRoute`,
   `GetAppRoute`, `GetStatus`; `AppShortcutsProvider` with phrases (Russian and English).
[x] Hotkeys with KeyboardShortcuts: add the SPM package to `project.yml`; shortcuts "toggle SplitPipe" and "route menu
   for the frontmost app" (NSMenu at the mouse pointer with routes and "temporarily…"); recorders in "General"
   (section "Keyboard Shortcuts"), plus the list of URL senders allowed without confirmation.

## Step 6: Widget and Control Center

[x] App Group in use again: shared `UserDefaults(suiteName:)` for the widget state. Fix `Config.appGroup` to come from
   the entitlement / build setting instead of the hardcoded team id.
[x] App publishes `WidgetState` (on/off, status, connected VPNs, problems, traffic today) on change, traffic at most once
   a minute; calls `WidgetCenter.reloadAllTimelines()`.
[x] New target `SplitPipeWidgets` (WidgetKit extension, embedded in the app): small and medium widget with status,
   VPNs, problems and traffic; tap opens the app.
[x] Control Center control: `ControlWidgetToggle` "SplitPipe" with its state from the App Group. Its intent must reach
   the app (proxy control lives there): the control's `SetValueIntent` runs in the widget extension and returns `OpenURLIntent(splitpipe://on|off?token=…)`;
   the token is a per-install secret in the App Group, so the app runs it without the confirmation dialog.
[x] Update the known limitations (`docs/known-limitations.md`) and the live verification plan for each step.

## Tests (after all steps)

[x] `Tests/IPListsTests.swift`: formats, comments, invalid lines, host bits, merge (overlap, adjacent, full range),
   pack/unpack, lookup boundaries, list order, missing lists, upsert / keepOnly, a large sparse list.
[x] `Tests/EventsTests.swift`: `EventJournal` numbering, batches, persistence, new journal per file, 30-day retention
   and the 5000 limit, `EventKind` round trip and severity; `EventLog` merge, dedupe, cursors, journal reset, sorting
   of late events, retention, persistence.
[x] `Tests/URLCommandTests.swift`: `splitpipe://` commands, parameters, encoding, token, errors; duration parsing and
   ends; `TemporaryRoute` round trip.
[x] To make them testable: `EventLog`, `URLCommand` (with `CommandError`) and the temporary route types moved into
   files without `AppModel` (`EventLog.swift`, `URLCommand.swift`, `TemporaryRouteTypes.swift`).


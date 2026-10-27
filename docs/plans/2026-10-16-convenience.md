# Description

Stage 6 of the original plan: statistics, import/export, temporary routes, notifications, profiles and distribution.

# Implementation

## Step 1: Statistics

[x] **Statistics** (section Statistics, design — `design/prototype.html#view=stats`): the extension itself counts
   traffic ↓/↑, connections and blocks per app and actual route ("Default" — where it really went), in 5-minute
   (2 h) and hourly (30 days) buckets, adds active connections every 10 s, writes to disk once a minute and on stop; the
   app requests an aggregate (`stats(from:bucket:)`). Screen: Hour / Today / 7 Days / 30 Days, tiles, a Swift Charts
   chart by route, routes, apps. Reset — Settings → Advanced. IPv6/QUIC rejections are not counted as blocks. Not
   verified: persistence across an extension restart.

## Step 2: Rules and diagnostics export

[x] Rules import and export (JSON), diagnostics export to text.

## Step 3: Temporary routes

[x] **Temporary route for an app** (2026-10-23): switch an app to another route for a while (15 min / 1 h / until the
   app quits / until the VPN disconnects), then the rule reverts by itself. A timer icon next to the route picker in the
   list and in the menu bar, "Temporarily…" in the details panel; there also a countdown, "then — <route>" and "Revert
   now". Stored in the app (`temporaryRoutes`, `TemporaryRoutes.swift`): the previous rule and the end; the extension
   sees a regular rule. Checked every 5 s, on route changes and on app launch/quit; "until the VPN disconnects" — if the
   VPN did not return within 30 s (a reconnect is not a disconnect). Picking a route by hand makes it permanent; a
   temporary route over a temporary one reverts to the original rule. If SplitPipe is closed, the rule won't revert
   early — expired ones are removed right at launch. Not verified live.

## Step 4: Notifications

[x] **Notifications** (2026-10-23, `Notifications.swift`, setting in General, on by default): a VPN with apps on rules
   disconnected for more than 10 s — which are blocked, which went to the fallback, and "connected again"; the VPN kill
   switch blocks "Direct"; the proxy stopped not by the switch and did not come back within 15 s; a temporary route
   ended by itself. A repeated event replaces the notification, a resolved one is removed. A click opens the relevant
   section. Permission is asked after onboarding and when the setting is turned on; if denied — a hint in settings and a
   button to System Settings. Not verified live.

## Step 5: Profiles

[ ] Profiles: rule sets, switching by Wi-Fi SSID and by whether Amnezia is connected.

## Step 6: Distribution

[ ] Developer ID, notarization, the `app-proxy-provider-systemextension` entitlement, auto-update (Sparkle).

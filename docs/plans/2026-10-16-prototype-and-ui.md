# Description

Stages 0–1 of the original plan: a working prototype of interception, then the design and the native SwiftUI
interface. The interactive design prototype is `design/prototype.html` (brief: `DESIGN_BRIEF.md`).

# Implementation

## Step 1: Prototype

[x] Connection interception, interface binding, Amnezia kill switch bypass — checked on Opera.

## Step 2: Design

[x] Interactive prototype: `design/prototype.html` (brief: `DESIGN_BRIEF.md`), approved.
   State in the URL: `prototype.html#theme=dark&view=routes&off=work&ks=always&popover=1&settings=ks&onb=1&diag=1`.
[x] App icon (`design/icon`, `Assets.xcassets`).

## Step 3: Main window and screens

[x] Main window: sidebar with sections and counters, status card with the SplitPipe switch, `⋯` menu (extension
   install, helper, refresh, settings). The last section is remembered.
[x] Screen title bar as in the design (title, subtitle, items on the right, full-width line).
[x] **Apps:** list under the common title bar, details panel on the right; filter "Running / With Rules / All" (custom
   segmented control), system search; sections "RUNNING / NOT RUNNING"; route selection in one pop-up with groups;
   problem line under the name ("… unavailable → blocked"); row highlight on hover, full-width separators.
[x] **App details panel:** route, "Remove Rule", "If the Route Is Unavailable" (block / default / fallback), actual
   route, recent connections, "Drop Connections", "Restart app".
[x] **Routes:** "Direct" and VPN cards (interface, local and external IP with country, check with latency, apps of the
   route), "Test Connection" / "Test All Routes", rename a VPN by double click, banners: kill switch detected and
   bypassed / blocking, scoped route missing, VPN disconnected.
[x] **Connections:** live feed (once a second) — time, app (helper processes under their app), address and host name,
   protocol, route as a colored badge, traffic; filter by route, grouping by app with "Drop", pause, context menu; row
   highlight, fixed-width columns.
[x] **Diagnostics:** step by step with a spinner, summary banner, "Fix" buttons: extension, SplitPipe, default route,
   scoped route, each route with IP, kill switch, traffic split, rules, DNS.
[x] **Settings window** — only what works: General (login, start at boot, menu bar, Dock — at least one icon is on),
   Routing, Helper (state, kill switch bypass, route, last action, VPN kill switch, install / check / remove), Checks,
   Advanced (+ "Run setup again"). The Kill switch and DNS tabs return with their features.

## Step 4: Localization, windows, menu bar, onboarding

[x] Russian or English UI by system language: a Russian system gets Russian, any other gets English (2026-10-19).
   String Catalog `SplitPipe/Localizable.xcstrings` (keys are Russian text), countries, dates and sizes use the same
   locale (`Locale.app`). Helper texts are codes (`HelperEvent`), translated by the app. Checked with
   `-AppleLanguages (en)`, `(ru)` and `(de)` → English.
[x] One main window (2026-10-19): a `Window` scene instead of `WindowGroup` — "Open SplitPipe" brings the open window
   forward instead of creating a new one (before: every click made another window); after closing, a click on the Dock
   icon opens it again.
[x] **Menu bar** (`MenuBarExtra`, window): icon by state (working / problems / turning on / off), status and switch,
   kill switch, helper, connected VPNs, problem banners, the active app (last frontmost one, except SplitPipe) and up to
   6 apps with rules with route selection, "Open SplitPipe", "Settings…", "Quit". Layout debugging:
   `-SPMenuPreview YES` shows the same in a regular window.
[x] **Onboarding** on first launch: extension → proxy configuration → helper, step state comes from the system
   (pending / waiting for approval / done / error with "Try Again"), then "You're All Set". Not shown if everything is
   already set up. `-SPOnboarding YES` shows it on a configured machine.

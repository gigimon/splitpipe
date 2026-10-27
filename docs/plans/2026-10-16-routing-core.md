# Description

Stage 3 of the original plan: the routing core — what to do when a route is unavailable, routes by role, several VPNs,
managing all apps, command-line programs, WebKit and XPC services, route checks, and a global kill switch.

# Implementation

## Step 1: Rules and fallbacks

[x] **What to do if a route is unavailable** (per rule): block / default route / fallback route. If the fallback is gone
   too — block, traffic never bypasses the chosen route. Defaults are in the settings.
[x] **"Block"** as a route (a firewall for the app).
[x] Route for apps without a rule (e.g. "Block" — only apps with a rule get network access).
[x] Dropping connections on a rule change (on/off), a "Drop Connections" button, "Restart app".
[x] Local addresses (10/8, 172.16/12, 192.168/16, link-local) go by the system route even for redirected apps.
[x] IPv6 of interface-bound apps is rejected at once if the interface has no IPv6 route; always — by an option.
[x] DNS (port 53) always goes by the system route.
[x] **"Direct" without a scoped route** counts as unavailable: the rule goes to the fallback at once instead of hanging
   for 5 s with `Network is down`. If no VPN holds the default route — it goes by the system route.

## Step 2: Routes by role and several VPNs

[x] **Routes by role:** "Direct" is the interface with the default gateway (Wi-Fi or Ethernet), a VPN is stored by key
   (`vpn:amnezia`), not by `utunN`; the config is recomputed on network change.
[x] **Several VPNs:** each `utun` with IPv4 is a separate route, renamable; disconnected ones are kept in rules and shown
   grayed. Recognized (`VPNDetection`): Amnezia, WireGuard, OpenVPN and Outline, other utuns are "VPN utunN":
   Network Extension services (Outline, WireGuard, OpenVPN Connect) via SCDynamicStore, key `ne:<service id>`, service
   name; `amneziawg-go` / `wireguard-go` / `openvpn` by process: the only running client gets the utun with the default
   route (the owner of the `utun_control` socket is visible only to root without a sandbox — not in the app or the
   extension).
[x] **Routes by role in the extension itself.** The extension gets rules with roles (`direct`, `vpn:amnezia`, fallback)
   and finds the interfaces itself (`NetworkState`: routing table and processes via sysctl) — on routing socket and
   interface events, with a timer as a safety net. If a connection's binding changed (Amnezia reconnected with another
   `utunN`, Wi-Fi ↔ Ethernet, the VPN came back after the fallback), the connection is dropped (if dropping on rule
   change is on). Connections by the system route ("Default", "Direct" without a VPN) are bound to the default route's
   interface: those opened through en1 while the VPN was reconnecting are dropped when it returns instead of living past
   the kill switch. Diagnostics has the "Routes in the Extension" check: does the extension's view match the app's.
   Not verified on a real Amnezia reconnect and Wi-Fi ↔ Ethernet.
[x] ~~Keep rules in the App Group~~ — not needed and does not work: the extension runs as root, its container is
   `/private/var/root/Library/Group Containers/…`, while the app's is in the user's home folder. Rules for the extension
   are saved in the proxy configuration anyway (they survive a restart); the helper gets them over XPC.

## Step 3: Which processes rules apply to

[x] **Manage all apps** (on by default): connections of apps without a rule are handled by the extension too, so any app
   switches at once. System services and VPN clients are left alone.
[x] **Rules for command-line programs** (curl, git, ssh) by binary path: key `path:/usr/bin/curl`, a terminal button in
   the Apps title bar, a "Programs" section. The extension takes the pid from the flow's audit token and the path via
   `proc_pidpath` (works in the sandbox). Symlinks (`/opt/homebrew/bin/git` → `Cellar/…`) are resolved on every rules
   push. Checked: `path:/usr/bin/curl (com.apple.curl)`.
[x] **WebKit and XPC services:** a process without its own rule gets the rule of its responsible app
   (`responsibility_get_pid_responsible_for_pid` → signing id or bundle id; a responsible program — by path). Every app
   has its own `com.apple.WebKit.Networking`. Checked: OrcaSlicer, a test binary with WKWebView. In the feed the
   connection is shown under the app, the process in parentheses.
[x] **Menu bar apps** (`LSUIElement`, `activationPolicy == .accessory`: Google Drive, Raycast, Dropbox) in Running
   (2026-10-19): the list used to take only `.regular`. `.accessory` apps from `/Applications` and `~/Applications` are
   shown; system agents (`/System/Library/CoreServices`) and nested helpers
   (`Google Drive.app/Contents/Applications/FinderHelper.app`) are not. Routing did not need changes: a signing id rule
   (`com.google.drivefs`) covers the File Provider `com.google.drivefs.fpext` by prefix, helpers — through the
   responsible app. Checked: the filter on the live process list, Google Drive in Running.

## Step 4: Route checks

[x] **Route check and external IP:** the request is made by the extension (root, past the kill switch) through the
   route's interface; Cloudflare trace (`1.1.1.1/cdn-cgi/trace`, no DNS) → IP and country, then the list of fallback
   services from the settings (by default `www.cloudflare.com/cdn-cgi/trace` — also with country, ipify, icanhazip).
   UDP — STUN (Google, Cloudflare) through the same interface: if the external IP over UDP differs from TCP, the card
   and diagnostics show it. On a button, on a schedule (5 min by default) and on network change — when the route's
   interface or address changed (setting "Test when the network changes"). The kill switch is detected by fact (the
   extension gets out, the app doesn't).
   2026-10-19: the banner "VPN kill switch blocks Direct" got stuck — it was set by a check right after sleep when there
   was no network yet, and "Direct" was not rechecked on a VPN reconnect (same address and interface). Now "Direct" is
   rechecked 10 s after wake, 3 s after the proxy is enabled and after a default route change (the VPN removed or
   re-added `0/1`). "Blocking" is shown only after a repeated failure 20 s later, only while SplitPipe is on, with the
   check time; turning off resets the result. Not verified live: sleep and a real kill switch without the bypass.

## Step 5: Global kill switch

[ ] **Global kill switch** (pf through the helper, anchor `com.apple/splitpipe`): modes off / on VPN drop / always.
   Outgoing traffic on physical interfaces is blocked, except `user root` (the extension and VPN daemons), LAN, DHCP.
   Check Network Extension VPN clients that don't run as root: allow their server address.

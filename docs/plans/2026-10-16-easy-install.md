# Description

Stage 2 of the original plan: two-click install. The user only confirms system prompts, everything else happens by
itself. Fully without confirmations is impossible: macOS requires manual approval of network extensions (only MDM can
avoid it).

# Implementation

## Step 1: Extension lifecycle

[x] On launch check the extension state (`propertiesRequest`): installed / waiting for approval / not installed.
[x] Update: when a new version launches, the extension replaces itself (approval is inherited), the proxy restarts.
[x] If there is no extension — request activation right at launch; while waiting for approval, open System Settings.
[x] After the first activation SplitPipe turns itself on.
[x] **"Start at boot"** (setting in General): while it is on, SplitPipe keeps itself in Login Items
   (`SMAppService.mainApp`), at login it starts without a window and enables the proxy if SplitPipe was on; the helper
   gets "enabled" as soon as the proxy is connected. On-demand start (`onDemandRules`) is not used: it makes the proxy
   mandatory for the whole system, and if the provider is being replaced or fails to start, all traffic hangs, DNS
   included (incident 2026-10-18). Not verified: a real reboot.

## Step 2: Root helper

[x] **Root helper** `SMAppService.daemon` (`dev.splitpipe.helper`, one approval in "Allow in the Background"):
   - XPC `setEnabled` / `status` / `resetConnections` / `restart`; connections only from SplitPipe of our team and vice
     versa;
   - while SplitPipe is on: the pf rule `pass out quick on <phys> user root flags any no state` and scoped `0/1` +
     `128.0/1` through the physical interface (marked `RTF_PROTO2`) — only while a VPN holds the default route; removes
     them when SplitPipe is turned off, when the physical interface changes and **immediately** when its link blinks
     (`RTM_IFINFO`, `State:/Network/Interface/<if>/Link`) or the VPN utun disappears, re-adds them after the VPN host
     route returns (at most 15 s); recreates them on `RTM_NEWADDR` and a gateway change; reacts to routing socket
     events and logs who (pid) changed the routes;
   - restarts itself after an app update: it watches its binary and exits when it is removed or replaced (otherwise
     the process code does not match the signature on disk and the app rejects XPC: `-67030`), launchd starts the new
     version (`KeepAlive`); the app resends the state to it if it was approved or restarted later;
   - checked 2026-10-18: on enabling SplitPipe it added the pf rule and scoped `0/1` + `128.0/1` through en1
     (`UGS2cIg`) within a second, reset 15 old connections; diagnostics all green, Opera "Direct" through en1, IPv6
     rejected at once, no errors. In the route log its own `route add` shows process name `?`: `/sbin/route` has
     already exited by then. On turning SplitPipe off (21:05:30) the pf rule and both scoped routes were removed in the
     same second, the table was as before enabling. Amnezia reconnect (22:45:00, 0.76 s, same utun4):
     AmneziaVPN-service removes and re-adds only its own `0/1`, `128.0/1` through utun4 and the host route to the server;
     our scoped routes through en1 untouched, the helper did not have to step in. Claude (`vpn:amnezia`, fallback —
     block) was blocked in the window without the VPN, the extension noticed the VPN return with ~0.5 s delay (2 more
     blocks after).
[x] `osascript ... with administrator privileges` and the pf items in the `⋯` menu removed, replaced by the helper
   status.
[x] **Reset of connections opened before SplitPipe** (helper): established TCP and connected UDP of the process and of
   those it is responsible for, to the internet (no LAN or DNS) → `block return out quick … from <local> to <remote>` in
   anchor `com.apple/splitpipe-reset`; the RST arrives on the next packet, the rule is removed when the socket closes
   (at most 30 min); if pf is off — `pfctl -E`/`-X` with a reference count. Called by: "Drop Connections", a rule change
   (with dropping enabled), enabling SplitPipe (apps with rules). Checked on Notes and Google Drive: connections found,
   one replaced at once, the rest were idle — they reset on the first packet.

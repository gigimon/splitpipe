# Description

Security review 4 (2026-11-06), checked against the code on 2026-11-06. Only findings worth fixing are kept; what
overlaps with [review 2](2026-10-19-review-2-fixes.md), [review 3](2026-10-20-review-3-fixes.md) and
[known limitations](../known-limitations.md) is not repeated.

Threat model: SplitPipe routes the user's own apps; it is not a sandbox against malicious code running as the user.
Such code can rewrite the policy directly (rules, IP lists, probe URLs live in the app's `UserDefaults`), and it can
escape a rule by picking a signing id that has none. The provider message channel (`sendProviderMessage`) is available
only to the app that owns the NE configuration. Findings that assumed a spoofed signing id or a foreign sender on that
channel (VPN-client detection by substring, rule inheritance by id prefix, responsible app from `Info.plist`,
unauthenticated channel, size limits on messages) were dropped for this reason; the trade-off is documented instead.

# Implementation

## Step 1: cheap hardening

[ ] **Probe request built from raw `URL.path`** (`Shared/Probe.swift:84-85`). `URL(string:)` keeps CR/LF in `path`
   and decodes `%0d%0a` into it (checked: `http://a/x\r\nY: 1` → `/x\r\nY: 1`), so a probe URL injects headers or a
   second request; any scheme passes (`file://h/...` is sent as plain HTTP). Fix: allow only `http`/`https`, reject
   control characters in host and path, send the percent-encoded path (`URLComponents.percentEncodedPath`).
[ ] **`bucket == 0` crashes the extension** (`SplitPipeProxy/TrafficStats.swift:76`, `t - t % size`). The app sends
   only 3600 or a period bucket, but a trap in the root process stops all routing. Fix: `guard bucket > 0` in the
   `stats` handler, an empty reply otherwise.
[ ] **Relay opened after `stopProxy`** (`TransparentProxyProvider.swift:362-380`, `:433`). A flow waiting for its
   interface (`waitForInterface`, up to `interfaceWait`) is opened after `stopProxy` cleared `relays`: its
   `NWConnection` is never cancelled. Fix: a `running` flag set in `startProxy`, cleared in `stopProxy`, checked before
   `open()`; reject the flow otherwise.

## Step 2: routing leaks

[ ] **Port 53 escapes the interface binding for TCP** (`TCPRelay.swift:30`, `isDNS` at
   `TransparentProxyProvider.swift:10-13`). Any TCP flow to port 53 goes by the system route, including for apps pinned
   to a VPN — not only "Direct" as `known-limitations.md` says. Fix: keep the DNS exemption for UDP only, or document
   it for both protocols and every route.
[ ] **UDP checks only the first destination** (`TransparentProxyProvider.swift:398-413` vs `UDPRelay.swift:62-72`).
   IPv6 rejection, QUIC blocking and IP-list rules are decided by the flow's first endpoint; later datagrams of the
   same flow go to any address, and port-53 datagrams to any server skip the interface binding (a DNS leak around the
   pinned VPN). Fix: in `UDPRelay.connection(for:)` apply the IPv6/QUIC rejection per endpoint (drop that peer); for
   IP lists either re-match per endpoint or keep the documented "first address" behaviour.

## Step 3: fail-open decisions

[ ] **Helper falls back to "extension process exists"** (`SplitPipeHelper/main.swift:320-343`). When the heartbeat
   is unreadable for any reason other than `ENOENT` in an existing container, the helper treats a running extension
   process as a running proxy; the process outlives `stopProxy`, so the kill switch bypass and the scoped routes can
   stay armed with the proxy off. Review 3 kept this fallback on purpose. Decide: fail closed (no heartbeat — no
   bypass, "Direct" apps lose network until the proxy is back) or keep it and log it as a warning in diagnostics.
[ ] **No configuration and no last good copy** (`TransparentProxyProvider.swift:208-222`). The extension starts with
   empty rules and passes every flow to the system: `Block` rules and route pinning stop applying until the app
   resends its config. Decide: reject flows of interface-pinned and blocked verdicts until the first `setConfig`, or
   keep fail-open (the network keeps working) and only show the red state that already exists.
[ ] **No cap on live relays** (`TransparentProxyProvider.swift:433`). Every governed flow gets a relay and an
   `NWConnection`, without a limit; one app opening thousands of sockets under "Manage all apps" doubles them in the
   root process. Fix: a global cap (e.g. 4000) with `reject(flow)` and a counter in `ProviderStatus`.

## Step 4: documentation and hygiene

[ ] **Known limitations**: rules match the signing id (and `path:` the binary path) without verifying the signature
   or team id; SplitPipe does not protect against code running as the user. `Block` and route pinning do not apply to
   loopback (excluded from interception) and, with "LAN via system", to private, link-local and CGNAT addresses.
[ ] **VPN client by substring** (`Shared/VPNDetection.swift:48-52`): `localizedCaseInsensitiveContains("amnezia")`
   also matches unrelated apps and drops their rules. Replace with exact bundle ids / a prefix of Amnezia's ids.
[ ] **Audit token fields by index** (`SplitPipeProxy/OwnerResolver.swift:33-41`): the layout matches `libbsm`
   (`val.5` pid, `val.1` euid, `val.7` pid version), but use `audit_token_to_pid` / `audit_token_to_euid` /
   `audit_token_to_pidversion` instead of the indexes.

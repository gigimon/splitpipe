# Known limitations

- Connections SplitPipe handles itself ("Manage all apps", "Default" included) belong to the extension
  `dev.splitpipe.app.proxy` (root), not to the app, for other firewalls (Little Snitch, LuLu), `nettop` and pf by user:
  their per-app rules do not apply to such connections.
- The helper resets connections opened before SplitPipe with a pf rule: the RST arrives on the app's next packet, so
  idle connections (IMAP IDLE, keep-alive) switch with a delay. Without the helper — "Restart app". The reset works only
  if the connection has no pf state entry: Amnezia's rules are `no state`, but with a VPN client or firewall using
  `keep state` packets follow the state past the reset rule (a state can't be killed selectively on macOS). The helper
  logs such connections.
- A temporary route is reverted by the SplitPipe app: while it is closed, the rule won't revert early (expired ones are
  removed right at launch).
- The responsible app is found with a private libsystem function (`responsibility_get_pid_responsible_for_pid`): if
  Apple removes it, WebKit will bypass the app's rules again.
- IP lists apply only to connections by address: if an app connects by name (NSURLSession and Network.framework give the
  extension a name, not an IP), there is no address yet and the list does not apply. Only for apps without their own
  rule and with "Manage all apps". UDP — by the flow's first destination address.
- DNS queries (port 53) always go by the system route, even for "Direct" apps (see
  [DNS and domain rules](plans/2026-10-16-dns-and-domain-rules.md)).
- ICMP (ping) and raw sockets are not intercepted; statistics do not see traffic that bypasses SplitPipe (system
  services, command-line programs without a rule).
- The kill switch bypass lets through any root process explicitly bound to the physical interface (regular root
  traffic still goes into `utun`). If a VPN client reloads pf so that `anchor "com.apple/*"` is not called or comes after
  its rules, the bypass stops working — the helper sees and shows it, but does not fight the client's kill switch.
- During a VPN reconnect window (a fraction of a second) "Default" connections go directly; when the VPN returns they
  are dropped and reconnect through it — see [system notes](system-notes.md).
- A command-line program rule (`path:`) works by the binary path, not the signature: a file in the user's folder can be
  replaced, and the replacement gets the rule's route. The signature is not checked on purpose — after `brew upgrade` or
  a rebuild the rule would silently stop working.
- IPv6 through the Amnezia kill switch is blocked (`250.blockIPv6`), en1 has no IPv6 route: "Direct" works over IPv4
  only.
- Quitting SplitPipe does not stop routing (the extension is a separate process). After a reboot the proxy is enabled
  by the app ("Start at boot" through Login Items), not by the system: until the app starts, rules do not apply.
- A VPN without a Network Extension is recognized by its process: if two known clients run (e.g. `amneziawg-go` and
  `openvpn`), their utuns are not recognized and are shown as "VPN utunN" (the extension sandbox has no access to
  `proc_pidfdinfo` of other processes; the exact way — by the `utun_control` socket — is available only to root without
  a sandbox).

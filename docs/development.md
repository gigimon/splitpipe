# Development notes

## CI and versions

- `.github/workflows/ci.yml` runs on pushes to `main` and on pull requests (`macos-26`, Xcode 26.5): `make test` and
  `make package`, which builds an unsigned Release archive (`build/release/SplitPipe-<version>-macOS.zip` + `.sha256`)
  and uploads it as an artifact. Unsigned, the system extension can't run — the archive only proves the build works.
- Versions come from git (`scripts/resolve_version.sh`, sourced by `scripts/package.sh`): HEAD at a `vX.Y.Z` tag gives
  `X.Y.Z`, anything else `X.Y.Z-N-g<hash>` after the last tag (the short hash before the first one), `-dirty` with
  uncommitted changes; the build number is the commit count. `EXTENSION_VERSION` stays as in the Makefile. `make build`
  keeps its timestamp build number for local development.

## Build and development lessons

- The system extension's Info.plist must have `CFBundlePackageType = SYSX`, otherwise `sysextd` rejects it.
- The extension is replaced only on a new `CFBundleVersion`. The Makefile takes it from the last commit touching
  `SplitPipeProxy/` and `Shared/` (or from file mtimes without git): every replacement stops the proxy and drops all
  intercepted connections.
- All operations with `NETransparentProxyManager` are strictly serialized (`serialized`): concurrent
  `saveToPreferences` calls give `configuration is stale`, and a start in the middle of an extension replacement is
  killed by the system ("Plugin was disabled").
- **Do not use `onDemandRules`**: the proxy becomes a `compulsory, kernel-activated` agent for the whole system; if the
  provider is being replaced or fails to start at that moment, all traffic hangs, DNS included (incident 2026-10-18,
  reboot).
- After its binary is replaced, the helper must restart itself (it watches its own file): otherwise the process code
  does not match the signature on disk, and the app rejects XPC (`-67030`), even to ask it to restart.
- `MenuBarExtra(isInserted:)` writes to the binding on every update — assign only on change, otherwise it is an
  endless redraw loop (the app hangs at 100% CPU).
- The app must live in `/Applications`. `open` does not relaunch an already running app — `make install` quits
  SplitPipe first.
- Browsers reuse connections (keep-alive, HTTP/2, QUIC), so old connections must be dropped when a rule changes;
  connections opened before SplitPipe are reset by the helper (the RST arrives on the app's next packet).
- `NWConnection` often goes to `.waiting` for a moment and then connects by itself: close a relay only on `.failed` or
  if `.waiting` lasts longer than 5 s.
- A UDP flow does not know its destination: the first address comes in
  `handleNewUDPFlow(_:initialRemoteFlowEndpoint:)`.
- SwiftUI `Table` cells on macOS live in separate hosting views without `@EnvironmentObject` — accessing it crashes the
  app.
- macOS 26: `.inspector` and the toolbar are transparent and draw over the content — screens have their own title bar
  (`.screen(...)`). Fixed-width elements next to `NavigationSplitView` columns need `frame(minWidth: 0)`, otherwise
  layout loops and AppKit crashes the app.
- macOS picks the UI language from the app's localizations (`en`, `ru`; `CFBundleDevelopmentRegion = en` — any other
  system language gets English). `ru.lproj` must have a full string table: if a key is missing there, Foundation takes
  it from `en.lproj`, not the key itself, so every string in the catalog has an explicit Russian value. Formatters
  (countries, dates, sizes) and `.environment(\.locale)` use `Locale.app`, not `Locale.current`: otherwise with the
  English UI on, say, a German system, countries would be in German. Checking the language:
  `--args -AppleLanguages "(en)"` / `"(ru)"`.
- New strings: a literal in `Text`/`Button`/`Label` gets into the catalog by itself, strings in the model go through
  `String(localized:)`; keys are collected at build time (`SWIFT_EMIT_LOC_STRINGS`) and added to the catalog with
  `xcrun xcstringstool sync SplitPipe/Localizable.xcstrings --stringsdata <Objects-normal/arm64>/*.stringsdata`.
  Counters are plural variants in the catalog (ru: one/few/many/other, en: one/other).
- The helper (root, its own locale) and the extension (no localizations) do not build UI text: the helper sends
  `HelperEvent`; the names "Direct" / "Default" / "Blocked" that the extension writes into the feed in Russian are
  translated by the app (`FlowRecord.routeLabel`). `Config.locale` in Shared is no longer used — remove it on the next
  extension change, and pass the route id in the feed instead of the name at the same time.

## Troubleshooting

- **Logs.** Info logs are not persisted (only live: `make logs`); proxy start/stop, network and rule changes, helper
  actions are `notice` and can be seen later. In zsh `log` is a builtin, use `/usr/bin/log`.
  - helper (route log with pids, pf state on VPN loss/return, `pf anchor effective / not effective`):
    `/usr/bin/log show --last 30m --predicate 'subsystem == "dev.splitpipe" AND category == "helper"'`
  - extension: `/usr/bin/log show --last 30m --predicate 'subsystem == "dev.splitpipe" AND category == "proxy"'`
    (`--info` adds every connection, until evicted from memory)
  - proxy session: `process == "nesessionmanager" AND eventMessage CONTAINS "SplitPipe"` (commands, status, "Plugin
    was disabled"); Network.framework errors in the extension:
    `process == "dev.splitpipe.app.proxy" AND subsystem == "com.apple.network"`
  - system DNS: `process == "mDNSResponder" AND eventMessage CONTAINS "timing out"`; sleep: `pmset -g log`
- **State:** `netstat -rn -f inet` (our scoped routes have flags `UGS2cIg`), `route -n get -ifscope en1 1.1.1.1`,
  `sfltool dumpbtm` (helper and launch at login), `systemextensionsctl list`.
- **Debug arguments** (`open /Applications/SplitPipe.app --args -ApplePersistenceIgnoreState YES …`):
  `-SPEnable YES` — turn SplitPipe on; `-SPDiagnosticsOut <file>` — diagnostics report (including how the app and the
  extension see the network); `-SPInstallHelper YES`; `-SPReset <bundle id>` — reset an app's connections through the
  helper; `-SPOnboarding YES`; `-SPMenuPreview YES` (menu bar popover in a regular window); `-SPOpenSettings YES`
  (+ `defaults write dev.splitpipe.app sidebarSection|settingsTab|statsPeriod`).
- **Window screenshots** without capturing the rest of the screen: get the window id via
  `CGWindowListCopyWindowInfo`, then `screencapture -x -o -l <id>`.
- **Prototype** in the built-in browser: `.claude/launch.json` (configuration `prototype`, port 8765),
  `prototype.html#theme=dark&view=stats|routes|conns|diag&popover=1&onb=1&settings=…`.

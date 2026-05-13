# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ZedisUI is a native macOS Redis client (SwiftUI, deployment target macOS 15). The
goal is feature parity with Medis (https://getmedis.com/) — multi-window,
multi-connection, key browser + per-type editor + inline command terminal.

Bundle id `tech.xvanturing.ZedisUI`. Single-user app: one TCP connection per
session, no pooling.

## Build / run

The Xcode project is generated from `project.yml` via XcodeGen. After editing
`project.yml` (or adding/removing source files when not relying on the
implicit `Sources/` glob), regenerate it:

```sh
xcodegen
```

Build + run from CLI (used during development for fast iteration without Xcode):

```sh
xcodebuild -project ZedisUI.xcodeproj -scheme ZedisUI \
    -configuration Debug -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/ZedisUI.app
```

When iterating on UI, kill the running app first:
`pkill -f ZedisUI; open DerivedData/Build/Products/Debug/ZedisUI.app`.

There are no tests yet.

### Cutting a release

See [`docs/release.md`](docs/release.md). The flow is automated by
`./release.sh <version>` and has a five-rule contract at the top of
that doc — read it before changing `release.sh` or running a release.
Do NOT trigger a release yourself; it is user-initiated.

### Important build settings

- `SWIFT_VERSION: "5.0"` and `SWIFT_STRICT_CONCURRENCY: minimal` are deliberate.
  RediStack's public API is not `Sendable`, so we use Swift 5 mode and
  `@preconcurrency import RediStack/NIOCore/NIOPosix` in `RedisService.swift`.
  Do not flip these to Swift 6 / `complete` without adapting that file — it
  will not compile.
- App sandbox is on with `network.client`, `network.server`,
  `files.user-selected.read-write`, plus a
  `temporary-exception.mach-lookup.global-name` listing
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`
  so Sparkle 2 can talk to its bundled Installer and Downloader XPC
  services. Updates are installed by Sparkle's helper running outside
  our sandbox — we no longer grant ourselves any `/Applications/`
  write access. If you ever see the old `files.absolute-path.read-write`
  exception for `/Applications/`, that's stale — delete it.

## Architecture

### Window model (multi-window, two scene types)

`ZedisUIApp.swift` declares three scenes:

1. `Window("ZedisUI", id: "launcher")` — singleton **Launcher** window for
   managing saved connections (`LauncherView`).
2. `WindowGroup(id: "session", for: Connection.self)` — **Session** windows,
   one per connection. `Connection` is `Codable & Hashable` so SwiftUI can
   restore session windows. Open via `@Environment(\.openWindow)
   openWindow(id: "session", value: connection)`.
3. `Settings { PreferencesView() }` — system Preferences window.

The connection-manager menu item (⇧⌘0) finds the launcher `NSWindow` by
identifier and brings it forward.

### State ownership

- `AppState` (`@Observable @MainActor`) — top-level app state. Owns
  `connections: [Connection]` (persisted to disk via `ConnectionStore`) and
  `sessions: [Connection.ID: RedisSession]` (live sessions). Created once in
  `ZedisUIApp` and injected via `.environment(appState)`.
- `RedisSession` (`@Observable @MainActor`) — one per active connection.
  Owns the `RedisService` actor, the current DB index, the loaded key list,
  and `selectedKey` / `commandQueryActive`. Detail editors do NOT own a
  session — they read/write through the session's `service`.
- `RedisService` (`actor`) — the only thing that actually talks to Redis.
  Wraps a single `RedisConnection`. Methods are `async throws`; UI code
  awaits them from the main actor.

`selectedKey` and `commandQueryActive` are mutually exclusive — selecting a
key clears Command Query mode and vice versa. The clearing is done via a
custom `Binding` in `KeySidebarView` (the List's selection binding) and a
direct assignment in `terminalRow`'s click handler.

### Persistence

- Connections: `ConnectionStore` writes to a JSON file in Application
  Support. `Connection` itself does NOT carry the password.
- Passwords: stored in macOS Keychain, keyed by `Connection.id`, via
  `KeychainHelper`. Loaded on demand when constructing a `RedisSession`.

### View layout

- `LauncherView` — two-pane: brand sidebar + saved-connections list / quick-connect.
- `SessionWindow` → `SessionContent` (`RootView.swift`) — `NavigationSplitView`
  (sidebar = `KeySidebarView`, detail = `DetailView`) with an `.inspector`
  panel on the right (`InspectorPanel`).
- Window title uses `.navigationTitle(connection.name)` +
  `.navigationSubtitle("host:port · DB n · status")`. **Do not put a
  "Connected to X" pill in the toolbar's principal slot** — SwiftUI's toolbar
  Menu chrome can't be styled cleanly and we tried multiple times. Status
  lives in a small icon button (`ConnectionStatusButton`) that opens a
  popover with details. Errors surface via `ConnectionErrorBanner` in
  `safeAreaInset(.top)` — only when status is `.failed`.
- `DetailView` dispatches by `RedisKeyType` to `StringEditor` / `HashEditor`
  / `ListEditor` / `SetEditor` / `ZSetEditor`. When `commandQueryActive` is
  true, it shows `CommandQueryView` instead.

### SwiftUI gotchas hit in this repo

These were debugged the hard way; please respect them rather than re-trying.

- **`Menu` height is preserved by *keeping* the menu indicator visible.**
  When `.menuIndicator(.hidden)` is applied, SwiftUI's `Menu` collapses to a
  shorter `NSPopUpButton`-style bezel that no longer matches a sibling
  `.bordered` `Button`. The fix used in `KeySidebarView.searchRow` is the
  opposite of what looked right: **let the chevron show**. The Menu then
  renders at the full bordered-button height and lines up with the reload
  `Button` (which uses `.buttonStyle(.bordered) + .controlSize(.small) +
  .frame(width: 28, height: 28)`). Do not "tidy this up" by hiding the
  indicator — it will silently regress the alignment.
- **Toolbar principal slot adds chrome you can't remove.** Custom
  Capsule/HStack content gets a second pill drawn around it. We deleted that
  approach; the toolbar now uses default chrome plus the
  `ConnectionStatusButton` popover pattern.
- **`@preconcurrency import`** is required for RediStack/NIO — see Build
  Settings note above.

# ezvpn-apple

A universal native iOS + macOS SwiftUI app running the [`ezvpn`](../ezvpn)
IP-over-QUIC tunnel. The packet-tunnel provider ships as an **app extension on
iOS** and a **system extension on macOS** (the packaging Apple requires for
Developer ID distribution outside the App Store). **Scope:** dual-stack **split
tunnel**, optional tunnel DNS on iOS only, and macOS distribution via Developer
ID + notarization (`scripts/create-archive-macos.sh`).

It links `libezvpn.xcframework` (the Rust core, built from the sibling `../ezvpn`
repo and delivered via a local Swift package) into a `NEPacketTunnelProvider`.
The Rust side does the iroh connect + handshake + datagram loop; the Apple
Network Extension owns the `utun` interface, routing, and IP/MTU config.

## What this app does and does not do

- ✅ Multiple saved VPN profiles, WireGuard-app style: a tunnel list where each
  profile is its own `NETunnelProviderManager` (name shown in Settings > VPN).
  Add/edit/rename/delete profiles; connect one at a time (activating a second
  automatically tears down the first). All profiles share the one PacketTunnel
  extension. Non-secret settings live in `providerConfiguration`; the auth
  token is a device-only data-protection Keychain item shared with the extension
  through a keychain access group, and the VPN protocol stores only its
  persistent reference.
- ✅ IPv4/IPv6 split tunnel. The server gateway/interface routes are always
  routed automatically; extra IPv4 and IPv6 CIDRs are optional.
- ✅ Optional tunnel DNS on iOS, including match domains for conditional
  forwarding because iOS ignores installed DNS profiles while a VPN is active.
  The macOS build leaves the system's DNS configuration untouched.
- ✅ Connects to an `ezvpn` server over iroh (direct or relay), handshakes,
  tunnels IP over QUIC datagrams.
- ✅ Underlay-bypass routing, like the desktop client's bootstrap bypass: at
  connect, the core computes every relay IP plus the server's candidate
  underlay addresses, and any **global-scope** address a routed prefix would
  capture is excluded from the tunnel (`excludedRoutes`), so the transport never
  self-captures. Private/LAN server addresses are intentionally kept in the
  tunnel. Static (handshake-time) only — the server's mid-session address
  publications are not re-applied.
- ✅ Simple manual connect/disconnect. Tunnel teardown follows wireguard-apple:
  `stopTunnel` completes only after the Rust data plane has actually stopped.
- ✅ On macOS, a native menu-bar icon provides quick profile connect/disconnect,
  main-window, and quit actions. Closing the main window removes the Dock icon
  while leaving the menu-bar controls running; reopening restores both.
- ✅ Disconnect on network change: any change to the physical network (Wi-Fi ↔
  cellular, different Wi-Fi, network lost) cancels the tunnel rather than trying
  to migrate the QUIC session across it — reconnect manually on the new network.
- ✅ Refuses to start when a configured split-tunnel route overlaps the local
  network's subnet (e.g. routing `192.168.0.0/16` while on a `192.168.1.0/24`
  Wi-Fi): capturing the on-link subnet would cut off the LAN, including the
  gateway carrying the tunnel's own underlay traffic.
- ✅ Debug: while connected, the app shows the *applied* interface state —
  assigned addresses, tunnel routes, active bypass (excluded) routes, and on
  iOS, DNS settings — queried live from the tunnel process over the WireGuard-style
  runtime-configuration app message (single byte `0`). It can also show a live
  iroh connection-path snapshot (direct/relay paths) via app message byte `1`.
- ✅ macOS distribution for anyone, outside the App Store: the tunnel ships as a
  system extension and `scripts/create-archive-macos.sh` produces a Developer-ID-
  signed, notarized, stapled `.dmg`. The app activates the extension via
  `OSSystemExtensionRequest` at first launch (approved once in System Settings);
  activation requires the app to run from `/Applications`.
- ❌ No App Store or TestFlight submission. iOS still installs only via a
  development-signed build to a registered device. A Packet Tunnel Provider
  cannot run in the iOS Simulator.

## Documentation

- [docs/building.md](docs/building.md) — prerequisites, generating the project,
  local FFI dev, signing, running on macOS/iOS, and the unit tests.
- [docs/distribution-macos.md](docs/distribution-macos.md) — producing a
  Developer-ID-signed, notarized `.dmg` locally or in CI (including the GitHub
  Actions secrets the macOS release workflow needs).
- [docs/architecture.md](docs/architecture.md) — how the app, extension, and
  Rust core fit together; logs; and operational notes.

## Downloads (GitHub Releases)

### macOS — ready to run

Download the latest `.dmg` from the
[**Releases page**](https://github.com/flexaccessdev/ezvpn-apple/releases). It is
a **signed, notarized, drag-to-Applications** disk image — a click-to-run
download, **no Apple Developer account required to use it**: download the `.dmg`,
drag **ezvpn** to Applications, launch it, and approve the network extension once
in System Settings.

The DMG is produced by the **Release macOS DMG (Manual)** workflow
(`.github/workflows/release-macos.yml`), which publishes it as a GitHub
prerelease. See [docs/distribution-macos.md](docs/distribution-macos.md) for how
the DMG is built (locally or in CI).

### iOS — you must build and sign it yourself

There is **no ready-to-run iOS download.** The **Release iOS (Manual)** workflow
(`.github/workflows/release-ios.yml`) only attaches an **unsigned** bundle for
build verification and inspection:

- `ezvpn-ios-unsigned.tar.gz` — the iOS `ezvpn.app` (`ios-arm64`, device only).

**This is not installable as-is, and it cannot be re-signed into a working app.**
A Packet Tunnel Provider uses the restricted
`com.apple.developer.networking.networkextension` entitlement, which requires
**explicit, non-wildcard App IDs registered to your own paid team** — a shared
id can't be reused across accounts. So running the iOS app means **building from
source under your own team**, not re-signing the download.

Follow [docs/building.md](docs/building.md): copy
`Developer.local.xcconfig.sample` to `Developer.local.xcconfig`, set your
`DEVELOPMENT_TEAM` **and** a `BUNDLE_ID_PREFIX` your team owns,
`xcodegen generate`, then build with `scripts/run-device-ios.sh <DEVICE_ID>`.
Xcode signs it as it builds. (Building the macOS app from source works the same
way with `scripts/run-macos.sh`.)

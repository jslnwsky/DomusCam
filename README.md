<h1 align="center">
  <img src="docs/assets/icon-256.png" alt="DomusCam" width="120" height="120"><br>
  DomusCam
</h1>

<p align="center">
  A native client for Reolink cameras, NVRs, doorbells, and Home Hubs — on Mac, iPad, and iPhone.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-1ba6d8" alt="macOS 26+">
  <img src="https://img.shields.io/badge/iOS-26%2B-1ba6d8" alt="iOS 26+">
</p>

<p align="center">
  <a href="https://github.com/jslnwsky/DomusCam">GitHub</a> ·
  <a href="#install">Install</a> ·
  <a href="docs/FEATURES.md">Features</a> ·
  <a href="CHANGELOG.md">What's new</a>
</p>

---

DomusCam watches Reolink cameras on **your house Wi-Fi** — live view, recordings,
doorbell talkback, motion alerts — in a native Swift 6 app. Each household
runs its own copy. There is no DomusCam cloud and no Reolink cloud.

It is a fork of [Reolens](https://github.com/jestatsio/reolens) (MIT, J&E Stats),
rebranded and scoped to LAN-per-home: Reolink P2P discovery is not included.

![Adaptive multi-camera grid](docs/screenshots/grid-adaptive.png)

<sub>Screenshot footage is procedurally rendered, not real captures — privacy-clean and still representative.</sub>

## Highlights

- 🎥 **Live** — hardware-decoded RTSP (H.264 / H.265), adaptive grids up to 5×5, PiP, full 17-op PTZ, two-way talkback.
- ⏺️ **Recordings** — day-density calendar, thumbnail scrubber, a cross-hub "All Recordings" feed, and on-device natural-language search.
- 🔔 **Notifications** — rich motion / AI pushes with the trigger frame, relayed through *your own* iCloud, with per-camera and per-tag filters.
- 🗓️ **Schedules** — visual recording grid, motion windows with per-AI-tag overrides, and drawable privacy zones.
- 🧩 **Platform-native** — widgets, Live Activities + Dynamic Island, Shortcuts & Siri, Stage Manager, Liquid Glass throughout.
- 🔌 **Local REST API** — opt-in, LAN-only `/v1` HTTP API on macOS for Home Assistant, Shortcuts, and scripts.
- 🔒 **Private by design** — no server, no accounts, no telemetry; camera passwords stay in the Keychain.

The full surface lives in **[docs/FEATURES.md](docs/FEATURES.md)**.

## Install

Build from source (Xcode 26 + Swift 6.2). App Store / TestFlight shipping uses
bundle id `com.75-c.DomusCam` on team `NXVC3868F7`.

```sh
git clone https://github.com/jslnwsky/DomusCam.git
cd DomusCam
./Scripts/build-app.sh run      # macOS — builds + signs + launches
cd AppiOS && xcodegen generate  # iOS — then open in Xcode 26
```

## Quick start

1. **Launch DomusCam.** It asks for Local Network permission (to reach your
   cameras) and Notification permission (for motion alerts).
2. **Click + in the sidebar** to add a camera. Enter its IP (or hostname),
   username, and password — the rest is auto-detected.
3. **Pick a camera** to view it, and use the toolbar layout picker to switch
   between adaptive / spotlight / 2×2 → 4×4 grids.

Drag tiles to rearrange; right-click for "Make primary", "Rotate", and
per-channel settings.

## Remote access

DomusCam is **LAN-only** — it talks to the camera's local IP, never to
Reolink's cloud or a DDNS relay. To use it away from home, put the phone
*on* the LAN with an overlay network instead of forwarding ports.
**[Tailscale](https://tailscale.com)** is the recommended path.

Full step-by-step in **[docs/remote-connectivity.md](docs/remote-connectivity.md)**.

## Requirements

- **macOS 26 Tahoe+** (Apple Silicon or Intel), or **iPadOS / iOS 26+**
- **A Reolink camera, NVR, doorbell, or Home Hub** on the local network
- HTTP / HTTPS access to the device's CGI port (default 80 / 443)

## Privacy

DomusCam runs on your devices. The only network surface is your Reolink
devices (LAN), your own iCloud, and Apple's App Store / TestFlight for
updates. Camera-list sync uses iCloud Drive. Motion-event relay, snapshot
images, and Apple TV password sync each stay off until you turn them on.
"Run as Hub" does not turn those on; while Hub is on, this Mac's name goes
out in a heartbeat. No third-party analytics, crash reporting, telemetry,
or accounts.

**Credentials are device-local** — camera passwords live in each device's
Keychain (`kSecAttrSynchronizable: false` by default). They leave the device
only if you turn on iCloud Keychain sync or Apple TV password sync. The
camera list in iCloud does not include passwords. The full model is in
[AGENTS.md](AGENTS.md) §3, §4 and [SECURITY.md](SECURITY.md).

## Attribution

DomusCam is derived from **Reolens** by [J&E Stats](https://jestats.io),
MIT-licensed at [github.com/jestatsio/reolens](https://github.com/jestatsio/reolens).
The original copyright notice is preserved in [LICENSE](LICENSE).

## Documentation

| | |
|---|---|
| [Features](docs/FEATURES.md) | The full feature surface |
| [Architecture](docs/ARCHITECTURE.md) | Layers, concurrency model, repo layout |
| [Local REST API](docs/api/README.md) | The `/v1` HTTP API contract |
| [Changelog](CHANGELOG.md) | Per-release history (includes Reolens lineage) |
| [Contributing](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) | Dev setup + engineering principles |

## Development

```sh
swift build                 # libs + macOS app
swift test                  # unit + integration tests
./Scripts/build-app.sh run  # bundled .app (needed for Local Network access)

bash Scripts/check-versions.sh  # macOS + iOS marketing versions must match
bash Scripts/coverage-gate.sh   # per-target coverage regression gate
```

## Contributing

PRs welcome. Read [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md)
first. For security issues, use the private flow in [SECURITY.md](SECURITY.md).

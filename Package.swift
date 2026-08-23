// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DomusCam",
    platforms: [
        // 0.5.0 raises the floor to macOS 26 / iOS 26 to adopt Liquid Glass
        // and the ActivityKit + ControlWidget APIs that ship in those
        // releases. Users on macOS 14 / iOS 18 receive security-only
        // backports against the 0.4.x track per SECURITY.md.
        .macOS(.v26),
        .iOS(.v26),
        // 0.6.4 adds the AppWatch product (companion watchOS target).
        // Setting the floor at watchOS 11 lets the watch app run on
        // Series 6+ — the iOS/macOS floors are only consulted when
        // those platforms are the build destination, so this doesn't
        // affect the main app's deployment target.
        .watchOS(.v11),
        // 0.7.0 adds the AppTVOS product (Apple TV living-room viewer).
        // tvOS 26 to match the iOS/macOS SDK floor.
        .tvOS(.v26)
    ],
    products: [
        .library(name: "ReolinkAPI", targets: ["ReolinkAPI"]),
        .library(name: "ReolinkStreaming", targets: ["ReolinkStreaming"]),
        .library(name: "ReolinkBaichuan", targets: ["ReolinkBaichuan"]),
        // 0.8.x — DomusCamCore: the clean, Reolink-agnostic public API
        // contract (resource DTOs + the `CameraAPI` protocol). Zero deps;
        // the in-process implementation lives in AppShared and the HTTP
        // facade in DomusCamServer. See docs/api/.
        .library(name: "DomusCamCore", targets: ["DomusCamCore"]),
        // 0.8.x — DomusCamServer: hand-rolled NWListener HTTP/1.1 + SSE
        // facade over the `CameraAPI` contract. Depends only on
        // DomusCamCore; the app injects the live implementation. See
        // docs/api/.
        .library(name: "DomusCamServer", targets: ["DomusCamServer"]),
        .library(name: "AppShared", targets: ["AppShared"]),
        // 0.6.4 — Minimal watchOS-facing surface used by the
        // companion Watch App target in `DomusCamiOS.xcodeproj`.
        // Depends only on `ReolinkAPI` (pure HTTP+JSON) to avoid
        // dragging UIKit/AppKit-leaning code into the watch build.
        .library(name: "AppWatch", targets: ["AppWatch"]),
        // 0.7.0 — Apple TV viewer surface used by the DomusCamTVOS app
        // target in `DomusCamiOS.xcodeproj`. Depends only on ReolinkAPI +
        // ReolinkStreaming (live RTSP) — never AppShared — to stay thin,
        // mirroring the AppWatch precedent. See Sources/AppTVOS/README.md.
        .library(name: "AppTVOS", targets: ["AppTVOS"]),
        .executable(name: "DomusCam", targets: ["DomusCam"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ReolinkAPI",
            path: "Sources/ReolinkAPI",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "ReolinkStreaming",
            dependencies: ["ReolinkAPI"],
            path: "Sources/ReolinkStreaming",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "ReolinkBaichuan",
            dependencies: ["ReolinkAPI"],
            path: "Sources/ReolinkBaichuan",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.8.x — public API contract. Pure value types (resource
            // DTOs) + the `CameraAPI` protocol. Foundation-only, zero
            // dependencies, so it is the stable surface the app and
            // external consumers are both built on. The in-process
            // implementation (`LiveCameraAPI`) lives in AppShared; the
            // HTTP facade in DomusCamServer. See docs/api/.
            name: "DomusCamCore",
            path: "Sources/DomusCamCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // Cross-platform app domain layer shared by the macOS app and
            // the iPad/iPhone app: camera persistence, sessions, discovery,
            // notifications, downloads, Keychain. Anything that does NOT
            // require AppKit/UIKit lives here.
            name: "AppShared",
            // 0.5.1 — `AllRecordingsView` and the recording-row
            // helpers import `ReolinkStreaming` for `StreamURLs`.
            // Declared explicitly here so a clean build resolves
            // cleanly and the iOS Xcode build's dependency-scan
            // warning stops firing.
            dependencies: ["ReolinkAPI", "ReolinkStreaming", "ReolinkBaichuan", "DomusCamCore"],
            path: "Sources/AppShared",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.8.x — local HTTP facade. Hand-rolled HTTP/1.1 + SSE on
            // Network.framework (NWListener), preserving the package's
            // zero-dependency posture. Generic over `any CameraAPI`, so
            // it's exercised in tests against an in-memory fake with no
            // sockets and no cameras. See docs/api/.
            name: "DomusCamServer",
            dependencies: ["DomusCamCore"],
            path: "Sources/DomusCamServer",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.6.4 — Watch-app-facing library. Kept deliberately
            // thin: a slim Codable mirror of `CameraEntry` so the
            // watch can decode `cameras.json` from the App Group
            // container without compiling all of AppShared (which
            // pulls in SwiftUI views, AVFoundation playback, etc.).
            // The watch target consumes this product from Xcode and
            // adds its own minimal `@main` shell. See
            // `Sources/AppWatch/README.md` for setup steps.
            name: "AppWatch",
            dependencies: ["ReolinkAPI"],
            path: "Sources/AppWatch",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.7.0 — Apple TV viewer library. Thin like AppWatch, but
            // adds ReolinkStreaming because the TV does real RTSP live
            // view (the watch only shows snapshots). Never depends on
            // AppShared. The tvOS app target in DomusCamiOS.xcodeproj
            // consumes this product. See `Sources/AppTVOS/README.md`.
            name: "AppTVOS",
            dependencies: ["ReolinkAPI", "ReolinkStreaming"],
            path: "Sources/AppTVOS",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "DomusCam",
            dependencies: [
                "ReolinkAPI",
                "ReolinkStreaming",
                "ReolinkBaichuan",
                "AppShared",
                // 0.9.0 — macOS hosts the opt-in Local HTTP API (LocalAPIController).
                "DomusCamServer"
            ],
            path: "App",
            // 0.5.0 — Widgets/ is a separate WidgetKit app-extension
            // target built by Xcode, not by SPM. Excluding it from
            // the main DomusCam target keeps `swift build` clean and
            // prevents the @main collision between
            // `DomusCamApp` and `DomusCamWidgetsBundle`.
            // 0.7.0 — the Hub LaunchAgent plist is a build-time artifact
            // embedded into Contents/Library/LaunchAgents/ by
            // Scripts/build-app.sh, not an SPM source or resource.
            exclude: ["Info.plist", "DomusCam.entitlements", "DomusCam.dev.entitlements", "DomusCam.appstore.entitlements", "Widgets"],
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "ReolinkAPITests",
            dependencies: ["ReolinkAPI"],
            path: "Tests/ReolinkAPITests"
        ),
        .testTarget(
            name: "ReolinkStreamingTests",
            dependencies: ["ReolinkStreaming"],
            path: "Tests/ReolinkStreamingTests"
        ),
        .testTarget(
            name: "ReolinkBaichuanTests",
            dependencies: ["ReolinkBaichuan", "ReolinkAPI"],
            path: "Tests/ReolinkBaichuanTests"
        ),
        .testTarget(
            // 0.8.x — DomusCamCore contract round-trips. The DTOs are a
            // public wire format, so Codable encode→decode identity plus
            // stable JSON-key assertions pin the shape against
            // docs/api/openapi.yaml.
            name: "DomusCamCoreTests",
            dependencies: ["DomusCamCore"],
            path: "Tests/DomusCamCoreTests"
        ),
        .testTarget(
            // 0.8.x — HTTP facade routing/auth/SSE, exercised against an
            // in-memory fake `CameraAPI` plus a loopback end-to-end smoke
            // test on an ephemeral port.
            name: "DomusCamServerTests",
            dependencies: ["DomusCamServer", "DomusCamCore"],
            path: "Tests/DomusCamServerTests"
        ),
        // End-to-end integration test target. Drives the full
        // ReolinkAPI client through a mocked Reolink device using
        // URLProtocol — covers the path no unit test can: login →
        // token cache → batched commands → retry-on-loginRequired.
        .testTarget(
            name: "DomusCamE2ETests",
            dependencies: ["ReolinkAPI"],
            path: "Tests/DomusCamE2ETests"
        ),
        // AppShared privacy / sync semantics tests. The protocol
        // tests cover Reolink wire format; this target covers the
        // app's *differentiator* — Keychain sync, notification
        // routing, log redaction, preview-cache atomicity, and the
        // recording-downloader URL-leak prevention. AGENTS.md §12.
        .testTarget(
            name: "AppSharedTests",
            dependencies: ["AppShared", "ReolinkAPI"],
            path: "Tests/AppSharedTests"
        )
    ]
)

import CloudKit
import Foundation
import Testing
@testable import AppShared

/// Off-LAN defaults. Hub mode, motion relay, snapshot upload, and
/// Apple TV password sync are independent. Missing keys stay off
/// except the iOS subscriber, which is unchanged.
@MainActor
@Suite("Cloud relay privacy defaults")
struct CloudRelayPrivacyTests {
    private func defaults() -> UserDefaults {
        let name = "domuscam-cloud-relay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Enabling Hub does not write the CloudKit relay or snapshot keys")
    func hubDoesNotEnableRelayOrSnapshots() {
        let store = defaults()
        store.set(false, forKey: MotionEventRelaySettings.publisherEnabledKey)
        store.set(false, forKey: MotionEventRelaySettings.includeSnapshotsKey)
        let prefs = AppPreferences(defaults: store)

        prefs.setRunAsHub(true)

        #expect(prefs.runAsHub)
        #expect(!MotionEventRelaySettings.isPublisherEnabled(in: store))
        #expect(!MotionEventRelaySettings.areSnapshotsIncluded(in: store))
        let fresh = AppPreferences(defaults: store)
        #expect(fresh.runAsHub)
        #expect(!MotionEventRelaySettings.isPublisherEnabled(in: store))
    }

    @Test("Relay and snapshot upload default off and are independent")
    func relayAndSnapshotsDefaultOff() {
        let store = defaults()
        #expect(!MotionEventRelaySettings.isPublisherEnabled(in: store))
        #expect(!MotionEventRelaySettings.areSnapshotsIncluded(in: store))

        store.set(true, forKey: MotionEventRelaySettings.publisherEnabledKey)
        let url = URL(fileURLWithPath: "/tmp/domuscam-snap.jpg")
        #expect(MotionEventRelaySettings.snapshotURLForRelay(url, defaults: store) == nil)

        store.set(true, forKey: MotionEventRelaySettings.includeSnapshotsKey)
        #expect(MotionEventRelaySettings.snapshotURLForRelay(url, defaults: store) == url)
        #expect(MotionEventRelaySettings.snapshotURLForRelay(nil, defaults: store) == nil)
    }

    @Test("A motion record omits the snapshot asset unless a file URL is set")
    func recordOmitsSnapshotUnlessURLIsSet() throws {
        let bare = MotionEvent(
            cameraID: UUID(),
            channel: 1,
            detection: "people",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotFileURL: nil,
            cameraName: "Hall"
        )
        let bareRecord = bare.toRecord()
        #expect(bareRecord[MotionEvent.RecordKey.snapshot] == nil)
        #expect(bareRecord[MotionEvent.RecordKey.cameraName] as? String == "Hall")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("domuscam-relay-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let withImage = MotionEvent(
            cameraID: bare.cameraID,
            channel: 1,
            detection: "people",
            timestamp: bare.timestamp,
            snapshotFileURL: url,
            cameraName: "Hall"
        )
        #expect(withImage.toRecord()[MotionEvent.RecordKey.snapshot] != nil)
    }

    @Test("Apple TV password sync defaults off")
    func tvCredentialSyncDefaultsOff() {
        let store = defaults()
        #expect(!TVCredentialSync.isEnabled(in: store))
        store.set(true, forKey: TVCredentialSync.enabledKey)
        #expect(TVCredentialSync.isEnabled(in: store))
        store.set(false, forKey: TVCredentialSync.enabledKey)
        #expect(!TVCredentialSync.isEnabled(in: store))
    }
}

import SwiftUI

/// Settings section gating the macOS-side CloudKit motion relay.
/// Added in 0.4.1. AGENTS.md §5 — opt-in, off by default.
/// Relay and snapshot upload are separate switches. Run as Hub does
/// not turn either on. Each asks before the first enable.
public struct MotionRelayPublisherSection: View {
    @AppStorage(MotionEventRelaySettings.publisherEnabledKey) private var publisherEnabled: Bool = false
    @AppStorage(MotionEventRelaySettings.includeSnapshotsKey) private var includeSnapshots: Bool = false
    /// One alert for both opt-ins. Two `.alert` modifiers in the same
    /// section can swallow each other.
    @State private var pendingConsent: PendingConsent?
    @State private var sendingTestEvent: Bool = false
    @State private var testEventFeedback: String?

    public init() {}

    public var body: some View {
        let cloudKitAvailable = CloudKitAvailability.canUseCloudKit(
            containerID: "iCloud.com.75-c.DomusCam"
        )
        Section("Push notifications to iPhone / iPad") {
            Toggle("Relay motion events to my other Apple devices", isOn: Binding(
                get: { publisherEnabled },
                set: { newValue in
                    if newValue {
                        pendingConsent = .relay
                    } else {
                        publisherEnabled = false
                        // Image upload has nothing to attach to, and turning
                        // relay back on later must not resume it silently.
                        includeSnapshots = false
                    }
                }
            ))
            .disabled(!cloudKitAvailable)
            if cloudKitAvailable {
                Text("Off by default, and separate from Run as Hub. When on, this Mac sends motion events through your own iCloud account so DomusCam on iPhone or iPad can notify you. That includes the camera’s name, the kind of event, and the time. It does not include a picture unless you also turn on snapshot images below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only the event types you've enabled above are relayed — so a category you mute on this Mac (Motion is off by default) won't push to your other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include snapshot images", isOn: Binding(
                    get: { includeSnapshots },
                    set: { newValue in
                        if newValue {
                            pendingConsent = .snapshots
                        } else {
                            includeSnapshots = false
                        }
                    }
                ))
                .disabled(!publisherEnabled)
                if publisherEnabled && !includeSnapshots {
                    Text("Snapshot images stay on this Mac. They used to be included with every relayed event. Turn on “Include snapshot images” if you want that picture on your other devices — the image then leaves the house.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Off by default. A snapshot is a picture from the camera. Turning this on uploads that picture to your iCloud with each relayed event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Events ride through Apple's CloudKit under your own iCloud account. Apple throttles silent push delivery for free iCloud tiers, so busy cameras may not get every event. For round-the-clock listening, turn on DomusCam Hub (Settings → Background). Hub keeps the cameras connected; it does not turn this relay on.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    Task { await sendTestEvent() }
                } label: {
                    if sendingTestEvent {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                    } else {
                        Label("Send test event via CloudKit", systemImage: "paperplane")
                    }
                }
                .controlSize(.small)
                .disabled(sendingTestEvent || !publisherEnabled || !cloudKitAvailable)
                if let testEventFeedback {
                    Text(testEventFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("iCloud isn't available on this DomusCam build.", systemImage: "icloud.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text("Locally-built (./Scripts/build-app.sh) DomusCam uses slim entitlements that drop the iCloud container to keep AMFI happy. Run the DomusCamMac scheme in Xcode, or install the App Store / TestFlight build, to use the CloudKit motion-event relay. The toggle is disabled until iCloud is reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            consentTitle,
            isPresented: Binding(
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil } }
            ),
            presenting: pendingConsent
        ) { consent in
            switch consent {
            case .relay:
                Button("Relay events") { publisherEnabled = true }
            case .snapshots:
                Button("Include images") { includeSnapshots = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: { consent in
            switch consent {
            case .relay:
                Text("Camera names, event types, and times will leave this house and be stored in your private iCloud so your other Apple devices can show notifications. Snapshot images stay on this Mac unless you turn those on separately. There is no DomusCam server. You can turn this off at any time.")
            case .snapshots:
                Text("A still image from the camera will leave this house and be stored in your private iCloud with each relayed event. CloudKit does not end-to-end encrypt that image unless Advanced Data Protection is on for your iCloud account. You can turn this off at any time.")
            }
        }
    }

    private var consentTitle: String {
        switch pendingConsent {
        case .snapshots: "Upload snapshot images to iCloud?"
        case .relay, nil: "Send motion events to iCloud?"
        }
    }

    private enum PendingConsent: Identifiable {
        case relay
        case snapshots
        var id: Self { self }
    }

    /// Publishes a synthetic `MotionEvent` to CloudKit. The receiving
    /// iOS device fans this out through the same subscriber path as a
    /// real motion event, so it's a true end-to-end test of the relay
    /// pipeline — APNS registration on iOS, the CloudKit subscription,
    /// the publisher's account guard, and the receiver's local-
    /// notification compose path all participate. The detection string
    /// is set to "test" so the receiving device can render a distinct
    /// title.
    private func sendTestEvent() async {
        sendingTestEvent = true
        defer { sendingTestEvent = false }

        // Random cameraID per press so the rate-limiter never blocks a
        // legitimate test (it caps at 30 events / 10 min / camera).
        let event = MotionEvent(
            cameraID: UUID(),
            channel: 0,
            detection: "test",
            timestamp: Date(),
            cameraName: "Relay test"
        )
        let publisher = CloudKitMotionEventPublisher()
        await publisher.publish(event)

        // Read back the outcome from the diagnostics actor so the user
        // sees what happened immediately — much friendlier than
        // pointing them to the diagnostics screen.
        let snapshot = await RelayDiagnostics.shared.snapshot()
        if snapshot.lastPublisherSaveSucceeded == true {
            testEventFeedback = "Test event published. Open DomusCam on your iPhone or iPad within ~30 s to confirm the notification arrived."
        } else if let outcome = snapshot.lastPublisherSaveOutcome {
            testEventFeedback = "Publish reported: \(outcome). See the diagnostics row below for context."
        } else {
            testEventFeedback = "Publish attempted; check the diagnostics row below for the recorded outcome."
        }
    }
}

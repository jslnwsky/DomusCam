import SwiftUI

/// Form section that exposes the AGENTS.md §4 iCloud Keychain Sync
/// opt-in. Shared by the macOS and iOS Settings surfaces so the
/// migration semantics, copy, and confirmation flow stay identical on
/// both platforms.
///
/// The default behavior remains device-local — this section is a
/// gateway to opt in. Turning the toggle on copies every password onto
/// the iCloud Keychain side and, only after that write succeeds,
/// removes the device-local copy. Turning it off copies each password
/// into a device-local item and leaves the iCloud Keychain item in
/// place, because deleting it would remove the password on the user's
/// other devices. A failed write leaves the previous item alone.
public struct ICloudKeychainSyncSection: View {
    @Environment(CameraStore.self) private var store
    @State private var lastMigration: MigrationFeedback?

    public init() {}

    public var body: some View {
        Section("iCloud Keychain Sync") {
            Toggle("Sync camera passwords to iCloud Keychain", isOn: Binding(
                get: { store.iCloudKeychainSyncEnabled },
                set: { newValue in
                    // Flip the flag *first*, then migrate — the migration
                    // helper reads the flag indirectly via the `syncOn`
                    // argument, but downstream `Keychain.set` calls in the
                    // app rely on the flag matching at write time.
                    store.iCloudKeychainSyncEnabled = newValue
                    let result = store.migrateKeychainSync(toSync: newValue)
                    lastMigration = MigrationFeedback(
                        toSync: newValue,
                        migrated: result.migrated,
                        skipped: result.skipped,
                        failed: result.failed
                    )
                }
            ))
            Text(rationaleCopy)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let lastMigration {
                feedbackRow(for: lastMigration)
            }
            Text(reversibilityCopy)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var rationaleCopy: String {
        store.iCloudKeychainSyncEnabled
            ? "Your camera passwords sync to your other Apple devices through iCloud Keychain. DomusCam never sees your passwords — Apple encrypts them end-to-end."
            : "Off by default. Camera passwords stay on this device. Other Apple devices signed in to the same iCloud account see the camera list and have to re-enter the password locally."
    }

    private var reversibilityCopy: String {
        "Turning this off later only changes where new password edits are stored. Passwords already synced to iCloud Keychain stay there so your other devices keep working."
    }

    private func feedbackRow(for feedback: MigrationFeedback) -> some View {
        let symbol = feedback.failed > 0
            ? "exclamationmark.triangle"
            : (feedback.toSync ? "icloud.fill" : "lock.shield.fill")
        return Label(summary(for: feedback), systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private func summary(for feedback: MigrationFeedback) -> String {
        var parts: [String] = []
        if feedback.migrated == 0 && feedback.failed == 0 {
            parts.append("No saved camera passwords to update.")
        } else if feedback.toSync, feedback.migrated > 0 {
            let noun = feedback.migrated == 1 ? "password" : "passwords"
            parts.append("Copied \(feedback.migrated) \(noun) to iCloud Keychain.")
        } else if feedback.migrated > 0 {
            let noun = feedback.migrated == 1 ? "password" : "passwords"
            parts.append("Saved \(feedback.migrated) \(noun) on this device. Passwords already in iCloud Keychain were left there so your other devices keep working.")
        }
        if feedback.failed > 0 {
            let noun = feedback.failed == 1 ? "password" : "passwords"
            parts.append("\(feedback.failed) \(noun) could not be saved. The previous copies are still in the Keychain.")
        }
        return parts.joined(separator: " ")
    }

    private struct MigrationFeedback: Equatable {
        let toSync: Bool
        let migrated: Int
        let skipped: Int
        let failed: Int
    }
}

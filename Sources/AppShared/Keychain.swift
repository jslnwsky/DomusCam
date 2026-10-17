import Foundation
import Security
import os

/// Per-camera password storage. Backed by the system Keychain.
///
/// By default (AGENTS.md §4), items are written with
/// `kSecAttrSynchronizable: false` — passwords stay device-local.
/// Settings → Privacy → "Sync camera passwords to iCloud Keychain"
/// opts in. With sync on, new writes set the attribute to true so the
/// items replicate through iCloud Keychain.
///
/// Writes never delete an existing item before the replacement is
/// readable. The synchronizable flag is part of a generic-password
/// item's identity, so the local and iCloud copies can coexist for
/// the duration of a migration. Turning sync **off** copies the
/// password into a device-local item and leaves the synchronizable
/// item in place: deleting it would propagate through iCloud Keychain
/// and remove the password on the user's other devices.
///
/// Reads prefer the side that matches the current toggle, then fall
/// back to the other side, so a device that opted out still sees a
/// previously synced password when it has no local copy.
///
/// Logging (AGENTS.md §11): passwords are never logged. Account UUIDs
/// are `privacy: .private`. OSStatus codes and the sync flag are
/// `privacy: .public`.
package enum Keychain {
    package static let service = "com.75-c.DomusCam.cameraPassword"

    /// UserDefaults key for the user's iCloud Keychain opt-in. Default
    /// false — device-local — to preserve the AGENTS.md §4 default.
    package static let syncDefaultsKey = "com.75-c.DomusCam.iCloudKeychainSync"

    /// Set when a sync-on write had to fall back to a device-local item
    /// (typical of an ad-hoc build without the iCloud Keychain
    /// entitlement). While set, reads on this device prefer the local
    /// item so the password just saved isn't shadowed by an older
    /// synchronizable copy. Device-local; never written to iCloud.
    package static let syncFellBackToLocalKey = "com.75-c.DomusCam.iCloudKeychainSyncFellBackToLocal"

    /// Whether writes should mark new items as synchronizable. Reads the
    /// `UserDefaults` flag; absence ⇒ false.
    package static var syncEnabled: Bool {
        syncEnabled(in: .standard)
    }

    package static func syncEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: syncDefaultsKey)
    }

    /// Which side `password(for:)` consults first.
    ///
    /// Sync on, and the last sync write succeeded → synchronizable item.
    /// Sync off, or the last sync write fell back to local → local item.
    /// The other side is always the fallback, never a hard miss.
    package static func prefersSynchronizableItem(syncEnabled: Bool, fellBackToLocal: Bool) -> Bool {
        if fellBackToLocal { return false }
        return syncEnabled
    }

    @discardableResult
    package static func set(password: String, for id: UUID) -> Bool {
        set(password: password, for: id, defaults: .standard, backing: SystemKeychainBacking.shared)
    }

    /// Explicit form used by callers that already know the target side.
    /// Returns true only when that side reads back the new password.
    /// Does not delete the other side first.
    @discardableResult
    package static func set(password: String, for id: UUID, synchronized: Bool) -> Bool {
        set(password: password, for: id, synchronized: synchronized, backing: SystemKeychainBacking.shared)
    }

    @discardableResult
    package static func set(
        password: String,
        for id: UUID,
        defaults: UserDefaults,
        backing: any KeychainBacking
    ) -> Bool {
        // Try the user's chosen sync side first. If it fails because
        // the binary lacks the iCloud Keychain entitlement (common on
        // ad-hoc-signed `swift build` outputs), retry with sync off.
        // The local-only side has no entitlement requirement. The
        // synchronizable item, if one already exists, is left alone —
        // deleting it would wipe the password on the user's other devices.
        let preferred = syncEnabled(in: defaults)
        if writePassword(password, for: id, synchronized: preferred, backing: backing) {
            defaults.set(false, forKey: syncFellBackToLocalKey)
            return true
        }
        if preferred {
            log.warning("Keychain set with synchronized=true failed; retrying synchronized=false (likely a dev / ad-hoc signing build missing the iCloud entitlement)")
            if writePassword(password, for: id, synchronized: false, backing: backing) {
                defaults.set(true, forKey: syncFellBackToLocalKey)
                return true
            }
        }
        return false
    }

    @discardableResult
    package static func set(
        password: String,
        for id: UUID,
        synchronized: Bool,
        backing: any KeychainBacking
    ) -> Bool {
        writePassword(password, for: id, synchronized: synchronized, backing: backing)
    }

    package static func password(for id: UUID) -> String? {
        password(for: id, defaults: .standard, backing: SystemKeychainBacking.shared)
    }

    package static func password(
        for id: UUID,
        defaults: UserDefaults,
        backing: any KeychainBacking
    ) -> String? {
        let preferSync = prefersSynchronizableItem(
            syncEnabled: syncEnabled(in: defaults),
            fellBackToLocal: defaults.bool(forKey: syncFellBackToLocalKey)
        )
        return password(for: id, preferSynchronizable: preferSync, backing: backing)
    }

    package static func deletePassword(for id: UUID) {
        // Explicit removal (the user deleted the camera). Matches both
        // sides. This is not the migration path: a synchronizable delete
        // here is intentional and does propagate to other devices.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Re-save each known password on `syncOn`'s side.
    ///
    /// - Turning **on** copies onto the synchronizable item, and only
    ///   then deletes the device-local item (that item was never synced,
    ///   so removing it cannot reach other devices).
    /// - Turning **off** copies onto a device-local item and leaves the
    ///   synchronizable item in place.
    ///
    /// A failed write does not delete anything and is counted in
    /// `failed`. Skipped means this device had no password for that
    /// camera. Never throws.
    @discardableResult
    package static func migrate(
        accounts: [UUID],
        toSync syncOn: Bool,
        defaults: UserDefaults = .standard,
        backing: any KeychainBacking = SystemKeychainBacking.shared
    ) -> MigrationResult {
        var migrated = 0
        var skipped = 0
        var failed = 0
        for id in accounts {
            // Prefer the device-local copy when both sides exist. The
            // settings toggle flips the UserDefaults flag *before*
            // calling migrate, so "whichever side the flag names" would
            // read a stale synchronizable item and ignore a newer local
            // edit. Local-then-synchronizable is the password this
            // device is actually using.
            guard let existing = password(for: id, preferSynchronizable: false, backing: backing) else {
                skipped += 1
                continue
            }
            if writePassword(existing, for: id, synchronized: syncOn, backing: backing) {
                migrated += 1
            } else {
                failed += 1
                log.error("Keychain migration write failed toSync=\(syncOn, privacy: .public) account=\(id.uuidString, privacy: .private); existing item left unchanged")
            }
        }
        if failed == 0 {
            defaults.set(false, forKey: syncFellBackToLocalKey)
        }
        log.info("Keychain migration toSync=\(syncOn, privacy: .public) migrated=\(migrated, privacy: .public) skipped=\(skipped, privacy: .public) failed=\(failed, privacy: .public)")
        return MigrationResult(migrated: migrated, skipped: skipped, failed: failed)
    }

    package struct MigrationResult: Sendable, Equatable {
        package let migrated: Int
        package let skipped: Int
        package let failed: Int
    }

    /// Update-or-add on `synchronized`'s side. On success, a sync-on
    /// write deletes the device-local copy. A sync-off write does not
    /// delete the synchronizable copy.
    private static func writePassword(
        _ password: String,
        for id: UUID,
        synchronized: Bool,
        backing: any KeychainBacking
    ) -> Bool {
        guard let data = password.data(using: .utf8) else {
            log.error("Keychain write skipped: password was not UTF-8")
            return false
        }
        let account = id.uuidString
        switch backing.write(account: account, data: data, synchronized: synchronized) {
        case .stored:
            if synchronized {
                switch backing.delete(account: account, synchronized: false) {
                case .stored:
                    break
                case .failed(let status):
                    // The synchronizable item is already stored. Leaving
                    // the local copy is safe; losing it is not an option
                    // we have, because we are not going to roll the
                    // successful write back.
                    log.error("Keychain local-copy delete failed after synced write status=\(status, privacy: .public) account=\(account, privacy: .private)")
                }
            }
            return true
        case .failed(let status):
            log.error("Keychain write failed status=\(status, privacy: .public) sync=\(synchronized, privacy: .public) account=\(account, privacy: .private); existing item left unchanged")
            return false
        }
    }

    /// `preferSynchronizable == false` reads local, then synchronizable.
    private static func password(
        for id: UUID,
        preferSynchronizable: Bool,
        backing: any KeychainBacking
    ) -> String? {
        let account = id.uuidString
        let first = preferSynchronizable
        let data = backing.read(account: account, synchronized: first)
            ?? backing.read(account: account, synchronized: !first)
        guard let data, let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static let log = Logger(subsystem: "com.75-c.DomusCam", category: "Keychain")
}

package enum KeychainWriteOutcome: Equatable, Sendable {
    case stored
    case failed(status: Int32)
}

/// Primitive Keychain operations. Production uses
/// `SystemKeychainBacking`; tests inject an in-memory fake so a failed
/// write can be observed without touching the login keychain.
package protocol KeychainBacking: Sendable {
    func read(account: String, synchronized: Bool) -> Data?
    func write(account: String, data: Data, synchronized: Bool) -> KeychainWriteOutcome
    func delete(account: String, synchronized: Bool) -> KeychainWriteOutcome
}

package struct SystemKeychainBacking: KeychainBacking, Sendable {
    package static let shared = SystemKeychainBacking()

    private static let log = Logger(subsystem: "com.75-c.DomusCam", category: "Keychain")

    package func read(account: String, synchronized: Bool) -> Data? {
        var query = attributes(account: account, synchronized: synchronized)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    package func write(account: String, data: Data, synchronized: Bool) -> KeychainWriteOutcome {
        let base = attributes(account: account, synchronized: synchronized)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return verified(data, account: account, synchronized: synchronized, status: updateStatus)
        case errSecItemNotFound:
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retry = SecItemUpdate(base as CFDictionary, update as CFDictionary)
                guard retry == errSecSuccess else {
                    Self.log.error("SecItemUpdate after duplicate failed status=\(retry, privacy: .public) sync=\(synchronized, privacy: .public)")
                    return .failed(status: retry)
                }
                return verified(data, account: account, synchronized: synchronized, status: retry)
            }
            guard addStatus == errSecSuccess else {
                Self.log.error("SecItemAdd failed status=\(addStatus, privacy: .public) sync=\(synchronized, privacy: .public)")
                return .failed(status: addStatus)
            }
            return verified(data, account: account, synchronized: synchronized, status: addStatus)
        default:
            Self.log.error("SecItemUpdate failed status=\(updateStatus, privacy: .public) sync=\(synchronized, privacy: .public)")
            return .failed(status: updateStatus)
        }
    }

    package func delete(account: String, synchronized: Bool) -> KeychainWriteOutcome {
        let status = SecItemDelete(attributes(account: account, synchronized: synchronized) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .stored
        }
        Self.log.error("SecItemDelete failed status=\(status, privacy: .public) sync=\(synchronized, privacy: .public)")
        return .failed(status: status)
    }

    private func verified(
        _ data: Data,
        account: String,
        synchronized: Bool,
        status: OSStatus
    ) -> KeychainWriteOutcome {
        if read(account: account, synchronized: synchronized) == data {
            return .stored
        }
        Self.log.error("Keychain read-back mismatch status=\(status, privacy: .public) sync=\(synchronized, privacy: .public)")
        return .failed(status: status)
    }

    private func attributes(account: String, synchronized: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronized ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
    }
}

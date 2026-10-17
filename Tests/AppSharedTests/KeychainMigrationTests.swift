import Foundation
import Testing
@testable import AppShared

/// In-memory `KeychainBacking` so migration tests can fail a write
/// without the system Keychain. Records every write and delete so a
/// regression that deletes before a successful write fails the test.
private final class MemoryKeychain: KeychainBacking, @unchecked Sendable {
    struct Op: Equatable {
        enum Kind: Equatable { case write, delete }
        let kind: Kind
        let synchronized: Bool
        let outcome: KeychainWriteOutcome
    }

    private let lock = NSLock()
    private var items: [String: [Bool: Data]] = [:]
    private var ops: [Op] = []
    var failAllWrites = false
    var failSynchronizedWrites = false

    func seed(account: String, synchronized: Bool, password: String) {
        lock.lock()
        defer { lock.unlock() }
        items[account, default: [:]][synchronized] = Data(password.utf8)
    }

    func password(account: String, synchronized: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = items[account]?[synchronized] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func operations() -> [Op] {
        lock.lock()
        defer { lock.unlock() }
        return ops
    }

    func read(account: String, synchronized: Bool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]?[synchronized]
    }

    func write(account: String, data: Data, synchronized: Bool) -> KeychainWriteOutcome {
        lock.lock()
        defer { lock.unlock() }
        if failAllWrites || (failSynchronizedWrites && synchronized) {
            let outcome = KeychainWriteOutcome.failed(status: -1)
            ops.append(Op(kind: .write, synchronized: synchronized, outcome: outcome))
            return outcome
        }
        items[account, default: [:]][synchronized] = data
        let outcome = KeychainWriteOutcome.stored
        ops.append(Op(kind: .write, synchronized: synchronized, outcome: outcome))
        return outcome
    }

    func delete(account: String, synchronized: Bool) -> KeychainWriteOutcome {
        lock.lock()
        defer { lock.unlock() }
        items[account]?[synchronized] = nil
        let outcome = KeychainWriteOutcome.stored
        ops.append(Op(kind: .delete, synchronized: synchronized, outcome: outcome))
        return outcome
    }
}

@Suite("Keychain migration")
struct KeychainMigrationTests {
    private func defaults() -> UserDefaults {
        let name = "domuscam-keychain-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A failed sync-on migration does not delete the existing password or count as migrated")
    func failedWriteLeavesExistingItem() {
        let id = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: false, password: "secret")
        backing.failAllWrites = true

        let result = Keychain.migrate(accounts: [id], toSync: true, defaults: defaults(), backing: backing)

        #expect(result.migrated == 0)
        #expect(result.failed == 1)
        #expect(result.skipped == 0)
        #expect(backing.password(account: id.uuidString, synchronized: false) == "secret")
        #expect(backing.password(account: id.uuidString, synchronized: true) == nil)
        let ops = backing.operations()
        #expect(ops.contains { $0.kind == .write && $0.outcome != .stored })
        #expect(!ops.contains { $0.kind == .delete })
    }

    @Test("Turning sync on writes the synchronizable item before deleting the local one")
    func syncOnWritesBeforeDelete() {
        let id = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: false, password: "secret")

        let result = Keychain.migrate(accounts: [id], toSync: true, defaults: defaults(), backing: backing)

        #expect(result == Keychain.MigrationResult(migrated: 1, skipped: 0, failed: 0))
        #expect(backing.password(account: id.uuidString, synchronized: true) == "secret")
        #expect(backing.password(account: id.uuidString, synchronized: false) == nil)
        let ops = backing.operations()
        let writeIndex = ops.firstIndex { $0.kind == .write && $0.synchronized && $0.outcome == .stored }
        let deleteIndex = ops.firstIndex { $0.kind == .delete && !$0.synchronized }
        #expect(writeIndex != nil)
        #expect(deleteIndex != nil)
        #expect(writeIndex! < deleteIndex!)
        #expect(!ops.contains { $0.kind == .delete && $0.synchronized })
    }

    @Test("Turning sync off keeps the synchronizable item")
    func syncOffDoesNotDeleteSyncedItem() {
        let id = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: true, password: "secret")

        let result = Keychain.migrate(accounts: [id], toSync: false, defaults: defaults(), backing: backing)

        #expect(result.migrated == 1)
        #expect(result.failed == 0)
        #expect(backing.password(account: id.uuidString, synchronized: false) == "secret")
        #expect(backing.password(account: id.uuidString, synchronized: true) == "secret")
        #expect(!backing.operations().contains { $0.kind == .delete })
    }

    @Test("A failed sync-off write does not remove the synchronizable password")
    func failedSyncOffLeavesSyncedItem() {
        let id = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: true, password: "secret")
        backing.failAllWrites = true

        let result = Keychain.migrate(accounts: [id], toSync: false, defaults: defaults(), backing: backing)

        #expect(result.migrated == 0)
        #expect(result.failed == 1)
        #expect(backing.password(account: id.uuidString, synchronized: true) == "secret")
        #expect(!backing.operations().contains { $0.kind == .delete })
    }

    @Test("One account's failed write does not drop a later account")
    func failureDoesNotAbortTheLoop() {
        let first = UUID()
        let second = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: first.uuidString, synchronized: false, password: "one")
        backing.seed(account: second.uuidString, synchronized: false, password: "two")

        // The first synchronizable write fails. Migration must continue
        // with the next account and must not delete the first password.
        let once = FailFirstWrite(inner: backing)
        let result = Keychain.migrate(accounts: [first, second], toSync: true, defaults: defaults(), backing: once)

        #expect(result.migrated == 1)
        #expect(result.failed == 1)
        #expect(once.password(account: first.uuidString, synchronized: false) == "one")
        #expect(once.password(account: second.uuidString, synchronized: true) == "two")
        #expect(once.password(account: second.uuidString, synchronized: false) == nil)
    }

    @Test("An empty account list does not write or delete")
    func emptyListIsANoOp() {
        let backing = MemoryKeychain()
        let result = Keychain.migrate(accounts: [], toSync: true, defaults: defaults(), backing: backing)
        #expect(result == Keychain.MigrationResult(migrated: 0, skipped: 0, failed: 0))
        #expect(backing.operations().isEmpty)
    }

    @Test("A missing password is skipped and not deleted")
    func missingPasswordIsSkipped() {
        let backing = MemoryKeychain()
        let result = Keychain.migrate(accounts: [UUID()], toSync: true, defaults: defaults(), backing: backing)
        #expect(result.skipped == 1)
        #expect(result.migrated == 0)
        #expect(result.failed == 0)
        #expect(!backing.operations().contains { $0.kind == .delete || $0.kind == .write })
    }

    @Test("A failed explicit write does not delete the existing item")
    func setFailureDoesNotDelete() {
        let id = UUID()
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: false, password: "secret")
        backing.failAllWrites = true

        let saved = Keychain.set(password: "new", for: id, synchronized: true, backing: backing)

        #expect(!saved)
        #expect(backing.password(account: id.uuidString, synchronized: false) == "secret")
        #expect(!backing.operations().contains { $0.kind == .delete })
    }

    @Test("Sync-on save that falls back to local keeps the synchronizable item and reads the new password")
    func fallbackDoesNotDeleteSyncedItem() {
        let id = UUID()
        let prefs = defaults()
        prefs.set(true, forKey: Keychain.syncDefaultsKey)
        let backing = MemoryKeychain()
        backing.seed(account: id.uuidString, synchronized: true, password: "old")
        backing.failSynchronizedWrites = true

        let saved = Keychain.set(password: "new", for: id, defaults: prefs, backing: backing)

        #expect(saved)
        #expect(backing.password(account: id.uuidString, synchronized: true) == "old")
        #expect(backing.password(account: id.uuidString, synchronized: false) == "new")
        #expect(Keychain.password(for: id, defaults: prefs, backing: backing) == "new")
        #expect(!backing.operations().contains { $0.kind == .delete && $0.synchronized })
    }

    @Test("Read preference follows the toggle, then the fallback flag")
    func readPreference() {
        #expect(Keychain.prefersSynchronizableItem(syncEnabled: false, fellBackToLocal: false) == false)
        #expect(Keychain.prefersSynchronizableItem(syncEnabled: true, fellBackToLocal: false) == true)
        #expect(Keychain.prefersSynchronizableItem(syncEnabled: true, fellBackToLocal: true) == false)
    }
}

/// Fails the first `write` and forwards everything else. Used to prove
/// a failed account does not abort migration of the next one, and that
/// the failed account's existing item is not deleted.
private final class FailFirstWrite: KeychainBacking, @unchecked Sendable {
    private let inner: MemoryKeychain
    private let lock = NSLock()
    private var remainingFailures = 1

    init(inner: MemoryKeychain) {
        self.inner = inner
    }

    func password(account: String, synchronized: Bool) -> String? {
        inner.password(account: account, synchronized: synchronized)
    }

    func read(account: String, synchronized: Bool) -> Data? {
        inner.read(account: account, synchronized: synchronized)
    }

    func write(account: String, data: Data, synchronized: Bool) -> KeychainWriteOutcome {
        lock.lock()
        let fail = remainingFailures > 0
        if fail { remainingFailures -= 1 }
        lock.unlock()
        if fail { return .failed(status: -1) }
        return inner.write(account: account, data: data, synchronized: synchronized)
    }

    func delete(account: String, synchronized: Bool) -> KeychainWriteOutcome {
        inner.delete(account: account, synchronized: synchronized)
    }
}

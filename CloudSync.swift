import CloudKit
import Foundation

extension CKRecord {
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func fromSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}

/// Sincronizzazione con il database CloudKit PRIVATO dell'utente tramite CKSyncEngine.
/// In CloudKit viaggiano solo: blob AES-256-GCM, data di modifica e il "key wrap"
/// (chiave dati cifrata con la chiave di recupero). Mai testo in chiaro.
final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    private weak var store: VaultStore?
    private var engine: CKSyncEngine?
    private let stateURL: URL
    private let zoneID = CKRecordZone.ID(zoneName: "MySafeZone", ownerName: CKCurrentUserDefaultName)

    private var container: CKContainer { CKContainer.default() }
    private var database: CKDatabase { container.privateCloudDatabase }

    init(store: VaultStore, directory: URL) {
        self.store = store
        self.stateURL = directory.appendingPathComponent("syncstate.json")
    }

    func start() {
        var saved: CKSyncEngine.State.Serialization?
        if let data = try? Data(contentsOf: stateURL) {
            saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        var configuration = CKSyncEngine.Configuration(
            database: database, stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    func enqueueSave(_ id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: id))])
    }

    func enqueueDelete(_ id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(for: id))])
    }

    func syncNow() async {
        try? await engine?.fetchChanges()
        try? await engine?.sendChanges()
    }

    private func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    func accountStatusText() async -> String {
        switch try? await container.accountStatus() {
        case .available: return "Active"
        case .noAccount: return "Sign in to iCloud in iPhone Settings"
        case .restricted: return "Restricted by device settings"
        default: return "Unavailable"
        }
    }

    // MARK: - Chiave di recupero (key wrap)

    private let wrapRecordID = CKRecord.ID(recordName: "recovery-wrap")

    func uploadKeyWrap(_ wrap: KeyWrap) async throws {
        let record: CKRecord
        do {
            record = try await database.record(for: wrapRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "KeyWrap", recordID: wrapRecordID)
        }
        record["salt"] = wrap.salt as CKRecordValue
        record["sealed"] = wrap.sealed as CKRecordValue
        try await database.save(record)
    }

    func fetchKeyWrap() async throws -> KeyWrap? {
        do {
            let record = try await database.record(for: wrapRecordID)
            guard let salt = record["salt"] as? Data, let sealed = record["sealed"] as? Data else { return nil }
            return KeyWrap(salt: salt, sealed: sealed)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }

        case .accountChange(let change):
            if case .signIn = change.changeType {
                let ids = await store?.prepareFullUpload() ?? []
                let changes = ids.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0)) }
                syncEngine.state.add(pendingRecordZoneChanges: changes)
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                await store?.applyRemote(modification.record)
            }
            for deletion in changes.deletions {
                await store?.applyRemoteDeletion(deletion.recordID)
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                await store?.updateSystemFields(saved)
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord,
                       let localWins = await store?.resolveConflict(server: server), localWins {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    }
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    await store?.clearSystemFields(id)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                default:
                    break // rete assente ecc.: il motore riprova da solo
                }
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            let record = await self?.store?.makeRecord(recordID: recordID)
            if record == nil {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
            return record
        }
    }
}

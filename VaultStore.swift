import CloudKit
import CryptoKit
import Foundation

enum Config {
    /// Metti `false` se non hai un account Apple Developer a pagamento
    /// (iCloud/CloudKit non è disponibile con l'account gratuito).
    static let cloudEnabled = true
}

enum VaultError: LocalizedError {
    case locked, keyMissing, invalidRecoveryKey, wrapNotFound, wrongRecoveryKey

    var errorDescription: String? {
        switch self {
        case .locked: return "The vault is locked."
        case .keyMissing: return "Key not found on this device. Use your recovery key."
        case .invalidRecoveryKey: return "The recovery key isn't valid. Check the characters you entered."
        case .wrapNotFound: return "No recovery key found in iCloud. Make sure you're signed in to iCloud."
        case .wrongRecoveryKey: return "That recovery key isn't correct."
        }
    }
}

/// Archivio cifrato. Su disco e in iCloud finiscono SOLO blob AES-256-GCM.
/// Nessuna stampa nei log: nessuna funzione qui usa print/os_log.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var credentials: [Credential] = []
    @Published private(set) var undecryptableCount = 0

    private var records: [UUID: StoredRecord] = [:]
    private var dataKey: SymmetricKey?
    private(set) var cloud: CloudSync?

    private static let keyAccount = "dataKey"
    private static let wrapUploadedKey = "wrapUploaded"
    private let directory: URL
    private var vaultURL: URL { directory.appendingPathComponent("vault.json") }
    private var wrapURL: URL { directory.appendingPathComponent("keywrap.json") }

    var hasKey: Bool { KeychainStore.load(account: Self.keyAccount) != nil }
    var iCloudEnabled: Bool { cloud != nil }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MySafe", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        loadRecords()
        if Config.cloudEnabled {
            let sync = CloudSync(store: self, directory: directory)
            cloud = sync
            sync.start()
        }
    }

    // MARK: - Creazione / ripristino / blocco

    /// Crea un nuovo archivio e restituisce la chiave di recupero da mostrare UNA volta.
    func createVault() throws -> String {
        let key = CryptoService.newKey()
        try KeychainStore.save(key.rawData, account: Self.keyAccount)
        dataKey = key
        let recovery = CryptoService.newRecoveryKey()
        try storeWrap(for: key, recovery: recovery)
        refresh()
        return RecoveryKeyFormat.display(recovery)
    }

    func restore(recoveryInput: String) async throws {
        guard let recovery = Base32.decode(recoveryInput), recovery.count == 32 else {
            throw VaultError.invalidRecoveryKey
        }
        var candidates: [KeyWrap] = []
        if let remote = try? await cloud?.fetchKeyWrap() { candidates.append(remote) }
        if let local = localWrap() { candidates.append(local) }
        guard !candidates.isEmpty else { throw VaultError.wrapNotFound }

        for wrap in candidates {
            if let key = try? CryptoService.unwrap(wrap, recoveryKey: recovery) {
                try KeychainStore.save(key.rawData, account: Self.keyAccount)
                dataKey = key
                try? JSONEncoder().encode(wrap).write(
                    to: wrapURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                UserDefaults.standard.set(true, forKey: Self.wrapUploadedKey)
                refresh()
                await cloud?.syncNow()
                return
            }
        }
        throw VaultError.wrongRecoveryKey
    }

    func unlock() throws {
        guard let raw = KeychainStore.load(account: Self.keyAccount) else { throw VaultError.keyMissing }
        dataKey = SymmetricKey(data: raw)
        refresh()
        Task { await uploadWrapIfNeeded() }
    }

    /// Dimentica la chiave e svuota ogni dato in chiaro dalla memoria.
    func lock() {
        dataKey = nil
        credentials = []
        undecryptableCount = 0
    }

    func rotateRecoveryKey() throws -> String {
        guard let key = dataKey else { throw VaultError.locked }
        let recovery = CryptoService.newRecoveryKey()
        try storeWrap(for: key, recovery: recovery)
        return RecoveryKeyFormat.display(recovery)
    }

    // MARK: - CRUD

    func save(_ credential: Credential) throws {
        guard let key = dataKey else { throw VaultError.locked }
        let blob = try encrypt(credential, key: key)
        var record = records[credential.id]
            ?? StoredRecord(id: credential.id, blob: blob, modified: Date(), systemFields: nil)
        record.blob = blob
        record.modified = Date()
        records[credential.id] = record
        try persist()
        refresh()
        cloud?.enqueueSave(credential.id)
    }

    func delete(id: UUID) throws {
        records[id] = nil
        try persist()
        refresh()
        cloud?.enqueueDelete(id)
    }

    func discardUndecryptable() {
        guard let key = dataKey else { return }
        let bad = records.values.filter { (try? decrypt($0, key: key)) == nil }.map(\.id)
        for id in bad {
            records[id] = nil
            cloud?.enqueueDelete(id)
        }
        try? persist()
        refresh()
    }

    // MARK: - Cifratura / decifratura

    private func aad(for id: UUID) -> Data { Data(id.uuidString.utf8) }

    private func encrypt(_ c: Credential, key: SymmetricKey) throws -> Data {
        let payload = CredentialPayload(organization: c.organization, user: c.user, password: c.password)
        let plain = try JSONEncoder().encode(payload)
        return try CryptoService.seal(plain, key: key, aad: aad(for: c.id))
    }

    private func decrypt(_ r: StoredRecord, key: SymmetricKey) throws -> Credential {
        let plain = try CryptoService.open(r.blob, key: key, aad: aad(for: r.id))
        let p = try JSONDecoder().decode(CredentialPayload.self, from: plain)
        return Credential(id: r.id, organization: p.organization, user: p.user, password: p.password)
    }

    private func refresh() {
        guard let key = dataKey else {
            credentials = []
            return
        }
        var list: [Credential] = []
        var bad = 0
        for record in records.values {
            if let c = try? decrypt(record, key: key) { list.append(c) } else { bad += 1 }
        }
        credentials = list.sorted {
            let order = $0.organization.localizedCaseInsensitiveCompare($1.organization)
            if order == .orderedSame { return $0.user.localizedCaseInsensitiveCompare($1.user) == .orderedAscending }
            return order == .orderedAscending
        }
        undecryptableCount = bad
    }

    // MARK: - Disco

    private func loadRecords() {
        guard let data = try? Data(contentsOf: vaultURL),
              let list = try? JSONDecoder().decode([StoredRecord].self, from: data) else { return }
        records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Array(records.values))
        try data.write(to: vaultURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Chiave di recupero (wrap)

    private func localWrap() -> KeyWrap? {
        guard let data = try? Data(contentsOf: wrapURL) else { return nil }
        return try? JSONDecoder().decode(KeyWrap.self, from: data)
    }

    private func storeWrap(for key: SymmetricKey, recovery: Data) throws {
        let wrap = try CryptoService.wrap(dataKey: key, recoveryKey: recovery)
        try JSONEncoder().encode(wrap).write(
            to: wrapURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        UserDefaults.standard.set(false, forKey: Self.wrapUploadedKey)
        Task { await uploadWrapIfNeeded() }
    }

    func uploadWrapIfNeeded() async {
        guard let cloud,
              !UserDefaults.standard.bool(forKey: Self.wrapUploadedKey),
              let wrap = localWrap() else { return }
        do {
            try await cloud.uploadKeyWrap(wrap)
            UserDefaults.standard.set(true, forKey: Self.wrapUploadedKey)
        } catch {
            // Riproverà al prossimo sblocco. Nessun dettaglio nei log.
        }
    }

    // MARK: - Interfaccia verso CloudSync (solo dati cifrati)

    func makeRecord(recordID: CKRecord.ID) -> CKRecord? {
        guard let id = UUID(uuidString: recordID.recordName), let stored = records[id] else { return nil }
        let record: CKRecord
        if let fields = stored.systemFields, let restored = CKRecord.fromSystemFields(fields) {
            record = restored
        } else {
            record = CKRecord(recordType: "Credential", recordID: recordID)
        }
        record["blob"] = stored.blob as CKRecordValue
        record["modified"] = stored.modified as CKRecordValue
        return record
    }

    func applyRemote(_ record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let blob = record["blob"] as? Data else { return }
        let modified = record["modified"] as? Date ?? Date()
        records[id] = StoredRecord(id: id, blob: blob, modified: modified, systemFields: record.encodedSystemFields)
        try? persist()
        refresh()
    }

    func applyRemoteDeletion(_ recordID: CKRecord.ID) {
        guard let id = UUID(uuidString: recordID.recordName) else { return }
        records[id] = nil
        try? persist()
        refresh()
    }

    func updateSystemFields(_ record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName), var stored = records[id] else { return }
        stored.systemFields = record.encodedSystemFields
        records[id] = stored
        try? persist()
    }

    func clearSystemFields(_ recordID: CKRecord.ID) {
        guard let id = UUID(uuidString: recordID.recordName), var stored = records[id] else { return }
        stored.systemFields = nil
        records[id] = stored
        try? persist()
    }

    /// Ultima modifica vince. Ritorna true se la versione locale è più recente e va rinviata.
    func resolveConflict(server: CKRecord) -> Bool {
        guard let id = UUID(uuidString: server.recordID.recordName), var local = records[id] else {
            applyRemote(server)
            return false
        }
        let serverDate = server["modified"] as? Date ?? .distantPast
        if local.modified > serverDate {
            local.systemFields = server.encodedSystemFields
            records[id] = local
            try? persist()
            return true
        }
        applyRemote(server)
        return false
    }

    func prepareFullUpload() -> [UUID] {
        for id in records.keys { records[id]?.systemFields = nil }
        try? persist()
        return Array(records.keys)
    }
}

import Foundation

/// Registrazione in chiaro: esiste SOLO in memoria mentre l'app è sbloccata.
/// Contiene esclusivamente le tre informazioni richieste (+ id tecnico locale).
struct Credential: Identifiable, Hashable {
    var id: UUID
    var organization: String
    var user: String
    var password: String

    init(id: UUID = UUID(), organization: String = "", user: String = "", password: String = "") {
        self.id = id
        self.organization = organization
        self.user = user
        self.password = password
    }
}

/// Contenuto che viene cifrato con AES-256-GCM.
struct CredentialPayload: Codable {
    var organization: String
    var user: String
    var password: String
}

/// Registrazione come salvata su disco e in CloudKit: solo testo cifrato.
struct StoredRecord: Codable, Identifiable {
    var id: UUID
    var blob: Data            // AES-GCM combined (nonce + ciphertext + tag)
    var modified: Date        // serve solo a risolvere i conflitti di sincronizzazione
    var systemFields: Data?   // metadati CloudKit (nessun dato utente)
}

/// Chiave dati cifrata con la chiave di recupero (mai la chiave in chiaro).
struct KeyWrap: Codable {
    var salt: Data
    var sealed: Data
}

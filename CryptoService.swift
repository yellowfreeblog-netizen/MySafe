import CryptoKit
import Foundation

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

enum CryptoError: Error {
    case invalidData
}

/// Cifratura AES-256-GCM (CryptoKit). Il nonce è casuale e diverso per ogni cifratura.
/// L'id della registrazione è usato come "dati autenticati aggiuntivi" (AAD):
/// un blob cifrato non può essere spostato su un'altra registrazione senza essere rilevato.
enum CryptoService {
    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw CryptoError.invalidData }
        return combined
    }

    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Chiave di recupero

    /// 256 bit casuali, mostrati all'utente una sola volta e MAI salvati.
    static func newRecoveryKey() -> Data { SymmetricKey(size: .bits256).rawData }

    private static let wrapAAD = Data("MySafe.keywrap.v1".utf8)

    private static func derive(_ recoveryKey: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey),
            salt: salt,
            info: Data("MySafe.recovery.v1".utf8),
            outputByteCount: 32
        )
    }

    static func wrap(dataKey: SymmetricKey, recoveryKey: Data) throws -> KeyWrap {
        let salt = SymmetricKey(size: .bits128).rawData
        let wrapKey = derive(recoveryKey, salt: salt)
        let sealed = try seal(dataKey.rawData, key: wrapKey, aad: wrapAAD)
        return KeyWrap(salt: salt, sealed: sealed)
    }

    static func unwrap(_ wrap: KeyWrap, recoveryKey: Data) throws -> SymmetricKey {
        let wrapKey = derive(recoveryKey, salt: wrap.salt)
        let raw = try open(wrap.sealed, key: wrapKey, aad: wrapAAD)
        guard raw.count == 32 else { throw CryptoError.invalidData }
        return SymmetricKey(data: raw)
    }
}

// MARK: - Formato leggibile della chiave di recupero (Base32, 52 caratteri)

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func decode(_ string: String) -> Data? {
        var out = Data()
        var buffer = 0
        var bits = 0
        for ch in string.uppercased() where !ch.isWhitespace && ch != "-" {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        return out
    }
}

enum RecoveryKeyFormat {
    static func display(_ key: Data) -> String {
        let text = Base32.encode(key)
        var groups: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            groups.append(String(text[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }
}

import CryptoKit
import Foundation

public enum RuntimeIntegrityDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let value = String(byte, radix: 16, uppercase: false)
            return value.count == 1 ? "0\(value)" : value
        }.joined()
    }
}

enum RuntimeBundledResourceIntegrity {
    static func matchesSHA256(_ expectedSHA256: Data, data: Data) -> Bool {
        guard expectedSHA256.count == SHA256.Digest.byteCount else { return false }
        return Data(SHA256.hash(data: data)) == expectedSHA256
    }
}

struct RuntimeOperationContextAuthenticator: Sendable {
    private let key: SymmetricKey

    init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    static func randomKeyData() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    func authenticationCode(for data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    func isValidAuthenticationCode(_ code: Data, for data: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: data,
            using: key
        )
    }
}

enum RuntimeCryptographicDigest {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

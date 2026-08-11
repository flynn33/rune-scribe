import CryptoKit
import Foundation

enum RuntimeBundledResourceIntegrity {
    static func matchesSHA256(_ expectedSHA256: Data, data: Data) -> Bool {
        guard expectedSHA256.count == SHA256.Digest.byteCount else { return false }
        return Data(SHA256.hash(data: data)) == expectedSHA256
    }
}

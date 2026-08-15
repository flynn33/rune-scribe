import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ProgressionTokenServiceError: Error, Equatable, Sendable {
    case entropyUnavailable
    case invalidSeedLength
    case invalidStoredSecret
    case secureStorageUnavailable
    case tokenConstructionFailed
}

protocol ProgressionTokenEntropyProviding: Sendable {
    func randomBytes(count: Int) throws -> Data
}

struct SystemProgressionTokenEntropy: ProgressionTokenEntropyProviding {
    func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        return SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

/// Core-owned derivation for the opaque tokens admitted to progression events.
/// The two device secrets are isolated from the application's content-encryption
/// and lock records even though access to all of them is mediated by Runtime.
actor ProgressionTokenService {
    private static let secretByteCount = 32
    private static let keychainService = "com.runescribe.progression-token"
    private static let progressionSecretAccount = "progression-token-secret-v1"
    private static let relationshipSecretAccount = "device-relationship-secret-v1"

    private static let cipherDomain = "runescribe.cipher.v1"
    private static let messageDomain = "runescribe.message.v1"
    private static let packageDomain = "runescribe.package.v1"
    private static let relationshipDomain = "runescribe.relationship.v1"

    private let runtimeIO: RuntimeIOClient
    private let entropy: any ProgressionTokenEntropyProviding

    private var cachedProgressionSecret: Data?
    private var progressionSecretTask: Task<Data, Error>?
    private var cachedRelationshipSecret: Data?
    private var relationshipSecretTask: Task<Data, Error>?

    init(
        runtimeIO: RuntimeIOClient,
        entropy: any ProgressionTokenEntropyProviding = SystemProgressionTokenEntropy()
    ) {
        self.runtimeIO = runtimeIO
        self.entropy = entropy
    }

    /// Creates the randomized value persisted with one cipher-library entry.
    func makeCipherSeed() throws -> Data {
        try makeSeed()
    }

    /// The same persisted seed always maps to the same device-local cipher token.
    func cipherToken(for seed: Data) async throws -> CipherToken {
        try Self.validateSeed(seed)
        let secret = try await progressionSecret()
        guard let token = CipherToken(
            rawValue: Self.hmacHex(domain: Self.cipherDomain, material: seed, key: secret)
        ) else {
            throw ProgressionTokenServiceError.tokenConstructionFailed
        }
        return token
    }

    /// Creates one fresh token for a new logical encode operation. Its caller
    /// retains the returned value through prepare and terminal share completion.
    func makeMessageToken() async throws -> MessageToken {
        let seed = try makeSeed()
        let secret = try await progressionSecret()
        guard let token = MessageToken(
            rawValue: Self.hmacHex(domain: Self.messageDomain, material: seed, key: secret)
        ) else {
            throw ProgressionTokenServiceError.tokenConstructionFailed
        }
        return token
    }

    /// Derives a device-local one-way token only after package bytes are admitted.
    func packageToken(for admittedPackageBytes: Data) async throws -> PackageToken {
        let secret = try await progressionSecret()
        guard let token = PackageToken(
            rawValue: Self.hmacHex(
                domain: Self.packageDomain,
                material: admittedPackageBytes,
                key: secret
            )
        ) else {
            throw ProgressionTokenServiceError.tokenConstructionFailed
        }
        return token
    }

    /// Creates the random value persisted encrypted with one Core relationship.
    func makeRelationshipSeed() throws -> Data {
        try makeSeed()
    }

    /// Implements ADR-RS-009 exactly: HMAC-SHA256 of the relationship domain
    /// concatenated directly with the persisted 256-bit seed.
    func relationshipToken(for seed: Data) async throws -> RelationshipToken {
        try Self.validateSeed(seed)
        let secret = try await relationshipSecret()
        guard let token = RelationshipToken(
            rawValue: Self.hmacHex(
                domain: Self.relationshipDomain,
                material: seed,
                key: secret
            )
        ) else {
            throw ProgressionTokenServiceError.tokenConstructionFailed
        }
        return token
    }

    private func makeSeed() throws -> Data {
        let seed: Data
        do {
            seed = try entropy.randomBytes(count: Self.secretByteCount)
        } catch {
            throw ProgressionTokenServiceError.entropyUnavailable
        }
        guard seed.count == Self.secretByteCount else {
            throw ProgressionTokenServiceError.entropyUnavailable
        }
        return seed
    }

    private func progressionSecret() async throws -> Data {
        if let cachedProgressionSecret {
            return cachedProgressionSecret
        }
        if let progressionSecretTask {
            return try await progressionSecretTask.value
        }

        let task = Self.secretTask(
            runtimeIO: runtimeIO,
            entropy: entropy,
            account: Self.progressionSecretAccount
        )
        progressionSecretTask = task
        do {
            let secret = try await task.value
            cachedProgressionSecret = secret
            progressionSecretTask = nil
            return secret
        } catch {
            progressionSecretTask = nil
            throw error
        }
    }

    private func relationshipSecret() async throws -> Data {
        if let cachedRelationshipSecret {
            return cachedRelationshipSecret
        }
        if let relationshipSecretTask {
            return try await relationshipSecretTask.value
        }

        let task = Self.secretTask(
            runtimeIO: runtimeIO,
            entropy: entropy,
            account: Self.relationshipSecretAccount
        )
        relationshipSecretTask = task
        do {
            let secret = try await task.value
            cachedRelationshipSecret = secret
            relationshipSecretTask = nil
            return secret
        } catch {
            relationshipSecretTask = nil
            throw error
        }
    }

    private static func secretTask(
        runtimeIO: RuntimeIOClient,
        entropy: any ProgressionTokenEntropyProviding,
        account: String
    ) -> Task<Data, Error> {
        Task {
            let existing: Data?
            do {
                existing = try await runtimeIO.secureValueData(
                    service: keychainService,
                    account: account
                )
            } catch {
                throw ProgressionTokenServiceError.secureStorageUnavailable
            }

            if let existing {
                guard existing.count == secretByteCount else {
                    throw ProgressionTokenServiceError.invalidStoredSecret
                }
                return existing
            }

            let candidate: Data
            do {
                candidate = try entropy.randomBytes(count: secretByteCount)
            } catch {
                throw ProgressionTokenServiceError.entropyUnavailable
            }
            guard candidate.count == secretByteCount else {
                throw ProgressionTokenServiceError.entropyUnavailable
            }

            do {
                try await runtimeIO.setSecureValue(
                    candidate,
                    service: keychainService,
                    account: account
                )
                let persisted = try await runtimeIO.secureValueData(
                    service: keychainService,
                    account: account
                )
                guard persisted == candidate else {
                    throw ProgressionTokenServiceError.secureStorageUnavailable
                }
            } catch let error as ProgressionTokenServiceError {
                throw error
            } catch {
                throw ProgressionTokenServiceError.secureStorageUnavailable
            }
            return candidate
        }
    }

    private static func validateSeed(_ seed: Data) throws {
        guard seed.count == secretByteCount else {
            throw ProgressionTokenServiceError.invalidSeedLength
        }
    }

    private static func hmacHex(domain: String, material: Data, key: Data) -> String {
        var authenticatedData = Data(domain.utf8)
        authenticatedData.append(material)
        let authenticationCode = Array(
            HMAC<SHA256>.authenticationCode(
                for: authenticatedData,
                using: SymmetricKey(data: key)
            )
        )
        let hexadecimal = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(authenticationCode.count * 2)
        for byte in authenticationCode {
            result.append(hexadecimal[Int(byte >> 4)])
            result.append(hexadecimal[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }
}

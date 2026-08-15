import Foundation
import os
import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

final class ProgressionTokenServiceTests: XCTestCase {
    private static let progressionAddress = RecordingTokenStore.Address(
        service: "com.runescribe.progression-token",
        account: "progression-token-secret-v1"
    )
    private static let relationshipAddress = RecordingTokenStore.Address(
        service: "com.runescribe.progression-token",
        account: "device-relationship-secret-v1"
    )

    func testFixedGoldenVectorsAreDomainSeparatedLowercaseAndRedacted() async throws {
        let progressionSecret = Data(0x00 ... 0x1f)
        let relationshipSecret = Data(0x20 ... 0x3f)
        let material = Data(0x40 ... 0x5f)
        let store = RecordingTokenStore(values: [
            Self.progressionAddress: progressionSecret,
            Self.relationshipAddress: relationshipSecret,
        ])
        let entropy = RecordingTokenEntropy(responses: [material, material, material])
        let service = ProgressionTokenService(store: store, entropy: entropy)

        let cipherSeed = try await service.makeCipherSeed()
        let relationshipSeed = try await service.makeRelationshipSeed()
        let cipherToken = try await service.cipherToken(for: cipherSeed)
        let messageToken = try await service.makeMessageToken()
        let packageToken = try await service.packageToken(for: material)
        let relationshipToken = try await service.relationshipToken(for: relationshipSeed)

        XCTAssertEqual(cipherSeed, material)
        XCTAssertEqual(relationshipSeed, material)
        XCTAssertEqual(
            cipherToken.rawValue,
            "7700e3eb39b13b3b4bdb9fb14dc994b0304d3a8cd2482017eb8ca16c16b3af4e"
        )
        XCTAssertEqual(
            messageToken.rawValue,
            "8d2da0e327e435ea2b140497e516b0cb8b723b917820a553cf210bd256b6ed59"
        )
        XCTAssertEqual(
            packageToken.rawValue,
            "9e621335404b6748d47b432fc45226e4e31744631cd073db9939d873a2c638ab"
        )
        XCTAssertEqual(
            relationshipToken.rawValue,
            "c875a9535393531cf71b4618fd08e22cb5ec6ef175ff852513694916a011ca04"
        )

        let rawValues = [
            cipherToken.rawValue,
            messageToken.rawValue,
            packageToken.rawValue,
            relationshipToken.rawValue,
        ]
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
        for rawValue in rawValues {
            XCTAssertNotNil(
                rawValue.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression)
            )
        }
        XCTAssertEqual(cipherToken.description, "<redacted-token>")
        XCTAssertEqual(messageToken.description, "<redacted-token>")
        XCTAssertEqual(packageToken.description, "<redacted-token>")
        XCTAssertEqual(relationshipToken.description, "<redacted-token>")
        XCTAssertEqual(entropy.recordedCounts(), [32, 32, 32])

        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations,
            [.read(Self.progressionAddress), .read(Self.relationshipAddress)]
        )
    }

    func testSeedAndPerEncodeMessageCreationUseFreshIndependentEntropy() async throws {
        let progressionSecret = Data(repeating: 0xa5, count: 32)
        let generatedValues = (1 ... 6).map { Data(repeating: UInt8($0), count: 32) }
        let store = RecordingTokenStore(values: [
            Self.progressionAddress: progressionSecret,
        ])
        let entropy = RecordingTokenEntropy(responses: generatedValues)
        let service = ProgressionTokenService(store: store, entropy: entropy)

        let firstCipherSeed = try await service.makeCipherSeed()
        let secondCipherSeed = try await service.makeCipherSeed()
        let firstRelationshipSeed = try await service.makeRelationshipSeed()
        let secondRelationshipSeed = try await service.makeRelationshipSeed()
        let firstMessageToken = try await service.makeMessageToken()
        let secondMessageToken = try await service.makeMessageToken()

        XCTAssertEqual(firstCipherSeed.count, 32)
        XCTAssertEqual(firstRelationshipSeed.count, 32)
        XCTAssertNotEqual(firstCipherSeed, secondCipherSeed)
        XCTAssertNotEqual(firstRelationshipSeed, secondRelationshipSeed)
        XCTAssertNotEqual(firstMessageToken, secondMessageToken)
        XCTAssertEqual(entropy.recordedCounts(), Array(repeating: 32, count: 6))
        let operations = await store.recordedOperations()
        XCTAssertEqual(operations, [.read(Self.progressionAddress)])
    }

    func testConcurrentInitializationWritesEachIndependentSecretOnce() async throws {
        let material = Data(repeating: 0x7c, count: 32)
        let entropy = RecordingTokenEntropy(responses: [
            Data(repeating: 0x11, count: 32),
            Data(repeating: 0x22, count: 32),
        ])
        let store = RecordingTokenStore()
        let service = ProgressionTokenService(store: store, entropy: entropy)

        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        let token = try await service.packageToken(for: material)
                        return "package:\(token.rawValue)"
                    }
                    let token = try await service.relationshipToken(for: material)
                    return "relationship:\(token.rawValue)"
                }
            }

            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        let packageOutputs = outputs.filter { $0.hasPrefix("package:") }
        let relationshipOutputs = outputs.filter { $0.hasPrefix("relationship:") }
        XCTAssertEqual(outputs.count, 64)
        XCTAssertEqual(Set(packageOutputs).count, 1)
        XCTAssertEqual(Set(relationshipOutputs).count, 1)
        XCTAssertEqual(entropy.recordedCounts(), [32, 32])
        let persistedProgressionSecret = await store.value(at: Self.progressionAddress)
        let persistedRelationshipSecret = await store.value(at: Self.relationshipAddress)
        XCTAssertEqual(persistedProgressionSecret?.count, 32)
        XCTAssertEqual(persistedRelationshipSecret?.count, 32)
        XCTAssertNotEqual(persistedProgressionSecret, persistedRelationshipSecret)

        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations.filter { $0.address == Self.progressionAddress },
            [
                .read(Self.progressionAddress),
                .write(Self.progressionAddress),
                .read(Self.progressionAddress),
            ]
        )
        XCTAssertEqual(
            operations.filter { $0.address == Self.relationshipAddress },
            [
                .read(Self.relationshipAddress),
                .write(Self.relationshipAddress),
                .read(Self.relationshipAddress),
            ]
        )
    }

    func testRelaunchReadsPersistedSecretsAndProducesStableTokens() async throws {
        let material = Data(repeating: 0x6d, count: 32)
        let firstEntropy = RecordingTokenEntropy(responses: [
            Data(repeating: 0x31, count: 32),
            Data(repeating: 0x42, count: 32),
        ])
        let store = RecordingTokenStore()
        let firstService = ProgressionTokenService(store: store, entropy: firstEntropy)

        let firstCipher = try await firstService.cipherToken(for: material)
        let firstRelationship = try await firstService.relationshipToken(for: material)
        let firstOperations = await store.recordedOperations()
        XCTAssertEqual(
            firstOperations,
            [
                .read(Self.progressionAddress),
                .write(Self.progressionAddress),
                .read(Self.progressionAddress),
                .read(Self.relationshipAddress),
                .write(Self.relationshipAddress),
                .read(Self.relationshipAddress),
            ]
        )
        XCTAssertEqual(firstEntropy.recordedCounts(), [32, 32])

        await store.clearOperations()
        let relaunchEntropy = RecordingTokenEntropy(responses: [])
        let relaunchedService = ProgressionTokenService(
            store: store,
            entropy: relaunchEntropy
        )
        let relaunchedCipher = try await relaunchedService.cipherToken(for: material)
        let relaunchedRelationship = try await relaunchedService.relationshipToken(for: material)

        XCTAssertEqual(relaunchedCipher, firstCipher)
        XCTAssertEqual(relaunchedRelationship, firstRelationship)
        XCTAssertEqual(relaunchEntropy.recordedCounts(), [])
        let relaunchOperations = await store.recordedOperations()
        XCTAssertEqual(
            relaunchOperations,
            [.read(Self.progressionAddress), .read(Self.relationshipAddress)]
        )
    }

    func testWrongLengthProgressionSecretFailsClosedWithoutEntropyOrWrite() async throws {
        let store = RecordingTokenStore(values: [
            Self.progressionAddress: Data(repeating: 0x01, count: 31),
        ])
        let entropy = RecordingTokenEntropy(responses: [])
        let service = ProgressionTokenService(store: store, entropy: entropy)

        do {
            _ = try await service.packageToken(for: Data())
            XCTFail("Expected the invalid stored secret to be rejected.")
        } catch let error as ProgressionTokenServiceError {
            XCTAssertEqual(error, .invalidStoredSecret)
        }

        XCTAssertEqual(entropy.recordedCounts(), [])
        let operations = await store.recordedOperations()
        XCTAssertEqual(operations, [.read(Self.progressionAddress)])
    }

    func testWrongLengthRelationshipSecretFailsClosedWithoutEntropyOrWrite() async throws {
        let store = RecordingTokenStore(values: [
            Self.relationshipAddress: Data(repeating: 0x02, count: 33),
        ])
        let entropy = RecordingTokenEntropy(responses: [])
        let service = ProgressionTokenService(store: store, entropy: entropy)

        do {
            _ = try await service.relationshipToken(for: Data(repeating: 0x03, count: 32))
            XCTFail("Expected the invalid stored secret to be rejected.")
        } catch let error as ProgressionTokenServiceError {
            XCTAssertEqual(error, .invalidStoredSecret)
        }

        XCTAssertEqual(entropy.recordedCounts(), [])
        let operations = await store.recordedOperations()
        XCTAssertEqual(operations, [.read(Self.relationshipAddress)])
    }

    func testWrongLengthSeedsFailBeforeSecretAccess() async throws {
        let store = RecordingTokenStore()
        let entropy = RecordingTokenEntropy(responses: [])
        let service = ProgressionTokenService(store: store, entropy: entropy)

        do {
            _ = try await service.cipherToken(for: Data(repeating: 0x04, count: 31))
            XCTFail("Expected the short cipher seed to be rejected.")
        } catch let error as ProgressionTokenServiceError {
            XCTAssertEqual(error, .invalidSeedLength)
        }
        do {
            _ = try await service.relationshipToken(for: Data(repeating: 0x05, count: 33))
            XCTFail("Expected the long relationship seed to be rejected.")
        } catch let error as ProgressionTokenServiceError {
            XCTAssertEqual(error, .invalidSeedLength)
        }

        XCTAssertEqual(entropy.recordedCounts(), [])
        let operations = await store.recordedOperations()
        XCTAssertEqual(operations, [])
    }

    func testTokenSecretsNeverReuseApplicationKeychainOrIdentityInputs() async throws {
        let legacyAddresses = [
            RecordingTokenStore.Address(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.symmetricKeyAccount
            ),
            RecordingTokenStore.Address(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.cipherLibraryAccount
            ),
            RecordingTokenStore.Address(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            ),
            RecordingTokenStore.Address(
                service: RuneScribeKeychain.service,
                account: "publicCipherIdentifier"
            ),
            RecordingTokenStore.Address(
                service: RuneScribeKeychain.service,
                account: "contactIdentifier"
            ),
        ]
        let legacyValues = Dictionary(
            uniqueKeysWithValues: legacyAddresses.enumerated().map { index, address in
                (address, Data(repeating: UInt8(0x80 + index), count: 32))
            }
        )
        let store = RecordingTokenStore(values: legacyValues)
        let entropy = RecordingTokenEntropy(responses: [
            Data(repeating: 0x51, count: 32),
            Data(repeating: 0x62, count: 32),
            Data(repeating: 0x73, count: 32),
        ])
        let service = ProgressionTokenService(store: store, entropy: entropy)
        let material = Data(repeating: 0x19, count: 32)

        _ = try await service.cipherToken(for: material)
        _ = try await service.relationshipToken(for: material)
        _ = try await service.packageToken(for: material)
        _ = try await service.makeMessageToken()

        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                .read(Self.progressionAddress),
                .write(Self.progressionAddress),
                .read(Self.progressionAddress),
                .read(Self.relationshipAddress),
                .write(Self.relationshipAddress),
                .read(Self.relationshipAddress),
            ]
        )
        XCTAssertEqual(entropy.recordedCounts(), [32, 32, 32])
        for address in legacyAddresses {
            let storedValue = await store.value(at: address)
            XCTAssertEqual(storedValue, legacyValues[address])
        }
    }
}

private extension ProgressionTokenService {
    init(
        store: RecordingTokenStore,
        entropy: any ProgressionTokenEntropyProviding
    ) {
        self.init(
            runtimeIO: RuntimeIOClient(
                secureValueData: {
                    await store.data(service: $0, account: $1)
                },
                setSecureValue: {
                    await store.set($0, service: $1, account: $2)
                }
            ),
            entropy: entropy
        )
    }
}

private actor RecordingTokenStore {
    struct Address: Hashable, Sendable {
        let service: String
        let account: String
    }

    enum Operation: Equatable, Sendable {
        case read(Address)
        case write(Address)

        var address: Address {
            switch self {
            case let .read(address), let .write(address):
                address
            }
        }
    }

    private var values: [Address: Data]
    private var operations: [Operation] = []

    init(values: [Address: Data] = [:]) {
        self.values = values
    }

    func data(service: String, account: String) -> Data? {
        let address = Address(service: service, account: account)
        operations.append(.read(address))
        return values[address]
    }

    func set(_ data: Data, service: String, account: String) {
        let address = Address(service: service, account: account)
        operations.append(.write(address))
        values[address] = data
    }

    func value(at address: Address) -> Data? {
        values[address]
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func clearOperations() {
        operations.removeAll(keepingCapacity: true)
    }
}

private final class RecordingTokenEntropy: @unchecked Sendable,
    ProgressionTokenEntropyProviding
{
    private struct State {
        var responses: [Data]
        var nextResponse = 0
        var counts: [Int] = []
    }

    private struct Exhausted: Error {}

    private let state: OSAllocatedUnfairLock<State>

    init(responses: [Data]) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
    }

    func randomBytes(count: Int) throws -> Data {
        try state.withLock { state in
            state.counts.append(count)
            guard state.nextResponse < state.responses.count else {
                throw Exhausted()
            }
            defer { state.nextResponse += 1 }
            return state.responses[state.nextResponse]
        }
    }

    func recordedCounts() -> [Int] {
        state.withLock { $0.counts }
    }
}

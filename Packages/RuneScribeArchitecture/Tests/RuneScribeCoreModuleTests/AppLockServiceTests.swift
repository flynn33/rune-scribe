import Foundation
import os
import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

final class AppLockServiceTests: XCTestCase {
    private static let pinAddress = RecordingSecureValueStore.Address(
        service: RuneScribeKeychain.service,
        account: RuneScribeKeychain.appPINAccount
    )
    private static let throttleAddress = RecordingSecureValueStore.Address(
        service: RuneScribeKeychain.service,
        account: RuneScribeKeychain.pinThrottleAccount
    )

    private static let legacyPINRecord = Data(
        #"{"version":1,"iterations":120000,"salt":"AAECAwQFBgcICQoLDA0ODw==","hash":"UHAyHKNNva/pslNx0cD4O8r+Bz+64fInTwCm1saOmJk="}"#.utf8
    )

    func testGoldenPBKDF2VectorMatchesShippingBytes() {
        let salt = Data((0...15).map(UInt8.init))
        let expected = Data([
            0x50, 0x70, 0x32, 0x1c, 0xa3, 0x4d, 0xbd, 0xaf,
            0xe9, 0xb2, 0x53, 0x71, 0xd1, 0xc0, 0xf8, 0x3b,
            0xca, 0xfe, 0x07, 0x3f, 0xba, 0xe1, 0xf2, 0x27,
            0x4f, 0x00, 0xa6, 0xd6, 0xc6, 0x8e, 0x98, 0x99,
        ])

        XCTAssertEqual(
            AppLockService.deriveHash(pin: "1234", salt: salt, iterations: 120_000),
            expected
        )
    }

    func testSeededLegacyPINAndThrottleRestoreColdLockedState() async throws {
        let lastFailure = Date(timeIntervalSinceReferenceDate: 770_976_550)
        let expectedRetryAfter = lastFailure.addingTimeInterval(15)
        let throttle = Data(
            #"{"failedAttempts":5,"lastFailure":770976550}"#.utf8
        )
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
            Self.throttleAddress: throttle,
        ])
        let clock = MutableClock(lastFailure.addingTimeInterval(1))
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        let state = try await service.state()

        XCTAssertTrue(state.isPINSet)
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.retryAfter, expectedRetryAfter)
        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations,
            [.read(Self.pinAddress), .read(Self.throttleAddress)]
        )
    }

    func testFifthFailureLocksUntilCooldownAndSuccessfulUnlockClearsThrottle() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
        ])
        let clock = MutableClock(now)
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        _ = try await service.state()

        for _ in 1...4 {
            let result = try await service.unlock(PINInput("0000"))
            XCTAssertEqual(result, .incorrect)
        }

        let retryAfter = now.addingTimeInterval(15)
        let fifth = try await service.unlock(PINInput("0000"))
        XCTAssertEqual(fifth, .lockedOut(retryAfter: retryAfter))

        let persistedValue = await store.value(at: Self.throttleAddress)
        let persisted = try XCTUnwrap(persistedValue)
        let persistedThrottle = try JSONDecoder().decode(FrozenThrottleState.self, from: persisted)
        XCTAssertEqual(persistedThrottle.failedAttempts, 5)
        XCTAssertEqual(persistedThrottle.lastFailure, now)

        let operationCountBeforeLockedAttempt = await store.recordedOperations().count
        let stillLocked = try await service.unlock(PINInput("1234"))
        XCTAssertEqual(stillLocked, .lockedOut(retryAfter: retryAfter))
        let operationCountAfterLockedAttempt = await store.recordedOperations().count
        XCTAssertEqual(operationCountAfterLockedAttempt, operationCountBeforeLockedAttempt)

        clock.advance(by: 15)
        let unlocked = try await service.unlock(PINInput("1234"))
        XCTAssertEqual(unlocked, .unlocked)
        let clearedThrottle = await store.value(at: Self.throttleAddress)
        XCTAssertNil(clearedThrottle)

        let state = try await service.state()
        XCTAssertTrue(state.isPINSet)
        XCTAssertFalse(state.isLocked)
        XCTAssertNil(state.retryAfter)
    }

    func testManagementAttemptsShareUnlockThrottleAndSuccessfulProbeResetsFailures() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
        ])
        let clock = MutableClock(now)
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        _ = try await service.state()

        let firstManagementAttempt = try await service.verifyForManagement(PINInput("0000"))
        XCTAssertFalse(firstManagementAttempt)
        do {
            try await service.changePIN(
                current: PINInput("0000"),
                replacement: PINInput("5678")
            )
            XCTFail("An incorrect current PIN must fail")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .incorrectPIN)
        }
        do {
            try await service.disablePIN(current: PINInput("0000"))
            XCTFail("An incorrect current PIN must fail")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .incorrectPIN)
        }
        let fourthAttempt = try await service.unlock(PINInput("0000"))
        XCTAssertEqual(fourthAttempt, .incorrect)
        let fifthAttempt = try await service.verifyForManagement(PINInput("0000"))
        XCTAssertFalse(fifthAttempt)

        let retryAfter = now.addingTimeInterval(15)
        let lockedUnlock = try await service.unlock(PINInput("1234"))
        XCTAssertEqual(
            lockedUnlock,
            .lockedOut(retryAfter: retryAfter)
        )
        let lockedManagement = try await service.verifyForManagement(PINInput("1234"))
        XCTAssertFalse(lockedManagement)

        let persistedValue = await store.value(at: Self.throttleAddress)
        let persisted = try XCTUnwrap(persistedValue)
        let lockedThrottle = try JSONDecoder().decode(FrozenThrottleState.self, from: persisted)
        XCTAssertEqual(lockedThrottle.failedAttempts, 5)
        XCTAssertEqual(lockedThrottle.lastFailure, now)

        clock.advance(by: 15)
        let successfulManagement = try await service.verifyForManagement(PINInput("1234"))
        XCTAssertTrue(successfulManagement)
        let clearedThrottle = await store.value(at: Self.throttleAddress)
        XCTAssertNil(clearedThrottle)
        let state = try await service.state()
        XCTAssertTrue(state.isLocked)
        XCTAssertNil(state.retryAfter)
    }

    func testSuccessfulChangeAndDisableResetPriorManagementFailures() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let seededThrottle = Data(
            #"{"failedAttempts":4,"lastFailure":800000000}"#.utf8
        )
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
            Self.throttleAddress: seededThrottle,
        ])
        let service = AppLockService(
            secureValueStore: store,
            clock: MutableClock(now),
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        try await service.changePIN(
            current: PINInput("1234"),
            replacement: PINInput("5678")
        )
        let changeClearedThrottle = await store.value(at: Self.throttleAddress)
        XCTAssertNil(changeClearedThrottle)

        let failedManagement = try await service.verifyForManagement(PINInput("0000"))
        XCTAssertFalse(failedManagement)
        let failedValue = await store.value(at: Self.throttleAddress)
        let failed = try XCTUnwrap(failedValue)
        let failedThrottle = try JSONDecoder().decode(FrozenThrottleState.self, from: failed)
        XCTAssertEqual(failedThrottle.failedAttempts, 1)

        try await service.disablePIN(current: PINInput("5678"))
        let disableClearedThrottle = await store.value(at: Self.throttleAddress)
        let deletedPIN = await store.value(at: Self.pinAddress)
        XCTAssertNil(disableClearedThrottle)
        XCTAssertNil(deletedPIN)
    }

    func testSetChangeDisableUseStableAccountsAndRecordSchema() async throws {
        let salt = Data(0...15)
        let store = RecordingSecureValueStore()
        let service = AppLockService(
            secureValueStore: store,
            clock: MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000)),
            entropy: FixedPINEntropy(bytes: salt)
        )

        try await service.setPIN(PINInput("1234"))

        let setOperations = await store.recordedOperations()
        XCTAssertEqual(
            setOperations,
            [
                .read(Self.pinAddress),
                .read(Self.throttleAddress),
                .write(Self.pinAddress),
                .delete(Self.throttleAddress),
            ]
        )
        let initialValue = await store.value(at: Self.pinAddress)
        let initialData = try XCTUnwrap(initialValue)
        let initialRecord = try JSONDecoder().decode(FrozenPINRecord.self, from: initialData)
        XCTAssertEqual(initialRecord.version, 1)
        XCTAssertEqual(initialRecord.iterations, 120_000)
        XCTAssertEqual(initialRecord.salt, salt)
        XCTAssertEqual(
            initialRecord.hash,
            AppLockService.deriveHash(pin: "1234", salt: salt, iterations: 120_000)
        )

        await store.clearOperations()
        try await service.changePIN(
            current: PINInput("1234"),
            replacement: PINInput("5678")
        )

        let changeOperations = await store.recordedOperations()
        XCTAssertEqual(
            changeOperations,
            [
                .read(Self.pinAddress),
                .write(Self.pinAddress),
                .delete(Self.throttleAddress),
            ]
        )
        let changedValue = await store.value(at: Self.pinAddress)
        let changedData = try XCTUnwrap(changedValue)
        let changedRecord = try JSONDecoder().decode(FrozenPINRecord.self, from: changedData)
        XCTAssertEqual(changedRecord.version, 1)
        XCTAssertEqual(changedRecord.iterations, 120_000)
        XCTAssertEqual(changedRecord.salt, salt)
        XCTAssertEqual(
            changedRecord.hash,
            AppLockService.deriveHash(pin: "5678", salt: salt, iterations: 120_000)
        )

        await store.clearOperations()
        try await service.disablePIN(current: PINInput("5678"))

        let disableOperations = await store.recordedOperations()
        XCTAssertEqual(
            disableOperations,
            [
                .read(Self.pinAddress),
                .delete(Self.throttleAddress),
                .delete(Self.pinAddress),
            ]
        )
        let deletedPIN = await store.value(at: Self.pinAddress)
        let deletedThrottle = await store.value(at: Self.throttleAddress)
        XCTAssertNil(deletedPIN)
        XCTAssertNil(deletedThrottle)
        let finalState = try await service.state()
        XCTAssertFalse(finalState.isPINSet)
        XCTAssertFalse(finalState.isLocked)
        XCTAssertNil(finalState.retryAfter)
    }

    func testCorruptPINRecordFailsClosedAndAccumulatesThrottle() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let corruptRecord = Data(
            #"{"version":1,"iterations":120000,"salt":"","hash":""}"#.utf8
        )
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: corruptRecord,
        ])
        let service = AppLockService(
            secureValueStore: store,
            clock: MutableClock(now),
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        let coldState = try await service.state()
        XCTAssertTrue(coldState.isPINSet)
        XCTAssertTrue(coldState.isLocked)

        let result = try await service.unlock(PINInput("1234"))
        XCTAssertEqual(result, .incorrect)
        let retainedCorruptRecord = await store.value(at: Self.pinAddress)
        XCTAssertEqual(retainedCorruptRecord, corruptRecord)

        let throttleValue = await store.value(at: Self.throttleAddress)
        let throttleData = try XCTUnwrap(throttleValue)
        let throttle = try JSONDecoder().decode(FrozenThrottleState.self, from: throttleData)
        XCTAssertEqual(throttle.failedAttempts, 1)
        XCTAssertEqual(throttle.lastFailure, now)
        let finalState = try await service.state()
        XCTAssertTrue(finalState.isLocked)
    }

    func testUnlockDeleteFailureRemainsLockedAndReconstructionRetainsThrottle() async throws {
        let throttle = Data(
            #"{"failedAttempts":1,"lastFailure":800000000}"#.utf8
        )
        let store = RecordingSecureValueStore(
            values: [
                Self.pinAddress: Self.legacyPINRecord,
                Self.throttleAddress: throttle,
            ],
            deleteFailures: [Self.throttleAddress: 1]
        )
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_001))
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        do {
            _ = try await service.unlock(PINInput("1234"))
            XCTFail("A failed durable throttle delete must not unlock")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .secureStorageUnavailable)
        }
        let failedState = try await service.state()
        XCTAssertTrue(failedState.isLocked)
        let retainedThrottle = await store.value(at: Self.throttleAddress)
        XCTAssertEqual(retainedThrottle, throttle)

        let reconstructed = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        let coldState = try await reconstructed.state()
        XCTAssertTrue(coldState.isPINSet)
        XCTAssertTrue(coldState.isLocked)
        let result = try await reconstructed.unlock(PINInput("1234"))
        XCTAssertEqual(result, .unlocked)
    }

    func testSetDeleteFailurePersistsNewPINButNeverReportsUnlocked() async throws {
        let store = RecordingSecureValueStore(
            deleteFailures: [Self.throttleAddress: 1]
        )
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        do {
            try await service.setPIN(PINInput("1234"))
            XCTFail("A failed durable throttle delete must fail PIN setup")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .secureStorageUnavailable)
        }
        let state = try await service.state()
        XCTAssertTrue(state.isPINSet)
        XCTAssertTrue(state.isLocked)

        let reconstructed = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        let reconstructedMatches = try await reconstructed.verifyForManagement(
            PINInput("1234")
        )
        XCTAssertTrue(reconstructedMatches)
        let result = try await reconstructed.unlock(PINInput("1234"))
        XCTAssertEqual(result, .unlocked)
    }

    func testChangeDeleteFailureLeavesReplacementPINLockedAcrossReconstruction() async throws {
        let store = RecordingSecureValueStore(
            values: [Self.pinAddress: Self.legacyPINRecord],
            deleteFailures: [Self.throttleAddress: 1]
        )
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        do {
            try await service.changePIN(
                current: PINInput("1234"),
                replacement: PINInput("5678")
            )
            XCTFail("A failed durable throttle delete must fail PIN change")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .secureStorageUnavailable)
        }
        let state = try await service.state()
        XCTAssertTrue(state.isPINSet)
        XCTAssertTrue(state.isLocked)

        let reconstructed = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        let replacementMatches = try await reconstructed.verifyForManagement(PINInput("5678"))
        let priorMatches = try await reconstructed.verifyForManagement(PINInput("1234"))
        XCTAssertTrue(replacementMatches)
        XCTAssertFalse(priorMatches)
        let result = try await reconstructed.unlock(PINInput("5678"))
        XCTAssertEqual(result, .unlocked)
    }

    func testDisableDeleteFailureKeepsPINDurableAndLockedAcrossReconstruction() async throws {
        let store = RecordingSecureValueStore(
            values: [Self.pinAddress: Self.legacyPINRecord],
            deleteFailures: [Self.throttleAddress: 1]
        )
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let service = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        do {
            try await service.disablePIN(current: PINInput("1234"))
            XCTFail("A failed durable throttle delete must fail PIN disable")
        } catch {
            XCTAssertEqual(error as? AppLockServiceError, .secureStorageUnavailable)
        }
        let retainedPIN = await store.value(at: Self.pinAddress)
        XCTAssertEqual(retainedPIN, Self.legacyPINRecord)
        let operations = await store.recordedOperations()
        XCTAssertFalse(operations.contains(.delete(Self.pinAddress)))

        let reconstructed = AppLockService(
            secureValueStore: store,
            clock: clock,
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )
        let coldState = try await reconstructed.state()
        XCTAssertTrue(coldState.isPINSet)
        XCTAssertTrue(coldState.isLocked)
        let result = try await reconstructed.unlock(PINInput("1234"))
        XCTAssertEqual(result, .unlocked)
    }

    func testMalformedAndNegativeThrottleRecordsFailClosedWithoutMutation() async throws {
        let invalidRecords = [
            Data("not-json".utf8),
            Data(#"{"failedAttempts":-1,"lastFailure":null}"#.utf8),
            Data(#"{"failedAttempts":1,"lastFailure":null}"#.utf8),
        ]

        for invalidRecord in invalidRecords {
            let store = RecordingSecureValueStore(values: [
                Self.pinAddress: Self.legacyPINRecord,
                Self.throttleAddress: invalidRecord,
            ])
            let service = AppLockService(
                secureValueStore: store,
                clock: MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000)),
                entropy: FixedPINEntropy(bytes: Data(0...15))
            )

            do {
                _ = try await service.state()
                XCTFail("Invalid persisted throttle state must fail closed")
            } catch {
                XCTAssertEqual(error as? AppLockServiceError, .secureStorageUnavailable)
            }
            let retainedRecord = await store.value(at: Self.throttleAddress)
            XCTAssertEqual(retainedRecord, invalidRecord)
            let operations = await store.recordedOperations()
            XCTAssertEqual(
                operations,
                [.read(Self.pinAddress), .read(Self.throttleAddress)]
            )
        }
    }

    func testLegacyOverPolicyAndIntMaximumThrottleRecordsNormalizeAndRemainUnlockable() async throws {
        let legacyRecords = [
            Data(#"{"failedAttempts":10,"lastFailure":800000000}"#.utf8),
            Data(#"{"failedAttempts":\#(Int.max),"lastFailure":800000000}"#.utf8),
        ]

        for legacyRecord in legacyRecords {
            let store = RecordingSecureValueStore(values: [
                Self.pinAddress: Self.legacyPINRecord,
                Self.throttleAddress: legacyRecord,
            ])
            let clock = MutableClock(
                Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
            let service = AppLockService(
                secureValueStore: store,
                clock: clock,
                entropy: FixedPINEntropy(bytes: Data(0...15))
            )

            let locked = try await service.state()
            XCTAssertTrue(locked.isLocked)
            XCTAssertEqual(
                locked.retryAfter,
                Date(timeIntervalSinceReferenceDate: 800_000_300)
            )
            let retainedRecord = await store.value(at: Self.throttleAddress)
            XCTAssertEqual(retainedRecord, legacyRecord)

            clock.advance(by: 300)
            let result = try await service.unlock(PINInput("1234"))
            XCTAssertEqual(result, .unlocked)
            let clearedRecord = await store.value(at: Self.throttleAddress)
            XCTAssertNil(clearedRecord)
        }
    }

    func testFailureCountTransitionsToMaximumBoundary() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
            Self.throttleAddress: Data(
                #"{"failedAttempts":8,"lastFailure":799999879}"#.utf8
            ),
        ])
        let service = AppLockService(
            secureValueStore: store,
            clock: MutableClock(now),
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        let result = try await service.unlock(PINInput("0000"))
        XCTAssertEqual(result, .lockedOut(retryAfter: now.addingTimeInterval(300)))

        let persistedValue = await store.value(at: Self.throttleAddress)
        let persisted = try XCTUnwrap(persistedValue)
        let throttle = try JSONDecoder().decode(FrozenThrottleState.self, from: persisted)
        XCTAssertEqual(throttle.failedAttempts, 9)
        XCTAssertEqual(throttle.lastFailure, now)
    }

    func testMaximumFailureCountSaturatesAndRefreshesSharedManagementCooldown() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RecordingSecureValueStore(values: [
            Self.pinAddress: Self.legacyPINRecord,
            Self.throttleAddress: Data(
                #"{"failedAttempts":9,"lastFailure":799999699}"#.utf8
            ),
        ])
        let service = AppLockService(
            secureValueStore: store,
            clock: MutableClock(now),
            entropy: FixedPINEntropy(bytes: Data(0...15))
        )

        let managementResult = try await service.verifyForManagement(PINInput("0000"))
        XCTAssertFalse(managementResult)

        let persistedValue = await store.value(at: Self.throttleAddress)
        let persisted = try XCTUnwrap(persistedValue)
        let throttle = try JSONDecoder().decode(FrozenThrottleState.self, from: persisted)
        XCTAssertEqual(throttle.failedAttempts, 9)
        XCTAssertEqual(throttle.lastFailure, now)

        let state = try await service.state()
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.retryAfter, now.addingTimeInterval(300))
    }
}

private struct FrozenPINRecord: Decodable {
    let version: Int
    let iterations: Int
    let salt: Data
    let hash: Data
}

private struct FrozenThrottleState: Decodable {
    let failedAttempts: Int
    let lastFailure: Date?
}

private struct FixedPINEntropy: PINEntropyProviding {
    enum Error: Swift.Error {
        case unexpectedCount
    }

    let bytes: Data

    func randomBytes(count: Int) throws -> Data {
        guard count == bytes.count else { throw Error.unexpectedCount }
        return bytes
    }
}

private extension AppLockService {
    init(
        secureValueStore: any SecureValueStore,
        clock: any ClockProviding,
        entropy: any PINEntropyProviding = SystemPINEntropy()
    ) {
        self.init(
            runtimeIO: RuntimeIOClient(
                secureValueData: {
                    try await secureValueStore.data(service: $0, account: $1)
                },
                setSecureValue: {
                    try await secureValueStore.set($0, service: $1, account: $2)
                },
                deleteSecureValue: {
                    try await secureValueStore.delete(service: $0, account: $1)
                },
                now: { clock.now() }
            ),
            entropy: entropy
        )
    }
}

private struct MutableClock: ClockProviding {
    private let value: OSAllocatedUnfairLock<Date>

    init(_ initialValue: Date) {
        value = OSAllocatedUnfairLock(initialState: initialValue)
    }

    func now() -> Date {
        value.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private actor RecordingSecureValueStore: SecureValueStore {
    struct Address: Hashable, Sendable {
        let service: String
        let account: String
    }

    enum Operation: Equatable, Sendable {
        case read(Address)
        case write(Address)
        case delete(Address)
    }

    private struct InjectedFailure: Error {}

    private var values: [Address: Data]
    private var operations: [Operation] = []
    private var deleteFailures: [Address: Int]

    init(
        values: [Address: Data] = [:],
        deleteFailures: [Address: Int] = [:]
    ) {
        self.values = values
        self.deleteFailures = deleteFailures
    }

    func data(service: String, account: String) async throws -> Data? {
        let address = Address(service: service, account: account)
        operations.append(.read(address))
        return values[address]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        let address = Address(service: service, account: account)
        operations.append(.write(address))
        values[address] = data
    }

    func delete(service: String, account: String) async throws {
        let address = Address(service: service, account: account)
        operations.append(.delete(address))
        if let failures = deleteFailures[address], failures > 0 {
            deleteFailures[address] = failures - 1
            throw InjectedFailure()
        }
        values.removeValue(forKey: address)
    }

    func value(at address: Address) -> Data? {
        values[address]
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func clearOperations() {
        operations.removeAll()
    }
}

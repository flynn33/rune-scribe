import CommonCrypto
import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum AppLockServiceError: Error, Equatable, Sendable {
    case invalidPINFormat
    case incorrectPIN
    case secureStorageUnavailable
}

protocol PINEntropyProviding: Sendable {
    func randomBytes(count: Int) throws -> Data
}

struct SystemPINEntropy: PINEntropyProviding {
    func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        return SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

/// Core-owned optional application lock. Persisted record schemas, account names,
/// derivation parameters, and cooldown intervals match the shipping implementation.
actor AppLockService {
    private struct PINRecord: Codable, Sendable {
        var version: Int = 1
        let iterations: Int
        let salt: Data
        let hash: Data
    }

    private struct ThrottleState: Codable, Sendable {
        var failedAttempts: Int = 0
        var lastFailure: Date?
    }

    private static let iterations = 120_000
    private static let failureThreshold = 5
    // The cooldown schedule reaches its maximum tier at nine attempts. Legacy
    // releases persisted larger counters, which load at this saturated tier.
    private static let maximumFailedAttempts = 9
    private static let saltByteCount = 16

    private let runtimeIO: RuntimeIOClient
    private let entropy: any PINEntropyProviding

    private var loaded = false
    private var pinIsSet = false
    private var locked = false
    private var throttle = ThrottleState()

    init(
        runtimeIO: RuntimeIOClient,
        entropy: any PINEntropyProviding = SystemPINEntropy()
    ) {
        self.runtimeIO = runtimeIO
        self.entropy = entropy
    }

    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isNumber && $0.isASCII }
    }

    func state() async throws -> ApplicationLockStateDTO {
        try await loadIfNeeded()
        return try await makeState()
    }

    func setPIN(_ input: PINInput) async throws {
        try await loadIfNeeded()
        guard input.withValue(Self.isValidFormat) else {
            throw AppLockServiceError.invalidPINFormat
        }
        let salt: Data
        do {
            salt = try entropy.randomBytes(count: Self.saltByteCount)
        } catch {
            throw AppLockServiceError.secureStorageUnavailable
        }
        guard salt.count == Self.saltByteCount else {
            throw AppLockServiceError.secureStorageUnavailable
        }

        let record = try input.withValue { pin in
            guard Self.isValidFormat(pin) else { throw AppLockServiceError.invalidPINFormat }
            return PINRecord(
                iterations: Self.iterations,
                salt: salt,
                hash: Self.deriveHash(pin: pin, salt: salt, iterations: Self.iterations)
            )
        }
        do {
            try await runtimeIO.setSecureValue(
                try JSONEncoder().encode(record),
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            )
        } catch {
            throw AppLockServiceError.secureStorageUnavailable
        }

        pinIsSet = true
        locked = true
        try await clearThrottle()
        locked = false
    }

    func changePIN(current: PINInput, replacement: PINInput) async throws {
        try await loadIfNeeded()
        let matches = try await verifyUsingThrottle(current, clearFailuresOnSuccess: false)
        guard matches else { throw AppLockServiceError.incorrectPIN }
        try await setPIN(replacement)
    }

    func disablePIN(current: PINInput) async throws {
        try await loadIfNeeded()
        let matches = try await verifyUsingThrottle(current, clearFailuresOnSuccess: false)
        guard matches else { throw AppLockServiceError.incorrectPIN }
        // Clear durable throttle state before removing the PIN. If either
        // operation fails, a reconstructing service still sees a PIN and fails
        // closed instead of reporting a successful disable with stale security
        // state left behind.
        try await clearThrottle()
        do {
            try await runtimeIO.deleteSecureValue(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            )
        } catch {
            locked = pinIsSet
            throw AppLockServiceError.secureStorageUnavailable
        }
        pinIsSet = false
        locked = false
    }

    func unlock(_ input: PINInput) async throws -> UnlockResultDTO {
        try await loadIfNeeded()
        if let retryAfter = try await lockoutRetryAfter() {
            return .lockedOut(retryAfter: retryAfter)
        }

        if try await verify(input) {
            try await clearThrottle()
            locked = false
            return .unlocked
        }

        try await registerFailure()
        if let retryAfter = try await lockoutRetryAfter() {
            return .lockedOut(retryAfter: retryAfter)
        }
        return .incorrect
    }

    /// Management verification shares the durable unlock throttle but never
    /// unlocks the app. A successful probe clears prior failures so a valid PIN
    /// is not penalized by earlier mistakes.
    func verifyForManagement(_ input: PINInput) async throws -> Bool {
        try await loadIfNeeded()
        return try await verifyUsingThrottle(input, clearFailuresOnSuccess: true)
    }

    func lockIfEnabled() async throws {
        try await loadIfNeeded()
        if pinIsSet { locked = true }
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        do {
            let pinData = try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            )
            let throttleData = try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.pinThrottleAccount
            )
            pinIsSet = pinData != nil
            locked = pinIsSet
            if let throttleData {
                guard let decoded = try? JSONDecoder().decode(
                    ThrottleState.self,
                    from: throttleData
                ), Self.isValid(decoded) else {
                    throw AppLockServiceError.secureStorageUnavailable
                }
                // Earlier releases persisted an unbounded positive attempt
                // count. Normalize that valid legacy state to the maximum
                // cooldown tier so upgrades remain unlockable and subsequent
                // failures cannot overflow.
                throttle = ThrottleState(
                    failedAttempts: min(
                        decoded.failedAttempts,
                        Self.maximumFailedAttempts
                    ),
                    lastFailure: decoded.lastFailure
                )
            } else {
                throttle = ThrottleState()
            }
            loaded = true
        } catch {
            throw AppLockServiceError.secureStorageUnavailable
        }
    }

    private func verify(_ input: PINInput) async throws -> Bool {
        let data: Data?
        do {
            data = try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            )
        } catch {
            throw AppLockServiceError.secureStorageUnavailable
        }
        guard let data,
              let record = try? JSONDecoder().decode(PINRecord.self, from: data),
              record.version == 1,
              record.iterations == Self.iterations,
              record.salt.count == Self.saltByteCount,
              record.hash.count == 32
        else { return false }

        return input.withValue { pin in
            guard Self.isValidFormat(pin) else { return false }
            let candidate = Self.deriveHash(
                pin: pin,
                salt: record.salt,
                iterations: record.iterations
            )
            return Self.constantTimeEqual(candidate, record.hash)
        }
    }

    private func verifyUsingThrottle(
        _ input: PINInput,
        clearFailuresOnSuccess: Bool
    ) async throws -> Bool {
        guard try await lockoutRetryAfter() == nil else { return false }

        if try await verify(input) {
            if clearFailuresOnSuccess, throttle.failedAttempts > 0 {
                try await clearThrottle()
            }
            return true
        }

        try await registerFailure()
        return false
    }

    private func registerFailure() async throws {
        let increment = throttle.failedAttempts.addingReportingOverflow(1)
        throttle.failedAttempts = increment.overflow
            ? Self.maximumFailedAttempts
            : min(increment.partialValue, Self.maximumFailedAttempts)
        throttle.lastFailure = try await runtimeIO.now()
        do {
            try await runtimeIO.setSecureValue(
                try JSONEncoder().encode(throttle),
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.pinThrottleAccount
            )
        } catch {
            // Retain the in-process throttle and fail closed if persistence is unavailable.
            locked = pinIsSet
            throw AppLockServiceError.secureStorageUnavailable
        }
    }

    private func clearThrottle() async throws {
        do {
            try await runtimeIO.deleteSecureValue(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.pinThrottleAccount
            )
        } catch {
            locked = pinIsSet
            throw AppLockServiceError.secureStorageUnavailable
        }
        // Mutate actor state only after durable deletion succeeds. A failed
        // delete therefore preserves the same cooldown in memory and on disk.
        throttle = ThrottleState()
    }

    private static func isValid(_ throttle: ThrottleState) -> Bool {
        guard throttle.failedAttempts >= 0 else { return false }
        if throttle.failedAttempts == 0 {
            return throttle.lastFailure == nil
        }
        return throttle.lastFailure != nil
    }

    private func lockoutRetryAfter() async throws -> Date? {
        guard throttle.failedAttempts >= Self.failureThreshold,
              let lastFailure = throttle.lastFailure
        else { return nil }
        let expiry = lastFailure.addingTimeInterval(Self.cooldown(forAttempts: throttle.failedAttempts))
        return expiry > (try await runtimeIO.now()) ? expiry : nil
    }

    private static func cooldown(forAttempts attempts: Int) -> TimeInterval {
        switch attempts {
        case ..<failureThreshold: 0
        case 5: 15
        case 6: 30
        case 7: 60
        case 8: 120
        default: 300
        }
    }

    private func makeState() async throws -> ApplicationLockStateDTO {
        ApplicationLockStateDTO(
            isPINSet: pinIsSet,
            isLocked: locked,
            retryAfter: try await lockoutRetryAfter()
        )
    }

    /// PBKDF2-HMAC-SHA256. Returning zeroes on derivation failure preserves the
    /// shipping fail-closed behavior and the persisted compatibility contract.
    static func deriveHash(pin: String, salt: Data, iterations: Int) -> Data {
        let pinData = Data(pin.utf8)
        guard !pinData.isEmpty,
              !salt.isEmpty,
              iterations > 0,
              iterations <= Int(UInt32.max)
        else { return Data(repeating: 0, count: 32) }

        var derived = Data(repeating: 0, count: 32)
        let status = derived.withUnsafeMutableBytes { derivedPointer in
            salt.withUnsafeBytes { saltPointer in
                pinData.withUnsafeBytes { pinPointer in
                    guard let derivedBase = derivedPointer.baseAddress,
                          let saltBase = saltPointer.baseAddress,
                          let pinBase = pinPointer.baseAddress
                    else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBase.assumingMemoryBound(to: CChar.self),
                        pinData.count,
                        saltBase.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBase.assumingMemoryBound(to: UInt8.self),
                        derivedPointer.count
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : Data(repeating: 0, count: 32)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        for index in 0..<Swift.max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0)
                ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}

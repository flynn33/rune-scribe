// RuneScrib/Services/AppLock.swift

import Foundation
import CryptoKit
import CommonCrypto

/// Manages the optional 4-digit app-lock PIN.
///
/// The PIN itself is never stored. A random 16-byte salt and a PBKDF2-HMAC-SHA256
/// derivation of the PIN are stored in the Keychain; verification re-derives and
/// compares in constant time. Failed attempts are rate-limited with an escalating
/// lockout that survives relaunch (the throttle state is persisted in the Keychain),
/// so the small 4-digit space can't be brute-forced by repeated launches.
///
/// The lock engages on cold launch and whenever the app goes to the background, and
/// is released only by entering the correct PIN.
///
/// Published as a singleton and injected as an `@EnvironmentObject`; all state
/// mutates on the main actor.
@MainActor
final class AppLock: ObservableObject {

    // MARK: - Singleton

    static let shared = AppLock()

    // MARK: - Published State

    /// Whether a PIN is currently configured.
    @Published private(set) var isPINSet: Bool = false

    /// Whether the app is currently locked behind the PIN screen.
    @Published var isLocked: Bool = false

    // MARK: - Result / Errors

    enum UnlockResult: Equatable {
        case success
        case incorrect
        case lockedOut(seconds: Int)
    }

    enum PINError: LocalizedError {
        case invalidFormat
        case wrongPIN

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Enter a 4-digit PIN."
            case .wrongPIN:      return "Incorrect PIN."
            }
        }
    }

    // MARK: - Stored Records

    private struct PINRecord: Codable {
        var version: Int = 1
        let iterations: Int
        let salt: Data
        let hash: Data
    }

    private struct ThrottleState: Codable {
        var failedAttempts: Int = 0
        var lastFailure: Date?
    }

    // MARK: - Tuning

    private let iterations = 120_000              // PBKDF2 rounds
    private let failureThreshold = 5              // free attempts before lockout

    // MARK: - Dependencies / State

    private let keychain = KeychainService.shared
    private var throttle: ThrottleState

    // MARK: - Init

    private init() {
        throttle = Self.loadThrottle()
        let hasPIN = ((try? keychain.retrievePINRecord()) ?? nil) != nil
        if hasPIN {
            isPINSet = true
            isLocked = true   // require the PIN on a cold launch
        }
    }

    // MARK: - Validation

    /// True when `pin` is exactly four ASCII digits.
    nonisolated static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isNumber && $0.isASCII }
    }

    // MARK: - Mutations

    /// Sets (or replaces) the PIN, clears any lockout, and unlocks.
    func setPIN(_ pin: String) throws {
        guard Self.isValidFormat(pin) else { throw PINError.invalidFormat }
        let record = makeRecord(for: pin)
        try keychain.storePINRecord(JSONEncoder().encode(record))
        clearThrottle()
        isPINSet = true
        isLocked = false
    }

    /// Verifies the current PIN, then replaces it with `new`.
    func changePIN(current: String, new: String) throws {
        guard verify(current) else { throw PINError.wrongPIN }
        try setPIN(new)
    }

    /// Verifies the current PIN, then removes it (disables the lock).
    func disablePIN(current: String) throws {
        guard verify(current) else { throw PINError.wrongPIN }
        try keychain.deletePINRecord()
        clearThrottle()
        isPINSet = false
        isLocked = false
    }

    // MARK: - Lock / Unlock

    /// Attempts to unlock with `pin`, enforcing the failed-attempt lockout.
    @discardableResult
    func attemptUnlock(_ pin: String) -> UnlockResult {
        if let remaining = lockoutRemaining() {
            return .lockedOut(seconds: remaining)
        }
        if verify(pin) {
            clearThrottle()
            isLocked = false
            return .success
        }
        registerFailure()
        if let remaining = lockoutRemaining() {
            return .lockedOut(seconds: remaining)
        }
        return .incorrect
    }

    /// Engages the lock if a PIN is configured (called when backgrounding).
    func lockIfEnabled() {
        if isPINSet { isLocked = true }
    }

    // MARK: - Verification

    /// Constant-time comparison of `pin` against the stored PBKDF2 hash.
    func verify(_ pin: String) -> Bool {
        guard Self.isValidFormat(pin) else { return false }
        guard
            let data = (try? keychain.retrievePINRecord()) ?? nil,
            let record = try? JSONDecoder().decode(PINRecord.self, from: data)
        else { return false }

        let candidate = Self.deriveHash(pin: pin, salt: record.salt, iterations: record.iterations)
        return constantTimeEqual(candidate, record.hash)
    }

    // MARK: - Throttle

    /// Seconds remaining in the current lockout, or nil if attempts are allowed.
    private func lockoutRemaining() -> Int? {
        guard throttle.failedAttempts >= failureThreshold, let last = throttle.lastFailure else { return nil }
        let remaining = cooldown(forAttempts: throttle.failedAttempts) - Date().timeIntervalSince(last)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }

    /// Escalating lockout duration once the free-attempt threshold is passed.
    private func cooldown(forAttempts attempts: Int) -> TimeInterval {
        switch attempts {
        case ..<failureThreshold: return 0
        case 5:  return 15
        case 6:  return 30
        case 7:  return 60
        case 8:  return 120
        default: return 300
        }
    }

    private func registerFailure() {
        throttle.failedAttempts += 1
        throttle.lastFailure = Date()
        persistThrottle()
    }

    private func clearThrottle() {
        throttle = ThrottleState()
        try? keychain.deletePINThrottle()
    }

    private func persistThrottle() {
        if let data = try? JSONEncoder().encode(throttle) {
            try? keychain.storePINThrottle(data)
        }
    }

    private static func loadThrottle() -> ThrottleState {
        if let data = (try? KeychainService.shared.retrievePINThrottle()) ?? nil,
           let state = try? JSONDecoder().decode(ThrottleState.self, from: data) {
            return state
        }
        return ThrottleState()
    }

    // MARK: - Crypto Helpers

    private func makeRecord(for pin: String) -> PINRecord {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let hash = Self.deriveHash(pin: pin, salt: salt, iterations: iterations)
        return PINRecord(iterations: iterations, salt: salt, hash: hash)
    }

    /// PBKDF2-HMAC-SHA256 derivation. On any failure it returns all-zero bytes, so
    /// verification fails closed.
    private static func deriveHash(pin: String, salt: Data, iterations: Int) -> Data {
        let pinData = Data(pin.utf8)
        guard !pinData.isEmpty, !salt.isEmpty else { return Data(repeating: 0, count: 32) }

        var derived = Data(repeating: 0, count: 32)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                pinData.withUnsafeBytes { pinPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinPtr.baseAddress!.assumingMemoryBound(to: CChar.self),
                        pinData.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        derivedPtr.count
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : Data(repeating: 0, count: 32)
    }

    /// Length-folded constant-time equality (no early return on length mismatch).
    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let a = [UInt8](lhs)
        let b = [UInt8](rhs)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        let count = Swift.max(a.count, b.count)
        for index in 0..<count {
            let left  = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

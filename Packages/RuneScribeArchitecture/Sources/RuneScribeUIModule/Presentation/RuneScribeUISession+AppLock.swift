import Foundation
import RuneScribeContracts

extension RuneScribeUISession {
    enum UnlockResult: Equatable, Sendable {
        case success
        case incorrect
        case lockedOut(seconds: Int)
    }

    enum PINError: LocalizedError, Sendable {
        case invalidFormat
        case wrongPIN
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidFormat: "Enter a 4-digit PIN."
            case .wrongPIN: "Incorrect PIN."
            case .unavailable: "App Lock is temporarily unavailable."
            }
        }
    }

    nonisolated static func isValidPINFormat(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 4 && bytes.allSatisfy { (48...57).contains($0) }
    }

    nonisolated static func isValidFormat(_ pin: String) -> Bool {
        isValidPINFormat(pin)
    }

    nonisolated static func message(forPINError error: Error) -> String {
        guard let pinError = error as? PINError else {
            return "App Lock is temporarily unavailable."
        }
        return pinError.errorDescription ?? "App Lock is temporarily unavailable."
    }

    func setPIN(_ pin: String) async throws {
        guard Self.isValidPINFormat(pin) else { throw PINError.invalidFormat }
        do {
            try await requireApplicationService().setPIN(SetPINCommand(input: PINInput(pin)))
        } catch {
            throw Self.mapPINError(error)
        }
    }

    func changePIN(current: String, new: String) async throws {
        guard Self.isValidPINFormat(new) else { throw PINError.invalidFormat }
        do {
            try await requireApplicationService().changePIN(
                ChangePINCommand(current: PINInput(current), replacement: PINInput(new))
            )
        } catch {
            throw Self.mapPINError(error)
        }
    }

    func disablePIN(current: String) async throws {
        do {
            try await requireApplicationService().disablePIN(
                DisablePINCommand(current: PINInput(current))
            )
        } catch {
            throw Self.mapPINError(error)
        }
    }

    func attemptUnlock(_ pin: String) async throws -> UnlockResult {
        do {
            switch try await requireApplicationService().unlock(
                UnlockCommand(input: PINInput(pin))
            ) {
            case .unlocked:
                return .success
            case .incorrect:
                return .incorrect
            case .lockedOut(let retryAfter):
                let seconds = max(1, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))
                return .lockedOut(seconds: seconds)
            }
        } catch {
            throw Self.mapPINError(error)
        }
    }

    func verify(_ pin: String) async throws -> Bool {
        do {
            return try await requireApplicationService().verifyPIN(PINInput(pin))
        } catch {
            throw Self.mapPINError(error)
        }
    }

    func lockIfEnabled() async {
        guard let service = try? requireApplicationService() else { return }
        await service.lock()
    }

    func lock() async {
        guard let service = try? requireApplicationService() else { return }
        await service.lock()
    }

    private nonisolated static func mapPINError(_ error: Error) -> PINError {
        guard let productError = error as? RuneScribeProductError,
              case .failure(let failure) = productError
        else { return .unavailable }
        switch failure.code {
        case .invalidInput:
            return .invalidFormat
        case .authenticationFailed:
            return .wrongPIN
        default:
            return .unavailable
        }
    }
}

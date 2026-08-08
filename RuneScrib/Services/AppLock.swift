import Combine
import Foundation
import RuneScribeContracts

/// Key-free presentation adapter for the Core-owned application lock.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isPINSet = false
    @Published private(set) var isLocked = false

    enum UnlockResult: Equatable {
        case success
        case incorrect
        case lockedOut(seconds: Int)
    }

    enum PINError: LocalizedError {
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

    private let service: any RuneScribeApplicationService
    private var observationTask: Task<Void, Never>?

    init(service: any RuneScribeApplicationService) {
        self.service = service
        observationTask = Task { [weak self, service] in
            for await snapshot in service.stateStream() {
                guard !Task.isCancelled else { return }
                self?.isPINSet = snapshot.lockState.isPINSet
                self?.isLocked = snapshot.lockState.isLocked
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    nonisolated static func isValidFormat(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 4 && bytes.allSatisfy { (48...57).contains($0) }
    }

    func setPIN(_ pin: String) async throws {
        guard Self.isValidFormat(pin) else { throw PINError.invalidFormat }
        do {
            try await service.setPIN(SetPINCommand(input: PINInput(pin)))
        } catch {
            throw Self.map(error)
        }
    }

    func changePIN(current: String, new: String) async throws {
        guard Self.isValidFormat(new) else { throw PINError.invalidFormat }
        do {
            try await service.changePIN(
                ChangePINCommand(current: PINInput(current), replacement: PINInput(new))
            )
        } catch {
            throw Self.map(error)
        }
    }

    func disablePIN(current: String) async throws {
        do {
            try await service.disablePIN(DisablePINCommand(current: PINInput(current)))
        } catch {
            throw Self.map(error)
        }
    }

    func attemptUnlock(_ pin: String) async throws -> UnlockResult {
        do {
            switch try await service.unlock(UnlockCommand(input: PINInput(pin))) {
            case .unlocked:
                return .success
            case .incorrect:
                return .incorrect
            case .lockedOut(let retryAfter):
                let seconds = max(1, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))
                return .lockedOut(seconds: seconds)
            }
        } catch {
            throw Self.map(error)
        }
    }

    func verify(_ pin: String) async throws -> Bool {
        do {
            return try await service.verifyPIN(PINInput(pin))
        } catch {
            throw Self.map(error)
        }
    }

    func lockIfEnabled() async {
        await service.lock()
    }

    private nonisolated static func map(_ error: Error) -> PINError {
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

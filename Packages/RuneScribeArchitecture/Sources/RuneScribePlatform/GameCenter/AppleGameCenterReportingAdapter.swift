#if canImport(GameKit)
import Foundation
import GameKit
import CryptoKit
import RuneScribeContracts
#if os(macOS)
import AppKit
private typealias GameCenterAuthenticationViewController = NSViewController
#elseif os(iOS)
import UIKit
private typealias GameCenterAuthenticationViewController = UIViewController
#endif

public actor AppleGameCenterReportingAdapter: GameCenterReporting {
    private let authenticationSingleFlight: GameCenterAuthenticationSingleFlight

    public init() {
        authenticationSingleFlight = GameCenterAuthenticationSingleFlight {
            try await AppleGameCenterAuthenticationAttempt().run()
        }
    }

    public func authenticationState() async -> GameCenterAuthenticationStateDTO {
        GKLocalPlayer.local.isAuthenticated ? .authenticated : .notAuthenticated
    }

    public func accountScopeDigest() async -> GameCenterAccountScopeDigestDTO? {
        guard GKLocalPlayer.local.isAuthenticated else { return nil }
        let scopedMaterial = Data(
            "runescribe.game-center.account.v1|\(GKLocalPlayer.local.gamePlayerID)".utf8
        )
        let digest = SHA256.hash(data: scopedMaterial)
            .map { String(format: "%02x", $0) }
            .joined()
        return GameCenterAccountScopeDigestDTO(rawValue: digest)
    }

    public func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO {
        if GKLocalPlayer.local.isAuthenticated { return .authenticated }
        return try await authenticationSingleFlight.run()
    }

    public func report(_ achievements: [GameCenterAchievementReportDTO]) async throws {
        guard GKLocalPlayer.local.isAuthenticated else {
            throw GameCenterReportingTransportError.notAuthenticated
        }
        guard !achievements.isEmpty else { return }
        let reports = achievements.map { report in
            let achievement = GKAchievement(identifier: report.identifier)
            achievement.percentComplete = Double(report.percentage)
            achievement.showsCompletionBanner = false
            return achievement
        }
        do {
            try await GKAchievement.report(reports)
        } catch {
            throw mapGameCenterError(error)
        }
    }
}

actor GameCenterAuthenticationSingleFlight {
    typealias Operation = @Sendable () async throws -> GameCenterAuthenticationStateDTO

    private struct ActiveOperation {
        let id: UUID
        let task: Task<GameCenterAuthenticationStateDTO, Error>
    }

    private let operation: Operation
    private var activeOperation: ActiveOperation?
    private var activeRequestCount = 0

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run() async throws -> GameCenterAuthenticationStateDTO {
        let active: ActiveOperation
        if let activeOperation {
            active = activeOperation
        } else {
            let operation = self.operation
            let created = ActiveOperation(
                id: UUID(),
                task: Task { try await operation() }
            )
            activeOperation = created
            active = created
        }

        activeRequestCount += 1
        defer { finishRequest(for: active.id) }
        return try await active.task.value
    }

    func currentRequestCount() -> Int {
        activeRequestCount
    }

    private func finishRequest(for operationID: UUID) {
        activeRequestCount -= 1
        if activeOperation?.id == operationID {
            activeOperation = nil
        }
    }
}

@MainActor
private final class AppleGameCenterAuthenticationAttempt {
    private var continuation: CheckedContinuation<
        GameCenterAuthenticationStateDTO,
        any Error
    >?

    func run() async throws -> GameCenterAuthenticationStateDTO {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
                MainActor.assumeIsolated {
                    self?.handle(viewController: viewController, error: error)
                }
            }
        }
    }

    private func handle(
        viewController: GameCenterAuthenticationViewController?,
        error: Error?
    ) {
        if let error {
            finish(throwing: mapGameCenterError(error))
            return
        }
        if let viewController {
            do {
                try present(viewController)
            } catch {
                finish(throwing: error)
            }
            return
        }
        finish(
            returning: GKLocalPlayer.local.isAuthenticated
                ? .authenticated
                : .notAuthenticated
        )
    }

    private func present(_ viewController: GameCenterAuthenticationViewController) throws {
        #if os(macOS)
        guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible),
            let presenter = window.contentViewController
        else {
            throw GameCenterReportingTransportError.authenticationPresentationUnavailable
        }
        presenter.presentAsSheet(viewController)
        #elseif os(iOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard var presenter = window?.rootViewController else {
            throw GameCenterReportingTransportError.authenticationPresentationUnavailable
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(viewController, animated: true)
        #else
        throw GameCenterReportingTransportError.authenticationPresentationUnavailable
        #endif
    }

    private func finish(returning state: GameCenterAuthenticationStateDTO) {
        guard let continuation else { return }
        self.continuation = nil
        GKLocalPlayer.local.authenticateHandler = nil
        continuation.resume(returning: state)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        GKLocalPlayer.local.authenticateHandler = nil
        continuation.resume(throwing: error)
    }
}

private func mapGameCenterError(_ error: Error) -> GameCenterReportingTransportError {
    guard let code = GKError.Code(rawValue: (error as NSError).code) else {
        return .serviceUnavailable
    }
    switch code {
    case .notAuthenticated:
        return .notAuthenticated
    case .communicationsFailure:
        return .offline
    case .parentalControlsBlocked:
        return .restricted
    case .cancelled:
        return .cancelled
    case .gameUnrecognized, .notSupported:
        return .configurationUnavailable
    default:
        return .serviceUnavailable
    }
}
#endif

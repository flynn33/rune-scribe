import Foundation
import RuneScribeContracts
import SwiftUI

public struct RootViewContribution: Sendable {
    public let moduleID: ModuleIdentifier
    private let builder: @MainActor @Sendable () -> AnyView

    public init(
        moduleID: ModuleIdentifier,
        builder: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.moduleID = moduleID
        self.builder = builder
    }

    @MainActor
    public func makeView() -> AnyView {
        builder()
    }
}

public enum BootPresentationState: Equatable, Sendable {
    case booting
    case ready(moduleID: ModuleIdentifier)
    case recovery(message: String)
}

public enum RootContributionError: Error, Equatable, Sendable {
    case none
    case multiple([ModuleIdentifier])
}

public enum RootContributionSelector {
    public static func select(
        from contributions: [RootViewContribution]
    ) throws -> RootViewContribution {
        guard let first = contributions.first else {
            throw RootContributionError.none
        }
        guard contributions.count == 1 else {
            throw RootContributionError.multiple(contributions.map(\.moduleID).sorted())
        }
        return first
    }
}

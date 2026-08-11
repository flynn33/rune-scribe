import Foundation
import RuneScribeContracts
import SwiftUI

public struct RuneScribeUIProductMetadata: Equatable, Sendable {
    public let version: String
    public let buildNumber: String

    public init(version: String, buildNumber: String) {
        self.version = version
        self.buildNumber = buildNumber
    }

    public static let unavailable = RuneScribeUIProductMetadata(
        version: "—",
        buildNumber: "—"
    )
}

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

public struct RuntimeRootPresentationPortKey: Hashable, Sendable {
    public static let standard = RuntimeRootPresentationPortKey(
        identifier: "runtime.standard-port.root-presentation"
    )

    public let identifier: ServiceIdentifier

    private init(identifier: ServiceIdentifier) {
        self.identifier = identifier
    }
}

public struct RuntimeRootPresentationHostAdapter: Sendable {
    package let productMetadata: RuneScribeUIProductMetadata
    private let presentOperation: @MainActor @Sendable (
        RootViewContribution
    ) throws -> Void
    private let dismissOperation: @MainActor @Sendable (
        ModuleIdentifier
    ) -> Void

    package init(
        productMetadata: RuneScribeUIProductMetadata,
        present: @escaping @MainActor @Sendable (
            RootViewContribution
        ) throws -> Void,
        dismiss: @escaping @MainActor @Sendable (
            ModuleIdentifier
        ) -> Void
    ) {
        self.productMetadata = productMetadata
        presentOperation = present
        dismissOperation = dismiss
    }

    package func present(_ contribution: RootViewContribution) async throws {
        try await presentOperation(contribution)
    }

    package func dismiss(moduleID: ModuleIdentifier) async {
        await dismissOperation(moduleID)
    }
}

public struct RuntimeRootPresentationClient: Sendable {
    private let productMetadataOperation: @Sendable () async throws
        -> RuneScribeUIProductMetadata
    private let presentOperation: @Sendable (
        RootViewContribution
    ) async throws -> Void
    private let dismissOperation: @Sendable () async throws -> Void

    package init(
        productMetadata: @escaping @Sendable () async throws
            -> RuneScribeUIProductMetadata,
        present: @escaping @Sendable (
            RootViewContribution
        ) async throws -> Void,
        dismiss: @escaping @Sendable () async throws -> Void
    ) {
        productMetadataOperation = productMetadata
        presentOperation = present
        dismissOperation = dismiss
    }

    public func productMetadata() async throws -> RuneScribeUIProductMetadata {
        try await productMetadataOperation()
    }

    public func present(_ contribution: RootViewContribution) async throws {
        try await presentOperation(contribution)
    }

    public func dismiss() async throws {
        try await dismissOperation()
    }
}

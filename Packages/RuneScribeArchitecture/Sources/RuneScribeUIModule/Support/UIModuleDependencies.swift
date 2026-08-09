import Foundation
import RuneScribeUIRuntime

public struct RuneScribeUIProductMetadata: Equatable, Sendable {
    let version: String
    let buildNumber: String

    public init(version: String, buildNumber: String) {
        self.version = version
        self.buildNumber = buildNumber
    }

    public static let unavailable = RuneScribeUIProductMetadata(
        version: "—",
        buildNumber: "—"
    )
}

public struct RuneScribeUIDependencies: Sendable {
    let rootPresentationStore: RootViewPresentationStore
    let sharePresentation: OpaqueSharePresentationProvider
    let productMetadata: RuneScribeUIProductMetadata

    public init(
        rootPresentationStore: RootViewPresentationStore,
        sharePresentation: OpaqueSharePresentationProvider = .unavailable,
        productMetadata: RuneScribeUIProductMetadata = .unavailable
    ) {
        self.rootPresentationStore = rootPresentationStore
        self.sharePresentation = sharePresentation
        self.productMetadata = productMetadata
    }
}

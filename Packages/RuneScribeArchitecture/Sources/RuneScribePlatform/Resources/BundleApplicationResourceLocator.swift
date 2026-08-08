import Foundation
import RuneScribeContracts

public enum ApplicationResourceLocatorError: Error, Equatable, Sendable {
    case resourceNotFound(ApplicationResource)
}

/// Resolves resources from the bundle explicitly supplied by an application
/// host. Package code never assumes that its own bundle is the app resource owner.
public struct BundleApplicationResourceLocator: ApplicationResourceLocator, Sendable {
    private let bundle: Bundle

    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    public func data(for resource: ApplicationResource) async throws -> Data {
        try dataSynchronously(for: resource)
    }

    public func url(for resource: ApplicationResource) async throws -> URL {
        try urlSynchronously(for: resource)
    }

    public func dataSynchronously(for resource: ApplicationResource) throws -> Data {
        try Data(contentsOf: try urlSynchronously(for: resource))
    }

    public func urlSynchronously(for resource: ApplicationResource) throws -> URL {
        guard let url = bundle.url(
            forResource: resource.name,
            withExtension: resource.fileExtension,
            subdirectory: resource.subdirectory
        ) else {
            throw ApplicationResourceLocatorError.resourceNotFound(resource)
        }
        return url
    }
}

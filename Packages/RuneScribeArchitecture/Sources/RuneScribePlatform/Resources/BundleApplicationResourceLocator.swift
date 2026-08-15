import Foundation
import RuneScribeContracts

public enum ApplicationResourceLocatorError: Error, Equatable, Sendable {
    case resourceNotFound(ApplicationResource)
    case ownerBundleUnavailable(ModuleIdentifier)
}

/// Resolves resources from the bundle explicitly supplied by an application
/// host. Package code never assumes that its own bundle is the app resource owner.
public struct BundleApplicationResourceLocator: ApplicationResourceLocator, Sendable {
    private let bundle: Bundle
    private let moduleBundles: [ModuleIdentifier: Bundle]

    public init(
        bundle: Bundle,
        moduleBundles: [ModuleIdentifier: Bundle] = [:]
    ) {
        self.bundle = bundle
        self.moduleBundles = moduleBundles
    }

    public func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    public func data(
        for resource: ApplicationResource,
        maximumByteCount: Int
    ) async throws -> Data {
        guard maximumByteCount > 0, maximumByteCount < Int.max else {
            throw ApplicationResourceReadError.invalidMaximumByteCount
        }
        let handle = try FileHandle(forReadingFrom: location(for: resource))
        defer { try? handle.close() }
        let value = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard value.count <= maximumByteCount else {
            throw ApplicationResourceReadError.contentTooLarge(resource)
        }
        return value
    }

    public func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        let resourceBundle: Bundle
        if let ownerModuleID = resource.ownerModuleID {
            guard let registeredBundle = moduleBundles[ownerModuleID] else {
                throw ApplicationResourceLocatorError.ownerBundleUnavailable(ownerModuleID)
            }
            resourceBundle = registeredBundle
        } else {
            resourceBundle = bundle
        }
        guard let url = resourceBundle.url(
            forResource: resource.name,
            withExtension: resource.fileExtension,
            subdirectory: resource.subdirectory
        ) else {
            throw ApplicationResourceLocatorError.resourceNotFound(resource)
        }
        return url
    }
}

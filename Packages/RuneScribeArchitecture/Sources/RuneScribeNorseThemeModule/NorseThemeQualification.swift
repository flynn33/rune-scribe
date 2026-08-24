import Foundation
import RuneScribeContracts

/// Keeps deliberate required-Base resource failure injection inside Simulator
/// qualification builds. Device and macOS products always receive the original
/// application resource locator.
public enum RuneScribeNorseThemeQualification {
    public static func applicationResourceLocator(
        base: any ApplicationResourceLocator,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any ApplicationResourceLocator {
        #if targetEnvironment(simulator)
        if environment["RUNESCRIBE_QUALIFICATION_BASE_RESOURCE_FAILURE"]
            == "missing-norse-font" {
            return MissingRequiredBaseResourceLocator(
                base: base,
                unavailableResource: NorseBaseBundledResourceCatalog.notoSansRunic
            )
        }
        #endif
        return base
    }
}

private struct MissingRequiredBaseResourceLocator: ApplicationResourceLocator {
    let base: any ApplicationResourceLocator
    let unavailableResource: ApplicationResource

    func data(for resource: ApplicationResource) async throws -> Data {
        try rejectUnavailable(resource)
        return try await base.data(for: resource)
    }

    func data(
        for resource: ApplicationResource,
        maximumByteCount: Int
    ) async throws -> Data {
        try rejectUnavailable(resource)
        return try await base.data(for: resource, maximumByteCount: maximumByteCount)
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try rejectUnavailable(resource)
        return try await base.url(for: resource)
    }

    private func rejectUnavailable(_ resource: ApplicationResource) throws {
        guard resource != unavailableResource else {
            throw QualificationResourceFailure.unavailable
        }
    }
}

private enum QualificationResourceFailure: Error {
    case unavailable
}

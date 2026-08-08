import Foundation
import RuneScribeContracts

/// Hosted launch bridge retained until bootstrap moves fully to the application
/// snapshot lifecycle. Font lookup, validation, persistence, and registration
/// are owned by Core behind injected Platform seams.
final class FontStore: Sendable {
    private let applicationService: any RuneScribeApplicationService

    init(applicationService: any RuneScribeApplicationService) {
        self.applicationService = applicationService
    }

    func registerBundledAndImportedFonts() {
        let stream = applicationService.stateStream()
        Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
}

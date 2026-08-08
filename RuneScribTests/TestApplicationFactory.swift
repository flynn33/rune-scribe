import Combine
import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import XCTest
@testable import RuneScrib

@MainActor
enum TestApplicationFactory {
    struct IntegratedContext {
        let service: RuneScribeCoreApplicationService
        let protectedFiles: InMemoryProtectedFileStore
        let fontRegistrar: InMemoryFontRegistrar
        let bundledFontData: Data
    }

    static func makeKeyManager() -> KeyManager {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        return KeyManager(service: service)
    }

    static func makeIntegratedContext(
        protectedFiles initialFiles: [ProtectedPath: Data] = [:],
        additionalFontNames: [Data: String] = [:]
    ) throws -> IntegratedContext {
        let testBundle = Bundle(for: TestApplicationBundleAnchor.self)
        guard let fontURL = testBundle.url(
            forResource: "NotoSansRunic-Regular",
            withExtension: "ttf"
        ) ?? Bundle.main.url(
            forResource: "NotoSansRunic-Regular",
            withExtension: "ttf"
        ) else {
            throw TestApplicationFactoryError.missingBundledFont
        }
        let bundledFontData = try Data(contentsOf: fontURL)
        let protectedFiles = InMemoryProtectedFileStore(files: initialFiles)
        var fontNames = additionalFontNames
        fontNames[bundledFontData] = "Noto Sans Runic"
        let fontRegistrar = InMemoryFontRegistrar(namesByData: fontNames)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            protectedFileStore: protectedFiles,
            inboundFileReader: InMemoryInboundFileReader(),
            shareArtifactStore: InMemoryShareArtifactStore(),
            applicationResourceLocator: MappedApplicationResourceLocator(
                locations: [.bundledRuneFont: fontURL]
            ),
            systemFontRegistrar: fontRegistrar,
            contactAccess: InMemoryContactAccessService(authorizationStatus: .authorized),
            clipboardReading: InMemoryClipboardService(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        return IntegratedContext(
            service: service,
            protectedFiles: protectedFiles,
            fontRegistrar: fontRegistrar,
            bundledFontData: bundledFontData
        )
    }
}

private final class TestApplicationBundleAnchor: NSObject {}

private enum TestApplicationFactoryError: Error {
    case missingBundledFont
}

@MainActor
extension XCTestCase {
    @discardableResult
    func waitForApplicationSnapshot(
        from keyManager: KeyManager,
        timeout: TimeInterval = 3,
        satisfying predicate: @escaping (RuneScribeApplicationSnapshot) -> Bool
    ) async throws -> RuneScribeApplicationSnapshot {
        if let snapshot = keyManager.snapshot, predicate(snapshot) {
            return snapshot
        }

        let snapshotExpectation = expectation(description: "Application snapshot satisfies predicate")
        var matchingSnapshot: RuneScribeApplicationSnapshot?
        var subscription: AnyCancellable?
        subscription = keyManager.$snapshot.sink { snapshot in
            guard let snapshot, predicate(snapshot), matchingSnapshot == nil else { return }
            matchingSnapshot = snapshot
            snapshotExpectation.fulfill()
            subscription?.cancel()
        }

        await fulfillment(of: [snapshotExpectation], timeout: timeout)
        subscription?.cancel()
        return try XCTUnwrap(matchingSnapshot)
    }
}

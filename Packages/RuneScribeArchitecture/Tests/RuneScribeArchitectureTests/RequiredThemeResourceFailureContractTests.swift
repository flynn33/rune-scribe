import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import XCTest

final class RequiredThemeResourceFailureContractTests: XCTestCase {
    func testEmergencySnapshotDeduplicatesBoundedRequiredBaseFailure() throws {
        let failure = makeFailure()
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let snapshot = try ThemeCoordinatorSnapshotDTO(
            revision: 41,
            capturedAt: Date(timeIntervalSince1970: 1_776_211_202),
            preferredCodexID: RuneScribeCodexIDs.norse,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            fallbackReason: .invalidResources,
            effectiveTheme: descriptor,
            providers: [
                ThemeProviderSummaryDTO(
                    codexID: RuneScribeCodexIDs.norse,
                    moduleID: RuneScribeModuleIDs.norseTheme,
                    displayName: "Norse",
                    state: .invalidResources,
                    isOwned: true,
                    isSelectable: false,
                    isSelected: true
                ),
            ],
            isEmergencyPresentation: true,
            requiredBaseResourceFailures: [failure, failure]
        )

        XCTAssertEqual(snapshot.requiredBaseResourceFailures, [failure])
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            ThemeCoordinatorSnapshotDTO.self,
            from: encoded
        )
        XCTAssertEqual(decoded.requiredBaseResourceFailures, [failure])
    }

    func testDiagnosticsRejectRequiredFailureOutsideEmergencyState() throws {
        let failure = makeFailure()
        XCTAssertThrowsError(
            try ThemeCoordinatorDiagnosticsDTO(
                capturedAt: Date(timeIntervalSince1970: 1_776_211_203),
                contributionRevision: 2,
                resourceRevision: 3,
                preferredCodexID: RuneScribeCodexIDs.norse,
                effectiveCodexID: RuneScribeCodexIDs.norse,
                fallbackReason: .none,
                providers: [],
                requiredBaseResourceFailures: [failure]
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeCoordinatorContractError,
                .invalidRequiredBaseResourceFailure
            )
        }
    }

    func testFailureEncodingContainsOnlyBoundedStructuredValues() throws {
        let failure = makeFailure()
        let encoded = try JSONEncoder().encode(failure)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertLessThan(encoded.count, 2_048)
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("plaintext"))
        XCTAssertTrue(text.contains("resource.background.norse.forge.static"))
        XCTAssertTrue(text.contains("digest-mismatch"))
    }

    private func makeFailure() -> RequiredThemeResourceFailureDTO {
        RequiredThemeResourceFailureDTO(
            moduleID: RuneScribeModuleIDs.norseTheme,
            codexID: RuneScribeCodexIDs.norse,
            stage: .digest,
            resourceID: ThemeResourceID(
                rawValue: "resource.background.norse.forge.static"
            ),
            errorCode: .digestMismatch,
            expectedByteCount: 480_562,
            actualByteCount: 480_562,
            expectedSHA256: ThemeSHA256Digest(
                rawValue: String(repeating: "a", count: 64)
            ),
            actualSHA256: ThemeSHA256Digest(
                rawValue: String(repeating: "b", count: 64)
            ),
            mediaType: .png
        )
    }
}

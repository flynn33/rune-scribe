#if canImport(CloudKit)
import CloudKit
import Foundation
import RuneScribeContracts
@testable import RuneScribePlatform
import XCTest

final class AppleCloudKitProgressionTransportTests: XCTestCase {
    func testAssetPolicyRejectsMissingMalformedAndOversizeInputsBeforeAllocation() {
        let maximum = CloudSyncFetchResultDTO.maximumPayloadByteCount

        XCTAssertEqual(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: false,
                hasFileURL: false,
                isRegularFile: nil,
                fileSize: nil
            ),
            "missing-asset"
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: false,
                isRegularFile: nil,
                fileSize: nil
            ),
            "missing-asset"
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: true,
                isRegularFile: false,
                fileSize: maximum
            ),
            "invalid-asset"
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: true,
                isRegularFile: true,
                fileSize: -1
            ),
            "invalid-asset"
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: true,
                isRegularFile: true,
                fileSize: maximum + 1
            ),
            "oversize-asset"
        )
        XCTAssertNil(
            AppleCloudKitProgressionTransport.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: true,
                isRegularFile: true,
                fileSize: maximum
            )
        )
        XCTAssertLessThan(
            AppleCloudKitProgressionTransport.invalidPayloadMarker("oversize-asset").count,
            maximum
        )
    }

    func testPartialFailurePreservesRateLimitRetryAfterAndPriorityCategories() {
        let now = Date(timeIntervalSince1970: 50_000)
        let limited = cloudError(
            .requestRateLimited,
            userInfo: [CKErrorRetryAfterKey: NSNumber(value: 45)]
        )
        let unavailable = cloudError(.serviceUnavailable)
        let rateLimitedPartial = cloudError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable(CKRecord.ID(recordName: "limited")): limited as Error,
                    AnyHashable(CKRecord.ID(recordName: "unavailable")): unavailable as Error,
                ],
            ]
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.map(rateLimitedPartial, now: now),
            .rateLimited(retryAfter: now.addingTimeInterval(45))
        )

        let account = cloudError(.notAuthenticated)
        let accountPartial = cloudError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable(CKRecord.ID(recordName: "account")): account as Error,
                    AnyHashable(CKRecord.ID(recordName: "limited")): limited as Error,
                ],
            ]
        )
        XCTAssertEqual(
            AppleCloudKitProgressionTransport.map(accountPartial, now: now),
            .accountUnavailable
        )
    }

    func testTemporaryPayloadCleanupIsExplicitAndPropagatesFailure() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/runescribe-cloud-cleanup-test")
        var removedURL: URL?
        try AppleCloudKitProgressionTransport.removeTemporaryPayload(
            at: fileURL,
            fileExists: { _ in true },
            remove: { removedURL = $0 }
        )
        XCTAssertEqual(removedURL, fileURL)

        XCTAssertThrowsError(
            try AppleCloudKitProgressionTransport.removeTemporaryPayload(
                at: fileURL,
                fileExists: { _ in true },
                remove: { _ in throw CleanupFailure.injected }
            )
        ) { error in
            XCTAssertEqual(error as? CleanupFailure, .injected)
        }
    }

    private func cloudError(
        _ code: CKError.Code,
        userInfo: [String: Any] = [:]
    ) -> CKError {
        CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: code.rawValue,
            userInfo: userInfo
        ))
    }
}

private enum CleanupFailure: Error, Equatable {
    case injected
}
#endif

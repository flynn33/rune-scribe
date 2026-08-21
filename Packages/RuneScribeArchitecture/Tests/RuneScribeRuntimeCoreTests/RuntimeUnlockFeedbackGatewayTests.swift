import Foundation
import RuneScribeContracts
@testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeUnlockFeedbackGatewayTests: XCTestCase {
    func testOptionalGatewayReturnsNoClientUntilAdapterIsInstalled() async throws {
        let gateway = RuntimeUnlockFeedbackGateway()
        let lease = ModuleContextLease(moduleID: "com.runescribe.test.feedback-client")

        let absentClient = await gateway.makeClient(lease: lease)

        XCTAssertNil(absentClient)
    }

    func testTypedRequestIsForwardedExactlyOnceAndClientRevokes() async throws {
        let gateway = RuntimeUnlockFeedbackGateway()
        let recorder = UnlockFeedbackRecorder()
        let moduleID: ModuleIdentifier = "com.runescribe.test.feedback-client"
        let lease = ModuleContextLease(moduleID: moduleID)
        try await gateway.install(recorder)
        let installedClient = await gateway.makeClient(lease: lease)
        let client = try XCTUnwrap(installedClient)
        let request = UnlockFeedbackRequestDTO(
            tier: .codex,
            soundEnabled: true,
            hapticEnabled: false
        )

        try await client.perform(request)

        let requests = await recorder.requests()
        XCTAssertEqual(requests, [request])
        await lease.deactivate()
        do {
            try await client.perform(request)
            XCTFail("A stopped module must not retain feedback authority")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .contextInactive(moduleID)
            )
        }
        let requestsAfterRevocation = await recorder.requests()
        XCTAssertEqual(requestsAfterRevocation, [request])
    }

    func testDuplicateAdapterIsRejected() async throws {
        let gateway = RuntimeUnlockFeedbackGateway()
        try await gateway.install(UnlockFeedbackRecorder())

        do {
            try await gateway.install(UnlockFeedbackRecorder())
            XCTFail("Expected one feedback adapter per Runtime")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .duplicateService(RuneScribeUnlockFeedback.serviceID)
            )
        }
    }

    func testSemanticRequestContainsNoRevealIdentityOrUserToken() throws {
        let request = UnlockFeedbackRequestDTO(
            tier: .mastery,
            soundEnabled: true,
            hapticEnabled: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            ["tier", "codexID", "soundEnabled", "hapticEnabled"]
        )
        XCTAssertEqual(request.codexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(request.soundSemanticID, .mastery)
        XCTAssertEqual(request.fallbackResourceID, .mastery)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("reveal"))
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertFalse(encoded.contains("cipher"))
        XCTAssertFalse(encoded.contains("message"))
    }
}

private actor UnlockFeedbackRecorder: UnlockFeedbackProviding {
    private var recorded: [UnlockFeedbackRequestDTO] = []

    func perform(_ request: UnlockFeedbackRequestDTO) async {
        recorded.append(request)
    }

    func requests() -> [UnlockFeedbackRequestDTO] {
        recorded
    }
}

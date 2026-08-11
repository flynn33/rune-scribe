import Foundation
import RuneScribeContracts
import XCTest

final class RuntimeOperationContractTests: XCTestCase {
    private struct CommandPayload: Equatable, Hashable, Sendable {
        let text: String
    }

    private struct QueryPayload: Equatable, Sendable {
        let includeLockedValues: Bool
    }

    private struct IngressPayload: Equatable, Sendable {
        let route: String
    }

    private struct ResponsePayload: Equatable, Sendable {
        let accepted: Bool
    }

    private struct StatePayload: Equatable, Sendable {
        let revision: UInt64
    }

    func testTypedCommandEnvelopeHasImmutableValueSemanticsWithoutCodablePayload() {
        let metadata = makeMetadata(
            operationIdentifier: "runescribe.core.command.encode",
            privacyClass: .sensitiveRedacted,
            idempotencyKey: "encode-once"
        )
        let envelope = RuntimeCommandEnvelope(
            metadata: metadata,
            payload: CommandPayload(text: "ᚠᚢᚦ")
        )
        let copy = envelope

        assertSendable(envelope)
        XCTAssertEqual(copy, envelope)
        XCTAssertEqual(envelope.schemaVersion, "1.0")
        XCTAssertEqual(envelope.operationID, "operation-001")
        XCTAssertEqual(envelope.correlationID, "correlation-001")
        XCTAssertEqual(envelope.sourceModuleID, "com.runescribe.module.ui")
        XCTAssertEqual(envelope.destinationModuleID, "com.runescribe.module.core")
        XCTAssertEqual(envelope.runtimeGeneration, 7)
        XCTAssertEqual(envelope.timestampUTC, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(envelope.commandID, "runescribe.core.command.encode")
        XCTAssertEqual(envelope.privacyClass, .sensitiveRedacted)
        XCTAssertEqual(envelope.idempotencyKey, "encode-once")
        XCTAssertEqual(envelope.payload, CommandPayload(text: "ᚠᚢᚦ"))
    }

    func testQueryAndIngressExposeSchemaSpecificOperationNames() {
        let query = RuntimeQueryEnvelope(
            metadata: makeMetadata(
                operationIdentifier: "runescribe.core.query.snapshot",
                privacyClass: .internalData
            ),
            payload: QueryPayload(includeLockedValues: false)
        )
        let ingress = RuntimeIngressEnvelope(
            metadata: makeMetadata(
                operationIdentifier: "runescribe.host.ingress.url",
                privacyClass: .secretProhibited
            ),
            payload: IngressPayload(route: "runescribe://import")
        )
        let state = RuntimeStateEnvelope(
            metadata: makeMetadata(
                operationIdentifier: "runescribe.core.state.snapshot",
                privacyClass: .sensitiveRedacted
            ),
            payload: StatePayload(revision: 42)
        )

        assertSendable(query)
        assertSendable(ingress)
        assertSendable(state)
        XCTAssertEqual(query.queryID, "runescribe.core.query.snapshot")
        XCTAssertEqual(ingress.inputType, "runescribe.host.ingress.url")
        XCTAssertEqual(state.stateID, "runescribe.core.state.snapshot")
        XCTAssertEqual(state.payload, StatePayload(revision: 42))
        XCTAssertNil(query.idempotencyKey)
        XCTAssertEqual(ingress.privacyClass.rawValue, "secret-prohibited")
        XCTAssertEqual(
            RuntimePrivacyClass.allCases.map(\.rawValue),
            ["public", "internal", "sensitive-redacted", "secret-prohibited"]
        )
    }

    func testEndpointKeyRetainsFullTypedContractAndSeparateUntypedIdentity() {
        let descriptor = RuntimeEndpointDescriptor<CommandPayload, ResponsePayload>(
            endpointID: "runescribe.core.command.encode",
            kind: .command,
            destination: .module("com.runescribe.module.core"),
            requestSchemaVersion: "1.0",
            responseSchemaVersion: "1.1",
            requiredCapability: "application.commands",
            privacyClass: .sensitiveRedacted,
            maximumRequestBytes: 4_096,
            maximumResponseBytes: 8_192
        )
        let sameIdentity = RuntimeEndpointDescriptor<CommandPayload, ResponsePayload>(
            endpointID: "runescribe.core.command.encode",
            kind: .query,
            destination: .role("runescribe.policy.core-domain"),
            requestSchemaVersion: "9.0",
            responseSchemaVersion: "9.0",
            requiredCapability: "application.state.read",
            privacyClass: .internalData,
            maximumRequestBytes: 1,
            maximumResponseBytes: 2
        )

        assertSendable(descriptor)
        XCTAssertEqual(descriptor.kind, .command)
        XCTAssertEqual(descriptor.destination, .module("com.runescribe.module.core"))
        XCTAssertEqual(descriptor.requestSchemaVersion, "1.0")
        XCTAssertEqual(descriptor.responseSchemaVersion, "1.1")
        XCTAssertEqual(descriptor.requiredCapability, "application.commands")
        XCTAssertEqual(descriptor.privacyClass, .sensitiveRedacted)
        XCTAssertEqual(descriptor.maximumRequestBytes, 4_096)
        XCTAssertEqual(descriptor.maximumResponseBytes, 8_192)
        XCTAssertEqual(descriptor.identity.description, "runescribe.core.command.encode")
        XCTAssertEqual(descriptor.key.descriptor, descriptor)
        XCTAssertNotEqual(descriptor.key, sameIdentity.key)
        XCTAssertEqual(Set([descriptor.key, sameIdentity.key]).count, 2)
        XCTAssertEqual(descriptor.key.identity, sameIdentity.key.identity)
    }

    func testStateEndpointUsesExplicitTypedSubscriptionDescriptor() {
        let descriptor = RuntimeStateEndpointDescriptor<StatePayload>(
            endpointID: "runescribe.core.state.snapshot",
            destination: .role("runescribe.policy.core-domain"),
            subscriptionSchemaVersion: "1.0",
            stateSchemaVersion: "2.0",
            requiredCapability: "runtime.state.observe",
            privacyClass: .internalData,
            maximumSubscriptionBytes: 128,
            maximumStateBytes: 65_536,
            bufferingPolicy: .bufferingOldest(16)
        )

        assertSendable(descriptor)
        XCTAssertEqual(descriptor.endpoint.kind, .state)
        XCTAssertEqual(descriptor.destination, .role("runescribe.policy.core-domain"))
        XCTAssertEqual(descriptor.subscriptionSchemaVersion, "1.0")
        XCTAssertEqual(descriptor.stateSchemaVersion, "2.0")
        XCTAssertEqual(descriptor.requiredCapability, "runtime.state.observe")
        XCTAssertEqual(descriptor.privacyClass, .internalData)
        XCTAssertEqual(descriptor.maximumSubscriptionBytes, 128)
        XCTAssertEqual(descriptor.bufferingPolicy, .bufferingOldest(16))
        XCTAssertEqual(descriptor.maximumStateBytes, 65_536)
        XCTAssertEqual(descriptor.key.identity, descriptor.identity)
    }

    private func makeMetadata(
        operationIdentifier: RuntimeOperationIdentifier,
        privacyClass: RuntimePrivacyClass,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) -> RuntimeOperationMetadata {
        RuntimeOperationMetadata(
            schemaVersion: RuntimeSchemaVersions.v1,
            operationID: "operation-001",
            correlationID: "correlation-001",
            sourceModuleID: "com.runescribe.module.ui",
            destinationModuleID: "com.runescribe.module.core",
            runtimeGeneration: 7,
            timestampUTC: Date(timeIntervalSince1970: 1_700_000_000),
            operationIdentifier: operationIdentifier,
            privacyClass: privacyClass,
            idempotencyKey: idempotencyKey
        )
    }

    private func assertSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}

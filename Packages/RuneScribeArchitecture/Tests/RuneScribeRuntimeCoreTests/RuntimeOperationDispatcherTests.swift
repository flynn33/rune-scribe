import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeOperationDispatcherTests: XCTestCase {
    func testTRT001AuthorizedCommandIsMediatedAndLedgered() async throws {
        let harness = try await makeHarness { value in "reply:\(value)" }

        let result = try await harness.client.send("hello", to: harness.key)

        XCTAssertEqual(result, "reply:hello")
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .succeeded)
        XCTAssertEqual(ledger[0].requestByteCount, 5)
        XCTAssertEqual(ledger[0].responseByteCount, 11)
        XCTAssertNotNil(ledger[0].completedAtUTC)
        XCTAssertEqual(ledger[0].metadata.sourceModuleID, harness.sourceID)
        XCTAssertEqual(ledger[0].metadata.destinationModuleID, harness.providerID)
    }

    func testLedgerUsesRuntimeStampedBoundedMetadata() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let environment = RuntimeEnvironment(now: { date }, nextUUID: { uuid })
        let harness = try await makeHarness(environment: environment) { $0 }

        _ = try await harness.client.send(
            "hello",
            to: harness.key,
            idempotencyKey: "caller-secret"
        )

        let ledger = await harness.dispatcher.ledgerSnapshot()
        let record = try XCTUnwrap(ledger.last)
        XCTAssertEqual(record.metadata.schemaVersion, RuntimeSchemaVersions.v1)
        XCTAssertEqual(
            record.metadata.operationID,
            "11111111-2222-3333-4444-555555555555-1"
        )
        XCTAssertEqual(
            record.metadata.correlationID,
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(record.metadata.sourceModuleID, harness.sourceID)
        XCTAssertEqual(record.metadata.destinationModuleID, harness.providerID)
        XCTAssertEqual(record.metadata.runtimeGeneration, 1)
        XCTAssertEqual(record.metadata.timestampUTC, date)
        XCTAssertEqual(
            record.metadata.operationIdentifier,
            RuntimeOperationIdentifier(harness.key.descriptor.endpointID.rawValue)
        )
        XCTAssertEqual(record.metadata.privacyClass, .internalData)
        XCTAssertNil(record.metadata.idempotencyKey)
        XCTAssertTrue(record.hadIdempotencyKey)
        XCTAssertEqual(record.requestByteCount, 5)
        XCTAssertEqual(record.responseByteCount, 5)
        XCTAssertEqual(record.completedAtUTC, date)
        XCTAssertEqual(record.outcome, .succeeded)
    }

    func testTRT002UnauthorizedAndUndeclaredSourcesFailClosed() async throws {
        let unauthorized = try await makeHarness(sourceCapabilities: []) { $0 }
        let capabilityError = await runtimeError {
            _ = try await unauthorized.client.send("denied", to: unauthorized.key)
        }
        XCTAssertEqual(
            capabilityError,
            .capabilityDenied(
                moduleID: unauthorized.sourceID,
                capability: RuneScribeCapabilities.applicationCommands
            )
        )

        let undeclared = try await makeHarness(sourceDeclaresEndpoint: false) { $0 }
        let declarationError = await runtimeError {
            _ = try await undeclared.client.send("denied", to: undeclared.key)
        }
        XCTAssertEqual(
            declarationError,
            .endpointNotDeclared(
                moduleID: undeclared.sourceID,
                endpoint: undeclared.key.descriptor.endpointID
            )
        )
    }

    func testEveryRejectedAttemptCreatesOneCompletedClassifiedLedgerRow() async throws {
        let inactiveSourceCounter = RuntimeInvocationCounter()
        let inactiveSource = try await makeHarness { value in
            await inactiveSourceCounter.record(); return value
        }
        let inactiveSourceGeneration = try await inactiveSource.dispatcher.beginActivation(
            moduleID: inactiveSource.sourceID
        )
        let inactiveSourceLease = RuntimeClientLease(
            runtimeGeneration: 1,
            sourceModuleID: inactiveSource.sourceID,
            sourceGeneration: inactiveSourceGeneration,
            destinationModuleID: inactiveSource.providerID,
            destinationGeneration: inactiveSource.providerGeneration
        )
        let inactiveSourceClient = RuntimeCommandClient(
            dispatcher: inactiveSource.dispatcher,
            lease: inactiveSourceLease
        )
        await assertSingleRejectedCall(
            dispatcher: inactiveSource.dispatcher,
            expectedError: .moduleNotActive(inactiveSource.sourceID),
            expectedOutcome: .denied(.inactiveSource),
            counter: inactiveSourceCounter
        ) { _ = try await inactiveSourceClient.send("x", to: inactiveSource.key) }

        let inactiveDestinationCounter = RuntimeInvocationCounter()
        let inactiveDestination = try await makeHarness { value in
            await inactiveDestinationCounter.record(); return value
        }
        let inactiveDestinationGeneration = try await inactiveDestination.dispatcher.beginActivation(
            moduleID: inactiveDestination.providerID
        )
        let inactiveDestinationLease = RuntimeClientLease(
            runtimeGeneration: 1,
            sourceModuleID: inactiveDestination.sourceID,
            sourceGeneration: inactiveDestination.sourceGeneration,
            destinationModuleID: inactiveDestination.providerID,
            destinationGeneration: inactiveDestinationGeneration
        )
        let inactiveDestinationClient = RuntimeCommandClient(
            dispatcher: inactiveDestination.dispatcher,
            lease: inactiveDestinationLease
        )
        await assertSingleRejectedCall(
            dispatcher: inactiveDestination.dispatcher,
            expectedError: .moduleNotActive(inactiveDestination.providerID),
            expectedOutcome: .denied(.inactiveDestination),
            counter: inactiveDestinationCounter
        ) { _ = try await inactiveDestinationClient.send("x", to: inactiveDestination.key) }

        let undeclaredSourceCounter = RuntimeInvocationCounter()
        let undeclaredSource = try await makeHarness(sourceDeclaresEndpoint: false) { value in
            await undeclaredSourceCounter.record(); return value
        }
        await assertSingleRejectedCall(
            dispatcher: undeclaredSource.dispatcher,
            expectedError: .endpointNotDeclared(
                moduleID: undeclaredSource.sourceID,
                endpoint: undeclaredSource.key.descriptor.endpointID
            ),
            expectedOutcome: .denied(.undeclaredSource),
            counter: undeclaredSourceCounter
        ) { _ = try await undeclaredSource.client.send("x", to: undeclaredSource.key) }

        let undeclaredDestinationCounter = RuntimeInvocationCounter()
        let undeclaredDestination = try await makeHarness { value in
            await undeclaredDestinationCounter.record(); return value
        }
        await undeclaredDestination.dispatcher.replaceDeclarations(
            moduleID: undeclaredDestination.providerID,
            consumed: [],
            published: []
        )
        await assertSingleRejectedCall(
            dispatcher: undeclaredDestination.dispatcher,
            expectedError: .endpointNotDeclared(
                moduleID: undeclaredDestination.providerID,
                endpoint: undeclaredDestination.key.descriptor.endpointID
            ),
            expectedOutcome: .denied(.undeclaredDestination),
            counter: undeclaredDestinationCounter
        ) { _ = try await undeclaredDestination.client.send("x", to: undeclaredDestination.key) }

        let capabilityCounter = RuntimeInvocationCounter()
        let capability = try await makeHarness(sourceCapabilities: []) { value in
            await capabilityCounter.record(); return value
        }
        await assertSingleRejectedCall(
            dispatcher: capability.dispatcher,
            expectedError: .capabilityDenied(
                moduleID: capability.sourceID,
                capability: RuneScribeCapabilities.applicationCommands
            ),
            expectedOutcome: .denied(.capabilityDenied),
            counter: capabilityCounter
        ) { _ = try await capability.client.send("x", to: capability.key) }

        let policyCounter = RuntimeInvocationCounter()
        let deniedRole: ModuleRole = "test.policy-denied-role"
        let policyDenied = try await makeHarness(sourceRole: deniedRole) { value in
            await policyCounter.record(); return value
        }
        await assertSingleRejectedCall(
            dispatcher: policyDenied.dispatcher,
            expectedError: .capabilityDenied(
                moduleID: policyDenied.sourceID,
                capability: RuneScribeCapabilities.applicationCommands
            ),
            expectedOutcome: .denied(.capabilityDenied),
            counter: policyCounter
        ) { _ = try await policyDenied.client.send("x", to: policyDenied.key) }

        let missingCounter = RuntimeInvocationCounter()
        let missing = try await makeHarness { value in
            await missingCounter.record(); return value
        }
        let missingID: RuntimeEndpointIdentifier = "test.command.missing"
        await missing.dispatcher.replaceDeclarations(
            moduleID: missing.sourceID,
            consumed: [missingID],
            published: []
        )
        await missing.dispatcher.replaceDeclarations(
            moduleID: missing.providerID,
            consumed: [],
            published: [missingID]
        )
        let missingKey = RuntimeEndpointDescriptor<String, String>(
            endpointID: missingID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024
        ).key
        await assertSingleRejectedCall(
            dispatcher: missing.dispatcher,
            expectedError: .endpointUnavailable(missingID),
            expectedOutcome: .denied(.endpointUnavailable),
            counter: missingCounter
        ) { _ = try await missing.client.send("x", to: missingKey) }

        let kindCounter = RuntimeInvocationCounter()
        let wrongKind = try await makeHarness { value in
            await kindCounter.record(); return value
        }
        let queryClient = RuntimeQueryClient(
            dispatcher: wrongKind.dispatcher,
            lease: wrongKind.lease
        )
        await assertSingleRejectedCall(
            dispatcher: wrongKind.dispatcher,
            expectedError: .endpointKindMismatch(
                endpoint: wrongKind.key.descriptor.endpointID,
                expected: .query,
                actual: .command
            ),
            expectedOutcome: .denied(.kindMismatch),
            counter: kindCounter
        ) { _ = try await queryClient.fetch("x", from: wrongKind.key) }

        let typeCounter = RuntimeInvocationCounter()
        let wrongType = try await makeHarness { value in
            await typeCounter.record(); return value
        }
        let wrongTypeKey = RuntimeEndpointDescriptor<Int, Int>(
            endpointID: wrongType.key.descriptor.endpointID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024
        ).key
        await assertSingleRejectedCall(
            dispatcher: wrongType.dispatcher,
            expectedError: .endpointTypeMismatch(wrongType.key.descriptor.endpointID),
            expectedOutcome: .denied(.typeMismatch),
            counter: typeCounter
        ) { _ = try await wrongType.client.send(1, to: wrongTypeKey) }

        let descriptorCounter = RuntimeInvocationCounter()
        let descriptorDrift = try await makeHarness { value in
            await descriptorCounter.record(); return value
        }
        let driftedKey = RuntimeEndpointDescriptor<String, String>(
            endpointID: descriptorDrift.key.descriptor.endpointID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .publicData,
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024
        ).key
        await assertSingleRejectedCall(
            dispatcher: descriptorDrift.dispatcher,
            expectedError: .endpointDescriptorMismatch(descriptorDrift.key.descriptor.endpointID),
            expectedOutcome: .denied(.descriptorMismatch),
            counter: descriptorCounter
        ) { _ = try await descriptorDrift.client.send("x", to: driftedKey) }

        let schemaCounter = RuntimeInvocationCounter()
        let schema = try await makeHarness { value in
            await schemaCounter.record(); return value
        }
        await assertSingleRejectedCall(
            dispatcher: schema.dispatcher,
            expectedError: .operationSchemaMismatch(
                endpoint: schema.key.descriptor.endpointID,
                expected: RuntimeSchemaVersions.v1,
                actual: "2.0"
            ),
            expectedOutcome: .denied(.schemaMismatch),
            counter: schemaCounter
        ) {
            _ = try await schema.client.send(
                "x",
                to: schema.key,
                requestSchemaVersion: "2.0"
            )
        }

        let requestCounter = RuntimeInvocationCounter()
        let requestBound = try await makeHarness(maximumRequestBytes: 1) { value in
            await requestCounter.record(); return value
        }
        await assertSingleRejectedCall(
            dispatcher: requestBound.dispatcher,
            expectedError: .operationRequestTooLarge(
                endpoint: requestBound.key.descriptor.endpointID,
                maximumBytes: 1
            ),
            expectedOutcome: .denied(.requestTooLarge),
            counter: requestCounter
        ) { _ = try await requestBound.client.send("xx", to: requestBound.key) }

        let stoppedCounter = RuntimeInvocationCounter()
        let stopped = try await makeHarness { value in
            await stoppedCounter.record(); return value
        }
        await stopped.dispatcher.beginRuntimeStop()
        await assertSingleRejectedCall(
            dispatcher: stopped.dispatcher,
            expectedError: .runtimeNotRunning,
            expectedOutcome: .denied(.runtimeUnavailable),
            counter: stoppedCounter
        ) { _ = try await stopped.client.send("x", to: stopped.key) }

        let staleSourceCounter = RuntimeInvocationCounter()
        let staleSource = try await makeHarness { value in
            await staleSourceCounter.record(); return value
        }
        _ = try await staleSource.dispatcher.beginActivation(moduleID: staleSource.sourceID)
        await assertSingleRejectedCall(
            dispatcher: staleSource.dispatcher,
            expectedError: .staleClient(staleSource.sourceID),
            expectedOutcome: .denied(.staleClient),
            counter: staleSourceCounter
        ) { _ = try await staleSource.client.send("x", to: staleSource.key) }

        let staleDestinationCounter = RuntimeInvocationCounter()
        let staleDestination = try await makeHarness { value in
            await staleDestinationCounter.record(); return value
        }
        _ = try await staleDestination.dispatcher.beginActivation(
            moduleID: staleDestination.providerID
        )
        await assertSingleRejectedCall(
            dispatcher: staleDestination.dispatcher,
            expectedError: .staleClient(staleDestination.providerID),
            expectedOutcome: .denied(.staleClient),
            counter: staleDestinationCounter
        ) { _ = try await staleDestination.client.send("x", to: staleDestination.key) }
    }

    func testStoppedClientFailsBeforeEndpointLookup() async throws {
        let harness = try await makeHarness { $0 }
        await harness.dispatcher.beginRuntimeStop()

        let error = await runtimeError {
            _ = try await harness.client.send("stopped", to: harness.key)
        }

        XCTAssertEqual(error, .runtimeNotRunning)
    }

    func testSourceInvalidationMakesRetainedClientStale() async throws {
        let harness = try await makeHarness { $0 }
        await harness.dispatcher.invalidateModule(moduleID: harness.sourceID)

        let error = await runtimeError {
            _ = try await harness.client.send("stale", to: harness.key)
        }

        XCTAssertEqual(error, .staleClient(harness.sourceID))
    }

    func testProviderInvalidationMakesRetainedClientStale() async throws {
        let harness = try await makeHarness { $0 }
        await harness.dispatcher.invalidateModule(moduleID: harness.providerID)

        let error = await runtimeError {
            _ = try await harness.client.send("stale", to: harness.key)
        }

        XCTAssertEqual(error, .staleClient(harness.providerID))
    }

    func testProviderInvalidationWhileInFlightDiscardsResultAndFinalizesLedgerAsStale() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { value in
            await barrier.suspend()
            return value
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        await harness.dispatcher.invalidateModule(moduleID: harness.providerID)
        await barrier.releaseAll()

        let error = await runtimeError { _ = try await operation.value }
        XCTAssertEqual(error, .staleClient(harness.providerID))
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .denied(.staleClient))
        XCTAssertNotNil(ledger[0].completedAtUTC)
    }

    func testRuntimeRestartMakesPriorGenerationClientStale() async throws {
        let harness = try await makeHarness { $0 }
        await harness.dispatcher.beginRuntimeStop()
        _ = await harness.dispatcher.beginRuntimeStart()
        await harness.dispatcher.markRuntimeRunning()

        let error = await runtimeError {
            _ = try await harness.client.send("stale", to: harness.key)
        }

        XCTAssertEqual(error, .staleClient(harness.sourceID))
    }

    func testResponseSchemaOverrideIsDeniedBeforeHandler() async throws {
        let counter = RuntimeInvocationCounter()
        let harness = try await makeHarness { value in
            await counter.record(); return value
        }

        await assertSingleRejectedCall(
            dispatcher: harness.dispatcher,
            expectedError: .operationSchemaMismatch(
                endpoint: harness.key.descriptor.endpointID,
                expected: RuntimeSchemaVersions.v1,
                actual: "2.0"
            ),
            expectedOutcome: .denied(.schemaMismatch),
            counter: counter
        ) {
            _ = try await harness.client.send(
                "value",
                to: harness.key,
                responseSchemaVersion: "2.0"
            )
        }
    }

    func testNoEligibleDestinationReturnsBoundedTypedFailure() async throws {
        let dispatcher = RuntimeOperationDispatcher(policy: .patternBFoundation, environment: .live)
        let sourceID: ModuleIdentifier = "test.destination.source"
        await dispatcher.registerModule(
            testDescriptor(
                id: sourceID,
                role: RuneScribeRoles.primaryUI,
                capabilities: [RuneScribeCapabilities.applicationCommands]
            )
        )
        _ = await dispatcher.beginRuntimeStart()
        let generation = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(moduleID: sourceID, generation: generation)
        await dispatcher.markRuntimeRunning()

        do {
            _ = try await dispatcher.makeLease(
                sourceModuleID: sourceID,
                sourceGeneration: generation,
                destination: .role(RuneScribeRoles.core)
            )
            XCTFail("Expected a bounded unavailable-destination error.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .messageDestinationUnavailable(RuneScribeRoles.core)
            )
        }
    }

    func testRuntimeIngressClientMediatesAndLedgersAcceptedInput() async throws {
        let dispatcher = RuntimeOperationDispatcher(policy: .patternBFoundation, environment: .live)
        let providerID: ModuleIdentifier = "test.ingress.provider"
        let sourceID: ModuleIdentifier = "test.ingress.host"
        let endpointID: RuntimeEndpointIdentifier = "test.ingress.submit"
        let key = RuntimeEndpointDescriptor<String, String>(
            endpointID: endpointID,
            kind: .ingress,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.inboundInput,
            privacyClass: .sensitiveRedacted,
            maximumRequestBytes: 64,
            maximumResponseBytes: 64
        ).key
        await dispatcher.registerModule(
            testDescriptor(
                id: providerID,
                role: RuneScribeRoles.core,
                capabilities: [],
                published: [endpointID]
            )
        )
        await dispatcher.registerModule(
            testDescriptor(
                id: sourceID,
                role: RuneScribeRoles.applicationHost,
                capabilities: [RuneScribeCapabilities.inboundInput],
                consumed: [endpointID]
            )
        )
        _ = await dispatcher.beginRuntimeStart()
        let providerGeneration = try await dispatcher.beginActivation(moduleID: providerID)
        try await dispatcher.registerEndpoint(
            ownerModuleID: providerID,
            ownerGeneration: providerGeneration,
            key: key,
            handler: { _, value in "accepted:\(value)" }
        )
        try await dispatcher.markActive(moduleID: providerID, generation: providerGeneration)
        let sourceGeneration = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(moduleID: sourceID, generation: sourceGeneration)
        await dispatcher.markRuntimeRunning()
        let lease = try await dispatcher.makeLease(
            sourceModuleID: sourceID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.core)
        )
        let client = RuntimeIngressClient(dispatcher: dispatcher, lease: lease)

        let result = try await client.submit("input", to: key)

        XCTAssertEqual(result, "accepted:input")
        let ledger = await dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].endpointKind, .ingress)
        XCTAssertEqual(ledger[0].outcome, .succeeded)
    }

    func testProviderCannotRegisterUndeclaredEndpoint() async throws {
        let dispatcher = RuntimeOperationDispatcher(policy: .patternBFoundation, environment: .live)
        let providerID: ModuleIdentifier = "test.undeclared.provider"
        let endpoint = RuntimeEndpointDescriptor<String, String>(
            endpointID: "test.undeclared.endpoint",
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 16,
            maximumResponseBytes: 16
        ).key
        await dispatcher.registerModule(
            testDescriptor(
                id: providerID,
                role: RuneScribeRoles.core,
                capabilities: []
            )
        )
        _ = await dispatcher.beginRuntimeStart()
        let generation = try await dispatcher.beginActivation(moduleID: providerID)

        do {
            try await dispatcher.registerEndpoint(
                ownerModuleID: providerID,
                ownerGeneration: generation,
                key: endpoint,
                handler: { _, value in value }
            )
            XCTFail("Expected undeclared publisher endpoint rejection.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .endpointNotDeclared(
                    moduleID: providerID,
                    endpoint: endpoint.descriptor.endpointID
                )
            )
        }
    }

    func testWrongSchemaTypeDescriptorAndOversizedRequestFailClosed() async throws {
        let harness = try await makeHarness(maximumRequestBytes: 4) { $0 }
        let schemaError = await runtimeError {
            _ = try await harness.client.send(
                "ok",
                to: harness.key,
                requestSchemaVersion: "2.0"
            )
        }
        XCTAssertEqual(
            schemaError,
            .operationSchemaMismatch(
                endpoint: harness.key.descriptor.endpointID,
                expected: RuntimeSchemaVersions.v1,
                actual: "2.0"
            )
        )

        let oversizedError = await runtimeError {
            _ = try await harness.client.send("12345", to: harness.key)
        }
        XCTAssertEqual(
            oversizedError,
            .operationRequestTooLarge(
                endpoint: harness.key.descriptor.endpointID,
                maximumBytes: 4
            )
        )

        let drifted = RuntimeEndpointDescriptor<String, String>(
            endpointID: harness.key.descriptor.endpointID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .publicData,
            maximumRequestBytes: 4,
            maximumResponseBytes: 1_024
        ).key
        let descriptorError = await runtimeError {
            _ = try await harness.client.send("ok", to: drifted)
        }
        XCTAssertEqual(
            descriptorError,
            .endpointDescriptorMismatch(harness.key.descriptor.endpointID)
        )

        let wrongType = RuntimeEndpointDescriptor<Int, Int>(
            endpointID: harness.key.descriptor.endpointID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 4,
            maximumResponseBytes: 1_024
        ).key
        let typeError = await runtimeError {
            _ = try await harness.client.send(1, to: wrongType)
        }
        XCTAssertEqual(
            typeError,
            .endpointTypeMismatch(harness.key.descriptor.endpointID)
        )

        let oversizedResponse = try await makeHarness { _ in
            String(repeating: "x", count: 1_025)
        }
        let responseError = await runtimeError {
            _ = try await oversizedResponse.client.send("ok", to: oversizedResponse.key)
        }
        XCTAssertEqual(
            responseError,
            .operationResponseTooLarge(
                endpoint: oversizedResponse.key.descriptor.endpointID,
                maximumBytes: 1_024
            )
        )
        let responseLedger = await oversizedResponse.dispatcher.ledgerSnapshot()
        XCTAssertEqual(responseLedger.count, 1)
        XCTAssertEqual(responseLedger[0].outcome, .failed(.responseTooLarge))
        XCTAssertEqual(responseLedger[0].responseByteCount, 1_025)
        XCTAssertNotNil(responseLedger[0].completedAtUTC)
    }

    func testHandlerFailureCreatesOneCompletedFailureLedgerRow() async throws {
        let harness = try await makeHarness { _ in
            throw RuntimeTestHandlerError.expected
        }

        do {
            _ = try await harness.client.send("request", to: harness.key)
            XCTFail("Expected the handler failure.")
        } catch RuntimeTestHandlerError.expected {
            // Expected provider failure after all runtime checks passed.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].requestByteCount, 7)
        XCTAssertNil(ledger[0].responseByteCount)
        XCTAssertEqual(ledger[0].outcome, .failed(.handlerFailure))
        XCTAssertNotNil(ledger[0].completedAtUTC)
    }

    func testTRT003ReplacementInvalidatesOldClientAndNewClientUsesNewHandler() async throws {
        let harness = try await makeHarness { "old:\($0)" }

        let replacementGeneration = try await harness.dispatcher.beginActivation(
            moduleID: harness.providerID
        )
        try await harness.dispatcher.registerEndpoint(
            ownerModuleID: harness.providerID,
            ownerGeneration: replacementGeneration,
            key: harness.key,
            handler: { _, value in "new:\(value)" }
        )
        try await harness.dispatcher.markActive(
            moduleID: harness.providerID,
            generation: replacementGeneration
        )

        let oldError = await runtimeError {
            _ = try await harness.client.send("value", to: harness.key)
        }
        XCTAssertEqual(oldError, .staleClient(harness.providerID))

        let newLease = try await harness.dispatcher.makeLease(
            sourceModuleID: harness.sourceID,
            sourceGeneration: harness.sourceGeneration,
            destination: .role(RuneScribeRoles.core)
        )
        let newClient = RuntimeCommandClient(
            dispatcher: harness.dispatcher,
            lease: newLease
        )
        let newValue = try await newClient.send("value", to: harness.key)
        XCTAssertEqual(newValue, "new:value")
    }

    func testStopWhileInFlightDiscardsHandlerResultAfterAwait() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { value in
            await barrier.suspend()
            return value
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        await harness.dispatcher.beginRuntimeStop()
        await barrier.releaseAll()

        let error = await runtimeError { _ = try await operation.value }
        XCTAssertEqual(error, .runtimeNotRunning)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.last?.outcome, .denied(.runtimeUnavailable))
    }

    func testReplacementWhileInFlightDiscardsStaleResultAfterAwait() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { value in
            await barrier.suspend()
            return value
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        let replacementGeneration = try await harness.dispatcher.beginActivation(
            moduleID: harness.providerID
        )
        try await harness.dispatcher.registerEndpoint(
            ownerModuleID: harness.providerID,
            ownerGeneration: replacementGeneration,
            key: harness.key,
            handler: { _, value in "replacement:\(value)" }
        )
        try await harness.dispatcher.markActive(
            moduleID: harness.providerID,
            generation: replacementGeneration
        )
        await barrier.releaseAll()

        let error = await runtimeError { _ = try await operation.value }
        XCTAssertEqual(error, .staleClient(harness.providerID))
    }

    func testStopWhileInFlightReplacesLateHandlerFailureWithRuntimeFailure() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { _ in
            await barrier.suspend()
            throw RuntimeTestHandlerError.expected
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        await harness.dispatcher.beginRuntimeStop()
        await barrier.releaseAll()

        let error = await runtimeError { _ = try await operation.value }
        XCTAssertEqual(error, .runtimeNotRunning)
    }

    func testCooperativeInFlightCancellationCreatesOneCancelledLedgerRow() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { value in
            await barrier.suspend()
            try Task.checkCancellation()
            return value
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        await harness.dispatcher.beginRuntimeStop()
        await barrier.releaseAll()

        do {
            _ = try await operation.value
            XCTFail("Expected cooperative cancellation.")
        } catch let error as RuneScribeRuntimeError {
            if case .operationCancelled = error {} else {
                XCTFail("Unexpected runtime error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .cancelled)
        XCTAssertNotNil(ledger[0].completedAtUTC)
    }

    func testReplacementWhileInFlightReplacesLateHandlerFailureWithStaleFailure() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { _ in
            await barrier.suspend()
            throw RuntimeTestHandlerError.expected
        }
        let operation = Task {
            try await harness.client.send("blocked", to: harness.key)
        }
        await barrier.waitForArrivals(1)

        _ = try await harness.dispatcher.beginActivation(moduleID: harness.providerID)
        await barrier.releaseAll()

        let error = await runtimeError { _ = try await operation.value }
        XCTAssertEqual(error, .staleClient(harness.providerID))
    }

    func testTRT014LedgerNeverRetainsPayloadResultOrIdempotencySecret() async throws {
        let sentinel = "SENTINEL-SECRET-DO-NOT-RETAIN"
        let harness = try await makeHarness { _ in sentinel }

        _ = try await harness.client.send(
            sentinel,
            to: harness.key,
            idempotencyKey: RuntimeIdempotencyKey(sentinel)
        )

        let ledger = await harness.dispatcher.ledgerSnapshot()
        let record = try XCTUnwrap(ledger.last)
        XCTAssertTrue(record.hadIdempotencyKey)
        XCTAssertNil(record.metadata.idempotencyKey)
        XCTAssertFalse(String(reflecting: ledger).contains(sentinel))
        XCTAssertEqual(record.requestByteCount, UInt64(sentinel.utf8.count))
        XCTAssertEqual(record.responseByteCount, UInt64(sentinel.utf8.count))
    }

    func testLedgerEvictsOldestRecordsAtDeterministicBound() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let environment = RuntimeEnvironment(now: { date }, nextUUID: { uuid })
        let harness = try await makeHarness(environment: environment) { $0 }

        for index in 0...RuntimeOperationDispatcher.maximumLedgerRecords {
            _ = try await harness.client.send("\(index)", to: harness.key)
        }

        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, RuntimeOperationDispatcher.maximumLedgerRecords)
        XCTAssertTrue(ledger.allSatisfy { $0.outcome == .succeeded })
        XCTAssertTrue(ledger.allSatisfy { $0.completedAtUTC == date })
        XCTAssertEqual(Set(ledger.map(\.metadata.operationID)).count, ledger.count)
        XCTAssertTrue(ledger.first?.metadata.operationID.rawValue.hasSuffix("-2") == true)
        XCTAssertTrue(
            ledger.last?.metadata.operationID.rawValue.hasSuffix("-4097") == true
        )
    }

    func testStateRelayIsRuntimeOwnedAndFinishesOnProviderInvalidation() async throws {
        let dispatcher = RuntimeOperationDispatcher(
            policy: .patternBFoundation,
            environment: .live
        )
        let providerID: ModuleIdentifier = "test.state.provider"
        let sourceID: ModuleIdentifier = "test.state.source"
        let endpointID: RuntimeEndpointIdentifier = "test.state.snapshot"
        let descriptor = RuntimeStateEndpointDescriptor<String>(
            endpointID: endpointID,
            destination: .role(RuneScribeRoles.core),
            subscriptionSchemaVersion: RuntimeSchemaVersions.v1,
            stateSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationStateRead,
            privacyClass: .internalData,
            maximumSubscriptionBytes: 0,
            maximumStateBytes: 64
        )
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        await dispatcher.registerModule(
            testDescriptor(
                id: providerID,
                role: RuneScribeRoles.core,
                capabilities: [],
                published: [endpointID]
            )
        )
        await dispatcher.registerModule(
            testDescriptor(
                id: sourceID,
                role: RuneScribeRoles.primaryUI,
                capabilities: [RuneScribeCapabilities.applicationStateRead],
                consumed: [endpointID]
            )
        )
        _ = await dispatcher.beginRuntimeStart()
        let providerGeneration = try await dispatcher.beginActivation(moduleID: providerID)
        try await dispatcher.registerStateEndpoint(
            ownerModuleID: providerID,
            ownerGeneration: providerGeneration,
            descriptor: descriptor,
            handler: { _ in providerStream }
        )
        try await dispatcher.markActive(moduleID: providerID, generation: providerGeneration)
        let sourceGeneration = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(moduleID: sourceID, generation: sourceGeneration)
        await dispatcher.markRuntimeRunning()
        let lease = try await dispatcher.makeLease(
            sourceModuleID: sourceID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.core)
        )
        let client = RuntimeStateClient(dispatcher: dispatcher, lease: lease)
        let relay = try await client.subscribe(to: descriptor)
        var iterator = relay.makeAsyncIterator()

        providerContinuation.yield("snapshot")
        let first = await iterator.next()
        XCTAssertEqual(first?.payload, "snapshot")
        await dispatcher.invalidateModule(moduleID: providerID)
        let finished = await iterator.next()
        XCTAssertNil(finished)
        let ledger = await dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .cancelled)
        XCTAssertEqual(ledger[0].responseByteCount, 8)
        XCTAssertNotNil(ledger[0].completedAtUTC)
        providerContinuation.finish()
    }

    func testStateRelaySuppressesLateValueWhenProviderInvalidationWinsDeliveryRace() async throws {
        let barrier = RuntimeTestBarrier()
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let harness = try await makeStateHarness(
            beforeStateDelivery: { await barrier.suspend() }
        ) { _ in
            providerStream
        }
        let relay = try await harness.client.subscribe(to: harness.descriptor)
        let nextValue = Task {
            var iterator = relay.makeAsyncIterator()
            return await iterator.next()
        }

        providerContinuation.yield("late")
        await barrier.waitForArrivals(1)
        await harness.dispatcher.invalidateModule(moduleID: harness.providerID)
        await barrier.releaseAll()

        let deliveredAfterInvalidation = await nextValue.value
        XCTAssertNil(deliveredAfterInvalidation)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .cancelled)
        providerContinuation.finish()
    }

    func testStateRelayPurgesUnreadBufferedValueAfterProviderInvalidation() async throws {
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let harness = try await makeStateHarness { _ in providerStream }
        let relay = try await harness.client.subscribe(to: harness.descriptor)

        providerContinuation.yield("unread")
        var buffered = false
        for _ in 0..<1_000 {
            let ledger = await harness.dispatcher.ledgerSnapshot()
            buffered = ledger.first?.responseByteCount == 6
            if buffered { break }
            await Task.yield()
        }
        XCTAssertTrue(buffered)

        await harness.dispatcher.invalidateModule(moduleID: harness.providerID)
        var iterator = relay.makeAsyncIterator()
        let staleBufferedValue = await iterator.next()

        XCTAssertNil(staleBufferedValue)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.first?.outcome, .cancelled)
        providerContinuation.finish()
    }

    func testStateSubscriptionSchemaMismatchIsDeniedBeforeProviderStreamCreation() async throws {
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let counter = RuntimeSynchronousInvocationCounter()
        let harness = try await makeStateHarness { _ in
            counter.record()
            return providerStream
        }

        let error = await runtimeError {
            _ = try await harness.client.subscribe(
                to: harness.descriptor,
                stateSchemaVersion: "2.0"
            )
        }

        XCTAssertEqual(
            error,
            .operationSchemaMismatch(
                endpoint: harness.descriptor.endpointID,
                expected: RuntimeSchemaVersions.v1,
                actual: "2.0"
            )
        )
        XCTAssertEqual(counter.value(), 0)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .denied(.schemaMismatch))
        XCTAssertNotNil(ledger[0].completedAtUTC)
        providerContinuation.finish()
    }

    func testStateRelayRejectsClientBufferingPolicyDriftBeforeProviderStreamCreation() async throws {
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let counter = RuntimeSynchronousInvocationCounter()
        let harness = try await makeStateHarness { _ in
            counter.record()
            return providerStream
        }
        let descriptor = RuntimeStateEndpointDescriptor<String>(
            endpointID: harness.descriptor.endpointID,
            destination: harness.descriptor.destination,
            subscriptionSchemaVersion: harness.descriptor.subscriptionSchemaVersion,
            stateSchemaVersion: harness.descriptor.stateSchemaVersion,
            requiredCapability: harness.descriptor.requiredCapability,
            privacyClass: harness.descriptor.privacyClass,
            maximumSubscriptionBytes: harness.descriptor.maximumSubscriptionBytes,
            maximumStateBytes: harness.descriptor.maximumStateBytes,
            bufferingPolicy: .bufferingOldest(16)
        )

        let error = await runtimeError {
            _ = try await harness.client.subscribe(to: descriptor)
        }

        XCTAssertEqual(error, .endpointDescriptorMismatch(descriptor.endpointID))
        XCTAssertEqual(counter.value(), 0)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .denied(.descriptorMismatch))
        providerContinuation.finish()
    }

    func testOversizedStateDeliveryIsSuppressedAndLedgered() async throws {
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let harness = try await makeStateHarness(maximumStateBytes: 4) { _ in
            providerStream
        }
        let relay = try await harness.client.subscribe(to: harness.descriptor)
        var iterator = relay.makeAsyncIterator()

        providerContinuation.yield("12345")

        let suppressed = await iterator.next()
        XCTAssertNil(suppressed)
        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .failed(.responseTooLarge))
        XCTAssertEqual(ledger[0].responseByteCount, 5)
        XCTAssertNotNil(ledger[0].completedAtUTC)
        providerContinuation.finish()
    }

    func testNormallyCompletedStateRelayCreatesSucceededLedgerRow() async throws {
        let (providerStream, providerContinuation) = AsyncStream<String>.makeStream()
        let harness = try await makeStateHarness { _ in providerStream }
        let relay = try await harness.client.subscribe(to: harness.descriptor)

        providerContinuation.yield("snapshot")
        providerContinuation.finish()
        var completed = false
        for _ in 0..<1_000 {
            let ledger = await harness.dispatcher.ledgerSnapshot()
            completed = ledger.first?.outcome == .succeeded
            if completed { break }
            await Task.yield()
        }
        XCTAssertTrue(completed)

        var iterator = relay.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.payload, "snapshot")
        let finished = await iterator.next()
        XCTAssertNil(finished)

        let ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].outcome, .succeeded)
        XCTAssertEqual(ledger[0].responseByteCount, 8)
        XCTAssertNotNil(ledger[0].completedAtUTC)
    }

    func testSessionBoundRejectsSaturationWithoutRetry() async throws {
        let barrier = RuntimeTestBarrier()
        let harness = try await makeHarness { value in
            await barrier.suspend()
            return value
        }
        let operations = (0..<RuntimeOperationDispatcher.maximumInFlightOperations).map { index in
            Task { try? await harness.client.send("\(index)", to: harness.key) }
        }
        await barrier.waitForArrivals(RuntimeOperationDispatcher.maximumInFlightOperations)

        let error = await runtimeError {
            _ = try await harness.client.send("saturated", to: harness.key)
        }
        XCTAssertEqual(
            error,
            .operationSessionLimitExceeded(
                maximum: RuntimeOperationDispatcher.maximumInFlightOperations
            )
        )
        let arrivalCount = await barrier.arrivalCount()
        XCTAssertEqual(
            arrivalCount,
            RuntimeOperationDispatcher.maximumInFlightOperations
        )
        let saturatedLedger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(
            saturatedLedger.last?.outcome,
            .denied(.sessionLimit)
        )
        XCTAssertEqual(saturatedLedger.last?.requestByteCount, 9)
        XCTAssertNotNil(saturatedLedger.last?.completedAtUTC)

        await harness.dispatcher.beginRuntimeStop()
        await barrier.releaseAll()
        for operation in operations { _ = await operation.value }
    }

    func testPerSourceRateBoundRejectsWithoutInvokingHandlerAndResetsAfterWindow() async throws {
        let clock = RuntimeLockedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let environment = RuntimeEnvironment(
            now: { clock.now() },
            nextUUID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )
        let counter = RuntimeInvocationCounter()
        let harness = try await makeHarness(
            environment: environment,
            ratePolicy: RuntimeOperationRatePolicy(
                maximumCallsPerSource: 2,
                window: 60
            )
        ) { value in
            await counter.record()
            return value
        }

        _ = try await harness.client.send("one", to: harness.key)
        _ = try await harness.client.send("two", to: harness.key)
        let error = await runtimeError {
            _ = try await harness.client.send("three", to: harness.key)
        }

        XCTAssertEqual(
            error,
            .operationRateLimitExceeded(maximumCalls: 2, window: 60)
        )
        let countAtLimit = await counter.value()
        XCTAssertEqual(countAtLimit, 2)
        var ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger.last?.outcome, .denied(.rateLimit))
        XCTAssertEqual(ledger.last?.requestByteCount, 5)

        clock.advance(by: 60)
        _ = try await harness.client.send("four", to: harness.key)
        let countAfterWindow = await counter.value()
        XCTAssertEqual(countAfterWindow, 3)
        ledger = await harness.dispatcher.ledgerSnapshot()
        XCTAssertEqual(ledger.last?.outcome, .succeeded)
    }

    func testApplicationEndpointUsesComputedPayloadBound() async throws {
        let dispatcher = RuntimeOperationDispatcher(policy: .patternBFoundation, environment: .live)
        let providerID: ModuleIdentifier = "test.application.provider"
        let sourceID: ModuleIdentifier = "test.application.source"
        let endpoint = RuntimeApplicationEndpointCatalog.verifyPIN
        let endpointID = endpoint.descriptor.endpointID
        await dispatcher.registerModule(testDescriptor(id: providerID, role: RuneScribeRoles.core, capabilities: [], published: [endpointID]))
        await dispatcher.registerModule(testDescriptor(id: sourceID, role: RuneScribeRoles.primaryUI, capabilities: [RuneScribeCapabilities.applicationCommands], consumed: [endpointID]))
        _ = await dispatcher.beginRuntimeStart()
        let providerGeneration = try await dispatcher.beginActivation(moduleID: providerID)
        try await dispatcher.registerEndpoint(
            ownerModuleID: providerID,
            ownerGeneration: providerGeneration,
            key: endpoint,
            handler: { _, _ in true }
        )
        try await dispatcher.markActive(moduleID: providerID, generation: providerGeneration)
        let sourceGeneration = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(moduleID: sourceID, generation: sourceGeneration)
        await dispatcher.markRuntimeRunning()
        let lease = try await dispatcher.makeLease(sourceModuleID: sourceID, sourceGeneration: sourceGeneration, destination: .role(RuneScribeRoles.core))
        let client = RuntimeCommandClient(dispatcher: dispatcher, lease: lease)
        let oversizedPIN = PINInput(String(repeating: "7", count: Int(endpoint.descriptor.maximumRequestBytes + 1)))

        let error = await runtimeError { _ = try await client.send(oversizedPIN, to: endpoint) }
        XCTAssertEqual(error, .operationRequestTooLarge(endpoint: endpointID, maximumBytes: endpoint.descriptor.maximumRequestBytes))
    }

    func testHostRegistrationRejectsMismatchedExactKey() async throws {
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )
        let wrongKey = ServiceKey<any ClipboardReading>(RuneScribeServiceIDs.clipboardWrite)
        do {
            try await runtime.installPlatformAdapter(RuntimeTestClipboardReader(), for: wrongKey)
            XCTFail("Expected mismatched exact host key rejection.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .hostServiceAccessDenied(RuneScribeServiceIDs.clipboardWrite)
            )
        }
    }

    func testFailedActivationInvalidatesCapturedContextBeforeReturning() async throws {
        let core = testDescriptor(
            id: "test.failed-activation.core",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let ui = ModuleDescriptor(
            moduleID: "test.failed-activation.ui",
            moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            kind: .ui,
            entryPoint: "test.failed-activation.ui",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: [RuneScribeRoles.core]
        )
        let capture = RuntimeModuleContextCapture()
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )
        try await runtime.register(
            manifest: testManifest(for: core),
            factory: AnyModuleFactory(descriptor: core) {
                RuntimeClosureModule(descriptor: core) { context in
                    await capture.store(context)
                    throw RuntimeTestHandlerError.expected
                }
            }
        )
        try await runtime.register(
            manifest: testManifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                RuntimeClosureModule(descriptor: ui) { _ in }
            }
        )

        do {
            try await runtime.start()
            XCTFail("Expected activation failure.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .activationFailed(core.moduleID)
            )
        }
        let capturedContext = await capture.value()
        let context = try XCTUnwrap(capturedContext)
        let error = await runtimeError {
            _ = try await context.commandClient(to: .role(RuneScribeRoles.core))
        }
        XCTAssertEqual(error, .contextInactive(core.moduleID))
    }

    func testClockRegistrationTracksAvailabilityWithoutVendingAProviderClient() async throws {
        let bridge = RuntimePlatformBridge()
        let date = Date(timeIntervalSince1970: 123)
        try await bridge.register(RuntimeTestClock(date: date))
        let containsClock = await bridge.contains(RuneScribeServiceIDs.clock)
        XCTAssertTrue(containsClock)
        do {
            try await bridge.register(RuntimeTestClock(date: date))
            XCTFail("Expected duplicate clock registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .duplicateService(RuneScribeServiceIDs.clock)
            )
        }
    }

    private func makeStateHarness(
        maximumStateBytes: UInt64 = 64,
        beforeStateDelivery: @escaping @Sendable () async -> Void = {},
        handler: @escaping @Sendable (RuntimeOperationMetadata) -> AsyncStream<String>
    ) async throws -> RuntimeStateHarness {
        let dispatcher = RuntimeOperationDispatcher(
            policy: .patternBFoundation,
            environment: .live,
            ratePolicy: .shippingDefault,
            beforeStateDelivery: beforeStateDelivery
        )
        let providerID: ModuleIdentifier = "test.state-harness.provider"
        let sourceID: ModuleIdentifier = "test.state-harness.source"
        let endpointID: RuntimeEndpointIdentifier = "test.state-harness.snapshot"
        let descriptor = RuntimeStateEndpointDescriptor<String>(
            endpointID: endpointID,
            destination: .role(RuneScribeRoles.core),
            subscriptionSchemaVersion: RuntimeSchemaVersions.v1,
            stateSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationStateRead,
            privacyClass: .internalData,
            maximumSubscriptionBytes: 0,
            maximumStateBytes: maximumStateBytes
        )
        await dispatcher.registerModule(
            testDescriptor(
                id: providerID,
                role: RuneScribeRoles.core,
                capabilities: [],
                published: [endpointID]
            )
        )
        await dispatcher.registerModule(
            testDescriptor(
                id: sourceID,
                role: RuneScribeRoles.primaryUI,
                capabilities: [RuneScribeCapabilities.applicationStateRead],
                consumed: [endpointID]
            )
        )
        _ = await dispatcher.beginRuntimeStart()
        let providerGeneration = try await dispatcher.beginActivation(moduleID: providerID)
        try await dispatcher.registerStateEndpoint(
            ownerModuleID: providerID,
            ownerGeneration: providerGeneration,
            descriptor: descriptor,
            handler: handler
        )
        try await dispatcher.markActive(
            moduleID: providerID,
            generation: providerGeneration
        )
        let sourceGeneration = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(
            moduleID: sourceID,
            generation: sourceGeneration
        )
        await dispatcher.markRuntimeRunning()
        let lease = try await dispatcher.makeLease(
            sourceModuleID: sourceID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.core)
        )
        return RuntimeStateHarness(
            dispatcher: dispatcher,
            providerID: providerID,
            descriptor: descriptor,
            client: RuntimeStateClient(dispatcher: dispatcher, lease: lease)
        )
    }

    private func makeHarness(
        sourceCapabilities: Set<CapabilityIdentifier> = [RuneScribeCapabilities.applicationCommands],
        sourceDeclaresEndpoint: Bool = true,
        sourceRole: ModuleRole = RuneScribeRoles.primaryUI,
        maximumRequestBytes: UInt64 = 1_024,
        environment: RuntimeEnvironment = .live,
        ratePolicy: RuntimeOperationRatePolicy = .shippingDefault,
        handler: @escaping @Sendable (String) async throws -> String
    ) async throws -> RuntimeCommandHarness {
        let dispatcher = RuntimeOperationDispatcher(
            policy: .patternBFoundation,
            environment: environment,
            ratePolicy: ratePolicy
        )
        let providerID: ModuleIdentifier = "test.command.provider"
        let sourceID: ModuleIdentifier = "test.command.source"
        let endpointID: RuntimeEndpointIdentifier = "test.command.echo"
        let key = RuntimeEndpointDescriptor<String, String>(
            endpointID: endpointID,
            kind: .command,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: 1_024
        ).key
        await dispatcher.registerModule(testDescriptor(id: providerID, role: RuneScribeRoles.core, capabilities: [], published: [endpointID]))
        await dispatcher.registerModule(testDescriptor(id: sourceID, role: sourceRole, capabilities: sourceCapabilities, consumed: sourceDeclaresEndpoint ? [endpointID] : []))
        _ = await dispatcher.beginRuntimeStart()
        let providerGeneration = try await dispatcher.beginActivation(moduleID: providerID)
        try await dispatcher.registerEndpoint(
            ownerModuleID: providerID,
            ownerGeneration: providerGeneration,
            key: key,
            handler: { _, value in try await handler(value) }
        )
        try await dispatcher.markActive(moduleID: providerID, generation: providerGeneration)
        let sourceGeneration = try await dispatcher.beginActivation(moduleID: sourceID)
        try await dispatcher.markActive(moduleID: sourceID, generation: sourceGeneration)
        await dispatcher.markRuntimeRunning()
        let lease = try await dispatcher.makeLease(sourceModuleID: sourceID, sourceGeneration: sourceGeneration, destination: .role(RuneScribeRoles.core))
        return RuntimeCommandHarness(
            dispatcher: dispatcher,
            key: key,
            client: RuntimeCommandClient(dispatcher: dispatcher, lease: lease),
            providerID: providerID,
            sourceID: sourceID,
            sourceGeneration: sourceGeneration,
            providerGeneration: providerGeneration,
            lease: lease
        )
    }

    private func assertSingleRejectedCall(
        dispatcher: RuntimeOperationDispatcher,
        expectedError: RuneScribeRuntimeError,
        expectedOutcome: RuntimeCallLedgerOutcome,
        counter: RuntimeInvocationCounter,
        operation: () async throws -> Void
    ) async {
        let before = await dispatcher.ledgerSnapshot()
        let error = await runtimeError(operation)
        let after = await dispatcher.ledgerSnapshot()
        XCTAssertEqual(error, expectedError)
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.last?.outcome, expectedOutcome)
        XCTAssertNotNil(after.last?.completedAtUTC)
        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 0)
    }

    private func runtimeError(
        _ operation: () async throws -> Void
    ) async -> RuneScribeRuntimeError? {
        do { try await operation(); return nil }
        catch { return error as? RuneScribeRuntimeError }
    }
}

private struct RuntimeCommandHarness: Sendable {
    let dispatcher: RuntimeOperationDispatcher
    let key: RuntimeEndpointKey<String, String>
    let client: RuntimeCommandClient
    let providerID: ModuleIdentifier
    let sourceID: ModuleIdentifier
    let sourceGeneration: UInt64
    let providerGeneration: UInt64
    let lease: RuntimeClientLease
}

private struct RuntimeStateHarness: Sendable {
    let dispatcher: RuntimeOperationDispatcher
    let providerID: ModuleIdentifier
    let descriptor: RuntimeStateEndpointDescriptor<String>
    let client: RuntimeStateClient
}

private func testDescriptor(
    id: ModuleIdentifier,
    role: ModuleRole,
    capabilities: Set<CapabilityIdentifier>,
    consumed: Set<RuntimeEndpointIdentifier> = [],
    published: Set<RuntimeEndpointIdentifier> = []
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: id,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        kind: role == RuneScribeRoles.primaryUI ? .ui : .service,
        entryPoint: id.rawValue,
        role: role,
        requestedCapabilities: capabilities,
        consumedEndpoints: consumed,
        publishedEndpoints: published
    )
}

private func testManifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        supportedPlatforms: [.macOS],
        minimumOS: MinimumOSVersions(macOS: "15.0"),
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role
    )
}

private struct RuntimeClosureModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    init(
        descriptor: ModuleDescriptor,
        startAction: @escaping @Sendable (ModuleContext) async throws -> Void
    ) {
        self.descriptor = descriptor
        self.startAction = startAction
    }

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private actor RuntimeModuleContextCapture {
    private var context: ModuleContext?
    func store(_ context: ModuleContext) { self.context = context }
    func value() -> ModuleContext? { context }
}

private actor RuntimeTestBarrier {
    private var arrivals = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspend() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { arrivals >= $0.0 }
        arrivalWaiters.removeAll { arrivals >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func releaseAll() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }


    func arrivalCount() -> Int { arrivals }
}

private actor RuntimeInvocationCounter {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private final class RuntimeLockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class RuntimeSynchronousInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct RuntimeTestClipboardReader: ClipboardReading {
    func changeCount() async -> Int { 0 }
    func string() async -> String? { nil }
}

private enum RuntimeTestHandlerError: Error {
    case expected
}

private struct RuntimeTestClock: ClockProviding {
    let date: Date
    func now() -> Date { date }
}

private struct RuntimeTestUUID: UUIDProviding {
    let value: UUID
    func nextUUID() -> UUID { value }
}

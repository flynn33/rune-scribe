import CryptoKit
import Foundation
import RuneScribeContracts
@_spi(RuntimeFileImportHost) @_spi(RuntimeResourceHost) @_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

final class RuntimeIOGatewayTests: XCTestCase {
    func testAuthorizedCoreSystemIOOperationsForwardArgumentsAndResults() async throws {
        let secureData = Data("secure-result".utf8)
        let writtenSecureData = Data("secure-write".utf8)
        let protectedData = Data("protected-result".utf8)
        let writtenProtectedData = Data("protected-write".utf8)
        let protectedPath = ProtectedPath(rawValue: "Vault/item.enc")!
        let protectedDirectory = ProtectedPath(rawValue: "Vault")!
        let protectedContents = [
            ProtectedPath(rawValue: "Vault/first.enc")!,
            ProtectedPath(rawValue: "Vault/second.enc")!,
        ]
        let expectedDate = Date(timeIntervalSince1970: 1_765_432_100)
        let expectedUUID = UUID(uuidString: "36CFCA08-1016-4B01-8652-76EB19E0AE84")!
        let secureValues = SecureValueStoreProbe(dataResult: secureData)
        let protectedFiles = ProtectedFileStoreProbe(
            readResult: protectedData,
            existsResult: true,
            contentsResult: protectedContents
        )
        let clock = ClockProbe(result: expectedDate)
        let uuid = UUIDProbe(result: expectedUUID)
        let gateway = await makeGateway(
            secureValues: secureValues,
            protectedFiles: protectedFiles,
            clock: clock,
            uuid: uuid
        )
        let source = authorizedSystemIOCoreDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-system-io"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 1
        )

        let loadedSecureData = try await client.secureValueData(
            service: "com.runescribe.test.secure-service",
            account: "read-account"
        )
        try await client.setSecureValue(
            writtenSecureData,
            service: "com.runescribe.test.secure-service",
            account: "write-account"
        )
        try await client.deleteSecureValue(
            service: "com.runescribe.test.secure-service",
            account: "delete-account"
        )
        let loadedProtectedData = try await client.readProtectedFile(protectedPath)
        try await client.writeProtectedFile(
            writtenProtectedData,
            path: protectedPath
        )
        try await client.removeProtectedFile(protectedPath)
        let protectedFileExists = try await client.protectedFileExists(protectedPath)
        let listedProtectedFiles = try await client.protectedFileContents(
            of: protectedDirectory,
            matchingExtension: "enc"
        )
        let currentDate = try await client.now()
        let generatedUUID = try await client.nextUUID()

        XCTAssertEqual(loadedSecureData, secureData)
        XCTAssertEqual(loadedProtectedData, protectedData)
        XCTAssertTrue(protectedFileExists)
        XCTAssertEqual(listedProtectedFiles, protectedContents)
        XCTAssertEqual(currentDate, expectedDate)
        XCTAssertEqual(generatedUUID, expectedUUID)
        let secureState = await secureValues.state()
        XCTAssertEqual(
            secureState.dataRequests,
            [
                SecureValueLookupProbeRequest(
                    service: "com.runescribe.test.secure-service",
                    account: "read-account"
                ),
            ]
        )
        XCTAssertEqual(
            secureState.setRequests,
            [
                SecureValueSetProbeRequest(
                    data: writtenSecureData,
                    service: "com.runescribe.test.secure-service",
                    account: "write-account"
                ),
            ]
        )
        XCTAssertEqual(
            secureState.deleteRequests,
            [
                SecureValueLookupProbeRequest(
                    service: "com.runescribe.test.secure-service",
                    account: "delete-account"
                ),
            ]
        )
        let protectedState = await protectedFiles.state()
        XCTAssertEqual(protectedState.readRequests, [protectedPath])
        XCTAssertEqual(
            protectedState.writeRequests,
            [
                ProtectedFileWriteProbeRequest(
                    data: writtenProtectedData,
                    path: protectedPath
                ),
            ]
        )
        XCTAssertEqual(protectedState.removeRequests, [protectedPath])
        XCTAssertEqual(protectedState.existsRequests, [protectedPath])
        XCTAssertEqual(
            protectedState.contentsRequests,
            [
                ProtectedFileContentsProbeRequest(
                    directory: protectedDirectory,
                    fileExtension: "enc"
                ),
            ]
        )
        XCTAssertEqual(clock.invocationCount(), 1)
        XCTAssertEqual(uuid.invocationCount(), 1)
    }

    func testSystemIODenialsPrecedeProviderInvocation() async throws {
        let secureValues = SecureValueStoreProbe(dataResult: Data("denied".utf8))
        let protectedFiles = ProtectedFileStoreProbe(
            readResult: Data("denied".utf8),
            existsResult: false,
            contentsResult: []
        )
        let clock = ClockProbe(result: Date(timeIntervalSince1970: 1))
        let uuid = UUIDProbe(
            result: UUID(uuidString: "C8807E28-D11D-430B-A259-EE274CE0A45A")!
        )
        let gateway = await makeGateway(
            secureValues: secureValues,
            protectedFiles: protectedFiles,
            clock: clock,
            uuid: uuid
        )
        let undeclaredSecureSource = ioDescriptor(
            id: "com.runescribe.test.runtime-io-undeclared-secure-value",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.keychainStorage],
            requiredServices: []
        )
        let missingProtectedCapabilitySource = ioDescriptor(
            id: "com.runescribe.test.runtime-io-missing-protected-capability",
            role: RuneScribeRoles.core,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.protectedFileStore]
        )
        let wrongRoleSource = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-clock-uuid",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.clockRead,
                RuneScribeCapabilities.uuidGenerate,
            ],
            requiredServices: [
                RuneScribeServiceIDs.clock,
                RuneScribeServiceIDs.uuid,
            ]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let undeclaredSecureClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: undeclaredSecureSource,
            sourceGeneration: 2
        )
        let missingProtectedCapabilityClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: missingProtectedCapabilitySource,
            sourceGeneration: 3
        )
        let wrongRoleClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: wrongRoleSource,
            sourceGeneration: 4
        )

        let undeclaredError = await runtimeError {
            _ = try await undeclaredSecureClient.secureValueData(
                service: "com.runescribe.test.denied",
                account: "denied"
            )
        }
        let missingCapabilityError = await runtimeError {
            _ = try await missingProtectedCapabilityClient.readProtectedFile(.contacts)
        }
        let wrongClockRoleError = await runtimeError {
            _ = try await wrongRoleClient.now()
        }
        let wrongUUIDRoleError = await runtimeError {
            _ = try await wrongRoleClient.nextUUID()
        }

        XCTAssertEqual(
            undeclaredError,
            .serviceNotDeclared(
                moduleID: undeclaredSecureSource.moduleID,
                service: RuneScribeServiceIDs.secureValueStore
            )
        )
        XCTAssertEqual(
            missingCapabilityError,
            .serviceCapabilityMissing(
                moduleID: missingProtectedCapabilitySource.moduleID,
                service: RuneScribeServiceIDs.protectedFileStore
            )
        )
        XCTAssertEqual(
            wrongClockRoleError,
            .serviceAccessDenied(
                moduleID: wrongRoleSource.moduleID,
                service: RuneScribeServiceIDs.clock
            )
        )
        XCTAssertEqual(
            wrongUUIDRoleError,
            .serviceAccessDenied(
                moduleID: wrongRoleSource.moduleID,
                service: RuneScribeServiceIDs.uuid
            )
        )
        let secureState = await secureValues.state()
        let protectedState = await protectedFiles.state()
        XCTAssertEqual(secureState, .empty)
        XCTAssertEqual(protectedState, .empty)
        XCTAssertEqual(clock.invocationCount(), 0)
        XCTAssertEqual(uuid.invocationCount(), 0)
    }

    func testUnavailableSystemIOProvidersFailClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedSystemIOCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-system-io"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 5
        )

        let secureError = await runtimeError {
            _ = try await client.secureValueData(service: "service", account: "account")
        }
        let protectedError = await runtimeError {
            _ = try await client.readProtectedFile(.contacts)
        }
        let clockError = await runtimeError {
            _ = try await client.now()
        }
        let uuidError = await runtimeError {
            _ = try await client.nextUUID()
        }

        XCTAssertEqual(
            secureError,
            .serviceUnavailable(RuneScribeServiceIDs.secureValueStore)
        )
        XCTAssertEqual(
            protectedError,
            .serviceUnavailable(RuneScribeServiceIDs.protectedFileStore)
        )
        XCTAssertEqual(clockError, .serviceUnavailable(RuneScribeServiceIDs.clock))
        XCTAssertEqual(uuidError, .serviceUnavailable(RuneScribeServiceIDs.uuid))
    }

    func testLateSecureAndProtectedResultsAreRevokedAfterSourceInvalidation() async throws {
        let secureBarrier = RuntimeIOBarrier()
        let protectedBarrier = RuntimeIOBarrier()
        let secureValues = SecureValueStoreProbe(
            dataResult: Data("late-secure".utf8),
            dataBarrier: secureBarrier
        )
        let protectedFiles = ProtectedFileStoreProbe(
            readResult: Data("late-protected".utf8),
            existsResult: true,
            contentsResult: [],
            readBarrier: protectedBarrier
        )
        let gateway = await makeGateway(
            secureValues: secureValues,
            protectedFiles: protectedFiles
        )
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-late-system-io",
            role: RuneScribeRoles.core,
            capabilities: [
                RuneScribeCapabilities.keychainStorage,
                RuneScribeCapabilities.protectedFileStorage,
            ],
            requiredServices: [
                RuneScribeServiceIDs.secureValueStore,
                RuneScribeServiceIDs.protectedFileStore,
            ]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 6
        )
        let secureOperation = Task {
            try await client.secureValueData(service: "late", account: "secure")
        }
        let protectedOperation = Task {
            try await client.readProtectedFile(.contacts)
        }

        await secureBarrier.waitUntilEntered()
        await protectedBarrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 6)
        await secureBarrier.release()
        await protectedBarrier.release()

        let secureError = await runtimeError {
            _ = try await secureOperation.value
        }
        let protectedError = await runtimeError {
            _ = try await protectedOperation.value
        }
        XCTAssertEqual(secureError, .staleClient(source.moduleID))
        XCTAssertEqual(protectedError, .staleClient(source.moduleID))
        let secureState = await secureValues.state()
        let protectedState = await protectedFiles.state()
        XCTAssertEqual(
            secureState.dataRequests,
            [SecureValueLookupProbeRequest(service: "late", account: "secure")]
        )
        XCTAssertEqual(protectedState.readRequests, [.contacts])
    }

    func testRetainedClockAndUUIDClientIsStaleAfterSourceInvalidation() async throws {
        let clock = ClockProbe(result: Date(timeIntervalSince1970: 2))
        let uuid = UUIDProbe(
            result: UUID(uuidString: "01E4D590-CFF0-4D24-B0D9-CFD0EB0C1BF1")!
        )
        let gateway = await makeGateway(clock: clock, uuid: uuid)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-stale-clock-uuid",
            role: RuneScribeRoles.core,
            capabilities: [
                RuneScribeCapabilities.clockRead,
                RuneScribeCapabilities.uuidGenerate,
            ],
            requiredServices: [
                RuneScribeServiceIDs.clock,
                RuneScribeServiceIDs.uuid,
            ]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 7
        )

        await gateway.invalidateModule(source.moduleID, generation: 7)

        let clockError = await runtimeError {
            _ = try await client.now()
        }
        let uuidError = await runtimeError {
            _ = try await client.nextUUID()
        }
        XCTAssertEqual(clockError, .staleClient(source.moduleID))
        XCTAssertEqual(uuidError, .staleClient(source.moduleID))
        XCTAssertEqual(clock.invocationCount(), 0)
        XCTAssertEqual(uuid.invocationCount(), 0)
    }

    func testAuthorizedCoreReadAndPrimaryUIWrite() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 3)
        let gateway = await makeGateway(
            reader: clipboard as any ClipboardReading,
            writer: clipboard as any ClipboardWriting
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let core = ioDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-core",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardRead],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let ui = ioDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-ui",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.clipboardWrite],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite]
        )

        let coreClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: core,
            sourceGeneration: 11
        )
        let uiClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: ui,
            sourceGeneration: 12
        )

        let snapshot = try await coreClient.clipboardSnapshot()
        try await uiClient.setClipboardString("updated")

        XCTAssertEqual(
            snapshot,
            RuntimeClipboardSnapshot(changeCount: 3, string: "seed")
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.string, "updated")
        XCTAssertEqual(state.changeCount, 4)
        XCTAssertEqual(state.readInvocations, 3)
        XCTAssertEqual(state.writeInvocations, 1)
    }

    func testCoreWriteIsDeniedBeforeProviderInvocation() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 1)
        let gateway = await makeGateway(writer: clipboard as any ClipboardWriting)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-core-writer",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardWrite],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 21
        )

        let error = await runtimeError {
            try await client.setClipboardString("denied")
        }

        XCTAssertEqual(
            error,
            .serviceAccessDenied(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.clipboardWrite
            )
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.writeInvocations, 0)
        XCTAssertEqual(state.string, "seed")
    }

    func testPrimaryUIReadIsDeniedBeforeProviderInvocation() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 1)
        let gateway = await makeGateway(reader: clipboard as any ClipboardReading)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-reader",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.clipboardRead],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 22
        )

        let error = await runtimeError {
            _ = try await client.clipboardSnapshot()
        }

        XCTAssertEqual(
            error,
            .serviceAccessDenied(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.clipboardRead
            )
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.readInvocations, 0)
    }

    func testUndeclaredClipboardServiceFailsBeforeProviderInvocation() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 1)
        let gateway = await makeGateway(reader: clipboard as any ClipboardReading)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-undeclared",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardRead],
            requiredServices: []
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 23
        )

        let error = await runtimeError {
            _ = try await client.clipboardSnapshot()
        }

        XCTAssertEqual(
            error,
            .serviceNotDeclared(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.clipboardRead
            )
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.readInvocations, 0)
    }

    func testMissingClipboardCapabilityFailsBeforeProviderInvocation() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 1)
        let gateway = await makeGateway(reader: clipboard as any ClipboardReading)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-missing-capability",
            role: RuneScribeRoles.core,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 24
        )

        let error = await runtimeError {
            _ = try await client.clipboardSnapshot()
        }

        XCTAssertEqual(
            error,
            .serviceCapabilityMissing(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.clipboardRead
            )
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.readInvocations, 0)
    }

    func testUnavailableClipboardProviderFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 25
        )

        let error = await runtimeError {
            _ = try await client.clipboardSnapshot()
        }

        XCTAssertEqual(
            error,
            .serviceUnavailable(RuneScribeServiceIDs.clipboardRead)
        )
    }

    func testStoppedClientFailsThenBecomesStaleAfterRestart() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 7)
        let gateway = await makeGateway(reader: clipboard as any ClipboardReading)
        let source = authorizedCoreDescriptor(
            id: "com.runescribe.test.runtime-io-restart"
        )
        let firstRuntimeGeneration = await gateway.currentGeneration()
        let oldClient = try await activateClient(
            on: gateway,
            runtimeGeneration: firstRuntimeGeneration,
            descriptor: source,
            sourceGeneration: 31
        )

        await gateway.deactivateRuntime()

        let stoppedError = await runtimeError {
            _ = try await oldClient.clipboardSnapshot()
        }
        XCTAssertEqual(stoppedError, .runtimeNotRunning)

        let secondRuntimeGeneration = await gateway.activateRuntime()
        let newClient = try await activateClient(
            on: gateway,
            runtimeGeneration: secondRuntimeGeneration,
            descriptor: source,
            sourceGeneration: 32
        )

        let staleError = await runtimeError {
            _ = try await oldClient.clipboardSnapshot()
        }
        XCTAssertEqual(staleError, .staleClient(source.moduleID))

        let snapshot = try await newClient.clipboardSnapshot()
        XCTAssertEqual(
            snapshot,
            RuntimeClipboardSnapshot(changeCount: 7, string: "seed")
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.readInvocations, 3)
    }

    func testSourceReplacementRevokesRetainedClient() async throws {
        let clipboard = CountingClipboardProbe(string: "seed", changeCount: 8)
        let gateway = await makeGateway(reader: clipboard as any ClipboardReading)
        let source = authorizedCoreDescriptor(
            id: "com.runescribe.test.runtime-io-source-replacement"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let oldClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 41
        )

        await gateway.invalidateModule(source.moduleID, generation: 41)
        let newClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 42
        )

        let staleError = await runtimeError {
            _ = try await oldClient.clipboardSnapshot()
        }
        XCTAssertEqual(staleError, .staleClient(source.moduleID))

        let snapshot = try await newClient.clipboardSnapshot()
        XCTAssertEqual(
            snapshot,
            RuntimeClipboardSnapshot(changeCount: 8, string: "seed")
        )
        let state = await clipboard.state()
        XCTAssertEqual(state.readInvocations, 3)
    }

    func testLateClipboardReadResultIsRevokedAfterSourceReplacement() async throws {
        let barrier = RuntimeIOBarrier()
        let reader = SuspendingClipboardReader(
            barrier: barrier,
            string: "late",
            changeCount: 9
        )
        let gateway = await makeGateway(reader: reader)
        let source = authorizedCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-read"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 51
        )
        let operation = Task {
            try await client.clipboardSnapshot()
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 51)
        try await gateway.activateModule(descriptor: source, generation: 52)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
    }

    func testLateClipboardWriteErrorIsReplacedByRuntimeRevocation() async throws {
        let barrier = RuntimeIOBarrier()
        let writer = SuspendingFailingClipboardWriter(barrier: barrier)
        let gateway = await makeGateway(writer: writer)
        let source = authorizedUIDescriptor(
            id: "com.runescribe.test.runtime-io-late-write"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 61
        )
        let operation = Task {
            try await client.setClipboardString("late")
        }

        await barrier.waitUntilEntered()
        await gateway.deactivateRuntime()
        await barrier.release()

        let error = await runtimeError {
            try await operation.value
        }
        XCTAssertEqual(error, .runtimeNotRunning)
    }

    func testClipboardProviderErrorIsPreservedWhileLeaseRemainsValid() async throws {
        let gateway = await makeGateway(writer: FailingClipboardWriter())
        let source = authorizedUIDescriptor(
            id: "com.runescribe.test.runtime-io-provider-error"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 62
        )

        do {
            try await client.setClipboardString("failure")
            XCTFail("Expected the clipboard provider error to be preserved.")
        } catch {
            XCTAssertEqual(error as? RuntimeIOProbeError, .providerFailure)
        }
    }

    func testClipboardTerminalJournalRetryRetainsCompletedUtilityEvidence() async throws {
        let store = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 9_210) }
        )
        let clipboard = CountingClipboardProbe(string: nil, changeCount: 0)
        let gateway = await makeGateway(
            writer: clipboard,
            issueOperationContexts: true,
            moduleStateStore: store
        )
        let source = authorizedUIDescriptor(
            id: "com.runescribe.test.runtime-io-clipboard-terminal-retry"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 63
        )
        let artifactID = ShareArtifactID(
            rawValue: UUID(
                uuidString: "63000000-0000-0000-0000-000000000001"
            )!
        )
        await store.injectFault(
            at: .beforeTransactionCommit,
            afterSuccessfulCalls: 1
        )

        do {
            _ = try await client.setClipboardString(
                "terminal",
                artifactID: artifactID
            )
            XCTFail("Expected the first terminal journal write to fail")
        } catch ModuleStateStoreError.injectedFailure {}
        let afterFailure = await clipboard.state()
        XCTAssertEqual(afterFailure.string, "terminal")
        XCTAssertEqual(afterFailure.writeInvocations, 1)

        let evidence = try await client.setClipboardString(
            "terminal",
            artifactID: artifactID
        )
        XCTAssertEqual(evidence.artifactID, artifactID)
        XCTAssertEqual(evidence.report.routeClass, .clipboard)
        XCTAssertEqual(evidence.report.result, .completionUnavailable)
        let afterRetry = await clipboard.state()
        XCTAssertEqual(afterRetry.writeInvocations, 2)
    }

    func testAuthorizedCoreContactStatusRequestAndFetch() async throws {
        let expectedContacts = [
            SystemContactDTO(
                systemIdentifier: "contact-1",
                displayName: "Ada Example",
                phoneNumbers: ["+15550100"],
                emailAddresses: ["ada@example.invalid"]
            ),
            SystemContactDTO(
                systemIdentifier: "contact-2",
                displayName: "Grace Example"
            ),
        ]
        let contacts = ContactAccessProbe(
            authorizationStatus: .limited,
            requestResult: true,
            contacts: expectedContacts
        )
        let gateway = await makeGateway(contacts: contacts)
        let source = authorizedContactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-contacts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 71
        )

        let status = try await client.contactAuthorizationStatus()
        let requestResult = try await client.requestContactAccess()
        let fetchedContacts = try await client.fetchSystemContacts()

        XCTAssertEqual(status, .limited)
        XCTAssertTrue(requestResult)
        XCTAssertEqual(fetchedContacts, expectedContacts)
        let state = await contacts.state()
        XCTAssertEqual(state.authorizationStatusInvocations, 1)
        XCTAssertEqual(state.requestAccessInvocations, 1)
        XCTAssertEqual(state.fetchContactsInvocations, 1)
    }

    func testPrimaryUIContactOperationsAreDeniedBeforeProviderInvocation() async throws {
        let contacts = ContactAccessProbe(
            authorizationStatus: .authorized,
            requestResult: true,
            contacts: []
        )
        let gateway = await makeGateway(contacts: contacts)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-contacts",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.contactRead],
            requiredServices: [RuneScribeServiceIDs.contactAccess]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 72
        )
        let expectedError = RuneScribeRuntimeError.serviceAccessDenied(
            moduleID: source.moduleID,
            service: RuneScribeServiceIDs.contactAccess
        )

        let statusError = await runtimeError {
            _ = try await client.contactAuthorizationStatus()
        }
        let requestError = await runtimeError {
            _ = try await client.requestContactAccess()
        }
        let fetchError = await runtimeError {
            _ = try await client.fetchSystemContacts()
        }

        XCTAssertEqual(statusError, expectedError)
        XCTAssertEqual(requestError, expectedError)
        XCTAssertEqual(fetchError, expectedError)
        let state = await contacts.state()
        XCTAssertEqual(state.authorizationStatusInvocations, 0)
        XCTAssertEqual(state.requestAccessInvocations, 0)
        XCTAssertEqual(state.fetchContactsInvocations, 0)
    }

    func testUnavailableContactProviderFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedContactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-contacts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 73
        )
        let expectedError = RuneScribeRuntimeError.serviceUnavailable(
            RuneScribeServiceIDs.contactAccess
        )

        let statusError = await runtimeError {
            _ = try await client.contactAuthorizationStatus()
        }
        let requestError = await runtimeError {
            _ = try await client.requestContactAccess()
        }
        let fetchError = await runtimeError {
            _ = try await client.fetchSystemContacts()
        }

        XCTAssertEqual(statusError, expectedError)
        XCTAssertEqual(requestError, expectedError)
        XCTAssertEqual(fetchError, expectedError)
    }

    func testLateContactFetchResultIsRevokedAfterRuntimeStop() async throws {
        let barrier = RuntimeIOBarrier()
        let contacts = ContactAccessProbe(
            authorizationStatus: .authorized,
            requestResult: true,
            contacts: [
                SystemContactDTO(
                    systemIdentifier: "late-contact",
                    displayName: "Late Contact"
                ),
            ],
            fetchBarrier: barrier
        )
        let gateway = await makeGateway(contacts: contacts)
        let source = authorizedContactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-contact-fetch"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 74
        )
        let operation = Task {
            try await client.fetchSystemContacts()
        }

        await barrier.waitUntilEntered()
        await gateway.deactivateRuntime()
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .runtimeNotRunning)
        let state = await contacts.state()
        XCTAssertEqual(state.fetchContactsInvocations, 1)
    }

    func testAuthorizedCoreInboundReadForwardsRequestAndReturnsData() async throws {
        let expectedData = Data("inbound-data".utf8)
        let inboundFiles = InboundFileProbe(data: expectedData)
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundCoreDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-inbound"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 81
        )
        let request = RuntimeInboundFileReadRequest(
            fileURL: URL(fileURLWithPath: "/tmp/runtime-io-authorized.runescribe"),
            requiresSecurityScopedAccess: true,
            maximumByteCount: 12_345
        )

        let data = try await client.readInboundFile(request)

        XCTAssertEqual(data, expectedData)
        let state = await inboundFiles.state()
        XCTAssertEqual(state.requests, [request])
    }

    func testAuthorizedUIImportSessionNormalizesAndDeliversSelectedFile() async throws {
        let expectedData = Data("selected-file".utf8)
        let expectedDate = Date(timeIntervalSince1970: 1_780_000_001)
        let expectedUUID = UUID(
            uuidString: "6256403D-48B3-4D6A-9E45-A54A46FB6DB8"
        )!
        let inboundFiles = InboundFileProbe(data: expectedData)
        let gateway = await makeGateway(
            inboundFiles: inboundFiles,
            environment: RuntimeEnvironment(
                now: { expectedDate },
                nextUUID: { expectedUUID }
            )
        )
        let source = authorizedInboundImportUIDescriptor(
            id: "com.runescribe.test.runtime-io-ui-import"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 8_201
        )
        let delivery = InboundImportDeliveryProbe(
            result: ImportResultDTO(disposition: .duplicate)
        )
        let session = try await client.inboundFileImportSession { input in
            try await delivery.deliver(input)
        }
        let selectedURL = URL(
            fileURLWithPath: "/tmp/runtime-ui-selected.runescribe"
        )

        let result = try await session.importSelectedFile(selectedURL)

        XCTAssertEqual(result.disposition, .duplicate)
        let providerState = await inboundFiles.state()
        XCTAssertEqual(
            providerState.requests,
            [
                RuntimeInboundFileReadRequest(
                    fileURL: selectedURL,
                    requiresSecurityScopedAccess: true,
                    maximumByteCount: RuntimeIOGateway.maximumInboundFileByteCount
                )
            ]
        )
        let delivered = await delivery.snapshot()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].data, expectedData)
        XCTAssertEqual(
            delivered[0].declaredContentType,
            RuneScribeWireFormat.contentType
        )
        XCTAssertEqual(delivered[0].metadata.receivedAt, expectedDate)
        XCTAssertEqual(delivered[0].metadata.id.rawValue, expectedUUID)
        XCTAssertEqual(delivered[0].metadata.source, .fileImporter)
        XCTAssertFalse(delivered[0].metadata.isColdStart)
    }

    func testUIImportSessionAuthorizationFailsBeforeProviderInvocation() async throws {
        let inboundFiles = InboundFileProbe(data: Data("denied".utf8))
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-import-denied",
            role: RuneScribeRoles.primaryUI,
            capabilities: [],
            requiredServices: []
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 8_202
        )

        let error = await runtimeError {
            _ = try await client.inboundFileImportSession { _ in
                ImportResultDTO(disposition: .ignored)
            }
        }

        XCTAssertEqual(
            error,
            .serviceCapabilityMissing(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.inboundFileReader
            )
        )
        let providerState = await inboundFiles.state()
        XCTAssertTrue(providerState.requests.isEmpty)
    }

    func testInvalidatedUIImportSessionDoesNotInvokeProviderOrDelivery() async throws {
        let inboundFiles = InboundFileProbe(data: Data("stale".utf8))
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundImportUIDescriptor(
            id: "com.runescribe.test.runtime-io-ui-import-stale"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let sourceGeneration: UInt64 = 8_203
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: sourceGeneration
        )
        let delivery = InboundImportDeliveryProbe(
            result: ImportResultDTO(disposition: .ignored)
        )
        let session = try await client.inboundFileImportSession { input in
            try await delivery.deliver(input)
        }
        await gateway.invalidateModule(
            source.moduleID,
            generation: sourceGeneration
        )

        let error = await runtimeError {
            _ = try await session.importSelectedFile(
                URL(fileURLWithPath: "/tmp/stale-ui-import.runescribe")
            )
        }

        XCTAssertEqual(error, .staleClient(source.moduleID))
        let providerState = await inboundFiles.state()
        let delivered = await delivery.snapshot()
        XCTAssertTrue(providerState.requests.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testLateUIImportReadIsRevokedBeforeDelivery() async throws {
        let barrier = RuntimeIOBarrier()
        let inboundFiles = InboundFileProbe(
            data: Data("late".utf8),
            barrier: barrier
        )
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundImportUIDescriptor(
            id: "com.runescribe.test.runtime-io-ui-import-late"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let sourceGeneration: UInt64 = 8_204
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: sourceGeneration
        )
        let delivery = InboundImportDeliveryProbe(
            result: ImportResultDTO(disposition: .ignored)
        )
        let session = try await client.inboundFileImportSession { input in
            try await delivery.deliver(input)
        }
        let operation = Task {
            try await session.importSelectedFile(
                URL(fileURLWithPath: "/tmp/late-ui-import.runescribe")
            )
        }
        await barrier.waitUntilEntered()
        await gateway.invalidateModule(
            source.moduleID,
            generation: sourceGeneration
        )
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }

        XCTAssertEqual(error, .staleClient(source.moduleID))
        let providerState = await inboundFiles.state()
        let delivered = await delivery.snapshot()
        XCTAssertEqual(providerState.requests.count, 1)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testUIImportSessionRejectsOversizedProviderResultBeforeDelivery() async throws {
        let inboundFiles = InboundFileProbe(
            data: Data(
                repeating: 0xA5,
                count: RuntimeIOGateway.maximumInboundFileByteCount + 1
            )
        )
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundImportUIDescriptor(
            id: "com.runescribe.test.runtime-io-ui-import-oversized"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 8_205
        )
        let delivery = InboundImportDeliveryProbe(
            result: ImportResultDTO(disposition: .ignored)
        )
        let session = try await client.inboundFileImportSession { input in
            try await delivery.deliver(input)
        }

        do {
            _ = try await session.importSelectedFile(
                URL(fileURLWithPath: "/tmp/oversized-ui-import.runescribe")
            )
            XCTFail("An oversized provider result must fail closed.")
        } catch let error as InboundFileReaderError {
            XCTAssertEqual(error, .contentTooLarge)
        }
        let delivered = await delivery.snapshot()
        XCTAssertTrue(delivered.isEmpty)
    }

    func testPrimaryUIInboundReadIsDeniedBeforeProviderInvocation() async throws {
        let inboundFiles = InboundFileProbe(data: Data("denied".utf8))
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-inbound",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.inboundFileRead],
            requiredServices: [RuneScribeServiceIDs.inboundFileReader]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 82
        )

        let error = await runtimeError {
            _ = try await client.readInboundFile(inboundRequest(maximumByteCount: 64))
        }

        XCTAssertEqual(
            error,
            .serviceAccessDenied(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.inboundFileReader
            )
        )
        let state = await inboundFiles.state()
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testUndeclaredInboundServiceFailsBeforeProviderInvocation() async throws {
        let inboundFiles = InboundFileProbe(data: Data("undeclared".utf8))
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-undeclared-inbound",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.inboundFileRead],
            requiredServices: []
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 83
        )

        let error = await runtimeError {
            _ = try await client.readInboundFile(inboundRequest(maximumByteCount: 65))
        }

        XCTAssertEqual(
            error,
            .serviceNotDeclared(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.inboundFileReader
            )
        )
        let state = await inboundFiles.state()
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testMissingInboundCapabilityFailsBeforeProviderInvocation() async throws {
        let inboundFiles = InboundFileProbe(data: Data("missing".utf8))
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = ioDescriptor(
            id: "com.runescribe.test.runtime-io-missing-inbound-capability",
            role: RuneScribeRoles.core,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.inboundFileReader]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 84
        )

        let error = await runtimeError {
            _ = try await client.readInboundFile(inboundRequest(maximumByteCount: 66))
        }

        XCTAssertEqual(
            error,
            .serviceCapabilityMissing(
                moduleID: source.moduleID,
                service: RuneScribeServiceIDs.inboundFileReader
            )
        )
        let state = await inboundFiles.state()
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testUnavailableInboundProviderFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedInboundCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-inbound"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 85
        )

        let error = await runtimeError {
            _ = try await client.readInboundFile(inboundRequest(maximumByteCount: 67))
        }

        XCTAssertEqual(
            error,
            .serviceUnavailable(RuneScribeServiceIDs.inboundFileReader)
        )
    }

    func testInboundByteBoundIsForwardedAndProviderErrorIsPreserved() async throws {
        let inboundFiles = InboundFileProbe(error: .contentTooLarge)
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundCoreDescriptor(
            id: "com.runescribe.test.runtime-io-inbound-provider-error"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 86
        )
        let request = inboundRequest(maximumByteCount: 4_097)

        do {
            _ = try await client.readInboundFile(request)
            XCTFail("Expected the inbound provider error to be preserved.")
        } catch {
            XCTAssertEqual(error as? InboundFileReaderError, .contentTooLarge)
        }
        let state = await inboundFiles.state()
        XCTAssertEqual(state.requests, [request])
        XCTAssertEqual(state.requests.first?.maximumByteCount, 4_097)
    }

    func testLateInboundReadResultIsRevokedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let inboundFiles = InboundFileProbe(
            data: Data("late-inbound".utf8),
            barrier: barrier
        )
        let gateway = await makeGateway(inboundFiles: inboundFiles)
        let source = authorizedInboundCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-inbound"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 87
        )
        let operation = Task {
            try await client.readInboundFile(inboundRequest(maximumByteCount: 8_192))
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 87)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let state = await inboundFiles.state()
        XCTAssertEqual(state.requests.count, 1)
    }

    func testApplicationResourceSessionAcquiresAndClosesOpaqueLease() async throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/runtime-io-resource-session.mp4")
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: expectedURL
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-session",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 90
        )

        let session = try await client.applicationResourceSession(.splashVideo)
        var state = await resources.state()
        XCTAssertTrue(state.urlRequests.isEmpty)

        let lease = try await session.acquire()
        XCTAssertEqual(lease.url, expectedURL)
        state = await resources.state()
        XCTAssertEqual(state.urlRequests, [.splashVideo])

        let eventStream = await lease.events()
        var events = eventStream.makeAsyncIterator()
        await lease.close()
        let event = await events.next()
        XCTAssertNil(event)
        await lease.close()
    }

    func testProgressionReadsDeclaredOwnedResourceWithBoundAndDigest() async throws {
        let moduleID: ModuleIdentifier = "com.runescribe.test.runtime-io-progression-resource"
        let resource = ApplicationResource(
            name: "progression-catalog",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let expectedData = Data("{\"catalog\":1}".utf8)
        let resources = ApplicationResourceProbe(
            data: expectedData,
            url: URL(fileURLWithPath: "/tmp/progression-catalog.json")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [resource]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 901
        )

        let value = try await client.readVerifiedApplicationResource(
            resource,
            expectedSHA256: Data(SHA256.hash(data: expectedData)),
            maximumByteCount: 4_096
        )

        XCTAssertEqual(value, expectedData)
        let state = await resources.state()
        XCTAssertEqual(state.dataRequests, [resource])
        XCTAssertEqual(
            state.boundedDataRequests,
            [ApplicationResourceBoundedProbeRequest(resource: resource, maximumByteCount: 4_096)]
        )
    }

    func testVerifiedResourceRejectsInvalidBoundOversizeAndDigestMismatch() async throws {
        let moduleID: ModuleIdentifier = "com.runescribe.test.runtime-io-verified-failures"
        let resource = ApplicationResource(
            name: "progression-events",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let data = Data("oversized-resource".utf8)
        let resources = ApplicationResourceProbe(
            data: data,
            url: URL(fileURLWithPath: "/tmp/progression-events.json")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [resource]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 902
        )

        let invalidBound = await verifiedResourceFailure {
            _ = try await client.readVerifiedApplicationResource(
                resource,
                expectedSHA256: Data(SHA256.hash(data: data)),
                maximumByteCount: 0
            )
        }
        XCTAssertEqual(invalidBound, .invalidMaximumByteCount)
        var state = await resources.state()
        XCTAssertTrue(state.dataRequests.isEmpty)

        let oversized = await verifiedResourceFailure {
            _ = try await client.readVerifiedApplicationResource(
                resource,
                expectedSHA256: Data(SHA256.hash(data: data)),
                maximumByteCount: data.count - 1
            )
        }
        XCTAssertEqual(oversized, .contentTooLarge)

        let digestMismatch = await verifiedResourceFailure {
            _ = try await client.readVerifiedApplicationResource(
                resource,
                expectedSHA256: Data(repeating: 0, count: SHA256.Digest.byteCount),
                maximumByteCount: data.count
            )
        }
        XCTAssertEqual(digestMismatch, .integrityMismatch)
        state = await resources.state()
        XCTAssertEqual(state.dataRequests, [resource, resource])
    }

    func testLateVerifiedResourceBytesAreRevokedAfterSourceInvalidation() async throws {
        let moduleID: ModuleIdentifier = "com.runescribe.test.runtime-io-late-verified-resource"
        let resource = ApplicationResource(
            name: "late-catalog",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let data = Data("late-verified-resource".utf8)
        let barrier = RuntimeIOBarrier()
        let resources = ApplicationResourceProbe(
            data: data,
            url: URL(fileURLWithPath: "/tmp/late-catalog.json"),
            dataBarrier: barrier
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [resource]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 904
        )
        let operation = Task {
            try await client.readVerifiedApplicationResource(
                resource,
                expectedSHA256: Data(SHA256.hash(data: data)),
                maximumByteCount: data.count
            )
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(moduleID, generation: 904)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(moduleID))
        let state = await resources.state()
        XCTAssertEqual(state.dataRequests, [resource])
    }

    func testVerifiedResourceRequiresDeclarationAndMatchingOwner() async throws {
        let moduleID: ModuleIdentifier = "com.runescribe.test.runtime-io-resource-owner"
        let undeclared = ApplicationResource(
            name: "undeclared",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let foreign = ApplicationResource(
            name: "foreign",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.test.runtime-io-resource-foreign"
        )
        let resources = ApplicationResourceProbe(
            data: Data("{}".utf8),
            url: URL(fileURLWithPath: "/tmp/resource.json")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [foreign]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 903
        )

        let undeclaredError = await runtimeError {
            _ = try await client.readVerifiedApplicationResource(
                undeclared,
                expectedSHA256: Data(repeating: 0, count: SHA256.Digest.byteCount),
                maximumByteCount: 100
            )
        }
        XCTAssertEqual(
            undeclaredError,
            .resourceNotDeclared(moduleID: moduleID, resource: undeclared)
        )

        let ownerError = await runtimeError {
            _ = try await client.readVerifiedApplicationResource(
                foreign,
                expectedSHA256: Data(repeating: 0, count: SHA256.Digest.byteCount),
                maximumByteCount: 100
            )
        }
        XCTAssertEqual(
            ownerError,
            .serviceAccessDenied(
                moduleID: moduleID,
                service: RuneScribeServiceIDs.applicationResourceLocator
            )
        )
        let state = await resources.state()
        XCTAssertTrue(state.dataRequests.isEmpty)
    }

    func testHostVerifiedManifestReadRequiresDeclaredMatchingOwner() async throws {
        let moduleID: ModuleIdentifier = "com.runescribe.test.runtime-io-host-manifest"
        let manifestResource = ApplicationResource(
            name: "module-manifest",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let manifestData = Data("{\"schemaVersion\":\"1.0\"}".utf8)
        let resources = ApplicationResourceProbe(
            data: manifestData,
            url: URL(fileURLWithPath: "/tmp/module-manifest.json")
        )
        let gateway = await makeGateway(resources: resources)
        let descriptor = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [manifestResource]
        )

        let value = try await gateway.readHostVerifiedApplicationResource(
            manifestResource,
            expectedSHA256: Data(SHA256.hash(data: manifestData)),
            maximumByteCount: 8_192,
            descriptor: descriptor
        )
        XCTAssertEqual(value, manifestData)

        let foreignResource = ApplicationResource(
            name: "module-manifest",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.test.runtime-io-other-owner"
        )
        let foreignDescriptor = authorizedResourceDescriptor(
            id: moduleID,
            role: RuneScribeRoles.progression,
            requiredResources: [foreignResource]
        )
        let ownerError = await runtimeError {
            _ = try await gateway.readHostVerifiedApplicationResource(
                foreignResource,
                expectedSHA256: Data(SHA256.hash(data: manifestData)),
                maximumByteCount: 8_192,
                descriptor: foreignDescriptor
            )
        }
        XCTAssertEqual(
            ownerError,
            .serviceAccessDenied(
                moduleID: moduleID,
                service: RuneScribeServiceIDs.applicationResourceLocator
            )
        )
        let state = await resources.state()
        XCTAssertEqual(state.dataRequests, [manifestResource])
    }

    func testManifestResourceRegistrationFailsOptionalAndThrowsForRequired() async throws {
        for criticality in [ModuleCriticality.optional, .required] {
            let suffix = criticality.rawValue
            let moduleID = ModuleIdentifier(
                rawValue: "com.runescribe.test.runtime-io-resource-registration-\(suffix)"
            )
            let resource = ApplicationResource(
                name: "module-manifest-\(suffix)",
                fileExtension: "json",
                ownerModuleID: moduleID
            )
            let descriptor = resourceRegistrationDescriptor(
                moduleID: moduleID,
                criticality: criticality,
                manifestResource: resource
            )
            let manifestData = try resourceRegistrationManifestData(for: descriptor)
            let resources = ApplicationResourceProbe(
                data: manifestData,
                url: URL(fileURLWithPath: "/tmp/module-manifest-\(suffix).json")
            )
            let runtime = RuneScribeRuntime(
                runtimeVersion: SemanticVersion(
                    major: UInt(1),
                    minor: UInt(0),
                    patch: UInt(0)
                ),
                platform: .macOS
            )
            try await runtime.installPlatformAdapter(
                resources,
                for: RuneScribeServiceKeys.applicationResourceLocator
            )
            let factory = AnyModuleFactory(descriptor: descriptor) {
                RuntimeIORegistrationProbeModule(descriptor: descriptor)
            }

            do {
                try await runtime.register(
                    manifestResource: resource,
                    expectedSHA256: Data(repeating: 0, count: SHA256.Digest.byteCount),
                    maximumByteCount: 16_384,
                    factory: factory
                )
                if criticality == .required {
                    XCTFail("A required manifest integrity failure must throw")
                }
            } catch {
                XCTAssertEqual(criticality, .required)
                XCTAssertEqual(
                    error as? RuntimeVerifiedApplicationResourceFailure,
                    .integrityMismatch
                )
            }

            let snapshot = await runtime.snapshot()
            if criticality == .optional {
                XCTAssertEqual(snapshot.moduleStates[moduleID], .failed)
            } else {
                XCTAssertNil(snapshot.moduleStates[moduleID])
            }
        }
    }

    func testMissingManifestResourceSurfacesFailedOptionalAvailability() async throws {
        let moduleID: ModuleIdentifier =
            "com.runescribe.test.runtime-io-missing-optional-manifest"
        let resource = ApplicationResource(
            name: "missing-module-manifest",
            fileExtension: "json",
            ownerModuleID: moduleID
        )
        let descriptor = resourceRegistrationDescriptor(
            moduleID: moduleID,
            criticality: .optional,
            manifestResource: resource
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            platform: .macOS
        )
        let factory = AnyModuleFactory(descriptor: descriptor) {
            RuntimeIORegistrationProbeModule(descriptor: descriptor)
        }

        try await runtime.register(
            manifestResource: resource,
            expectedSHA256: Data(repeating: 0, count: SHA256.Digest.byteCount),
            maximumByteCount: 16_384,
            factory: factory
        )

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.moduleStates[moduleID], .failed)
        let availability = await runtime.optionalAvailabilitySnapshots()
        XCTAssertEqual(
            availability,
            [
                RuntimeOptionalModuleAvailabilitySnapshot(
                    moduleID: moduleID,
                    role: RuneScribeRoles.progression,
                    lifecycleState: .failed
                ),
            ]
        )
    }

    func testApplicationResourceLeaseIsRevokedWhenSourceInvalidates() async throws {
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: URL(fileURLWithPath: "/tmp/runtime-io-resource-revoked.mp4")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-revoked",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 91
        )
        let session = try await client.applicationResourceSession(.splashVideo)
        let lease = try await session.acquire()
        let eventStream = await lease.events()
        let copiedLeaseEventStream = await lease.events()
        var events = eventStream.makeAsyncIterator()
        var copiedLeaseEvents = copiedLeaseEventStream.makeAsyncIterator()

        await gateway.invalidateModule(source.moduleID, generation: 91)

        let event = await events.next()
        XCTAssertEqual(event, .revoked)
        let copiedLeaseEvent = await copiedLeaseEvents.next()
        XCTAssertEqual(copiedLeaseEvent, .revoked)
        let terminalEvent = await events.next()
        XCTAssertNil(terminalEvent)
        let terminalCopiedLeaseEvent = await copiedLeaseEvents.next()
        XCTAssertNil(terminalCopiedLeaseEvent)
    }

    func testApplicationResourceLeasesRevokeIndependently() async throws {
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: URL(fileURLWithPath: "/tmp/runtime-io-resource-independent.mp4")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-independent",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 92
        )
        let session = try await client.applicationResourceSession(.splashVideo)
        let firstLease = try await session.acquire()
        let secondLease = try await session.acquire()
        let firstEventStream = await firstLease.events()
        let secondEventStream = await secondLease.events()
        var firstEvents = firstEventStream.makeAsyncIterator()
        var secondEvents = secondEventStream.makeAsyncIterator()

        await firstLease.close()
        let firstEvent = await firstEvents.next()
        XCTAssertNil(firstEvent)

        await gateway.invalidateModule(source.moduleID, generation: 92)
        let secondEvent = await secondEvents.next()
        XCTAssertEqual(secondEvent, .revoked)
        let terminalSecondEvent = await secondEvents.next()
        XCTAssertNil(terminalSecondEvent)

        let state = await resources.state()
        XCTAssertEqual(state.urlRequests, [.splashVideo, .splashVideo])
    }

    func testLateApplicationResourceLeaseIsNotIssuedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: URL(fileURLWithPath: "/tmp/runtime-io-resource-late.mp4"),
            urlBarrier: barrier
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-late",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 93
        )
        let session = try await client.applicationResourceSession(.splashVideo)
        let operation = Task {
            try await session.acquire()
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 93)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let state = await resources.state()
        XCTAssertEqual(state.urlRequests, [.splashVideo])
    }

    func testCancelledApplicationResourceAcquireDoesNotRegisterBinding() async throws {
        let barrier = RuntimeIOBarrier()
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: URL(fileURLWithPath: "/tmp/runtime-io-resource-cancelled.mp4"),
            urlBarrier: barrier
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-cancelled",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 94
        )
        let session = try await client.applicationResourceSession(.splashVideo)
        let operation = Task {
            try await session.acquire()
        }

        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()

        do {
            _ = try await operation.value
            XCTFail("A cancelled resource acquisition must not issue a lease")
        } catch is CancellationError {
            // Expected: cancellation is checked after the provider returns.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testDroppingApplicationResourceLeaseClosesBinding() async throws {
        let resources = ApplicationResourceProbe(
            data: Data(),
            url: URL(fileURLWithPath: "/tmp/runtime-io-resource-dropped.mp4")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-resource-dropped",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 95
        )
        let session = try await client.applicationResourceSession(.splashVideo)
        var lease: RuntimeApplicationResourceLease? = try await session.acquire()
        XCTAssertNotNil(lease)
        let activeBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(activeBindingCount, 1)

        lease = nil

        let bindingClosed = await resourceBindingCountEventuallyEquals(
            0,
            on: gateway
        )
        XCTAssertTrue(bindingClosed)
    }

    func testAuthorizedCoreBundledFontAndPrimaryUIResourceSession() async throws {
        let expectedData = Data("bundled-resource".utf8)
        let expectedURL = URL(fileURLWithPath: "/tmp/runtime-io-resource.mp4")
        let expectedRegistration = RegisteredFontDTO(
            postScriptName: "RuneScribeBundledFont-Regular"
        )
        let resources = ApplicationResourceProbe(
            data: expectedData,
            url: expectedURL
        )
        let fonts = SystemFontRegistrarProbe(
            postScriptName: "RuneScribeBundledFont-Regular",
            registeredFont: expectedRegistration
        )
        let gateway = await makeGateway(resources: resources, fonts: fonts)
        let core = authorizedBundledFontCoreDescriptor(
            id: "com.runescribe.test.runtime-io-core-resources"
        )
        let ui = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-ui-resources",
            role: RuneScribeRoles.primaryUI,
            requiredResources: [.splashVideo]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let coreClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: core,
            sourceGeneration: 91
        )
        let uiClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: ui,
            sourceGeneration: 92
        )

        let registered = try await coreClient.registerBundledSystemFont(
            .bundledRuneFont,
            expectedSHA256: Data(SHA256.hash(data: expectedData))
        )
        let session = try await uiClient.applicationResourceSession(.splashVideo)
        let lease = try await session.acquire()

        XCTAssertEqual(registered, expectedRegistration)
        XCTAssertEqual(lease.url, expectedURL)
        await lease.close()
        let state = await resources.state()
        XCTAssertEqual(state.dataRequests, [.bundledRuneFont])
        XCTAssertEqual(state.urlRequests, [.splashVideo])
        let fontState = await fonts.state()
        XCTAssertEqual(fontState.postScriptNameRequests, [expectedData])
        XCTAssertEqual(fontState.registrationRequests, [expectedData])
    }

    func testApplicationHostResourceOperationsAreDeniedBeforeProviderInvocation() async throws {
        let resources = ApplicationResourceProbe(
            data: Data("denied-resource".utf8),
            url: URL(fileURLWithPath: "/tmp/denied-resource")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-host-resources",
            role: RuneScribeRoles.applicationHost
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 93
        )
        let expectedError = RuneScribeRuntimeError.serviceAccessDenied(
            moduleID: source.moduleID,
            service: RuneScribeServiceIDs.applicationResourceLocator
        )

        let bundledFontError = await runtimeError {
            _ = try await client.registerBundledSystemFont(
                .bundledRuneFont,
                expectedSHA256: Data(repeating: 0, count: 32)
            )
        }
        let sessionError = await runtimeError {
            _ = try await client.applicationResourceSession(.splashVideo)
        }

        XCTAssertEqual(bundledFontError, expectedError)
        XCTAssertEqual(sessionError, expectedError)
        let state = await resources.state()
        XCTAssertTrue(state.dataRequests.isEmpty)
        XCTAssertTrue(state.urlRequests.isEmpty)
    }

    func testUnavailableApplicationResourceProviderFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-resources",
            role: RuneScribeRoles.core
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 94
        )
        let expectedError = RuneScribeRuntimeError.serviceUnavailable(
            RuneScribeServiceIDs.applicationResourceLocator
        )

        let bundledFontError = await runtimeError {
            _ = try await client.registerBundledSystemFont(
                .bundledRuneFont,
                expectedSHA256: Data(repeating: 0, count: 32)
            )
        }
        let sessionError = await runtimeError {
            _ = try await client.applicationResourceSession(.splashVideo)
        }

        XCTAssertEqual(bundledFontError, expectedError)
        XCTAssertEqual(sessionError, expectedError)
    }

    func testUndeclaredApplicationResourceIsDeniedBeforeProviderInvocation() async throws {
        let resources = ApplicationResourceProbe(
            data: Data("undeclared-resource".utf8),
            url: URL(fileURLWithPath: "/tmp/undeclared-resource")
        )
        let gateway = await makeGateway(resources: resources)
        let source = authorizedResourceDescriptor(
            id: "com.runescribe.test.runtime-io-undeclared-resource",
            role: RuneScribeRoles.core,
            requiredResources: [.bundledRuneFont]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 96
        )

        let error = await runtimeError {
            _ = try await client.registerBundledSystemFont(
                .splashVideo,
                expectedSHA256: Data(repeating: 0, count: 32)
            )
        }
        let sessionError = await runtimeError {
            _ = try await client.applicationResourceSession(.splashVideo)
        }

        XCTAssertEqual(
            error,
            .resourceNotDeclared(
                moduleID: source.moduleID,
                resource: .splashVideo
            )
        )
        XCTAssertEqual(
            sessionError,
            .resourceNotDeclared(
                moduleID: source.moduleID,
                resource: .splashVideo
            )
        )
        let state = await resources.state()
        XCTAssertTrue(state.dataRequests.isEmpty)
        XCTAssertTrue(state.urlRequests.isEmpty)
    }

    func testLateApplicationResourceResultIsRevokedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let resources = ApplicationResourceProbe(
            data: Data("late-resource".utf8),
            url: URL(fileURLWithPath: "/tmp/late-resource"),
            dataBarrier: barrier
        )
        let fonts = SystemFontRegistrarProbe(
            postScriptName: "LateResourceFont",
            registeredFont: RegisteredFontDTO(postScriptName: "LateResourceFont")
        )
        let gateway = await makeGateway(resources: resources, fonts: fonts)
        let source = authorizedBundledFontCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-resources"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 95
        )
        let operation = Task {
            try await client.registerBundledSystemFont(
                .bundledRuneFont,
                expectedSHA256: Data(SHA256.hash(data: Data("late-resource".utf8)))
            )
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 95)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let state = await resources.state()
        XCTAssertEqual(state.dataRequests, [.bundledRuneFont])
        XCTAssertTrue(state.urlRequests.isEmpty)
        let fontState = await fonts.state()
        XCTAssertTrue(fontState.postScriptNameRequests.isEmpty)
        XCTAssertTrue(fontState.registrationRequests.isEmpty)
    }

    func testAuthorizedCoreFontNameAndRegistrationForwardData() async throws {
        let nameData = Data("font-name-data".utf8)
        let registrationData = Data("font-registration-data".utf8)
        let expectedRegistration = RegisteredFontDTO(
            postScriptName: "RuneScribeTestFont-Regular"
        )
        let fonts = SystemFontRegistrarProbe(
            postScriptName: "RuneScribeTestFont-Name",
            registeredFont: expectedRegistration
        )
        let gateway = await makeGateway(fonts: fonts)
        let source = authorizedFontCoreDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-fonts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 101
        )

        let postScriptName = try await client.systemFontPostScriptName(
            for: nameData
        )
        let registeredFont = try await client.registerSystemFont(
            registrationData
        )

        XCTAssertEqual(postScriptName, "RuneScribeTestFont-Name")
        XCTAssertEqual(registeredFont, expectedRegistration)
        let state = await fonts.state()
        XCTAssertEqual(state.postScriptNameRequests, [nameData])
        XCTAssertEqual(state.registrationRequests, [registrationData])
    }

    func testUnavailableSystemFontRegistrarFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedFontCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-fonts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 102
        )
        let expectedError = RuneScribeRuntimeError.serviceUnavailable(
            RuneScribeServiceIDs.systemFontRegistrar
        )

        let nameError = await runtimeError {
            _ = try await client.systemFontPostScriptName(for: Data())
        }
        let registrationError = await runtimeError {
            _ = try await client.registerSystemFont(Data())
        }

        XCTAssertEqual(nameError, expectedError)
        XCTAssertEqual(registrationError, expectedError)
    }

    func testFontRoleAndCapabilityDenialsPrecedeProviderInvocation() async throws {
        let fonts = SystemFontRegistrarProbe(
            postScriptName: "DeniedFont",
            registeredFont: RegisteredFontDTO(postScriptName: "DeniedFont")
        )
        let gateway = await makeGateway(fonts: fonts)
        let roleDenied = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-fonts",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.fontRegistration],
            requiredServices: [RuneScribeServiceIDs.systemFontRegistrar]
        )
        let capabilityDenied = ioDescriptor(
            id: "com.runescribe.test.runtime-io-missing-font-capability",
            role: RuneScribeRoles.core,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.systemFontRegistrar]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let roleDeniedClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: roleDenied,
            sourceGeneration: 103
        )
        let capabilityDeniedClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: capabilityDenied,
            sourceGeneration: 104
        )

        let roleError = await runtimeError {
            _ = try await roleDeniedClient.systemFontPostScriptName(for: Data())
        }
        let capabilityError = await runtimeError {
            _ = try await capabilityDeniedClient.registerSystemFont(Data())
        }

        XCTAssertEqual(
            roleError,
            .serviceAccessDenied(
                moduleID: roleDenied.moduleID,
                service: RuneScribeServiceIDs.systemFontRegistrar
            )
        )
        XCTAssertEqual(
            capabilityError,
            .serviceCapabilityMissing(
                moduleID: capabilityDenied.moduleID,
                service: RuneScribeServiceIDs.systemFontRegistrar
            )
        )
        let state = await fonts.state()
        XCTAssertTrue(state.postScriptNameRequests.isEmpty)
        XCTAssertTrue(state.registrationRequests.isEmpty)
    }

    func testLateFontResultIsRevokedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let fontData = Data("late-font-data".utf8)
        let fonts = SystemFontRegistrarProbe(
            postScriptName: "LateFont",
            registeredFont: RegisteredFontDTO(postScriptName: "LateFont"),
            postScriptNameBarrier: barrier
        )
        let gateway = await makeGateway(fonts: fonts)
        let source = authorizedFontCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-fonts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 105
        )
        let operation = Task {
            try await client.systemFontPostScriptName(for: fontData)
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 105)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let state = await fonts.state()
        XCTAssertEqual(state.postScriptNameRequests, [fontData])
        XCTAssertTrue(state.registrationRequests.isEmpty)
    }

    func testSharePresentationAuthorizationDenialsPrecedeProviderInvocation() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-denied.txt")
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let undeclared = ioDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-undeclared",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.shareUI],
            requiredServices: []
        )
        let missingCapability = ioDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-no-capability",
            role: RuneScribeRoles.primaryUI,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.sharePresentation]
        )
        let wrongRole = ioDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-wrong-role",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.shareUI],
            requiredServices: [RuneScribeServiceIDs.sharePresentation]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let undeclaredClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: undeclared,
            sourceGeneration: 117
        )
        let missingCapabilityClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: missingCapability,
            sourceGeneration: 118
        )
        let wrongRoleClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: wrongRole,
            sourceGeneration: 119
        )

        let undeclaredError = await runtimeError {
            _ = try await undeclaredClient.sharePresentationSession(
                artifactID: artifactID
            )
        }
        let missingCapabilityError = await runtimeError {
            _ = try await missingCapabilityClient.sharePresentationSession(
                artifactID: artifactID
            )
        }
        let wrongRoleError = await runtimeError {
            _ = try await wrongRoleClient.sharePresentationSession(
                artifactID: artifactID
            )
        }

        XCTAssertEqual(
            undeclaredError,
            .serviceNotDeclared(
                moduleID: undeclared.moduleID,
                service: RuneScribeServiceIDs.sharePresentation
            )
        )
        XCTAssertEqual(
            missingCapabilityError,
            .serviceCapabilityMissing(
                moduleID: missingCapability.moduleID,
                service: RuneScribeServiceIDs.sharePresentation
            )
        )
        XCTAssertEqual(
            wrongRoleError,
            .serviceAccessDenied(
                moduleID: wrongRole.moduleID,
                service: RuneScribeServiceIDs.sharePresentation
            )
        )
        let state = await presentations.state()
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testSharePresentationSessionResolvesArtifactURLThroughSPILease() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        )
        let expectedURL = URL(
            fileURLWithPath: "/tmp/runtime-io-share-presentation.txt"
        )
        let presentations = SharePresentationProbe(url: expectedURL)
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-artifact"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 120
        )

        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        var state = await presentations.state()
        XCTAssertTrue(state.requests.isEmpty)

        let lease = try await session.acquire()
        XCTAssertEqual(lease.content, .artifact(expectedURL))
        state = await presentations.state()
        XCTAssertEqual(state.requests, [artifactID])
        let activeBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(activeBindingCount, 1)

        await lease.close()
        let closedBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(closedBindingCount, 0)
    }

    func testTextSharePresentationSessionCarriesTextAndCloses() async throws {
        let gateway = await makeGateway()
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-text"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 121
        )

        let session = try await client.textSharePresentationSession("rune text")
        let lease = try await session.acquire()
        XCTAssertEqual(lease.content, .text("rune text"))
        let activeBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(activeBindingCount, 1)

        let eventStream = await lease.events()
        var events = eventStream.makeAsyncIterator()
        await lease.close()
        let closeEvent = await events.next()
        XCTAssertNil(closeEvent)
        let closedBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(closedBindingCount, 0)
    }

    func testSharePresentationReportsNonterminalPresentationAndExactlyOneTerminalEvidence() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000012")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-evidence.txt")
        )
        let gateway = await makeGateway(
            sharePresentation: presentations,
            issueOperationContexts: true
        )
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-evidence"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 131
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        let lease = try await session.acquire()
        let eventStream = await lease.presentationEvents()
        var events = eventStream.makeAsyncIterator()

        try await lease.reportPresented(on: .airDrop)
        let presented = try SharePresentationReportDTO(
            routeClass: .airDrop,
            result: .presented
        )
        let presentedEvent = await events.next()
        let bindingCountAfterPresentation = await gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(presentedEvent, .presented(presented))
        XCTAssertEqual(bindingCountAfterPresentation, 1)

        let completed = try SharePresentationReportDTO(
            routeClass: .airDrop,
            result: .completedBySystem
        )
        let evidence = try await lease.finish(completed)
        XCTAssertEqual(evidence.artifactID, artifactID)
        XCTAssertEqual(evidence.report, completed)
        XCTAssertEqual(evidence.operationContext.authorityScope, .persistent)
        let completionEvent = await events.next()
        let endEvent = await events.next()
        let bindingCountAfterCompletion = await gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(completionEvent, .completed(evidence))
        XCTAssertNil(endEvent)
        XCTAssertEqual(bindingCountAfterCompletion, 0)

        let duplicateError = await runtimeError {
            _ = try await lease.finish(completed)
        }
        XCTAssertEqual(
            duplicateError,
            .serviceUnavailable(RuneScribeServiceIDs.sharePresentation)
        )
    }

    func testShareCompletionCapacityIsReservedBeforePlatformPresentation() async throws {
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-capacity.txt")
        )
        let gateway = await makeGateway(
            sharePresentation: presentations,
            issueOperationContexts: true
        )
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-capacity"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 132
        )
        var leases: [RuntimeSharePresentationLease] = []
        for index in 0..<64 {
            let artifactID = ShareArtifactID(
                rawValue: UUID(
                    uuidString: String(
                        format: "61000000-0000-0000-0000-%012x",
                        index
                    )
                )!
            )
            let session = try await client.sharePresentationSession(
                artifactID: artifactID
            )
            leases.append(try await session.acquire())
        }

        let overflowArtifactID = ShareArtifactID(
            rawValue: UUID(
                uuidString: "61000000-0000-0000-0000-000000000064"
            )!
        )
        let overflowSession = try await client.sharePresentationSession(
            artifactID: overflowArtifactID
        )
        do {
            _ = try await overflowSession.acquire()
            XCTFail("Expected terminal journal capacity backpressure")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .shareCompletionJournalFull
            )
        }
        let state = await presentations.state()
        XCTAssertEqual(state.requests.count, 64)
        XCTAssertFalse(state.requests.contains(overflowArtifactID))

        for lease in leases {
            await lease.close()
        }

        let recoveredSession = try await client.sharePresentationSession(
            artifactID: overflowArtifactID
        )
        let recoveredLease = try await recoveredSession.acquire()
        let recoveredState = await presentations.state()
        XCTAssertEqual(recoveredState.requests.count, 65)
        XCTAssertEqual(recoveredState.requests.last, overflowArtifactID)
        await recoveredLease.close()
    }

    func testTerminalJournalFinishIsRetryableAcrossCommitFaults() async throws {
        for (index, fault) in [
            (0, InMemoryModuleStateFaultPoint.beforeTransactionCommit),
            (1, InMemoryModuleStateFaultPoint.afterTransactionCommit),
        ] {
            let store = InMemoryModuleStateStore(
                now: { Date(timeIntervalSince1970: TimeInterval(9_200 + index)) }
            )
            let presentations = SharePresentationProbe(
                url: URL(fileURLWithPath: "/tmp/runtime-io-share-fault.txt")
            )
            let gateway = await makeGateway(
                sharePresentation: presentations,
                issueOperationContexts: true,
                moduleStateStore: store
            )
            let source = authorizedSharePresentationUIDescriptor(
                id: ModuleIdentifier(
                    rawValue: "com.runescribe.test.runtime-io-share-fault-\(index)"
                )
            )
            let runtimeGeneration = await gateway.currentGeneration()
            let client = try await activateClient(
                on: gateway,
                runtimeGeneration: runtimeGeneration,
                descriptor: source,
                sourceGeneration: UInt64(140 + index)
            )
            let artifactID = ShareArtifactID(
                rawValue: UUID(
                    uuidString: String(
                        format: "62000000-0000-0000-0000-%012x",
                        index
                    )
                )!
            )
            let session = try await client.sharePresentationSession(
                artifactID: artifactID
            )
            let lease = try await session.acquire()
            let report = try SharePresentationReportDTO(
                routeClass: .airDrop,
                result: .completedBySystem
            )
            await store.injectFault(at: fault)

            if fault == .beforeTransactionCommit {
                do {
                    _ = try await lease.finish(report)
                    XCTFail("Expected the first terminal journal write to fail")
                } catch ModuleStateStoreError.injectedFailure {}
                let retainedBindingCount = await gateway
                    .activeApplicationResourceBindingCount()
                XCTAssertEqual(retainedBindingCount, 1)
            }
            let evidence: ShareArtifactCompletionEvidenceDTO
            do {
                evidence = try await lease.finish(report)
            } catch {
                XCTFail("Terminal retry failed for \(fault): \(error)")
                continue
            }
            XCTAssertEqual(evidence.artifactID, artifactID)
            XCTAssertEqual(evidence.report, report)
            let finalBindingCount = await gateway
                .activeApplicationResourceBindingCount()
            XCTAssertEqual(finalBindingCount, 0)
        }
    }

    func testDroppingSharePresentationLeaseClosesBinding() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-dropped.txt")
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-dropped"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 122
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        var lease: RuntimeSharePresentationLease? = try await session.acquire()
        XCTAssertNotNil(lease)
        let activeBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(activeBindingCount, 1)

        lease = nil

        let bindingClosed = await resourceBindingCountEventuallyEquals(0, on: gateway)
        XCTAssertTrue(bindingClosed)
    }

    func testSharePresentationLeaseIsRevokedWhenModuleInvalidates() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000004")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-module-revoked.txt")
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-module-revoked"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 123
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        let lease = try await session.acquire()
        let eventStream = await lease.events()
        var events = eventStream.makeAsyncIterator()

        await gateway.invalidateModule(source.moduleID, generation: 123)

        let revocationEvent = await events.next()
        XCTAssertEqual(revocationEvent, .revoked)
        let terminalEvent = await events.next()
        XCTAssertNil(terminalEvent)
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testSharePresentationLeaseIsRevokedWhenRuntimeDeactivates() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000005")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-runtime-revoked.txt")
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-runtime-revoked"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 124
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        let lease = try await session.acquire()
        let eventStream = await lease.events()
        var events = eventStream.makeAsyncIterator()

        await gateway.deactivateRuntime()

        let revocationEvent = await events.next()
        XCTAssertEqual(revocationEvent, .revoked)
        let terminalEvent = await events.next()
        XCTAssertNil(terminalEvent)
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testRemovingShareArtifactRevokesOnlyMatchingPresentationLease() async throws {
        let removedArtifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        )
        let retainedArtifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000007")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-specific.txt")
        )
        let shareArtifacts = ShareArtifactStoreProbe()
        let gateway = await makeGateway(
            sharePresentation: presentations,
            shareArtifacts: shareArtifacts
        )
        let uiSource = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-specific-ui"
        )
        let coreSource = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-specific-core"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let uiClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: uiSource,
            sourceGeneration: 125
        )
        let coreClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: coreSource,
            sourceGeneration: 126
        )
        let removedSession = try await uiClient.sharePresentationSession(
            artifactID: removedArtifactID
        )
        let retainedSession = try await uiClient.sharePresentationSession(
            artifactID: retainedArtifactID
        )
        let removedLease = try await removedSession.acquire()
        let retainedLease = try await retainedSession.acquire()
        let removedEventStream = await removedLease.events()
        var removedEvents = removedEventStream.makeAsyncIterator()

        try await coreClient.removeShareArtifact(artifactID: removedArtifactID)

        let revocationEvent = await removedEvents.next()
        XCTAssertEqual(revocationEvent, .revoked)
        let terminalEvent = await removedEvents.next()
        XCTAssertNil(terminalEvent)
        let retainedBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(retainedBindingCount, 1)
        let artifactState = await shareArtifacts.state()
        XCTAssertEqual(artifactState.removeRequests, [removedArtifactID])

        await retainedLease.close()
        let closedBindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(closedBindingCount, 0)
    }

    func testRemovingAllShareArtifactsRevokesAllPresentationLeases() async throws {
        let firstArtifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000008")!
        )
        let secondArtifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000009")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-remove-all.txt")
        )
        let shareArtifacts = ShareArtifactStoreProbe()
        let gateway = await makeGateway(
            sharePresentation: presentations,
            shareArtifacts: shareArtifacts
        )
        let uiSource = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-remove-all-ui"
        )
        let coreSource = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-remove-all-core"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let uiClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: uiSource,
            sourceGeneration: 127
        )
        let coreClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: coreSource,
            sourceGeneration: 128
        )
        let firstSession = try await uiClient.sharePresentationSession(
            artifactID: firstArtifactID
        )
        let secondSession = try await uiClient.sharePresentationSession(
            artifactID: secondArtifactID
        )
        let firstLease = try await firstSession.acquire()
        let secondLease = try await secondSession.acquire()
        let firstEventStream = await firstLease.events()
        let secondEventStream = await secondLease.events()
        var firstEvents = firstEventStream.makeAsyncIterator()
        var secondEvents = secondEventStream.makeAsyncIterator()

        try await coreClient.removeAllShareArtifacts()

        let firstRevocationEvent = await firstEvents.next()
        let secondRevocationEvent = await secondEvents.next()
        XCTAssertEqual(firstRevocationEvent, .revoked)
        XCTAssertEqual(secondRevocationEvent, .revoked)
        let firstTerminalEvent = await firstEvents.next()
        let secondTerminalEvent = await secondEvents.next()
        XCTAssertNil(firstTerminalEvent)
        XCTAssertNil(secondTerminalEvent)
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
        let artifactState = await shareArtifacts.state()
        XCTAssertEqual(artifactState.removeAllInvocations, 1)
    }

    func testCancelledSharePresentationAcquireDoesNotRegisterBinding() async throws {
        let barrier = RuntimeIOBarrier()
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000010")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-cancelled.txt"),
            barrier: barrier
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-cancelled"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 129
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        let operation = Task {
            try await session.acquire()
        }

        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()

        do {
            _ = try await operation.value
            XCTFail("A cancelled presentation acquisition must not issue a lease")
        } catch is CancellationError {
            // Expected: cancellation is checked after URL resolution returns.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
        let state = await presentations.state()
        XCTAssertEqual(state.requests, [artifactID])
    }

    func testLateSharePresentationResolutionIsRevokedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000011")!
        )
        let presentations = SharePresentationProbe(
            url: URL(fileURLWithPath: "/tmp/runtime-io-share-late.txt"),
            barrier: barrier
        )
        let gateway = await makeGateway(sharePresentation: presentations)
        let source = authorizedSharePresentationUIDescriptor(
            id: "com.runescribe.test.runtime-io-share-presentation-late"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 130
        )
        let session = try await client.sharePresentationSession(
            artifactID: artifactID
        )
        let operation = Task {
            try await session.acquire()
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 130)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let bindingCount = await gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
        let state = await presentations.state()
        XCTAssertEqual(state.requests, [artifactID])
    }

    func testAuthorizedCoreShareArtifactOperationsForwardArgumentsAndResults() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let linkArtifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let payload = Data("share-payload".utf8)
        let link = URL(string: "runescribe://cipher/test#share-key")!
        let shareArtifacts = ShareArtifactStoreProbe()
        let gateway = await makeGateway(shareArtifacts: shareArtifacts)
        let source = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-authorized-share-artifacts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 111
        )

        try await client.createShareArtifact(
            payload,
            artifactID: artifactID,
            filename: "runtime-share",
            fileExtension: "txt"
        )
        try await client.storeShareArtifactLink(link, artifactID: linkArtifactID)
        try await client.removeShareArtifactLink(artifactID: linkArtifactID)
        try await client.removeShareArtifact(artifactID: artifactID)
        try await client.removeAllShareArtifacts()

        let state = await shareArtifacts.state()
        XCTAssertEqual(
            state.createRequests,
            [
                ShareArtifactCreateProbeRequest(
                    data: payload,
                    artifactID: artifactID,
                    filename: "runtime-share",
                    fileExtension: "txt"
                ),
            ]
        )
        XCTAssertEqual(
            state.storeLinkRequests,
            [
                ShareArtifactLinkProbeRequest(
                    url: link,
                    artifactID: linkArtifactID
                ),
            ]
        )
        XCTAssertEqual(state.removeLinkRequests, [linkArtifactID])
        XCTAssertEqual(state.removeRequests, [artifactID])
        XCTAssertEqual(state.removeAllInvocations, 1)
    }

    func testShareArtifactRoleAndCapabilityDenialsPrecedeProviderInvocation() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let shareArtifacts = ShareArtifactStoreProbe()
        let gateway = await makeGateway(shareArtifacts: shareArtifacts)
        let roleDenied = ioDescriptor(
            id: "com.runescribe.test.runtime-io-ui-share-artifacts",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.shareArtifactStorage],
            requiredServices: [RuneScribeServiceIDs.shareArtifactStore]
        )
        let capabilityDenied = ioDescriptor(
            id: "com.runescribe.test.runtime-io-missing-share-capability",
            role: RuneScribeRoles.core,
            capabilities: [],
            requiredServices: [RuneScribeServiceIDs.shareArtifactStore]
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let roleDeniedClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: roleDenied,
            sourceGeneration: 112
        )
        let capabilityDeniedClient = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: capabilityDenied,
            sourceGeneration: 113
        )

        let roleError = await runtimeError {
            _ = try await roleDeniedClient.createShareArtifact(
                Data(),
                artifactID: artifactID,
                filename: "denied-role",
                fileExtension: "txt"
            )
        }
        let capabilityError = await runtimeError {
            _ = try await capabilityDeniedClient.createShareArtifact(
                Data(),
                artifactID: artifactID,
                filename: "denied-capability",
                fileExtension: "txt"
            )
        }

        XCTAssertEqual(
            roleError,
            .serviceAccessDenied(
                moduleID: roleDenied.moduleID,
                service: RuneScribeServiceIDs.shareArtifactStore
            )
        )
        XCTAssertEqual(
            capabilityError,
            .serviceCapabilityMissing(
                moduleID: capabilityDenied.moduleID,
                service: RuneScribeServiceIDs.shareArtifactStore
            )
        )
        let state = await shareArtifacts.state()
        XCTAssertTrue(state.createRequests.isEmpty)
        XCTAssertTrue(state.storeLinkRequests.isEmpty)
        XCTAssertTrue(state.removeLinkRequests.isEmpty)
        XCTAssertTrue(state.removeRequests.isEmpty)
        XCTAssertEqual(state.removeAllInvocations, 0)
    }

    func testUnavailableShareArtifactProviderFailsClosed() async throws {
        let gateway = await makeGateway()
        let source = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-unavailable-share-artifacts"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 114
        )
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        )
        let link = URL(string: "runescribe://cipher/unavailable#share-key")!
        let expectedError = RuneScribeRuntimeError.serviceUnavailable(
            RuneScribeServiceIDs.shareArtifactStore
        )

        let createError = await runtimeError {
            _ = try await client.createShareArtifact(
                Data(),
                artifactID: artifactID,
                filename: "unavailable",
                fileExtension: "txt"
            )
        }
        let storeLinkError = await runtimeError {
            try await client.storeShareArtifactLink(link, artifactID: artifactID)
        }
        let removeLinkError = await runtimeError {
            try await client.removeShareArtifactLink(artifactID: artifactID)
        }
        let removeError = await runtimeError {
            try await client.removeShareArtifact(artifactID: artifactID)
        }
        let removeAllError = await runtimeError {
            try await client.removeAllShareArtifacts()
        }

        XCTAssertEqual(createError, expectedError)
        XCTAssertEqual(storeLinkError, expectedError)
        XCTAssertEqual(removeLinkError, expectedError)
        XCTAssertEqual(removeError, expectedError)
        XCTAssertEqual(removeAllError, expectedError)
    }

    func testShareArtifactProviderErrorIsPreservedWhileLeaseRemainsValid() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let shareArtifacts = ShareArtifactStoreProbe(
            createError: .providerFailure
        )
        let gateway = await makeGateway(shareArtifacts: shareArtifacts)
        let source = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-share-provider-error"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 115
        )

        do {
            _ = try await client.createShareArtifact(
                Data("failure".utf8),
                artifactID: artifactID,
                filename: "failure",
                fileExtension: "txt"
            )
            XCTFail("Expected the share-artifact provider error to be preserved.")
        } catch {
            XCTAssertEqual(error as? RuntimeIOProbeError, .providerFailure)
        }
        let state = await shareArtifacts.state()
        XCTAssertEqual(state.createRequests.count, 1)
    }

    func testLateShareArtifactCreateResultIsRevokedAfterSourceInvalidation() async throws {
        let barrier = RuntimeIOBarrier()
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let shareArtifacts = ShareArtifactStoreProbe(
            createBarrier: barrier
        )
        let gateway = await makeGateway(shareArtifacts: shareArtifacts)
        let source = authorizedShareArtifactCoreDescriptor(
            id: "com.runescribe.test.runtime-io-late-share-artifact"
        )
        let runtimeGeneration = await gateway.currentGeneration()
        let client = try await activateClient(
            on: gateway,
            runtimeGeneration: runtimeGeneration,
            descriptor: source,
            sourceGeneration: 116
        )
        let operation = Task {
            try await client.createShareArtifact(
                Data("late-share".utf8),
                artifactID: artifactID,
                filename: "late-share",
                fileExtension: "txt"
            )
        }

        await barrier.waitUntilEntered()
        await gateway.invalidateModule(source.moduleID, generation: 116)
        await barrier.release()

        let error = await runtimeError {
            _ = try await operation.value
        }
        XCTAssertEqual(error, .staleClient(source.moduleID))
        let state = await shareArtifacts.state()
        XCTAssertEqual(state.createRequests.count, 1)
    }

    private func runtimeError(
        from operation: () async throws -> Void
    ) async -> RuneScribeRuntimeError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? RuneScribeRuntimeError
        }
    }

    private func verifiedResourceFailure(
        from operation: () async throws -> Void
    ) async -> RuntimeVerifiedApplicationResourceFailure? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? RuntimeVerifiedApplicationResourceFailure
        }
    }
}

private struct SecureValueLookupProbeRequest: Equatable, Sendable {
    let service: String
    let account: String
}

private struct SecureValueSetProbeRequest: Equatable, Sendable {
    let data: Data
    let service: String
    let account: String
}

private struct SecureValueStoreProbeState: Equatable, Sendable {
    static let empty = SecureValueStoreProbeState(
        dataRequests: [],
        setRequests: [],
        deleteRequests: []
    )

    let dataRequests: [SecureValueLookupProbeRequest]
    let setRequests: [SecureValueSetProbeRequest]
    let deleteRequests: [SecureValueLookupProbeRequest]
}

private actor SecureValueStoreProbe: SecureValueStore {
    private let dataResult: Data?
    private let dataBarrier: RuntimeIOBarrier?
    private var dataRequests: [SecureValueLookupProbeRequest] = []
    private var setRequests: [SecureValueSetProbeRequest] = []
    private var deleteRequests: [SecureValueLookupProbeRequest] = []

    init(
        dataResult: Data?,
        dataBarrier: RuntimeIOBarrier? = nil
    ) {
        self.dataResult = dataResult
        self.dataBarrier = dataBarrier
    }

    func data(service: String, account: String) async throws -> Data? {
        dataRequests.append(
            SecureValueLookupProbeRequest(service: service, account: account)
        )
        if let dataBarrier {
            await dataBarrier.enterAndWait()
        }
        return dataResult
    }

    func set(_ data: Data, service: String, account: String) async throws {
        setRequests.append(
            SecureValueSetProbeRequest(
                data: data,
                service: service,
                account: account
            )
        )
    }

    func delete(service: String, account: String) async throws {
        deleteRequests.append(
            SecureValueLookupProbeRequest(service: service, account: account)
        )
    }

    func state() -> SecureValueStoreProbeState {
        SecureValueStoreProbeState(
            dataRequests: dataRequests,
            setRequests: setRequests,
            deleteRequests: deleteRequests
        )
    }
}

private struct ProtectedFileWriteProbeRequest: Equatable, Sendable {
    let data: Data
    let path: ProtectedPath
}

private struct ProtectedFileContentsProbeRequest: Equatable, Sendable {
    let directory: ProtectedPath
    let fileExtension: String?
}

private struct ProtectedFileStoreProbeState: Equatable, Sendable {
    static let empty = ProtectedFileStoreProbeState(
        readRequests: [],
        writeRequests: [],
        removeRequests: [],
        existsRequests: [],
        contentsRequests: []
    )

    let readRequests: [ProtectedPath]
    let writeRequests: [ProtectedFileWriteProbeRequest]
    let removeRequests: [ProtectedPath]
    let existsRequests: [ProtectedPath]
    let contentsRequests: [ProtectedFileContentsProbeRequest]
}

private actor ProtectedFileStoreProbe: ProtectedFileStore {
    private let readResult: Data?
    private let existsResult: Bool
    private let contentsResult: [ProtectedPath]
    private let readBarrier: RuntimeIOBarrier?
    private var readRequests: [ProtectedPath] = []
    private var writeRequests: [ProtectedFileWriteProbeRequest] = []
    private var removeRequests: [ProtectedPath] = []
    private var existsRequests: [ProtectedPath] = []
    private var contentsRequests: [ProtectedFileContentsProbeRequest] = []

    init(
        readResult: Data?,
        existsResult: Bool,
        contentsResult: [ProtectedPath],
        readBarrier: RuntimeIOBarrier? = nil
    ) {
        self.readResult = readResult
        self.existsResult = existsResult
        self.contentsResult = contentsResult
        self.readBarrier = readBarrier
    }

    func read(relativePath: ProtectedPath) async throws -> Data? {
        readRequests.append(relativePath)
        if let readBarrier {
            await readBarrier.enterAndWait()
        }
        return readResult
    }

    func write(_ data: Data, relativePath: ProtectedPath) async throws {
        writeRequests.append(
            ProtectedFileWriteProbeRequest(data: data, path: relativePath)
        )
    }

    func remove(relativePath: ProtectedPath) async throws {
        removeRequests.append(relativePath)
    }

    func exists(relativePath: ProtectedPath) async throws -> Bool {
        existsRequests.append(relativePath)
        return existsResult
    }

    func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        contentsRequests.append(
            ProtectedFileContentsProbeRequest(
                directory: directory,
                fileExtension: fileExtension
            )
        )
        return contentsResult
    }

    func state() -> ProtectedFileStoreProbeState {
        ProtectedFileStoreProbeState(
            readRequests: readRequests,
            writeRequests: writeRequests,
            removeRequests: removeRequests,
            existsRequests: existsRequests,
            contentsRequests: contentsRequests
        )
    }
}

private final class ClockProbe: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Date
    private var invocations = 0

    init(result: Date) {
        self.result = result
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        invocations += 1
        return result
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private final class UUIDProbe: UUIDProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let result: UUID
    private var invocations = 0

    init(result: UUID) {
        self.result = result
    }

    func nextUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        invocations += 1
        return result
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private struct ClipboardProbeState: Equatable, Sendable {
    let string: String?
    let changeCount: Int
    let readInvocations: Int
    let writeInvocations: Int
}

private actor CountingClipboardProbe: ClipboardReading, ClipboardWriting {
    private var storedString: String?
    private var counter: Int
    private var readCount = 0
    private var writeCount = 0

    init(string: String?, changeCount: Int) {
        storedString = string
        counter = changeCount
    }

    func changeCount() async -> Int {
        readCount += 1
        return counter
    }

    func string() async -> String? {
        readCount += 1
        return storedString
    }

    func setString(_ value: String) async throws {
        writeCount += 1
        storedString = value
        counter += 1
    }

    func state() -> ClipboardProbeState {
        ClipboardProbeState(
            string: storedString,
            changeCount: counter,
            readInvocations: readCount,
            writeInvocations: writeCount
        )
    }
}

private struct ContactAccessProbeState: Equatable, Sendable {
    let authorizationStatusInvocations: Int
    let requestAccessInvocations: Int
    let fetchContactsInvocations: Int
}

private actor ContactAccessProbe: ContactAccessService {
    private let status: ContactAuthorizationDTO
    private let requestResult: Bool
    private let contacts: [SystemContactDTO]
    private let fetchBarrier: RuntimeIOBarrier?
    private var authorizationStatusInvocationCount = 0
    private var requestAccessInvocationCount = 0
    private var fetchContactsInvocationCount = 0

    init(
        authorizationStatus: ContactAuthorizationDTO,
        requestResult: Bool,
        contacts: [SystemContactDTO],
        fetchBarrier: RuntimeIOBarrier? = nil
    ) {
        status = authorizationStatus
        self.requestResult = requestResult
        self.contacts = contacts
        self.fetchBarrier = fetchBarrier
    }

    func authorizationStatus() async -> ContactAuthorizationDTO {
        authorizationStatusInvocationCount += 1
        return status
    }

    func requestAccess() async throws -> Bool {
        requestAccessInvocationCount += 1
        return requestResult
    }

    func fetchContacts() async throws -> [SystemContactDTO] {
        fetchContactsInvocationCount += 1
        if let fetchBarrier {
            await fetchBarrier.enterAndWait()
        }
        return contacts
    }

    func state() -> ContactAccessProbeState {
        ContactAccessProbeState(
            authorizationStatusInvocations: authorizationStatusInvocationCount,
            requestAccessInvocations: requestAccessInvocationCount,
            fetchContactsInvocations: fetchContactsInvocationCount
        )
    }
}

private struct InboundFileProbeState: Equatable, Sendable {
    let requests: [RuntimeInboundFileReadRequest]
}

private actor InboundFileProbe: InboundFileReader {
    private let data: Data
    private let error: InboundFileReaderError?
    private let barrier: RuntimeIOBarrier?
    private var requests: [RuntimeInboundFileReadRequest] = []

    init(
        data: Data = Data(),
        error: InboundFileReaderError? = nil,
        barrier: RuntimeIOBarrier? = nil
    ) {
        self.data = data
        self.error = error
        self.barrier = barrier
    }

    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        requests.append(
            RuntimeInboundFileReadRequest(
                fileURL: fileURL,
                requiresSecurityScopedAccess: requiresSecurityScope,
                maximumByteCount: maximumByteCount
            )
        )
        if let barrier {
            await barrier.enterAndWait()
        }
        if let error {
            throw error
        }
        return data
    }

    func state() -> InboundFileProbeState {
        InboundFileProbeState(requests: requests)
    }
}

private actor InboundImportDeliveryProbe {
    private let result: ImportResultDTO
    private var inputs: [InboundFileDTO] = []

    init(result: ImportResultDTO) {
        self.result = result
    }

    func deliver(_ input: InboundFileDTO) throws -> ImportResultDTO {
        inputs.append(input)
        return result
    }

    func snapshot() -> [InboundFileDTO] {
        inputs
    }
}

private struct ApplicationResourceBoundedProbeRequest: Equatable, Sendable {
    let resource: ApplicationResource
    let maximumByteCount: Int
}

private struct ApplicationResourceProbeState: Equatable, Sendable {
    let dataRequests: [ApplicationResource]
    let boundedDataRequests: [ApplicationResourceBoundedProbeRequest]
    let urlRequests: [ApplicationResource]
}

private actor ApplicationResourceProbe: ApplicationResourceLocator {
    private let dataResult: Data
    private let urlResult: URL
    private let dataBarrier: RuntimeIOBarrier?
    private let urlBarrier: RuntimeIOBarrier?
    private var dataRequests: [ApplicationResource] = []
    private var boundedDataRequests: [ApplicationResourceBoundedProbeRequest] = []
    private var urlRequests: [ApplicationResource] = []

    init(
        data: Data,
        url: URL,
        dataBarrier: RuntimeIOBarrier? = nil,
        urlBarrier: RuntimeIOBarrier? = nil
    ) {
        dataResult = data
        urlResult = url
        self.dataBarrier = dataBarrier
        self.urlBarrier = urlBarrier
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        dataRequests.append(resource)
        if let dataBarrier {
            await dataBarrier.enterAndWait()
        }
        return dataResult
    }

    func data(
        for resource: ApplicationResource,
        maximumByteCount: Int
    ) async throws -> Data {
        boundedDataRequests.append(
            ApplicationResourceBoundedProbeRequest(
                resource: resource,
                maximumByteCount: maximumByteCount
            )
        )
        return try await data(for: resource)
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        urlRequests.append(resource)
        if let urlBarrier {
            await urlBarrier.enterAndWait()
        }
        return urlResult
    }

    func state() -> ApplicationResourceProbeState {
        ApplicationResourceProbeState(
            dataRequests: dataRequests,
            boundedDataRequests: boundedDataRequests,
            urlRequests: urlRequests
        )
    }
}

private struct SystemFontRegistrarProbeState: Equatable, Sendable {
    let postScriptNameRequests: [Data]
    let registrationRequests: [Data]
}

private actor SystemFontRegistrarProbe: SystemFontRegistrar {
    private let postScriptNameResult: String
    private let registeredFontResult: RegisteredFontDTO
    private let postScriptNameBarrier: RuntimeIOBarrier?
    private var postScriptNameRequests: [Data] = []
    private var registrationRequests: [Data] = []

    init(
        postScriptName: String,
        registeredFont: RegisteredFontDTO,
        postScriptNameBarrier: RuntimeIOBarrier? = nil
    ) {
        postScriptNameResult = postScriptName
        registeredFontResult = registeredFont
        self.postScriptNameBarrier = postScriptNameBarrier
    }

    func postScriptName(forFontData data: Data) async throws -> String {
        postScriptNameRequests.append(data)
        if let postScriptNameBarrier {
            await postScriptNameBarrier.enterAndWait()
        }
        return postScriptNameResult
    }

    func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        registrationRequests.append(data)
        return registeredFontResult
    }

    func state() -> SystemFontRegistrarProbeState {
        SystemFontRegistrarProbeState(
            postScriptNameRequests: postScriptNameRequests,
            registrationRequests: registrationRequests
        )
    }
}

private struct ShareArtifactCreateProbeRequest: Equatable, Sendable {
    let data: Data
    let artifactID: ShareArtifactID
    let filename: String
    let fileExtension: String
}

private struct SharePresentationProbeState: Equatable, Sendable {
    let requests: [ShareArtifactID]
}

private actor SharePresentationProbe: SharePresentationProviding {
    private let url: URL
    private let barrier: RuntimeIOBarrier?
    private var requests: [ShareArtifactID] = []

    init(url: URL, barrier: RuntimeIOBarrier? = nil) {
        self.url = url
        self.barrier = barrier
    }

    func presentationURL(for artifactID: ShareArtifactID) async throws -> URL {
        requests.append(artifactID)
        if let barrier {
            await barrier.enterAndWait()
        }
        return url
    }

    func state() -> SharePresentationProbeState {
        SharePresentationProbeState(requests: requests)
    }
}

private struct ShareArtifactLinkProbeRequest: Equatable, Sendable {
    let url: URL
    let artifactID: ShareArtifactID
}

private struct ShareArtifactStoreProbeState: Equatable, Sendable {
    let createRequests: [ShareArtifactCreateProbeRequest]
    let storeLinkRequests: [ShareArtifactLinkProbeRequest]
    let removeLinkRequests: [ShareArtifactID]
    let removeRequests: [ShareArtifactID]
    let removeAllInvocations: Int
}

private actor ShareArtifactStoreProbe: ShareArtifactStore {
    private let createBarrier: RuntimeIOBarrier?
    private let createError: RuntimeIOProbeError?
    private var createRequests: [ShareArtifactCreateProbeRequest] = []
    private var storeLinkRequests: [ShareArtifactLinkProbeRequest] = []
    private var removeLinkRequests: [ShareArtifactID] = []
    private var removeRequests: [ShareArtifactID] = []
    private var removeAllInvocationCount = 0

    init(
        createBarrier: RuntimeIOBarrier? = nil,
        createError: RuntimeIOProbeError? = nil
    ) {
        self.createBarrier = createBarrier
        self.createError = createError
    }

    func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws {
        createRequests.append(
            ShareArtifactCreateProbeRequest(
                data: data,
                artifactID: artifactID,
                filename: filename,
                fileExtension: fileExtension
            )
        )
        if let createBarrier {
            await createBarrier.enterAndWait()
        }
        if let createError {
            throw createError
        }
    }

    func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws {
        storeLinkRequests.append(
            ShareArtifactLinkProbeRequest(url: url, artifactID: artifactID)
        )
    }

    func removeLink(artifactID: ShareArtifactID) async throws {
        removeLinkRequests.append(artifactID)
    }

    func remove(artifactID: ShareArtifactID) async throws {
        removeRequests.append(artifactID)
    }

    func removeAll() async throws {
        removeAllInvocationCount += 1
    }

    func state() -> ShareArtifactStoreProbeState {
        ShareArtifactStoreProbeState(
            createRequests: createRequests,
            storeLinkRequests: storeLinkRequests,
            removeLinkRequests: removeLinkRequests,
            removeRequests: removeRequests,
            removeAllInvocations: removeAllInvocationCount
        )
    }
}

private actor RuntimeIOBarrier {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor SuspendingClipboardReader: ClipboardReading {
    private let barrier: RuntimeIOBarrier
    private let storedString: String?
    private let counter: Int
    private var hasSuspended = false

    init(
        barrier: RuntimeIOBarrier,
        string: String?,
        changeCount: Int
    ) {
        self.barrier = barrier
        storedString = string
        counter = changeCount
    }

    func changeCount() async -> Int {
        if !hasSuspended {
            hasSuspended = true
            await barrier.enterAndWait()
        }
        return counter
    }

    func string() async -> String? {
        storedString
    }
}

private actor SuspendingFailingClipboardWriter: ClipboardWriting {
    private let barrier: RuntimeIOBarrier

    init(barrier: RuntimeIOBarrier) {
        self.barrier = barrier
    }

    func setString(_ value: String) async throws {
        await barrier.enterAndWait()
        throw RuntimeIOProbeError.providerFailure
    }
}

private struct FailingClipboardWriter: ClipboardWriting {
    func setString(_ value: String) async throws {
        throw RuntimeIOProbeError.providerFailure
    }
}

private enum RuntimeIOProbeError: Error, Equatable, Sendable {
    case providerFailure
}

private func makeGateway(
    secureValues: (any SecureValueStore)? = nil,
    protectedFiles: (any ProtectedFileStore)? = nil,
    clock: (any ClockProviding)? = nil,
    uuid: (any UUIDProviding)? = nil,
    reader: (any ClipboardReading)? = nil,
    writer: (any ClipboardWriting)? = nil,
    contacts: (any ContactAccessService)? = nil,
    inboundFiles: (any InboundFileReader)? = nil,
    resources: (any ApplicationResourceLocator)? = nil,
    fonts: (any SystemFontRegistrar)? = nil,
    sharePresentation: (any SharePresentationProviding)? = nil,
    shareArtifacts: (any ShareArtifactStore)? = nil,
    issueOperationContexts: Bool = false,
    moduleStateStore: InMemoryModuleStateStore? = nil,
    environment: RuntimeEnvironment = .live
) async -> RuntimeIOGateway {
    let operationContextAuthority: RuntimeProgressionOutbox?
    if issueOperationContexts {
        let state = RuntimeModuleStateGateway(policy: .patternBFoundation)
        try! await state.install(moduleStateStore ?? InMemoryModuleStateStore())
        _ = await state.activateRuntime()
        let authority = RuntimeProgressionOutbox(
            state: state,
            dispatcher: RuntimeOperationDispatcher(
                policy: .patternBFoundation,
                environment: environment
            ),
            environment: environment
        )
        await authority.activateRuntime()
        operationContextAuthority = authority
    } else {
        operationContextAuthority = nil
    }
    let gateway = RuntimeIOGateway(
        policy: .patternBFoundation,
        environment: environment,
        operationContextAuthority: operationContextAuthority
    )
    if let secureValues {
        await gateway.install(secureValues)
    }
    if let protectedFiles {
        await gateway.install(protectedFiles)
    }
    if let clock {
        await gateway.install(clock)
    }
    if let uuid {
        await gateway.install(uuid)
    }
    if let reader {
        await gateway.install(reader)
    }
    if let writer {
        await gateway.install(writer)
    }
    if let contacts {
        await gateway.install(contacts)
    }
    if let inboundFiles {
        await gateway.install(inboundFiles)
    }
    if let resources {
        await gateway.install(resources)
    }
    if let fonts {
        await gateway.install(fonts)
    }
    if let sharePresentation {
        await gateway.install(sharePresentation)
    }
    if let shareArtifacts {
        await gateway.install(shareArtifacts)
    }
    await gateway.activateRuntime()
    return gateway
}

private func activateClient(
    on gateway: RuntimeIOGateway,
    runtimeGeneration: UInt64,
    descriptor: ModuleDescriptor,
    sourceGeneration: UInt64
) async throws -> RuntimeIOClient {
    try await gateway.activateModule(
        descriptor: descriptor,
        generation: sourceGeneration
    )
    return try await gateway.makeClient(
        sourceModuleID: descriptor.moduleID,
        sourceModuleGeneration: sourceGeneration,
        runtimeGeneration: runtimeGeneration
    )
}

private func resourceBindingCountEventuallyEquals(
    _ expectedCount: Int,
    on gateway: RuntimeIOGateway
) async -> Bool {
    for _ in 0..<1_000 {
        if await gateway.activeApplicationResourceBindingCount() == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

private func authorizedCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [RuneScribeCapabilities.clipboardRead],
        requiredServices: [RuneScribeServiceIDs.clipboardRead]
    )
}

private func authorizedSystemIOCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [
            RuneScribeCapabilities.keychainStorage,
            RuneScribeCapabilities.protectedFileStorage,
            RuneScribeCapabilities.clockRead,
            RuneScribeCapabilities.uuidGenerate,
        ],
        requiredServices: [
            RuneScribeServiceIDs.secureValueStore,
            RuneScribeServiceIDs.protectedFileStore,
            RuneScribeServiceIDs.clock,
            RuneScribeServiceIDs.uuid,
        ]
    )
}

private func authorizedUIDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.primaryUI,
        capabilities: [RuneScribeCapabilities.clipboardWrite],
        requiredServices: [RuneScribeServiceIDs.clipboardWrite]
    )
}

private func authorizedContactCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [RuneScribeCapabilities.contactRead],
        requiredServices: [RuneScribeServiceIDs.contactAccess]
    )
}

private func authorizedInboundCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [RuneScribeCapabilities.inboundFileRead],
        requiredServices: [RuneScribeServiceIDs.inboundFileReader]
    )
}

private func authorizedInboundImportUIDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.primaryUI,
        capabilities: [RuneScribeCapabilities.fileImportUI],
        requiredServices: []
    )
}

private func authorizedResourceDescriptor(
    id: ModuleIdentifier,
    role: ModuleRole,
    requiredResources: Set<ApplicationResource> = [
        .bundledRuneFont,
        .splashVideo,
        .defaultMetalLibrary,
    ]
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: role,
        capabilities: [RuneScribeCapabilities.resourceRead],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: requiredResources
    )
}

private struct RuntimeIORegistrationProbeModule: RuneScribeModule {
    let descriptor: ModuleDescriptor

    func start(context: ModuleContext) async throws {}
    func stop() async {}
}

private func resourceRegistrationDescriptor(
    moduleID: ModuleIdentifier,
    criticality: ModuleCriticality,
    manifestResource: ApplicationResource
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(0)
        ),
        kind: .service,
        criticality: criticality,
        entryPoint: "RuntimeIORegistrationProbeModule-\(criticality.rawValue)",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [RuneScribeCapabilities.resourceRead],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: [manifestResource]
    )
}

private func resourceRegistrationManifestData(
    for descriptor: ModuleDescriptor
) throws -> Data {
    let manifest = ModuleManifest(
        runtimeVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(0)
        ),
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredResources: Array(descriptor.requiredResources),
            requiredModuleRoles: []
        ),
        defaultRole: descriptor.role
    )
    return try JSONEncoder().encode(manifest)
}

private func authorizedBundledFontCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.fontRegistration,
        ],
        requiredServices: [
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.systemFontRegistrar,
        ],
        requiredResources: [.bundledRuneFont]
    )
}

private func authorizedFontCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [RuneScribeCapabilities.fontRegistration],
        requiredServices: [RuneScribeServiceIDs.systemFontRegistrar]
    )
}

private func authorizedShareArtifactCoreDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.core,
        capabilities: [RuneScribeCapabilities.shareArtifactStorage],
        requiredServices: [RuneScribeServiceIDs.shareArtifactStore]
    )
}

private func authorizedSharePresentationUIDescriptor(
    id: ModuleIdentifier
) -> ModuleDescriptor {
    ioDescriptor(
        id: id,
        role: RuneScribeRoles.primaryUI,
        capabilities: [RuneScribeCapabilities.shareUI],
        requiredServices: [RuneScribeServiceIDs.sharePresentation]
    )
}

private func inboundRequest(
    maximumByteCount: Int
) -> RuntimeInboundFileReadRequest {
    RuntimeInboundFileReadRequest(
        fileURL: URL(fileURLWithPath: "/tmp/runtime-io-inbound.runescribe"),
        requiresSecurityScopedAccess: false,
        maximumByteCount: maximumByteCount
    )
}

private func ioDescriptor(
    id: ModuleIdentifier,
    role: ModuleRole,
    capabilities: Set<CapabilityIdentifier>,
    requiredServices: Set<ServiceIdentifier>,
    requiredResources: Set<ApplicationResource> = []
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: id,
        moduleVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(34)
        ),
        kind: role == RuneScribeRoles.primaryUI ? .ui : .service,
        entryPoint: "RuntimeIOGatewayTestModule",
        role: role,
        requestedCapabilities: capabilities,
        requiredServices: requiredServices,
        requiredResources: requiredResources,
        publishedServices: [],
        requiredModuleRoles: [],
        consumedEndpoints: [],
        publishedEndpoints: []
    )
}

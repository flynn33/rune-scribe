import Foundation
import RuneScribeContracts
@testable import RuneScribeRuntimeCore
import XCTest

@MainActor
final class RuntimeContributionRegistryTests: XCTestCase {
    private let publishCapability = CapabilityIdentifier(
        rawValue: "runtime.contributions.publish"
    )
    private let readCapability = CapabilityIdentifier(
        rawValue: "runtime.contributions.read"
    )

    func testIdentifiersAcceptOnlyStableBoundedSyntax() throws {
        XCTAssertEqual(
            RuntimeContributionTypeID(rawValue: "runtime.sample-items")?.rawValue,
            "runtime.sample-items"
        )
        XCTAssertEqual(
            RuntimeContributionKey(rawValue: "sample.item-01")?.rawValue,
            "sample.item-01"
        )

        for invalid in [
            "",
            ".leading",
            "trailing-",
            "double..separator",
            "Uppercase",
            "contains_underscore",
            "nonascii-\u{00E9}",
            String(repeating: "a", count: 97),
        ] {
            XCTAssertNil(RuntimeContributionTypeID(rawValue: invalid))
            XCTAssertNil(RuntimeContributionKey(rawValue: invalid))
        }

        let encoded = try JSONEncoder().encode(
            XCTUnwrap(RuntimeContributionTypeID(rawValue: "runtime.sample-items"))
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeContributionTypeID.self, from: encoded),
            RuntimeContributionTypeID(rawValue: "runtime.sample-items")
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RuntimeContributionKey.self,
                from: Data("\"invalid key\"".utf8)
            )
        )
    }

    func testPublishingTracksOwnerRejectsGlobalDuplicateAndOrdersSnapshot() async throws {
        let registry = makeRegistry()
        let runtimeGeneration = await registry.activateRuntime()
        let first = descriptor(
            moduleID: "com.runescribe.test.contributor.first",
            capabilities: [publishCapability]
        )
        let second = descriptor(
            moduleID: "com.runescribe.test.contributor.second",
            capabilities: [publishCapability]
        )
        let reader = descriptor(
            moduleID: "com.runescribe.test.contributor.reader",
            capabilities: [readCapability]
        )
        try await registry.activateModule(descriptor: first, generation: 3)
        try await registry.activateModule(descriptor: second, generation: 5)
        try await registry.activateModule(descriptor: reader, generation: 7)
        let firstPublisher = try await registry.makePublisherClient(
            sourceModuleID: first.moduleID,
            sourceModuleGeneration: 3,
            runtimeGeneration: runtimeGeneration
        )
        let secondPublisher = try await registry.makePublisherClient(
            sourceModuleID: second.moduleID,
            sourceModuleGeneration: 5,
            runtimeGeneration: runtimeGeneration
        )
        let readClient = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 7,
            runtimeGeneration: runtimeGeneration
        )
        let type = RuntimeContributionType<TestContribution>(
            id: try XCTUnwrap(RuntimeContributionTypeID(rawValue: "runtime.sample"))
        )
        let laterKey = try XCTUnwrap(
            RuntimeContributionKey(rawValue: "sample.zulu")
        )
        let earlierKey = try XCTUnwrap(
            RuntimeContributionKey(rawValue: "sample.alpha")
        )

        let firstEntry = try await firstPublisher.publish(
            TestContribution(label: "later"),
            type: type,
            key: laterKey
        )
        XCTAssertEqual(firstEntry.publishedRevision, 1)
        XCTAssertEqual(
            firstEntry.owner,
            RuntimeContributionOwner(
                moduleID: first.moduleID,
                moduleGeneration: 3,
                runtimeGeneration: runtimeGeneration
            )
        )
        let secondEntry = try await secondPublisher.publish(
            TestContribution(label: "earlier"),
            type: type,
            key: earlierKey
        )
        XCTAssertEqual(secondEntry.publishedRevision, 2)

        do {
            _ = try await secondPublisher.publish(
                TestContribution(label: "duplicate"),
                type: type,
                key: laterKey
            )
            XCTFail("A contribution key must be globally unique")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .duplicateKey(laterKey)
            )
        }

        let snapshot = try await readClient.snapshot(for: type)
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.runtimeGeneration, runtimeGeneration)
        XCTAssertEqual(snapshot.entries.map(\.key), [earlierKey, laterKey])
        XCTAssertEqual(snapshot.entries.map(\.value.label), ["earlier", "later"])
    }

    func testTypeMismatchesAndForeignRemovalAreRejected() async throws {
        let registry = makeRegistry()
        let runtimeGeneration = await registry.activateRuntime()
        let owner = descriptor(
            moduleID: "com.runescribe.test.contributor.owner",
            capabilities: [publishCapability]
        )
        let foreignOwner = descriptor(
            moduleID: "com.runescribe.test.contributor.foreign",
            capabilities: [publishCapability]
        )
        let reader = descriptor(
            moduleID: "com.runescribe.test.contributor.reader",
            capabilities: [readCapability]
        )
        try await registry.activateModule(descriptor: owner, generation: 1)
        try await registry.activateModule(descriptor: foreignOwner, generation: 1)
        try await registry.activateModule(descriptor: reader, generation: 1)
        let publisher = try await registry.makePublisherClient(
            sourceModuleID: owner.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration
        )
        let foreignPublisher = try await registry.makePublisherClient(
            sourceModuleID: foreignOwner.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration
        )
        let readClient = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration
        )
        let typeID = try XCTUnwrap(
            RuntimeContributionTypeID(rawValue: "runtime.typed-sample")
        )
        let typed = RuntimeContributionType<TestContribution>(id: typeID)
        let wrongValueType = RuntimeContributionType<Int>(id: typeID)
        let otherType = RuntimeContributionType<TestContribution>(
            id: try XCTUnwrap(
                RuntimeContributionTypeID(rawValue: "runtime.other-sample")
            )
        )
        let key = try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.one"))
        let secondKey = try XCTUnwrap(
            RuntimeContributionKey(rawValue: "sample.two")
        )
        _ = try await publisher.publish(
            TestContribution(label: "one"),
            type: typed,
            key: key
        )

        do {
            _ = try await publisher.publish(2, type: wrongValueType, key: secondKey)
            XCTFail("A stable type identifier must not change its Swift value type")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .valueTypeMismatch(typeID)
            )
        }

        do {
            _ = try await readClient.entry(for: key, as: otherType)
            XCTFail("A key lookup must reject the wrong contribution type")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .keyTypeMismatch(
                    key: key,
                    expected: otherType.id,
                    actual: typeID
                )
            )
        }

        do {
            _ = try await readClient.snapshot(for: wrongValueType)
            XCTFail("A typed snapshot must reject a mismatched Swift value type")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .valueTypeMismatch(typeID)
            )
        }

        do {
            _ = try await foreignPublisher.remove(key: key, type: typed)
            XCTFail("Only the publishing owner generation may remove a contribution")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .ownershipDenied(key: key, ownerModuleID: foreignOwner.moduleID)
            )
        }
    }

    func testCapabilitiesGatePublisherAndReaderClients() async throws {
        let registry = makeRegistry { descriptor, _ in
            descriptor.moduleID.rawValue != "com.runescribe.test.contributor.denied"
        }
        let runtimeGeneration = await registry.activateRuntime()
        let missing = descriptor(
            moduleID: "com.runescribe.test.contributor.missing",
            capabilities: []
        )
        let denied = descriptor(
            moduleID: "com.runescribe.test.contributor.denied",
            capabilities: [publishCapability, readCapability]
        )
        let publishOnly = descriptor(
            moduleID: "com.runescribe.test.contributor.publish-only",
            capabilities: [publishCapability]
        )
        try await registry.activateModule(descriptor: missing, generation: 1)
        try await registry.activateModule(descriptor: denied, generation: 1)
        try await registry.activateModule(descriptor: publishOnly, generation: 1)

        do {
            _ = try await registry.makePublisherClient(
                sourceModuleID: missing.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: runtimeGeneration
            )
            XCTFail("Publishing requires the injected publish capability")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: missing.moduleID,
                    capability: publishCapability
                )
            )
        }

        do {
            _ = try await registry.makePublisherClient(
                sourceModuleID: denied.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: runtimeGeneration
            )
            XCTFail("The injected authorization must be enforced")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: denied.moduleID,
                    capability: publishCapability
                )
            )
        }

        do {
            _ = try await registry.makeReaderClient(
                sourceModuleID: publishOnly.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: runtimeGeneration
            )
            XCTFail("Reading requires the independently injected read capability")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: publishOnly.moduleID,
                    capability: readCapability
                )
            )
        }
    }

    func testModuleInvalidationRemovesOwnedEntriesAndRevokesClient() async throws {
        let registry = makeRegistry()
        let runtimeGeneration = await registry.activateRuntime()
        let owner = descriptor(
            moduleID: "com.runescribe.test.contributor.owner",
            capabilities: [publishCapability]
        )
        let survivor = descriptor(
            moduleID: "com.runescribe.test.contributor.survivor",
            capabilities: [publishCapability]
        )
        let reader = descriptor(
            moduleID: "com.runescribe.test.contributor.reader",
            capabilities: [readCapability]
        )
        try await registry.activateModule(descriptor: owner, generation: 11)
        try await registry.activateModule(descriptor: survivor, generation: 13)
        try await registry.activateModule(descriptor: reader, generation: 17)
        let ownerPublisher = try await registry.makePublisherClient(
            sourceModuleID: owner.moduleID,
            sourceModuleGeneration: 11,
            runtimeGeneration: runtimeGeneration
        )
        let survivorPublisher = try await registry.makePublisherClient(
            sourceModuleID: survivor.moduleID,
            sourceModuleGeneration: 13,
            runtimeGeneration: runtimeGeneration
        )
        let readClient = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 17,
            runtimeGeneration: runtimeGeneration
        )
        let type = RuntimeContributionType<TestContribution>(
            id: try XCTUnwrap(RuntimeContributionTypeID(rawValue: "runtime.sample"))
        )
        let ownerKeys = [
            try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.owner-one")),
            try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.owner-two")),
        ]
        let survivorKey = try XCTUnwrap(
            RuntimeContributionKey(rawValue: "sample.survivor")
        )
        _ = try await ownerPublisher.publish(
            TestContribution(label: "owner-one"),
            type: type,
            key: ownerKeys[0]
        )
        _ = try await ownerPublisher.publish(
            TestContribution(label: "owner-two"),
            type: type,
            key: ownerKeys[1]
        )
        _ = try await survivorPublisher.publish(
            TestContribution(label: "survivor"),
            type: type,
            key: survivorKey
        )

        await registry.invalidateModule(owner.moduleID, generation: 10)
        let snapshotBeforeInvalidation = try await readClient.snapshot(for: type)
        XCTAssertEqual(snapshotBeforeInvalidation.revision, 3)
        await registry.invalidateModule(owner.moduleID, generation: 11)

        let snapshot = try await readClient.snapshot(for: type)
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(snapshot.entries.map(\.key), [survivorKey])
        do {
            _ = try await ownerPublisher.publish(
                TestContribution(label: "stale"),
                type: type,
                key: try XCTUnwrap(
                    RuntimeContributionKey(rawValue: "sample.stale")
                )
            )
            XCTFail("Invalidation must revoke the owner generation client")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .staleClient(owner.moduleID)
            )
        }
    }

    func testRuntimeReplacementClearsEntriesRevokesClientsAndKeepsRevisionMonotonic()
        async throws
    {
        let registry = makeRegistry()
        let firstRuntimeGeneration = await registry.activateRuntime()
        let owner = descriptor(
            moduleID: "com.runescribe.test.contributor.owner",
            capabilities: [publishCapability]
        )
        let reader = descriptor(
            moduleID: "com.runescribe.test.contributor.reader",
            capabilities: [readCapability]
        )
        try await registry.activateModule(descriptor: owner, generation: 1)
        try await registry.activateModule(descriptor: reader, generation: 1)
        let publisher = try await registry.makePublisherClient(
            sourceModuleID: owner.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: firstRuntimeGeneration
        )
        let oldReader = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: firstRuntimeGeneration
        )
        let type = RuntimeContributionType<TestContribution>(
            id: try XCTUnwrap(RuntimeContributionTypeID(rawValue: "runtime.sample"))
        )
        _ = try await publisher.publish(
            TestContribution(label: "first-runtime"),
            type: type,
            key: try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.first"))
        )
        let firstSnapshot = try await oldReader.snapshot(for: type)
        XCTAssertEqual(firstSnapshot.revision, 1)

        let secondRuntimeGeneration = await registry.activateRuntime()
        XCTAssertGreaterThan(secondRuntimeGeneration, firstRuntimeGeneration)
        do {
            _ = try await oldReader.snapshot(for: type)
            XCTFail("A client from the replaced runtime must be revoked")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }

        try await registry.activateModule(descriptor: owner, generation: 2)
        try await registry.activateModule(descriptor: reader, generation: 2)
        let newPublisher = try await registry.makePublisherClient(
            sourceModuleID: owner.moduleID,
            sourceModuleGeneration: 2,
            runtimeGeneration: secondRuntimeGeneration
        )
        let newReader = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 2,
            runtimeGeneration: secondRuntimeGeneration
        )
        let emptySnapshot = try await newReader.snapshot(for: type)
        XCTAssertEqual(emptySnapshot.revision, 2)
        XCTAssertEqual(emptySnapshot.entries, [])
        _ = try await newPublisher.publish(
            TestContribution(label: "second-runtime"),
            type: type,
            key: try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.second"))
        )
        let secondSnapshot = try await newReader.snapshot(for: type)
        XCTAssertEqual(secondSnapshot.revision, 3)
    }

    func testChangeStreamEmitsInitialPublishRemovalAndFinishesWhenReaderIsRevoked()
        async throws
    {
        let registry = makeRegistry()
        let runtimeGeneration = await registry.activateRuntime()
        let owner = descriptor(
            moduleID: "com.runescribe.test.contributor.stream-owner",
            capabilities: [publishCapability]
        )
        let reader = descriptor(
            moduleID: "com.runescribe.test.contributor.stream-reader",
            capabilities: [readCapability]
        )
        try await registry.activateModule(descriptor: owner, generation: 2)
        try await registry.activateModule(descriptor: reader, generation: 4)
        let publisher = try await registry.makePublisherClient(
            sourceModuleID: owner.moduleID,
            sourceModuleGeneration: 2,
            runtimeGeneration: runtimeGeneration
        )
        let readClient = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 4,
            runtimeGeneration: runtimeGeneration
        )
        let type = RuntimeContributionType<TestContribution>(
            id: try XCTUnwrap(RuntimeContributionTypeID(rawValue: "runtime.stream-sample"))
        )
        let key = try XCTUnwrap(RuntimeContributionKey(rawValue: "sample.stream"))
        let stream = try await readClient.changes()
        var iterator = stream.makeAsyncIterator()

        let initialRevisionValue = await iterator.next()
        let initialRevision = try XCTUnwrap(initialRevisionValue)
        XCTAssertEqual(initialRevision, 0)

        _ = try await publisher.publish(
            TestContribution(label: "published"),
            type: type,
            key: key
        )
        let publishRevisionValue = await iterator.next()
        let publishRevision = try XCTUnwrap(publishRevisionValue)
        XCTAssertGreaterThan(publishRevision, initialRevision)

        let didRemove = try await publisher.remove(key: key, type: type)
        XCTAssertTrue(didRemove)
        let removalRevisionValue = await iterator.next()
        let removalRevision = try XCTUnwrap(removalRevisionValue)
        XCTAssertGreaterThan(removalRevision, publishRevision)

        await registry.invalidateModule(reader.moduleID, generation: 4)
        let terminalRevision = await iterator.next()
        XCTAssertNil(terminalRevision)
    }

    private func makeRegistry(
        authorization: @escaping RuntimeContributionRegistry.CapabilityAuthorization = {
            _, _ in true
        }
    ) -> RuntimeContributionRegistry {
        RuntimeContributionRegistry(
            publishCapabilityID: publishCapability,
            readCapabilityID: readCapability,
            authorization: authorization
        )
    }

    private func descriptor(
        moduleID: ModuleIdentifier,
        capabilities: Set<CapabilityIdentifier>
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: moduleID,
            moduleVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            kind: .service,
            criticality: .optional,
            entryPoint: moduleID.rawValue,
            role: "role.test-contributor",
            requestedCapabilities: capabilities
        )
    }
}

private struct TestContribution: Equatable, Sendable {
    let label: String
}

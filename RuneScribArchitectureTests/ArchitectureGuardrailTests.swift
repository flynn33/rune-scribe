import Foundation
import XCTest

final class ArchitectureGuardrailTests: XCTestCase {
    func testRepositoryArchitectureGuardrails() throws {
        let invocation = try invokeGuard()
        XCTAssertEqual(invocation.status, 0, invocation.message)
    }

    func testProgressionBoundaryNegativeMutationsAreBlocking() throws {
        let mutations: [(source: String, expected: String)] = [
            ("@preconcurrency import CoreData\n", "may not import CoreData"),
            ("@preconcurrency\nimport CoreData\n", "may not import CoreData"),
            ("@_implementationOnly import RuneScribePlatform\n", "may not import RuneScribePlatform"),
            ("@_exported import RuneScribeUIModule\n", "may not import RuneScribeUIModule"),
            ("@testable import RuneScribeThemeMoonleafModule\n", "may not import RuneScribeThemeMoonleafModule"),
            ("let preferences = UserDefaults.standard\n", "preferences storage"),
            ("private let store: any ModuleStateStore\n", "raw module-state store or adapter"),
            ("private let adapter: RuntimeModuleStateGateway\n", "raw module-state store or adapter"),
            ("let location = storeURL\n", "physical store URL"),
            ("let files = FileManager.default\n", "direct file API"),
            ("let bytes = try Data(contentsOf: URL(string: \"https://example.invalid\")!)\n", "direct file API"),
            ("let session = URLSession.shared\n", "direct network API"),
            ("let status = SecItemCopyMatching([:] as CFDictionary, nil)\n", "Keychain facility"),
            ("AudioServicesPlaySystemSound(1)\n", "audio or haptic facility"),
            ("let engine = CHHapticEngine()\n", "audio or haptic facility"),
            ("import GameKit\n", "may not import GameKit"),
            ("import CloudKit\n", "may not import CloudKit"),
            ("import StoreKit\n", "may not import StoreKit"),
            (
                "public func context() -> NSManagedObjectContext { fatalError() }\n",
                "NSManagedObject type"
            ),
            (
                "public var coordinator: NSPersistentStoreCoordinator { fatalError() }\n",
                "persistent-store handle"
            ),
        ]

        for mutation in mutations {
            let invocation = try invokeFixture(
                product: "RuneScribeProgressionModule",
                source: mutation.source
            )
            XCTAssertNotEqual(invocation.status, 0, mutation.source)
            XCTAssertTrue(
                invocation.message.contains(mutation.expected),
                "\(mutation.source)\n\(invocation.message)"
            )
        }
    }

    func testDirectPeerServiceHandlesAreBlocking() throws {
        let mutations: [(product: String, source: String, expected: String)] = [
            (
                "RuneScribeCoreModule",
                "private var peer: RuneScribeProgressionServiceActor?\n",
                "direct Progression service implementation handles"
            ),
            (
                "RuneScribeProgressionModule",
                "private var peer: RuneScribeCoreApplicationService?\n",
                "direct Core service implementation handles"
            ),
            (
                "RuneScribeUIModule",
                "private var peer: RuneScribeProgressionServiceActor?\n",
                "direct Progression service implementation handles"
            ),
        ]

        for mutation in mutations {
            let invocation = try invokeFixture(
                product: mutation.product,
                source: mutation.source
            )
            XCTAssertNotEqual(invocation.status, 0, mutation.source)
            XCTAssertTrue(
                invocation.message.contains(mutation.expected),
                "\(mutation.source)\n\(invocation.message)"
            )
        }
    }

    func testFreeFormProgressionEnvelopeCreationIsBlockingOutsideRuntime() throws {
        for product in [
            "RuneScribeCoreModule", "RuneScribeProgressionModule", "RuneScribeUIModule",
        ] {
            let invocation = try invokeFixture(
                product: product,
                source: "let envelope = DomainEventEnvelope(eventID: eventID)\n"
            )
            XCTAssertNotEqual(invocation.status, 0, product)
            XCTAssertTrue(
                invocation.message.contains("free-form Progression event envelopes"),
                "\(product)\n\(invocation.message)"
            )
        }
    }

    func testUIOwnedProgressionTruthMutationIsBlocking() throws {
        let mutations = [
            "let evaluator = ProgressionRuleEvaluator()\n",
            "let operation = \"distinctCountAtLeast\"\n",
            "let event = ProgressionEventFact(eventType: eventType)\n",
        ]
        for source in mutations {
            let invocation = try invokeFixture(product: "RuneScribeUIModule", source: source)
            XCTAssertNotEqual(invocation.status, 0, source)
            XCTAssertTrue(invocation.message.contains("UI may not own"), invocation.message)
        }
    }

    func testDuplicateProgressionStableIDMutationIsBlocking() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeArchitectureCatalogFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        let catalog = fixtureRoot.appendingPathComponent("Catalog.json")
        try """
        {
          "achievements": [{"achievementID":"achievement.duplicate"}],
          "milestones": [{"ruleID":"achievement.duplicate"}],
          "content": [],
          "grantGroups": [],
          "statistics": [],
          "journeyGraph": {"nodes": []}
        }
        """.write(to: catalog, atomically: true, encoding: .utf8)

        let invocation = try invokeGuard(environment: [
            "RUNESCRIBE_ARCHITECTURE_CATALOG_FIXTURE": catalog.path,
        ])
        XCTAssertNotEqual(invocation.status, 0, invocation.message)
        XCTAssertTrue(
            invocation.message.contains("duplicate Progression stable ID"),
            invocation.message
        )
    }

    func testApprovedModuleStateReferencesAndAttributedImportsRemainAllowed() throws {
        let approvedFixtures: [(product: String, source: String)] = [
            (
                "RuneScribeProgressionModule",
                """
                import Foundation
                import RuneScribeContracts
                import RuneScribeRuntimeCore
                struct Fixture { let state: RuntimeModuleStateClient }
                """
            ),
            (
                "RuneScribePlatform",
                """
                @preconcurrency import CoreData
                private var context: NSManagedObjectContext?
                """
            ),
            (
                "RuneScribeRuntimeCore",
                """
                import RuneScribeContracts
                private var store: (any ModuleStateStore)?
                """
            ),
            (
                "RuneScribeTestSupport",
                """
                import RuneScribeContracts
                actor InMemoryModuleStateStore: ModuleStateStore {}
                """
            ),
        ]

        for fixture in approvedFixtures {
            let invocation = try invokeFixture(
                product: fixture.product,
                source: fixture.source
            )
            XCTAssertEqual(
                invocation.status,
                0,
                "\(fixture.product)\n\(invocation.message)"
            )
        }
    }

    func testThemeProgressionCouplingNegativeMutationsAreBlocking() throws {
        let mutations: [(source: String, expected: String)] = [
            (
                "@_implementationOnly import RuneScribeProgressionModule\n",
                "Theme source may not import RuneScribeProgressionModule"
            ),
            (
                "let endpoint = RuntimeProgressionEndpointCatalog.apply\n",
                "runtime Progression endpoint catalog"
            ),
            (
                "let endpointID = \"progression.event.apply\"\n",
                "Progression endpoint identifier"
            ),
            (
                "let ruleID = \"rule.codex.moonleaf.first-share\"\n",
                "Theme source may not own Progression rule stable ID"
            ),
            (
                "let achievementID = \"achievement.first-inscription\"\n",
                "Theme source may not own Achievement stable ID"
            ),
        ]

        for mutation in mutations {
            let invocation = try invokeFixture(
                product: "RuneScribeSyntheticThemeModule",
                source: mutation.source
            )
            XCTAssertNotEqual(invocation.status, 0, mutation.source)
            XCTAssertTrue(
                invocation.message.contains(mutation.expected),
                "\(mutation.source)\n\(invocation.message)"
            )
        }
    }

    func testCoreAndUICannotImportProgressionImplementation() throws {
        for product in ["RuneScribeCoreModule", "RuneScribeUIModule"] {
            let invocation = try invokeFixture(
                product: product,
                source: "@preconcurrency import RuneScribeProgressionModule\n"
            )
            XCTAssertNotEqual(invocation.status, 0, product)
            XCTAssertTrue(
                invocation.message.contains("may not import RuneScribeProgressionModule"),
                "\(product)\n\(invocation.message)"
            )
        }
    }

    private func invokeFixture(product: String, source: String) throws -> Invocation {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeArchitectureFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        try source.write(
            to: fixtureRoot.appendingPathComponent("Fixture.swift"),
            atomically: true,
            encoding: .utf8
        )

        return try invokeGuard(environment: [
            "RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_ROOT": fixtureRoot.path,
            "RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_PRODUCT": product,
        ])
    }

    private func invokeGuard(environment: [String: String] = [:]) throws -> Invocation {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appendingPathComponent("scripts/check-architecture.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repository
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Invocation(
            status: process.terminationStatus,
            message: String(decoding: data, as: UTF8.self)
        )
    }

    private struct Invocation {
        let status: Int32
        let message: String
    }
}

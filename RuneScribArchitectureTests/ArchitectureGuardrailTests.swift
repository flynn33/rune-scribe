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

    func testUIProviderResourceDecoderMutationsAreBlocking() throws {
        let mutations: [(source: String, expected: String)] = [
            ("let source = CGImageSourceCreateWithData(bytes, nil)\n", "ImageIO image-source decoder"),
            ("let document = CGPDFDocument(provider)\n", "Core Graphics PDF decoder"),
            ("let provider = CGDataProvider(data: bytes)\n", "Core Graphics encoded-data provider"),
            ("let image = NSImage(data: bytes)\n", "platform image-data decoder"),
            ("let image = UIImage(data: bytes)\n", "platform image-data decoder"),
            ("let bitmap = NSBitmapImageRep(data: bytes)\n", "platform image-data decoder"),
            (
                "let image = CGImage(pngDataProviderSource: provider)\n",
                "CGImage encoded-provider decoder"
            ),
        ]

        for mutation in mutations {
            let invocation = try invokeFixture(
                product: "RuneScribeUIModule",
                source: mutation.source
            )
            XCTAssertNotEqual(invocation.status, 0, mutation.source)
            XCTAssertTrue(
                invocation.message.contains("UI-RUNTIME-IMAGE-DECODE")
                    && invocation.message.contains(mutation.expected),
                "\(mutation.source)\n\(invocation.message)"
            )
        }
    }

    func testUIStaticRendererOutputEncodingRemainsAllowed() throws {
        let invocation = try invokeFixture(
            product: "RuneScribeUIModule",
            source: """
            let image = renderer.cgImage
            let png = NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            )
            """
        )
        XCTAssertEqual(invocation.status, 0, invocation.message)
    }

    func testReceivedSafePreviewExceptionIsExactAndCannotHideProviderDecoding() throws {
        let approved = try invokeFixture(
            product: "RuneScribeUIModule",
            source: """
            guard let image = NSImage(data: safePreviewData) else { return nil }
            guard let image = UIImage(data: safePreviewData) else { return nil }
            """,
            treatAsSafePreviewSource: true
        )
        XCTAssertEqual(approved.status, 0, approved.message)

        let rejected = try invokeFixture(
            product: "RuneScribeUIModule",
            source: """
            guard let image = NSImage(data: safePreviewData) else { return nil }
            let providerImage = NSImage(data: providerResourceData)
            """,
            treatAsSafePreviewSource: true
        )
        XCTAssertNotEqual(rejected.status, 0, rejected.message)
        XCTAssertTrue(rejected.message.contains("UI-RUNTIME-IMAGE-DECODE"), rejected.message)
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

    private func invokeFixture(
        product: String,
        source: String,
        treatAsSafePreviewSource: Bool = false
    ) throws -> Invocation {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeArchitectureFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        let fixtureSource = fixtureRoot.appendingPathComponent("Fixture.swift")
        try source.write(
            to: fixtureSource,
            atomically: true,
            encoding: .utf8
        )

        var environment = [
            "RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_ROOT": fixtureRoot.path,
            "RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_PRODUCT": product,
        ]
        if treatAsSafePreviewSource {
            environment["RUNESCRIBE_ARCHITECTURE_UI_SAFE_PREVIEW_SOURCE"] = fixtureSource.path
        }
        return try invokeGuard(environment: environment)
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

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuneScribeArchitectureGuardTests-\(UUID().uuidString).log"
        )
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        try output.close()

        let data = try Data(contentsOf: outputURL)
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

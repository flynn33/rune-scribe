import Foundation
import XCTest

final class ComplianceGuardTests: XCTestCase {
    private static let banner = "REPORT ONLY — NOT A COMPLIANCE PASS"

    private struct Invocation {
        let status: Int32
        let standardOutput: String
        let standardError: String
        let json: Data
        let markdown: Data
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCatalogHasCanonicalIDsNamesOrderAndMappings() throws {
        let catalogURL = repository.appendingPathComponent("scripts/forsetti-compliance-rules.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let rules = try XCTUnwrap(root["rules"] as? [[String: Any]])

        let expectedIDs = (1...20).map { String(format: "FG-%03d", $0) }
        XCTAssertEqual(rules.compactMap { $0["id"] as? String }, expectedIDs)
        XCTAssertEqual(
            rules.compactMap { $0["name"] as? String },
            [
                "permanent-no-external-forsetti-dependency",
                "exactly-one-ui-module",
                "no-runtime-module-import-edge",
                "no-provider-object-publication",
                "no-peer-service-handle-retention",
                "runtime-in-every-call-path",
                "runtime-owned-io",
                "runtime-owned-settings",
                "uniform-module-factory",
                "standard-module-ports",
                "unique-id-reusable-policy-class",
                "explicit-dependencies-only",
                "optional-failure-isolation",
                "live-eligibility-reconciliation",
                "keyed-contribution-lifecycle",
                "opaque-resource-lifecycle",
                "runtime-owned-operation-metadata",
                "typed-declared-event-routing",
                "negative-mutation-suite",
                "single-authority-documentation"
            ]
        )

        let expectedMappings: [String: [String]] = [
            "FG-001": ["FRC-015"],
            "FG-002": [],
            "FG-003": [],
            "FG-004": ["FRC-001"],
            "FG-005": ["FRC-002", "FRC-003"],
            "FG-006": ["FRC-001", "FRC-002", "FRC-003"],
            "FG-007": ["FRC-004", "FRC-005"],
            "FG-008": ["FRC-006"],
            "FG-009": ["FRC-004", "FRC-007"],
            "FG-010": ["FRC-008", "FRC-012", "FRC-014"],
            "FG-011": ["FRC-011", "FRC-014"],
            "FG-012": ["FRC-010", "FRC-014"],
            "FG-013": ["FRC-010"],
            "FG-014": ["FRC-009"],
            "FG-015": ["FRC-012"],
            "FG-016": ["FRC-012", "FRC-017"],
            "FG-017": ["FRC-017"],
            "FG-018": ["FRC-013"],
            "FG-019": ["FRC-016"],
            "FG-020": ["FRC-015", "FRC-016", "FRC-018"]
        ]
        let historicalP01Statuses: [String: String] = Dictionary(
            uniqueKeysWithValues: expectedIDs.map { id in
                let status: String
                switch id {
                case "FG-001", "FG-002", "FG-003", "FG-020":
                    status = "pass"
                case "FG-019":
                    status = "pending-enforcement"
                default:
                    status = "violation"
                }
                return (id, status)
            }
        )

        for rule in rules {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["findingIDs"] as? [String], expectedMappings[id], id)
            XCTAssertEqual(rule["expectedP01Status"] as? String, historicalP01Statuses[id], id)
            XCTAssertFalse(try XCTUnwrap(rule["requirement"] as? String).isEmpty, id)
            XCTAssertEqual(rule["waiverStatus"] as? String, "none", id)
            XCTAssertEqual((rule["enforcement"] as? [String: Any])?["mode"] as? String, "report-only", id)
            XCTAssertFalse(try XCTUnwrap(rule["owningPhases"] as? [String]).isEmpty, id)
            if ["FG-004", "FG-005", "FG-006", "FG-007", "FG-009", "FG-016"].contains(id) {
                XCTAssertEqual(
                    (rule["enforcement"] as? [String: Any])?["detectorCoverage"] as? String,
                    "complete",
                    id
                )
            }
        }
    }

    func testReportIsDeterministicAndCannotClaimOverallPass() throws {
        let first = try invokeGuard()
        let second = try invokeGuard()

        XCTAssertEqual(first.status, 0, first.standardError)
        XCTAssertEqual(second.status, 0, second.standardError)
        XCTAssertEqual(first.standardOutput, second.standardOutput)
        XCTAssertEqual(first.json, second.json)
        XCTAssertEqual(first.markdown, second.markdown)
        XCTAssertTrue(first.standardOutput.hasPrefix(Self.banner + "\n"))

        let markdown = String(decoding: first.markdown, as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix(Self.banner + "\n"))
        XCTAssertFalse(markdown.split(separator: "\n").dropFirst().contains("COMPLIANCE PASS"))

        let report = try decodeReport(first.json)
        XCTAssertEqual(report["mode"] as? String, "report-only")
        XCTAssertEqual(report["overallStatus"] as? String, "report-only")
    }

    func testLiveStatusesHaveConcreteEvidenceAnchorsWithoutRewritingP01History() throws {
        let invocation = try invokeGuard()
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)

        for rule in rules {
            let id = try XCTUnwrap(rule["id"] as? String)
            let status = try XCTUnwrap(rule["status"] as? String, id)
            let expectedP01Status = try XCTUnwrap(rule["expectedP01Status"] as? String, id)
            XCTAssertEqual(rule["matchesP01Baseline"] as? Bool, status == expectedP01Status, id)
            XCTAssertTrue(
                ["pass", "violation", "pending-enforcement", "not-evaluated"].contains(status),
                id
            )
            if status == "pass" {
                XCTAssertEqual(rule["evidenceKind"] as? String, "detector-proof", id)
            }

            let evidence = try XCTUnwrap(rule["evidence"] as? [[String: Any]], id)
            XCTAssertFalse(evidence.isEmpty, id)
            for anchor in evidence {
                XCTAssertFalse(try XCTUnwrap(anchor["path"] as? String).isEmpty, id)
                XCTAssertGreaterThan(try XCTUnwrap(anchor["line"] as? Int), 0, id)
            }
        }

        for id in ["FG-004", "FG-005", "FG-006"] {
            let rule = try XCTUnwrap(rules.first { ($0["id"] as? String) == id })
            XCTAssertEqual(rule["status"] as? String, "pass", id)
            XCTAssertEqual(rule["expectedP01Status"] as? String, "violation", id)
            XCTAssertEqual(rule["matchesP01Baseline"] as? Bool, false, id)
            XCTAssertEqual(rule["evidenceKind"] as? String, "detector-proof", id)
        }
    }

    func testFocusedNegativeMutationsReportExactRuleIDs() throws {
        let fixtures: [(String, String, String, String)] = [
            ("NM-FG-001-01", "Package.swift", ".package(url: \"https://example.invalid/Forsetti.git\", from: \"1.0.0\")\n", "FG-001"),
            ("NM-FG-001-02", "Mutation.swift", "import ForsettiCore\n", "FG-001"),
            ("NM-FG-001-03", "Vendor/Forsetti/.fixture", "vendored\n", "FG-001"),
            ("NM-FG-001-04", "scripts/fetch-forsetti.sh", "git clone https://example.invalid/Forsetti.git\n", "FG-001"),
            ("NM-FG-020-01", "docs/architecture/decisions/ADR-MUTATION.md", "# Accepted\nA future external Forsetti dependency is permitted.\n", "FG-020"),
            ("NM-FG-020-02", "docs/verification/MutationReport.md", "# Current report\nLookup-time authorization is full runtime mediation.\n", "FG-020")
        ]

        for fixture in fixtures {
            let invocation = try invokeGuard { root in
                let file = root.appendingPathComponent(fixture.1)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(fixture.2.utf8).write(to: file, options: .atomic)
            }
            XCTAssertEqual(invocation.status, 0, "\(fixture.0): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let triggered = rules.filter { ($0["status"] as? String) == "violation" && ($0["id"] as? String) == fixture.3 }
            XCTAssertEqual(triggered.count, 1, fixture.0)
            let evidence = try XCTUnwrap(triggered.first?["evidence"] as? [[String: Any]], fixture.0)
            XCTAssertTrue(evidence.contains { ($0["path"] as? String) == fixture.1 || ($0["path"] as? String) == "Vendor/Forsetti" }, fixture.0)
        }
    }

    func testP02NegativeMutationsReportExactRuleIDs() throws {
        func replacingSingleAnchor(
            _ original: String?,
            anchor: String,
            replacement: String,
            mutationID: String
        ) throws -> String {
            let source = try XCTUnwrap(original, "\(mutationID): source file is missing")
            let ranges = source.ranges(of: anchor)
            XCTAssertEqual(ranges.count, 1, "\(mutationID): expected one stable anchor")
            let range = try XCTUnwrap(ranges.first, "\(mutationID): stable anchor is missing")
            return source.replacingCharacters(in: range, with: replacement)
        }

        let dispatcher = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
        let fixtures: [(
            id: String,
            ruleID: String,
            relativePath: String,
            mutate: (String?) throws -> String
        )] = [
            (
                "NM-FG-004-01",
                "FG-004",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderPublicationMutation.swift",
                { _ in
                    """
                    protocol ProviderPublicationMutationService: Actor {}
                    func publishMutation(
                        _ provider: any ProviderPublicationMutationService,
                        through context: ModuleContext
                    ) async throws {
                        try await context.publishService(self)
                    }
                    """
                }
            ),
            (
                "NM-FG-004-02",
                "FG-004",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/RawActorRegistrationMutation.swift",
                { _ in
                    """
                    protocol RawActorMutationService: Actor {}
                    private var rawActorMutationStorage: [String: Any] = [:]

                    func registerRawMutationService(_ service: any RawActorMutationService) {
                        rawActorMutationStorage["provider"] = service
                    }
                    """
                }
            ),
            (
                "NM-FG-006-01",
                "FG-006",
                dispatcher,
                { original in
                    try replacingSingleAnchor(
                        original,
                        anchor: "let source = try validateSourceLifecycle(lease: lease, expectedKind: expectedKind)",
                        replacement: "let source = modules[lease.sourceModuleID]!",
                        mutationID: "NM-FG-006-01"
                    )
                }
            ),
            (
                "NM-FG-006-02",
                "FG-006",
                dispatcher,
                { original in
                    try replacingSingleAnchor(
                        original,
                        anchor: "try validateAfterCall(lease: lease, endpoint: endpoint)",
                        replacement: "try Task.checkCancellation()",
                        mutationID: "NM-FG-006-02"
                    )
                }
            ),
            (
                "NM-FG-006-03",
                "FG-006",
                dispatcher,
                { original in
                    try replacingSingleAnchor(
                        original,
                        anchor: "try validateEndpointDeclarations(\n"
                            + "            endpointID: endpointID,\n"
                            + "            source: source,\n"
                            + "            destination: destination\n"
                            + "        )",
                        replacement: "",
                        mutationID: "NM-FG-006-03"
                    )
                }
            )
        ]

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )

        for fixture in fixtures {
            XCTAssertEqual(baselineStatuses[fixture.ruleID], "pass", fixture.id)
            let invocation = try invokeGuard { root in
                let source = self.repository.appendingPathComponent(fixture.relativePath)
                let original = FileManager.default.fileExists(atPath: source.path)
                    ? try String(contentsOf: source, encoding: .utf8)
                    : nil
                let mutated = try fixture.mutate(original)
                let destination = root.appendingPathComponent(fixture.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(mutated.utf8).write(to: destination, options: .atomic)
            }

            XCTAssertEqual(invocation.status, 0, "\(fixture.id): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let result = try XCTUnwrap(
                rules.first { ($0["id"] as? String) == fixture.ruleID },
                fixture.id
            )
            XCTAssertEqual(result["status"] as? String, "violation", fixture.id)
            let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], fixture.id)
            XCTAssertTrue(
                evidence.contains { ($0["path"] as? String) == fixture.relativePath },
                fixture.id
            )

            for rule in rules where (rule["id"] as? String) != fixture.ruleID {
                let id = try XCTUnwrap(rule["id"] as? String, fixture.id)
                XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], "\(fixture.id): \(id)")
            }
        }
    }

    func testP04SemanticNegativeMutationsReportOnlyTheirExactRuleIDs() throws {
        func normalizedEvidence(in rule: [String: Any]) -> [String] {
            let evidence = rule["evidence"] as? [[String: Any]] ?? []
            return evidence.map { item in
                let path = item["path"] as? String ?? ""
                let detail = item["detail"] as? String ?? ""
                return "\(path):\(detail)"
            }.sorted()
        }

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String,
                      let status = rule["status"] as? String
                else {
                    return nil
                }
                return (id, status)
            }
        )
        let baselineEvidence = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, [String])? in
                guard let id = rule["id"] as? String else { return nil }
                return (id, normalizedEvidence(in: rule))
            }
        )

        func assertMutation(
            _ label: String,
            ruleID: String,
            expectedEvidence: [String: [String]],
            fixture: @escaping (URL) throws -> Void
        ) throws {
            let invocation = try invokeGuard(fixture: fixture)
            XCTAssertEqual(invocation.status, 0, "\(label): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let result = try XCTUnwrap(
                rules.first { ($0["id"] as? String) == ruleID },
                label
            )
            XCTAssertEqual(result["status"] as? String, "violation", label)
            let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], label)
            for (evidencePath, detailFragments) in expectedEvidence {
                let mutationEvidence = evidence.filter {
                    ($0["path"] as? String) == evidencePath
                }
                XCTAssertFalse(mutationEvidence.isEmpty, "\(label): \(evidencePath)")
                for fragment in detailFragments {
                    XCTAssertTrue(
                        mutationEvidence.contains {
                            ($0["detail"] as? String)?.contains(fragment) == true
                        },
                        "\(label): \(evidencePath) missing detail fragment \(fragment)"
                    )
                }
            }

            for rule in rules where (rule["id"] as? String) != ruleID {
                let id = try XCTUnwrap(rule["id"] as? String, label)
                XCTAssertEqual(
                    rule["status"] as? String,
                    baselineStatuses[id],
                    "\(label): \(id)"
                )
                XCTAssertEqual(
                    normalizedEvidence(in: rule),
                    baselineEvidence[id],
                    "\(label): unexpected \(id) evidence"
                )
            }
        }

        let moduleOperationalPath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/P04OperationalMutation.swift"
        let unknownBridgePath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/P04UnknownNativeBridgeMutation.swift"
        let knownBridgePath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeQRScanner.swift"
        let authorityBridgePath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeSharePresentation.swift"
        try assertMutation(
            "P04 runtime-owned I/O",
            ruleID: "FG-007",
            expectedEvidence: [
                moduleOperationalPath: [
                    "symbol fileImporter", "symbol fileExporter",
                    "symbol UIActivityViewController", "symbol MFMessageComposeViewController",
                    "symbol AVCaptureSession", "symbol requestAccess", "symbol CNContact",
                    "symbol UIApplication", "symbol Link", "symbol AVAudioSession",
                    "symbol AppStorage", "symbol UserDefaults",
                    "imports operational framework AVFoundation",
                    "imports operational framework Contacts",
                    "imports operational framework MessageUI",
                    "reads file data directly",
                ],
                unknownBridgePath: [
                    "not allowlisted for P04UnknownNativeBridgeMutation.swift",
                    "lacks opaque runtime authority acquisition",
                ],
                knownBridgePath: ["operational symbol AVAudioRecorder is not allowlisted"],
                authorityBridgePath: ["lacks opaque runtime authority acquisition"],
            ]
        ) { root in
            var destination = root.appendingPathComponent(moduleOperationalPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                import AVFoundation
                import Contacts
                import MessageUI
                import SwiftUI

                private func mutateOperationalAPIs<Content>(
                    _ content: Content,
                    contact: CNContact
                ) {
                    _ = content.fileImporter
                    _ = content.fileExporter
                    _ = UIActivityViewController(activityItems: [], applicationActivities: nil)
                    _ = MFMessageComposeViewController()
                    _ = AVCaptureSession()
                    _ = AVCaptureDevice.requestAccess
                    _ = contact.identifier
                    _ = UIApplication.shared
                    _ = Link.self
                    _ = AVAudioSession.sharedInstance()
                    _ = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/p04"))
                }

                @AppStorage("p04.operational-setting")
                private var p04OperationalSetting = false
                private let p04DefaultsMutation = UserDefaults.standard
                """.utf8
            ).write(to: destination, options: .atomic)

            destination = root.appendingPathComponent(unknownBridgePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                private let unownedCaptureSession = AVCaptureSession()
                """.utf8
            ).write(to: destination, options: .atomic)

            let source = try String(
                contentsOf: self.repository.appendingPathComponent(knownBridgePath),
                encoding: .utf8
            )
            destination = root.appendingPathComponent(knownBridgePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                (source + "\nprivate let p04UnknownAudioMutation = AVAudioRecorder()\n").utf8
            ).write(to: destination, options: .atomic)

            let authoritySource = try String(
                contentsOf: self.repository.appendingPathComponent(authorityBridgePath),
                encoding: .utf8
            )
            let acquireAnchor = "session.acquire()"
            let acquireRanges = authoritySource.ranges(of: acquireAnchor)
            XCTAssertEqual(acquireRanges.count, 1, "P04 opaque authority acquire anchor")
            let acquireRange = try XCTUnwrap(acquireRanges.first)
            let authorityMutation = authoritySource.replacingCharacters(
                in: acquireRange,
                with: "session.unvalidatedOpen()"
            )
            destination = root.appendingPathComponent(authorityBridgePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(authorityMutation.utf8).write(to: destination, options: .atomic)
        }

        let factoryPath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/P04FactoryMutation.swift"
        try assertMutation(
            "P04 uniform factory",
            ruleID: "FG-009",
            expectedEvidence: [
                factoryPath: [
                    "factory accepts arbitrary dependencies",
                    "closure captures an operational dependency",
                    "closure constructs a module with captured arguments",
                    "uses the RuntimeTesting descriptor-and-closure",
                    "imports the RuntimeTesting SPI",
                    "closure-valued module factory",
                    "module bootstrap closure captures an operational dependency",
                ],
            ]
        ) { root in
            let destination = root.appendingPathComponent(factoryPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                @_spi(RuntimeTesting) import RuneScribeRuntimeCore

                private struct P04CapturedProvider {}
                private struct P04FactoryModule {
                    init(provider: P04CapturedProvider) {}
                }

                private enum P04FactoryMutation {
                    static func factory(
                        dependencies: P04CapturedProvider
                    ) -> AnyModuleFactory {
                        AnyModuleFactory(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                            P04FactoryModule(provider: dependencies)
                        }
                    }

                    static func alternateFactory(
                        dependencies: P04CapturedProvider
                    ) -> AnyModuleFactory {
                        .init(
                            descriptor: RuneScribeUIModuleBootstrap.descriptor,
                            make: {
                                P04FactoryModule(provider: dependencies)
                            }
                        )
                    }

                    static let bootstrapFactory:
                        (P04CapturedProvider) -> AnyModuleFactory = { provider in
                            .init(
                                descriptor: RuneScribeUIModuleBootstrap.descriptor,
                                make: {
                                    P04FactoryModule(provider: provider)
                                }
                            )
                        }
                }
                """.utf8
            ).write(to: destination, options: .atomic)
        }

        let resourceBoundaryPath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/P04ResourceBoundaryMutation.swift"
        let gatewayPath =
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeIOGateway.swift"
        try assertMutation(
            "P04 opaque resource boundary with runtime generation and revocation validation",
            ruleID: "FG-016",
            expectedEvidence: [
                resourceBoundaryPath: [
                    "imports the RuntimeResourceHost SPI outside",
                    "exposes a provider or raw URL/Data resource result",
                    "constructs an ApplicationResource outside its canonical catalog",
                    "without a catalog and descriptor declaration",
                    "declares a URL/Data-bearing DTO",
                    "stores raw URL/Data instead of an opaque resource handle",
                    "resource property instead of an opaque session",
                    "resource subscript instead of an opaque session",
                    "Bundle.module resource location outside its manifest loader",
                ],
                gatewayPath: [
                    "no longer checks runtime and module generations",
                    "module invalidation no longer revokes runtime resource bindings",
                ],
            ]
        ) { root in
            var destination = root.appendingPathComponent(resourceBoundaryPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                import Foundation
                @_spi(RuntimeResourceHost) import RuneScribeRuntimeCore

                private typealias P04ResourceURL = URL
                private struct P04KeyBearingURLDTO {
                    let keyURL: URL
                }
                private let p04RetainedKeyURL: URL = fatalError()

                public extension ModuleContext {
                    func resourceProvider() -> any ApplicationResourceLocator {
                        fatalError()
                    }

                    func resourceData() -> Data {
                        Data()
                    }

                    var resourceURL: P04ResourceURL {
                        fatalError()
                    }

                    subscript(resource name: String) -> Data {
                        Data()
                    }
                }

                public extension RuntimeIOClient {
                    func unsafeResourceURL() -> URL {
                        fatalError()
                    }
                }

                private let guessedResource = ApplicationResource(
                    name: "guessed",
                    fileExtension: "bin"
                )
                private let guessedResourceViaInit: ApplicationResource = .init(
                    name: "guessed-via-init",
                    fileExtension: "bin"
                )
                private let guessedResourceBundle = Bundle.module

                private func requestUndeclaredResource(
                    _ client: RuntimeIOClient
                ) async throws {
                    let indirectResource = ApplicationResource.bundledRuneFont
                    _ = try await client.applicationResourceSession(indirectResource)
                }
                """.utf8
            ).write(to: destination, options: .atomic)

            let source = try String(
                contentsOf: self.repository.appendingPathComponent(gatewayPath),
                encoding: .utf8
            )
            let anchor = "guard runtimeGeneration == lease.runtimeGeneration else {"
            let ranges = source.ranges(of: anchor)
            XCTAssertEqual(ranges.count, 1, "P04 runtime generation validation anchor")
            let range = try XCTUnwrap(ranges.first)
            var mutated = source.replacingCharacters(
                in: range,
                with: "guard lease.runtimeGeneration > 0 else {"
            )
            let lifecycleTailAnchor = "        return source\n    }\n}"
            let lifecycleTailRanges = mutated.ranges(of: lifecycleTailAnchor)
            XCTAssertEqual(lifecycleTailRanges.count, 1, "P04 lifecycle tail anchor")
            let lifecycleTailRange = try XCTUnwrap(lifecycleTailRanges.first)
            mutated.replaceSubrange(
                lifecycleTailRange,
                with: """
                        if false {
                            guard runtimeGeneration == lease.runtimeGeneration else {
                                return source
                            }
                        }
                        return source
                    }
                }
                """
            )
            let revocationAnchor =
                "await revokeResourceBindings(moduleID: moduleID, generation: generation)"
            let revocationRanges = mutated.ranges(of: revocationAnchor)
            XCTAssertEqual(
                revocationRanges.count,
                1,
                "P04 runtime revocation validation anchor"
            )
            let revocationRange = try XCTUnwrap(revocationRanges.first)
            mutated.replaceSubrange(
                revocationRange,
                with: """
                if false {
                    await revokeResourceBindings(
                        moduleID: moduleID,
                        generation: generation
                    )
                }
                """
            )
            destination = root.appendingPathComponent(gatewayPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(mutated.utf8).write(to: destination, options: .atomic)
        }
    }

    func testP03PeerServiceRetentionMutationsReportExactRuleIDs() throws {
        let fixtures: [(
            id: String,
            relativePath: String,
            contents: String
        )] = [
            (
                "NM-FG-005-01",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/PeerApplicationServiceRetentionMutation.swift",
                """
                import RuneScribeContracts

                private struct PeerApplicationServiceRetentionMutation {
                    private let applicationService: any RuneScribeApplicationService
                }
                """
            ),
            (
                "NM-FG-005-02",
                "RuneScrib/AppHost/PeerInboundServiceRetentionMutation.swift",
                """
                import RuneScribeContracts

                private struct PeerInboundServiceRetentionMutation {
                    private let inboundService: any RuneScribeInboundInputService
                }
                """
            )
        ]

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-005"], "pass")

        for fixture in fixtures {
            let invocation = try invokeGuard { root in
                let destination = root.appendingPathComponent(fixture.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(fixture.contents.utf8).write(to: destination, options: .atomic)
            }

            XCTAssertEqual(invocation.status, 0, "\(fixture.id): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let result = try XCTUnwrap(
                rules.first { ($0["id"] as? String) == "FG-005" },
                fixture.id
            )
            XCTAssertEqual(result["status"] as? String, "violation", fixture.id)
            let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], fixture.id)
            XCTAssertTrue(
                evidence.contains { ($0["path"] as? String) == fixture.relativePath },
                fixture.id
            )

            for rule in rules where (rule["id"] as? String) != "FG-005" {
                let id = try XCTUnwrap(rule["id"] as? String, fixture.id)
                XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], "\(fixture.id): \(id)")
            }
        }
    }

    func testHostResolverProxyRegressionReportsFG005() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/HostResolverProxyRegression.swift"
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-005"], "pass")

        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                import RuneScribeContracts

                struct RuntimeInboundInputServiceProxy: RuneScribeInboundInputService {
                    func receive(
                        _ input: RuneScribeInboundInput
                    ) async throws -> InboundInputDispositionDTO {
                        .accepted
                    }
                }

                func resolveHostService() -> any RuneScribeInboundInputService {
                    RuntimeInboundInputServiceProxy()
                }
                """.utf8
            ).write(to: destination, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == "FG-005" })
        XCTAssertEqual(result["status"] as? String, "violation")
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
        XCTAssertTrue(evidence.contains { ($0["path"] as? String) == relative })

        for rule in rules where (rule["id"] as? String) != "FG-005" {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testTransitivePeerServiceAliasRetentionReportsOnlyFG005() throws {
        let fixtures: [(
            id: String,
            retainedPath: String,
            files: [(path: String, contents: String)]
        )] = [
            (
                "application-alias-chain",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/TransitiveApplicationServiceAliasRegression.swift",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/TransitiveApplicationServiceAliasRegression.swift",
                        """
                        public typealias HiddenApplicationServiceRoot =
                            any
                            RuneScribeApplicationService
                        public typealias HiddenApplicationServiceHandle =
                            HiddenApplicationServiceRoot
                        """
                    ),
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/TransitiveApplicationServiceAliasRegression.swift",
                        """
                        import RuneScribeContracts

                        private struct TransitiveApplicationServiceAliasRegression {
                            private let retained: HiddenApplicationServiceHandle
                        }
                        """
                    )
                ]
            ),
            (
                "inbound-alias-chain",
                "RuneScrib/AppHost/TransitiveInboundServiceAliasRegression.swift",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/TransitiveInboundServiceAliasRegression.swift",
                        """
                        import RuneScribeContracts

                        public typealias HiddenInboundServiceRoot =
                            RuneScribeContracts
                            .RuneScribeInboundInputService
                        public typealias HiddenInboundServiceHandle =
                            HiddenInboundServiceRoot
                        """
                    ),
                    (
                        "RuneScrib/AppHost/TransitiveInboundServiceAliasRegression.swift",
                        """
                        import RuneScribeRuntimeCore

                        private struct TransitiveInboundServiceAliasRegression {
                            private let retained: any HiddenInboundServiceHandle
                        }
                        """
                    )
                ]
            )
        ]

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-005"], "pass")

        for fixture in fixtures {
            let invocation = try invokeGuard { root in
                for file in fixture.files {
                    let destination = root.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(file.contents.utf8).write(to: destination, options: .atomic)
                }
            }

            XCTAssertEqual(invocation.status, 0, "\(fixture.id): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let result = try XCTUnwrap(
                rules.first { ($0["id"] as? String) == "FG-005" },
                fixture.id
            )
            XCTAssertEqual(result["status"] as? String, "violation", fixture.id)
            let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], fixture.id)
            XCTAssertTrue(
                evidence.contains { ($0["path"] as? String) == fixture.retainedPath },
                fixture.id
            )

            for rule in rules where (rule["id"] as? String) != "FG-005" {
                let id = try XCTUnwrap(rule["id"] as? String, fixture.id)
                XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], "\(fixture.id): \(id)")
            }
        }
    }

    func testTransitivePeerServiceProtocolRefinementReportsOnlyFG005() throws {
        let fixtures: [(
            id: String,
            retainedPath: String,
            files: [(path: String, contents: String)]
        )] = [
            (
                "application-refinement-chain",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/TransitiveApplicationServiceRefinementRegression.swift",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/TransitiveApplicationServiceRefinementRegression.swift",
                        """
                        public protocol HiddenApplicationRefinementRoot:
                            RuneScribeApplicationService
                        {}
                        public typealias HiddenApplicationRefinementAlias =
                            HiddenApplicationRefinementRoot
                        public protocol HiddenApplicationRefinementLeaf:
                            HiddenApplicationRefinementAlias
                        {}
                        """
                    ),
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/TransitiveApplicationServiceRefinementRegression.swift",
                        """
                        import RuneScribeContracts

                        private struct TransitiveApplicationServiceRefinementRegression {
                            private let retained: any HiddenApplicationRefinementLeaf
                        }
                        """
                    )
                ]
            ),
            (
                "inbound-refinement-chain",
                "RuneScrib/AppHost/TransitiveInboundServiceRefinementRegression.swift",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/TransitiveInboundServiceRefinementRegression.swift",
                        """
                        import RuneScribeContracts

                        public protocol HiddenInboundRefinementRoot:
                            RuneScribeInboundInputService
                        {}
                        public typealias HiddenInboundRefinementAlias =
                            HiddenInboundRefinementRoot
                        public protocol HiddenInboundRefinementLeaf:
                            HiddenInboundRefinementAlias
                        {}
                        """
                    ),
                    (
                        "RuneScrib/AppHost/TransitiveInboundServiceRefinementRegression.swift",
                        """
                        import RuneScribeRuntimeCore

                        private struct TransitiveInboundServiceRefinementRegression {
                            private let retained: any HiddenInboundRefinementLeaf
                        }
                        """
                    )
                ]
            )
        ]

        for fixture in fixtures {
            try assertOverlayFilesReportOnly(
                ruleID: "FG-005",
                evidencePath: fixture.retainedPath,
                files: fixture.files,
                label: fixture.id
            )
        }
    }

    func testProtocolWhereConstraintDoesNotMasqueradeAsServiceRefinement() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-005"], "pass")

        let invocation = try invokeGuard { root in
            let files: [(String, String)] = [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/ProtocolWhereConstraintRegression.swift",
                    """
                    public protocol HiddenWhereBase {
                        associatedtype Peer
                    }
                    public protocol HiddenWhereCarrier:
                        HiddenWhereBase
                    where Peer: RuneScribeApplicationService
                    {}
                    """
                ),
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/ProtocolWhereConstraintRegression.swift",
                    """
                    import RuneScribeContracts

                    private struct ProtocolWhereConstraintRegression {
                        private let retained: any HiddenWhereCarrier
                    }
                    """
                )
            ]
            for file in files {
                let destination = root.appendingPathComponent(file.0)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.1.utf8).write(to: destination, options: .atomic)
            }
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testPeerTypeNameShadowingDoesNotTriggerFG005() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let invocation = try invokeGuard { root in
            let files: [(String, String)] = [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/PeerTypeNameShadowingRegression.swift",
                    """
                    public typealias SharedPeerHandle =
                        any RuneScribeApplicationService
                    """
                ),
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerTypeNameShadowingRegression.swift",
                    """
                    import RuneScribeContracts

                    private struct SharedPeerHandle {}

                    private struct LocalPeerNameHolder {
                        private let retained: SharedPeerHandle
                    }

                    private struct GenericPeerNameHolder<SharedPeerHandle> {
                        private let retained: SharedPeerHandle
                    }
                    """
                )
            ]
            for file in files {
                let destination = root.appendingPathComponent(file.0)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.1.utf8).write(to: destination, options: .atomic)
            }
        }
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testPeerTypeNameShadowingCannotSuppressDisjointScopeRetention() throws {
        try assertOverlayFilesReportOnly(
            ruleID: "FG-005",
            evidencePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerTypeNameScopeRegression.swift",
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/PeerTypeNameScopeRegression.swift",
                    """
                    public typealias ScopedPeerHandleRegression =
                        any RuneScribeApplicationService
                    """
                ),
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerTypeNameScopeRegression.swift",
                    """
                    import RuneScribeContracts

                    private enum HarmlessLocalPeerScopeRegression {
                        struct ScopedPeerHandleRegression {}
                        static let value: ScopedPeerHandleRegression? = nil
                    }

                    private struct DisjointPeerRetentionRegression {
                        private let retained: ScopedPeerHandleRegression
                    }
                    """
                )
            ],
            label: "peer-type-name-disjoint-scope-retention"
        )
    }

    func testPeerServiceNamesInCommentsAndStringsDoNotTriggerFG005() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )

        let invocation = try invokeGuard { root in
            let files: [(String, String)] = [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/CommentOnlyPeerAliasRegression.swift",
                    """
                    public typealias CommentOnlyPeerAlias = RuneScribeApplicationService
                    """
                ),
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CommentOnlyPeerAliasRegression.swift",
                    """
                    private let peerTypeDocumentation = "CommentOnlyPeerAlias RuneScribeApplicationService"
                    private let CommentOnlyPeerAlias = 1
                    private let RuneScribeApplicationService = 2
                    // CommentOnlyPeerAlias and RuneScribeApplicationService are documentation only.
                    """
                )
            ]
            for file in files {
                let destination = root.appendingPathComponent(file.0)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.1.utf8).write(to: destination, options: .atomic)
            }
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testPeerAndCoreNamesInRegexLiteralsDoNotTriggerGuards() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RegexLiteralGuardRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                private let peerPattern = /RuneScribeApplicationService|RuneScribeInboundInputService/
                private let corePattern = #/RuneScribeCoreApplicationService/#
                """.utf8
            ).write(to: destination, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testNonProviderShippingTargetRetentionReportsOnlyFG005() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerRetentionRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-005",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private struct PeerRetentionRegression {
                private let retained: any RuneScribeApplicationService
            }
            """
        )
    }

    func testPeerServiceInitializerAssignmentAndResultFlowReportsOnlyFG005() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerTypeFlowRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-005",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private typealias PeerTypeFlowHandle =
                any RuneScribeApplicationService

            private final class PeerTypeFlowRegression {
                private var retained: Any?

                init(hidden: PeerTypeFlowHandle) {
                    retained = hidden
                }

                private func resolveService() -> PeerTypeFlowHandle {
                    fatalError()
                }

                func replaceFromResolvedResult() {
                    retained = resolveService()
                }
            }
            """
        )
    }

    func testPeerServiceGenericConstraintRetentionReportsOnlyFG005() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PeerGenericConstraintRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-005",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private final class DirectPeerConstraintHolder<Peer: RuneScribeApplicationService> {
                private let retained: Peer

                init(retained: Peer) {
                    self.retained = retained
                }
            }

            private final class WherePeerConstraintHolder<Peer>
            where Peer: RuneScribeInboundInputService {
                private let retained: Peer

                init(retained: Peer) {
                    self.retained = retained
                }
            }
            """
        )
    }

    func testPeerServiceErasedRetentionFlowsReportOnlyFG005() throws {
        let fixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/AnyObjectPeerRetentionRegression.swift",
                """
                import RuneScribeContracts

                private final class AnyObjectPeerRetentionRegression {
                    private var retained: [AnyObject] = []

                    func accept(_ service: any RuneScribeApplicationService) {
                        retained.append(service)
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/HelperErasedPeerRetentionRegression.swift",
                """
                import RuneScribeContracts

                private final class HelperErasedPeerRetentionRegression {
                    private var retained: [AnyObject] = []

                    private func store(_ candidate: AnyObject) {
                        retained.append(candidate)
                    }

                    func accept(_ service: any RuneScribeInboundInputService) {
                        store(service)
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/SelfConstrainedPeerRetentionRegression.swift",
                """
                import RuneScribeContracts

                private protocol SelfConstrainedPeerRegression
                where Self: RuneScribeApplicationService {}

                private struct SelfConstrainedPeerRetentionRegression {
                    private let retained: any SelfConstrainedPeerRegression
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/ErasedIntermediatePeerRetentionRegression.swift",
                """
                import RuneScribeContracts

                private final class ErasedIntermediatePeerRetentionRegression {
                    private var retained: AnyObject?

                    func accept(_ peer: any RuneScribeApplicationService) {
                        let erased = peer as AnyObject
                        self.retained = erased
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/PropertyWrapperPeerRetentionRegression.swift",
                """
                import RuneScribeContracts

                @propertyWrapper
                private struct ErasedPeerBoxRegression {
                    var wrappedValue: Any

                    init(wrappedValue: Any) {
                        self.wrappedValue = wrappedValue
                    }
                }

                private struct PropertyWrapperPeerRetentionRegression {
                    @ErasedPeerBoxRegression var retained: Any

                    init(peer: any RuneScribeApplicationService) {
                        _retained = ErasedPeerBoxRegression(wrappedValue: peer)
                    }
                }
                """
            )
        ]

        for fixture in fixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-005",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }

        let memberConsumerPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CrossFilePeerMemberAssignmentRegression.swift"
        try assertOverlayFilesReportOnly(
            ruleID: "FG-005",
            evidencePath: memberConsumerPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CrossFilePeerBoxRegression.swift",
                    """
                    final class CrossFilePeerBoxRegression {
                        var value: AnyObject?
                    }
                    """
                ),
                (
                    memberConsumerPath,
                    """
                    import RuneScribeContracts

                    private let crossFilePeerBoxRegression =
                        CrossFilePeerBoxRegression()

                    private func retainCrossFilePeerRegression(
                        _ peer: any RuneScribeApplicationService
                    ) {
                        crossFilePeerBoxRegression.value = peer
                    }
                    """
                )
            ],
            label: "cross-file-peer-member-assignment"
        )

        let extensionConsumerPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CrossFilePeerExtensionRegression.swift"
        try assertOverlayFilesReportOnly(
            ruleID: "FG-005",
            evidencePath: extensionConsumerPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CrossFilePeerHolderRegression.swift",
                    """
                    final class CrossFilePeerHolderRegression {
                        var retained: AnyObject?
                    }
                    """
                ),
                (
                    extensionConsumerPath,
                    """
                    import RuneScribeContracts

                    extension CrossFilePeerHolderRegression {
                        func accept(_ peer: any RuneScribeApplicationService) {
                            retained = peer as AnyObject
                        }
                    }
                    """
                )
            ],
            label: "cross-file-peer-extension-assignment"
        )
    }

    func testPeerServiceLocalShadowsAndAssociatedMemberConstraintsDoNotTriggerFG005() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let fixtures: [(label: String, files: [(path: String, contents: String)])] = [
            (
                "local-alias-and-protocol-shadows",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/LocalPeerShadowRegression.swift",
                        """
                        public typealias LocalPeerAliasShadowRegression =
                            any RuneScribeApplicationService

                        public protocol LocalPeerProtocolShadowRegression:
                            RuneScribeInboundInputService
                        {}
                        """
                    ),
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/LocalPeerShadowRegression.swift",
                        """
                        import RuneScribeContracts

                        private typealias LocalPeerAliasShadowRegression = Int
                        private protocol LocalPeerProtocolShadowRegression {}

                        private struct LocalPeerShadowRegression {
                            private let aliasValue: LocalPeerAliasShadowRegression
                            private let protocolValue: (any LocalPeerProtocolShadowRegression)?
                        }
                        """
                    )
                ]
            ),
            (
                "associated-member-where-constraint",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/AssociatedMemberWhereRegression.swift",
                        """
                        public protocol AssociatedMemberContainerRegression {
                            associatedtype Service
                        }

                        public protocol AssociatedMemberWhereBaseRegression {
                            associatedtype Container: AssociatedMemberContainerRegression
                        }

                        public protocol AssociatedMemberWhereCarrierRegression:
                            AssociatedMemberWhereBaseRegression
                        where Container.Service: RuneScribeApplicationService
                        {}
                        """
                    ),
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/AssociatedMemberWhereRegression.swift",
                        """
                        import RuneScribeContracts

                        private struct AssociatedMemberWhereRegression {
                            private let retained: any AssociatedMemberWhereCarrierRegression
                        }
                        """
                    )
                ]
            ),
            (
                "exact-root-local-shadows",
                [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/ExactRootPeerShadowRegression.swift",
                        """
                        private struct RuneScribeApplicationService {}
                        private typealias RuneScribeInboundInputService = Int

                        private struct ExactRootPeerShadowRegression {
                            private let application: RuneScribeApplicationService
                            private let inbound: RuneScribeInboundInputService
                        }
                        """
                    )
                ]
            )
        ]

        for fixture in fixtures {
            let invocation = try invokeGuard { root in
                for file in fixture.files {
                    let destination = root.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(file.contents.utf8).write(to: destination, options: .atomic)
                }
            }

            XCTAssertEqual(invocation.status, 0, "\(fixture.label): \(invocation.standardError)")
            for rule in try reportRules(invocation.json) {
                let id = try XCTUnwrap(rule["id"] as? String, fixture.label)
                XCTAssertEqual(
                    rule["status"] as? String,
                    baselineStatuses[id],
                    "\(fixture.label): \(id)"
                )
            }
        }
    }

    func testDirectCoreBypassReportsOnlyFG006() throws {
        let relative = "RuneScrib/AppHost/DirectCoreBypassRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            import RuneScribeCoreModule

            private final class DirectCoreBypassRegression {
                private let service: RuneScribeCoreApplicationService

                init(service: RuneScribeCoreApplicationService) {
                    self.service = service
                }

                func lockDirectly() async {
                    await service.lock()
                }
            }
            """
        )
    }

    func testNonProviderShippingTargetDirectCoreBypassReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/DirectCoreBypassRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            import RuneScribeCoreModule

            private struct DirectCoreBypassRegression {
                private let service: RuneScribeCoreApplicationService
            }
            """
        )
    }

    func testConcreteCoreAliasBypassInCompositionReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ConcreteCoreAliasRegression.swift",
                    """
                    public typealias NeutralOperationalHandle =
                        RuneScribeCoreApplicationService
                    """
                ),
                (
                    compositionPath,
                    original + """

                    private struct ConcreteCoreAliasRegression {
                        private let retained: NeutralOperationalHandle
                    }
                    """
                )
            ],
            label: "concrete-core-alias-composition"
        )
    }

    func testConcreteCoreAliasStaticOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ConcreteCoreStaticAliasRegression.swift",
                    """
                    public enum ConcreteCoreStaticOwnerRegression {
                        public static func perform() {}
                    }

                    public typealias HiddenCoreStaticOwnerRegression =
                        ConcreteCoreStaticOwnerRegression
                    """
                ),
                (
                    compositionPath,
                    original + """

                    private func invokeConcreteCoreStaticAliasRegression() {
                        HiddenCoreStaticOwnerRegression.perform()
                    }
                    """
                )
            ],
            label: "concrete-core-static-alias-operation"
        )
    }

    func testConcreteCoreOperationSurfacesReportOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        let fixtures: [(
            label: String,
            providerPath: String,
            provider: String,
            consumer: String
        )] = [
            (
                "neutral-core-computed-property",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ConcreteCorePropertyRegression.swift",
                """
                public enum ConcreteCorePropertyRegression {
                    public
                    static
                    var liveValue: Int { 1 }
                }
                """,
                """

                private let concreteCorePropertyRegression = ConcreteCorePropertyRegression.liveValue
                """
            ),
            (
                "neutral-core-operation",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/NeutralCoreOperationRegression.swift",
                """
                public enum NeutralCoreOperationRegression {
                    public
                    static
                    func performNeutralOperation() {}
                }
                """,
                """

                private func invokeNeutralCoreOperationRegression() {
                    NeutralCoreOperationRegression.performNeutralOperation()
                }
                """
            ),
            (
                "neutral-core-instance-operation",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/NeutralCoreBridgeRegression.swift",
                """
                public
                final
                class NeutralCoreBridgeRegression {
                    public init() {}
                    public func perform() {}
                }
                """,
                """

                private func invokeNeutralCoreBridgeRegression(
                    _ bridge: NeutralCoreBridgeRegression
                ) {
                    bridge.perform()
                }
                """
            )
        ]
        for fixture in fixtures {
            try assertOverlayFilesReportOnly(
                ruleID: "FG-006",
                evidencePath: compositionPath,
                files: [
                    (fixture.providerPath, fixture.provider),
                    (compositionPath, original + fixture.consumer)
                ],
                label: fixture.label
            )
        }
    }

    func testCoreExtensionOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        let coreExtension = """
        public extension String {
            func performCoreExtensionOperation() {}
        }
        """
        let fixtures: [(label: String, consumer: String)] = [
            (
                "core-extension-literal-operation",
                """

                private func invokeCoreExtensionLiteralOperationRegression() {
                    "value".performCoreExtensionOperation()
                }
                """
            ),
            (
                "core-extension-inferred-result-operation",
                """

                private func makeCoreExtensionReceiverRegression() -> String {
                    "value"
                }

                private func invokeCoreExtensionInferredResultOperationRegression() {
                    makeCoreExtensionReceiverRegression().performCoreExtensionOperation()
                }
                """
            )
        ]
        for fixture in fixtures {
            try assertOverlayFilesReportOnly(
                ruleID: "FG-006",
                evidencePath: compositionPath,
                files: [
                    (
                        "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreExtensionOperationRegression.swift",
                        coreExtension
                    ),
                    (compositionPath, original + fixture.consumer)
                ],
                label: fixture.label
            )
        }
    }

    func testCoreSymbolCollisionConservativelyReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreSymbolCollisionRegression.swift",
                    """
                    public final class CoreSymbolCollisionRegression {
                        public init() {}
                        public func perform() {}
                    }
                    """
                ),
                (
                    compositionPath,
                    original + """

                    private final class CoreSymbolCollisionRegression {
                        func perform() {}
                    }

                    private func invokeCoreSymbolCollisionRegression() {
                        CoreSymbolCollisionRegression().perform()
                    }
                    """
                )
            ],
            label: "conservative-core-symbol-collision"
        )
    }

    func testRetainedTopLevelCoreFunctionReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/TopLevelCoreFunctionRegression.swift",
                    """
                    public func topLevelCoreFunctionRegression() {}
                    """
                ),
                (
                    compositionPath,
                    original + """

                    private let retainedTopLevelCoreFunctionRegression =
                        RuneScribeCoreModule.topLevelCoreFunctionRegression

                    private func invokeRetainedTopLevelCoreFunctionRegression() {
                        retainedTopLevelCoreFunctionRegression()
                    }
                    """
                )
            ],
            label: "retained-top-level-core-function"
        )
    }

    func testPublicRuntimeClientExtensionMustDispatchReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeClientExtensionBypassRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            public extension RuntimeApplicationClient {
                func bypassRuntimeDispatchRegression() async throws {
                    try await Task.yield()
                }
            }
            """
        )
    }

    func testRuntimeClientDummyDispatchCannotMaskBypassReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [
                (
                    relative,
                    original + """

                    public extension RuntimeApplicationClient {
                        func dummyDispatchMaskingRegression() async throws {
                            let unusedDispatch = { () async throws -> Void in
                                _ = try await command.send(
                                    RuntimeEmptyPayload(),
                                    to: RuntimeApplicationEndpointCatalog.lock
                                )
                            }
                            _ = unusedDispatch
                            try await Task.yield()
                        }
                    }


                    private enum QualifiedCatalogLookalikeRegression {
                        enum RuntimeApplicationEndpointCatalog {
                            static let lock:
                                RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload> =
                                fatalError()
                        }
                    }

                    public extension RuntimeApplicationClient {
                        func lock(qualifiedLookalike: Bool) async throws {
                            _ = try await command.send(
                                RuntimeEmptyPayload(),
                                to: QualifiedCatalogLookalikeRegression
                                    .RuntimeApplicationEndpointCatalog.lock
                            )
                        }
                    }
                    """
                )
            ],
            label: "runtime-client-dummy-dispatch-masking"
        )
    }

    func testRuntimeClientRequiresCanonicalCommandAndEndpointReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeClientLookalikeDispatchRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            public struct RuntimeCommandLookalikeRegression {
                public init() {}

                public func send<Request: Sendable, Endpoint: Sendable>(
                    _ request: Request,
                    to endpoint: Endpoint
                ) async throws {}
            }

            public struct RuntimeEndpointLookalikeRegression: Sendable {
                public init() {}
            }

            public extension RuntimeApplicationClient {
                func lookalikeDispatchRegression(
                    command: RuntimeCommandLookalikeRegression,
                    endpoint: RuntimeEndpointLookalikeRegression
                ) async throws {
                    try await command.send(RuntimeEmptyPayload(), to: endpoint)
                }
            }
            """
        )
    }

    func testTypedRuntimeClientOverloadsMustDispatchReportsOnlyFG006() throws {
        let fixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/CommandClientOverloadBypassRegression.swift",
                """
                public extension RuntimeCommandClient {
                    func send(
                        _ value: PINInput,
                        to endpoint: RuntimeEndpointKey<PINInput, Bool>
                    ) async throws -> Bool {
                        false
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/QueryClientOverloadBypassRegression.swift",
                """
                public extension RuntimeQueryClient {
                    func fetch(
                        _ value: PINInput,
                        from endpoint: RuntimeEndpointKey<PINInput, Bool>
                    ) async throws -> Bool {
                        false
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/StateClientOverloadBypassRegression.swift",
                """
                public extension RuntimeStateClient {
                    func subscribe(
                        to descriptor: RuntimeStateEndpointDescriptor<Int>,
                        bypass: Bool
                    ) async throws -> RuntimeStateStream<Int> {
                        fatalError()
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/IngressClientOverloadBypassRegression.swift",
                """
                public extension RuntimeIngressClient {
                    func submit(
                        _ value: PINInput,
                        to endpoint: RuntimeEndpointKey<PINInput, Bool>
                    ) async throws -> Bool {
                        false
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/GlobalDecoyClientBindingRegression.swift",
                """
                private let request = PINInput(digits: [])
                private let key: RuntimeEndpointKey<PINInput, Bool> = fatalError()

                public extension RuntimeCommandClient {
                    func send(
                        _ value: PINInput,
                        to endpoint: RuntimeEndpointKey<PINInput, Bool>
                    ) async throws -> Bool {
                        try await dispatcher.dispatch(
                            lease: lease,
                            key: key,
                            expectedKind: .command,
                            request: request,
                            requestSchemaVersion: key.descriptor.requestSchemaVersion,
                            responseSchemaVersion: key.descriptor.responseSchemaVersion,
                            idempotencyKey: nil
                        )
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/InternalTypedClientOverloadRegression.swift",
                """
                extension RuntimeCommandClient {
                    func send(
                        _ request: PINInput,
                        to key: RuntimeEndpointKey<PINInput, Bool>
                    ) async throws -> Bool {
                        false
                    }
                }
                """
            )
        ]
        for fixture in fixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-006",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }

        let dispatcherPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: dispatcherPath,
            anchor: """
            try await dispatcher.dispatch(
                        lease: lease,
                        key: key,
                        expectedKind: .command,
                        request: request,
            """,
            replacement: """
            try await dispatcher.dispatch(
                        lease: RuntimeClientLease(
                            runtimeGeneration: lease.runtimeGeneration,
                            sourceModuleID: "forged.module",
                            sourceGeneration: lease.sourceGeneration,
                            destinationModuleID: lease.destinationModuleID,
                            destinationGeneration: lease.destinationGeneration
                        ),
                        key: key,
                        expectedKind: .command,
                        request: request,
            """,
            label: "typed-runtime-client-forged-lease"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: dispatcherPath,
            anchor: """
            try await dispatcher.dispatch(
                        lease: lease,
                        key: key,
                        expectedKind: .command,
                        request: request,
            """,
            replacement: """
            try await dispatcher.dispatch(
                        lease: lease,
                        key: unsafeBitCast(
                            RuntimeApplicationEndpointCatalog.deleteAllImportedContacts,
                            to: RuntimeEndpointKey<Request, Response>.self
                        ),
                        expectedKind: .command,
                        request: request,
            """,
            label: "typed-runtime-client-forged-inner-key"
        )
    }

    func testTypedRuntimeClientTupleResultCannotMaskDispatchReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/QueryClientTupleResultRegression.swift"
        let canonicalDispatch = """
        try await dispatcher.dispatch(
                    lease: lease,
                    key: key,
                    expectedKind: .query,
                    request: request,
                    requestSchemaVersion: requestSchemaVersion
                        ?? key.descriptor.requestSchemaVersion,
                    responseSchemaVersion: responseSchemaVersion
                        ?? key.descriptor.responseSchemaVersion
                )
        """
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            public extension RuntimeQueryClient {
                func fetch<Request: Sendable, Response: Sendable>(
                    _ request: Request,
                    from key: RuntimeEndpointKey<Request, Response>,
                    requestSchemaVersion: RuntimeSchemaVersion? = nil,
                    responseSchemaVersion: RuntimeSchemaVersion? = nil,
                    forged: Response
                ) async throws -> Response {
                    (\(canonicalDispatch), forged).1
                }
            }
            """
        )
        let shadowFixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCatalogValueShadowRegression.swift",
                """
                private struct RuntimeCatalogValueTargetRegression {
                    let lock: RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload>
                }
                private let RuntimeApplicationEndpointCatalog =
                    RuntimeCatalogValueTargetRegression(lock: fatalError())

                public extension RuntimeApplicationClient {
                    func lock(valueShadowRegression: Bool) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCatalogTypeAliasShadowRegression.swift",
                """
                private enum RuntimeCatalogAliasTargetRegression {
                    static let lock:
                        RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload> =
                        fatalError()
                }
                private typealias RuntimeApplicationEndpointCatalog =
                    RuntimeCatalogAliasTargetRegression

                public extension RuntimeApplicationClient {
                    func lock(typeAliasShadowRegression: Bool) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCatalogGenericShadowRegression.swift",
                """
                public extension RuntimeApplicationClient {
                    func lock<RuntimeApplicationEndpointCatalog>(
                        genericShadowRegression: Bool
                    ) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCatalogFunctionShadowRegression.swift",
                """
                private func RuntimeApplicationEndpointCatalog() -> Never { fatalError() }

                public extension RuntimeApplicationClient {
                    func lock(functionShadowRegression: Bool) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCatalogNominalShadowRegression.swift",
                """
                private enum RuntimeApplicationEndpointCatalog {
                    static let lock:
                        RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload> =
                        fatalError()
                }

                public extension RuntimeApplicationClient {
                    func lock(nominalShadowRegression: Bool) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }
                """
            ),
        ]
        for fixture in shadowFixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-006",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let clean = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                public extension RuntimeQueryClient {
                    func fetch<Request: Sendable, Response: Sendable>(
                        _ request: Request,
                        from key: RuntimeEndpointKey<Request, Response>,
                        requestSchemaVersion: RuntimeSchemaVersion? = nil,
                        responseSchemaVersion: RuntimeSchemaVersion? = nil,
                        verifiedDirectTerminalRegression: Bool
                    ) async throws -> Response {
                        return \(canonicalDispatch)
                    }
                }
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testTypedRuntimeClientForwardedArgumentsRemainCanonicalFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: """
            expectedKind: .command,
                        request: request,
                        requestSchemaVersion: requestSchemaVersion
                            ?? key.descriptor.requestSchemaVersion,
            """,
            replacement: """
            expectedKind: .command,
                        request: request,
                        requestSchemaVersion: key.descriptor.requestSchemaVersion,
            """,
            label: "typed-client-unchecked-request-schema"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: """
            expectedKind: .command,
                        request: request,
                        requestSchemaVersion: requestSchemaVersion
                            ?? key.descriptor.requestSchemaVersion,
                        responseSchemaVersion: responseSchemaVersion
                            ?? key.descriptor.responseSchemaVersion,
                        idempotencyKey: idempotencyKey
            """,
            replacement: """
            expectedKind: .command,
                        request: request,
                        requestSchemaVersion: requestSchemaVersion
                            ?? key.descriptor.requestSchemaVersion,
                        responseSchemaVersion: responseSchemaVersion
                            ?? key.descriptor.responseSchemaVersion,
                        idempotencyKey: nil
            """,
            label: "typed-client-forged-idempotency"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: """
            lease: lease,
                        descriptor: descriptor,
                        subscriptionSchemaVersion: subscriptionSchemaVersion
                            ?? descriptor.subscriptionSchemaVersion,
            """,
            replacement: """
            lease: lease,
                        descriptor: RuntimeApplicationEndpointCatalog.applicationState,
                        subscriptionSchemaVersion: subscriptionSchemaVersion
                            ?? descriptor.subscriptionSchemaVersion,
            """,
            label: "typed-state-client-forged-descriptor"
        )
    }

    func testRuntimeClientSameShapeEndpointSwapReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift",
            anchor: "_ = try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.lock)",
            replacement: "_ = try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.deleteAllImportedContacts)",
            label: "runtime-client-same-shape-endpoint-swap"
        )
    }

    func testRuntimeApplicationClientPayloadAndExtraArgumentsReportOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: "try await command.send(value, to: RuntimeApplicationEndpointCatalog.encode)",
            replacement: "try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.encode)",
            label: "runtime-application-client-payload-swap"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: "try await command.send(value, to: RuntimeApplicationEndpointCatalog.encode)",
            replacement: """
            try await command.send(
                        value,
                        to: RuntimeApplicationEndpointCatalog.encode,
                        requestSchemaVersion: RuntimeSchemaVersions.v1
                    )
            """,
            label: "runtime-application-client-extra-dispatch-argument"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            anchor: "try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)",
            replacement: "(try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)) as Bool",
            label: "runtime-application-client-cast-result"
        )
    }

    func testRuntimeClientDecoyEndpointReferenceReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [
                (
                    relative,
                    source + """


                    public extension RuntimeApplicationClient {
                        func lock(
                            endpoint: RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload>
                        ) async throws {
                            _ = try await command.send(
                                {
                                    _ = RuntimeApplicationEndpointCatalog.lock
                                    return RuntimeEmptyPayload()
                                }(),
                                to: endpoint
                            )
                        }
                    }
                    """
                )
            ],
            label: "runtime-client-decoy-endpoint-reference"
        )
    }

    func testRuntimeApplicationEndpointCatalogShadowCannotMaskDispatchReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeEndpointCatalogShadowRegression.swift"
        let decoy = """
        public struct RuntimeEndpointCatalogShadowRegression: Sendable {
            public let lock:
                RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload>

            public init(
                lock: RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload>
            ) {
                self.lock = lock
            }
        }
        """
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            \(decoy)

            public extension RuntimeApplicationClient {
                func lock(
                    RuntimeApplicationEndpointCatalog: RuntimeEndpointCatalogShadowRegression
                ) async throws {
                    _ = try await command.send(
                        RuntimeEmptyPayload(),
                        to: RuntimeApplicationEndpointCatalog.lock
                    )
                }
            }
            """
        )

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let clean = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                \(decoy)

                public extension RuntimeApplicationClient {
                    func lock(
                        catalog: RuntimeEndpointCatalogShadowRegression
                    ) async throws {
                        _ = try await command.send(
                            RuntimeEmptyPayload(),
                            to: RuntimeApplicationEndpointCatalog.lock
                        )
                    }
                }

                private func disjointRuntimeCatalogShadowRegression() {
                    struct RuntimeApplicationEndpointCatalog {}
                    _ = RuntimeApplicationEndpointCatalog.self
                }

                private struct DisjointRuntimeCatalogOwnerRegression {
                    typealias RuntimeApplicationEndpointCatalog = Int
                }
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testExplicitTerminalRuntimeClientReturnDoesNotTriggerFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        let anchor = "try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)"
        let ranges = source.ranges(of: anchor)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        let mutated = source.replacingCharacters(
            in: range,
            with: "return try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)"
        )
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(mutated.utf8).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testRuntimeIngressShadowBindingsCannotSatisfyDispatchRailsFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "hostIngress.submit(input)",
            replacement: "let hostIngress = dispatcher\n"
                + "        return hostIngress.submit(input)",
            label: "runtime-submit-shadow-binding"
        )
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "try await dispatcher.dispatchHostIngress(input)",
            replacement: "let dispatcher = hostIngress\n"
                + "                try await dispatcher.dispatchHostIngress(input)",
            label: "runtime-start-shadow-binding"
        )
    }

    func testRuntimeClientAndSubmitConditionalPathsReportOnlyFG006() throws {
        let clientPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let canonicalLock = "_ = try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.lock)"
        let clientFixtures: [(label: String, replacement: String)] = [
            (
                "runtime-client-conditional-terminal-dispatch",
                "if true {\n"
                    + "            \(canonicalLock)\n"
                    + "        }"
            ),
            (
                "runtime-client-nonterminal-return-before-dispatch",
                "return\n"
                    + "        \(canonicalLock)"
            ),
            (
                "runtime-client-nonterminal-throw-before-dispatch",
                "throw CancellationError()\n"
                    + "        \(canonicalLock)"
            ),
            (
                "runtime-client-labeled-do-break-before-dispatch",
                "bypass: do {\n"
                    + "            break bypass\n"
                    + "            \(canonicalLock)\n"
                    + "        }"
            ),
            (
                "runtime-client-nested-do-return-before-dispatch",
                "do {\n"
                    + "            return\n"
                    + "            \(canonicalLock)\n"
                    + "        }"
            )
        ]
        for fixture in clientFixtures {
            try assertSourceReplacementReportsOnly(
                ruleID: "FG-006",
                relativePath: clientPath,
                anchor: canonicalLock,
                replacement: fixture.replacement,
                label: fixture.label
            )
        }

        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: clientPath,
            anchor: "try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)",
            replacement: "Bool.random() && (try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN))",
            label: "runtime-client-short-circuit-dispatch"
        )

        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "hostIngress.submit(input)",
            replacement: "if true {\n"
                + "            return .accepted\n"
                + "        }\n"
                + "        return hostIngress.submit(input)",
            label: "runtime-submit-early-return-masking"
        )
    }

    func testRuntimeStartConditionalDummyActivationCannotMaskBypassFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "hostIngress.activate { [dispatcher] input in\n"
                + "                try await dispatcher.dispatchHostIngress(input)\n"
                + "            }",
            replacement: "if false {\n"
                + "                hostIngress.activate { [dispatcher] input in\n"
                + "                    try await dispatcher.dispatchHostIngress(input)\n"
                + "                }\n"
                + "            }\n"
                + "            hostIngress.activate { _ in }",
            label: "runtime-start-conditional-dummy-activation"
        )
    }

    func testModuleContextDummyApplicationClientCallsReportOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/ModuleContextDummyClientCallsRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            private struct ModuleContextDummyClientCallsRegression {
                func commandClient() {}
                func queryClient() {}
                func stateClient() {}
                func subscribe() {}
                func subscribeToMenuCommands() {}
            }

            public extension ModuleContext {
                func applicationClient(dummyRegression: Bool) async throws -> RuntimeApplicationClient {
                    let dummy = ModuleContextDummyClientCallsRegression()
                    dummy.commandClient()
                    dummy.queryClient()
                    dummy.stateClient()
                    dummy.subscribe()
                    dummy.subscribeToMenuCommands()
                    fatalError()
                }
            }
            """
        )
    }

    func testModuleContextTopLevelClientOverloadCannotMaskBindingReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        let anchor = "let command = try await self.commandClient(to: destination)"
        let ranges = source.ranges(of: anchor)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        let overload = """


        private func commandClient(
            _ bypass: Bool,
            to destination: RuntimeEndpointDestination
        ) async throws -> RuntimeCommandClient {
            fatalError()
        }
        """

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-006"], "pass")

        let mutated = source.replacingCharacters(
            in: range,
            with: "let command = try await commandClient(true, to: destination)"
        ) + overload
        let bypass = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(mutated.utf8).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(bypass.status, 0, bypass.standardError)
        let bypassRules = try reportRules(bypass.json)
        let result = try XCTUnwrap(bypassRules.first { ($0["id"] as? String) == "FG-006" })
        XCTAssertEqual(result["status"] as? String, "violation")
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
        XCTAssertTrue(evidence.contains { ($0["path"] as? String) == relative })
        for rule in bypassRules where (rule["id"] as? String) != "FG-006" {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }

        let clean = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((source + overload).utf8).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testModuleContextTupleSelectedClientCannotMaskBindingReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        let anchor = "let command = try await self.commandClient(to: destination)"
        let ranges = source.ranges(of: anchor)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        let bypass = source.replacingCharacters(
            in: range,
            with: """
            let forgedCommand: RuntimeCommandClient = fatalError()
                    let command = (
                        try await self.commandClient(to: destination),
                        forgedCommand
                    ).1
            """
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [(relative, bypass)],
            label: "module-context-tuple-selected-command-client"
        )

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let cleanSource = source.replacingCharacters(
            in: range,
            with: "let command = (try await self.commandClient(to: destination))"
        )
        let clean = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(cleanSource.utf8).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testModuleContextApplicationClientExactFactoryReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let fixtures: [(label: String, anchor: String, replacement: String)] = [
            (
                "module-context-wrong-core-destination",
                "let destination: RuntimeEndpointDestination = .role(RuneScribeRoles.core)",
                "let destination: RuntimeEndpointDestination = .role(RuneScribeRoles.ui)"
            ),
            (
                "module-context-unqualified-command-client",
                "let command = try await self.commandClient(to: destination)",
                "let command = try await commandClient(to: destination)"
            ),
            (
                "module-context-swapped-query-client",
                "let query = try await self.queryClient(to: destination)",
                "let query = try await self.commandClient(to: destination)"
            ),
            (
                "module-context-wrong-state-endpoint",
                "to: RuntimeApplicationEndpointCatalog.applicationState",
                "to: RuntimeApplicationEndpointCatalog.menuCommands"
            ),
            (
                "module-context-extra-factory-statement",
                "let command = try await self.commandClient(to: destination)",
                "let ignored = destination\n        let command = try await self.commandClient(to: destination)"
            ),
            (
                "module-context-command-reassignment",
                "let command = try await self.commandClient(to: destination)",
                """
                var command = try await self.commandClient(to: destination)
                        command = try await self.commandClient(
                            to: .role(RuneScribeRoles.ui)
                        )
                """
            ),
        ]
        for fixture in fixtures {
            try assertSourceReplacementReportsOnly(
                ruleID: "FG-006",
                relativePath: relative,
                anchor: fixture.anchor,
                replacement: fixture.replacement,
                label: fixture.label
            )
        }

        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        func replacingSingle(_ anchor: String, with replacement: String) throws -> String {
            let ranges = source.ranges(of: anchor)
            XCTAssertEqual(ranges.count, 1, anchor)
            return source.replacingCharacters(
                in: try XCTUnwrap(ranges.first),
                with: replacement
            )
        }
        let commandOverload = """


        private extension ModuleContext {
            func commandClient(
                _ bypass: Bool,
                to destination: RuntimeEndpointDestination
            ) async throws -> RuntimeCommandClient {
                fatalError()
            }
        }
        """
        let selectedCommandOverload = try replacingSingle(
            "let command = try await self.commandClient(to: destination)",
            with: "let command = try await self.commandClient(true, to: destination)"
        ) + commandOverload
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [(relative, selectedCommandOverload)],
            label: "module-context-exact-self-extra-argument-overload"
        )

        let stateOverload = """


        private extension RuntimeStateClient {
            func subscribe<State: Sendable>(
                to descriptor: RuntimeStateEndpointDescriptor<State>,
                bypass: Bool
            ) async throws -> RuntimeStateStream<State> {
                fatalError()
            }
        }
        """
        let selectedStateOverload = try replacingSingle(
            """
            let applicationState = try await state.subscribe(
                        to: RuntimeApplicationEndpointCatalog.applicationState
                    )
            """,
            with: """
            let applicationState = try await state.subscribe(
                        to: RuntimeApplicationEndpointCatalog.applicationState,
                        bypass: true
                    )
            """
        ) + stateOverload
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [(relative, selectedStateOverload)],
            label: "module-context-state-extra-argument-overload"
        )

        let forgedCommandDeclaration = """


        private let forgedFactoryCommandRegression: RuntimeCommandClient = fatalError()
        """
        let decoyFactory = """


        private enum ForgedRuntimeApplicationClientFactoryRegression {
            static func make(
                command: RuntimeCommandClient,
                query: RuntimeQueryClient,
                applicationStateEnvelopes: RuntimeStateStream<RuneScribeApplicationSnapshot>,
                menuCommandEnvelopes: RuntimeStateStream<ApplicationMenuCommandDTO>
            ) -> RuntimeApplicationClient {
                RuntimeApplicationClient(
                    command: forgedFactoryCommandRegression,
                    query: query,
                    applicationStateEnvelopes: applicationStateEnvelopes,
                    menuCommandEnvelopes: menuCommandEnvelopes
                )
            }
        }
        """
        let selectedDecoyFactory = try replacingSingle(
            "return RuntimeApplicationClient(",
            with: "return ForgedRuntimeApplicationClientFactoryRegression.make("
        ) + forgedCommandDeclaration + decoyFactory
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [(relative, selectedDecoyFactory)],
            label: "module-context-selectable-qualified-decoy-factory"
        )

        let bypassInitializer = """


        private extension RuntimeApplicationClient {
            init(
                command: RuntimeCommandClient,
                query: RuntimeQueryClient,
                applicationStateEnvelopes: RuntimeStateStream<RuneScribeApplicationSnapshot>,
                menuCommandEnvelopes: RuntimeStateStream<ApplicationMenuCommandDTO>,
                bypass: RuntimeCommandClient
            ) {
                self.init(
                    command: bypass,
                    query: query,
                    applicationStateEnvelopes: applicationStateEnvelopes,
                    menuCommandEnvelopes: menuCommandEnvelopes
                )
            }
        }
        """
        let selectedBypassInitializer = try replacingSingle(
            "menuCommandEnvelopes: menuCommands\n        )",
            with: """
            menuCommandEnvelopes: menuCommands,
                    bypass: forgedFactoryCommandRegression
                )
            """
        ) + forgedCommandDeclaration + bypassInitializer
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: relative,
            files: [(relative, selectedBypassInitializer)],
            label: "module-context-selectable-extra-argument-initializer"
        )

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String,
                      let status = rule["status"] as? String
                else {
                    return nil
                }
                return (id, status)
            }
        )
        let cleanUnusedOverload = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((source + commandOverload).utf8).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(cleanUnusedOverload.status, 0, cleanUnusedOverload.standardError)
        for rule in try reportRules(cleanUnusedOverload.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testCoreBootstrapAliasOutsideCompositionReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let consumerPath = "RuneScrib/AppHost/CoreBootstrapAliasRegression.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: consumerPath,
            files: [
                (
                    compositionPath,
                    composition + """


                    typealias CoreBootstrapAliasRegression =
                        RuneScribeCoreModuleBootstrap
                    """
                ),
                (
                    consumerPath,
                    """
                    private let aliasedBootstrapManifestRegression =
                        CoreBootstrapAliasRegression.manifest()
                    """
                )
            ],
            label: "core-bootstrap-alias-outside-composition"
        )
    }

    func testOpenCoreOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/OpenCoreOperationRegression.swift",
                    """
                    open class OpenCoreOperationRegression {
                        public init() {}
                        open func performCoreOperation() {}
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private func invokeOpenCoreOperationRegression() {
                        OpenCoreOperationRegression().performCoreOperation()
                    }
                    """
                )
            ],
            label: "open-core-operation"
        )
    }

    func testCoreInitializerOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreInitializerOperationRegression.swift",
                    """
                    public extension String {
                        init(coreOperation value: Int) {
                            self = String(value)
                        }

                        init(defaultedCoreOperation value: Int = 0) {
                            self = String(value)
                        }

                        init(coreValues values: Int...) {
                            self = values.map(String.init).joined(separator: ",")
                        }
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private let coreInitializerOperationRegression =
                        String(coreOperation: 1)

                    private let defaultedCoreInitializerOperationRegression =
                        String()

                    private let variadicCoreInitializerOperationRegression =
                        String(coreValues: 1, 2)
                    """
                )
            ],
            label: "core-initializer-operation"
        )
    }

    func testCoreExtensionOwnerAliasOperationsReportOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreExtensionOwnerAliasRegression.swift",
                    """
                    public extension String {
                        init(coreAliasOperation value: Int) {
                            self = String(value)
                        }

                        func performCoreAliasOperation() -> String {
                            self
                        }
                    }

                    public typealias CoreDeclaredTextAliasRegression = String

                    public extension CoreDeclaredTextAliasRegression {
                        func performCoreAliasDeclaredOperationRegression() {}
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private typealias CoreExtensionTextAliasRegression = String

                    private func invokeCoreExtensionOwnerAliasRegression(
                        _ value: CoreExtensionTextAliasRegression
                    ) {
                        _ = CoreExtensionTextAliasRegression(coreAliasOperation: 1)
                        _ = value.performCoreAliasOperation()
                        "value".performCoreAliasDeclaredOperationRegression()
                    }
                    """
                )
            ],
            label: "core-extension-owner-alias-operations"
        )
    }

    func testCoreCallAsFunctionOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreCallAsFunctionRegression.swift",
                    """
                    public extension String {
                        func callAsFunction() {}
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private func invokeCoreCallAsFunctionRegression() {
                        "value"()
                        struct Wrapper {
                            let value: String
                        }
                        Wrapper(value: "nested").value()
                    }
                    """
                )
            ],
            label: "core-call-as-function-operation"
        )
    }

    func testCoreContextualKeyPathAndVariadicSurfacesReportOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreExtendedSyntaxRegression.swift",
                    """
                    public extension String {
                        init(contextualCoreOperation value: Int) {
                            self = String(value)
                        }

                        init(_ contextualCoreValues: Int...) {
                            self = contextualCoreValues.map(String.init).joined()
                        }

                        static var contextualCoreStaticValue: String { "core" }
                        var coreComputedValueRegression: Int { count }

                        subscript(coreIndex index: Int) -> Character {
                            self[self.index(startIndex, offsetBy: index)]
                        }

                        subscript(_ coreIndices: Int...) -> Int {
                            coreIndices.count
                        }
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private let contextualCoreInitializerRegression: String =
                        .init(contextualCoreOperation: 1)
                    private let contextualCoreStaticRegression: String =
                        .contextualCoreStaticValue
                    private let retainedCoreInitializerRegression: (Int) -> String =
                        String.init(contextualCoreOperation:)
                    private let variadicCoreInitializerRegression = String(1, 2)
                    private let corePropertyKeyPathRegression =
                        \\String.coreComputedValueRegression
                    private let coreSubscriptKeyPathRegression =
                        \\String.[coreIndex: 0]

                    private func invokeVariadicCoreSubscriptRegression(_ value: String) {
                        _ = value[1, 2]
                    }
                    """
                )
            ],
            label: "core-contextual-keypath-variadic-surfaces"
        )
    }

    func testCoreCollectionSugarExtensionOperationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreArrayExtensionRegression.swift",
                    """
                    public extension Array where Element == String {
                        func performCoreArrayOperationRegression() {}
                    }
                    """
                ),
                (
                    compositionPath,
                    composition + """


                    private func invokeCoreArrayExtensionRegression() {
                        let values: [String] = []
                        values.performCoreArrayOperationRegression()
                    }
                    """
                )
            ],
            label: "core-array-extension-sugar-receiver"
        )
    }

    func testOptionalCoreExtensionOperationReportsOnlyFG006() throws {
        let corePath = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreOptionalExtensionRegression.swift"
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let composition = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        let coreExtension = """
        public extension Optional where Wrapped == String {
            func performOptionalCoreOperationRegression() {}
        }

        public extension String {
            func performOptionalWrappedCoreOperationRegression() {}
        }
        """
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (corePath, coreExtension),
                (
                    compositionPath,
                    composition + """


                    private func invokeOptionalCoreOperationRegression(
                        _ value: String?
                    ) {
                        value.performOptionalCoreOperationRegression()
                    }
                    """
                )
            ],
            label: "optional-core-extension-operation"
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (corePath, coreExtension),
                (
                    compositionPath,
                    composition + """


                    private func invokeOptionalWrappedCoreOperationRegression(
                        _ value: String?
                    ) {
                        value?.performOptionalWrappedCoreOperationRegression()
                    }
                    """
                )
            ],
            label: "optional-chained-wrapped-core-extension-operation"
        )

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let localPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/LocalOptionalCollisionRegression.swift"
        let clean = try invokeGuard { root in
            for file in [
                (corePath, coreExtension),
                (
                    localPath,
                    """
                    private struct LocalOptionalCollision {
                        func performOptionalCoreOperationRegression() {}
                    }

                    private struct LocalOptionalWrappedCollision {
                        func performOptionalWrappedCoreOperationRegression() {}
                    }

                    private func invokeLocalOptionalCollision(
                        _ value: LocalOptionalCollision
                    ) {
                        value.performOptionalCoreOperationRegression()
                    }

                    private func invokeLocalOptionalWrappedCollision(
                        _ value: LocalOptionalWrappedCollision?
                    ) {
                        value?.performOptionalWrappedCoreOperationRegression()
                    }
                    """
                )
            ] {
                let destination = root.appendingPathComponent(file.0)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.1.utf8).write(to: destination, options: .atomic)
            }
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testTypedLocalCoreExtensionCollisionDoesNotTriggerFG006() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let invocation = try invokeGuard { root in
            let core = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreArrayCollisionRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: core.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                public extension Array where Element == String {
                    func performCoreArrayCollisionRegression() {}
                }

                public extension String {
                    func callAsFunction() {}
                }
                """.utf8
            ).write(to: core, options: .atomic)

            let consumer = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/CoreArrayCollisionRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: consumer.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                private struct LocalArrayCollisionRegression {
                    func performCoreArrayCollisionRegression() {}
                }

                private struct LocalCallableCollisionRegression {
                    func callAsFunction() {}
                }

                private struct LocalHolderCollisionRegression {
                    let value: LocalCallableCollisionRegression
                }

                private func invokeLocalHolderCollisionRegression() {
                    LocalHolderCollisionRegression(
                        value: LocalCallableCollisionRegression()
                    ).value()
                }

                private struct StringHolderCollisionRegression {
                    let value: String
                }

                private func unrelatedArrayBindingRegression() {
                    let value: [String] = []
                    _ = value
                }

                private func invokeLocalArrayCollisionRegression(
                    _ value: LocalArrayCollisionRegression
                ) {
                    value.performCoreArrayCollisionRegression()
                }

                private func invokeLocalCallableCollisionRegression(
                    _ value: LocalCallableCollisionRegression
                ) {
                    value()
                }
                """.utf8
            ).write(to: consumer, options: .atomic)
        }
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testDirectCoreBypassInsideStringInterpolationReportsOnlyFG006() throws {
        let compositionPath = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
        let original = try String(
            contentsOf: repository.appendingPathComponent(compositionPath),
            encoding: .utf8
        )
        let fixtures: [(label: String, snippet: String)] = [
            (
                "direct-core-string-interpolation",
                """

                private func directCoreInterpolationRegression(_ value: Any) async {
                    let _ = "\\(await (value as! RuneScribeCoreApplicationService).lock())"
                }
                """
            ),
            (
                "direct-core-raw-string-interpolation",
                """

                private func directCoreRawInterpolationRegression(_ value: Any) async {
                    let _ = #"\\#(await (value as! RuneScribeCoreApplicationService).lock())"#
                }
                """
            )
        ]
        for fixture in fixtures {
            try assertOverlayFilesReportOnly(
                ruleID: "FG-006",
                evidencePath: compositionPath,
                files: [(compositionPath, original + fixture.snippet)],
                label: fixture.label
            )
        }
        try assertOverlayFilesReportOnly(
            ruleID: "FG-006",
            evidencePath: compositionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/NeutralCoreFactoryRegression.swift",
                    """
                    public final class NeutralInterpolationCoreBridge {
                        public init() {}
                        public func perform() -> String { "value" }
                    }

                    public func makeHiddenCoreHandle() -> NeutralInterpolationCoreBridge {
                        NeutralInterpolationCoreBridge()
                    }
                    """
                ),
                (
                    compositionPath,
                    original + """

                    private func neutralCoreInterpolationRegression() {
                        let _ = "\\(makeHiddenCoreHandle().perform())"
                    }
                    """
                )
            ],
            label: "neutral-core-factory-string-interpolation"
        )
    }

    func testLegacyServiceEndpointTranslationReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/LegacyServiceEndpointTranslationRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            private enum LegacyServiceEndpointTranslationRegression {
                static func mergeDeclarations() {}
                static func consumedEndpointIDs() {}
                static func publishedEndpointIDs() {}
            }
            """
        )
    }

    func testConsumerMenuBufferReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/ConsumerMenuBufferRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private final class ConsumerMenuBufferRegression {
                private var retained: [ApplicationMenuCommandDTO] = []

                func accept(_ command: ApplicationMenuCommandDTO) {
                    retained.append(command)
                }
            }
            """
        )
    }

    func testAliasedConsumerMenuBufferReportsOnlyFG006() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/AliasedConsumerMenuBufferRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-006",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private typealias AliasedConsumerMenuQueueRegression =
                [ApplicationMenuCommandDTO]

            private final class AliasedConsumerMenuBufferRegression {
                private var retained: AliasedConsumerMenuQueueRegression = []
            }
            """
        )
    }

    func testActivationCompletenessCallRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "dispatcher.publishedEndpointsAvailable(",
            replacement: "dispatcher.uncheckedPublishedEndpointsAvailable(",
            label: "activation-completeness-removal"
        )
    }

    func testRuntimeSubmitRailRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "hostIngress.submit(input)",
            replacement: "uncheckedHostIngress.submit(input)",
            label: "runtime-submit-rail-removal"
        )
    }

    func testStopQuiescenceDrainRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "await dispatcher.beginRuntimeQuiesce()",
            replacement: "await dispatcher.beginRuntimeStop()",
            label: "stop-quiescence-drain-removal"
        )
    }

    func testMenuCapacityAuthorityRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift",
            anchor: "public static let menuCapacity = 16",
            replacement: "public static let menuCapacity = 15",
            label: "menu-capacity-authority-removal"
        )
    }

    func testIngressFailureObserverRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift",
            anchor: "runtime.observeHostIngressFailures",
            replacement: "runtime.ignoreHostIngressFailures",
            label: "ingress-failure-observer-removal"
        )
    }

    func testEarlyStartStopCheckRemovalReportsOnlyFG006() throws {
        try assertSourceReplacementReportsOnly(
            ruleID: "FG-006",
            relativePath: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
            anchor: "await startCoordinator.beforeInfrastructureActivation()\n"
                + "        if stopRequestedWhileStarting {\n"
                + "            await finishInterruptedStart()\n"
                + "            return\n"
                + "        }",
            replacement: "await startCoordinator.beforeInfrastructureActivation()",
            label: "early-start-stop-check-removal"
        )
    }

    func testGenericRawResolverRegressionReportsFG004() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/GenericRawResolverRegression.swift"
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineResult = try XCTUnwrap(
            baselineRules.first { ($0["id"] as? String) == "FG-004" }
        )
        XCTAssertEqual(baselineResult["status"] as? String, "pass")

        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                struct GenericRawResolverRegression {
                    let value: any Sendable
                    func resolve<Value: Sendable>() throws -> Value {
                        guard let resolved = value as? Value else { throw RegressionError.mismatch }
                        return resolved
                    }
                }
                enum RegressionError: Error { case mismatch }
                """.utf8
            ).write(to: destination, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == "FG-004" })
        XCTAssertEqual(result["status"] as? String, "violation")
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
        XCTAssertTrue(evidence.contains { ($0["path"] as? String) == relative })
    }

    func testProviderResultPublicationSurfacesReportOnlyFG004() throws {
        let fixtures: [(label: String, path: String, contents: String)] = [
            (
                "provider-protocol-function-result",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderFunctionResultRegression.swift",
                """
                import RuneScribeContracts

                public func exposeProviderRegression(
                    _ value: any RuneScribeApplicationService
                ) -> any RuneScribeApplicationService {
                    value
                }
                """
            ),
            (
                "concrete-provider-computed-property",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderComputedPropertyRegression.swift",
                """
                public enum ProviderComputedPropertyRegression {
                    public static var live: RuneScribeCoreApplicationService {
                        fatalError()
                    }
                }
                """
            ),
            (
                "provider-protocol-subscript-result",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderSubscriptResultRegression.swift",
                """
                import RuneScribeContracts

                public struct ProviderSubscriptResultRegression {
                    public subscript(index: Int) -> any RuneScribeApplicationService {
                        fatalError()
                    }
                }
                """
            ),
            (
                "inferred-concrete-provider-stored-property",
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/InferredProviderStoredPropertyRegression.swift",
                """
                public enum InferredProviderStoredPropertyRegression {
                    public static let live = RuneScribeCoreApplicationService()
                }
                """
            )
        ]
        for fixture in fixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-004",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }
    }

    func testProviderSemanticPublicationSurfacesReportOnlyFG004() throws {
        let fixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/OpenProviderResultRegression.swift",
                """
                import RuneScribeContracts

                open class OpenProviderResultRegression {
                    public init() {}

                    open func resolve() -> any RuneScribeApplicationService {
                        fatalError()
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/AliasedSelfPublicationRegression.swift",
                """
                import RuneScribeRuntimeCore

                private struct AliasedSelfPublicationRegression {
                    func publish(through context: ModuleContext) async throws {
                        let aliasedSelf = self
                        try await context.publishService((aliasedSelf))
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/RawAnyAliasStorageRegression.swift",
                """
                private typealias RawAnyAliasStorageRegression = [String: Any]

                private struct RawAnyAliasRegistryRegression {
                    private var storage: RawAnyAliasStorageRegression = [:]

                    mutating func retain<Candidate: Sendable>(_ candidate: Candidate) {
                        storage["provider"] = candidate
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/NestedRegistryAppendRegression.swift",
                """
                private struct NestedRegistryAppendRegression {
                    private var registry: [String: [Any]] = [:]

                    mutating func retain<Candidate: Sendable>(_ candidate: Candidate) {
                        registry["providers", default: []].append(candidate)
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ErasedCandidateCastProvenanceRegression.swift",
                """
                private struct ErasedCandidateCastProvenanceRegression {
                    func resolve<Candidate: Sendable>(
                        _ candidate: Any,
                        as type: Candidate.Type
                    ) -> Candidate? {
                        let erasedCandidate = candidate
                        let forwardedCandidate = erasedCandidate
                        return forwardedCandidate as? Candidate
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/InferredPrivateProviderValueRegression.swift",
                """
                import RuneScribeContracts

                private let privateTypedProviderValueRegression:
                    any RuneScribeApplicationService = fatalError()

                private let chainedPrivateProviderValueRegression =
                    privateTypedProviderValueRegression

                public let inferredPublicProviderValueRegression =
                    chainedPrivateProviderValueRegression
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/PublicProviderPayloadRegression.swift",
                """
                import RuneScribeContracts

                public enum PublicProviderPayloadRegression {
                    case service(any RuneScribeApplicationService)
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/PublicProviderRequirementRegression.swift",
                """
                import RuneScribeContracts

                public protocol PublicProviderRequirementRegression {
                    func service() -> any RuneScribeApplicationService
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ErasedProviderPublicationRegression.swift",
                """
                import RuneScribeContracts

                private let erasedProviderPublicationSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public func erasedProviderPublicationFunctionRegression() -> AnyObject {
                    erasedProviderPublicationSourceRegression as AnyObject
                }

                public var erasedProviderPublicationPropertyRegression: Any {
                    erasedProviderPublicationSourceRegression
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/AnyObjectHelperPublicationRegression.swift",
                """
                import RuneScribeContracts

                private var anyObjectHelperPublicationStorageRegression:
                    [String: AnyObject] = [:]

                private func storeAnyObjectHelperPublicationRegression2(
                    _ value: AnyObject
                ) {
                    anyObjectHelperPublicationStorageRegression["provider"] = value
                }

                private func storeAnyObjectHelperPublicationRegression1(
                    _ value: AnyObject
                ) {
                    let forwarded = value
                    storeAnyObjectHelperPublicationRegression2(forwarded)
                }

                private final class AnyObjectHelperProviderRegression:
                    RuneScribeApplicationService
                {
                    func expose() {
                        storeAnyObjectHelperPublicationRegression1(self)
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/InlineErasedProviderPublicationRegression.swift",
                """
                import RuneScribeContracts

                public final class InlineErasedProviderPublicationRegression:
                    RuneScribeApplicationService
                {
                    public init() {}
                }

                public func makeInlineErasedProviderPublicationRegression() -> AnyObject {
                    InlineErasedProviderPublicationRegression()
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ErasedProviderHelperReturnRegression.swift",
                """
                extension RuneScribeCoreApplicationService {
                    private func erasedProviderHelperReturnRegression() -> AnyObject {
                        self
                    }

                    public func exposeErasedProviderHelperReturnRegression() -> AnyObject {
                        erasedProviderHelperReturnRegression()
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/HelperReturnedRawRegistryRegression.swift",
                """
                private func makeHelperReturnedRawRegistryRegression() -> [String: Any] {
                    [:]
                }

                private struct HelperReturnedRawRegistryRegression {
                    private var registry = makeHelperReturnedRawRegistryRegression()

                    mutating func retain<Candidate: Sendable>(_ candidate: Candidate) {
                        registry["provider"] = candidate
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ErasedProviderPropertyHelperRegression.swift",
                """
                extension RuneScribeCoreApplicationService {
                    private var erasedProviderPropertyHelperRegression: AnyObject {
                        self
                    }

                    private func erasedProviderFunctionHelperRegression() -> AnyObject {
                        self
                    }

                    public func exposeErasedProviderPropertyHelperRegression() -> AnyObject {
                        erasedProviderPropertyHelperRegression
                    }

                    public var computedErasedProviderFunctionHelperRegression: AnyObject {
                        erasedProviderFunctionHelperRegression()
                    }
                }

                private let inferredErasedProviderPropertySourceRegression =
                    RuneScribeCoreApplicationService()

                private func inferredErasedProviderPropertyHelperRegression() -> AnyObject {
                    inferredErasedProviderPropertySourceRegression
                }

                public let inferredErasedProviderPropertyRegression =
                    inferredErasedProviderPropertyHelperRegression()
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/GenericProviderCastRegression.swift",
                """
                extension RuneScribeCoreApplicationService {
                    public func exposeGenericProviderCastRegression<Candidate>() -> Candidate? {
                        self as? Candidate
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderWrapperPublicationRegression.swift",
                """
                import RuneScribeContracts

                public struct ProviderWrapperPublicationBoxRegression {
                    public let value: AnyObject
                }

                private let providerWrapperPublicationSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerWrapperPublicationRegression =
                    ProviderWrapperPublicationBoxRegression(
                        value: providerWrapperPublicationSourceRegression as AnyObject
                    )
                """
            )
        ]

        for fixture in fixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-004",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }

        let splitRawExtensionPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/SplitRawRegistryExtensionRegression.swift"
        try assertOverlayFilesReportOnly(
            ruleID: "FG-004",
            evidencePath: splitRawExtensionPath,
            files: [
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/SplitRawRegistryRegression.swift",
                    """
                    struct SplitRawRegistryRegression {
                        var values: [String: Any] = [:]
                    }
                    """
                ),
                (
                    splitRawExtensionPath,
                    """
                    extension SplitRawRegistryRegression {
                        mutating func retain<Candidate: Sendable>(_ candidate: Candidate) {
                            values["provider"] = candidate
                        }
                    }
                    """
                ),
                (
                    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/SplitRawRegistryProviderRegression.swift",
                    """
                    import RuneScribeContracts

                    final class SplitRawRegistryProviderRegression:
                        RuneScribeApplicationService
                    {
                        private var registry = SplitRawRegistryRegression()

                        func expose() {
                            registry.retain(self)
                        }
                    }
                    """
                )
            ],
            label: "split-file-raw-registry-extension"
        )

        let runtimeSinkPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeRawProviderSinkRegression.swift"
        let coreForwardPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/PrivateProviderForwardRegression.swift"
        try assertOverlayFilesReportOnly(
            ruleID: "FG-004",
            evidencePath: coreForwardPath,
            files: [
                (
                    runtimeSinkPath,
                    """
                    public final class RuntimeRawProviderSinkRegression {
                        private var retained: [AnyObject] = []

                        public init() {}

                        public func store(_ value: AnyObject) {
                            retained.append(value)
                        }
                    }
                    """
                ),
                (
                    coreForwardPath,
                    """
                    import RuneScribeContracts
                    import RuneScribeRuntimeCore

                    private let runtimeRawProviderSinkRegression =
                        RuntimeRawProviderSinkRegression()

                    private func forwardPrivateProviderRegression(_ value: AnyObject) {
                        runtimeRawProviderSinkRegression.store(value)
                    }

                    private final class PrivateProviderForwardRegression:
                        RuneScribeApplicationService
                    {
                        func expose() {
                            forwardPrivateProviderRegression(self)
                        }
                    }
                    """
                )
            ],
            label: "runtime-raw-sink-private-provider-forward"
        )
    }

    func testProviderHandlerAllowlistRequiresCanonicalModuleContextReportsOnlyFG004() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/HandlerAllowlistIdentityRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-004",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            private struct ModuleContext {
                private static var retained: [AnyObject] = []

                func registerApplicationEndpoints(_ value: AnyObject) {
                    Self.retained.append(value)
                }
            }

            private final class HandlerAllowlistIdentityProviderRegression:
                RuneScribeApplicationService
            {
                func expose(through context: ModuleContext) {
                    context.registerApplicationEndpoints(self)
                }
            }
            """
        )
    }

    func testCanonicalProviderRegistrationCannotRetainProviderReportsOnlyFG004() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
        let source = try String(
            contentsOf: repository.appendingPathComponent(relative),
            encoding: .utf8
        )
        let anchor = "public extension ModuleContext {"
        let ranges = source.ranges(of: anchor)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        let mutated = source.replacingCharacters(
            in: range,
            with: """
            private var retainedProviderRegistrationRegression: [AnyObject] = []

            public extension ModuleContext {
            """
        ).replacingOccurrences(
            of: "func registerApplicationEndpoints(_ service: any RuneScribeApplicationService) async throws {",
            with: """
            func registerApplicationEndpoints(_ service: any RuneScribeApplicationService) async throws {
                    retainedProviderRegistrationRegression.append(service)
            """
        )
        try assertOverlayFilesReportOnly(
            ruleID: "FG-004",
            evidencePath: relative,
            files: [(relative, mutated)],
            label: "canonical-provider-registration-retention"
        )
    }

    func testGenericAndCollectionProviderWrappersReportOnlyFG004() throws {
        let fixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/GenericProviderBoxRegression.swift",
                """
                import RuneScribeContracts

                public struct GenericProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value

                    public init(value: Value) {
                        self.value = value
                    }
                }

                private let genericProviderBoxSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let genericProviderBoxLeakRegression =
                    GenericProviderBoxRegression(value: genericProviderBoxSourceRegression)
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderCollectionRegression.swift",
                """
                import RuneScribeContracts

                private let providerCollectionSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerCollectionLeakRegression =
                    [providerCollectionSourceRegression]
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderDictionaryRegression.swift",
                """
                import RuneScribeContracts

                private let providerDictionarySourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerDictionaryLeakRegression =
                    ["provider": providerDictionarySourceRegression]
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderTupleRegression.swift",
                """
                import RuneScribeContracts

                private let providerTupleSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerTupleLeakRegression =
                    (providerTupleSourceRegression, "marker")
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderOptionalRegression.swift",
                """
                import RuneScribeContracts

                private let providerOptionalSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerOptionalLeakRegression =
                    Optional.some(providerOptionalSourceRegression)
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/OpaqueProviderBoxRegression.swift",
                """
                import RuneScribeContracts

                public struct OpaqueProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value

                    public init(value: Value) {
                        self.value = value
                    }
                }

                private let opaqueProviderBoxSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public func opaqueProviderBoxLeakRegression() -> some Sendable {
                    OpaqueProviderBoxRegression(value: opaqueProviderBoxSourceRegression)
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderParameterBoxRegression.swift",
                """
                import RuneScribeContracts

                public struct ProviderParameterBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                public func providerParameterBoxLeakRegression(
                    _ provider: any RuneScribeApplicationService
                ) -> some Sendable {
                    ProviderParameterBoxRegression(value: provider)
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ReturnedLocalProviderArrayRegression.swift",
                """
                import RuneScribeContracts

                private let returnedLocalArrayProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func returnedLocalProviderArrayLeakRegression() -> some Sendable {
                    let leaked = [returnedLocalArrayProviderRegression]
                    return leaked
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ReturnedLocalProviderBoxRegression.swift",
                """
                import RuneScribeContracts

                public struct ReturnedLocalProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let returnedLocalBoxProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func returnedLocalProviderBoxLeakRegression() -> some Sendable {
                    let leaked = ReturnedLocalProviderBoxRegression(
                        value: returnedLocalBoxProviderRegression
                    )
                    return leaked
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/StoredProviderAliasRegression.swift",
                """
                import RuneScribeContracts

                private let storedAliasProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private let storedProviderAliasRegression = [storedAliasProviderRegression]

                public func storedProviderAliasLeakRegression() -> some Sendable {
                    storedProviderAliasRegression
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderGetterAliasRegression.swift",
                """
                import RuneScribeContracts

                public struct ProviderGetterAliasRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let getterAliasProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private let getterProviderAliasRegression = ProviderGetterAliasRegression(
                    value: getterAliasProviderRegression
                )

                public var getterProviderAliasLeakRegression: some Sendable {
                    getterProviderAliasRegression
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderSubscriptAliasRegression.swift",
                """
                import RuneScribeContracts

                private let subscriptAliasProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private let subscriptProviderAliasRegression = [subscriptAliasProviderRegression]

                public struct ProviderSubscriptAliasRegression {
                    public subscript(index: Int) -> Any {
                        get { subscriptProviderAliasRegression }
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderYieldAliasRegression.swift",
                """
                import RuneScribeContracts

                private let yieldAliasProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private let yieldProviderAliasRegression = [yieldAliasProviderRegression]

                public struct ProviderYieldAliasRegression {
                    public subscript(index: Int) -> Any {
                        _read { yield yieldProviderAliasRegression }
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderDictionaryKeyRegression.swift",
                """
                import RuneScribeContracts

                private let providerDictionaryKeySourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerDictionaryKeyLeakRegression =
                    [providerDictionaryKeySourceRegression: "provider"]
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderConditionalResultRegression.swift",
                """
                import RuneScribeContracts

                public struct ProviderConditionalBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let conditionalProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func conditionalProviderLeakRegression(_ flag: Bool) -> some Sendable {
                    if flag {
                        return ProviderConditionalBoxRegression(value: conditionalProviderRegression)
                    }
                    return ProviderConditionalBoxRegression(value: "neutral")
                }

                public func switchProviderLeakRegression(_ value: Int) -> some Sendable {
                    switch value {
                    case 0:
                        return ProviderConditionalBoxRegression(value: conditionalProviderRegression)
                    default:
                        return ProviderConditionalBoxRegression(value: "neutral")
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ExplicitProviderBoxInitRegression.swift",
                """
                import RuneScribeContracts

                public struct ExplicitProviderBoxInitRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let explicitProviderBoxSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let explicitProviderBoxInitLeakRegression =
                    ExplicitProviderBoxInitRegression.init(value: explicitProviderBoxSourceRegression)
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/UnknownProviderIdentityRegression.swift",
                """
                import RuneScribeContracts

                private let unknownIdentityProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                private func unknownIdentityRegression<Value>(_ value: Value) -> Value { value }

                public func unknownProviderIdentityLeakRegression() -> some Sendable {
                    unknownIdentityRegression(unknownIdentityProviderRegression)
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/GlobalMutableProviderAliasRegression.swift",
                """
                import RuneScribeContracts

                public struct GlobalMutableProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let globalMutableProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private var globalMutableProviderAliasRegression =
                    GlobalMutableProviderBoxRegression(value: globalMutableProviderRegression)

                public func globalMutableProviderAliasLeakRegression() -> some Sendable {
                    globalMutableProviderAliasRegression
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/LocalMutableProviderAliasRegression.swift",
                """
                import RuneScribeContracts

                public struct LocalMutableProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value
                }

                private let localMutableProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func localMutableProviderAliasLeakRegression() -> some Sendable {
                    var hidden = LocalMutableProviderBoxRegression(
                        value: localMutableProviderRegression
                    )
                    return hidden
                }

                public func reassignedMutableProviderAliasLeakRegression() -> some Sendable {
                    var hidden = LocalMutableProviderBoxRegression(value: "clean")
                    hidden = LocalMutableProviderBoxRegression(
                        value: localMutableProviderRegression
                    )
                    return hidden
                }

                public func parenthesizedReassignedMutableProviderAliasLeakRegression()
                    -> some Sendable
                {
                    var hidden = LocalMutableProviderBoxRegression(value: "clean")
                    hidden = LocalMutableProviderBoxRegression(
                        value: localMutableProviderRegression
                    )
                    return (hidden)
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ImmediateProviderClosureRegression.swift",
                """
                import RuneScribeContracts

                private let immediateClosureProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func immediateProviderClosureLeakRegression() -> some Sendable {
                    ({ immediateClosureProviderRegression })()
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ReturnedProviderClosureRegression.swift",
                """
                import RuneScribeContracts

                private let returnedClosureProviderRegression:
                    any RuneScribeApplicationService = fatalError()

                public func returnedProviderClosureLeakRegression()
                    -> @Sendable () -> AnyObject
                {
                    { returnedClosureProviderRegression as AnyObject }
                }

                public func transformedReturnedProviderClosureLeakRegression()
                    -> @Sendable () -> String
                {
                    { String(describing: returnedClosureProviderRegression) }
                }

                public func capturedProviderClosureLeakRegression()
                    -> @Sendable () -> String
                {
                    { [returnedClosureProviderRegression] in "value" }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/NamedProviderClosureRegression.swift",
                """
                import RuneScribeContracts

                private let namedClosureProviderRegression:
                    any RuneScribeApplicationService = fatalError()
                private let storedProviderProducerRegression = {
                    namedClosureProviderRegression
                }

                public func storedNamedProviderClosureLeakRegression() -> some Sendable {
                    storedProviderProducerRegression()
                }

                public func localNamedProviderClosureLeakRegression() -> some Sendable {
                    let producer = { namedClosureProviderRegression }
                    return producer()
                }
                """
            )
        ]

        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses["FG-004"], "pass")

        for fixture in fixtures {
            let invocation = try invokeGuard { root in
                let destination = root.appendingPathComponent(fixture.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(fixture.contents.utf8).write(to: destination, options: .atomic)
            }
            XCTAssertEqual(invocation.status, 0, "\(fixture.path): \(invocation.standardError)")
            let rules = try reportRules(invocation.json)
            let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == "FG-004" })
            XCTAssertEqual(result["status"] as? String, "violation", fixture.path)
            let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
            XCTAssertTrue(
                evidence.contains { ($0["path"] as? String) == fixture.path },
                fixture.path
            )
            for rule in rules where (rule["id"] as? String) != "FG-004" {
                let id = try XCTUnwrap(rule["id"] as? String)
                XCTAssertEqual(
                    rule["status"] as? String,
                    baselineStatuses[id],
                    "\(fixture.path): \(id)"
                )
            }
        }

        let cleanPath = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/GenericProviderWrapperNoChangeRegression.swift"
        let clean = try invokeGuard { root in
            let destination = root.appendingPathComponent(cleanPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                import RuneScribeContracts

                public struct NeutralGenericProviderBoxRegression<Value: Sendable>: Sendable {
                    public let value: Value

                    public init(value: Value) {
                        self.value = value
                    }
                }

                private let neutralGenericProviderValueRegression = "value"
                public let neutralGenericProviderBoxRegression =
                    NeutralGenericProviderBoxRegression(value: neutralGenericProviderValueRegression)

                private let providerDescriptionWrapperSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public let providerDescriptionWrapperPropertyRegression =
                    String(describing: providerDescriptionWrapperSourceRegression)

                public func providerDescriptionWrapperFunctionRegression() -> some Sendable {
                    String(describing: providerDescriptionWrapperSourceRegression)
                }

                public let neutralProviderArrayRegression = [
                    String(describing: providerDescriptionWrapperSourceRegression)
                ]
                public let neutralProviderDictionaryRegression = [
                    "provider": String(describing: providerDescriptionWrapperSourceRegression)
                ]
                public let neutralProviderTupleRegression = (
                    String(describing: providerDescriptionWrapperSourceRegression),
                    "marker"
                )
                public let neutralProviderOptionalRegression = Optional.some(
                    String(describing: providerDescriptionWrapperSourceRegression)
                )
                public let neutralTransformedProviderBoxRegression =
                    NeutralGenericProviderBoxRegression(
                        value: String(describing: providerDescriptionWrapperSourceRegression)
                    )

                public func unrelatedLocalProviderWrapperRegression() -> String {
                    let ignored = NeutralGenericProviderBoxRegression(
                        value: providerDescriptionWrapperSourceRegression
                    )
                    _ = ignored
                    return "value"
                }

                public func nearestNeutralProviderShadowRegression() -> some Sendable {
                    let providerDescriptionWrapperSourceRegression = "shadow"
                    return NeutralGenericProviderBoxRegression(
                        value: providerDescriptionWrapperSourceRegression
                    )
                }

                public func transformedReturnedProviderAliasRegression() -> some Sendable {
                    let transformed = String(
                        describing: providerDescriptionWrapperSourceRegression
                    )
                    return NeutralGenericProviderBoxRegression(value: transformed)
                }

                public func transformedImmediateClosureRegression() -> some Sendable {
                    ({ String(describing: providerDescriptionWrapperSourceRegression) })()
                }

                private let transformedReturnedClosureDescriptionRegression =
                    String(describing: providerDescriptionWrapperSourceRegression)
                private let transformedNamedClosureRegression = {
                    transformedReturnedClosureDescriptionRegression
                }

                public func transformedReturnedClosureRegression()
                    -> @Sendable () -> String
                {
                    { transformedReturnedClosureDescriptionRegression }
                }

                public func transformedNamedClosureInvocationRegression() -> some Sendable {
                    transformedNamedClosureRegression()
                }
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(clean.status, 0, clean.standardError)
        for rule in try reportRules(clean.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testProviderSemanticNoChangeControlsRemainClean() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: try reportRules(baseline.json).compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderSemanticNoChangeRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                import RuneScribeContracts
                import RuneScribeRuntimeCore

                private struct ModuleContext {}

                private final class QualifiedCanonicalContextProviderRegression:
                    RuneScribeApplicationService
                {
                    func register(
                        through context: RuneScribeRuntimeCore.ModuleContext
                    ) async throws {
                        try await context.registerApplicationEndpoints(self)
                    }

                    public func echo<Candidate>(_ value: Candidate) -> Candidate {
                        _ = self
                        return value
                    }
                }

                private let providerDescriptionSourceRegression:
                    any RuneScribeApplicationService = fatalError()

                public func providerDescriptionRegression() -> String {
                    String(describing: providerDescriptionSourceRegression)
                }

                public struct NeutralProviderDTORegression {
                    public let value: String
                }

                private let neutralProviderDTOValueRegression = "value"
                public let neutralProviderDTORegression =
                    NeutralProviderDTORegression(value: neutralProviderDTOValueRegression)
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        for rule in try reportRules(invocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }
    }

    func testExtensionConformanceProviderPublicationReportsOnlyFG004() throws {
        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ExtensionProviderPublicationRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-004",
            relativePath: relative,
            contents: """
            import RuneScribeContracts

            public final class ExtensionProviderPublicationRegression {}

            extension ExtensionProviderPublicationRegression:
                RuneScribeApplicationService
            {}

            public enum ExtensionProviderPublicationSurfaceRegression {
                public static let live: ExtensionProviderPublicationRegression =
                    fatalError()
            }
            """
        )
    }

    func testProviderPublicationLexicalAndMultilineRegressions() throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        let lexicalInvocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/ProviderPublicationLexicalRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                private let providerPublicationDocumentation = "publishService(self)"
                // publishService(self) is documentation, not executable Swift.
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(lexicalInvocation.status, 0, lexicalInvocation.standardError)
        for rule in try reportRules(lexicalInvocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }

        let harmlessCoreInvocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/HarmlessCoreValueFlowRegression.swift"
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                private final class HarmlessCoreValueFlowRegression {
                    private func helper(_ value: HarmlessCoreValueFlowRegression) {}

                    func exercise() {
                        helper(self)
                    }
                }

                private protocol HarmlessActorParameterRegression: Actor {}
                private func inspectHarmlessActorRegression(
                    _ value: any HarmlessActorParameterRegression
                ) {}
                """.utf8
            ).write(to: destination, options: .atomic)
        }
        XCTAssertEqual(harmlessCoreInvocation.status, 0, harmlessCoreInvocation.standardError)
        for rule in try reportRules(harmlessCoreInvocation.json) {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], id)
        }

        let relative = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/MultilineProviderPublicationRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-004",
            relativePath: relative,
            contents: """
            import RuneScribeRuntimeCore

            private struct MultilineProviderPublicationRegression {
                func publish(through context: ModuleContext) async throws {
                    try await context.publishService(
                        self
                    )
                }
            }
            """
        )
        let rawStorageRelative = "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/RawGenericProviderStorageRegression.swift"
        try assertMutationReportsOnly(
            ruleID: "FG-004",
            relativePath: rawStorageRelative,
            contents: """
            private struct RawGenericProviderStorageRegression {
                private var storage: [String: Any] = [:]

                mutating func put<Value: Sendable>(
                    _ value: Value,
                    id: String
                ) {
                    storage[id] = value
                }
            }
            """
        )
        let collectionMutationFixtures: [(path: String, contents: String)] = [
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/RawUpdateValueStorageRegression.swift",
                """
                private struct RawUpdateValueStorageRegression {
                    private var storage: [String: Any] = [:]

                    mutating func retain<Value: Sendable>(_ value: Value) {
                        storage.updateValue(value, forKey: "provider")
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/RawAppendStorageRegression.swift",
                """
                private struct RawAppendStorageRegression {
                    private var storage: [Any] = []

                    mutating func retain<Value: Sendable>(_ value: Value) {
                        storage.append(value)
                    }
                }
                """
            ),
            (
                "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/InferredRawStorageRegression.swift",
                """
                private struct InferredRawStorageRegression {
                    private var storage = [String: Any]()

                    mutating func retain<Value: Sendable>(_ value: Value) {
                        storage["provider"] = value
                    }
                }
                """
            )
        ]
        for fixture in collectionMutationFixtures {
            try assertMutationReportsOnly(
                ruleID: "FG-004",
                relativePath: fixture.path,
                contents: fixture.contents
            )
        }
    }

    func testIndexedHistoricalDocumentCannotAcquireCurrentContradiction() throws {
        let relative = "docs/architecture/ForsettiCompliance.md"
        let original = try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
        let invocation = try invokeGuard { root in
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((original + "\nA future external Forsetti dependency is permitted.\n").utf8).write(to: file, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == "FG-020" })
        XCTAssertEqual(result["status"] as? String, "violation")
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
        XCTAssertTrue(evidence.contains { ($0["path"] as? String) == relative })
    }

    func testControllingPolicyHashDriftCannotPass() throws {
        let relative = "docs/architecture/FORSETTI_CONTROLLING_POLICY.md"
        let original = try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
        let invocation = try invokeGuard { root in
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((original + "\nHash drift fixture.\n").utf8).write(to: file, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == "FG-020" })
        XCTAssertEqual(result["status"] as? String, "violation")
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]])
        XCTAssertTrue(evidence.contains { ($0["detail"] as? String)?.contains("policy hash drifted") == true })
    }

    private func assertMutationReportsOnly(
        ruleID: String,
        relativePath: String,
        contents: String
    ) throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, baseline.standardError)
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses[ruleID], "pass", ruleID)

        let invocation = try invokeGuard { root in
            let destination = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: destination, options: .atomic)
        }

        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(rules.first { ($0["id"] as? String) == ruleID })
        XCTAssertEqual(result["status"] as? String, "violation", ruleID)
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], ruleID)
        XCTAssertTrue(
            evidence.contains { ($0["path"] as? String) == relativePath },
            ruleID
        )

        for rule in rules where (rule["id"] as? String) != ruleID {
            let id = try XCTUnwrap(rule["id"] as? String, ruleID)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], "\(ruleID): \(id)")
        }
    }

    private func assertOverlayFilesReportOnly(
        ruleID: String,
        evidencePath: String,
        files: [(path: String, contents: String)],
        label: String
    ) throws {
        let baseline = try invokeGuard()
        XCTAssertEqual(baseline.status, 0, "\(label): \(baseline.standardError)")
        let baselineRules = try reportRules(baseline.json)
        let baselineStatuses = Dictionary(
            uniqueKeysWithValues: baselineRules.compactMap { rule -> (String, String)? in
                guard let id = rule["id"] as? String, let status = rule["status"] as? String else {
                    return nil
                }
                return (id, status)
            }
        )
        XCTAssertEqual(baselineStatuses[ruleID], "pass", label)

        let invocation = try invokeGuard { root in
            for file in files {
                let destination = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.contents.utf8).write(to: destination, options: .atomic)
            }
        }

        XCTAssertEqual(invocation.status, 0, "\(label): \(invocation.standardError)")
        let rules = try reportRules(invocation.json)
        let result = try XCTUnwrap(
            rules.first { ($0["id"] as? String) == ruleID },
            label
        )
        XCTAssertEqual(result["status"] as? String, "violation", label)
        let evidence = try XCTUnwrap(result["evidence"] as? [[String: Any]], label)
        XCTAssertTrue(evidence.contains { ($0["path"] as? String) == evidencePath }, label)

        for rule in rules where (rule["id"] as? String) != ruleID {
            let id = try XCTUnwrap(rule["id"] as? String, label)
            XCTAssertEqual(rule["status"] as? String, baselineStatuses[id], "\(label): \(id)")
        }
    }

    private func assertSourceReplacementReportsOnly(
        ruleID: String,
        relativePath: String,
        anchor: String,
        replacement: String,
        label: String
    ) throws {
        let source = try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        let ranges = source.ranges(of: anchor)
        XCTAssertEqual(ranges.count, 1, "\(label): expected one stable source anchor")
        let range = try XCTUnwrap(ranges.first, "\(label): source anchor is missing")
        let mutated = source.replacingCharacters(in: range, with: replacement)
        try assertOverlayFilesReportOnly(
            ruleID: ruleID,
            evidencePath: relativePath,
            files: [(relativePath, mutated)],
            label: label
        )
    }

    private func invokeGuard(
        fixture: ((URL) throws -> Void)? = nil
    ) throws -> Invocation {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeComplianceGuardTests-\(UUID().uuidString)", isDirectory: true)
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        let fixtureRoot = workspace.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var arguments = [
            repository.appendingPathComponent("scripts/check-forsetti-compliance.sh").path,
            "--scan-root", repository.path,
            "--output", output.path
        ]
        if let fixture {
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try fixture(fixtureRoot)
            arguments.append(contentsOf: ["--fixture-root", fixtureRoot.path])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        let standardOutputURL = workspace.appendingPathComponent("stdout.log")
        let standardErrorURL = workspace.appendingPathComponent("stderr.log")
        _ = FileManager.default.createFile(
            atPath: standardOutputURL.path,
            contents: nil
        )
        _ = FileManager.default.createFile(
            atPath: standardErrorURL.path,
            contents: nil
        )
        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        try standardOutput.close()
        try standardError.close()

        let outputText = String(
            decoding: try Data(contentsOf: standardOutputURL),
            as: UTF8.self
        )
        let errorText = String(
            decoding: try Data(contentsOf: standardErrorURL),
            as: UTF8.self
        )
        let jsonURL = output.appendingPathComponent("forsetti-compliance-report.json")
        let markdownURL = output.appendingPathComponent("forsetti-compliance-report.md")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              FileManager.default.fileExists(atPath: markdownURL.path) else {
            throw NSError(
                domain: "ComplianceGuardTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "guard produced no report (exit \(process.terminationStatus)); stdout=\(outputText); stderr=\(errorText)"
                ]
            )
        }

        return Invocation(
            status: process.terminationStatus,
            standardOutput: outputText,
            standardError: errorText,
            json: try Data(contentsOf: jsonURL),
            markdown: try Data(contentsOf: markdownURL)
        )
    }

    private func decodeReport(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reportRules(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try decodeReport(data)["rules"] as? [[String: Any]])
    }
}

private extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: substring, range: searchStart..<endIndex)
        {
            matches.append(range)
            searchStart = range.upperBound
        }
        return matches
    }
}

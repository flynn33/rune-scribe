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

        for id in ["FG-004", "FG-006"] {
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
                    func registerRawMutationService(_ service: any RawActorMutationService) {}
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
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let outputText = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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

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

        for rule in rules {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["findingIDs"] as? [String], expectedMappings[id], id)
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

    func testCurrentP01StatusesHaveConcreteEvidenceAnchors() throws {
        let invocation = try invokeGuard()
        XCTAssertEqual(invocation.status, 0, invocation.standardError)
        let rules = try reportRules(invocation.json)

        let passIDs: Set<String> = ["FG-001", "FG-002", "FG-003", "FG-020"]
        let violationIDs = Set((4...18).map { String(format: "FG-%03d", $0) })

        for rule in rules {
            let id = try XCTUnwrap(rule["id"] as? String)
            XCTAssertEqual(rule["matchesP01Baseline"] as? Bool, true, id)
            if passIDs.contains(id) {
                XCTAssertEqual(rule["status"] as? String, "pass", id)
                XCTAssertEqual(rule["evidenceKind"] as? String, "detector-proof", id)
            } else if violationIDs.contains(id) {
                XCTAssertEqual(rule["status"] as? String, "violation", id)
            } else {
                XCTAssertEqual(id, "FG-019")
                XCTAssertEqual(rule["status"] as? String, "pending-enforcement", id)
            }

            let evidence = try XCTUnwrap(rule["evidence"] as? [[String: Any]], id)
            XCTAssertFalse(evidence.isEmpty, id)
            for anchor in evidence {
                XCTAssertFalse(try XCTUnwrap(anchor["path"] as? String).isEmpty, id)
                XCTAssertGreaterThan(try XCTUnwrap(anchor["line"] as? Int), 0, id)
            }
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

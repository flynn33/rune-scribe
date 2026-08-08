import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class ManifestValidationTests: XCTestCase {
    func testSemanticVersionIsStrictAndComparable() throws {
        let minimum = try SemanticVersion("1.0.0")
        let current = try SemanticVersion("1.2.3")

        XCTAssertLessThan(minimum, current)
        XCTAssertTrue(
            SemanticVersionRange(minimumInclusive: minimum).contains(current)
        )
        XCTAssertThrowsError(try SemanticVersion("1.2"))
        XCTAssertThrowsError(try SemanticVersion("1.02.3-beta"))
    }

    func testDecoderAcceptsStrictManifest() throws {
        let manifest = try ModuleManifestDecoder.decode(try validManifestData())

        XCTAssertEqual(manifest.moduleID, "com.runescribe.module.test")
        XCTAssertEqual(manifest.moduleVersion, try SemanticVersion("1.0.33"))
        XCTAssertFalse(manifest.diagnosticsVisibleInProduction)
    }

    func testDecoderRejectsUnknownRootAndNestedFields() throws {
        var root = try validManifestObject()
        root["unexpected"] = true
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .unknownField(path: "$", field: "unexpected")
            )
        }

        root = try validManifestObject()
        var requirements = try XCTUnwrap(root["runtimeRequirements"] as? [String: Any])
        requirements["unexpected"] = true
        root["runtimeRequirements"] = requirements
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .unknownField(path: "$.runtimeRequirements", field: "unexpected")
            )
        }
    }

    func testDecoderRejectsMissingDuplicateAndProductionDiagnostics() throws {
        var root = try validManifestObject()
        root.removeValue(forKey: "entryPoint")
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .missingField(path: "$", field: "entryPoint")
            )
        }

        root = try validManifestObject()
        root["capabilitiesRequested"] = [
            "runtime.events.publish",
            "runtime.events.publish",
        ]
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .duplicateValue(
                    path: "$.capabilitiesRequested",
                    value: "runtime.events.publish"
                )
            )
        }

        root = try validManifestObject()
        root["diagnosticsVisibleInProduction"] = true
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root)))
    }

    func testDecoderRejectsInvalidMinimumOSAndRole() throws {
        var root = try validManifestObject()
        root["minimumOS"] = ["macOS": "fifteen"]
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root)))

        root = try validManifestObject()
        root["defaultRole"] = "Invalid Role"
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root)))
    }
}

private func validManifestData() throws -> Data {
    try data(try validManifestObject())
}

private func validManifestObject() throws -> [String: Any] {
    [
        "schemaVersion": "1.0",
        "policyProfile": "forsetti-pattern-b-standalone",
        "runtimeVersion": "1.0.0",
        "moduleID": "com.runescribe.module.test",
        "displayName": "Test Module",
        "moduleVersion": "1.0.33",
        "moduleType": "service",
        "supportedPlatforms": ["macOS"],
        "minimumOS": ["macOS": "15.0"],
        "capabilitiesRequested": ["runtime.events.publish"],
        "entryPoint": "TestModule",
        "runtimeRequirements": [
            "requiredServices": [],
            "requiredModuleRoles": [],
        ],
        "defaultRole": "runescribe.test",
        "entitlementRequirement": NSNull(),
        "diagnosticsVisibleInProduction": false,
    ]
}

private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

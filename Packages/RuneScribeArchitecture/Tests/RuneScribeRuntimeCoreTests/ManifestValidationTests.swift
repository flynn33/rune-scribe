import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class ManifestValidationTests: XCTestCase {
    func testSemanticVersionIsStrictAndComparable() throws {
        let minimum = try SemanticVersion("1.0.0")
        let current = try SemanticVersion("1.2.3")

        XCTAssertLessThan(minimum, current)
        XCTAssertThrowsError(try SemanticVersion("1.2"))
        XCTAssertThrowsError(try SemanticVersion("1.02.3-beta"))
    }

    func testManifestRuntimeRequirementAcceptsCurrentAndRejectsOlderRuntime() throws {
        let manifest = try ModuleManifestDecoder.decode(try validManifestData())
        let descriptor = ModuleDescriptor(
            moduleID: manifest.moduleID,
            moduleVersion: manifest.moduleVersion,
            kind: manifest.moduleType,
            criticality: manifest.criticality,
            entryPoint: manifest.entryPoint,
            role: manifest.defaultRole,
            requestedCapabilities: Set(manifest.capabilitiesRequested),
            consumedEndpoints: Set(manifest.consumedEndpoints),
            publishedEndpoints: Set(manifest.publishedEndpoints)
        )
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(
                knownCapabilities: Set(manifest.capabilitiesRequested)
            ),
            capabilities: CapabilityPolicy(
                allowedRolesByCapability: Dictionary(
                    uniqueKeysWithValues: manifest.capabilitiesRequested.map {
                        ($0, Set([manifest.defaultRole]))
                    }
                )
            ),
            services: ServiceAccessPolicy(rules: [])
        )

        XCTAssertNoThrow(
            try ModuleManifestValidator.validate(
                manifest: manifest,
                descriptor: descriptor,
                runtimeVersion: manifest.runtimeVersion,
                platform: .macOS,
                policy: policy
            )
        )

        let olderRuntime = try SemanticVersion("0.9.9")
        XCTAssertThrowsError(
            try ModuleManifestValidator.validate(
                manifest: manifest,
                descriptor: descriptor,
                runtimeVersion: olderRuntime,
                platform: .macOS,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .incompatibleRuntime(
                    moduleID: manifest.moduleID,
                    minimum: manifest.runtimeVersion,
                    actual: olderRuntime
                )
            )
        }
    }

    func testDecoderAcceptsStrictManifest() throws {
        let manifest = try ModuleManifestDecoder.decode(try validManifestData())

        XCTAssertEqual(manifest.moduleID, "com.runescribe.module.test")
        XCTAssertEqual(manifest.moduleVersion, try SemanticVersion("1.0.34"))
        XCTAssertEqual(manifest.criticality, .optional)
        XCTAssertEqual(manifest.consumedEndpoints, ["test.input"])
        XCTAssertEqual(manifest.publishedEndpoints, ["test.output"])
        XCTAssertNil(manifest.policyClass)
        XCTAssertEqual(
            manifest.effectivePolicyClass,
            ModulePolicyClass(role: manifest.defaultRole)
        )
        XCTAssertFalse(manifest.diagnosticsVisibleInProduction)
    }

    func testExplicitPolicyClassIsStrictAndMustMatchDescriptor() throws {
        var root = try validManifestObject()
        root["policyClass"] = RuneScribePolicyClasses.themeProvider.rawValue
        let manifest = try ModuleManifestDecoder.decode(try data(root))
        XCTAssertEqual(manifest.policyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(
            manifest.effectivePolicyClass,
            RuneScribePolicyClasses.themeProvider
        )

        let descriptor = ModuleDescriptor(
            moduleID: manifest.moduleID,
            moduleVersion: manifest.moduleVersion,
            kind: manifest.moduleType,
            criticality: manifest.criticality,
            entryPoint: manifest.entryPoint,
            role: manifest.defaultRole,
            policyClass: RuneScribePolicyClasses.themeProvider,
            requestedCapabilities: Set(manifest.capabilitiesRequested),
            consumedEndpoints: Set(manifest.consumedEndpoints),
            publishedEndpoints: Set(manifest.publishedEndpoints)
        )
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(
                knownCapabilities: Set(manifest.capabilitiesRequested)
            ),
            capabilities: CapabilityPolicy(
                allowedPolicyClassesByCapability: Dictionary(
                    uniqueKeysWithValues: manifest.capabilitiesRequested.map {
                        ($0, Set([RuneScribePolicyClasses.themeProvider]))
                    }
                )
            ),
            services: ServiceAccessPolicy(rules: [])
        )
        XCTAssertNoThrow(
            try ModuleManifestValidator.validate(
                manifest: manifest,
                descriptor: descriptor,
                runtimeVersion: manifest.runtimeVersion,
                platform: .macOS,
                policy: policy
            )
        )

        let mismatchedDescriptor = ModuleDescriptor(
            moduleID: descriptor.moduleID,
            moduleVersion: descriptor.moduleVersion,
            kind: descriptor.kind,
            criticality: descriptor.criticality,
            entryPoint: descriptor.entryPoint,
            role: descriptor.role,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            requestedCapabilities: descriptor.requestedCapabilities,
            consumedEndpoints: descriptor.consumedEndpoints,
            publishedEndpoints: descriptor.publishedEndpoints
        )
        XCTAssertThrowsError(
            try ModuleManifestValidator.validate(
                manifest: manifest,
                descriptor: mismatchedDescriptor,
                runtimeVersion: manifest.runtimeVersion,
                platform: .macOS,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .manifestDescriptorMismatch(
                    moduleID: manifest.moduleID,
                    field: "policyClass"
                )
            )
        }

        root["policyClass"] = "Invalid Policy Class"
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .invalidField(path: "$.policyClass", reason: "Invalid identifier.")
            )
        }
    }

    func testDecoderAcceptsOwnedResourceAndRejectsUnknownResourceField() throws {
        var root = try validManifestObject()
        var requirements = try XCTUnwrap(root["runtimeRequirements"] as? [String: Any])
        requirements["requiredResources"] = [[
            "name": "progression-catalog",
            "fileExtension": "json",
            "subdirectory": "Progression",
            "ownerModuleID": "com.runescribe.module.progression",
        ]]
        root["runtimeRequirements"] = requirements

        let manifest = try ModuleManifestDecoder.decode(try data(root))
        XCTAssertEqual(
            manifest.runtimeRequirements.requiredResources,
            [
                ApplicationResource(
                    name: "progression-catalog",
                    fileExtension: "json",
                    subdirectory: "Progression",
                    ownerModuleID: "com.runescribe.module.progression"
                ),
            ]
        )

        requirements["requiredResources"] = [[
            "name": "progression-catalog",
            "fileExtension": "json",
            "ownerModuleID": "com.runescribe.module.progression",
            "unexpected": true,
        ]]
        root["runtimeRequirements"] = requirements
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .unknownField(
                    path: "$.runtimeRequirements.requiredResources[0]",
                    field: "unexpected"
                )
            )
        }
    }

    func testDecoderRequiresCriticalityAndExactEndpointDeclarations() throws {
        for field in ["criticality", "consumedEndpoints", "publishedEndpoints"] {
            var root = try validManifestObject()
            root.removeValue(forKey: field)

            XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
                XCTAssertEqual(
                    error as? ManifestDecodingError,
                    .missingField(path: "$", field: field)
                )
            }
        }

        var root = try validManifestObject()
        root["publishedEndpoints"] = ["test.output", "test.output"]
        XCTAssertThrowsError(try ModuleManifestDecoder.decode(try data(root))) { error in
            XCTAssertEqual(
                error as? ManifestDecodingError,
                .duplicateValue(path: "$.publishedEndpoints", value: "test.output")
            )
        }
    }

    func testValidatorRejectsCriticalityAndEndpointMismatches() throws {
        let manifest = try ModuleManifestDecoder.decode(try validManifestData())
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(
                knownCapabilities: Set(manifest.capabilitiesRequested)
            ),
            capabilities: CapabilityPolicy(
                allowedRolesByCapability: Dictionary(
                    uniqueKeysWithValues: manifest.capabilitiesRequested.map {
                        ($0, Set([manifest.defaultRole]))
                    }
                )
            ),
            services: ServiceAccessPolicy(rules: [])
        )
        let mismatched = ModuleDescriptor(
            moduleID: manifest.moduleID,
            moduleVersion: manifest.moduleVersion,
            kind: manifest.moduleType,
            criticality: .required,
            entryPoint: manifest.entryPoint,
            role: manifest.defaultRole,
            requestedCapabilities: Set(manifest.capabilitiesRequested),
            consumedEndpoints: Set(manifest.consumedEndpoints),
            publishedEndpoints: Set(manifest.publishedEndpoints)
        )

        XCTAssertThrowsError(
            try ModuleManifestValidator.validate(
                manifest: manifest,
                descriptor: mismatched,
                runtimeVersion: manifest.runtimeVersion,
                platform: .macOS,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .manifestDescriptorMismatch(
                    moduleID: manifest.moduleID,
                    field: "criticality"
                )
            )
        }
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
        "moduleVersion": "1.0.34",
        "moduleType": "service",
        "criticality": "optional",
        "supportedPlatforms": ["macOS"],
        "minimumOS": ["macOS": "15.0"],
        "capabilitiesRequested": ["runtime.events.publish"],
        "entryPoint": "TestModule",
        "runtimeRequirements": [
            "requiredServices": [],
            "requiredModuleRoles": [],
        ],
        "defaultRole": "runescribe.test",
        "consumedEndpoints": ["test.input"],
        "publishedEndpoints": ["test.output"],
        "entitlementRequirement": NSNull(),
        "diagnosticsVisibleInProduction": false,
    ]
}

private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

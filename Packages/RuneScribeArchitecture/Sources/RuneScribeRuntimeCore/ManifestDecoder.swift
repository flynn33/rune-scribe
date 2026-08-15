import Foundation
import RuneScribeContracts

public enum ManifestDecodingError: Error, Equatable, Sendable {
    case invalidRoot
    case unknownField(path: String, field: String)
    case missingField(path: String, field: String)
    case invalidField(path: String, reason: String)
    case duplicateValue(path: String, value: String)
    case decodingFailure
}

public enum ModuleManifestDecoder {
    private static let rootFields: Set<String> = [
        "schemaVersion",
        "policyProfile",
        "runtimeVersion",
        "moduleID",
        "displayName",
        "moduleVersion",
        "moduleType",
        "criticality",
        "supportedPlatforms",
        "minimumOS",
        "capabilitiesRequested",
        "entryPoint",
        "runtimeRequirements",
        "defaultRole",
        "consumedEndpoints",
        "publishedEndpoints",
        "entitlementRequirement",
        "diagnosticsVisibleInProduction",
    ]

    private static let requiredRootFields: Set<String> = [
        "schemaVersion",
        "policyProfile",
        "runtimeVersion",
        "moduleID",
        "displayName",
        "moduleVersion",
        "moduleType",
        "criticality",
        "supportedPlatforms",
        "capabilitiesRequested",
        "entryPoint",
        "runtimeRequirements",
        "defaultRole",
        "consumedEndpoints",
        "publishedEndpoints",
        "diagnosticsVisibleInProduction",
    ]

    public static func decode(_ data: Data) throws -> ModuleManifest {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManifestDecodingError.invalidRoot
        }

        guard let root = json as? [String: Any] else {
            throw ManifestDecodingError.invalidRoot
        }

        try checkFields(
            root,
            allowed: rootFields,
            required: requiredRootFields,
            path: "$"
        )
        try checkNestedObjects(root)

        let manifest: ModuleManifest
        do {
            manifest = try JSONDecoder().decode(ModuleManifest.self, from: data)
        } catch {
            throw ManifestDecodingError.decodingFailure
        }

        try validateStructure(manifest)
        return manifest
    }

    private static func checkNestedObjects(_ root: [String: Any]) throws {
        guard let requirements = root["runtimeRequirements"] as? [String: Any] else {
            throw ManifestDecodingError.invalidField(
                path: "$.runtimeRequirements",
                reason: "Expected object."
            )
        }
        try checkFields(
            requirements,
            allowed: ["requiredServices", "requiredResources", "requiredModuleRoles"],
            required: ["requiredServices", "requiredModuleRoles"],
            path: "$.runtimeRequirements"
        )
        if let resources = requirements["requiredResources"] {
            guard let values = resources as? [[String: Any]] else {
                throw ManifestDecodingError.invalidField(
                    path: "$.runtimeRequirements.requiredResources",
                    reason: "Expected an array of resource objects."
                )
            }
            for (index, value) in values.enumerated() {
                try checkFields(
                    value,
                    allowed: ["name", "fileExtension", "subdirectory", "ownerModuleID"],
                    required: ["name", "fileExtension"],
                    path: "$.runtimeRequirements.requiredResources[\(index)]"
                )
            }
        }

        if let minimumOS = root["minimumOS"] {
            guard !(minimumOS is NSNull), let object = minimumOS as? [String: Any] else {
                throw ManifestDecodingError.invalidField(
                    path: "$.minimumOS",
                    reason: "Expected object."
                )
            }
            try checkFields(
                object,
                allowed: ["iOS", "macOS"],
                required: [],
                path: "$.minimumOS"
            )
        }

        if let entitlement = root["entitlementRequirement"], !(entitlement is NSNull) {
            guard let object = entitlement as? [String: Any] else {
                throw ManifestDecodingError.invalidField(
                    path: "$.entitlementRequirement",
                    reason: "Expected object or null."
                )
            }
            try checkFields(
                object,
                allowed: ["kind", "identifier"],
                required: ["kind", "identifier"],
                path: "$.entitlementRequirement"
            )
        }
    }

    private static func checkFields(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        path: String
    ) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw ManifestDecodingError.unknownField(path: path, field: unknown)
        }
        if let missing = required.subtracting(Set(object.keys)).sorted().first {
            throw ManifestDecodingError.missingField(path: path, field: missing)
        }
    }

    private static func validateStructure(_ manifest: ModuleManifest) throws {
        guard manifest.schemaVersion == ModuleManifest.currentSchemaVersion else {
            throw ManifestDecodingError.invalidField(
                path: "$.schemaVersion",
                reason: "Unsupported schema version."
            )
        }
        guard manifest.policyProfile == ModuleManifest.currentPolicyProfile else {
            throw ManifestDecodingError.invalidField(
                path: "$.policyProfile",
                reason: "Unsupported policy profile."
            )
        }
        guard (1...80).contains(manifest.displayName.count) else {
            throw ManifestDecodingError.invalidField(
                path: "$.displayName",
                reason: "Expected 1 through 80 characters."
            )
        }
        try requireMatch(
            manifest.moduleID.rawValue,
            pattern: #"^com\.runescribe\.module\.[a-z0-9.-]+$"#,
            path: "$.moduleID"
        )
        try requireMatch(
            manifest.entryPoint,
            pattern: #"^[A-Za-z_][A-Za-z0-9_]+$"#,
            path: "$.entryPoint"
        )
        try requireMatch(
            manifest.defaultRole.rawValue,
            pattern: #"^[a-z][a-z0-9._-]+$"#,
            path: "$.defaultRole"
        )
        guard !manifest.supportedPlatforms.isEmpty else {
            throw ManifestDecodingError.invalidField(
                path: "$.supportedPlatforms",
                reason: "At least one platform is required."
            )
        }
        try requireUnique(manifest.supportedPlatforms.map(\.rawValue), path: "$.supportedPlatforms")
        try requireUnique(manifest.capabilitiesRequested.map(\.rawValue), path: "$.capabilitiesRequested")
        try requireUnique(
            manifest.runtimeRequirements.requiredServices.map(\.rawValue),
            path: "$.runtimeRequirements.requiredServices"
        )
        try requireUnique(
            manifest.runtimeRequirements.requiredResources.map {
                [
                    $0.ownerModuleID?.rawValue ?? "",
                    $0.subdirectory ?? "",
                    $0.name,
                    $0.fileExtension,
                ].joined(separator: "/")
            },
            path: "$.runtimeRequirements.requiredResources"
        )
        try requireUnique(
            manifest.runtimeRequirements.requiredModuleRoles.map(\.rawValue),
            path: "$.runtimeRequirements.requiredModuleRoles"
        )
        try requireUnique(
            manifest.consumedEndpoints.map(\.rawValue),
            path: "$.consumedEndpoints"
        )
        try requireUnique(
            manifest.publishedEndpoints.map(\.rawValue),
            path: "$.publishedEndpoints"
        )
        for role in manifest.runtimeRequirements.requiredModuleRoles {
            try requireMatch(
                role.rawValue,
                pattern: #"^[a-z][a-z0-9._-]+$"#,
                path: "$.runtimeRequirements.requiredModuleRoles"
            )
        }
        if let minimumOS = manifest.minimumOS {
            if let iOS = minimumOS.iOS {
                try requireMatch(
                    iOS,
                    pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                    path: "$.minimumOS.iOS"
                )
            }
            if let macOS = minimumOS.macOS {
                try requireMatch(
                    macOS,
                    pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                    path: "$.minimumOS.macOS"
                )
            }
        }
        for capability in manifest.capabilitiesRequested {
            try requireMatch(
                capability.rawValue,
                pattern: #"^[a-z][a-z0-9._-]+$"#,
                path: "$.capabilitiesRequested"
            )
        }
        for endpoint in manifest.consumedEndpoints {
            try requireMatch(
                endpoint.rawValue,
                pattern: #"^[a-z][a-z0-9._-]+$"#,
                path: "$.consumedEndpoints"
            )
        }
        for endpoint in manifest.publishedEndpoints {
            try requireMatch(
                endpoint.rawValue,
                pattern: #"^[a-z][a-z0-9._-]+$"#,
                path: "$.publishedEndpoints"
            )
        }
        for service in manifest.runtimeRequirements.requiredServices {
            try requireMatch(
                service.rawValue,
                pattern: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#,
                path: "$.runtimeRequirements.requiredServices"
            )
        }
        for resource in manifest.runtimeRequirements.requiredResources {
            try requireMatch(
                resource.name,
                pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                path: "$.runtimeRequirements.requiredResources.name"
            )
            try requireMatch(
                resource.fileExtension,
                pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#,
                path: "$.runtimeRequirements.requiredResources.fileExtension"
            )
            if let subdirectory = resource.subdirectory {
                try requireMatch(
                    subdirectory,
                    pattern: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#,
                    path: "$.runtimeRequirements.requiredResources.subdirectory"
                )
                guard !subdirectory.split(separator: "/").contains("..") else {
                    throw ManifestDecodingError.invalidField(
                        path: "$.runtimeRequirements.requiredResources.subdirectory",
                        reason: "Parent traversal is not allowed."
                    )
                }
            }
            if let ownerModuleID = resource.ownerModuleID {
                try requireMatch(
                    ownerModuleID.rawValue,
                    pattern: #"^com\.runescribe\.module\.[a-z0-9.-]+$"#,
                    path: "$.runtimeRequirements.requiredResources.ownerModuleID"
                )
            }
        }
        guard manifest.diagnosticsVisibleInProduction == false else {
            throw ManifestDecodingError.invalidField(
                path: "$.diagnosticsVisibleInProduction",
                reason: "Production module diagnostics must be disabled."
            )
        }
    }

    private static func requireMatch(_ value: String, pattern: String, path: String) throws {
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw ManifestDecodingError.invalidField(path: path, reason: "Invalid identifier.")
        }
    }

    private static func requireUnique(_ values: [String], path: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw ManifestDecodingError.duplicateValue(path: path, value: value)
        }
    }
}

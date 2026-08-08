import Foundation
import RuneScribeContracts

public enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case service
    case ui
}

public enum SupportedPlatform: String, Codable, CaseIterable, Sendable {
    case iOS
    case macOS
}

public struct MinimumOSVersions: Codable, Equatable, Sendable {
    public let iOS: String?
    public let macOS: String?

    public init(iOS: String? = nil, macOS: String? = nil) {
        self.iOS = iOS
        self.macOS = macOS
    }
}

public struct ModuleRuntimeRequirements: Codable, Equatable, Sendable {
    public let requiredServices: [ServiceIdentifier]
    public let requiredModuleRoles: [ModuleRole]

    public init(
        requiredServices: [ServiceIdentifier] = [],
        requiredModuleRoles: [ModuleRole] = []
    ) {
        self.requiredServices = requiredServices
        self.requiredModuleRoles = requiredModuleRoles
    }
}

public struct EntitlementRequirement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case always
        case earned
        case purchase
        case composite
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct ModuleManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"
    public static let currentPolicyProfile = "forsetti-pattern-b-standalone"

    public let schemaVersion: String
    public let policyProfile: String
    public let runtimeVersion: SemanticVersion
    public let moduleID: ModuleIdentifier
    public let displayName: String
    public let moduleVersion: SemanticVersion
    public let moduleType: ModuleKind
    public let supportedPlatforms: [SupportedPlatform]
    public let minimumOS: MinimumOSVersions?
    public let capabilitiesRequested: [CapabilityIdentifier]
    public let entryPoint: String
    public let runtimeRequirements: ModuleRuntimeRequirements
    public let defaultRole: ModuleRole
    public let entitlementRequirement: EntitlementRequirement?
    public let diagnosticsVisibleInProduction: Bool

    public init(
        schemaVersion: String = ModuleManifest.currentSchemaVersion,
        policyProfile: String = ModuleManifest.currentPolicyProfile,
        runtimeVersion: SemanticVersion,
        moduleID: ModuleIdentifier,
        displayName: String,
        moduleVersion: SemanticVersion,
        moduleType: ModuleKind,
        supportedPlatforms: [SupportedPlatform],
        minimumOS: MinimumOSVersions? = nil,
        capabilitiesRequested: [CapabilityIdentifier],
        entryPoint: String,
        runtimeRequirements: ModuleRuntimeRequirements,
        defaultRole: ModuleRole,
        entitlementRequirement: EntitlementRequirement? = nil,
        diagnosticsVisibleInProduction: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.policyProfile = policyProfile
        self.runtimeVersion = runtimeVersion
        self.moduleID = moduleID
        self.displayName = displayName
        self.moduleVersion = moduleVersion
        self.moduleType = moduleType
        self.supportedPlatforms = supportedPlatforms
        self.minimumOS = minimumOS
        self.capabilitiesRequested = capabilitiesRequested
        self.entryPoint = entryPoint
        self.runtimeRequirements = runtimeRequirements
        self.defaultRole = defaultRole
        self.entitlementRequirement = entitlementRequirement
        self.diagnosticsVisibleInProduction = diagnosticsVisibleInProduction
    }
}

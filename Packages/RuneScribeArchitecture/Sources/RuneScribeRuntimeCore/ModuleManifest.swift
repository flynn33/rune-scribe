import Foundation
import RuneScribeContracts

public enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case service
    case ui
}

public enum ModuleCriticality: String, Codable, CaseIterable, Sendable {
    case required
    case optional
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
    public let requiredResources: [ApplicationResource]
    public let requiredModuleRoles: [ModuleRole]

    public init(
        requiredServices: [ServiceIdentifier] = [],
        requiredResources: [ApplicationResource] = [],
        requiredModuleRoles: [ModuleRole] = []
    ) {
        self.requiredServices = requiredServices
        self.requiredResources = requiredResources
        self.requiredModuleRoles = requiredModuleRoles
    }

    private enum CodingKeys: String, CodingKey {
        case requiredServices
        case requiredResources
        case requiredModuleRoles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requiredServices = try container.decode(
            [ServiceIdentifier].self,
            forKey: .requiredServices
        )
        requiredResources = try container.decodeIfPresent(
            [ApplicationResource].self,
            forKey: .requiredResources
        ) ?? []
        requiredModuleRoles = try container.decode(
            [ModuleRole].self,
            forKey: .requiredModuleRoles
        )
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
    public let identifier: UnlockID

    public init(kind: Kind, identifier: UnlockID) {
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
    public let criticality: ModuleCriticality
    public let supportedPlatforms: [SupportedPlatform]
    public let minimumOS: MinimumOSVersions?
    public let capabilitiesRequested: [CapabilityIdentifier]
    public let entryPoint: String
    public let runtimeRequirements: ModuleRuntimeRequirements
    public let defaultRole: ModuleRole
    public let consumedEndpoints: [RuntimeEndpointIdentifier]
    public let publishedEndpoints: [RuntimeEndpointIdentifier]
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
        criticality: ModuleCriticality = .required,
        supportedPlatforms: [SupportedPlatform],
        minimumOS: MinimumOSVersions? = nil,
        capabilitiesRequested: [CapabilityIdentifier],
        entryPoint: String,
        runtimeRequirements: ModuleRuntimeRequirements,
        defaultRole: ModuleRole,
        consumedEndpoints: [RuntimeEndpointIdentifier] = [],
        publishedEndpoints: [RuntimeEndpointIdentifier] = [],
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
        self.criticality = criticality
        self.supportedPlatforms = supportedPlatforms
        self.minimumOS = minimumOS
        self.capabilitiesRequested = capabilitiesRequested
        self.entryPoint = entryPoint
        self.runtimeRequirements = runtimeRequirements
        self.defaultRole = defaultRole
        self.consumedEndpoints = consumedEndpoints
        self.publishedEndpoints = publishedEndpoints
        self.entitlementRequirement = entitlementRequirement
        self.diagnosticsVisibleInProduction = diagnosticsVisibleInProduction
    }
}

import Foundation
import RuneScribeContracts

public struct ModuleDescriptor: Hashable, Sendable {
    public let moduleID: ModuleIdentifier
    public let moduleVersion: SemanticVersion
    public let kind: ModuleKind
    public let criticality: ModuleCriticality
    public let entryPoint: String
    public let role: ModuleRole
    public let policyClass: ModulePolicyClass
    public let requestedCapabilities: Set<CapabilityIdentifier>
    public let requiredServices: Set<ServiceIdentifier>
    public let requiredResources: Set<ApplicationResource>
    public let publishedServices: Set<ServiceIdentifier>
    public let requiredModuleRoles: Set<ModuleRole>
    public let consumedEndpoints: Set<RuntimeEndpointIdentifier>
    public let publishedEndpoints: Set<RuntimeEndpointIdentifier>

    public init(
        moduleID: ModuleIdentifier,
        moduleVersion: SemanticVersion,
        kind: ModuleKind,
        criticality: ModuleCriticality = .required,
        entryPoint: String,
        role: ModuleRole,
        policyClass: ModulePolicyClass? = nil,
        requestedCapabilities: Set<CapabilityIdentifier>,
        requiredServices: Set<ServiceIdentifier> = [],
        requiredResources: Set<ApplicationResource> = [],
        publishedServices: Set<ServiceIdentifier> = [],
        requiredModuleRoles: Set<ModuleRole> = [],
        consumedEndpoints: Set<RuntimeEndpointIdentifier> = [],
        publishedEndpoints: Set<RuntimeEndpointIdentifier> = []
    ) {
        self.moduleID = moduleID
        self.moduleVersion = moduleVersion
        self.kind = kind
        self.criticality = criticality
        self.entryPoint = entryPoint
        self.role = role
        self.policyClass = policyClass ?? ModulePolicyClass(role: role)
        self.requestedCapabilities = requestedCapabilities
        self.requiredServices = requiredServices
        self.requiredResources = requiredResources
        self.publishedServices = publishedServices
        self.requiredModuleRoles = requiredModuleRoles
        self.consumedEndpoints = consumedEndpoints
        self.publishedEndpoints = publishedEndpoints
    }
}

public protocol RuneScribeModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    func start(context: ModuleContext) async throws
    func stop() async
}

public protocol RuntimeConstructibleModule: RuneScribeModule {
    static var moduleDescriptor: ModuleDescriptor { get }
    init()
}

public struct AnyModuleFactory: Sendable {
    public let descriptor: ModuleDescriptor
    private let makeClosure: @Sendable () throws -> any RuneScribeModule

    public init<Module: RuntimeConstructibleModule>(
        moduleType _: Module.Type
    ) {
        descriptor = Module.moduleDescriptor
        makeClosure = { Module.init() }
    }

    @_spi(RuntimeTesting)
    public init(
        descriptor: ModuleDescriptor,
        make: @escaping @Sendable () throws -> any RuneScribeModule
    ) {
        self.descriptor = descriptor
        makeClosure = make
    }

    @_spi(ThemeFidelityQualification)
    public init(
        qualificationDescriptor descriptor: ModuleDescriptor,
        make: @escaping @Sendable () throws -> any RuneScribeModule
    ) {
        self.descriptor = descriptor
        makeClosure = make
    }

    public func makeModule() throws -> any RuneScribeModule {
        try makeClosure()
    }
}

public enum ModuleLifecycleState: Equatable, Sendable {
    case registered
    case validated
    case eligible
    case activating
    case active
    case stopping
    case stopped
    case failed
}

public protocol ModuleEligibilityProviding: Sendable {
    func isEligible(_ manifest: ModuleManifest) async -> Bool
}

public struct AlwaysEligibleProvider: ModuleEligibilityProviding {
    public init() {}

    public func isEligible(_ manifest: ModuleManifest) async -> Bool {
        true
    }
}

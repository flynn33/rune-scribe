import Foundation
import RuneScribeContracts

public struct ModuleDescriptor: Hashable, Sendable {
    public let moduleID: ModuleIdentifier
    public let moduleVersion: SemanticVersion
    public let kind: ModuleKind
    public let entryPoint: String
    public let role: ModuleRole
    public let requestedCapabilities: Set<CapabilityIdentifier>
    public let requiredServices: Set<ServiceIdentifier>
    public let publishedServices: Set<ServiceIdentifier>
    public let requiredModuleRoles: Set<ModuleRole>

    public init(
        moduleID: ModuleIdentifier,
        moduleVersion: SemanticVersion,
        kind: ModuleKind,
        entryPoint: String,
        role: ModuleRole,
        requestedCapabilities: Set<CapabilityIdentifier>,
        requiredServices: Set<ServiceIdentifier> = [],
        publishedServices: Set<ServiceIdentifier> = [],
        requiredModuleRoles: Set<ModuleRole> = []
    ) {
        self.moduleID = moduleID
        self.moduleVersion = moduleVersion
        self.kind = kind
        self.entryPoint = entryPoint
        self.role = role
        self.requestedCapabilities = requestedCapabilities
        self.requiredServices = requiredServices
        self.publishedServices = publishedServices
        self.requiredModuleRoles = requiredModuleRoles
    }
}

public protocol RuneScribeModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    func start(context: ModuleContext) async throws
    func stop() async
}

public struct AnyModuleFactory: Sendable {
    public let descriptor: ModuleDescriptor
    private let makeClosure: @Sendable () throws -> any RuneScribeModule

    public init(
        descriptor: ModuleDescriptor,
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

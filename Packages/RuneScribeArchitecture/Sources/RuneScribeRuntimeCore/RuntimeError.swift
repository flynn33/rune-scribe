import Foundation
import RuneScribeContracts

public enum RuneScribeRuntimeError: Error, Equatable, Sendable {
    case duplicateModuleID(ModuleIdentifier)
    case duplicateEntryPoint(String)
    case duplicateRole(ModuleRole)
    case manifestDescriptorMismatch(moduleID: ModuleIdentifier, field: String)
    case factoryDescriptorMismatch(ModuleIdentifier)
    case incompatibleRuntime(moduleID: ModuleIdentifier, minimum: SemanticVersion, actual: SemanticVersion)
    case unsupportedPlatform(moduleID: ModuleIdentifier, platform: SupportedPlatform)
    case unknownCapability(moduleID: ModuleIdentifier, capability: CapabilityIdentifier)
    case capabilityDenied(moduleID: ModuleIdentifier, capability: CapabilityIdentifier)
    case serviceMappingMissing(moduleID: ModuleIdentifier, service: ServiceIdentifier)
    case noEligibleUIModule
    case multipleEligibleUIModules([ModuleIdentifier])
    case missingRequiredRole(moduleID: ModuleIdentifier, role: ModuleRole)
    case dependencyCycle([ModuleIdentifier])
    case activationFailed(ModuleIdentifier)
    case runtimeBusy
    case contextInactive(ModuleIdentifier)
    case serviceNotDeclared(moduleID: ModuleIdentifier, service: ServiceIdentifier)
    case serviceCapabilityMissing(moduleID: ModuleIdentifier, service: ServiceIdentifier)
    case serviceAccessDenied(moduleID: ModuleIdentifier, service: ServiceIdentifier)
    case serviceUnavailable(ServiceIdentifier)
    case serviceTypeMismatch(ServiceIdentifier)
    case duplicateService(ServiceIdentifier)
    case hostServiceAccessDenied(ServiceIdentifier)
    case messageDestinationUnavailable(ModuleRole)
    case duplicateMessageDestination(ModuleRole)
}

extension RuneScribeRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateModuleID(let id):
            "Duplicate module ID: \(id.rawValue)."
        case .duplicateEntryPoint(let entryPoint):
            "Duplicate module entry point: \(entryPoint)."
        case .duplicateRole(let role):
            "Duplicate module role: \(role.rawValue)."
        case .manifestDescriptorMismatch(let moduleID, let field):
            "Manifest and descriptor differ for \(moduleID.rawValue) at \(field)."
        case .factoryDescriptorMismatch(let moduleID):
            "Factory returned a descriptor that does not match \(moduleID.rawValue)."
        case .incompatibleRuntime(let moduleID, let minimum, let actual):
            "Module \(moduleID.rawValue) requires runtime \(minimum); current runtime is \(actual)."
        case .unsupportedPlatform(let moduleID, let platform):
            "Module \(moduleID.rawValue) does not support \(platform.rawValue)."
        case .unknownCapability(let moduleID, let capability):
            "Module \(moduleID.rawValue) requests unknown capability \(capability.rawValue)."
        case .capabilityDenied(let moduleID, let capability):
            "Module \(moduleID.rawValue) is not allowed capability \(capability.rawValue)."
        case .serviceMappingMissing(let moduleID, let service):
            "Module \(moduleID.rawValue) declares unmapped service \(service.rawValue)."
        case .noEligibleUIModule:
            "Exactly one eligible UI module is required; none were eligible."
        case .multipleEligibleUIModules:
            "Exactly one eligible UI module is required; multiple modules were eligible."
        case .missingRequiredRole(let moduleID, let role):
            "Module \(moduleID.rawValue) requires missing role \(role.rawValue)."
        case .dependencyCycle:
            "Module activation dependencies contain a cycle."
        case .activationFailed(let moduleID):
            "Module \(moduleID.rawValue) failed to activate."
        case .runtimeBusy:
            "The runtime is already starting or stopping."
        case .contextInactive(let moduleID):
            "The scoped context for \(moduleID.rawValue) is inactive."
        case .serviceNotDeclared(let moduleID, let service):
            "Module \(moduleID.rawValue) did not declare service \(service.rawValue)."
        case .serviceCapabilityMissing(let moduleID, let service):
            "Module \(moduleID.rawValue) lacks the capability required for \(service.rawValue)."
        case .serviceAccessDenied(let moduleID, let service):
            "Module \(moduleID.rawValue) is denied service \(service.rawValue)."
        case .serviceUnavailable(let service):
            "Service \(service.rawValue) is unavailable."
        case .serviceTypeMismatch(let service):
            "Service \(service.rawValue) was resolved with an incompatible type."
        case .duplicateService(let service):
            "Service \(service.rawValue) is already registered."
        case .hostServiceAccessDenied(let service):
            "The application host is denied service \(service.rawValue)."
        case .messageDestinationUnavailable(let role):
            "No message destination is registered for role \(role.rawValue)."
        case .duplicateMessageDestination(let role):
            "A message destination is already registered for role \(role.rawValue)."
        }
    }
}

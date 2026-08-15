import Foundation
import RuneScribeContracts

public enum ModuleManifestValidator {
    public static func validate(
        manifest: ModuleManifest,
        descriptor: ModuleDescriptor,
        runtimeVersion: SemanticVersion,
        platform: SupportedPlatform,
        policy: RuntimePolicy
    ) throws {
        try validateCriticality(descriptor)
        try requireEqual(manifest.moduleID, descriptor.moduleID, moduleID: manifest.moduleID, field: "moduleID")
        try requireEqual(manifest.moduleVersion, descriptor.moduleVersion, moduleID: manifest.moduleID, field: "moduleVersion")
        try requireEqual(manifest.moduleType, descriptor.kind, moduleID: manifest.moduleID, field: "moduleType")
        try requireEqual(manifest.criticality, descriptor.criticality, moduleID: manifest.moduleID, field: "criticality")
        try requireEqual(manifest.entryPoint, descriptor.entryPoint, moduleID: manifest.moduleID, field: "entryPoint")
        try requireEqual(manifest.defaultRole, descriptor.role, moduleID: manifest.moduleID, field: "defaultRole")
        try requireEqual(
            Set(manifest.capabilitiesRequested),
            descriptor.requestedCapabilities,
            moduleID: manifest.moduleID,
            field: "capabilitiesRequested"
        )
        try requireEqual(
            Set(manifest.runtimeRequirements.requiredServices),
            descriptor.requiredServices,
            moduleID: manifest.moduleID,
            field: "runtimeRequirements.requiredServices"
        )
        try requireEqual(
            Set(manifest.runtimeRequirements.requiredResources),
            descriptor.requiredResources,
            moduleID: manifest.moduleID,
            field: "runtimeRequirements.requiredResources"
        )
        try requireEqual(
            Set(manifest.runtimeRequirements.requiredModuleRoles),
            descriptor.requiredModuleRoles,
            moduleID: manifest.moduleID,
            field: "runtimeRequirements.requiredModuleRoles"
        )
        try requireEqual(
            Set(manifest.consumedEndpoints),
            descriptor.consumedEndpoints,
            moduleID: manifest.moduleID,
            field: "consumedEndpoints"
        )
        try requireEqual(
            Set(manifest.publishedEndpoints),
            descriptor.publishedEndpoints,
            moduleID: manifest.moduleID,
            field: "publishedEndpoints"
        )

        guard runtimeVersion >= manifest.runtimeVersion else {
            throw RuneScribeRuntimeError.incompatibleRuntime(
                moduleID: manifest.moduleID,
                minimum: manifest.runtimeVersion,
                actual: runtimeVersion
            )
        }
        guard manifest.supportedPlatforms.contains(platform) else {
            throw RuneScribeRuntimeError.unsupportedPlatform(
                moduleID: manifest.moduleID,
                platform: platform
            )
        }

        for capability in descriptor.requestedCapabilities.sorted() {
            guard policy.vocabulary.contains(capability) else {
                throw RuneScribeRuntimeError.unknownCapability(
                    moduleID: manifest.moduleID,
                    capability: capability
                )
            }
            guard policy.capabilities.allows(capability, for: descriptor.role) else {
                throw RuneScribeRuntimeError.capabilityDenied(
                    moduleID: manifest.moduleID,
                    capability: capability
                )
            }
        }

        if descriptor.kind == .ui,
           !descriptor.requestedCapabilities.contains(RuneScribeCapabilities.rootUI)
        {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: manifest.moduleID,
                capability: RuneScribeCapabilities.rootUI
            )
        }

        for service in descriptor.requiredServices.sorted() {
            guard let rule = policy.services.rule(for: service) else {
                throw RuneScribeRuntimeError.serviceMappingMissing(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
            guard descriptor.requestedCapabilities.contains(rule.requiredCapability),
                  policy.capabilities.allows(rule.requiredCapability, for: descriptor.role)
            else {
                throw RuneScribeRuntimeError.serviceCapabilityMissing(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
            guard rule.consumerRoles.contains(descriptor.role) else {
                throw RuneScribeRuntimeError.serviceAccessDenied(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
        }

        for service in descriptor.publishedServices.sorted() {
            guard let rule = policy.services.rule(for: service) else {
                throw RuneScribeRuntimeError.serviceMappingMissing(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
            guard descriptor.requestedCapabilities.contains(RuneScribeCapabilities.publishService) else {
                throw RuneScribeRuntimeError.serviceCapabilityMissing(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
            guard rule.publisherRoles.contains(descriptor.role) else {
                throw RuneScribeRuntimeError.serviceAccessDenied(
                    moduleID: manifest.moduleID,
                    service: service
                )
            }
        }
    }

    static func validateCriticality(_ descriptor: ModuleDescriptor) throws {
        let mustBeRequired = descriptor.kind == .ui
            || descriptor.moduleID == RuneScribeModuleIDs.core
            || descriptor.role == RuneScribeRoles.core
        guard !mustBeRequired || descriptor.criticality == .required else {
            throw RuneScribeRuntimeError.invalidModuleCriticality(
                moduleID: descriptor.moduleID,
                expected: .required,
                actual: descriptor.criticality
            )
        }
    }

    private static func requireEqual<Value: Equatable>(
        _ manifestValue: Value,
        _ descriptorValue: Value,
        moduleID: ModuleIdentifier,
        field: String
    ) throws {
        guard manifestValue == descriptorValue else {
            throw RuneScribeRuntimeError.manifestDescriptorMismatch(
                moduleID: moduleID,
                field: field
            )
        }
    }
}

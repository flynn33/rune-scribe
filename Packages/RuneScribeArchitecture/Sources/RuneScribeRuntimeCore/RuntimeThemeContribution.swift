import Foundation
import RuneScribeContracts

public enum RuntimeThemeContributionCatalog {
    public static let descriptor = RuntimeContributionType<ThemeDescriptor>(
        id: RuntimeContributionCatalog.themeDescriptorTypeID
    )

    public static func key(for codexID: CodexID) -> RuntimeContributionKey {
        RuntimeContributionKey(rawValue: codexID.rawValue)!
    }

    public static func resourceNamespace(
        for codexID: CodexID
    ) -> OpaqueResourceNamespaceID {
        OpaqueResourceNamespaceID(rawValue: codexID.rawValue)
    }
}

enum RuntimeContributionCatalog {
    static let themeDescriptorTypeID = RuntimeContributionTypeID(
        rawValue: "theme.descriptor"
    )!

    static let canonicalRules: [
        RuntimeContributionTypeID: RuntimeContributionCanonicalRule
    ] = [
        themeDescriptorTypeID: RuntimeContributionCanonicalRule(
            valueType: ThemeDescriptor.self,
            validate: validateThemeDescriptor
        ),
    ]

    static func validateThemeDescriptor(
        _ descriptor: ThemeDescriptor,
        _ key: RuntimeContributionKey,
        _ module: ModuleDescriptor
    ) throws {
        guard descriptor.moduleID.rawValue == module.moduleID.rawValue,
              descriptor.moduleRole.rawValue == module.role.rawValue,
              descriptor.policyClass.rawValue == module.policyClass.rawValue
        else {
            throw RuntimeContributionRegistryError.canonicalIdentityMismatch(key)
        }
        let expectedCriticality: ThemeCriticality
        switch module.criticality {
        case .optional:
            expectedCriticality = .optional
        case .required:
            guard module.moduleID == RuneScribeModuleIDs.norseTheme,
                  descriptor.codex.id == RuneScribeCodexIDs.norse,
                  descriptor.fallbackCodexID == RuneScribeCodexIDs.norse
            else {
                throw RuntimeContributionRegistryError.canonicalCriticalityMismatch(key)
            }
            expectedCriticality = .requiredBase
        }
        guard descriptor.criticality == expectedCriticality else {
            throw RuntimeContributionRegistryError.canonicalCriticalityMismatch(key)
        }
        guard descriptor.fallbackCodexID == RuneScribeCodexIDs.norse else {
            throw RuntimeContributionRegistryError.canonicalCriticalityMismatch(key)
        }
        let maximumDescriptorBytes = 256 * 1_024
        guard let encoded = try? JSONEncoder().encode(descriptor),
              encoded.count <= maximumDescriptorBytes
        else {
            throw RuntimeContributionRegistryError.canonicalDescriptorTooLarge(
                maximumBytes: maximumDescriptorBytes
            )
        }
        guard key == RuntimeThemeContributionCatalog.key(
            for: descriptor.codex.id
        ) else {
            throw RuntimeContributionRegistryError.canonicalKeyMismatch(key)
        }
    }
}

public extension ModuleContext {
    func publishTheme(
        descriptor: ThemeDescriptor,
        resourcePayloads: [ThemeResourceID: Data]
    ) async throws {
        guard descriptor.moduleID.rawValue == moduleID.rawValue,
              descriptor.moduleRole.rawValue == role.rawValue,
              descriptor.policyClass.rawValue == policyClass.rawValue
        else {
            throw RuntimeThemeContributionError.identityMismatch
        }
        let declaredIDs = Set(descriptor.resources.map(\.id))
        guard Set(resourcePayloads.keys).isSubset(of: declaredIDs) else {
            throw RuntimeThemeContributionError.undeclaredResource
        }
        let provider = try await opaqueResourceProviderClient()
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: descriptor.codex.id
        )
        try await provider.register(
            OpaqueResourceNamespaceRegistration(
                namespace: namespace,
                declarations: descriptor.resources.map { resource in
                    OpaqueResourceDeclaration(
                        resourceID: OpaqueResourceID(rawValue: resource.id.rawValue),
                        semanticRole: resource.role.rawValue,
                        mediaType: resource.mediaType.opaqueMediaType,
                        byteCount: Int(resource.integrity.byteLength),
                        sha256: resource.integrity.sha256.rawValue,
                        pixelSize: resource.integrity.pixelSize.map {
                            OpaqueResourcePixelSize(
                                width: Int($0.width),
                                height: Int($0.height)
                            )
                        },
                        isRequired: resource.requirement == .required
                    )
                },
                payloads: resourcePayloads.map { resourceID, data in
                    OpaqueResourcePayload(
                        resourceID: OpaqueResourceID(rawValue: resourceID.rawValue),
                        data: data
                    )
                }
            )
        )
        do {
            _ = try await publishThemeDescriptor(descriptor)
        } catch {
            try? await provider.unregister(namespace)
            throw error
        }
    }

    @discardableResult
    func publishThemeDescriptor(
        _ descriptor: ThemeDescriptor
    ) async throws -> RuntimeContributionSnapshotEntry<ThemeDescriptor> {
        guard descriptor.moduleID.rawValue == moduleID.rawValue,
              descriptor.moduleRole.rawValue == role.rawValue,
              descriptor.policyClass.rawValue == policyClass.rawValue
        else {
            throw RuntimeThemeContributionError.identityMismatch
        }
        let publisher = try await contributionPublisherClient()
        return try await publisher.publish(
            descriptor,
            type: RuntimeThemeContributionCatalog.descriptor,
            key: RuntimeThemeContributionCatalog.key(for: descriptor.codex.id)
        )
    }
}

public enum RuntimeThemeContributionError: Error, Equatable, Sendable {
    case identityMismatch
    case undeclaredResource
}

import Foundation
import RuneScribeContracts

public struct OpaqueResourceNamespaceID: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct OpaqueResourceID: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct OpaqueResourceHandle: Codable, Hashable, Sendable, Comparable {
    public let namespace: OpaqueResourceNamespaceID
    public let resourceID: OpaqueResourceID

    public init(
        namespace: OpaqueResourceNamespaceID,
        resourceID: OpaqueResourceID
    ) {
        self.namespace = namespace
        self.resourceID = resourceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.resourceID < rhs.resourceID
    }
}

public struct OpaqueResourceMediaType: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let json: Self = "application/json"
    public static let png: Self = "image/png"
    public static let heif: Self = "image/heif"
    public static let heic: Self = "image/heic"
    public static let pdf: Self = "application/pdf"
    public static let trueTypeFont: Self = "font/ttf"
    public static let openTypeFont: Self = "font/otf"
    public static let mp4: Self = "video/mp4"
    public static let quickTime: Self = "video/quicktime"
    public static let m4a: Self = "audio/mp4"
    public static let caf: Self = "audio/x-caf"
    public static let wav: Self = "audio/wav"
    public static let xWav: Self = "audio/x-wav"
}

public struct OpaqueResourcePixelSize: Codable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum OpaqueResourceCategory: String, Codable, CaseIterable, Sendable {
    case descriptor
    case image
    case font
    case animation
    case sound
}

public struct OpaqueResourceDeclaration: Codable, Equatable, Hashable, Sendable {
    public let resourceID: OpaqueResourceID
    public let semanticRole: String
    public let mediaType: OpaqueResourceMediaType
    public let byteCount: Int
    public let sha256: String
    public let pixelSize: OpaqueResourcePixelSize?
    public let isRequired: Bool

    public init(
        resourceID: OpaqueResourceID,
        semanticRole: String,
        mediaType: OpaqueResourceMediaType,
        byteCount: Int,
        sha256: String,
        pixelSize: OpaqueResourcePixelSize? = nil,
        isRequired: Bool = true
    ) {
        self.resourceID = resourceID
        self.semanticRole = semanticRole
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelSize = pixelSize
        self.isRequired = isRequired
    }
}

public struct OpaqueResourcePayload: Sendable {
    public let resourceID: OpaqueResourceID
    public let data: Data

    public init(resourceID: OpaqueResourceID, data: Data) {
        self.resourceID = resourceID
        self.data = data
    }
}

public typealias OpaqueResourceDataLoader =
    @Sendable (OpaqueResourceID) async throws -> Data?

public struct OpaqueResourceNamespaceRegistration: Sendable {
    public let namespace: OpaqueResourceNamespaceID
    public let declarations: [OpaqueResourceDeclaration]
    public let payloads: [OpaqueResourcePayload]
    public let resourceLoader: OpaqueResourceDataLoader?

    public init(
        namespace: OpaqueResourceNamespaceID,
        declarations: [OpaqueResourceDeclaration],
        payloads: [OpaqueResourcePayload]
    ) {
        self.namespace = namespace
        self.declarations = declarations
        self.payloads = payloads
        resourceLoader = nil
    }

    public init(
        namespace: OpaqueResourceNamespaceID,
        declarations: [OpaqueResourceDeclaration],
        resourceLoader: @escaping OpaqueResourceDataLoader
    ) {
        self.namespace = namespace
        self.declarations = declarations
        payloads = []
        self.resourceLoader = resourceLoader
    }
}

public struct OpaqueResourceMetadata: Codable, Equatable, Hashable, Sendable {
    public let handle: OpaqueResourceHandle
    public let ownerModuleID: ModuleIdentifier
    public let registrationID: UInt64
    public let semanticRole: String
    public let mediaType: OpaqueResourceMediaType
    public let category: OpaqueResourceCategory
    public let byteCount: Int
    public let sha256: String
    public let pixelSize: OpaqueResourcePixelSize?

    public init(
        handle: OpaqueResourceHandle,
        ownerModuleID: ModuleIdentifier,
        registrationID: UInt64 = 0,
        semanticRole: String,
        mediaType: OpaqueResourceMediaType,
        category: OpaqueResourceCategory,
        byteCount: Int,
        sha256: String,
        pixelSize: OpaqueResourcePixelSize?
    ) {
        self.handle = handle
        self.ownerModuleID = ownerModuleID
        self.registrationID = registrationID
        self.semanticRole = semanticRole
        self.mediaType = mediaType
        self.category = category
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelSize = pixelSize
    }

    private enum CodingKeys: String, CodingKey {
        case handle
        case ownerModuleID
        case registrationID
        case semanticRole
        case mediaType
        case category
        case byteCount
        case sha256
        case pixelSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decode(OpaqueResourceHandle.self, forKey: .handle)
        ownerModuleID = try container.decode(ModuleIdentifier.self, forKey: .ownerModuleID)
        registrationID = try container.decodeIfPresent(
            UInt64.self,
            forKey: .registrationID
        ) ?? 0
        semanticRole = try container.decode(String.self, forKey: .semanticRole)
        mediaType = try container.decode(OpaqueResourceMediaType.self, forKey: .mediaType)
        category = try container.decode(OpaqueResourceCategory.self, forKey: .category)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        pixelSize = try container.decodeIfPresent(
            OpaqueResourcePixelSize.self,
            forKey: .pixelSize
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handle, forKey: .handle)
        try container.encode(ownerModuleID, forKey: .ownerModuleID)
        try container.encode(registrationID, forKey: .registrationID)
        try container.encode(semanticRole, forKey: .semanticRole)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(category, forKey: .category)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(pixelSize, forKey: .pixelSize)
    }
}

public struct ResolvedOpaqueResource: Sendable {
    public let metadata: OpaqueResourceMetadata
    public let data: Data

    public init(metadata: OpaqueResourceMetadata, data: Data) {
        self.metadata = metadata
        self.data = data
    }
}

public enum OpaqueResourceValidationFaultCode: String, Codable, Hashable, Sendable {
    case missingRequiredResource = "missing-required-resource"
    case resourceMismatch = "resource-mismatch"
}

public struct OpaqueResourceValidationFault: Codable, Equatable, Hashable, Sendable {
    public let handle: OpaqueResourceHandle
    public let ownerModuleID: ModuleIdentifier
    public let registrationID: UInt64
    public let code: OpaqueResourceValidationFaultCode
    public let requiredBaseFailure: RequiredThemeResourceFailureDTO?

    public init(
        handle: OpaqueResourceHandle,
        ownerModuleID: ModuleIdentifier,
        registrationID: UInt64,
        code: OpaqueResourceValidationFaultCode,
        requiredBaseFailure: RequiredThemeResourceFailureDTO? = nil
    ) {
        self.handle = handle
        self.ownerModuleID = ownerModuleID
        self.registrationID = registrationID
        self.code = code
        self.requiredBaseFailure = requiredBaseFailure
    }
}

public struct OpaqueResourceSnapshot: Sendable {
    public let revision: UInt64
    public let resources: [OpaqueResourceMetadata]
    public let validationFaults: [OpaqueResourceValidationFault]

    public init(
        revision: UInt64,
        resources: [OpaqueResourceMetadata],
        validationFaults: [OpaqueResourceValidationFault] = []
    ) {
        self.revision = revision
        self.resources = resources
        self.validationFaults = validationFaults
    }
}

public struct OpaqueResourceBudget: Equatable, Sendable {
    public let maximumDescriptorBytes: Int
    public let maximumImageBytes: Int
    public let maximumImageDimension: Int
    public let maximumImageCatalogBytes: Int
    public let maximumFontBytes: Int
    public let maximumFontCatalogBytes: Int
    public let maximumAnimationCatalogBytes: Int
    public let maximumSoundBytes: Int
    public let maximumSoundCatalogBytes: Int
    public let maximumModuleBytes: Int

    public init(
        maximumDescriptorBytes: Int,
        maximumImageBytes: Int,
        maximumImageDimension: Int,
        maximumImageCatalogBytes: Int,
        maximumFontBytes: Int,
        maximumFontCatalogBytes: Int,
        maximumAnimationCatalogBytes: Int,
        maximumSoundBytes: Int,
        maximumSoundCatalogBytes: Int,
        maximumModuleBytes: Int
    ) {
        self.maximumDescriptorBytes = maximumDescriptorBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumImageDimension = maximumImageDimension
        self.maximumImageCatalogBytes = maximumImageCatalogBytes
        self.maximumFontBytes = maximumFontBytes
        self.maximumFontCatalogBytes = maximumFontCatalogBytes
        self.maximumAnimationCatalogBytes = maximumAnimationCatalogBytes
        self.maximumSoundBytes = maximumSoundBytes
        self.maximumSoundCatalogBytes = maximumSoundCatalogBytes
        self.maximumModuleBytes = maximumModuleBytes
    }

    public static let themeScaffold = Self(
        maximumDescriptorBytes: 256 * 1_024,
        maximumImageBytes: 8 * 1_024 * 1_024,
        maximumImageDimension: 4_096,
        maximumImageCatalogBytes: 96 * 1_024 * 1_024,
        maximumFontBytes: 8 * 1_024 * 1_024,
        maximumFontCatalogBytes: 16 * 1_024 * 1_024,
        maximumAnimationCatalogBytes: 16 * 1_024 * 1_024,
        maximumSoundBytes: 2 * 1_024 * 1_024,
        maximumSoundCatalogBytes: 8 * 1_024 * 1_024,
        maximumModuleBytes: 112 * 1_024 * 1_024
    )
}

public enum RuntimeOpaqueResourceError: Error, Equatable, Sendable {
    case invalidNamespace(OpaqueResourceNamespaceID)
    case invalidResourceID(OpaqueResourceID)
    case invalidSemanticRole(String)
    case duplicateNamespace(OpaqueResourceNamespaceID)
    case payloadBackedThemeProviderRegistrationDenied(OpaqueResourceNamespaceID)
    case duplicateResourceID(OpaqueResourceID)
    case duplicatePayload(OpaqueResourceID)
    case missingRequiredResource(OpaqueResourceID)
    case undeclaredResource(OpaqueResourceID)
    case unsupportedMediaType(OpaqueResourceMediaType)
    case mediaTypeMismatch(OpaqueResourceID)
    case invalidByteCount(OpaqueResourceID)
    case byteCountMismatch(OpaqueResourceID)
    case invalidSHA256(OpaqueResourceID)
    case hashMismatch(OpaqueResourceID)
    case pixelSizeRequired(OpaqueResourceID)
    case pixelSizeMismatch(OpaqueResourceID)
    case imageDimensionExceeded(OpaqueResourceID)
    case resourceBudgetExceeded(OpaqueResourceID)
    case catalogBudgetExceeded(OpaqueResourceCategory)
    case moduleBudgetExceeded
    case namespaceUnavailable(OpaqueResourceNamespaceID)
    case resourceUnavailable(OpaqueResourceHandle)
}

private struct RuntimeOpaqueResourceLease: Hashable, Sendable {
    let runtimeGeneration: UInt64
    let sourceModuleID: ModuleIdentifier
    let sourceModuleGeneration: UInt64
}

public struct RuntimeOpaqueResourceProviderClient: Sendable {
    private let registry: RuntimeOpaqueResourceRegistry
    private let lease: RuntimeOpaqueResourceLease

    fileprivate init(
        registry: RuntimeOpaqueResourceRegistry,
        lease: RuntimeOpaqueResourceLease
    ) {
        self.registry = registry
        self.lease = lease
    }

    public func register(
        _ registration: OpaqueResourceNamespaceRegistration
    ) async throws {
        try await registry.register(registration, for: lease)
    }

    func unregister(_ namespace: OpaqueResourceNamespaceID) async throws {
        try await registry.unregister(namespace, for: lease)
    }
}

public struct RuntimeOpaqueResourceResolverClient: Sendable {
    private let registry: RuntimeOpaqueResourceRegistry
    private let lease: RuntimeOpaqueResourceLease

    fileprivate init(
        registry: RuntimeOpaqueResourceRegistry,
        lease: RuntimeOpaqueResourceLease
    ) {
        self.registry = registry
        self.lease = lease
    }

    public func snapshot() async throws -> OpaqueResourceSnapshot {
        try await registry.snapshot(for: lease)
    }

    public func resolve(
        _ handle: OpaqueResourceHandle
    ) async throws -> ResolvedOpaqueResource {
        try await registry.resolve(handle, for: lease)
    }

    public func changes() async throws -> AsyncStream<UInt64> {
        try await registry.changes(for: lease)
    }
}

actor RuntimeOpaqueResourceRegistry {
    private struct ActiveModule: Sendable {
        let descriptor: ModuleDescriptor
        let generation: UInt64
    }

    private struct NamespaceOwner: Sendable {
        let moduleID: ModuleIdentifier
        let generation: UInt64
        let registrationID: UInt64
    }

    private struct StoredResource: Sendable {
        enum Storage: Sendable {
            case inline(Data)
            case deferred(OpaqueResourceDataLoader)
        }

        let metadata: OpaqueResourceMetadata
        let declaration: OpaqueResourceDeclaration
        let storage: Storage
        let ownerGeneration: UInt64
        let registrationID: UInt64
    }

    private struct Observer: Sendable {
        let lease: RuntimeOpaqueResourceLease
        let continuation: AsyncStream<UInt64>.Continuation
    }

    private let budget: OpaqueResourceBudget
    private var activeModules: [ModuleIdentifier: ActiveModule] = [:]
    private var namespaceOwners: [OpaqueResourceNamespaceID: NamespaceOwner] = [:]
    private var resources: [OpaqueResourceHandle: StoredResource] = [:]
    private var validationFaults: [OpaqueResourceHandle: OpaqueResourceValidationFault] = [:]
    private var runtimeGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var nextRegistrationID: UInt64 = 0
    private var isRuntimeActive = false
    private var nextObserverID: UInt64 = 0
    private var observers: [UInt64: Observer] = [:]

    init(budget: OpaqueResourceBudget = .themeScaffold) {
        self.budget = budget
    }

    @discardableResult
    func activateRuntime() -> UInt64 {
        finishObservers()
        runtimeGeneration &+= 1
        revision &+= 1
        activeModules.removeAll(keepingCapacity: true)
        namespaceOwners.removeAll(keepingCapacity: true)
        resources.removeAll(keepingCapacity: true)
        validationFaults.removeAll(keepingCapacity: true)
        isRuntimeActive = true
        return runtimeGeneration
    }

    func deactivateRuntime() {
        revision &+= 1
        activeModules.removeAll(keepingCapacity: false)
        namespaceOwners.removeAll(keepingCapacity: false)
        resources.removeAll(keepingCapacity: false)
        validationFaults.removeAll(keepingCapacity: false)
        isRuntimeActive = false
        finishObservers()
    }

    func currentGeneration() -> UInt64 {
        runtimeGeneration
    }

    func activateModule(descriptor: ModuleDescriptor, generation: UInt64) throws {
        guard isRuntimeActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        if let previous = activeModules[descriptor.moduleID],
           previous.generation != generation
        {
            removeResources(
                ownedBy: descriptor.moduleID,
                generation: previous.generation
            )
        }
        activeModules[descriptor.moduleID] = ActiveModule(
            descriptor: descriptor,
            generation: generation
        )
    }

    func invalidateModule(_ moduleID: ModuleIdentifier, generation: UInt64) {
        guard activeModules[moduleID]?.generation == generation else { return }
        activeModules.removeValue(forKey: moduleID)
        removeResources(ownedBy: moduleID, generation: generation)
        notifyObservers()
    }

    private func removeResources(
        ownedBy moduleID: ModuleIdentifier,
        generation: UInt64
    ) {
        let namespaces = namespaceOwners.compactMap { namespace, owner in
            owner.moduleID == moduleID && owner.generation == generation ? namespace : nil
        }
        guard !namespaces.isEmpty else { return }
        for namespace in namespaces {
            namespaceOwners.removeValue(forKey: namespace)
        }
        let namespaceSet = Set(namespaces)
        resources = resources.filter { !namespaceSet.contains($0.key.namespace) }
        validationFaults = validationFaults.filter {
            !namespaceSet.contains($0.key.namespace)
        }
        revision &+= 1
        notifyObservers()
    }

    func makeProviderClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration: UInt64,
        policy: RuntimePolicy,
        requiredCapability: CapabilityIdentifier
    ) throws -> RuntimeOpaqueResourceProviderClient {
        let lease = RuntimeOpaqueResourceLease(
            runtimeGeneration: runtimeGeneration,
            sourceModuleID: sourceModuleID,
            sourceModuleGeneration: sourceModuleGeneration
        )
        let module = try validate(lease)
        try authorize(
            module.descriptor,
            capability: requiredCapability,
            policy: policy
        )
        return RuntimeOpaqueResourceProviderClient(registry: self, lease: lease)
    }

    func makeResolverClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration: UInt64,
        policy: RuntimePolicy,
        requiredCapability: CapabilityIdentifier
    ) throws -> RuntimeOpaqueResourceResolverClient {
        let lease = RuntimeOpaqueResourceLease(
            runtimeGeneration: runtimeGeneration,
            sourceModuleID: sourceModuleID,
            sourceModuleGeneration: sourceModuleGeneration
        )
        let module = try validate(lease)
        try authorize(
            module.descriptor,
            capability: requiredCapability,
            policy: policy
        )
        return RuntimeOpaqueResourceResolverClient(registry: self, lease: lease)
    }

    fileprivate func register(
        _ registration: OpaqueResourceNamespaceRegistration,
        for lease: RuntimeOpaqueResourceLease
    ) throws {
        let module = try validate(lease)
        try Self.validateIdentifier(registration.namespace.rawValue)
            .orThrow(.invalidNamespace(registration.namespace))
        guard namespaceOwners[registration.namespace] == nil else {
            throw RuntimeOpaqueResourceError.duplicateNamespace(registration.namespace)
        }
        if module.descriptor.policyClass == RuneScribePolicyClasses.themeProvider,
           registration.resourceLoader == nil
        {
            throw RuntimeOpaqueResourceError
                .payloadBackedThemeProviderRegistrationDenied(registration.namespace)
        }
        precondition(
            nextRegistrationID < UInt64.max,
            "Opaque resource registration identity exhausted."
        )
        nextRegistrationID += 1
        let registrationID = nextRegistrationID

        let declarations = try Self.uniqueDeclarations(registration.declarations)
        var validated: [StoredResource] = []
        if let resourceLoader = registration.resourceLoader {
            for resourceID in declarations.keys.sorted() {
                let declaration = declarations[resourceID]!
                validated.append(
                    try validateDeclaration(
                        namespace: registration.namespace,
                        declaration: declaration,
                        storage: .deferred(resourceLoader),
                        ownerModuleID: lease.sourceModuleID,
                        ownerGeneration: lease.sourceModuleGeneration,
                        registrationID: registrationID
                    )
                )
            }
        } else {
            let payloads = try Self.uniquePayloads(registration.payloads)
            let declarationIDs = Set(declarations.keys)
            if let undeclared = payloads.keys.first(where: {
                !declarationIDs.contains($0)
            }) {
                throw RuntimeOpaqueResourceError.undeclaredResource(undeclared)
            }
            if let missing = declarations.values.first(where: {
                $0.isRequired && payloads[$0.resourceID] == nil
            }) {
                throw RuntimeOpaqueResourceError.missingRequiredResource(missing.resourceID)
            }
            for resourceID in declarations.keys.sorted() {
                guard let payload = payloads[resourceID] else { continue }
                let declaration = declarations[resourceID]!
                validated.append(
                    try validateResource(
                        namespace: registration.namespace,
                        declaration: declaration,
                        data: payload,
                        storage: .inline(payload),
                        ownerModuleID: lease.sourceModuleID,
                        ownerGeneration: lease.sourceModuleGeneration,
                        registrationID: registrationID
                    )
                )
            }
        }
        try validateBudgets(validated)

        namespaceOwners[registration.namespace] = NamespaceOwner(
            moduleID: lease.sourceModuleID,
            generation: lease.sourceModuleGeneration,
            registrationID: registrationID
        )
        validationFaults = validationFaults.filter {
            $0.key.namespace != registration.namespace
        }
        for resource in validated {
            resources[resource.metadata.handle] = resource
        }
        revision &+= 1
        notifyObservers()
    }

    fileprivate func snapshot(
        for lease: RuntimeOpaqueResourceLease
    ) throws -> OpaqueResourceSnapshot {
        _ = try validate(lease)
        return OpaqueResourceSnapshot(
            revision: revision,
            resources: resources.values.map(\.metadata).sorted { $0.handle < $1.handle },
            validationFaults: validationFaults.values.sorted {
                if $0.handle != $1.handle { return $0.handle < $1.handle }
                return $0.registrationID < $1.registrationID
            }
        )
    }

    fileprivate func unregister(
        _ namespace: OpaqueResourceNamespaceID,
        for lease: RuntimeOpaqueResourceLease
    ) throws {
        _ = try validate(lease)
        guard let owner = namespaceOwners[namespace],
              owner.moduleID == lease.sourceModuleID,
              owner.generation == lease.sourceModuleGeneration
        else {
            throw RuntimeOpaqueResourceError.namespaceUnavailable(namespace)
        }
        namespaceOwners.removeValue(forKey: namespace)
        resources = resources.filter { $0.key.namespace != namespace }
        validationFaults = validationFaults.filter { $0.key.namespace != namespace }
        revision &+= 1
        notifyObservers()
    }

    fileprivate func resolve(
        _ handle: OpaqueResourceHandle,
        for lease: RuntimeOpaqueResourceLease
    ) async throws -> ResolvedOpaqueResource {
        _ = try validate(lease)
        guard let owner = namespaceOwners[handle.namespace] else {
            throw RuntimeOpaqueResourceError.namespaceUnavailable(handle.namespace)
        }
        guard let resource = resources[handle],
              resource.registrationID == owner.registrationID
        else {
            throw RuntimeOpaqueResourceError.resourceUnavailable(handle)
        }
        let data = try await loadAndValidateData(for: resource)
        _ = try validate(lease)
        guard let current = resources[handle],
              let currentOwner = namespaceOwners[handle.namespace],
              currentOwner.registrationID == resource.registrationID,
              current.registrationID == resource.registrationID,
              current.metadata.registrationID == resource.registrationID,
              current.ownerGeneration == resource.ownerGeneration
        else { throw RuntimeOpaqueResourceError.resourceUnavailable(handle) }
        return ResolvedOpaqueResource(metadata: current.metadata, data: data)
    }

    func unlockFeedbackSoundData(
        codexID: CodexID,
        semanticID: UnlockFeedbackSoundSemanticID
    ) async -> Data? {
        guard isRuntimeActive else { return nil }
        let expectedSuffix: String = switch semanticID {
        case .micro: "unlock-minor"
        case .artifact: "unlock-relic"
        case .codex: "unlock-codex"
        case .mastery: "unlock-mastery"
        }
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: codexID
        )
        let matches = resources.values.filter {
            $0.metadata.handle.namespace == namespace
                && $0.metadata.semanticRole == "unlock-sound-cue"
                && $0.metadata.handle.resourceID.rawValue.hasSuffix(expectedSuffix)
        }
        guard matches.count == 1 else { return nil }
        return try? await loadAndValidateData(for: matches[0])
    }

    private func loadAndValidateData(for resource: StoredResource) async throws -> Data {
        let expectedRuntimeGeneration = runtimeGeneration
        do {
            let data: Data
            switch resource.storage {
            case .inline(let inlineData):
                data = inlineData
            case .deferred(let resourceLoader):
                guard let loaded = try await resourceLoader(
                    resource.declaration.resourceID
                ) else {
                    if resource.declaration.isRequired {
                        throw RuntimeOpaqueResourceError.missingRequiredResource(
                            resource.declaration.resourceID
                        )
                    }
                    throw RuntimeOpaqueResourceError.resourceUnavailable(
                        resource.metadata.handle
                    )
                }
                data = loaded
            }
            guard isCurrentRegistration(
                resource,
                expectedRuntimeGeneration: expectedRuntimeGeneration
            ), let current = resources[resource.metadata.handle]
            else {
                throw RuntimeOpaqueResourceError.resourceUnavailable(
                    resource.metadata.handle
                )
            }
            _ = try validateResource(
                namespace: resource.metadata.handle.namespace,
                declaration: resource.declaration,
                data: data,
                storage: current.storage,
                ownerModuleID: resource.metadata.ownerModuleID,
                ownerGeneration: resource.ownerGeneration,
                registrationID: resource.registrationID
            )
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrentRegistration(
                resource,
                expectedRuntimeGeneration: expectedRuntimeGeneration
            ) else {
                throw RuntimeOpaqueResourceError.resourceUnavailable(
                    resource.metadata.handle
                )
            }
            recordValidationFaultIfNeeded(for: resource, error: error)
            throw error
        }
    }

    private func isCurrentRegistration(
        _ resource: StoredResource,
        expectedRuntimeGeneration: UInt64
    ) -> Bool {
        guard isRuntimeActive,
              runtimeGeneration == expectedRuntimeGeneration,
              let current = resources[resource.metadata.handle],
              current.ownerGeneration == resource.ownerGeneration,
              current.registrationID == resource.registrationID,
              current.metadata.registrationID == resource.registrationID,
              current.declaration == resource.declaration,
              let owner = namespaceOwners[resource.metadata.handle.namespace],
              owner.moduleID == resource.metadata.ownerModuleID,
              owner.generation == resource.ownerGeneration,
              owner.registrationID == resource.registrationID
        else { return false }
        return true
    }

    private func recordValidationFaultIfNeeded(
        for resource: StoredResource,
        error: Error
    ) {
        guard resource.declaration.isRequired,
              !Self.isStaleOrCancellationFailure(error),
              validationFaults[resource.metadata.handle]?.registrationID
                != resource.registrationID
        else { return }
        validationFaults[resource.metadata.handle] = OpaqueResourceValidationFault(
            handle: resource.metadata.handle,
            ownerModuleID: resource.metadata.ownerModuleID,
            registrationID: resource.registrationID,
            code: Self.validationFaultCode(for: error),
            requiredBaseFailure: error as? RequiredThemeResourceFailureDTO
        )
        revision &+= 1
        notifyObservers()
    }

    private static func isStaleOrCancellationFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let runtimeError = error as? RuneScribeRuntimeError else { return false }
        switch runtimeError {
        case .runtimeNotRunning, .moduleNotActive, .staleClient, .contextInactive,
             .operationCancelled:
            return true
        default:
            return false
        }
    }

    private static func validationFaultCode(
        for error: Error
    ) -> OpaqueResourceValidationFaultCode {
        if let failure = error as? RequiredThemeResourceFailureDTO {
            return failure.errorCode == .resourceUnavailable
                ? .missingRequiredResource
                : .resourceMismatch
        }
        if let failure = error as? RuntimeVerifiedApplicationResourceFailure {
            if case .resourceUnavailable = failure { return .missingRequiredResource }
            return .resourceMismatch
        }
        guard let resourceError = error as? RuntimeOpaqueResourceError else {
            return .resourceMismatch
        }
        switch resourceError {
        case .missingRequiredResource, .namespaceUnavailable, .resourceUnavailable:
            return .missingRequiredResource
        default:
            return .resourceMismatch
        }
    }

    fileprivate func changes(
        for lease: RuntimeOpaqueResourceLease
    ) throws -> AsyncStream<UInt64> {
        _ = try validate(lease)
        precondition(nextObserverID < UInt64.max, "Resource observer ID exhausted.")
        nextObserverID += 1
        let observerID = nextObserverID
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[observerID] = Observer(lease: lease, continuation: continuation)
            continuation.yield(revision)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    private func validate(_ lease: RuntimeOpaqueResourceLease) throws -> ActiveModule {
        guard isRuntimeActive, runtimeGeneration == lease.runtimeGeneration else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard let module = activeModules[lease.sourceModuleID],
              module.generation == lease.sourceModuleGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        return module
    }

    private func authorize(
        _ descriptor: ModuleDescriptor,
        capability: CapabilityIdentifier,
        policy: RuntimePolicy
    ) throws {
        guard descriptor.requestedCapabilities.contains(capability),
              policy.capabilities.allows(capability, for: descriptor.policyClass)
        else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: descriptor.moduleID,
                capability: capability
            )
        }
    }

    private func validateResource(
        namespace: OpaqueResourceNamespaceID,
        declaration: OpaqueResourceDeclaration,
        data: Data,
        storage: StoredResource.Storage,
        ownerModuleID: ModuleIdentifier,
        ownerGeneration: UInt64,
        registrationID: UInt64
    ) throws -> StoredResource {
        let resource = try validateDeclaration(
            namespace: namespace,
            declaration: declaration,
            storage: storage,
            ownerModuleID: ownerModuleID,
            ownerGeneration: ownerGeneration,
            registrationID: registrationID
        )
        guard declaration.byteCount == data.count else {
            throw RuntimeOpaqueResourceError.byteCountMismatch(declaration.resourceID)
        }
        let digest = RuntimeIntegrityDigest.sha256Hex(data)
        guard digest == declaration.sha256 else {
            throw RuntimeOpaqueResourceError.hashMismatch(declaration.resourceID)
        }
        try Self.validateMediaContent(declaration, data: data)
        try validatePixelSize(
            declaration,
            data: data,
            category: resource.metadata.category
        )
        return resource
    }

    private func validateDeclaration(
        namespace: OpaqueResourceNamespaceID,
        declaration: OpaqueResourceDeclaration,
        storage: StoredResource.Storage,
        ownerModuleID: ModuleIdentifier,
        ownerGeneration: UInt64,
        registrationID: UInt64
    ) throws -> StoredResource {
        guard Self.validateIdentifier(declaration.resourceID.rawValue) else {
            throw RuntimeOpaqueResourceError.invalidResourceID(declaration.resourceID)
        }
        guard Self.validateIdentifier(declaration.semanticRole) else {
            throw RuntimeOpaqueResourceError.invalidSemanticRole(declaration.semanticRole)
        }
        guard declaration.byteCount >= 0 else {
            throw RuntimeOpaqueResourceError.invalidByteCount(declaration.resourceID)
        }
        guard declaration.sha256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw RuntimeOpaqueResourceError.invalidSHA256(declaration.resourceID)
        }

        let category = try Self.category(for: declaration.mediaType)
        try validatePerResourceBudget(declaration, category: category)
        try validateDeclaredPixelSize(declaration, category: category)
        let handle = OpaqueResourceHandle(
            namespace: namespace,
            resourceID: declaration.resourceID
        )
        return StoredResource(
            metadata: OpaqueResourceMetadata(
                handle: handle,
                ownerModuleID: ownerModuleID,
                registrationID: registrationID,
                semanticRole: declaration.semanticRole,
                mediaType: declaration.mediaType,
                category: category,
                byteCount: declaration.byteCount,
                sha256: declaration.sha256,
                pixelSize: declaration.pixelSize
            ),
            declaration: declaration,
            storage: storage,
            ownerGeneration: ownerGeneration,
            registrationID: registrationID
        )
    }

    private func validateDeclaredPixelSize(
        _ declaration: OpaqueResourceDeclaration,
        category: OpaqueResourceCategory
    ) throws {
        guard category == .image else {
            guard declaration.pixelSize == nil else {
                throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
            }
            return
        }
        if declaration.mediaType == .pdf, declaration.pixelSize == nil {
            return
        }
        guard let expected = declaration.pixelSize,
              expected.width > 0,
              expected.height > 0
        else {
            throw RuntimeOpaqueResourceError.pixelSizeRequired(declaration.resourceID)
        }
        guard expected.width <= budget.maximumImageDimension,
              expected.height <= budget.maximumImageDimension
        else {
            throw RuntimeOpaqueResourceError.imageDimensionExceeded(declaration.resourceID)
        }
    }

    private func validatePerResourceBudget(
        _ declaration: OpaqueResourceDeclaration,
        category: OpaqueResourceCategory
    ) throws {
        let limit: Int?
        switch category {
        case .descriptor:
            limit = budget.maximumDescriptorBytes
        case .image:
            limit = budget.maximumImageBytes
        case .font:
            limit = budget.maximumFontBytes
        case .animation:
            limit = budget.maximumAnimationCatalogBytes
        case .sound:
            limit = budget.maximumSoundBytes
        }
        if let limit, declaration.byteCount > limit {
            throw RuntimeOpaqueResourceError.resourceBudgetExceeded(declaration.resourceID)
        }
    }

    private func validatePixelSize(
        _ declaration: OpaqueResourceDeclaration,
        data: Data,
        category: OpaqueResourceCategory
    ) throws {
        guard category == .image else {
            guard declaration.pixelSize == nil else {
                throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
            }
            return
        }
        if declaration.mediaType == .pdf {
            guard let dimensions = Self.pdfDimensions(data) else {
                throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
            }
            guard dimensions.width > 0,
                  dimensions.height > 0,
                  dimensions.width <= Double(budget.maximumImageDimension),
                  dimensions.height <= Double(budget.maximumImageDimension)
            else {
                throw RuntimeOpaqueResourceError.imageDimensionExceeded(
                    declaration.resourceID
                )
            }
            if let expected = declaration.pixelSize {
                guard Int(dimensions.width.rounded()) == expected.width,
                      Int(dimensions.height.rounded()) == expected.height
                else {
                    throw RuntimeOpaqueResourceError.pixelSizeMismatch(
                        declaration.resourceID
                    )
                }
            }
            return
        }
        guard let expected = declaration.pixelSize,
              expected.width > 0,
              expected.height > 0
        else {
            throw RuntimeOpaqueResourceError.pixelSizeRequired(declaration.resourceID)
        }
        guard expected.width <= budget.maximumImageDimension,
              expected.height <= budget.maximumImageDimension
        else {
            throw RuntimeOpaqueResourceError.imageDimensionExceeded(declaration.resourceID)
        }
        if declaration.mediaType == .heif || declaration.mediaType == .heic {
            let candidates = Self.heifDimensionCandidates(data)
            guard !candidates.isEmpty else {
                throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
            }
            guard candidates.allSatisfy({
                $0.width <= budget.maximumImageDimension
                    && $0.height <= budget.maximumImageDimension
            }) else {
                throw RuntimeOpaqueResourceError.imageDimensionExceeded(declaration.resourceID)
            }
            guard candidates.contains(where: {
                $0.width == expected.width && $0.height == expected.height
            }) else {
                throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
            }
            return
        }
        guard let dimensions = Self.rasterDimensions(
            data,
            mediaType: declaration.mediaType
        ),
            dimensions.width == expected.width,
            dimensions.height == expected.height
        else {
            throw RuntimeOpaqueResourceError.pixelSizeMismatch(declaration.resourceID)
        }
    }

    private func validateBudgets(_ pending: [StoredResource]) throws {
        guard let ownerModuleID = pending.first?.metadata.ownerModuleID else { return }
        let existing = resources.values.filter {
            $0.metadata.ownerModuleID == ownerModuleID
        }
        let combined = existing + pending
        let moduleBytes = combined.reduce(0) { $0 + $1.metadata.byteCount }
        guard moduleBytes <= budget.maximumModuleBytes else {
            throw RuntimeOpaqueResourceError.moduleBudgetExceeded
        }
        for category in OpaqueResourceCategory.allCases {
            let bytes = combined
                .filter { $0.metadata.category == category }
                .reduce(0) { $0 + $1.metadata.byteCount }
            let limit: Int
            switch category {
            case .descriptor:
                continue
            case .image:
                limit = budget.maximumImageCatalogBytes
            case .font:
                limit = budget.maximumFontCatalogBytes
            case .animation:
                limit = budget.maximumAnimationCatalogBytes
            case .sound:
                limit = budget.maximumSoundCatalogBytes
            }
            guard bytes <= limit else {
                throw RuntimeOpaqueResourceError.catalogBudgetExceeded(category)
            }
        }
    }

    private static func uniqueDeclarations(
        _ values: [OpaqueResourceDeclaration]
    ) throws -> [OpaqueResourceID: OpaqueResourceDeclaration] {
        var result: [OpaqueResourceID: OpaqueResourceDeclaration] = [:]
        for value in values {
            guard result.updateValue(value, forKey: value.resourceID) == nil else {
                throw RuntimeOpaqueResourceError.duplicateResourceID(value.resourceID)
            }
        }
        return result
    }

    private static func uniquePayloads(
        _ values: [OpaqueResourcePayload]
    ) throws -> [OpaqueResourceID: Data] {
        var result: [OpaqueResourceID: Data] = [:]
        for value in values {
            guard result.updateValue(value.data, forKey: value.resourceID) == nil else {
                throw RuntimeOpaqueResourceError.duplicatePayload(value.resourceID)
            }
        }
        return result
    }

    private static func category(
        for mediaType: OpaqueResourceMediaType
    ) throws -> OpaqueResourceCategory {
        switch mediaType {
        case .json:
            .descriptor
        case .png, .heif, .heic, .pdf:
            .image
        case .trueTypeFont, .openTypeFont:
            .font
        case .mp4, .quickTime:
            .animation
        case .m4a, .caf, .wav, .xWav:
            .sound
        default:
            throw RuntimeOpaqueResourceError.unsupportedMediaType(mediaType)
        }
    }

    private static func validateMediaContent(
        _ declaration: OpaqueResourceDeclaration,
        data: Data
    ) throws {
        let matches: Bool
        switch declaration.mediaType {
        case .json:
            matches = (try? JSONSerialization.jsonObject(with: data)) != nil
        case .png:
            matches = pngDimensions(data) != nil
        case .heif, .heic:
            matches = isISOBaseMediaFile(data)
                && !heifDimensionCandidates(data).isEmpty
        case .pdf:
            matches = isValidPDF(data)
        case .trueTypeFont:
            matches = (data.starts(with: [0x00, 0x01, 0x00, 0x00])
                || data.starts(with: Data("true".utf8)))
                && isValidFont(data)
        case .openTypeFont:
            matches = data.starts(with: Data("OTTO".utf8)) && isValidFont(data)
        case .mp4:
            matches = isValidISOBaseMediaFile(
                data,
                acceptedBrands: ["isom", "iso2", "mp41", "mp42", "M4V ", "avc1"]
            )
        case .quickTime:
            matches = isValidISOBaseMediaFile(data, acceptedBrands: ["qt  "])
        case .m4a:
            matches = isValidISOBaseMediaFile(
                data,
                acceptedBrands: ["M4A ", "M4B ", "isom", "mp42"]
            )
        case .caf:
            matches = data.starts(with: Data("caff".utf8))
        case .wav, .xWav:
            matches = data.starts(with: Data("RIFF".utf8))
                && data.count >= 12
                && data.subdata(in: 8 ..< 12) == Data("WAVE".utf8)
        default:
            matches = false
        }
        guard matches else {
            throw RuntimeOpaqueResourceError.mediaTypeMismatch(declaration.resourceID)
        }
    }

    private static func isISOBaseMediaFile(_ data: Data) -> Bool {
        data.count >= 12
            && data.subdata(in: 4 ..< 8) == Data("ftyp".utf8)
    }

    private static func isValidPDF(_ data: Data) -> Bool {
        guard data.starts(with: Data("%PDF-".utf8)),
              Data(data.suffix(1_024)).range(of: Data("%%EOF".utf8)) != nil,
              pdfDimensions(data) != nil
        else { return false }
        return true
    }

    private static func isValidFont(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let tableCount = readUInt16(data, at: 4)
        guard tableCount > 0,
              tableCount <= 4_096,
              12 + tableCount * 16 <= data.count
        else { return false }

        var tables: [String: (offset: Int, length: Int)] = [:]
        for index in 0 ..< tableCount {
            let recordOffset = 12 + index * 16
            guard let tag = String(
                data: data.subdata(in: recordOffset ..< recordOffset + 4),
                encoding: .ascii
            ) else { return false }
            let offset = readUInt32(data, at: recordOffset + 8)
            let length = readUInt32(data, at: recordOffset + 12)
            guard length > 0,
                  offset >= 0,
                  offset <= data.count,
                  length <= data.count - offset,
                  tables[tag] == nil
            else { return false }
            tables[tag] = (offset, length)
        }
        guard let head = tables["head"], head.length >= 20,
              let maxp = tables["maxp"], maxp.length >= 6,
              tables["cmap"] != nil,
              readUInt16(data, at: head.offset + 18) > 0,
              readUInt16(data, at: maxp.offset + 4) > 0,
              (tables["glyf"] != nil && tables["loca"] != nil
                  || tables["CFF "] != nil
                  || tables["CFF2"] != nil)
        else { return false }
        return true
    }

    private static func rasterDimensions(
        _ data: Data,
        mediaType: OpaqueResourceMediaType
    ) -> (width: Int, height: Int)? {
        switch mediaType {
        case .png:
            pngDimensions(data)
        case .heif, .heic:
            heifDimensions(data)
        default:
            nil
        }
    }

    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.count >= 33, data.starts(with: signature) else { return nil }
        var offset = 8
        var dimensions: (width: Int, height: Int)?
        var sawImageEnd = false
        while offset + 12 <= data.count {
            let length = readUInt32(data, at: offset)
            guard length >= 0,
                  length <= data.count - offset - 12
            else { return nil }
            let typeRange = offset + 4 ..< offset + 8
            guard let type = String(
                data: data.subdata(in: typeRange),
                encoding: .ascii
            ) else { return nil }
            if offset == 8 {
                guard type == "IHDR", length == 13 else { return nil }
                let width = readUInt32(data, at: offset + 8)
                let height = readUInt32(data, at: offset + 12)
                guard width > 0, height > 0 else { return nil }
                dimensions = (width, height)
            }
            offset += 12 + length
            if type == "IEND" {
                guard length == 0, offset == data.count else { return nil }
                sawImageEnd = true
                break
            }
        }
        guard sawImageEnd else { return nil }
        return dimensions
    }

    private static func heifDimensions(_ data: Data) -> (width: Int, height: Int)? {
        heifDimensionCandidates(data).first
    }

    /// HEIF containers may place auxiliary-image properties before the primary image.
    /// Retain every structurally valid `ispe` candidate so validation can match the
    /// descriptor's declared primary dimensions without accepting an arbitrary first box.
    private static func heifDimensionCandidates(
        _ data: Data
    ) -> [(width: Int, height: Int)] {
        guard isISOBaseMediaFile(data) else { return [] }
        let marker = Data("ispe".utf8)
        var searchStart = data.startIndex
        var dimensions: [(width: Int, height: Int)] = []
        while searchStart < data.endIndex,
              let range = data.range(of: marker, in: searchStart ..< data.endIndex)
        {
            let typeOffset = range.lowerBound
            if typeOffset >= 4, typeOffset + 16 <= data.count {
                let boxSize = readUInt32(data, at: typeOffset - 4)
                let width = readUInt32(data, at: typeOffset + 8)
                let height = readUInt32(data, at: typeOffset + 12)
                if boxSize >= 20, width > 0, height > 0 {
                    dimensions.append((width, height))
                }
            }
            searchStart = range.upperBound
        }
        return dimensions
    }

    private static func pdfDimensions(_ data: Data) -> (width: Double, height: Double)? {
        RuntimePDFResourceValidation.singlePageDimensions(data)
    }

    private static func isValidISOBaseMediaFile(
        _ data: Data,
        acceptedBrands: Set<String>
    ) -> Bool {
        guard isISOBaseMediaFile(data), data.count >= 16 else { return false }
        let firstSize = readUInt32(data, at: 0)
        guard firstSize >= 16,
              firstSize <= data.count,
              let majorBrand = String(
                  data: data.subdata(in: 8 ..< 12),
                  encoding: .ascii
              ),
              acceptedBrands.contains(majorBrand)
        else { return false }

        var offset = firstSize
        var foundMediaBox = false
        while offset + 8 <= data.count {
            let size = readUInt32(data, at: offset)
            guard size >= 8, offset + size <= data.count else { return false }
            let type = String(
                data: data.subdata(in: offset + 4 ..< offset + 8),
                encoding: .ascii
            )
            if type == "moov" || type == "mdat" {
                foundMediaBox = true
            }
            offset += size
        }
        return offset == data.count && foundMediaBox
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset ..< offset + 4].reduce(0) {
            ($0 << 8) | Int($1)
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return data[offset ..< offset + 2].reduce(0) {
            ($0 << 8) | Int($1)
        }
    }

    private static func validateIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil
    }

    private func notifyObservers() {
        var invalidObserverIDs: [UInt64] = []
        for (observerID, observer) in observers {
            do {
                _ = try validate(observer.lease)
                observer.continuation.yield(revision)
            } catch {
                observer.continuation.finish()
                invalidObserverIDs.append(observerID)
            }
        }
        invalidObserverIDs.forEach { observers.removeValue(forKey: $0) }
    }

    private func removeObserver(_ observerID: UInt64) {
        observers.removeValue(forKey: observerID)
    }

    private func finishObservers() {
        let active = observers.values
        observers.removeAll(keepingCapacity: false)
        active.forEach { $0.continuation.finish() }
    }
}

private extension Bool {
    func orThrow(_ error: @autoclosure () -> RuntimeOpaqueResourceError) throws {
        guard self else { throw error() }
    }
}

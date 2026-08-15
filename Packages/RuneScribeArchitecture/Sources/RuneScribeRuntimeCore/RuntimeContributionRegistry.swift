import Foundation
import RuneScribeContracts

public struct RuntimeContributionTypeID: RawRepresentable, Codable, Hashable,
    Sendable, Comparable, CustomStringConvertible
{
    public static let maximumUTF8Count = 96

    public let rawValue: String

    public init?(rawValue: String) {
        guard RuntimeContributionIdentifierSyntax.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid runtime contribution type identifier."
            )
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RuntimeContributionKey: RawRepresentable, Codable, Hashable,
    Sendable, Comparable, CustomStringConvertible
{
    public static let maximumUTF8Count = 96

    public let rawValue: String

    public init?(rawValue: String) {
        guard RuntimeContributionIdentifierSyntax.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid runtime contribution key."
            )
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RuntimeContributionType<Value: Sendable>: Hashable, Sendable {
    public let id: RuntimeContributionTypeID

    // RuntimeCore owns the type catalog. Module targets can use published
    // catalog entries, but cannot manufacture a type token for an arbitrary
    // capability-bearing Swift value.
    init(id: RuntimeContributionTypeID) {
        self.id = id
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct RuntimeContributionOwner: Codable, Hashable, Sendable {
    public let moduleID: ModuleIdentifier
    public let moduleGeneration: UInt64
    public let runtimeGeneration: UInt64

    public init(
        moduleID: ModuleIdentifier,
        moduleGeneration: UInt64,
        runtimeGeneration: UInt64
    ) {
        self.moduleID = moduleID
        self.moduleGeneration = moduleGeneration
        self.runtimeGeneration = runtimeGeneration
    }
}

public struct RuntimeContributionSnapshotEntry<Value: Sendable>: Sendable {
    public let typeID: RuntimeContributionTypeID
    public let key: RuntimeContributionKey
    public let value: Value
    public let owner: RuntimeContributionOwner
    public let publishedRevision: UInt64

    public init(
        typeID: RuntimeContributionTypeID,
        key: RuntimeContributionKey,
        value: Value,
        owner: RuntimeContributionOwner,
        publishedRevision: UInt64
    ) {
        self.typeID = typeID
        self.key = key
        self.value = value
        self.owner = owner
        self.publishedRevision = publishedRevision
    }
}

extension RuntimeContributionSnapshotEntry: Equatable where Value: Equatable {}
extension RuntimeContributionSnapshotEntry: Hashable where Value: Hashable {}

public struct RuntimeContributionSnapshot<Value: Sendable>: Sendable {
    public let revision: UInt64
    public let runtimeGeneration: UInt64
    public let entries: [RuntimeContributionSnapshotEntry<Value>]

    public init(
        revision: UInt64,
        runtimeGeneration: UInt64,
        entries: [RuntimeContributionSnapshotEntry<Value>]
    ) {
        self.revision = revision
        self.runtimeGeneration = runtimeGeneration
        self.entries = entries.sorted { lhs, rhs in
            if lhs.key != rhs.key {
                return lhs.key < rhs.key
            }
            if lhs.owner.moduleID != rhs.owner.moduleID {
                return lhs.owner.moduleID < rhs.owner.moduleID
            }
            return lhs.publishedRevision < rhs.publishedRevision
        }
    }
}

extension RuntimeContributionSnapshot: Equatable where Value: Equatable {}

public enum RuntimeContributionRegistryError: Error, Equatable, Sendable {
    case duplicateKey(RuntimeContributionKey)
    case keyTypeMismatch(
        key: RuntimeContributionKey,
        expected: RuntimeContributionTypeID,
        actual: RuntimeContributionTypeID
    )
    case valueTypeMismatch(RuntimeContributionTypeID)
    case ownershipDenied(
        key: RuntimeContributionKey,
        ownerModuleID: ModuleIdentifier
    )
    case canonicalIdentityMismatch(RuntimeContributionKey)
    case canonicalKeyMismatch(RuntimeContributionKey)
    case canonicalCriticalityMismatch(RuntimeContributionKey)
    case canonicalDescriptorTooLarge(maximumBytes: Int)
}

public struct RuntimeContributionPublisherClient: Sendable {
    private let registry: RuntimeContributionRegistry
    private let lease: RuntimeContributionClientLease

    fileprivate init(
        registry: RuntimeContributionRegistry,
        lease: RuntimeContributionClientLease
    ) {
        self.registry = registry
        self.lease = lease
    }

    public func publish<Value: Sendable>(
        _ value: Value,
        type: RuntimeContributionType<Value>,
        key: RuntimeContributionKey
    ) async throws -> RuntimeContributionSnapshotEntry<Value> {
        try await registry.publish(value, type: type, key: key, lease: lease)
    }

    @discardableResult
    public func remove<Value: Sendable>(
        key: RuntimeContributionKey,
        type: RuntimeContributionType<Value>
    ) async throws -> Bool {
        try await registry.remove(key: key, type: type, lease: lease)
    }
}

public struct RuntimeContributionReaderClient: Sendable {
    private let registry: RuntimeContributionRegistry
    private let lease: RuntimeContributionClientLease

    fileprivate init(
        registry: RuntimeContributionRegistry,
        lease: RuntimeContributionClientLease
    ) {
        self.registry = registry
        self.lease = lease
    }

    public func snapshot<Value: Sendable>(
        for type: RuntimeContributionType<Value>
    ) async throws -> RuntimeContributionSnapshot<Value> {
        try await registry.snapshot(for: type, lease: lease)
    }

    public func entry<Value: Sendable>(
        for key: RuntimeContributionKey,
        as type: RuntimeContributionType<Value>
    ) async throws -> RuntimeContributionSnapshotEntry<Value>? {
        try await registry.entry(for: key, as: type, lease: lease)
    }

    public func changes() async throws -> AsyncStream<UInt64> {
        try await registry.changes(for: lease)
    }
}

private enum RuntimeContributionIdentifierSyntax {
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= RuntimeContributionTypeID.maximumUTF8Count
        else {
            return false
        }

        var previousWasSeparator = false
        for (index, byte) in bytes.enumerated() {
            let isLowercaseLetter = (0x61 ... 0x7A).contains(byte)
            let isNumber = (0x30 ... 0x39).contains(byte)
            if isLowercaseLetter || isNumber {
                previousWasSeparator = false
                continue
            }

            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isSeparator,
                  index > 0,
                  index < bytes.count - 1,
                  !previousWasSeparator
            else {
                return false
            }
            previousWasSeparator = true
        }
        return true
    }
}

private enum RuntimeContributionClientAccess: Sendable {
    case publish
    case read
}

private struct RuntimeContributionClientLease: Sendable {
    let owner: RuntimeContributionOwner
    let access: RuntimeContributionClientAccess
}

private protocol RuntimeContributionValueBox: Sendable {}

private struct RuntimeTypedContributionValue<Value: Sendable>:
    RuntimeContributionValueBox
{
    let value: Value
}

private struct StoredRuntimeContribution: Sendable {
    let typeID: RuntimeContributionTypeID
    let key: RuntimeContributionKey
    let valueType: ObjectIdentifier
    let valueBox: any RuntimeContributionValueBox
    let owner: RuntimeContributionOwner
    let publishedRevision: UInt64
}

private struct ActiveContributionModule: Sendable {
    let descriptor: ModuleDescriptor
    let generation: UInt64
}

private struct RuntimeContributionObserver: Sendable {
    let lease: RuntimeContributionClientLease
    let continuation: AsyncStream<UInt64>.Continuation
}

struct RuntimeContributionCanonicalRule: @unchecked Sendable {
    let valueType: ObjectIdentifier
    private let validateValue: @Sendable (
        Any,
        RuntimeContributionKey,
        ModuleDescriptor
    ) throws -> Void

    init<Value: Sendable>(
        valueType: Value.Type,
        validate: @escaping @Sendable (
            Value,
            RuntimeContributionKey,
            ModuleDescriptor
        ) throws -> Void
    ) {
        self.valueType = ObjectIdentifier(valueType)
        validateValue = { value, key, descriptor in
            guard let typed = value as? Value else {
                throw RuntimeContributionRegistryError.valueTypeMismatch(
                    RuntimeContributionTypeID(rawValue: "runtime.invalid-type")!
                )
            }
            try validate(typed, key, descriptor)
        }
    }

    func validate<Value: Sendable>(
        _ value: Value,
        key: RuntimeContributionKey,
        descriptor: ModuleDescriptor
    ) throws {
        try validateValue(value, key, descriptor)
    }
}

actor RuntimeContributionRegistry {
    typealias CapabilityAuthorization = @Sendable (
        ModuleDescriptor,
        CapabilityIdentifier
    ) -> Bool

    private let publishCapabilityID: CapabilityIdentifier
    private let readCapabilityID: CapabilityIdentifier
    private let authorization: CapabilityAuthorization
    private let canonicalRules: [
        RuntimeContributionTypeID: RuntimeContributionCanonicalRule
    ]
    private var runtimeGeneration: UInt64 = 0
    private var runtimeIsActive = false
    private var revision: UInt64 = 0
    private var activeModules: [ModuleIdentifier: ActiveContributionModule] = [:]
    private var entries: [RuntimeContributionKey: StoredRuntimeContribution] = [:]
    private var valueTypes: [RuntimeContributionTypeID: ObjectIdentifier] = [:]
    private var nextObserverID: UInt64 = 0
    private var observers: [UInt64: RuntimeContributionObserver] = [:]

    init(
        publishCapabilityID: CapabilityIdentifier,
        readCapabilityID: CapabilityIdentifier,
        authorization: @escaping CapabilityAuthorization,
        canonicalRules: [
            RuntimeContributionTypeID: RuntimeContributionCanonicalRule
        ] = [:]
    ) {
        self.publishCapabilityID = publishCapabilityID
        self.readCapabilityID = readCapabilityID
        self.authorization = authorization
        self.canonicalRules = canonicalRules
        valueTypes = canonicalRules.mapValues(\.valueType)
    }

    @discardableResult
    func activateRuntime() -> UInt64 {
        finishObservers()
        if !entries.isEmpty {
            entries.removeAll(keepingCapacity: true)
            advanceRevision()
        }
        activeModules.removeAll(keepingCapacity: true)
        valueTypes = canonicalRules.mapValues(\.valueType)
        runtimeGeneration &+= 1
        runtimeIsActive = true
        return runtimeGeneration
    }

    func deactivateRuntime() {
        if !entries.isEmpty {
            entries.removeAll(keepingCapacity: true)
            advanceRevision()
        }
        activeModules.removeAll(keepingCapacity: true)
        valueTypes = canonicalRules.mapValues(\.valueType)
        runtimeIsActive = false
        finishObservers()
    }

    func currentGeneration() -> UInt64 {
        runtimeGeneration
    }

    func activateModule(
        descriptor: ModuleDescriptor,
        generation: UInt64
    ) throws {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }

        if let previous = activeModules[descriptor.moduleID],
           previous.generation != generation
        {
            let previousOwner = RuntimeContributionOwner(
                moduleID: descriptor.moduleID,
                moduleGeneration: previous.generation,
                runtimeGeneration: runtimeGeneration
            )
            if removeEntries(ownedBy: previousOwner) {
                advanceRevision()
            }
        }

        activeModules[descriptor.moduleID] = ActiveContributionModule(
            descriptor: descriptor,
            generation: generation
        )
    }

    func invalidateModule(
        _ moduleID: ModuleIdentifier,
        generation: UInt64
    ) {
        guard activeModules[moduleID]?.generation == generation else {
            return
        }
        activeModules.removeValue(forKey: moduleID)
        let owner = RuntimeContributionOwner(
            moduleID: moduleID,
            moduleGeneration: generation,
            runtimeGeneration: runtimeGeneration
        )
        if removeEntries(ownedBy: owner) {
            advanceRevision()
        }
        pruneObservers()
    }

    func makePublisherClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration expectedRuntimeGeneration: UInt64
    ) throws -> RuntimeContributionPublisherClient {
        let lease = RuntimeContributionClientLease(
            owner: RuntimeContributionOwner(
                moduleID: sourceModuleID,
                moduleGeneration: sourceModuleGeneration,
                runtimeGeneration: expectedRuntimeGeneration
            ),
            access: .publish
        )
        _ = try validate(lease)
        return RuntimeContributionPublisherClient(registry: self, lease: lease)
    }

    func makeReaderClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration expectedRuntimeGeneration: UInt64
    ) throws -> RuntimeContributionReaderClient {
        let lease = RuntimeContributionClientLease(
            owner: RuntimeContributionOwner(
                moduleID: sourceModuleID,
                moduleGeneration: sourceModuleGeneration,
                runtimeGeneration: expectedRuntimeGeneration
            ),
            access: .read
        )
        _ = try validate(lease)
        return RuntimeContributionReaderClient(registry: self, lease: lease)
    }

    fileprivate func publish<Value: Sendable>(
        _ value: Value,
        type: RuntimeContributionType<Value>,
        key: RuntimeContributionKey,
        lease: RuntimeContributionClientLease
    ) throws -> RuntimeContributionSnapshotEntry<Value> {
        let activeModule = try validate(lease)
        try canonicalRules[type.id]?.validate(
            value,
            key: key,
            descriptor: activeModule.descriptor
        )
        guard entries[key] == nil else {
            throw RuntimeContributionRegistryError.duplicateKey(key)
        }
        try validateValueType(Value.self, for: type.id)

        let publishedRevision = nextRevision()
        let stored = StoredRuntimeContribution(
            typeID: type.id,
            key: key,
            valueType: ObjectIdentifier(Value.self),
            valueBox: RuntimeTypedContributionValue(value: value),
            owner: lease.owner,
            publishedRevision: publishedRevision
        )
        valueTypes[type.id] = stored.valueType
        entries[key] = stored
        revision = publishedRevision
        notifyObservers()
        return snapshotEntry(from: stored, value: value)
    }

    fileprivate func remove<Value: Sendable>(
        key: RuntimeContributionKey,
        type: RuntimeContributionType<Value>,
        lease: RuntimeContributionClientLease
    ) throws -> Bool {
        _ = try validate(lease)
        guard let stored = entries[key] else {
            return false
        }
        guard stored.typeID == type.id else {
            throw RuntimeContributionRegistryError.keyTypeMismatch(
                key: key,
                expected: type.id,
                actual: stored.typeID
            )
        }
        try validateValueType(Value.self, for: type.id)
        guard stored.owner == lease.owner else {
            throw RuntimeContributionRegistryError.ownershipDenied(
                key: key,
                ownerModuleID: lease.owner.moduleID
            )
        }

        let removalRevision = nextRevision()
        entries.removeValue(forKey: key)
        revision = removalRevision
        notifyObservers()
        return true
    }

    fileprivate func snapshot<Value: Sendable>(
        for type: RuntimeContributionType<Value>,
        lease: RuntimeContributionClientLease
    ) throws -> RuntimeContributionSnapshot<Value> {
        _ = try validate(lease)
        try validateValueType(Value.self, for: type.id)
        let typedEntries: [RuntimeContributionSnapshotEntry<Value>] =
            try entries.values.compactMap { stored in
            guard stored.typeID == type.id else { return nil }
            return try decode(stored, as: Value.self)
        }
        return RuntimeContributionSnapshot(
            revision: revision,
            runtimeGeneration: runtimeGeneration,
            entries: typedEntries
        )
    }

    fileprivate func entry<Value: Sendable>(
        for key: RuntimeContributionKey,
        as type: RuntimeContributionType<Value>,
        lease: RuntimeContributionClientLease
    ) throws -> RuntimeContributionSnapshotEntry<Value>? {
        _ = try validate(lease)
        guard let stored = entries[key] else {
            try validateValueType(Value.self, for: type.id)
            return nil
        }
        guard stored.typeID == type.id else {
            throw RuntimeContributionRegistryError.keyTypeMismatch(
                key: key,
                expected: type.id,
                actual: stored.typeID
            )
        }
        try validateValueType(Value.self, for: type.id)
        return try decode(stored, as: Value.self)
    }

    fileprivate func changes(
        for lease: RuntimeContributionClientLease
    ) throws -> AsyncStream<UInt64> {
        _ = try validate(lease)
        precondition(nextObserverID < UInt64.max, "Contribution observer ID exhausted.")
        nextObserverID += 1
        let observerID = nextObserverID
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[observerID] = RuntimeContributionObserver(
                lease: lease,
                continuation: continuation
            )
            continuation.yield(revision)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    private func validate(
        _ lease: RuntimeContributionClientLease
    ) throws -> ActiveContributionModule {
        guard runtimeIsActive,
              runtimeGeneration == lease.owner.runtimeGeneration
        else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard let activeModule = activeModules[lease.owner.moduleID],
              activeModule.generation == lease.owner.moduleGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.owner.moduleID)
        }

        let capability: CapabilityIdentifier
        switch lease.access {
        case .publish:
            capability = publishCapabilityID
        case .read:
            capability = readCapabilityID
        }
        guard activeModule.descriptor.requestedCapabilities.contains(capability),
              authorization(activeModule.descriptor, capability)
        else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: lease.owner.moduleID,
                capability: capability
            )
        }
        return activeModule
    }

    private func validateValueType<Value: Sendable>(
        _: Value.Type,
        for typeID: RuntimeContributionTypeID
    ) throws {
        guard let registeredType = valueTypes[typeID] else {
            return
        }
        guard registeredType == ObjectIdentifier(Value.self) else {
            throw RuntimeContributionRegistryError.valueTypeMismatch(typeID)
        }
    }

    private func decode<Value: Sendable>(
        _ stored: StoredRuntimeContribution,
        as _: Value.Type
    ) throws -> RuntimeContributionSnapshotEntry<Value> {
        guard stored.valueType == ObjectIdentifier(Value.self),
              let box = stored.valueBox as? RuntimeTypedContributionValue<Value>
        else {
            throw RuntimeContributionRegistryError.valueTypeMismatch(stored.typeID)
        }
        return snapshotEntry(from: stored, value: box.value)
    }

    private func snapshotEntry<Value: Sendable>(
        from stored: StoredRuntimeContribution,
        value: Value
    ) -> RuntimeContributionSnapshotEntry<Value> {
        RuntimeContributionSnapshotEntry(
            typeID: stored.typeID,
            key: stored.key,
            value: value,
            owner: stored.owner,
            publishedRevision: stored.publishedRevision
        )
    }

    private func removeEntries(ownedBy owner: RuntimeContributionOwner) -> Bool {
        let ownedKeys = entries.compactMap { key, entry in
            entry.owner == owner ? key : nil
        }
        for key in ownedKeys {
            entries.removeValue(forKey: key)
        }
        return !ownedKeys.isEmpty
    }

    private func nextRevision() -> UInt64 {
        precondition(revision < UInt64.max, "Runtime contribution revision exhausted.")
        return revision + 1
    }

    private func advanceRevision() {
        revision = nextRevision()
        notifyObservers()
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

    private func pruneObservers() {
        notifyObservers()
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

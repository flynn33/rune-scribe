import Foundation

public struct RuntimeContractIdentifier<Domain>: RawRepresentable, Hashable, Sendable,
    Comparable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum RuntimeSchemaVersionDomain: Sendable {}
public enum RuntimeOperationIDDomain: Sendable {}
public enum RuntimeCorrelationIDDomain: Sendable {}
public enum RuntimeOperationIdentifierDomain: Sendable {}
public enum RuntimeIdempotencyKeyDomain: Sendable {}
public enum RuntimeEndpointIdentifierDomain: Sendable {}

public typealias RuntimeSchemaVersion = RuntimeContractIdentifier<RuntimeSchemaVersionDomain>
public typealias RuntimeOperationID = RuntimeContractIdentifier<RuntimeOperationIDDomain>
public typealias RuntimeCorrelationID = RuntimeContractIdentifier<RuntimeCorrelationIDDomain>
public typealias RuntimeOperationIdentifier =
    RuntimeContractIdentifier<RuntimeOperationIdentifierDomain>
public typealias RuntimeIdempotencyKey =
    RuntimeContractIdentifier<RuntimeIdempotencyKeyDomain>
public typealias RuntimeEndpointIdentifier =
    RuntimeContractIdentifier<RuntimeEndpointIdentifierDomain>

public enum RuntimeSchemaVersions {
    public static let v1: RuntimeSchemaVersion = "1.0"
}

public enum RuntimePrivacyClass: String, Hashable, Sendable, CaseIterable {
    case publicData = "public"
    case internalData = "internal"
    case sensitiveRedacted = "sensitive-redacted"
    case secretProhibited = "secret-prohibited"
}

public struct RuntimeOperationMetadata: Hashable, Sendable {
    public let schemaVersion: RuntimeSchemaVersion
    public let operationID: RuntimeOperationID
    public let correlationID: RuntimeCorrelationID
    public let sourceModuleID: ModuleIdentifier
    public let destinationModuleID: ModuleIdentifier?
    public let runtimeGeneration: UInt64
    public let timestampUTC: Date
    public let operationIdentifier: RuntimeOperationIdentifier
    public let privacyClass: RuntimePrivacyClass
    public let idempotencyKey: RuntimeIdempotencyKey?

    public init(
        schemaVersion: RuntimeSchemaVersion,
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        sourceModuleID: ModuleIdentifier,
        destinationModuleID: ModuleIdentifier?,
        runtimeGeneration: UInt64,
        timestampUTC: Date,
        operationIdentifier: RuntimeOperationIdentifier,
        privacyClass: RuntimePrivacyClass,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.correlationID = correlationID
        self.sourceModuleID = sourceModuleID
        self.destinationModuleID = destinationModuleID
        self.runtimeGeneration = runtimeGeneration
        self.timestampUTC = timestampUTC
        self.operationIdentifier = operationIdentifier
        self.privacyClass = privacyClass
        self.idempotencyKey = idempotencyKey
    }
}

public protocol RuntimeOperationEnvelope: Sendable {
    associatedtype Payload: Sendable

    var metadata: RuntimeOperationMetadata { get }
    var payload: Payload { get }
}

public extension RuntimeOperationEnvelope {
    var schemaVersion: RuntimeSchemaVersion { metadata.schemaVersion }
    var operationID: RuntimeOperationID { metadata.operationID }
    var correlationID: RuntimeCorrelationID { metadata.correlationID }
    var sourceModuleID: ModuleIdentifier { metadata.sourceModuleID }
    var destinationModuleID: ModuleIdentifier? { metadata.destinationModuleID }
    var runtimeGeneration: UInt64 { metadata.runtimeGeneration }
    var timestampUTC: Date { metadata.timestampUTC }
    var operationIdentifier: RuntimeOperationIdentifier { metadata.operationIdentifier }
    var privacyClass: RuntimePrivacyClass { metadata.privacyClass }
    var idempotencyKey: RuntimeIdempotencyKey? { metadata.idempotencyKey }
}

public struct RuntimeCommandEnvelope<Payload: Sendable>: RuntimeOperationEnvelope {
    public let metadata: RuntimeOperationMetadata
    public let payload: Payload

    public init(metadata: RuntimeOperationMetadata, payload: Payload) {
        self.metadata = metadata
        self.payload = payload
    }

    public var commandID: RuntimeOperationIdentifier { operationIdentifier }
}

extension RuntimeCommandEnvelope: Equatable where Payload: Equatable {}
extension RuntimeCommandEnvelope: Hashable where Payload: Hashable {}

public struct RuntimeQueryEnvelope<Payload: Sendable>: RuntimeOperationEnvelope {
    public let metadata: RuntimeOperationMetadata
    public let payload: Payload

    public init(metadata: RuntimeOperationMetadata, payload: Payload) {
        self.metadata = metadata
        self.payload = payload
    }

    public var queryID: RuntimeOperationIdentifier { operationIdentifier }
}

extension RuntimeQueryEnvelope: Equatable where Payload: Equatable {}
extension RuntimeQueryEnvelope: Hashable where Payload: Hashable {}

public struct RuntimeIngressEnvelope<Payload: Sendable>: RuntimeOperationEnvelope {
    public let metadata: RuntimeOperationMetadata
    public let payload: Payload

    public init(metadata: RuntimeOperationMetadata, payload: Payload) {
        self.metadata = metadata
        self.payload = payload
    }

    public var inputType: RuntimeOperationIdentifier { operationIdentifier }
}

extension RuntimeIngressEnvelope: Equatable where Payload: Equatable {}
extension RuntimeIngressEnvelope: Hashable where Payload: Hashable {}

public struct RuntimeStateEnvelope<Payload: Sendable>: RuntimeOperationEnvelope {
    public let metadata: RuntimeOperationMetadata
    public let payload: Payload

    public init(metadata: RuntimeOperationMetadata, payload: Payload) {
        self.metadata = metadata
        self.payload = payload
    }

    public var stateID: RuntimeOperationIdentifier { operationIdentifier }
}

extension RuntimeStateEnvelope: Equatable where Payload: Equatable {}
extension RuntimeStateEnvelope: Hashable where Payload: Hashable {}

public enum RuntimeEndpointKind: String, Hashable, Sendable, CaseIterable {
    case command
    case query
    case ingress
    case state
}

public enum RuntimeEndpointDestination: Hashable, Sendable {
    case module(ModuleIdentifier)
    case role(ModuleRole)
}

public struct RuntimeEndpointIdentity: Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let endpointID: RuntimeEndpointIdentifier

    public init(endpointID: RuntimeEndpointIdentifier) {
        self.endpointID = endpointID
    }

    public var description: String { endpointID.rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.endpointID < rhs.endpointID
    }
}

public struct RuntimeEndpointDescriptor<Request: Sendable, Response: Sendable>:
    Hashable, Sendable
{
    public let endpointID: RuntimeEndpointIdentifier
    public let kind: RuntimeEndpointKind
    public let destination: RuntimeEndpointDestination
    public let requestSchemaVersion: RuntimeSchemaVersion
    public let responseSchemaVersion: RuntimeSchemaVersion
    public let requiredCapability: CapabilityIdentifier
    public let privacyClass: RuntimePrivacyClass
    public let maximumRequestBytes: UInt64
    public let maximumResponseBytes: UInt64

    public init(
        endpointID: RuntimeEndpointIdentifier,
        kind: RuntimeEndpointKind,
        destination: RuntimeEndpointDestination,
        requestSchemaVersion: RuntimeSchemaVersion,
        responseSchemaVersion: RuntimeSchemaVersion,
        requiredCapability: CapabilityIdentifier,
        privacyClass: RuntimePrivacyClass,
        maximumRequestBytes: UInt64,
        maximumResponseBytes: UInt64
    ) {
        self.endpointID = endpointID
        self.kind = kind
        self.destination = destination
        self.requestSchemaVersion = requestSchemaVersion
        self.responseSchemaVersion = responseSchemaVersion
        self.requiredCapability = requiredCapability
        self.privacyClass = privacyClass
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    public var identity: RuntimeEndpointIdentity {
        RuntimeEndpointIdentity(endpointID: endpointID)
    }

    public var key: RuntimeEndpointKey<Request, Response> {
        RuntimeEndpointKey(descriptor: self)
    }
}

public struct RuntimeEndpointKey<Request: Sendable, Response: Sendable>: Hashable,
    Sendable
{
    public let descriptor: RuntimeEndpointDescriptor<Request, Response>

    public init(descriptor: RuntimeEndpointDescriptor<Request, Response>) {
        self.descriptor = descriptor
    }

    public var identity: RuntimeEndpointIdentity { descriptor.identity }
}

public struct RuntimeStateSubscription: Hashable, Sendable {
    public init() {}
}

public struct RuntimeStateRelayBufferingPolicy: Hashable, Sendable {
    public enum Ordering: String, Hashable, Sendable {
        case newest
        case oldest
    }

    public let ordering: Ordering
    public let capacity: UInt16

    private init(ordering: Ordering, capacity: UInt16) {
        self.ordering = ordering
        self.capacity = max(1, capacity)
    }

    public static func bufferingNewest(_ capacity: UInt16) -> Self {
        Self(ordering: .newest, capacity: capacity)
    }

    public static func bufferingOldest(_ capacity: UInt16) -> Self {
        Self(ordering: .oldest, capacity: capacity)
    }
}

public struct RuntimeStateEndpointDescriptor<State: Sendable>: Hashable, Sendable {
    public let endpoint: RuntimeEndpointDescriptor<RuntimeStateSubscription, State>
    public let bufferingPolicy: RuntimeStateRelayBufferingPolicy

    public init(
        endpointID: RuntimeEndpointIdentifier,
        destination: RuntimeEndpointDestination,
        subscriptionSchemaVersion: RuntimeSchemaVersion,
        stateSchemaVersion: RuntimeSchemaVersion,
        requiredCapability: CapabilityIdentifier,
        privacyClass: RuntimePrivacyClass,
        maximumSubscriptionBytes: UInt64,
        maximumStateBytes: UInt64,
        bufferingPolicy: RuntimeStateRelayBufferingPolicy = .bufferingNewest(1)
    ) {
        endpoint = RuntimeEndpointDescriptor(
            endpointID: endpointID,
            kind: .state,
            destination: destination,
            requestSchemaVersion: subscriptionSchemaVersion,
            responseSchemaVersion: stateSchemaVersion,
            requiredCapability: requiredCapability,
            privacyClass: privacyClass,
            maximumRequestBytes: maximumSubscriptionBytes,
            maximumResponseBytes: maximumStateBytes
        )
        self.bufferingPolicy = bufferingPolicy
    }

    public var endpointID: RuntimeEndpointIdentifier { endpoint.endpointID }
    public var destination: RuntimeEndpointDestination { endpoint.destination }
    public var subscriptionSchemaVersion: RuntimeSchemaVersion {
        endpoint.requestSchemaVersion
    }
    public var stateSchemaVersion: RuntimeSchemaVersion { endpoint.responseSchemaVersion }
    public var requiredCapability: CapabilityIdentifier { endpoint.requiredCapability }
    public var privacyClass: RuntimePrivacyClass { endpoint.privacyClass }
    public var maximumSubscriptionBytes: UInt64 { endpoint.maximumRequestBytes }
    public var maximumStateBytes: UInt64 { endpoint.maximumResponseBytes }
    public var identity: RuntimeEndpointIdentity { endpoint.identity }
    public var key: RuntimeEndpointKey<RuntimeStateSubscription, State> { endpoint.key }
}

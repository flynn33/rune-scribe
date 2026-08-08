import Foundation
import RuneScribeContracts

public struct DirectedMessage: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let type: MessageIdentifier
    public let sourceModuleID: ModuleIdentifier
    public let destinationRole: ModuleRole
    public let timestamp: Date
    public let payload: Data

    public init(
        messageID: UUID,
        type: MessageIdentifier,
        sourceModuleID: ModuleIdentifier,
        destinationRole: ModuleRole,
        timestamp: Date,
        payload: Data
    ) {
        self.messageID = messageID
        self.type = type
        self.sourceModuleID = sourceModuleID
        self.destinationRole = destinationRole
        self.timestamp = timestamp
        self.payload = payload
    }

    public func decodePayload<Payload: Decodable & Sendable>(
        as type: Payload.Type = Payload.self
    ) throws -> Payload {
        try JSONDecoder().decode(type, from: payload)
    }
}

public actor DirectedMessageRouter {
    private struct Destination: Sendable {
        let owner: ModuleIdentifier
        let handler: @Sendable (DirectedMessage) async -> Void
    }

    private var destinations: [ModuleRole: Destination] = [:]

    public init() {}

    func register(
        role: ModuleRole,
        owner: ModuleIdentifier,
        handler: @escaping @Sendable (DirectedMessage) async -> Void
    ) throws {
        guard destinations[role] == nil else {
            throw RuneScribeRuntimeError.duplicateMessageDestination(role)
        }
        destinations[role] = Destination(owner: owner, handler: handler)
    }

    func send(_ message: DirectedMessage) async throws {
        guard let destination = destinations[message.destinationRole] else {
            throw RuneScribeRuntimeError.messageDestinationUnavailable(message.destinationRole)
        }
        await destination.handler(message)
    }

    func removeDestination(ownedBy owner: ModuleIdentifier) {
        destinations = destinations.filter { $0.value.owner != owner }
    }
}

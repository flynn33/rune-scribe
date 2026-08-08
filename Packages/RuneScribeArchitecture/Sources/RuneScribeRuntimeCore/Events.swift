import Foundation
import RuneScribeContracts

public struct RuntimeEvent: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let type: EventIdentifier
    public let sourceModuleID: ModuleIdentifier
    public let timestamp: Date
    public let sequence: UInt64
    public let payload: Data

    public init(
        eventID: UUID,
        type: EventIdentifier,
        sourceModuleID: ModuleIdentifier,
        timestamp: Date,
        sequence: UInt64,
        payload: Data
    ) {
        self.eventID = eventID
        self.type = type
        self.sourceModuleID = sourceModuleID
        self.timestamp = timestamp
        self.sequence = sequence
        self.payload = payload
    }

    public func decodePayload<Payload: Decodable & Sendable>(
        as type: Payload.Type = Payload.self
    ) throws -> Payload {
        try JSONDecoder().decode(type, from: payload)
    }
}

public actor RuntimeEventBus {
    private struct Subscription: Sendable {
        let owner: ModuleIdentifier
        let continuation: AsyncStream<RuntimeEvent>.Continuation
    }

    private var sequence: UInt64 = 0
    private var subscriptions: [UUID: Subscription] = [:]

    public init() {}

    func subscribe(
        owner: ModuleIdentifier,
        subscriptionID: UUID
    ) -> AsyncStream<RuntimeEvent> {
        let pair = AsyncStream<RuntimeEvent>.makeStream()
        subscriptions[subscriptionID] = Subscription(
            owner: owner,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscription(subscriptionID)
            }
        }
        return pair.stream
    }

    func publish(
        type: EventIdentifier,
        source: ModuleIdentifier,
        timestamp: Date,
        eventID: UUID,
        payload: Data
    ) -> RuntimeEvent {
        sequence &+= 1
        let event = RuntimeEvent(
            eventID: eventID,
            type: type,
            sourceModuleID: source,
            timestamp: timestamp,
            sequence: sequence,
            payload: payload
        )
        for subscription in subscriptions.values {
            subscription.continuation.yield(event)
        }
        return event
    }

    func removeSubscriptions(ownedBy owner: ModuleIdentifier) {
        let matching = subscriptions.filter { $0.value.owner == owner }
        for (identifier, subscription) in matching {
            subscription.continuation.finish()
            subscriptions.removeValue(forKey: identifier)
        }
    }

    private func removeSubscription(_ identifier: UUID) {
        subscriptions.removeValue(forKey: identifier)
    }
}

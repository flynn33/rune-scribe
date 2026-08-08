import Foundation
import RuneScribeContracts

/// Preserves the host callback order while forwarding into an async module
/// service. Submission is synchronous on the main actor; one consumer performs
/// every awaited receive operation in FIFO order.
@MainActor
public final class SerialInboundInputForwarder {
    public static let queueCapacity = 512
    public static let reservedControlCapacity = 16
    public static let maximumURLByteCount = 4 * 1_024
    public static let maximumContentTypeByteCount = 256

    private let service: any RuneScribeInboundInputService
    private var queue: [RuneScribeInboundInput] = []
    private var queuedDataCount = 0
    private var deliveryTask: Task<Void, Never>?
    public private(set) var rejectedInputCount = 0
    public private(set) var failedDeliveryCount = 0

    public var hasDeliveryFailures: Bool {
        rejectedInputCount > 0 || failedDeliveryCount > 0
    }

    public init(service: any RuneScribeInboundInputService) {
        self.service = service
    }

    @discardableResult
    public func submit(_ input: RuneScribeInboundInput) -> InboundInputDispositionDTO {
        submit(contentsOf: [input])[0]
    }

    /// Accepts at most 512 retained inputs, reserving 16 positions for lifecycle
    /// and menu control events so a saturated data rail cannot suppress a lock or
    /// termination signal. The result reports every rejected submission to the
    /// caller; inputs are never discarded silently.
    @discardableResult
    public func submit(
        contentsOf inputs: [RuneScribeInboundInput]
    ) -> [InboundInputDispositionDTO] {
        let dataCapacity = Self.queueCapacity - Self.reservedControlCapacity
        let dispositions = inputs.map { input in
            let isControl = Self.isControl(input)
            guard Self.hasBoundedMetadata(input),
                  queue.count < Self.queueCapacity,
                  isControl || queuedDataCount < dataCapacity
            else {
                rejectedInputCount += 1
                return InboundInputDispositionDTO.rejected
            }
            queue.append(input)
            if !isControl { queuedDataCount += 1 }
            return .accepted
        }
        if dispositions.contains(.accepted) { startDeliveryIfNeeded() }
        return dispositions
    }

    public func flush() async {
        startDeliveryIfNeeded()
        while let deliveryTask {
            await deliveryTask.value
        }
    }

    private func startDeliveryIfNeeded() {
        guard deliveryTask == nil, !queue.isEmpty else { return }
        deliveryTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let input = queue.first {
            do {
                if try await service.receive(input) == .rejected {
                    rejectedInputCount += 1
                }
            } catch {
                failedDeliveryCount += 1
            }
            queue.removeFirst()
            if !Self.isControl(input) { queuedDataCount -= 1 }
        }
        deliveryTask = nil
    }

    private static func isControl(_ input: RuneScribeInboundInput) -> Bool {
        switch input {
        case .lifecycle, .menu:
            true
        case .file, .url:
            false
        }
    }

    private static func hasBoundedMetadata(_ input: RuneScribeInboundInput) -> Bool {
        switch input {
        case .url(let value):
            value.url.absoluteString.utf8.count <= maximumURLByteCount
        case .file(let value):
            value.fileURL.absoluteString.utf8.count <= maximumURLByteCount
                && (value.declaredContentType?.utf8.count ?? 0)
                    <= maximumContentTypeByteCount
        case .lifecycle, .menu:
            true
        }
    }
}

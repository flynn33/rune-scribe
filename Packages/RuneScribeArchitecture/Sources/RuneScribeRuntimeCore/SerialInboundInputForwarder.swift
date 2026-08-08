import Foundation
import RuneScribeContracts

/// Preserves the host callback order while forwarding into an async module
/// service. Submission is synchronous on the main actor and remains available
/// while the service is detached; one consumer performs every awaited receive
/// operation in FIFO order after attachment.
@MainActor
public final class SerialInboundInputForwarder {
    public enum AttachmentDisposition: Equatable, Sendable {
        case attached
        case rejectedAlreadyAttached
        case rejectedWhileDetaching
    }

    public static let queueCapacity = 512
    public static let reservedControlCapacity = 16
    public static let reservedSecurityLifecycleCapacity = 2
    public static let maximumURLByteCount = 4 * 1_024
    public static let maximumContentTypeByteCount = 256

    private var service: (any RuneScribeInboundInputService)?
    private var queue: [RuneScribeInboundInput] = []
    private var queuedDataCount = 0
    private var queuedSecurityLifecycleEvents: Set<ApplicationLifecycleInputDTO> = []
    private var deliveryTask: Task<Void, Never>?
    private var attachmentGeneration: UInt64 = 0
    private var isDetaching = false
    public private(set) var rejectedInputCount = 0
    public private(set) var failedDeliveryCount = 0

    public var hasDeliveryFailures: Bool {
        rejectedInputCount > 0 || failedDeliveryCount > 0
    }

    public init() {}

    /// Attaches the sole destination for retained inputs. Replacing a live
    /// destination is rejected so an input cannot be delivered concurrently to
    /// two service handles. Await `detach()` before attaching another service.
    @discardableResult
    public func attach(
        service: any RuneScribeInboundInputService
    ) -> AttachmentDisposition {
        if isDetaching { return .rejectedWhileDetaching }
        guard self.service == nil else { return .rejectedAlreadyAttached }

        attachmentGeneration &+= 1
        self.service = service
        startDeliveryIfNeeded()
        return .attached
    }

    /// Stops the active delivery pump and awaits any receive operation already
    /// in flight. The detached service is not retained after this method
    /// returns. Inputs not yet offered to that service remain queued for a later
    /// attachment.
    public func detach() async {
        if isDetaching {
            await deliveryTask?.value
            return
        }
        guard service != nil else { return }

        isDetaching = true
        service = nil
        attachmentGeneration &+= 1

        let task = deliveryTask
        await task?.value

        deliveryTask = nil
        isDetaching = false
    }

    @discardableResult
    public func submit(_ input: RuneScribeInboundInput) -> InboundInputDispositionDTO {
        submit(contentsOf: [input])[0]
    }

    /// Accepts at most 512 retained inputs, reserving 16 positions for controls.
    /// Within that bound, two positions remain available for one pending
    /// background-lock event and one pending termination event. Repeated pending
    /// security events are coalesced as duplicates so either event cannot consume
    /// the other's reserve. The result reports every rejected submission to the
    /// caller; inputs are never discarded silently.
    @discardableResult
    public func submit(
        contentsOf inputs: [RuneScribeInboundInput]
    ) -> [InboundInputDispositionDTO] {
        let dataCapacity = Self.queueCapacity - Self.reservedControlCapacity
        let dispositions = inputs.map { input in
            let isControl = Self.isControl(input)
            let securityEvent = Self.securityLifecycleEvent(input)
            if let securityEvent,
               queuedSecurityLifecycleEvents.contains(securityEvent) {
                return InboundInputDispositionDTO.duplicate
            }
            let unqueuedSecurityEventCount = Self.reservedSecurityLifecycleCapacity
                - queuedSecurityLifecycleEvents.count
            let admissionCapacity = securityEvent == nil
                ? Self.queueCapacity - unqueuedSecurityEventCount
                : Self.queueCapacity
            guard Self.hasBoundedMetadata(input),
                  queue.count < admissionCapacity,
                  isControl || queuedDataCount < dataCapacity
            else {
                rejectedInputCount += 1
                return InboundInputDispositionDTO.rejected
            }
            queue.append(input)
            if !isControl { queuedDataCount += 1 }
            if let securityEvent {
                queuedSecurityLifecycleEvents.insert(securityEvent)
            }
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
        guard deliveryTask == nil,
              service != nil,
              !queue.isEmpty
        else { return }

        let generation = attachmentGeneration
        deliveryTask = Task { @MainActor [weak self] in
            await self?.drain(attachmentGeneration: generation)
        }
    }

    private func drain(attachmentGeneration generation: UInt64) async {
        while generation == attachmentGeneration,
              let service,
              let input = queue.first
        {
            do {
                if try await service.receive(input) == .rejected {
                    rejectedInputCount += 1
                }
            } catch {
                failedDeliveryCount += 1
            }
            queue.removeFirst()
            if !Self.isControl(input) { queuedDataCount -= 1 }
            if let securityEvent = Self.securityLifecycleEvent(input) {
                queuedSecurityLifecycleEvents.remove(securityEvent)
            }
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

    private static func securityLifecycleEvent(
        _ input: RuneScribeInboundInput
    ) -> ApplicationLifecycleInputDTO? {
        guard case .lifecycle(let lifecycle) = input else { return nil }
        switch lifecycle.event {
        case .didEnterBackground, .willTerminate:
            return lifecycle.event
        case .didBecomeActive, .willResignActive, .willEnterForeground:
            return nil
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

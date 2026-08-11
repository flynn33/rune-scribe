import Foundation
import RuneScribeContracts

/// Raw operating-system input. The host supplies only the callback payload and
/// source; runtime-owned metadata is added after the input passes admission.
public enum ExternalInputEnvelope: Equatable, Hashable, Sendable {
    case url(URL, source: InboundDeliverySourceDTO)
    case file(
        URL,
        declaredContentType: String? = nil,
        requiresSecurityScopedAccess: Bool = true,
        source: InboundDeliverySourceDTO
    )
    case lifecycle(ApplicationLifecycleInputDTO)
    case menu(ApplicationMenuCommandDTO)
}

public enum RuntimeHostIngressFailure: String, Equatable, Hashable, Sendable {
    case admissionRejected
    case destinationRejected
    case destinationUnavailable
    case deliveryFailed
}

public struct RuntimeHostIngressSnapshot: Equatable, Sendable {
    public let queuedInputCount: Int
    public let rejectedInputCount: Int
    public let failedDeliveryCount: Int
    public let lastFailure: RuntimeHostIngressFailure?

    public var hasDeliveryFailures: Bool {
        rejectedInputCount > 0 || failedDeliveryCount > 0
    }

    init(
        queuedInputCount: Int,
        rejectedInputCount: Int,
        failedDeliveryCount: Int,
        lastFailure: RuntimeHostIngressFailure?
    ) {
        self.queuedInputCount = queuedInputCount
        self.rejectedInputCount = rejectedInputCount
        self.failedDeliveryCount = failedDeliveryCount
        self.lastFailure = lastFailure
    }
}

/// Runtime-owned, bounded host ingress rail. Submission is synchronous so OS
/// callbacks can report admission immediately. A single asynchronous pump offers
/// inputs in FIFO order to a runtime dispatcher closure; module service values
/// never enter or leave this type.
public final class RuntimeHostIngressRail: @unchecked Sendable {
    public static let queueCapacity = 512
    public static let reservedControlCapacity = 16
    public static let reservedSecurityLifecycleCapacity = 2
    public static let menuCapacity = 16
    public static let maximumURLByteCount = 4 * 1_024
    public static let maximumContentTypeByteCount = 256
    public static let maximumDestinationResolutionRetries = 1

    typealias Delivery = @Sendable (
        RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO
    typealias FileNormalization = @Sendable (
        RuntimeInboundFileReadRequest
    ) async throws -> Data

    private enum StampedInput: Sendable {
        case ready(RuneScribeInboundInput)
        case file(
            metadata: InboundInputMetadataDTO,
            url: URL,
            declaredContentType: String?,
            requiresSecurityScopedAccess: Bool
        )
    }

    private struct RetainedInput: Sendable {
        let reservationID: UInt64
        var value: StampedInput?
        let isControl: Bool
        let isMenu: Bool
        let securityEvent: ApplicationLifecycleInputDTO?
    }

    private struct AdmissionReservation: Sendable {
        let reservationID: UInt64
        let rawInput: ExternalInputEnvelope
        let isColdStart: Bool
    }

    private struct ReservationWaiter {
        let cutoff: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let environment: RuntimeEnvironment
    private let normalizeFile: FileNormalization
    private var queue: [RetainedInput] = []
    private var offeredInput: RetainedInput?
    private var retainedDataCount = 0
    private var retainedMenuCount = 0
    private var retainedSecurityEvents: Set<ApplicationLifecycleInputDTO> = []
    private var unstampedReservationIDs: Set<UInt64> = []
    private var reservationWaiters: [ReservationWaiter] = []
    private var delivery: Delivery?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryTaskStarting = false
    private var routingGeneration: UInt64 = 0
    private var reservationSequence: UInt64 = 0
    private var hasCompletedSuccessfulActivation = false
    private var acceptsSubmissions = true
    private var rejectedInputCount = 0
    private var failedDeliveryCount = 0
    private var lastFailure: RuntimeHostIngressFailure?
    private var failureObserver: (@Sendable (RuntimeHostIngressFailure) -> Void)?

    init(
        environment: RuntimeEnvironment,
        normalizeFile: @escaping FileNormalization = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.inboundFileReader
            )
        }
    ) {
        self.environment = environment
        self.normalizeFile = normalizeFile
    }

    @discardableResult
    public func submit(
        _ input: ExternalInputEnvelope
    ) -> InboundInputDispositionDTO {
        submit(contentsOf: [input])[0]
    }

    /// Retains at most 512 inputs. Data is capped at 496 so controls always have
    /// 16 slots; within those 16 slots, one background-lock event and one
    /// termination event each keep a dedicated reserve. Menu commands have an
    /// independent 16-item bound. Duplicate pending security events coalesce
    /// without consuming either reserve.
    @discardableResult
    public func submit(
        contentsOf inputs: [ExternalInputEnvelope]
    ) -> [InboundInputDispositionDTO] {
        let admissions = withLock {
            inputs.map { admitLocked($0) }
        }
        for reservation in admissions.compactMap(\.reservation) {
            let value = stampedInput(
                reservation.rawInput,
                isColdStart: reservation.isColdStart
            )
            finishStamping(value, reservationID: reservation.reservationID)
        }
        let dispositions = admissions.map(\.disposition)
        if dispositions.contains(.rejected) {
            recordFailure(.admissionRejected)
        }
        if dispositions.contains(.accepted) { startDeliveryIfNeeded() }
        return dispositions
    }

    public var snapshot: RuntimeHostIngressSnapshot {
        withLock {
            RuntimeHostIngressSnapshot(
                queuedInputCount: queue.count + (offeredInput == nil ? 0 : 1),
                rejectedInputCount: rejectedInputCount,
                failedDeliveryCount: failedDeliveryCount,
                lastFailure: lastFailure
            )
        }
    }

    func observeFailures(
        _ observer: @escaping @Sendable (RuntimeHostIngressFailure) -> Void
    ) {
        withLock {
            failureObserver = observer
        }
    }

    func quiesceAdmissions() {
        withLock {
            acceptsSubmissions = false
        }
    }

    func resumeAdmissions() {
        withLock {
            acceptsSubmissions = true
        }
    }

    func activate(delivery: @escaping Delivery) {
        withLock {
            routingGeneration &+= 1
            self.delivery = delivery
            acceptsSubmissions = true
        }
        startDeliveryIfNeeded()
    }

    func noteSuccessfulActivation() {
        withLock {
            hasCompletedSuccessfulActivation = true
        }
    }

    /// Prevents further offers. An item already offered remains owned by that
    /// attempt and is never put back into the queue for a replacement handler.
    func suspend() {
        withLock {
            routingGeneration &+= 1
            delivery = nil
        }
    }

    func flush() async {
        // Establish one admission boundary before waiting. Runtime shutdown
        // quiesces admissions before calling flush(), so every accepted input at
        // or below this boundary must finish metadata stamping before flush can
        // conclude. This closes the interval where submit() has reserved queue
        // capacity but is still executing an environment provider outside the
        // lock.
        let reservationCutoff = withLock { reservationSequence }
        while true {
            await waitForStamping(through: reservationCutoff)
            startDeliveryIfNeeded()
            let state = withLock { (deliveryTask, deliveryTaskStarting) }
            if let task = state.0 {
                await task.value
            } else if state.1 {
                await Task.yield()
            } else {
                return
            }
        }
    }

    private func admitLocked(
        _ rawInput: ExternalInputEnvelope
    ) -> (
        disposition: InboundInputDispositionDTO,
        reservation: AdmissionReservation?
    ) {
        guard acceptsSubmissions else {
            rejectedInputCount += 1
            return (.rejected, nil)
        }
        let isControl = Self.isControl(rawInput)
        let isMenu = Self.isMenu(rawInput)
        let securityEvent = Self.securityLifecycleEvent(rawInput)
        if let securityEvent,
           retainedSecurityEvents.contains(securityEvent) {
            return (.duplicate, nil)
        }

        let retainedCount = queue.count + (offeredInput == nil ? 0 : 1)
        let unqueuedSecurityEventCount = Self.reservedSecurityLifecycleCapacity
            - retainedSecurityEvents.count
        let admissionCapacity = securityEvent == nil
            ? Self.queueCapacity - unqueuedSecurityEventCount
            : Self.queueCapacity
        let dataCapacity = Self.queueCapacity - Self.reservedControlCapacity

        guard Self.hasBoundedMetadata(rawInput),
              retainedCount < admissionCapacity,
              isControl || retainedDataCount < dataCapacity,
              !isMenu || retainedMenuCount < Self.menuCapacity
        else {
            rejectedInputCount += 1
            return (.rejected, nil)
        }

        reservationSequence &+= 1
        let reservation = AdmissionReservation(
            reservationID: reservationSequence,
            rawInput: rawInput,
            isColdStart: !hasCompletedSuccessfulActivation
        )
        let retainedInput = RetainedInput(
            reservationID: reservation.reservationID,
            value: nil,
            isControl: isControl,
            isMenu: isMenu,
            securityEvent: securityEvent
        )
        queue.append(retainedInput)
        unstampedReservationIDs.insert(reservation.reservationID)
        if !isControl { retainedDataCount += 1 }
        if isMenu { retainedMenuCount += 1 }
        if let securityEvent { retainedSecurityEvents.insert(securityEvent) }
        return (.accepted, reservation)
    }

    private func finishStamping(
        _ value: StampedInput,
        reservationID: UInt64
    ) {
        let readyWaiters = withLock { () -> [ReservationWaiter] in
            guard let index = queue.firstIndex(where: {
                $0.reservationID == reservationID
            }) else { return [] }
            queue[index].value = value
            unstampedReservationIDs.remove(reservationID)

            var ready: [ReservationWaiter] = []
            reservationWaiters.removeAll { waiter in
                let isReady = !hasUnstampedReservationLocked(through: waiter.cutoff)
                if isReady { ready.append(waiter) }
                return isReady
            }
            return ready
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    private func waitForStamping(through cutoff: UInt64) async {
        await withCheckedContinuation { continuation in
            let shouldResume = withLock { () -> Bool in
                guard hasUnstampedReservationLocked(through: cutoff) else {
                    return true
                }
                reservationWaiters.append(
                    ReservationWaiter(cutoff: cutoff, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func hasUnstampedReservationLocked(through cutoff: UInt64) -> Bool {
        unstampedReservationIDs.contains { $0 <= cutoff }
    }

    private func stampedInput(
        _ rawInput: ExternalInputEnvelope,
        isColdStart: Bool
    ) -> StampedInput {
        let source: InboundDeliverySourceDTO
        switch rawInput {
        case .url(_, let value), .file(_, _, _, let value):
            source = value
        case .lifecycle, .menu:
            source = .applicationOpen
        }
        let metadata = InboundInputMetadataDTO(
            id: InboundInputID(rawValue: environment.nextUUID()),
            receivedAt: environment.now(),
            source: source,
            isColdStart: isColdStart
        )
        switch rawInput {
        case .url(let url, _):
            return .ready(.url(InboundURLDTO(metadata: metadata, url: url)))
        case .file(
            let url,
            let declaredContentType,
            let requiresSecurityScopedAccess,
            _
        ):
            return .file(
                metadata: metadata,
                url: url,
                declaredContentType: declaredContentType,
                requiresSecurityScopedAccess: requiresSecurityScopedAccess
            )
        case .lifecycle(let event):
            return .ready(
                .lifecycle(InboundLifecycleDTO(metadata: metadata, event: event))
            )
        case .menu(let command):
            return .ready(
                .menu(InboundMenuCommandDTO(metadata: metadata, command: command))
            )
        }
    }

    private func startDeliveryIfNeeded() {
        let generation = withLock { () -> UInt64? in
            guard deliveryTask == nil,
                  !deliveryTaskStarting,
                  offeredInput == nil,
                  delivery != nil,
                  queue.first?.value != nil
            else { return nil }
            deliveryTaskStarting = true
            return routingGeneration
        }
        guard let generation else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            while self.withLock({ self.deliveryTaskStarting }) {
                await Task.yield()
            }
            await self.drain(routingGeneration: generation)
            self.startDeliveryIfNeeded()
        }
        withLock {
            deliveryTask = task
            deliveryTaskStarting = false
        }
    }

    private func drain(routingGeneration generation: UInt64) async {
        while let offer = takeNextOffer(routingGeneration: generation) {
            let value: RuneScribeInboundInput
            do {
                value = try await normalizedInput(offer.value)
            } catch {
                finishOffer(offer.input, failure: .deliveryFailed)
                continue
            }
            var destinationResolutionRetryCount = 0
            while true {
                do {
                    let disposition = try await offer.delivery(value)
                    finishOffer(
                        offer.input,
                        failure: disposition == .rejected ? .destinationRejected : nil
                    )
                    break
                } catch RuntimeHostIngressRoutingError
                    .destinationUnavailableBeforeInvocation {
                    // This error is produced only while resolving the current
                    // destination, before a provider handler is entered. One
                    // retry therefore permits a concurrent destination
                    // replacement without replaying a side-effecting call.
                    guard destinationResolutionRetryCount
                            < Self.maximumDestinationResolutionRetries
                    else {
                        finishOffer(offer.input, failure: .destinationUnavailable)
                        break
                    }
                    destinationResolutionRetryCount += 1
                    await Task.yield()
                } catch {
                    // A provider may already have observed the input. Never
                    // retry an ambiguous failure or an explicit rejection.
                    finishOffer(offer.input, failure: .deliveryFailed)
                    break
                }
            }
        }
    }

    private func takeNextOffer(
        routingGeneration generation: UInt64
    ) -> (input: RetainedInput, value: StampedInput, delivery: Delivery)? {
        withLock {
            guard generation == routingGeneration,
                  let delivery,
                  offeredInput == nil,
                  let first = queue.first,
                  let value = first.value
            else {
                deliveryTask = nil
                return nil
            }
            let input = queue.removeFirst()
            offeredInput = input
            return (input, value, delivery)
        }
    }

    private func normalizedInput(
        _ input: StampedInput
    ) async throws -> RuneScribeInboundInput {
        switch input {
        case .ready(let value):
            return value
        case .file(
            let metadata,
            let url,
            let declaredContentType,
            let requiresSecurityScopedAccess
        ):
            let data = try await normalizeFile(
                RuntimeInboundFileReadRequest(
                    fileURL: url,
                    requiresSecurityScopedAccess: requiresSecurityScopedAccess,
                    maximumByteCount: RuntimeIOGateway.maximumInboundFileByteCount
                )
            )
            return .file(
                InboundFileDTO(
                    metadata: metadata,
                    data: data,
                    declaredContentType: declaredContentType
                )
            )
        }
    }

    private func finishOffer(
        _ input: RetainedInput,
        failure: RuntimeHostIngressFailure? = nil
    ) {
        let observer = withLock { () -> (@Sendable (RuntimeHostIngressFailure) -> Void)? in
            guard offeredInput?.reservationID == input.reservationID else {
                return nil
            }
            offeredInput = nil
            if !input.isControl { retainedDataCount -= 1 }
            if input.isMenu { retainedMenuCount -= 1 }
            if let securityEvent = input.securityEvent {
                retainedSecurityEvents.remove(securityEvent)
            }
            if failure == .destinationRejected { rejectedInputCount += 1 }
            if failure == .destinationUnavailable || failure == .deliveryFailed {
                failedDeliveryCount += 1
            }
            guard let failure else { return nil }
            lastFailure = failure
            return failureObserver
        }
        if let failure {
            observer?(failure)
        }
    }

    private func recordFailure(_ failure: RuntimeHostIngressFailure) {
        let observer = withLock {
            lastFailure = failure
            return failureObserver
        }
        observer?(failure)
    }

    private static func isControl(_ input: ExternalInputEnvelope) -> Bool {
        switch input {
        case .lifecycle, .menu:
            true
        case .file, .url:
            false
        }
    }

    private static func isMenu(_ input: ExternalInputEnvelope) -> Bool {
        if case .menu = input { return true }
        return false
    }

    private static func securityLifecycleEvent(
        _ input: ExternalInputEnvelope
    ) -> ApplicationLifecycleInputDTO? {
        guard case .lifecycle(let lifecycle) = input else { return nil }
        switch lifecycle {
        case .didEnterBackground, .willTerminate:
            return lifecycle
        case .didBecomeActive, .willResignActive, .willEnterForeground:
            return nil
        }
    }

    private static func hasBoundedMetadata(
        _ input: ExternalInputEnvelope
    ) -> Bool {
        switch input {
        case .url(let url, _):
            return url.absoluteString.utf8.count <= maximumURLByteCount
        case .file(let url, let contentType, _, _):
            return url.absoluteString.utf8.count <= maximumURLByteCount
                && (contentType?.utf8.count ?? 0) <= maximumContentTypeByteCount
        case .lifecycle, .menu:
            return true
        }
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

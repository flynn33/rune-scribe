import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class InboundInputForwarderTests: XCTestCase {
    @MainActor
    func testInterleavedCallbackBatchesRemainFIFOAcrossAwait() async throws {
        let service = GatedInboundInputService()
        let forwarder = SerialInboundInputForwarder()
        let first = input(id: 1, event: .didBecomeActive)
        let second = input(id: 2, event: .willResignActive)
        let third = input(id: 3, event: .didEnterBackground)

        XCTAssertEqual(
            forwarder.submit(contentsOf: [first, second]),
            [.accepted, .accepted]
        )
        await forwarder.flush()
        XCTAssertEqual(forwarder.attach(service: service), .attached)
        while await !service.hasStartedFirstReceive { await Task.yield() }
        XCTAssertEqual(forwarder.submit(third), .accepted)
        await service.releaseFirstReceive()
        await forwarder.flush()

        let received = await service.receivedIDs
        XCTAssertEqual(received, [first.metadata.id, second.metadata.id, third.metadata.id])
    }

    @MainActor
    func testBoundedQueueReservesControlCapacityAndReportsOverflow() async {
        let service = GatedInboundInputService()
        let forwarder = SerialInboundInputForwarder()
        let first = urlInput(id: 1)
        let oversized = urlInput(
            id: 0,
            payload: String(
                repeating: "x",
                count: SerialInboundInputForwarder.maximumURLByteCount
            )
        )

        XCTAssertEqual(forwarder.submit(oversized), .rejected)
        XCTAssertEqual(forwarder.submit(first), .accepted)

        let dataInputs = (2...600).map { urlInput(id: $0) }
        let dataDispositions = forwarder.submit(contentsOf: dataInputs)
        let acceptedData = zip(dataInputs, dataDispositions).compactMap { input, disposition in
            disposition == .accepted ? input : nil
        }
        XCTAssertEqual(
            acceptedData.count + 1,
            SerialInboundInputForwarder.queueCapacity
                - SerialInboundInputForwarder.reservedControlCapacity
        )
        XCTAssertTrue(dataDispositions.dropFirst(acceptedData.count).allSatisfy { $0 == .rejected })

        let ordinaryControlCapacity = SerialInboundInputForwarder.reservedControlCapacity
            - SerialInboundInputForwarder.reservedSecurityLifecycleCapacity
        let controls = (1_000..<(1_000 + ordinaryControlCapacity)).map {
            input(id: $0, event: .didBecomeActive)
        }
        XCTAssertEqual(
            forwarder.submit(contentsOf: controls),
            Array(repeating: .accepted, count: controls.count)
        )
        XCTAssertEqual(
            forwarder.submit(input(id: 1_100, event: .willResignActive)),
            .rejected
        )
        let background = input(id: 1_101, event: .didEnterBackground)
        let duplicateBackground = input(id: 1_102, event: .didEnterBackground)
        let termination = input(id: 1_103, event: .willTerminate)
        XCTAssertEqual(forwarder.submit(background), .accepted)
        XCTAssertEqual(forwarder.submit(duplicateBackground), .duplicate)
        XCTAssertEqual(forwarder.submit(termination), .accepted)
        XCTAssertEqual(
            forwarder.submit(input(id: 1_104, event: .willEnterForeground)),
            .rejected
        )
        let expectedLocalRejections = 3
            + dataDispositions.filter { $0 == .rejected }.count
        XCTAssertEqual(forwarder.rejectedInputCount, expectedLocalRejections)

        XCTAssertEqual(forwarder.attach(service: service), .attached)
        while await !service.hasStartedFirstReceive { await Task.yield() }
        await service.releaseFirstReceive()
        await forwarder.flush()

        let expectedIDs = (
            [first] + acceptedData + controls + [background, termination]
        ).map(\.metadata.id)
        let receivedIDs = await service.receivedIDs
        XCTAssertEqual(receivedIDs, expectedIDs)
        XCTAssertEqual(expectedIDs.count, SerialInboundInputForwarder.queueCapacity)
        XCTAssertEqual(forwarder.rejectedInputCount, expectedLocalRejections)
        XCTAssertEqual(forwarder.failedDeliveryCount, 0)
        XCTAssertTrue(forwarder.hasDeliveryFailures)
    }

    @MainActor
    func testServiceRejectionsAndErrorsRemainObservable() async {
        let service = ReportingInboundInputService()
        let forwarder = SerialInboundInputForwarder()

        forwarder.submit(contentsOf: [
            input(id: 2_000, event: .didBecomeActive),
            input(id: 2_001, event: .willTerminate),
        ])
        XCTAssertEqual(forwarder.attach(service: service), .attached)
        await forwarder.flush()

        XCTAssertEqual(forwarder.rejectedInputCount, 1)
        XCTAssertEqual(forwarder.failedDeliveryCount, 1)
        XCTAssertTrue(forwarder.hasDeliveryFailures)
    }

    @MainActor
    func testDetachJoinsInFlightDeliveryAndQueuesWarmInputsForNextAttach() async {
        let firstService = GatedInboundInputService()
        let nextService = RecordingInboundInputService()
        let forwarder = SerialInboundInputForwarder()
        let first = input(id: 3_000, event: .didBecomeActive)
        let retained = input(id: 3_001, event: .willResignActive)
        let warm = input(id: 3_002, event: .didEnterBackground)

        XCTAssertEqual(
            forwarder.submit(contentsOf: [first, retained]),
            [.accepted, .accepted]
        )
        XCTAssertEqual(forwarder.attach(service: firstService), .attached)
        XCTAssertEqual(
            forwarder.attach(service: nextService),
            .rejectedAlreadyAttached
        )
        while await !firstService.hasStartedFirstReceive { await Task.yield() }

        let detachment = Task { @MainActor in
            await forwarder.detach()
        }
        var disposition = SerialInboundInputForwarder.AttachmentDisposition
            .rejectedAlreadyAttached
        while disposition == .rejectedAlreadyAttached {
            await Task.yield()
            disposition = forwarder.attach(service: nextService)
        }
        XCTAssertEqual(disposition, .rejectedWhileDetaching)
        XCTAssertEqual(forwarder.submit(warm), .accepted)

        await firstService.releaseFirstReceive()
        await detachment.value

        let firstReceivedIDs = await firstService.receivedIDs
        XCTAssertEqual(firstReceivedIDs, [first.metadata.id])
        XCTAssertEqual(forwarder.attach(service: nextService), .attached)
        await forwarder.flush()
        let nextReceivedIDs = await nextService.receivedIDs
        XCTAssertEqual(nextReceivedIDs, [retained.metadata.id, warm.metadata.id])
    }

    @MainActor
    func testDetachDoesNotCancelOfferedInputAndRetainsFollowingInputs() async {
        let firstService = CancellationSensitiveGatedInboundInputService()
        let nextService = RecordingInboundInputService()
        let forwarder = SerialInboundInputForwarder()
        let first = input(id: 4_000, event: .didBecomeActive)
        let retained = input(id: 4_001, event: .willResignActive)
        let warm = input(id: 4_002, event: .didEnterBackground)

        XCTAssertEqual(
            forwarder.submit(contentsOf: [first, retained]),
            [.accepted, .accepted]
        )
        XCTAssertEqual(forwarder.attach(service: firstService), .attached)
        while await !firstService.hasStartedFirstReceive { await Task.yield() }

        let detachment = Task { @MainActor in
            await forwarder.detach()
        }
        var disposition = SerialInboundInputForwarder.AttachmentDisposition
            .rejectedAlreadyAttached
        while disposition == .rejectedAlreadyAttached {
            await Task.yield()
            disposition = forwarder.attach(service: nextService)
        }
        XCTAssertEqual(disposition, .rejectedWhileDetaching)
        XCTAssertEqual(forwarder.submit(warm), .accepted)
        let cancellationBeforeRelease = await firstService.cancellationObserved
        XCTAssertFalse(cancellationBeforeRelease)

        await firstService.releaseFirstReceive()
        await detachment.value

        let cancellationAfterDetach = await firstService.cancellationObserved
        let firstReceivedIDs = await firstService.receivedIDs
        XCTAssertFalse(cancellationAfterDetach)
        XCTAssertEqual(firstReceivedIDs, [first.metadata.id])
        XCTAssertEqual(forwarder.attach(service: nextService), .attached)
        await forwarder.flush()
        let nextReceivedIDs = await nextService.receivedIDs
        XCTAssertEqual(nextReceivedIDs, [retained.metadata.id, warm.metadata.id])
    }

    @MainActor
    func testAwaitedDetachReleasesServiceHandle() async {
        let forwarder = SerialInboundInputForwarder()
        var service: RecordingInboundInputService? = RecordingInboundInputService()
        weak let weakService = service

        XCTAssertEqual(forwarder.attach(service: service!), .attached)
        service = nil
        XCTAssertNotNil(weakService)

        await forwarder.detach()

        XCTAssertNil(weakService)
    }

    private func input(
        id: Int,
        event: ApplicationLifecycleInputDTO
    ) -> RuneScribeInboundInput {
        let uuid = inputUUID(id)
        return .lifecycle(
            InboundLifecycleDTO(
                metadata: InboundInputMetadataDTO(
                    id: InboundInputID(rawValue: uuid),
                    receivedAt: .distantPast,
                    source: .applicationOpen,
                    isColdStart: true
                ),
                event: event
            )
        )
    }

    private func urlInput(id: Int, payload: String? = nil) -> RuneScribeInboundInput {
        .url(
            InboundURLDTO(
                metadata: InboundInputMetadataDTO(
                    id: InboundInputID(rawValue: inputUUID(id)),
                    receivedAt: .distantPast,
                    source: .applicationOpen,
                    isColdStart: true
                ),
                url: URL(string: "runescribe://import?p=\(payload ?? "synthetic-\(id)")")!
            )
        )
    }

    private func inputUUID(_ id: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", id))!
    }
}

private actor GatedInboundInputService: RuneScribeInboundInputService {
    private(set) var receivedIDs: [InboundInputID] = []
    private(set) var hasStartedFirstReceive = false
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        if !hasStartedFirstReceive {
            hasStartedFirstReceive = true
            await withCheckedContinuation { firstContinuation = $0 }
        }
        receivedIDs.append(input.metadata.id)
        return .accepted
    }

    func releaseFirstReceive() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor CancellationSensitiveGatedInboundInputService:
    RuneScribeInboundInputService {
    private(set) var receivedIDs: [InboundInputID] = []
    private(set) var hasStartedFirstReceive = false
    private(set) var cancellationObserved = false
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        if !hasStartedFirstReceive {
            hasStartedFirstReceive = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { firstContinuation = $0 }
            } onCancel: { [weak self] in
                guard let self else { return }
                Task.detached { await self.cancelFirstReceive() }
            }
            try Task.checkCancellation()
        }
        receivedIDs.append(input.metadata.id)
        return .accepted
    }

    func releaseFirstReceive() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func cancelFirstReceive() {
        cancellationObserved = true
        releaseFirstReceive()
    }
}

private actor ReportingInboundInputService: RuneScribeInboundInputService {
    private var callCount = 0

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        callCount += 1
        if callCount == 1 { return .rejected }
        throw ReportingInboundError.failed
    }
}

private actor RecordingInboundInputService: RuneScribeInboundInputService {
    private(set) var receivedIDs: [InboundInputID] = []

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        receivedIDs.append(input.metadata.id)
        return .accepted
    }
}

private enum ReportingInboundError: Error {
    case failed
}

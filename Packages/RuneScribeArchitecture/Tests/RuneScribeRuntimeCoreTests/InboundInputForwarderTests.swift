import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class InboundInputForwarderTests: XCTestCase {
    @MainActor
    func testInterleavedCallbackBatchesRemainFIFOAcrossAwait() async throws {
        let service = GatedInboundInputService()
        let forwarder = SerialInboundInputForwarder(service: service)
        let first = input(id: 1, event: .didBecomeActive)
        let second = input(id: 2, event: .willResignActive)
        let third = input(id: 3, event: .didEnterBackground)

        forwarder.submit(contentsOf: [first, second])
        while await !service.hasStartedFirstReceive { await Task.yield() }
        forwarder.submit(third)
        await service.releaseFirstReceive()
        await forwarder.flush()

        let received = await service.receivedIDs
        XCTAssertEqual(received, [first.metadata.id, second.metadata.id, third.metadata.id])
    }

    @MainActor
    func testBoundedQueueReservesControlCapacityAndReportsOverflow() async {
        let service = GatedInboundInputService()
        let forwarder = SerialInboundInputForwarder(service: service)
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
        while await !service.hasStartedFirstReceive { await Task.yield() }

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

        let controls = (1_000..<1_016).map { input(id: $0, event: .didEnterBackground) }
        XCTAssertEqual(
            forwarder.submit(contentsOf: controls),
            Array(repeating: .accepted, count: controls.count)
        )
        XCTAssertEqual(
            forwarder.submit(input(id: 1_016, event: .willTerminate)),
            .rejected
        )
        let expectedLocalRejections = 2
            + dataDispositions.filter { $0 == .rejected }.count
        XCTAssertEqual(forwarder.rejectedInputCount, expectedLocalRejections)

        await service.releaseFirstReceive()
        await forwarder.flush()

        let expectedIDs = ([first] + acceptedData + controls).map(\.metadata.id)
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
        let forwarder = SerialInboundInputForwarder(service: service)

        forwarder.submit(contentsOf: [
            input(id: 2_000, event: .didBecomeActive),
            input(id: 2_001, event: .willTerminate),
        ])
        await forwarder.flush()

        XCTAssertEqual(forwarder.rejectedInputCount, 1)
        XCTAssertEqual(forwarder.failedDeliveryCount, 1)
        XCTAssertTrue(forwarder.hasDeliveryFailures)
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

private enum ReportingInboundError: Error {
    case failed
}

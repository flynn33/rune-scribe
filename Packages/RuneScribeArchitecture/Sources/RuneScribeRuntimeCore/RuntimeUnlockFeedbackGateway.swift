import RuneScribeContracts

public struct RuntimeUnlockFeedbackClient: Sendable {
    private let gateway: RuntimeUnlockFeedbackGateway
    private let lease: ModuleContextLease

    init(
        gateway: RuntimeUnlockFeedbackGateway,
        lease: ModuleContextLease
    ) {
        self.gateway = gateway
        self.lease = lease
    }

    public func perform(_ request: UnlockFeedbackRequestDTO) async throws {
        try await lease.requireActive()
        try await gateway.perform(request)
        try await lease.requireActive()
    }
}

actor RuntimeUnlockFeedbackGateway {
    private var performHandler: (@Sendable (UnlockFeedbackRequestDTO) async -> Void)?

    func install(_ provider: any UnlockFeedbackProviding) throws {
        guard performHandler == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeUnlockFeedback.serviceID
            )
        }
        performHandler = { request in
            await provider.perform(request)
        }
    }

    func makeClient(lease: ModuleContextLease) -> RuntimeUnlockFeedbackClient? {
        guard performHandler != nil else { return nil }
        return RuntimeUnlockFeedbackClient(gateway: self, lease: lease)
    }

    fileprivate func perform(_ request: UnlockFeedbackRequestDTO) async throws {
        guard let performHandler else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeUnlockFeedback.serviceID
            )
        }
        await performHandler(request)
    }
}

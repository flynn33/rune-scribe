import Foundation
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
    private let resources: RuntimeOpaqueResourceRegistry?
    private var performHandler: (
        @Sendable (UnlockFeedbackRequestDTO, Data?) async -> Void
    )?

    init(resources: RuntimeOpaqueResourceRegistry? = nil) {
        self.resources = resources
    }

    func install(_ provider: any UnlockFeedbackProviding) throws {
        guard performHandler == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeUnlockFeedback.serviceID
            )
        }
        if let provider = provider as? any ThemeUnlockFeedbackProviding {
            performHandler = { request, providerSoundData in
                await provider.perform(
                    request,
                    providerSoundData: providerSoundData
                )
            }
        } else {
            performHandler = { request, _ in
                await provider.perform(request)
            }
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
        let providerSoundData = await resources?.unlockFeedbackSoundData(
            codexID: request.codexID,
            semanticID: request.soundSemanticID
        )
        await performHandler(request, providerSoundData)
    }
}

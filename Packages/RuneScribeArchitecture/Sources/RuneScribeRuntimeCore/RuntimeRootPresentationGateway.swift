import RuneScribeContracts
import RuneScribeUIPresentationContracts

private struct RuntimeRootPresentationLease: Hashable, Sendable {
    let runtimeGeneration: UInt64
    let sourceModuleID: ModuleIdentifier
    let sourceModuleGeneration: UInt64
}

actor RuntimeRootPresentationGateway {
    private struct ActiveModule: Sendable {
        let descriptor: ModuleDescriptor
        let generation: UInt64
    }

    private var hostAdapter: RuntimeRootPresentationHostAdapter?
    private var activeModules: [ModuleIdentifier: ActiveModule] = [:]
    private var activeOwner: RuntimeRootPresentationLease?
    private var runtimeGeneration: UInt64 = 0
    private var isRuntimeActive = false

    func install(
        _ adapter: RuntimeRootPresentationHostAdapter,
        for key: RuntimeRootPresentationPortKey
    ) throws {
        guard key == .standard else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(key.identifier)
        }
        guard hostAdapter == nil else {
            throw RuneScribeRuntimeError.duplicateService(key.identifier)
        }
        hostAdapter = adapter
    }

    @discardableResult
    func activateRuntime() -> UInt64 {
        runtimeGeneration &+= 1
        isRuntimeActive = true
        activeModules.removeAll(keepingCapacity: true)
        activeOwner = nil
        return runtimeGeneration
    }

    func deactivateRuntime() async {
        let owner = activeOwner
        activeOwner = nil
        activeModules.removeAll(keepingCapacity: false)
        isRuntimeActive = false
        if let owner, let hostAdapter {
            await hostAdapter.dismiss(moduleID: owner.sourceModuleID)
        }
    }

    func currentGeneration() -> UInt64 {
        runtimeGeneration
    }

    func activateModule(
        descriptor: ModuleDescriptor,
        generation: UInt64
    ) throws {
        guard isRuntimeActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        activeModules[descriptor.moduleID] = ActiveModule(
            descriptor: descriptor,
            generation: generation
        )
    }

    func invalidateModule(
        _ moduleID: ModuleIdentifier,
        generation: UInt64
    ) async {
        guard activeModules[moduleID]?.generation == generation else { return }
        activeModules.removeValue(forKey: moduleID)
        guard let owner = activeOwner,
              owner.sourceModuleID == moduleID,
              owner.sourceModuleGeneration == generation
        else { return }
        activeOwner = nil
        if let hostAdapter {
            await hostAdapter.dismiss(moduleID: moduleID)
        }
    }

    func makeClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration: UInt64,
        policy: RuntimePolicy
    ) throws -> RuntimeRootPresentationClient {
        let lease = RuntimeRootPresentationLease(
            runtimeGeneration: runtimeGeneration,
            sourceModuleID: sourceModuleID,
            sourceModuleGeneration: sourceModuleGeneration
        )
        let activeModule = try validate(lease)
        try authorize(activeModule.descriptor, policy: policy)

        return RuntimeRootPresentationClient(
            productMetadata: { [weak self] in
                guard let self else {
                    throw RuneScribeRuntimeError.contextInactive(sourceModuleID)
                }
                return try await self.productMetadata(for: lease)
            },
            present: { [weak self] contribution in
                guard let self else {
                    throw RuneScribeRuntimeError.contextInactive(sourceModuleID)
                }
                try await self.present(contribution, for: lease)
            },
            dismiss: { [weak self] in
                guard let self else {
                    throw RuneScribeRuntimeError.contextInactive(sourceModuleID)
                }
                try await self.dismiss(for: lease)
            }
        )
    }

    private func productMetadata(
        for lease: RuntimeRootPresentationLease
    ) throws -> RuneScribeUIProductMetadata {
        _ = try validate(lease)
        guard let hostAdapter else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuntimeRootPresentationPortKey.standard.identifier
            )
        }
        return hostAdapter.productMetadata
    }

    private func present(
        _ contribution: RootViewContribution,
        for lease: RuntimeRootPresentationLease
    ) async throws {
        _ = try validate(lease)
        guard contribution.moduleID == lease.sourceModuleID else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: RuntimeRootPresentationPortKey.standard.identifier
            )
        }
        guard let hostAdapter else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuntimeRootPresentationPortKey.standard.identifier
            )
        }
        if let activeOwner, activeOwner != lease {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: RuntimeRootPresentationPortKey.standard.identifier
            )
        }

        activeOwner = lease
        do {
            try await hostAdapter.present(contribution)
            _ = try validate(lease)
        } catch {
            if activeOwner == lease {
                activeOwner = nil
                await hostAdapter.dismiss(moduleID: lease.sourceModuleID)
            }
            throw error
        }
    }

    private func dismiss(for lease: RuntimeRootPresentationLease) async throws {
        _ = try validate(lease)
        guard activeOwner == lease else { return }
        activeOwner = nil
        if let hostAdapter {
            await hostAdapter.dismiss(moduleID: lease.sourceModuleID)
        }
    }

    private func validate(
        _ lease: RuntimeRootPresentationLease
    ) throws -> ActiveModule {
        guard isRuntimeActive,
              runtimeGeneration == lease.runtimeGeneration
        else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard let activeModule = activeModules[lease.sourceModuleID],
              activeModule.generation == lease.sourceModuleGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        return activeModule
    }

    private func authorize(
        _ descriptor: ModuleDescriptor,
        policy: RuntimePolicy
    ) throws {
        let capability = RuneScribeCapabilities.rootUI
        guard descriptor.requestedCapabilities.contains(capability),
              policy.capabilities.allows(capability, for: descriptor.role)
        else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: descriptor.moduleID,
                capability: capability
            )
        }
    }
}

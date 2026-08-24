import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

/// Applies deterministic optional-provider ownership only to an explicitly
/// requested Simulator qualification launch. Device and macOS launches are
/// unchanged.
public enum RuneScribeRuntimeSimulatorQualification {
    public static func applyIfRequested(
        to runtime: RuneScribeRuntime,
        optionalProviderUnlockIDs: [String: UnlockID],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        #if targetEnvironment(simulator)
        guard let provider = environment["RUNESCRIBE_QUALIFICATION_UNLOCK_CODEX"],
              let unlockID = optionalProviderUnlockIDs[provider]
        else { return }
        try await runtime.reconcileEntitlements(
            try ProgressionEntitlementSnapshotDTO(
                revision: UInt64.max - 1,
                capturedAt: Date(),
                includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                earnedUnlockIDs: [unlockID]
            )
        )
        #endif
    }
}

import RuneScribeContracts
import RuneScribeRuntimeCore

protocol ProgressionStateClient: Sendable {
    func prepare(schemaVersion: UInt32) async throws -> ModuleStateHealthSnapshot
    func fetch(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID
    ) async throws -> ModuleStateRecord?
    func scan(_ request: ModuleStateScanRequest) async throws -> ModuleStateScanPage
    func transact(_ transaction: ModuleStateTransaction) async throws
        -> ModuleStateTransactionResult
    func quarantine(diagnosticCode: String) async throws -> ModuleStateHealthSnapshot
    func quarantineRecord(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot
    func health() async throws -> ModuleStateHealthSnapshot
}

extension RuntimeModuleStateClient: ProgressionStateClient {}

import Foundation
import RuneScribeContracts

struct UnavailableInboundFileReader: InboundFileReader {
    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        throw InboundFileReaderError.unavailable
    }
}

/// Narrow internal seams let import/message orchestration remain independent of
/// the concrete contact and font persistence components while those components
/// retain ownership of their private domain values.
protocol CoreFontIntegrating: Sendable {
    func data(for reference: FontRef) async throws -> Data?
    func ensureAvailable(reference: FontRef, suppliedBytes: Data?) async throws
}

protocol CoreMessageContactAssociating: Sendable {
    func prepareImportedContact(named displayName: String) async throws
        -> PreparedMessageContact
    func commitPreparedImportedContact(
        _ prepared: PreparedMessageContact
    ) async throws -> ContactMutation<Contact>
    func stageMessageAssociation(
        _ prepared: PreparedMessageContact,
        cipherID: UUID,
        previousContactID: UUID?
    ) async throws -> MessageContactAssociationIntent
    func completeMessageAssociation(
        _ intent: MessageContactAssociationIntent
    ) async throws
}

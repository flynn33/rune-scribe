import Foundation
import RuneScribeContracts

struct PendingCipherImport: Sendable {
    let id: ImportID
    let payload: CipherSharePayload
    let suggestedName: String
    let source: ImportSourceDTO
    let fontBytes: Data?
    let dedupeKey: Data

    var summary: PendingImportSummary {
        PendingImportSummary(
            id: id,
            suggestedName: suggestedName,
            source: source,
            includesFont: fontBytes?.isEmpty == false
        )
    }
}

enum ImportUseCase {
    static func pending(
        payload: CipherSharePayload,
        fontBytes: Data?,
        id: ImportID,
        source: ImportSourceDTO,
        dedupeKey: Data
    ) -> PendingCipherImport {
        let supplied = payload.parsedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggested = supplied.flatMap { $0.isEmpty ? nil : $0 } ?? "Imported Cipher"
        return PendingCipherImport(
            id: id,
            payload: payload,
            suggestedName: String(suggested.prefix(40)),
            source: source,
            fontBytes: fontBytes,
            dedupeKey: dedupeKey
        )
    }
}

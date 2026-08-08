// RuneScrib/Views/Components/DecoderDocument.swift

import SwiftUI
import UniformTypeIdentifiers

/// The app's exported document type — the single `.runescribe` UTI shared by
/// ciphers and messages (disambiguated by leading version byte, never by type).
/// Matches `UTExportedTypeDeclarations` in `project.yml` and `RuneScribeShare.uti`.
extension UTType {
    static let runeScribe = UTType(exportedAs: "com.runescribe.runescribe")
}

/// A scoped Core-produced file reference for SwiftUI export/share presentation.
/// The hosted UI never reads or recreates the encrypted transport bytes.
struct RuneScribeExportArtifact: Transferable {
    let url: URL
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .runeScribe) { file in
            SentTransferredFile(file.url)
        }
        .suggestedFileName { "\($0.filename).\(RuneScribeShare.fileExtension)" }
    }
}

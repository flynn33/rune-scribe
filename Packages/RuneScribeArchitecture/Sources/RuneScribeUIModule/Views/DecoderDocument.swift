import RuneScribeContracts
import SwiftUI
import UniformTypeIdentifiers

/// The app's exported document type — the single `.runescribe` UTI shared by
/// ciphers and messages (disambiguated by leading version byte, never by type).
/// Matches the application's exported type declaration and shared wire contract.
extension UTType {
    static let runeScribe = UTType(exportedAs: RuneScribeWireFormat.contentType)
}

/// A scoped Core-produced file reference for SwiftUI export/share presentation.
/// The UI never reads or recreates the encrypted transport bytes.
struct RuneScribeExportArtifact: Transferable {
    let url: URL
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .runeScribe) { file in
            SentTransferredFile(file.url)
        }
        .suggestedFileName { artifact in
            artifact.filename + "." + RuneScribeWireFormat.fileExtension
        }
    }
}

// RuneScrib/Views/Components/DecoderDocument.swift

import SwiftUI
import UniformTypeIdentifiers

/// The app's exported document type — the single `.runescribe` UTI shared by
/// ciphers and messages (disambiguated by leading version byte, never by type).
/// Matches `UTExportedTypeDeclarations` in `project.yml` and `RuneScribeShare.uti`.
extension UTType {
    static let runeScribe = UTType(exportedAs: "com.runescribe.runescribe")
}

/// A single-file decoder document used by SwiftUI's cross-platform
/// `.fileExporter`. The whole decoder/decrypter — the cipher mapping, metadata,
/// and font bytes — is exactly one `.runescribe` file.
struct DecoderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.runeScribe] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A `Transferable` `.runescribe` file for `ShareLink`, used by the cipher library
/// (exported cipher) and the encode result (outbound message). It materializes the
/// bytes into a temp file with a `.runescribe` extension so the share sheet hands
/// other apps a real, correctly-typed file rather than a raw data blob.
struct RuneScribeShareFile: Transferable {
    let data: Data
    /// Base filename without extension; the `.runescribe` extension is always appended.
    let filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    static var transferRepresentation: some TransferRepresentation {
        // A real, correctly-typed file (preferred by AirDrop / Save to Files).
        FileRepresentation(exportedContentType: .runeScribe) { file in
            // Unique subdirectory so repeated/concurrent shares never collide on the name.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir
                .appendingPathComponent(file.filename)
                .appendingPathExtension(RuneScribeShare.fileExtension)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        .suggestedFileName { "\($0.filename).\(RuneScribeShare.fileExtension)" }

        // Fallback: several destinations (Messages, Mail) silently drop a lone
        // app-internal FileRepresentation under iOS 17's Transferable behavior, so
        // they fall through to this data representation and actually receive the file.
        DataRepresentation(exportedContentType: .runeScribe) { $0.data }
            .suggestedFileName { "\($0.filename).\(RuneScribeShare.fileExtension)" }
    }
}

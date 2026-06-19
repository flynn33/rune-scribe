// RuneScrib/Views/Components/DecoderDocument.swift

import SwiftUI
import UniformTypeIdentifiers

/// A single-file decoder document (JSON) used by SwiftUI's cross-platform
/// `.fileExporter`. The whole decoder/decrypter — the cipher mapping and its
/// metadata — is exactly one `.json` file.
struct DecoderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

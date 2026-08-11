import RuneScribeContracts
import SwiftUI
import UniformTypeIdentifiers

/// The app's exported document type — the single `.runescribe` UTI shared by
/// ciphers and messages (disambiguated by leading version byte, never by type).
/// Matches the application's exported type declaration and shared wire contract.
extension UTType {
    static let runeScribe = UTType(exportedAs: RuneScribeWireFormat.contentType)
}

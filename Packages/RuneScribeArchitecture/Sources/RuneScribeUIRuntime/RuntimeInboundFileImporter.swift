import RuneScribeContracts
@_spi(RuntimeFileImportHost) import RuneScribeRuntimeCore
import SwiftUI
import UniformTypeIdentifiers

private enum RuntimeInboundFileImporterError: Error {
    case selectionMissing
}

private extension UTType {
    static let runtimeInboundRuneScribe = UTType(
        exportedAs: RuneScribeWireFormat.contentType
    )
}

private struct RuntimeInboundFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let session: RuntimeInboundFileImportSession
    let onCompletion: @MainActor (Result<ImportResultDTO, Error>) -> Void

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: [.runtimeInboundRuneScribe],
            allowsMultipleSelection: false
        ) { selection in
            switch selection {
            case .success(let urls):
                guard let selectedURL = urls.first else {
                    onCompletion(.failure(RuntimeInboundFileImporterError.selectionMissing))
                    return
                }
                Task { @MainActor in
                    do {
                        let result = try await session.importSelectedFile(selectedURL)
                        onCompletion(.success(result))
                    } catch {
                        onCompletion(.failure(error))
                    }
                }
            case .failure(let error):
                onCompletion(.failure(error))
            }
        }
    }
}

public extension View {
    func runtimeInboundFileImporter(
        isPresented: Binding<Bool>,
        session: RuntimeInboundFileImportSession,
        onCompletion: @escaping @MainActor (
            Result<ImportResultDTO, Error>
        ) -> Void
    ) -> some View {
        modifier(
            RuntimeInboundFileImporterModifier(
                isPresented: isPresented,
                session: session,
                onCompletion: onCompletion
            )
        )
    }
}

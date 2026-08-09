import CoreText
import Foundation
import RuneScribeContracts

public enum CoreTextFontRegistrarError: Error, Equatable, Sendable {
    case invalidFontData
    case registrationFailed(Int)
}

/// Registers validated font bytes for the current process through CoreText.
public struct CoreTextFontRegistrar: SystemFontRegistrar, Sendable {
    private let operations: FontOperations

    public init() {
        operations = .coreText
    }

    init(operations: FontOperations) {
        self.operations = operations
    }

    public func postScriptName(forFontData data: Data) async throws -> String {
        guard let name = operations.postScriptName(data), !name.isEmpty else {
            throw CoreTextFontRegistrarError.invalidFontData
        }
        return name
    }

    public func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        let name = try await postScriptName(forFontData: data)
        switch operations.register(data) {
        case .registered, .alreadyRegistered:
            return RegisteredFontDTO(postScriptName: name)
        case .failed(let code):
            throw CoreTextFontRegistrarError.registrationFailed(code)
        }
    }
}

enum FontRegistrationResult: Equatable, Sendable {
    case registered
    case alreadyRegistered
    case failed(Int)
}

struct FontOperations: Sendable {
    let postScriptName: @Sendable (Data) -> String?
    let register: @Sendable (Data) -> FontRegistrationResult

    static let coreText = FontOperations(
        postScriptName: { data in
            guard let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider)
            else { return nil }
            return font.postScriptName as String?
        },
        register: { data in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RuneScribeFontRegistration-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent("font.ttf")
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: url, options: .atomic)
                #endif

                var unmanagedError: Unmanaged<CFError>?
                guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError) else {
                    return .registered
                }

                let code = unmanagedError
                    .map { Int(CFErrorGetCode($0.takeRetainedValue())) }
                    ?? CTFontManagerError.registrationFailed.rawValue
                return code == CTFontManagerError.alreadyRegistered.rawValue
                    ? .alreadyRegistered
                    : .failed(code)
            } catch {
                return .failed(CTFontManagerError.registrationFailed.rawValue)
            }
        }
    )
}

import CoreText
import CryptoKit
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
            if code == CTFontManagerError.duplicatedName.rawValue,
               operations.registeredFontMatches(data)
            {
                return RegisteredFontDTO(postScriptName: name)
            }
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
    let registeredFontMatches: @Sendable (Data) -> Bool

    init(
        postScriptName: @escaping @Sendable (Data) -> String?,
        register: @escaping @Sendable (Data) -> FontRegistrationResult,
        registeredFontMatches: @escaping @Sendable (Data) -> Bool = { _ in false }
    ) {
        self.postScriptName = postScriptName
        self.register = register
        self.registeredFontMatches = registeredFontMatches
    }

    static let coreText = FontOperations(
        postScriptName: { data in
            guard let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider)
            else { return nil }
            return font.postScriptName as String?
        },
        register: { data in
            guard let url = try? persistentFontURL(for: data) else {
                return .failed(CTFontManagerError.registrationFailed.rawValue)
            }

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
        },
        registeredFontMatches: { data in
            guard let provider = CGDataProvider(data: data as CFData),
                  let candidate = CGFont(provider),
                  let candidateName = candidate.postScriptName
            else { return false }

            let activeFont = CTFontCreateWithName(candidateName, 12, nil)
            guard CTFontCopyPostScriptName(activeFont) == candidateName else { return false }
            let activeGraphicsFont = CTFontCopyGraphicsFont(activeFont, nil)

            let descriptor = CTFontCopyFontDescriptor(activeFont)
            if let activeURL = CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontURLAttribute
            ) as? URL,
               let activeData = try? Data(contentsOf: activeURL, options: .mappedIfSafe)
            {
                if activeData == data { return true }
            }

            return fontsHaveIdenticalTables(candidate, activeGraphicsFont)
        }
    )
}

private func persistentFontURL(for data: Data) throws -> URL {
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RuneScribe", isDirectory: true)
        .appendingPathComponent("RegisteredFonts", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let url = directory.appendingPathComponent("\(digest).font", isDirectory: false)
    if let existingData = try? Data(contentsOf: url, options: .mappedIfSafe),
       existingData == data
    {
        return url
    }

    try data.write(to: url, options: .atomic)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
    return url
}

private func fontsHaveIdenticalTables(_ candidate: CGFont, _ active: CGFont) -> Bool {
    let candidateFont = CTFontCreateWithGraphicsFont(candidate, 12, nil, nil)
    let activeFont = CTFontCreateWithGraphicsFont(active, 12, nil, nil)
    guard let candidateTags = fontTableTags(candidateFont),
          let activeTags = fontTableTags(activeFont),
          !candidateTags.isEmpty,
          candidateTags == activeTags
    else { return false }

    return candidateTags.allSatisfy { tag in
        guard let candidateTable = CTFontCopyTable(candidateFont, tag, []) as Data?,
              let activeTable = CTFontCopyTable(activeFont, tag, []) as Data?
        else { return false }
        return candidateTable == activeTable
    }
}

private func fontTableTags(_ font: CTFont) -> Set<CTFontTableTag>? {
    guard let values = CTFontCopyAvailableTables(font, []) else { return nil }
    let count = CFArrayGetCount(values)
    var tags = Set<CTFontTableTag>()
    tags.reserveCapacity(count)
    for index in 0 ..< count {
        let value = CFArrayGetValueAtIndex(values, index)
        tags.insert(CTFontTableTag(UInt(bitPattern: value)))
    }
    return tags
}

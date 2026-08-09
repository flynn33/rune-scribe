import Combine
import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

@MainActor
final class RuneScribeUISession: ObservableObject {
    @Published private(set) var snapshot: RuneScribeApplicationSnapshot?
    @Published private(set) var lastError: String?
    @Published var importErrorMessage: String?
    @Published var messageErrorMessage: String?
    @Published private(set) var route: RuneScribeUIRouteRequest?

    let splashVideoURL: URL?
    let metalLibraryURL: URL?
    let appVersion: String
    let buildNumber: String

    private var applicationServiceHandle: (any RuneScribeApplicationService)?
    private var clipboardWritingHandle: (any ClipboardWriting)?
    private var sharePresentationHandle: OpaqueSharePresentationProvider?

    var contactSystemIdentifiers: [UUID: String] = [:]
    private var stateTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var observationGeneration: UInt64 = 0

    init(
        applicationService: any RuneScribeApplicationService,
        clipboardWriting: any ClipboardWriting,
        sharePresentation: OpaqueSharePresentationProvider,
        splashVideoURL: URL?,
        metalLibraryURL: URL?,
        productMetadata: RuneScribeUIProductMetadata
    ) {
        applicationServiceHandle = applicationService
        clipboardWritingHandle = clipboardWriting
        sharePresentationHandle = sharePresentation
        self.splashVideoURL = splashVideoURL
        self.metalLibraryURL = metalLibraryURL
        appVersion = productMetadata.version
        buildNumber = productMetadata.buildNumber
    }

    deinit {
        stateTask?.cancel()
        menuTask?.cancel()
    }

    func start() throws {
        guard stateTask == nil, menuTask == nil else { return }
        let service = try requireApplicationService()
        observationGeneration &+= 1
        let generation = observationGeneration
        stateTask = Task { @MainActor [weak self, service] in
            for await nextSnapshot in service.stateStream() {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                adopt(nextSnapshot)
            }
        }
        menuTask = Task { @MainActor [weak self, service] in
            for await command in service.menuCommandStream() {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                switch command {
                case .openCipherLibrary:
                    requestRoute(.openCipherLibrary)
                case .openSettings:
                    requestRoute(.openSettings)
                }
            }
        }
    }

    func stop() async {
        observationGeneration &+= 1
        let stateTask = self.stateTask
        let menuTask = self.menuTask
        stateTask?.cancel()
        menuTask?.cancel()
        self.stateTask = nil
        self.menuTask = nil
        snapshot = nil
        lastError = nil
        importErrorMessage = nil
        messageErrorMessage = nil
        route = nil
        contactSystemIdentifiers.removeAll()
        applicationServiceHandle = nil
        clipboardWritingHandle = nil
        sharePresentationHandle = nil
        await stateTask?.value
        await menuTask?.value
    }

    var isLoading: Bool {
        snapshot?.cipherLibrary.isLoading ?? true
    }

    var ciphers: [CipherViewState] {
        guard let snapshot else { return [] }
        let fonts = Dictionary(uniqueKeysWithValues: snapshot.fonts.map { ($0.id, $0) })
        return snapshot.cipherLibrary.ciphers.map { summary in
            CipherViewState(
                id: summary.id.rawValue,
                label: summary.name,
                origin: summary.origin,
                createdAt: summary.createdAt,
                isActive: summary.isActive,
                contactID: summary.assignedContactID?.rawValue,
                delivered: summary.hasBeenDelivered,
                publicIdentifier: summary.publicIdentifier,
                fontName: fonts[summary.fontID]?.displayName ?? "Noto Sans Runic"
            )
        }
    }

    var activeCipher: CipherViewState? {
        ciphers.first(where: \.isActive)
    }

    var contacts: [ContactViewState] {
        guard let snapshot else { return [] }
        return snapshot.contactLibrary.contacts.map { summary in
            ContactViewState(
                summary: summary,
                systemIdentifier: contactSystemIdentifiers[summary.id.rawValue]
            )
        }
    }

    var importedContactCount: Int {
        snapshot?.contactLibrary.importedCount ?? 0
    }

    var isPINSet: Bool {
        snapshot?.lockState.isPINSet ?? false
    }

    var isLocked: Bool {
        snapshot?.lockState.isLocked ?? false
    }

    var pendingImport: PendingImportSummary? {
        snapshot?.importState.pending
    }

    var pendingMessage: PendingMessageViewState? {
        snapshot?.messageState.pendingMessage.map(PendingMessageViewState.init)
    }

    func ciphers(forContact contactID: UUID) -> [CipherViewState] {
        ciphers.filter { $0.contactID == contactID }
    }

    func contact(id: UUID?) -> ContactViewState? {
        id.flatMap { id in contacts.first { $0.id == id } }
    }

    func requestRoute(_ route: RuneScribeUIRoute) {
        self.route = RuneScribeUIRouteRequest(route: route)
    }

    func consumeRoute(id: UUID) {
        guard route?.id == id else { return }
        route = nil
    }

    func copyToClipboard(_ value: String) async {
        do {
            try await requireClipboardWriter().setString(value)
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    func viewState(for summary: CipherSummary) -> CipherViewState {
        if let current = ciphers.first(where: { $0.id == summary.id.rawValue }) {
            return current
        }
        let fontName = snapshot?.fonts.first(where: { $0.id == summary.fontID })?.displayName
            ?? "Noto Sans Runic"
        return CipherViewState(
            id: summary.id.rawValue,
            label: summary.name,
            origin: summary.origin,
            createdAt: summary.createdAt,
            isActive: summary.isActive,
            contactID: summary.assignedContactID?.rawValue,
            delivered: summary.hasBeenDelivered,
            publicIdentifier: summary.publicIdentifier,
            fontName: fontName
        )
    }

    func perform<Result>(_ operation: () async throws -> Result) async throws -> Result {
        do {
            let result = try await operation()
            lastError = nil
            return result
        } catch {
            lastError = Self.message(for: error)
            throw error
        }
    }

    func recordPresentationError(_ error: Error) {
        lastError = Self.message(for: error)
    }

    func requireApplicationService() throws -> any RuneScribeApplicationService {
        guard let applicationServiceHandle else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .temporarilyUnavailable)
            )
        }
        return applicationServiceHandle
    }

    func requireSharePresentation() throws -> OpaqueSharePresentationProvider {
        guard let sharePresentationHandle else {
            throw OpaqueSharePresentationError.unavailable
        }
        return sharePresentationHandle
    }

    private func requireClipboardWriter() throws -> any ClipboardWriting {
        guard let clipboardWritingHandle else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .temporarilyUnavailable)
            )
        }
        return clipboardWritingHandle
    }

    static func message(for error: Error) -> String {
        if let productError = error as? RuneScribeProductError,
           case .failure(let failure) = productError {
            return message(for: failure)
        }
        return "Rune Scribe could not complete the operation."
    }

    static func message(for failure: RuneScribeFailureDTO) -> String {
        switch failure.code {
        case .invalidInput: "The information provided is not valid."
        case .itemNotFound: "The requested item is no longer available."
        case .unsupportedFormat: "This Rune Scribe format is not supported."
        case .corruptedContent: "This Rune Scribe item is damaged or incomplete."
        case .noMatchingCipher: "No cipher in your library can decode this message."
        case .authorizationDenied: "Permission was not granted."
        case .authenticationFailed: "Authentication failed."
        case .lockedOut: "Try again later."
        case .secureStorageUnavailable: "Secure storage is unavailable."
        case .protectedFileUnavailable: "The protected file could not be opened."
        case .resourceUnavailable: "A required app resource is unavailable."
        case .shareUnavailable: "The item could not be prepared for sharing."
        case .operationCancelled: "The operation was cancelled."
        case .temporarilyUnavailable: "The operation is temporarily unavailable."
        case .internalFailure: "Rune Scribe could not complete the operation."
        }
    }

    private func adopt(_ nextSnapshot: RuneScribeApplicationSnapshot) {
        let retainedContactIDs = Set(nextSnapshot.contactLibrary.contacts.map { $0.id.rawValue })
        contactSystemIdentifiers = contactSystemIdentifiers.filter {
            retainedContactIDs.contains($0.key)
        }
        snapshot = nextSnapshot
        lastError = nextSnapshot.lastFailure.map(Self.message(for:))
        adoptImportPresentation(nextSnapshot.importState)
        adoptMessagePresentation(nextSnapshot.messageState)
    }

    private func adoptImportPresentation(_ state: ImportStateDTO) {
        guard state.phase == .failed, let failure = state.lastFailure else {
            importErrorMessage = nil
            return
        }
        switch failure.code {
        case .invalidInput, .unsupportedFormat, .corruptedContent:
            importErrorMessage = "This isn't a valid Rune Scribe import."
        case .protectedFileUnavailable:
            importErrorMessage = "Rune Scribe could not open this file."
        case .noMatchingCipher:
            importErrorMessage = "This message couldn't be read with your ciphers."
        default:
            importErrorMessage = "Rune Scribe could not complete the import."
        }
    }

    private func adoptMessagePresentation(_ state: MessageStateDTO) {
        guard state.phase == .failed, let failure = state.lastFailure else {
            messageErrorMessage = nil
            return
        }
        switch failure.code {
        case .noMatchingCipher:
            messageErrorMessage = "This message couldn't be read with your ciphers."
        case .invalidInput, .unsupportedFormat, .corruptedContent:
            messageErrorMessage = "This message couldn't be read."
        default:
            messageErrorMessage = "Rune Scribe could not complete the message import."
        }
    }
}

import Combine
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime

@MainActor
final class RuneScribeUISession: ObservableObject {
    @Published private(set) var snapshot: RuneScribeApplicationSnapshot?
    @Published private(set) var lastError: String?
    @Published var importErrorMessage: String?
    @Published var messageErrorMessage: String?
    @Published private(set) var route: RuneScribeUIRouteRequest?
    @Published private(set) var availabilitySnapshot: RuntimeAvailabilitySnapshot?
    @Published var progressionSnapshot: ProgressionSnapshotDTO?
    @Published var progressionRailState: OptionalProgressionRailState = .unavailable
    @Published var runtimeSettingsSnapshot: RuntimeSettingsSnapshotDTO?
    @Published var settingsRailState: OptionalProgressionRailState = .unavailable
    @Published var unlockFeedbackPreferences = UnlockFeedbackPreferences.defaults
    @Published var activeReveal: ProgressionRevealSummaryDTO?
    @Published var progressionCommandError: String?

    let resourcePresentation: RuntimeApplicationResourcePresentation
    let inboundFileImportSession: RuntimeInboundFileImportSession
    let appVersion: String
    let buildNumber: String

    private var applicationClientHandle: RuntimeApplicationClient?
    private var runtimeIOHandle: RuntimeIOClient?
    private var availabilityClientHandle: RuntimeAvailabilityClient?
    var progressionClientHandle: RuntimeProgressionClient?
    var runtimeSettingsClientHandle: RuntimeSettingsClient?
    var unlockFeedbackClientHandle: RuntimeUnlockFeedbackClient?

    var contactSystemIdentifiers: [UUID: String] = [:]
    private var stateTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    var progressionTask: Task<Void, Never>?
    var settingsTask: Task<Void, Never>?
    var observationGeneration: UInt64 = 0
    var revealQueue = ProgressionRevealQueueModel()

    init(
        applicationClient: RuntimeApplicationClient,
        runtimeIO: RuntimeIOClient,
        availabilityClient: RuntimeAvailabilityClient? = nil,
        progressionClient: RuntimeProgressionClient? = nil,
        runtimeSettingsClient: RuntimeSettingsClient? = nil,
        unlockFeedbackClient: RuntimeUnlockFeedbackClient? = nil,
        inboundFileImportSession: RuntimeInboundFileImportSession = .unavailable,
        resourcePresentation: RuntimeApplicationResourcePresentation,
        productMetadata: RuneScribeUIProductMetadata
    ) {
        applicationClientHandle = applicationClient
        runtimeIOHandle = runtimeIO
        availabilityClientHandle = availabilityClient
        progressionClientHandle = progressionClient
        runtimeSettingsClientHandle = runtimeSettingsClient
        unlockFeedbackClientHandle = unlockFeedbackClient
        self.inboundFileImportSession = inboundFileImportSession
        self.resourcePresentation = resourcePresentation
        appVersion = productMetadata.version
        buildNumber = productMetadata.buildNumber
    }

    deinit {
        stateTask?.cancel()
        menuTask?.cancel()
        availabilityTask?.cancel()
        progressionTask?.cancel()
        settingsTask?.cancel()
    }

    func start() throws {
        guard stateTask == nil, menuTask == nil else { return }
        let client = try requireApplicationClient()
        observationGeneration &+= 1
        let generation = observationGeneration
        stateTask = Task { @MainActor [weak self, client] in
            for await envelope in client.applicationStateEnvelopes {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                adopt(envelope.payload)
            }
        }
        menuTask = Task { @MainActor [weak self, client] in
            for await envelope in client.menuCommandEnvelopes {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                switch envelope.payload {
                case .openCipherLibrary:
                    requestRoute(.openCipherLibrary)
                case .openSettings:
                    requestRoute(.openSettings)
                }
            }
        }
        if let availabilityClientHandle {
            availabilityTask = Task { @MainActor [weak self, availabilityClientHandle] in
                do {
                    let initial = try await availabilityClientHandle.snapshot()
                    guard !Task.isCancelled,
                          let self,
                          observationGeneration == generation
                    else { return }
                    availabilitySnapshot = initial

                    let snapshots = try await availabilityClientHandle.snapshots()
                    for await snapshot in snapshots {
                        guard !Task.isCancelled,
                              observationGeneration == generation
                        else { return }
                        availabilitySnapshot = snapshot
                    }
                } catch {
                    return
                }
            }
        }
        startOptionalProgressionObservation(generation: generation)
        startOptionalSettingsObservation(generation: generation)
    }

    func stop() async {
        observationGeneration &+= 1
        let stateTask = self.stateTask
        let menuTask = self.menuTask
        let availabilityTask = self.availabilityTask
        let progressionTask = self.progressionTask
        let settingsTask = self.settingsTask
        stateTask?.cancel()
        menuTask?.cancel()
        availabilityTask?.cancel()
        progressionTask?.cancel()
        settingsTask?.cancel()
        self.stateTask = nil
        self.menuTask = nil
        self.availabilityTask = nil
        self.progressionTask = nil
        self.settingsTask = nil
        snapshot = nil
        availabilitySnapshot = nil
        progressionSnapshot = nil
        progressionRailState = .unavailable
        runtimeSettingsSnapshot = nil
        settingsRailState = .unavailable
        unlockFeedbackPreferences = .defaults
        activeReveal = nil
        progressionCommandError = nil
        resetRevealPresentationState()
        lastError = nil
        importErrorMessage = nil
        messageErrorMessage = nil
        route = nil
        contactSystemIdentifiers.removeAll()
        applicationClientHandle = nil
        runtimeIOHandle = nil
        availabilityClientHandle = nil
        progressionClientHandle = nil
        runtimeSettingsClientHandle = nil
        unlockFeedbackClientHandle = nil
        await resourcePresentation.close()
        await stateTask?.value
        await menuTask?.value
        await availabilityTask?.value
        await progressionTask?.value
        await settingsTask?.value
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

    @discardableResult
    func copyToClipboard(_ value: String) async -> Bool {
        do {
            try await requireRuntimeIOClient().setClipboardString(value)
            lastError = nil
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
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

    func dismissLastError() {
        lastError = nil
    }

    func requireApplicationClient() throws -> RuntimeApplicationClient {
        guard let applicationClientHandle else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .temporarilyUnavailable)
            )
        }
        return applicationClientHandle
    }

    func requireRuntimeIOClient() throws -> RuntimeIOClient {
        guard let runtimeIOHandle else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .temporarilyUnavailable)
            )
        }
        return runtimeIOHandle
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

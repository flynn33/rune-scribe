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
    @Published private(set) var themeSnapshot: ThemeCoordinatorSnapshotDTO?
    @Published private(set) var themeScriptPresentation = ThemeScriptPresentation.baseFallback
    var themeUnlockAnimationDataByTier: [String: Data] = [:]
    @Published var themeSelectionError: String?
    @Published var runtimeSettingsSnapshot: RuntimeSettingsSnapshotDTO?
    @Published var settingsRailState: OptionalProgressionRailState = .unavailable
    @Published var runtimePresentationSettingsReady = false
    @Published var contactsImportPrompted = false
    @Published var splashLastShownAt: Date?
    @Published private(set) var cloudGameCenterStatus: RuntimeCloudGameCenterStatusSnapshotDTO?
    @Published private(set) var cloudGameCenterError: String?
    @Published var unlockFeedbackPreferences = UnlockFeedbackPreferences.defaults
    @Published var activeReveal: ProgressionRevealSummaryDTO?
    @Published var progressionCommandError: String?
    @Published var selectedThemeRelicID: ArtifactID?
    @Published var selectedThemeSealID: ArtifactID?
    @Published var selectedThemeFrameID: ArtifactID?
    @Published private(set) var outboundSharePresentationStatus: OutboundSharePresentationStatus = .idle

    let resourcePresentation: RuntimeApplicationResourcePresentation
    let inboundFileImportSession: RuntimeInboundFileImportSession
    let appVersion: String
    let buildNumber: String

    private var applicationClientHandle: RuntimeApplicationClient?
    var runtimeIOHandle: RuntimeIOClient?
    private var availabilityClientHandle: RuntimeAvailabilityClient?
    var progressionClientHandle: RuntimeProgressionClient?
    var themeCoordinatorClientHandle: RuntimeThemeCoordinatorClient?
    var runtimeSettingsClientHandle: RuntimeSettingsClient?
    private var cloudGameCenterStatusClientHandle: RuntimeCloudGameCenterStatusClient?
    var unlockFeedbackClientHandle: RuntimeUnlockFeedbackClient?

    var contactSystemIdentifiers: [UUID: String] = [:]
    private var stateTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    var progressionTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var themeResourceTask: Task<Void, Never>?
    private var themeAdoptionGeneration: UInt64 = 0
    private var latestThemeCoordinatorRevision: UInt64?
    var settingsTask: Task<Void, Never>?
    private var cloudGameCenterStatusTask: Task<Void, Never>?
    var observationGeneration: UInt64 = 0
    var revealQueue = ProgressionRevealQueueModel()

    init(
        applicationClient: RuntimeApplicationClient,
        runtimeIO: RuntimeIOClient,
        availabilityClient: RuntimeAvailabilityClient? = nil,
        progressionClient: RuntimeProgressionClient? = nil,
        themeCoordinatorClient: RuntimeThemeCoordinatorClient? = nil,
        runtimeSettingsClient: RuntimeSettingsClient? = nil,
        cloudGameCenterStatusClient: RuntimeCloudGameCenterStatusClient? = nil,
        unlockFeedbackClient: RuntimeUnlockFeedbackClient? = nil,
        inboundFileImportSession: RuntimeInboundFileImportSession = .unavailable,
        resourcePresentation: RuntimeApplicationResourcePresentation,
        productMetadata: RuneScribeUIProductMetadata
    ) {
        applicationClientHandle = applicationClient
        runtimeIOHandle = runtimeIO
        availabilityClientHandle = availabilityClient
        progressionClientHandle = progressionClient
        themeCoordinatorClientHandle = themeCoordinatorClient
        runtimeSettingsClientHandle = runtimeSettingsClient
        cloudGameCenterStatusClientHandle = cloudGameCenterStatusClient
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
        themeTask?.cancel()
        themeResourceTask?.cancel()
        settingsTask?.cancel()
        cloudGameCenterStatusTask?.cancel()
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
        if let themeCoordinatorClientHandle {
            themeTask = Task { @MainActor [weak self, themeCoordinatorClientHandle] in
                for await envelope in themeCoordinatorClientHandle.stateEnvelopes {
                    guard !Task.isCancelled,
                          let self,
                          observationGeneration == generation
                    else { return }
                    adoptTheme(envelope.payload)
                }
            }
        }
        startOptionalProgressionObservation(generation: generation)
        startOptionalSettingsObservation(generation: generation)
        startCloudGameCenterStatusObservation(generation: generation)
    }

    /// Loads and commits the required Base Theme before the root view is made
    /// visible. This prevents first-frame surfaces from referencing a provider
    /// font that has not yet crossed the runtime registration boundary.
    func prepareInitialTheme() async throws {
        guard themeSnapshot == nil,
              let themeCoordinatorClientHandle
        else { return }

        let snapshot = try await themeCoordinatorClientHandle.snapshot()
        latestThemeCoordinatorRevision = snapshot.revision
        themeAdoptionGeneration &+= 1
        try await resolveAndCommitTheme(
            snapshot,
            adoptionGeneration: themeAdoptionGeneration
        )
    }

    func stop() async {
        observationGeneration &+= 1
        let stateTask = self.stateTask
        let menuTask = self.menuTask
        let availabilityTask = self.availabilityTask
        let progressionTask = self.progressionTask
        let themeTask = self.themeTask
        let themeResourceTask = self.themeResourceTask
        let settingsTask = self.settingsTask
        let cloudGameCenterStatusTask = self.cloudGameCenterStatusTask
        stateTask?.cancel()
        menuTask?.cancel()
        availabilityTask?.cancel()
        progressionTask?.cancel()
        themeTask?.cancel()
        themeResourceTask?.cancel()
        settingsTask?.cancel()
        cloudGameCenterStatusTask?.cancel()
        self.stateTask = nil
        self.menuTask = nil
        self.availabilityTask = nil
        self.progressionTask = nil
        self.themeTask = nil
        self.themeResourceTask = nil
        themeAdoptionGeneration &+= 1
        latestThemeCoordinatorRevision = nil
        self.settingsTask = nil
        self.cloudGameCenterStatusTask = nil
        snapshot = nil
        availabilitySnapshot = nil
        progressionSnapshot = nil
        progressionRailState = .unavailable
        themeSnapshot = nil
        themeScriptPresentation = .baseFallback
        themeUnlockAnimationDataByTier = [:]
        themeSelectionError = nil
        RuneThemePaletteInterpreter.reset()
        RuneThemeHeadingInterpreter.reset()
        runtimeSettingsSnapshot = nil
        settingsRailState = .unavailable
        runtimePresentationSettingsReady = false
        contactsImportPrompted = false
        splashLastShownAt = nil
        cloudGameCenterStatus = nil
        cloudGameCenterError = nil
        unlockFeedbackPreferences = .defaults
        activeReveal = nil
        progressionCommandError = nil
        selectedThemeRelicID = nil
        selectedThemeSealID = nil
        selectedThemeFrameID = nil
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
        themeCoordinatorClientHandle = nil
        runtimeSettingsClientHandle = nil
        cloudGameCenterStatusClientHandle = nil
        unlockFeedbackClientHandle = nil
        await resourcePresentation.close()
        await stateTask?.value
        await menuTask?.value
        await availabilityTask?.value
        await progressionTask?.value
        await themeTask?.value
        await themeResourceTask?.value
        await settingsTask?.value
        await cloudGameCenterStatusTask?.value
    }

    func requestGameCenterOptIn() async {
        await submitGameCenterParticipation(.optIn)
    }

    func submitGameCenterParticipation(
        _ intent: RuntimeGameCenterParticipationIntentDTO
    ) async {
        guard let cloudGameCenterStatusClientHandle else {
            cloudGameCenterError = "Game Center is unavailable. Your local progress is unaffected."
            return
        }
        do {
            try await cloudGameCenterStatusClientHandle.submit(intent)
            cloudGameCenterError = nil
        } catch {
            cloudGameCenterError = intent == .optIn
                ? "Game Center could not connect. Your local progress is unaffected."
                : "Game Center mirroring could not be stopped. Your local progress is unaffected."
        }
    }

    func rebindCloudAccount() async {
        guard let cloudGameCenterStatusClientHandle else {
            cloudGameCenterError = "iCloud sync is unavailable. Your local progress is unaffected."
            return
        }
        do {
            try await cloudGameCenterStatusClientHandle.rebindCloudAccount()
            cloudGameCenterError = nil
        } catch {
            cloudGameCenterError = "iCloud sync could not resume. Your local progress is unaffected."
        }
    }

    private func startCloudGameCenterStatusObservation(generation: UInt64) {
        guard let cloudGameCenterStatusClientHandle else { return }
        cloudGameCenterStatusTask = Task {
            @MainActor [weak self, cloudGameCenterStatusClientHandle] in
            do {
                let initial = try await cloudGameCenterStatusClientHandle.snapshot()
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                cloudGameCenterStatus = initial

                let snapshots = try await cloudGameCenterStatusClientHandle.snapshots()
                for await snapshot in snapshots {
                    guard !Task.isCancelled,
                          observationGeneration == generation
                    else { return }
                    cloudGameCenterStatus = snapshot
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                cloudGameCenterError =
                    "Cloud and Game Center status is unavailable. Your local progress is unaffected."
            }
        }
    }

    var isLoading: Bool {
        snapshot?.cipherLibrary.isLoading ?? true
    }

    var ciphers: [CipherViewState] {
        guard let snapshot else { return [] }
        let fonts = Dictionary(uniqueKeysWithValues: snapshot.fonts.map { ($0.id, $0) })
        return snapshot.cipherLibrary.ciphers.map { summary in
            let font = fonts[summary.fontID]
            return CipherViewState(
                id: summary.id.rawValue,
                label: summary.name,
                origin: summary.origin,
                createdAt: summary.createdAt,
                isActive: summary.isActive,
                contactID: summary.assignedContactID?.rawValue,
                delivered: summary.hasBeenDelivered,
                publicIdentifier: summary.publicIdentifier,
                fontName: font?.displayName ?? "Noto Sans Runic",
                fontSource: font?.source ?? .bundled,
                fontIsRegistered: font?.isRegistered ?? false
            )
        }
    }

    var activeCipher: CipherViewState? {
        ciphers.first(where: \.isActive)
    }

    var inscriptionFontPostScriptName: String {
        ThemeScriptFontSelector.postScriptName(
            themePostScriptName: themeScriptPresentation.fontPostScriptName,
            cipherFontName: activeCipher?.fontName,
            cipherFontSource: activeCipher?.fontSource,
            cipherFontIsRegistered: activeCipher?.fontIsRegistered ?? false
        )
    }

    var inscriptionVectorDataByToken: [String: Data] {
        guard ThemeScriptFontSelector.usesThemeVectors(
            cipherFontSource: activeCipher?.fontSource,
            cipherFontIsRegistered: activeCipher?.fontIsRegistered ?? false
        ) else { return [:] }
        return themeScriptPresentation.vectorDataByToken
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
        snapshot?.messageState.pendingMessage.map {
            PendingMessageViewState($0, themeSnapshot: themeSnapshot)
        }
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

    func selectCodex(_ codexID: CodexID) async {
        guard let themeCoordinatorClientHandle else {
            themeSelectionError = "Appearance choices are temporarily unavailable."
            return
        }
        do {
            let snapshot = try await themeCoordinatorClientHandle.selectCodex(
                SelectThemeCodexCommand(
                    codexID: codexID,
                    expectedSnapshotRevision: latestThemeCoordinatorRevision
                        ?? themeSnapshot?.revision
                )
            )
            adoptTheme(snapshot)
        } catch {
            themeSelectionError = "That Codex is not available right now."
        }
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
        let font = snapshot?.fonts.first(where: { $0.id == summary.fontID })
        return CipherViewState(
            id: summary.id.rawValue,
            label: summary.name,
            origin: summary.origin,
            createdAt: summary.createdAt,
            isActive: summary.isActive,
            contactID: summary.assignedContactID?.rawValue,
            delivered: summary.hasBeenDelivered,
            publicIdentifier: summary.publicIdentifier,
            fontName: font?.displayName ?? "Noto Sans Runic",
            fontSource: font?.source ?? .bundled,
            fontIsRegistered: font?.isRegistered ?? false
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

    func dismissOutboundSharePresentationStatus() {
        outboundSharePresentationStatus = .idle
    }

    func recordOutboundSharePresentationStatus(
        _ status: OutboundSharePresentationStatus
    ) {
        outboundSharePresentationStatus = status
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

    private func adoptTheme(_ nextSnapshot: ThemeCoordinatorSnapshotDTO) {
        latestThemeCoordinatorRevision = nextSnapshot.revision
        scheduleThemeResourceAdoption(nextSnapshot)
    }

    private func scheduleThemeResourceAdoption(
        _ snapshot: ThemeCoordinatorSnapshotDTO
    ) {
        themeResourceTask?.cancel()
        themeAdoptionGeneration &+= 1
        let adoptionGeneration = themeAdoptionGeneration
        themeResourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await resolveAndCommitTheme(
                    snapshot,
                    adoptionGeneration: adoptionGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard themeAdoptionGeneration == adoptionGeneration else { return }
                themeSelectionError =
                    "The selected appearance could not be loaded. The previous appearance remains active."
            }
        }
    }

    private func resolveAndCommitTheme(
        _ snapshot: ThemeCoordinatorSnapshotDTO,
        adoptionGeneration: UInt64
    ) async throws {
        if snapshot.isEmergencyPresentation {
            try Task.checkCancellation()
            guard themeAdoptionGeneration == adoptionGeneration else {
                throw CancellationError()
            }
            resourcePresentation.clearThemeBackground()
            RuneThemePaletteInterpreter.reset()
            RuneThemeHeadingInterpreter.reset()
            themeScriptPresentation = .baseFallback
            themeUnlockAnimationDataByTier = [:]
            themeSnapshot = snapshot
            reconcileThemeArtifactSelections()
            themeSelectionError =
                "Norse appearance resources are unavailable. Rune Scribe is using its emergency system presentation; message data and decode remain available."
            return
        }
        guard let themeCoordinatorClientHandle,
              let runtimeIOHandle
        else {
            throw ThemePresentationResourceError.stateUnavailable
        }
        let plan = try ThemePresentationResourcePlan(
            descriptor: snapshot.effectiveTheme
        )
        let resolved = try await Self.resolveThemeResources(
            plan: plan,
            client: themeCoordinatorClientHandle
        )
        try Task.checkCancellation()

        var registeredFontName = plan.expectedFontPostScriptName
            ?? ThemeScriptPresentation.baseFallback.fontPostScriptName
        if let fontResourceID = plan.fontResourceID {
            guard let font = resolved[fontResourceID] else {
                throw ThemePresentationResourceError.missing(fontResourceID)
            }
            let inspectedName = try await runtimeIOHandle.systemFontPostScriptName(
                for: font.data
            )
            guard inspectedName == plan.expectedFontPostScriptName else {
                throw ThemePresentationResourceError.fontIdentityMismatch
            }
            let registered = try await runtimeIOHandle.registerSystemFont(font.data)
            guard registered.postScriptName == inspectedName else {
                throw ThemePresentationResourceError.fontIdentityMismatch
            }
            registeredFontName = registered.postScriptName
        }

        let vectorData = try Dictionary(
            uniqueKeysWithValues: plan.vectorResourceIDByToken.map { token, resourceID in
                guard let resource = resolved[resourceID] else {
                    throw ThemePresentationResourceError.missing(resourceID)
                }
                return (token, resource.data)
            }
        )
        guard let staticBase = resolved[plan.backgroundStaticResourceID],
              let reduceMotion = resolved[plan.backgroundReduceMotionResourceID],
              let highContrast = resolved[plan.backgroundHighContrastResourceID]
        else {
            throw ThemePresentationResourceError.missing(
                plan.backgroundStaticResourceID
            )
        }
        let parameters = plan.backgroundRendererParametersResourceID.flatMap {
            resolved[$0]?.data
        }

        try Task.checkCancellation()
        guard themeAdoptionGeneration == adoptionGeneration else {
            throw CancellationError()
        }
        do {
            try resourcePresentation.installThemeBackground(
                staticBaseData: staticBase.data,
                reduceMotionData: reduceMotion.data,
                highContrastData: highContrast.data,
                rendererParametersData: parameters
            )
        } catch is RuntimeThemeBackgroundParameterError {
            // Optional animation parameters may fail closed while the three
            // validated static variants remain usable.
        }
        RuneThemePaletteInterpreter.install(snapshot.effectiveTheme)
        RuneThemeHeadingInterpreter.install(
            plan.decorativeHeadingResourceID.flatMap { resolved[$0]?.data }
        )
        themeScriptPresentation = ThemeScriptPresentation(
            scriptID: plan.scriptID,
            fontPostScriptName: registeredFontName,
            vectorDataByToken: vectorData
        )
        themeUnlockAnimationDataByTier = Dictionary(
            uniqueKeysWithValues: plan.unlockAnimationResourceIDByTier.compactMap {
                tier, resourceID in
                resolved[resourceID].map { (tier, $0.data) }
            }
        )
        themeSnapshot = snapshot
        reconcileThemeArtifactSelections()
        themeSelectionError = nil
    }

    func reconcileThemeArtifactSelections() {
        guard let theme = themeSnapshot?.effectiveTheme else {
            selectedThemeRelicID = nil
            selectedThemeSealID = nil
            selectedThemeFrameID = nil
            return
        }
        let codexID = theme.codex.id
        let owned = Set((progressionSnapshot?.ownership ?? []).compactMap { item -> ArtifactID? in
            guard item.state == .owned, case .artifact(let id) = item.reference else { return nil }
            return id
        })
        let relicPreference = runtimeSettingsSnapshot?
            .artifactSelections(for: .relic)[codexID]
        let sealPreference = runtimeSettingsSnapshot?
            .artifactSelections(for: .seal)[codexID]
        let framePreference = runtimeSettingsSnapshot?
            .artifactSelections(for: .frame)[codexID]
        let selectableRelics = theme.codex.relics.filter {
            $0.metadata.availability == .included || owned.contains($0.metadata.id)
        }
        let selectableSeals = theme.codex.seals.filter {
            $0.metadata.availability == .included || owned.contains($0.metadata.id)
        }
        let selectableFrames = theme.codex.frames.filter {
            ($0.metadata.availability == .included || owned.contains($0.metadata.id))
                && $0.allowsStaticShare
        }
        selectedThemeRelicID = relicPreference.flatMap { preferred in
            selectableRelics.contains(where: { $0.metadata.id == preferred }) ? preferred : nil
        } ?? theme.codex.defaultRelicID
        selectedThemeSealID = sealPreference.flatMap { preferred in
            selectableSeals.contains(where: { $0.metadata.id == preferred }) ? preferred : nil
        } ?? selectableSeals.first?.metadata.id
        selectedThemeFrameID = framePreference.flatMap {
            preferred in
            selectableFrames.contains(where: { $0.metadata.id == preferred }) ? preferred : nil
        }
    }

    private static func resolveThemeResources(
        plan: ThemePresentationResourcePlan,
        client: RuntimeThemeCoordinatorClient
    ) async throws -> [ThemeResourceID: ResolvedThemeResourceDTO] {
        var resourceIDs = Set([
            plan.backgroundStaticResourceID,
            plan.backgroundReduceMotionResourceID,
            plan.backgroundHighContrastResourceID,
        ])
        if let fontResourceID = plan.fontResourceID {
            resourceIDs.insert(fontResourceID)
        }
        if let parameters = plan.backgroundRendererParametersResourceID {
            resourceIDs.insert(parameters)
        }
        resourceIDs.formUnion(plan.unlockAnimationResourceIDByTier.values)
        if let headings = plan.decorativeHeadingResourceID {
            resourceIDs.insert(headings)
        }
        resourceIDs.formUnion(plan.vectorResourceIDByToken.values)

        return try await withThrowingTaskGroup(
            of: (ThemeResourceID, ResolvedThemeResourceDTO).self,
            returning: [ThemeResourceID: ResolvedThemeResourceDTO].self
        ) { group in
            for resourceID in resourceIDs {
                group.addTask {
                    let resource = try await client.resolveResource(
                        ResolveThemeResourceRequestDTO(
                            codexID: plan.codexID,
                            resourceID: resourceID
                        )
                    )
                    guard resource.codexID == plan.codexID,
                          resource.resourceID == resourceID
                    else {
                        throw ThemePresentationResourceError.identityMismatch
                    }
                    return (resourceID, resource)
                }
            }
            var result: [ThemeResourceID: ResolvedThemeResourceDTO] = [:]
            for try await (resourceID, resource) in group {
                result[resourceID] = resource
            }
            return result
        }
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

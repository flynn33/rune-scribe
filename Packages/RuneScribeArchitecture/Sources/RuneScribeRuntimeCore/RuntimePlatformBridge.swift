import Foundation
import RuneScribeContracts

private struct SecureValueHandlers: Sendable {
    let data: @Sendable (String, String) async throws -> Data?
    let set: @Sendable (Data, String, String) async throws -> Void
    let delete: @Sendable (String, String) async throws -> Void
}

private struct ProtectedFileHandlers: Sendable {
    let read: @Sendable (ProtectedPath) async throws -> Data?
    let write: @Sendable (Data, ProtectedPath) async throws -> Void
    let remove: @Sendable (ProtectedPath) async throws -> Void
    let exists: @Sendable (ProtectedPath) async throws -> Bool
    let contents: @Sendable (ProtectedPath, String?) async throws -> [ProtectedPath]
}

private struct InboundFileHandlers: Sendable {
    let read: @Sendable (URL, Bool, Int) async throws -> Data
}

private struct ShareArtifactHandlers: Sendable {
    let create: @Sendable (Data, ShareArtifactID, String, String) async throws -> Void
    let storeLink: @Sendable (URL, ShareArtifactID) async throws -> Void
    let removeLink: @Sendable (ShareArtifactID) async throws -> Void
    let remove: @Sendable (ShareArtifactID) async throws -> Void
    let removeAll: @Sendable () async throws -> Void
}

private struct SharePresentationHandlers: Sendable {
    let resolve: @Sendable (ShareArtifactID) async throws -> URL
}

private struct ResourceHandlers: Sendable {
    let data: @Sendable (ApplicationResource) async throws -> Data
    let url: @Sendable (ApplicationResource) async throws -> URL
}

private struct FontHandlers: Sendable {
    let postScriptName: @Sendable (Data) async throws -> String
    let register: @Sendable (Data) async throws -> RegisteredFontDTO
}

private struct ContactHandlers: Sendable {
    let authorizationStatus: @Sendable () async -> ContactAuthorizationDTO
    let requestAccess: @Sendable () async throws -> Bool
    let fetchContacts: @Sendable () async throws -> [SystemContactDTO]
}

private struct ClipboardReadHandlers: Sendable {
    let changeCount: @Sendable () async -> Int
    let string: @Sendable () async -> String?
}

private struct ClipboardWriteHandlers: Sendable {
    let setString: @Sendable (String) async throws -> Void
}

actor RuntimePlatformBridge {
    private var secureValue: SecureValueHandlers?
    private var protectedFile: ProtectedFileHandlers?
    private var inboundFile: InboundFileHandlers?
    private var shareArtifact: ShareArtifactHandlers?
    private var sharePresentation: SharePresentationHandlers?
    private var resources: ResourceHandlers?
    private var fonts: FontHandlers?
    private var contacts: ContactHandlers?
    private var clipboardRead: ClipboardReadHandlers?
    private var clipboardWrite: ClipboardWriteHandlers?
    private var hasClock = false
    private var hasUUID = false
    private var hasModuleStateStore = false
    private var generation: UInt64 = 0
    private var active = false

    func activateRuntime() -> UInt64 {
        generation &+= 1
        active = true
        return generation
    }

    func deactivateRuntime() {
        active = false
    }

    func contains(_ serviceID: ServiceIdentifier) -> Bool {
        switch serviceID {
        case RuneScribeServiceIDs.secureValueStore: secureValue != nil
        case RuneScribeServiceIDs.protectedFileStore: protectedFile != nil
        case RuneScribeServiceIDs.inboundFileReader: inboundFile != nil
        case RuneScribeServiceIDs.shareArtifactStore: shareArtifact != nil
        case RuneScribeServiceIDs.sharePresentation: sharePresentation != nil
        case RuneScribeServiceIDs.applicationResourceLocator: resources != nil
        case RuneScribeServiceIDs.systemFontRegistrar: fonts != nil
        case RuneScribeServiceIDs.contactAccess: contacts != nil
        case RuneScribeServiceIDs.clipboardRead: clipboardRead != nil
        case RuneScribeServiceIDs.clipboardWrite: clipboardWrite != nil
        case RuneScribeServiceIDs.clock: hasClock
        case RuneScribeServiceIDs.uuid: hasUUID
        case RuneScribeServiceIDs.moduleStateStore: hasModuleStateStore
        default: false
        }
    }

    func register(_ value: any SecureValueStore) throws {
        guard secureValue == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.secureValueStore) }
        secureValue = SecureValueHandlers(
            data: { try await value.data(service: $0, account: $1) },
            set: { try await value.set($0, service: $1, account: $2) },
            delete: { try await value.delete(service: $0, account: $1) }
        )
    }

    func register(_ value: any ProtectedFileStore) throws {
        guard protectedFile == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.protectedFileStore) }
        protectedFile = ProtectedFileHandlers(
            read: { try await value.read(relativePath: $0) },
            write: { try await value.write($0, relativePath: $1) },
            remove: { try await value.remove(relativePath: $0) },
            exists: { try await value.exists(relativePath: $0) },
            contents: { try await value.contents(of: $0, matchingExtension: $1) }
        )
    }

    func register(_ value: any InboundFileReader) throws {
        guard inboundFile == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.inboundFileReader) }
        inboundFile = InboundFileHandlers(read: { try await value.read($0, requiresSecurityScope: $1, maximumByteCount: $2) })
    }

    func register(_ value: any ShareArtifactStore) throws {
        guard shareArtifact == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.shareArtifactStore) }
        shareArtifact = ShareArtifactHandlers(
            create: { try await value.create($0, artifactID: $1, filename: $2, fileExtension: $3) },
            storeLink: { try await value.storeLink($0, artifactID: $1) },
            removeLink: { try await value.removeLink(artifactID: $0) },
            remove: { try await value.remove(artifactID: $0) },
            removeAll: { try await value.removeAll() }
        )
    }

    func register(_ value: any SharePresentationProviding) throws {
        guard sharePresentation == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        sharePresentation = SharePresentationHandlers(
            resolve: { try await value.presentationURL(for: $0) }
        )
    }

    func register(_ value: any ApplicationResourceLocator) throws {
        guard resources == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.applicationResourceLocator) }
        resources = ResourceHandlers(data: { try await value.data(for: $0) }, url: { try await value.url(for: $0) })
    }

    func register(_ value: any SystemFontRegistrar) throws {
        guard fonts == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.systemFontRegistrar) }
        fonts = FontHandlers(postScriptName: { try await value.postScriptName(forFontData: $0) }, register: { try await value.registerFont($0) })
    }

    func register(_ value: any ContactAccessService) throws {
        guard contacts == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.contactAccess) }
        contacts = ContactHandlers(
            authorizationStatus: { await value.authorizationStatus() },
            requestAccess: { try await value.requestAccess() },
            fetchContacts: { try await value.fetchContacts() }
        )
    }

    func register(_ value: any ClipboardReading) throws {
        guard clipboardRead == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.clipboardRead) }
        clipboardRead = ClipboardReadHandlers(changeCount: { await value.changeCount() }, string: { await value.string() })
    }

    func register(_ value: any ClipboardWriting) throws {
        guard clipboardWrite == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.clipboardWrite) }
        clipboardWrite = ClipboardWriteHandlers(setString: { try await value.setString($0) })
    }

    func register(_: any ClockProviding) throws {
        guard !hasClock else {
            throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.clock)
        }
        hasClock = true
    }
    func register(_: any UUIDProviding) throws {
        guard !hasUUID else {
            throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.uuid)
        }
        hasUUID = true
    }

    func register(_: any ModuleStateStore) throws {
        guard !hasModuleStateStore else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeServiceIDs.moduleStateStore
            )
        }
        hasModuleStateStore = true
    }

    private func validate(_ expectedGeneration: UInt64, serviceID: ServiceIdentifier) throws {
        guard active, generation == expectedGeneration else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard contains(serviceID) else { throw RuneScribeRuntimeError.serviceUnavailable(serviceID) }
    }

    func secureData(_ service: String, _ account: String, generation: UInt64) async throws -> Data? {
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
        guard let handler = secureValue?.data else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.secureValueStore) }
        let result = try await handler(service, account)
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
        return result
    }
    func secureSet(_ data: Data, _ service: String, _ account: String, generation: UInt64) async throws {
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
        guard let handler = secureValue?.set else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.secureValueStore) }
        try await handler(data, service, account)
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
    }
    func secureDelete(_ service: String, _ account: String, generation: UInt64) async throws {
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
        guard let handler = secureValue?.delete else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.secureValueStore) }
        try await handler(service, account)
        try validate(generation, serviceID: RuneScribeServiceIDs.secureValueStore)
    }

    func protectedRead(_ path: ProtectedPath, generation: UInt64) async throws -> Data? { try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); guard let h = protectedFile?.read else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.protectedFileStore) }; let r = try await h(path); try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); return r }
    func protectedWrite(_ data: Data, _ path: ProtectedPath, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); guard let h = protectedFile?.write else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.protectedFileStore) }; try await h(data, path); try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore) }
    func protectedRemove(_ path: ProtectedPath, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); guard let h = protectedFile?.remove else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.protectedFileStore) }; try await h(path); try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore) }
    func protectedExists(_ path: ProtectedPath, generation: UInt64) async throws -> Bool { try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); guard let h = protectedFile?.exists else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.protectedFileStore) }; let r = try await h(path); try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); return r }
    func protectedContents(_ path: ProtectedPath, _ ext: String?, generation: UInt64) async throws -> [ProtectedPath] { try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); guard let h = protectedFile?.contents else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.protectedFileStore) }; let r = try await h(path, ext); try validate(generation, serviceID: RuneScribeServiceIDs.protectedFileStore); return r }
    func inboundRead(_ url: URL, _ scoped: Bool, _ maximum: Int, generation: UInt64) async throws -> Data { try validate(generation, serviceID: RuneScribeServiceIDs.inboundFileReader); guard let h = inboundFile?.read else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.inboundFileReader) }; let r = try await h(url, scoped, maximum); try validate(generation, serviceID: RuneScribeServiceIDs.inboundFileReader); return r }
    func shareCreate(_ data: Data, _ id: ShareArtifactID, _ name: String, _ ext: String, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.create else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(data, id, name, ext); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareStoreLink(_ url: URL, _ id: ShareArtifactID, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.storeLink else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(url, id); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareRemoveLink(_ id: ShareArtifactID, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.removeLink else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(id); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareRemove(_ id: ShareArtifactID, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.remove else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(id); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareRemoveAll(generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.removeAll else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func resourceData(_ resource: ApplicationResource, generation: UInt64) async throws -> Data { try validate(generation, serviceID: RuneScribeServiceIDs.applicationResourceLocator); guard let h = resources?.data else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.applicationResourceLocator) }; let r = try await h(resource); try validate(generation, serviceID: RuneScribeServiceIDs.applicationResourceLocator); return r }
    func resourceURL(_ resource: ApplicationResource, generation: UInt64) async throws -> URL { try validate(generation, serviceID: RuneScribeServiceIDs.applicationResourceLocator); guard let h = resources?.url else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.applicationResourceLocator) }; let r = try await h(resource); try validate(generation, serviceID: RuneScribeServiceIDs.applicationResourceLocator); return r }
    func fontName(_ data: Data, generation: UInt64) async throws -> String { try validate(generation, serviceID: RuneScribeServiceIDs.systemFontRegistrar); guard let h = fonts?.postScriptName else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.systemFontRegistrar) }; let r = try await h(data); try validate(generation, serviceID: RuneScribeServiceIDs.systemFontRegistrar); return r }
    func fontRegister(_ data: Data, generation: UInt64) async throws -> RegisteredFontDTO { try validate(generation, serviceID: RuneScribeServiceIDs.systemFontRegistrar); guard let h = fonts?.register else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.systemFontRegistrar) }; let r = try await h(data); try validate(generation, serviceID: RuneScribeServiceIDs.systemFontRegistrar); return r }
    func contactAuthorization(generation: UInt64) async -> ContactAuthorizationDTO { guard (try? validate(generation, serviceID: RuneScribeServiceIDs.contactAccess)) != nil, let h = contacts?.authorizationStatus else { return .denied }; let r = await h(); guard (try? validate(generation, serviceID: RuneScribeServiceIDs.contactAccess)) != nil else { return .denied }; return r }
    func contactRequest(generation: UInt64) async throws -> Bool { try validate(generation, serviceID: RuneScribeServiceIDs.contactAccess); guard let h = contacts?.requestAccess else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.contactAccess) }; let r = try await h(); try validate(generation, serviceID: RuneScribeServiceIDs.contactAccess); return r }
    func contactFetch(generation: UInt64) async throws -> [SystemContactDTO] { try validate(generation, serviceID: RuneScribeServiceIDs.contactAccess); guard let h = contacts?.fetchContacts else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.contactAccess) }; let r = try await h(); try validate(generation, serviceID: RuneScribeServiceIDs.contactAccess); return r }
    func clipboardChangeCount(generation: UInt64) async -> Int { guard (try? validate(generation, serviceID: RuneScribeServiceIDs.clipboardRead)) != nil, let h = clipboardRead?.changeCount else { return 0 }; let r = await h(); guard (try? validate(generation, serviceID: RuneScribeServiceIDs.clipboardRead)) != nil else { return 0 }; return r }
    func clipboardString(generation: UInt64) async -> String? { guard (try? validate(generation, serviceID: RuneScribeServiceIDs.clipboardRead)) != nil, let h = clipboardRead?.string else { return nil }; let r = await h(); guard (try? validate(generation, serviceID: RuneScribeServiceIDs.clipboardRead)) != nil else { return nil }; return r }
    func clipboardSet(_ value: String, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.clipboardWrite); guard let h = clipboardWrite?.setString else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.clipboardWrite) }; try await h(value); try validate(generation, serviceID: RuneScribeServiceIDs.clipboardWrite) }

}

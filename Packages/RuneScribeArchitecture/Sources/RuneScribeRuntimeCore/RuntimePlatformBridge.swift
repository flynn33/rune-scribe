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
    let create: @Sendable (Data, ShareArtifactID, String, String) async throws -> ScopedShareFile
    let storeLink: @Sendable (URL, ShareArtifactID) async throws -> Void
    let removeLink: @Sendable (ShareArtifactID) async throws -> Void
    let remove: @Sendable (ScopedShareFile) async throws -> Void
    let removeAll: @Sendable () async throws -> Void
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

private final class RuntimeSynchronousPlatformGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64?
    private var clock: (@Sendable () -> Date)?
    private var uuid: (@Sendable () -> UUID)?

    func registerClock(_ handler: @escaping @Sendable () -> Date) throws {
        lock.lock(); defer { lock.unlock() }
        guard clock == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.clock) }
        clock = handler
    }

    func registerUUID(_ handler: @escaping @Sendable () -> UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard uuid == nil else { throw RuneScribeRuntimeError.duplicateService(RuneScribeServiceIDs.uuid) }
        uuid = handler
    }

    func activate(generation: UInt64) {
        lock.lock(); activeGeneration = generation; lock.unlock()
    }

    func deactivate() {
        lock.lock(); activeGeneration = nil; lock.unlock()
    }

    func now(generation: UInt64) -> Date {
        lock.lock(); defer { lock.unlock() }
        guard activeGeneration == generation, let clock else { return .distantPast }
        return clock()
    }

    func nextUUID(generation: UInt64) -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard activeGeneration == generation, let uuid else {
            return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
        return uuid()
    }
}

actor RuntimePlatformBridge {
    private var secureValue: SecureValueHandlers?
    private var protectedFile: ProtectedFileHandlers?
    private var inboundFile: InboundFileHandlers?
    private var shareArtifact: ShareArtifactHandlers?
    private var resources: ResourceHandlers?
    private var fonts: FontHandlers?
    private var contacts: ContactHandlers?
    private var clipboardRead: ClipboardReadHandlers?
    private var clipboardWrite: ClipboardWriteHandlers?
    private var hasClock = false
    private var hasUUID = false
    private let synchronous = RuntimeSynchronousPlatformGate()
    private var generation: UInt64 = 0
    private var active = false

    func activateRuntime() -> UInt64 {
        generation &+= 1
        active = true
        synchronous.activate(generation: generation)
        return generation
    }

    func deactivateRuntime() {
        active = false
        synchronous.deactivate()
    }

    func currentGeneration() -> UInt64 { generation }

    func contains(_ serviceID: ServiceIdentifier) -> Bool {
        switch serviceID {
        case RuneScribeServiceIDs.secureValueStore: secureValue != nil
        case RuneScribeServiceIDs.protectedFileStore: protectedFile != nil
        case RuneScribeServiceIDs.inboundFileReader: inboundFile != nil
        case RuneScribeServiceIDs.shareArtifactStore: shareArtifact != nil
        case RuneScribeServiceIDs.applicationResourceLocator: resources != nil
        case RuneScribeServiceIDs.systemFontRegistrar: fonts != nil
        case RuneScribeServiceIDs.contactAccess: contacts != nil
        case RuneScribeServiceIDs.clipboardRead: clipboardRead != nil
        case RuneScribeServiceIDs.clipboardWrite: clipboardWrite != nil
        case RuneScribeServiceIDs.clock: hasClock
        case RuneScribeServiceIDs.uuid: hasUUID
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
            remove: { try await value.remove($0) },
            removeAll: { try await value.removeAll() }
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

    func register(_ value: any ClockProviding) throws {
        try synchronous.registerClock(value.now)
        hasClock = true
    }
    func register(_ value: any UUIDProviding) throws {
        try synchronous.registerUUID(value.nextUUID)
        hasUUID = true
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
    func shareCreate(_ data: Data, _ id: ShareArtifactID, _ name: String, _ ext: String, generation: UInt64) async throws -> ScopedShareFile { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.create else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; let r = try await h(data, id, name, ext); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); return r }
    func shareStoreLink(_ url: URL, _ id: ShareArtifactID, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.storeLink else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(url, id); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareRemoveLink(_ id: ShareArtifactID, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.removeLink else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(id); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
    func shareRemove(_ file: ScopedShareFile, generation: UInt64) async throws { try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore); guard let h = shareArtifact?.remove else { throw RuneScribeRuntimeError.serviceUnavailable(RuneScribeServiceIDs.shareArtifactStore) }; try await h(file); try validate(generation, serviceID: RuneScribeServiceIDs.shareArtifactStore) }
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

    nonisolated func clockClient(generation: UInt64) -> any ClockProviding { RuntimeClockProxy(gate: synchronous, generation: generation) }
    nonisolated func uuidClient(generation: UInt64) -> any UUIDProviding { RuntimeUUIDProxy(gate: synchronous, generation: generation) }
}

private struct RuntimeSecureValueProxy: SecureValueStore { let bridge: RuntimePlatformBridge; let generation: UInt64; func data(service: String, account: String) async throws -> Data? { try await bridge.secureData(service, account, generation: generation) }; func set(_ data: Data, service: String, account: String) async throws { try await bridge.secureSet(data, service, account, generation: generation) }; func delete(service: String, account: String) async throws { try await bridge.secureDelete(service, account, generation: generation) } }
private struct RuntimeProtectedFileProxy: ProtectedFileStore { let bridge: RuntimePlatformBridge; let generation: UInt64; func read(relativePath: ProtectedPath) async throws -> Data? { try await bridge.protectedRead(relativePath, generation: generation) }; func write(_ data: Data, relativePath: ProtectedPath) async throws { try await bridge.protectedWrite(data, relativePath, generation: generation) }; func remove(relativePath: ProtectedPath) async throws { try await bridge.protectedRemove(relativePath, generation: generation) }; func exists(relativePath: ProtectedPath) async throws -> Bool { try await bridge.protectedExists(relativePath, generation: generation) }; func contents(of directory: ProtectedPath, matchingExtension fileExtension: String?) async throws -> [ProtectedPath] { try await bridge.protectedContents(directory, fileExtension, generation: generation) } }
private struct RuntimeInboundFileProxy: InboundFileReader { let bridge: RuntimePlatformBridge; let generation: UInt64; func read(_ fileURL: URL, requiresSecurityScope: Bool, maximumByteCount: Int) async throws -> Data { try await bridge.inboundRead(fileURL, requiresSecurityScope, maximumByteCount, generation: generation) } }
private struct RuntimeShareArtifactProxy: ShareArtifactStore { let bridge: RuntimePlatformBridge; let generation: UInt64; func create(_ data: Data, artifactID: ShareArtifactID, filename: String, fileExtension: String) async throws -> ScopedShareFile { try await bridge.shareCreate(data, artifactID, filename, fileExtension, generation: generation) }; func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws { try await bridge.shareStoreLink(url, artifactID, generation: generation) }; func removeLink(artifactID: ShareArtifactID) async throws { try await bridge.shareRemoveLink(artifactID, generation: generation) }; func remove(_ file: ScopedShareFile) async throws { try await bridge.shareRemove(file, generation: generation) }; func removeAll() async throws { try await bridge.shareRemoveAll(generation: generation) } }
private struct RuntimeResourceProxy: ApplicationResourceLocator { let bridge: RuntimePlatformBridge; let generation: UInt64; func data(for resource: ApplicationResource) async throws -> Data { try await bridge.resourceData(resource, generation: generation) }; func url(for resource: ApplicationResource) async throws -> URL { try await bridge.resourceURL(resource, generation: generation) } }
private struct RuntimeFontProxy: SystemFontRegistrar { let bridge: RuntimePlatformBridge; let generation: UInt64; func postScriptName(forFontData data: Data) async throws -> String { try await bridge.fontName(data, generation: generation) }; func registerFont(_ data: Data) async throws -> RegisteredFontDTO { try await bridge.fontRegister(data, generation: generation) } }
private struct RuntimeContactProxy: ContactAccessService { let bridge: RuntimePlatformBridge; let generation: UInt64; func authorizationStatus() async -> ContactAuthorizationDTO { await bridge.contactAuthorization(generation: generation) }; func requestAccess() async throws -> Bool { try await bridge.contactRequest(generation: generation) }; func fetchContacts() async throws -> [SystemContactDTO] { try await bridge.contactFetch(generation: generation) } }
private struct RuntimeClipboardReadProxy: ClipboardReading { let bridge: RuntimePlatformBridge; let generation: UInt64; func changeCount() async -> Int { await bridge.clipboardChangeCount(generation: generation) }; func string() async -> String? { await bridge.clipboardString(generation: generation) } }
private struct RuntimeClipboardWriteProxy: ClipboardWriting { let bridge: RuntimePlatformBridge; let generation: UInt64; func setString(_ value: String) async throws { try await bridge.clipboardSet(value, generation: generation) } }
private struct RuntimeClockProxy: ClockProviding { let gate: RuntimeSynchronousPlatformGate; let generation: UInt64; func now() -> Date { gate.now(generation: generation) } }
private struct RuntimeUUIDProxy: UUIDProviding { let gate: RuntimeSynchronousPlatformGate; let generation: UInt64; func nextUUID() -> UUID { gate.nextUUID(generation: generation) } }

extension RuntimePlatformBridge {
    func secureValueClient(generation: UInt64) -> any SecureValueStore { RuntimeSecureValueProxy(bridge: self, generation: generation) }
    func protectedFileClient(generation: UInt64) -> any ProtectedFileStore { RuntimeProtectedFileProxy(bridge: self, generation: generation) }
    func inboundFileClient(generation: UInt64) -> any InboundFileReader { RuntimeInboundFileProxy(bridge: self, generation: generation) }
    func shareArtifactClient(generation: UInt64) -> any ShareArtifactStore { RuntimeShareArtifactProxy(bridge: self, generation: generation) }
    func resourceClient(generation: UInt64) -> any ApplicationResourceLocator { RuntimeResourceProxy(bridge: self, generation: generation) }
    func fontClient(generation: UInt64) -> any SystemFontRegistrar { RuntimeFontProxy(bridge: self, generation: generation) }
    func contactClient(generation: UInt64) -> any ContactAccessService { RuntimeContactProxy(bridge: self, generation: generation) }
    func clipboardReadClient(generation: UInt64) -> any ClipboardReading { RuntimeClipboardReadProxy(bridge: self, generation: generation) }
    func clipboardWriteClient(generation: UInt64) -> any ClipboardWriting { RuntimeClipboardWriteProxy(bridge: self, generation: generation) }
}

public extension ModuleContext {
    func secureValueStoreClient() async throws -> any SecureValueStore {
        try await requirePlatformService(RuneScribeServiceIDs.secureValueStore)
        return await platformBridge.secureValueClient(generation: platformGeneration)
    }

    func protectedFileStoreClient() async throws -> any ProtectedFileStore {
        try await requirePlatformService(RuneScribeServiceIDs.protectedFileStore)
        return await platformBridge.protectedFileClient(generation: platformGeneration)
    }

    func inboundFileReaderClient() async throws -> any InboundFileReader {
        try await requirePlatformService(RuneScribeServiceIDs.inboundFileReader)
        return await platformBridge.inboundFileClient(generation: platformGeneration)
    }

    func shareArtifactStoreClient() async throws -> any ShareArtifactStore {
        try await requirePlatformService(RuneScribeServiceIDs.shareArtifactStore)
        return await platformBridge.shareArtifactClient(generation: platformGeneration)
    }

    func applicationResourceClient() async throws -> any ApplicationResourceLocator {
        try await requirePlatformService(RuneScribeServiceIDs.applicationResourceLocator)
        return await platformBridge.resourceClient(generation: platformGeneration)
    }

    func systemFontRegistrarClient() async throws -> any SystemFontRegistrar {
        try await requirePlatformService(RuneScribeServiceIDs.systemFontRegistrar)
        return await platformBridge.fontClient(generation: platformGeneration)
    }

    func contactAccessClient() async throws -> any ContactAccessService {
        try await requirePlatformService(RuneScribeServiceIDs.contactAccess)
        return await platformBridge.contactClient(generation: platformGeneration)
    }

    func clipboardReadingClient() async throws -> any ClipboardReading {
        try await requirePlatformService(RuneScribeServiceIDs.clipboardRead)
        return await platformBridge.clipboardReadClient(generation: platformGeneration)
    }

    func clipboardWritingClient() async throws -> any ClipboardWriting {
        try await requirePlatformService(RuneScribeServiceIDs.clipboardWrite)
        return await platformBridge.clipboardWriteClient(generation: platformGeneration)
    }

    func clockClient() async throws -> any ClockProviding {
        try await requirePlatformService(RuneScribeServiceIDs.clock)
        return platformBridge.clockClient(generation: platformGeneration)
    }

    func uuidClient() async throws -> any UUIDProviding {
        try await requirePlatformService(RuneScribeServiceIDs.uuid)
        return platformBridge.uuidClient(generation: platformGeneration)
    }
}

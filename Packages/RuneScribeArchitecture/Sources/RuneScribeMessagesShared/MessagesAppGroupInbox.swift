import Foundation

public enum MessagesAppGroupInboxError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case invalidEnvelope
    case envelopeNotFound
    case inboxCapacityExceeded
    case persistenceFailed
}

public actor MessagesAppGroupInbox {
    public static let appGroupIdentifier = "group.com.runescribe.app"
    public static let directoryName = "MessagesImportInbox"
    public static let maximumEnvelopeCount = 128
    public static let maximumEnvelopeByteCount = 16_384

    private let directoryURL: URL
    private let fileManager: FileManager

    public init(
        appGroupIdentifier: String = MessagesAppGroupInbox.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw MessagesAppGroupInboxError.appGroupUnavailable
        }
        self.directoryURL = containerURL.appendingPathComponent(
            Self.directoryName,
            isDirectory: true
        )
        self.fileManager = fileManager
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func recordConfirmation(
        for invitation: MessagesValidatedInvitation,
        at date: Date
    ) throws -> MessagesImportEnvelope {
        try ensureDirectory()
        if let existing = try loadIfPresent(handoffID: invitation.handoffID) {
            return existing
        }
        guard try envelopeURLs().count < Self.maximumEnvelopeCount else {
            throw MessagesAppGroupInboxError.inboxCapacityExceeded
        }
        let envelope = MessagesImportEnvelope(
            invitation: invitation,
            confirmedAt: date
        )
        try persist(envelope)
        return envelope
    }

    @discardableResult
    public func recordOpenAttempt(
        handoffID: String,
        at date: Date
    ) throws -> MessagesImportEnvelope {
        var envelope = try load(handoffID: handoffID)
        envelope.recordOpenAttempt(at: date)
        try persist(envelope)
        return envelope
    }

    @discardableResult
    public func recordOpenResult(
        handoffID: String,
        result: MessagesOpenResult
    ) throws -> MessagesImportEnvelope {
        var envelope = try load(handoffID: handoffID)
        envelope.recordOpenResult(result)
        try persist(envelope)
        return envelope
    }

    @discardableResult
    public func recordAppState(
        handoffID: String,
        state: MessagesImportAppState
    ) throws -> MessagesImportEnvelope {
        var envelope = try load(handoffID: handoffID)
        envelope.recordAppState(state)
        try persist(envelope)
        return envelope
    }

    public func pendingEnvelopes() throws -> [MessagesImportEnvelope] {
        try ensureDirectory()
        return try envelopeURLs().compactMap { URL in
            guard let envelope = try? decode(contentsOf: URL) else { return nil }
            switch envelope.appState {
            case .awaitingDelivery, .presented:
                return envelope
            case .completed, .declined:
                return nil
            }
        }.sorted {
            if $0.confirmedAtEpochMilliseconds == $1.confirmedAtEpochMilliseconds {
                return $0.handoffID < $1.handoffID
            }
            return $0.confirmedAtEpochMilliseconds < $1.confirmedAtEpochMilliseconds
        }
    }

    public func envelope(handoffID: String) throws -> MessagesImportEnvelope? {
        try loadIfPresent(handoffID: handoffID)
    }

    public func remove(handoffID: String) throws {
        let URL = try envelopeURL(handoffID: handoffID)
        guard fileManager.fileExists(atPath: URL.path) else { return }
        do {
            try fileManager.removeItem(at: URL)
        } catch {
            throw MessagesAppGroupInboxError.persistenceFailed
        }
    }

    private func load(handoffID: String) throws -> MessagesImportEnvelope {
        guard let envelope = try loadIfPresent(handoffID: handoffID) else {
            throw MessagesAppGroupInboxError.envelopeNotFound
        }
        return envelope
    }

    private func loadIfPresent(handoffID: String) throws -> MessagesImportEnvelope? {
        let URL = try envelopeURL(handoffID: handoffID)
        guard fileManager.fileExists(atPath: URL.path) else { return nil }
        return try decode(contentsOf: URL)
    }

    private func decode(contentsOf URL: URL) throws -> MessagesImportEnvelope {
        do {
            let values = try URL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize <= Self.maximumEnvelopeByteCount
            else { throw MessagesAppGroupInboxError.invalidEnvelope }
            let data = try Data(contentsOf: URL, options: [.mappedIfSafe])
            let envelope = try JSONDecoder().decode(
                MessagesImportEnvelope.self,
                from: data
            )
            try envelope.validate()
            return envelope
        } catch let error as MessagesAppGroupInboxError {
            throw error
        } catch {
            throw MessagesAppGroupInboxError.invalidEnvelope
        }
    }

    private func persist(_ envelope: MessagesImportEnvelope) throws {
        try envelope.validate()
        try ensureDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= Self.maximumEnvelopeByteCount else {
                throw MessagesAppGroupInboxError.invalidEnvelope
            }
            try data.write(
                to: try envelopeURL(handoffID: envelope.handoffID),
                options: [.atomic]
            )
        } catch let error as MessagesAppGroupInboxError {
            throw error
        } catch {
            throw MessagesAppGroupInboxError.persistenceFailed
        }
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw MessagesAppGroupInboxError.persistenceFailed
        }
    }

    private func envelopeURLs() throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            throw MessagesAppGroupInboxError.persistenceFailed
        }
    }

    private func envelopeURL(handoffID: String) throws -> URL {
        guard handoffID.count == 64,
              handoffID.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw MessagesAppGroupInboxError.invalidEnvelope }
        return directoryURL.appendingPathComponent(
            "\(handoffID).json",
            isDirectory: false
        )
    }
}

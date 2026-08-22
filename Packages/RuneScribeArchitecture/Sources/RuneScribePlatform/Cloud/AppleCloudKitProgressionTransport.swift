#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation
import RuneScribeContracts

public actor AppleCloudKitProgressionTransport: CloudSyncTransport {
    public static let containerIdentifier = "iCloud.com.runescribe.app"

    private static let recordType = "RuneScribeProgressionReplica"
    private static let recordName = "private-progression-v1"
    private static let payloadField = "payload"

    private let injectedContainer: CKContainer?
    private var resolvedContainer: CKContainer?
    private var resolvedDatabase: CKDatabase?

    public init() {
        injectedContainer = nil
    }

    public init(container: CKContainer) {
        injectedContainer = container
    }

    public func accountState() async throws -> CloudAccountStateDTO {
        do {
            let (container, _) = resolveConnection()
            let status = try await container.accountStatus()
            switch status {
            case .available:
                let userRecordID = try await container.userRecordID()
                let digest = SHA256.hash(data: Data(userRecordID.recordName.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return try CloudAccountStateDTO(
                    state: .available,
                    accountScopeDigest: CloudAccountScopeDigestDTO(rawValue: digest)!
                )
            case .noAccount:
                return try CloudAccountStateDTO(state: .noAccount, accountScopeDigest: nil)
            case .restricted:
                return try CloudAccountStateDTO(state: .restricted, accountScopeDigest: nil)
            case .temporarilyUnavailable:
                return try CloudAccountStateDTO(
                    state: .temporarilyUnavailable,
                    accountScopeDigest: nil
                )
            case .couldNotDetermine:
                return try CloudAccountStateDTO(
                    state: .couldNotDetermine,
                    accountScopeDigest: nil
                )
            @unknown default:
                return try CloudAccountStateDTO(
                    state: .couldNotDetermine,
                    accountScopeDigest: nil
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO {
        do {
            let (_, database) = resolveConnection()
            let record = try await database.record(
                for: CKRecord.ID(recordName: Self.recordName)
            )
            guard let changeTag = record.recordChangeTag else {
                throw CloudSyncTransportError.corruptRemote
            }
            guard let asset = record[Self.payloadField] as? CKAsset,
                  let fileURL = asset.fileURL
            else {
                return try CloudSyncFetchResultDTO(
                    payload: Self.invalidPayloadMarker(
                        Self.payloadValidationFailure(
                            hasAsset: record[Self.payloadField] is CKAsset,
                            hasFileURL: false,
                            isRegularFile: nil,
                            fileSize: nil
                        ) ?? "missing-asset"
                    ),
                    changeTag: changeTag
                )
            }
            let values = try fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if let reason = Self.payloadValidationFailure(
                hasAsset: true,
                hasFileURL: true,
                isRegularFile: values.isRegularFile,
                fileSize: values.fileSize
            ) {
                return try CloudSyncFetchResultDTO(
                    payload: Self.invalidPayloadMarker(reason),
                    changeTag: changeTag
                )
            }
            let data = try Data(
                contentsOf: fileURL,
                options: [.mappedIfSafe, .uncached]
            )
            return try CloudSyncFetchResultDTO(
                payload: data,
                changeTag: changeTag
            )
        } catch let error as CKError where error.code == .unknownItem {
            return try CloudSyncFetchResultDTO(payload: nil, changeTag: nil)
        } catch let error as CloudSyncTransportError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    public func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) async throws -> CloudSyncSaveResultDTO {
        let (_, database) = resolveConnection()
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record: CKRecord
        do {
            let existing = try await database.record(for: recordID)
            guard request.expectedChangeTag == existing.recordChangeTag else {
                throw CloudSyncTransportError.conflict
            }
            record = existing
        } catch let error as CKError where error.code == .unknownItem {
            guard request.expectedChangeTag == nil else {
                throw CloudSyncTransportError.conflict
            }
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        } catch let error as CloudSyncTransportError {
            throw error
        } catch {
            throw Self.map(error)
        }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "RuneScribeCloudTransport",
            directoryHint: .isDirectory
        )
        let fileURL = directory.appending(
            path: UUID().uuidString.lowercased(),
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try request.payload.write(to: fileURL, options: [.atomic, .completeFileProtection])
            let result: CloudSyncSaveResultDTO
            do {
                record[Self.payloadField] = CKAsset(fileURL: fileURL)
                let saved = try await database.save(record)
                guard let changeTag = saved.recordChangeTag else {
                    throw CloudSyncTransportError.corruptRemote
                }
                result = try CloudSyncSaveResultDTO(changeTag: changeTag)
            } catch {
                let operationError = error
                do {
                    try Self.removeTemporaryPayload(at: fileURL)
                } catch {
                    throw CloudSyncTransportError.configurationUnavailable
                }
                throw operationError
            }
            do {
                try Self.removeTemporaryPayload(at: fileURL)
            } catch {
                // Cleanup is privacy-significant. Treat failure as a permanent
                // adapter configuration problem instead of silently discarding it.
                throw CloudSyncTransportError.configurationUnavailable
            }
            return result
        } catch let error as CloudSyncTransportError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    static func removeTemporaryPayload(
        at fileURL: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        remove: (URL) throws -> Void = FileManager.default.removeItem(at:)
    ) throws {
        guard fileExists(fileURL.path) else { return }
        try remove(fileURL)
    }

    private func resolveConnection() -> (CKContainer, CKDatabase) {
        if let resolvedContainer, let resolvedDatabase {
            return (resolvedContainer, resolvedDatabase)
        }
        let container = injectedContainer
            ?? CKContainer(identifier: Self.containerIdentifier)
        let database = container.privateCloudDatabase
        resolvedContainer = container
        resolvedDatabase = database
        return (container, database)
    }

    static func payloadValidationFailure(
        hasAsset: Bool,
        hasFileURL: Bool,
        isRegularFile: Bool?,
        fileSize: Int?
    ) -> String? {
        guard hasAsset, hasFileURL else { return "missing-asset" }
        guard isRegularFile == true, let fileSize, fileSize >= 0 else {
            return "invalid-asset"
        }
        guard fileSize <= CloudSyncFetchResultDTO.maximumPayloadByteCount else {
            return "oversize-asset"
        }
        return nil
    }

    static func invalidPayloadMarker(_ reason: String) -> Data {
        Data("runescribe-cloud-invalid-v1|\(reason)".utf8)
    }

    static func map(
        _ error: Error,
        now: Date = Date()
    ) -> CloudSyncTransportError {
        guard let error = error as? CKError else { return .serviceUnavailable }
        if error.code == .partialFailure,
           let partial = error.userInfo[CKPartialErrorsByItemIDKey]
               as? [AnyHashable: Error]
        {
            let mapped = partial.values.map { Self.map($0, now: now) }
            if mapped.contains(.accountUnavailable) { return .accountUnavailable }
            if mapped.contains(.accountChanged) { return .accountChanged }
            if mapped.contains(.configurationUnavailable) {
                return .configurationUnavailable
            }
            if mapped.contains(.conflict) { return .conflict }
            if mapped.contains(.offline) { return .offline }
            let retryDates = mapped.compactMap { value -> Date? in
                if case let .rateLimited(retryAfter) = value { return retryAfter }
                return nil
            }
            if !retryDates.isEmpty { return .rateLimited(retryAfter: retryDates.max()) }
            if mapped.contains(where: {
                if case .rateLimited = $0 { return true }
                return false
            }) {
                return .rateLimited(retryAfter: nil)
            }
            return .serviceUnavailable
        }
        let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)
            .map { now.addingTimeInterval($0.doubleValue) }
        switch error.code {
        case .networkFailure, .networkUnavailable:
            return .offline
        case .notAuthenticated:
            return .accountUnavailable
        case .accountTemporarilyUnavailable:
            return .serviceUnavailable
        case .requestRateLimited, .zoneBusy:
            return .rateLimited(retryAfter: retryAfter)
        case .serverRecordChanged:
            return .conflict
        case .badContainer, .missingEntitlement, .permissionFailure:
            return .configurationUnavailable
        default:
            return .serviceUnavailable
        }
    }
}
#endif

import Foundation
import RuneScribeContracts

enum ShareArtifactRegistryError: Error, Equatable, Sendable {
    case artifactNotFound
    case storageUnavailable
}

struct UnavailableShareArtifactStore: ShareArtifactStore {
    func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws -> ScopedShareFile {
        throw ShareArtifactRegistryError.storageUnavailable
    }

    func remove(_ file: ScopedShareFile) async throws {
        throw ShareArtifactRegistryError.storageUnavailable
    }

    func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws {
        throw ShareArtifactRegistryError.storageUnavailable
    }

    func removeLink(artifactID: ShareArtifactID) async throws {
        throw ShareArtifactRegistryError.storageUnavailable
    }

    func removeAll() async throws {
        throw ShareArtifactRegistryError.storageUnavailable
    }
}

struct CoreShareArtifact: Sendable {
    let dto: ShareArtifactDTO
    let scopedFile: ScopedShareFile?
    let hasStoredLink: Bool
    let messageCipherID: UUID?
}

/// Owns the lifetime of every outbound share lease. Key-bearing data is passed
/// directly to the scoped Platform store and is never cached by this registry.
actor ShareArtifactRegistry {
    private let store: any ShareArtifactStore
    private var artifacts: [ShareArtifactID: CoreShareArtifact] = [:]

    init(store: any ShareArtifactStore) {
        self.store = store
    }

    func createFile(
        data: Data,
        id: ShareArtifactID,
        filename: String,
        displayName: String,
        contentType: String,
        fileExtension: String,
        requiresKeyDelivery: Bool,
        messageCipherID: UUID?
    ) async throws -> ShareArtifactDTO {
        let scopedFile: ScopedShareFile
        do {
            scopedFile = try await store.create(
                data,
                artifactID: id,
                filename: filename,
                fileExtension: fileExtension
            )
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }

        let dto = ShareArtifactDTO(
            id: id,
            reference: .file(scopedFile.fileURL),
            displayName: displayName,
            contentType: contentType,
            fileExtension: fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: requiresKeyDelivery
        )
        artifacts[id] = CoreShareArtifact(
            dto: dto,
            scopedFile: scopedFile,
            hasStoredLink: false,
            messageCipherID: messageCipherID
        )
        return dto
    }

    func createLink(
        url: URL,
        id: ShareArtifactID,
        displayName: String
    ) async throws -> ShareArtifactDTO {
        do {
            try await store.storeLink(url, artifactID: id)
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }
        let dto = ShareArtifactDTO(
            id: id,
            reference: .opaque(id),
            displayName: displayName,
            contentType: "text/uri-list",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: true
        )
        artifacts[id] = CoreShareArtifact(
            dto: dto,
            scopedFile: nil,
            hasStoredLink: true,
            messageCipherID: nil
        )
        return dto
    }

    func createOpaqueMessage(
        id: ShareArtifactID,
        cipherID: UUID
    ) -> ShareArtifactDTO {
        let dto = ShareArtifactDTO(
            id: id,
            reference: .opaque(id),
            displayName: "Rune Scribe Message",
            contentType: "text/plain",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: false
        )
        artifacts[id] = CoreShareArtifact(
            dto: dto,
            scopedFile: nil,
            hasStoredLink: false,
            messageCipherID: cipherID
        )
        return dto
    }

    func artifact(id: ShareArtifactID) throws -> CoreShareArtifact {
        guard let artifact = artifacts[id] else {
            throw ShareArtifactRegistryError.artifactNotFound
        }
        return artifact
    }

    func release(id: ShareArtifactID) async throws {
        guard let artifact = artifacts[id] else { return }
        if let scopedFile = artifact.scopedFile {
            do {
                try await store.remove(scopedFile)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        } else if artifact.hasStoredLink {
            do {
                try await store.removeLink(artifactID: id)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        }
        artifacts.removeValue(forKey: id)
    }

    func releaseAll() async throws {
        do {
            try await store.removeAll()
            artifacts.removeAll()
        } catch {
            // Keep leases addressable so callers can retry explicit cleanup.
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }
}

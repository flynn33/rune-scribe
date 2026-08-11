import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ShareArtifactRegistryError: Error, Equatable, Sendable {
    case artifactNotFound
    case storageUnavailable
}

struct CoreShareArtifact: Sendable {
    let dto: ShareArtifactDTO
    let hasStoredFile: Bool
    let hasStoredLink: Bool
    let messageCipherID: UUID?
}

/// Owns the lifetime of every outbound share lease. Key-bearing data is passed
/// directly to the scoped Platform store and is never cached by this registry.
actor ShareArtifactRegistry {
    private let runtimeIO: RuntimeIOClient
    private var artifacts: [ShareArtifactID: CoreShareArtifact] = [:]

    init(runtimeIO: RuntimeIOClient) {
        self.runtimeIO = runtimeIO
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
        do {
            try await runtimeIO.createShareArtifact(
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
            reference: .file(id),
            displayName: displayName,
            contentType: contentType,
            fileExtension: fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: requiresKeyDelivery
        )
        artifacts[id] = CoreShareArtifact(
            dto: dto,
            hasStoredFile: true,
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
            try await runtimeIO.storeShareArtifactLink(url, artifactID: id)
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
            hasStoredFile: false,
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
            hasStoredFile: false,
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
        if artifact.hasStoredFile {
            do {
                try await runtimeIO.removeShareArtifact(artifactID: id)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        } else if artifact.hasStoredLink {
            do {
                try await runtimeIO.removeShareArtifactLink(artifactID: id)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        }
        artifacts.removeValue(forKey: id)
    }

    func releaseAll() async throws {
        do {
            try await runtimeIO.removeAllShareArtifacts()
            artifacts.removeAll()
        } catch {
            // Keep leases addressable so callers can retry explicit cleanup.
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }
}

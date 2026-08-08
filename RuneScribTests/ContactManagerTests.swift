import Foundation
import RuneScribeContracts
import XCTest
@testable import RuneScrib

@MainActor
final class ContactManagerTests: XCTestCase {
    private struct Context {
        let keyManager: KeyManager
        let contactManager: ContactManager
    }

    func testAddImportedAutoLinksExactlyOneCipherWithoutChangingActiveSelection() async throws {
        let context = try await makeContext()
        let priorActiveID = context.keyManager.activeCipher?.id

        context.contactManager.addImported([
            Contact(displayName: "Sten", appleContactID: "imp-1", source: .imported),
        ])
        await waitUntil {
            context.contactManager.contacts.contains { $0.appleContactID == "imp-1" }
        }
        let stored = try XCTUnwrap(
            context.contactManager.contacts.first { $0.appleContactID == "imp-1" }
        )
        await waitUntil {
            context.keyManager.ciphers(forContact: stored.id).count == 1
        }

        let linked = context.keyManager.ciphers(forContact: stored.id)
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.label, "Sten")
        XCTAssertEqual(linked.first?.contactID, stored.id)
        XCTAssertNotEqual(context.keyManager.activeCipher?.id, linked.first?.id)
        XCTAssertEqual(context.keyManager.activeCipher?.id, priorActiveID)
    }

    func testReimportingSameSystemIdentifierIsIdempotent() async throws {
        let context = try await makeContext()
        let snapshot = Contact(
            displayName: "Vala",
            appleContactID: "imp-2",
            source: .imported
        )

        context.contactManager.addImported([snapshot])
        await waitUntil {
            context.contactManager.contacts.contains { $0.appleContactID == "imp-2" }
        }
        let stored = try XCTUnwrap(
            context.contactManager.contacts.first { $0.appleContactID == "imp-2" }
        )
        await waitUntil {
            context.keyManager.ciphers(forContact: stored.id).count == 1
        }

        context.contactManager.addImported([snapshot])
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(
            context.contactManager.contacts.filter { $0.displayName == "Vala" }.count,
            1
        )
        XCTAssertEqual(context.keyManager.ciphers(forContact: stored.id).count, 1)
    }

    func testManualAddDoesNotGenerateLinkedCipher() async throws {
        let context = try await makeContext()

        context.contactManager.add(Contact(displayName: "Orm", source: .manual))
        await waitUntil {
            context.contactManager.contacts.contains { $0.displayName == "Orm" }
        }
        let stored = try XCTUnwrap(
            context.contactManager.contacts.first { $0.displayName == "Orm" }
        )

        XCTAssertTrue(context.keyManager.ciphers(forContact: stored.id).isEmpty)
    }

    func testAsyncCreateReturnsAuthoritativePersistedIdentity() async throws {
        let context = try await makeContext()
        let temporaryID = try XCTUnwrap(
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        )

        let persisted = try await context.contactManager.create(
            Contact(id: temporaryID, displayName: "Authoritative", source: .manual)
        )
        await waitUntil {
            context.contactManager.contacts.contains { $0.id == persisted.id }
        }

        XCTAssertNotEqual(persisted.id, temporaryID)
        XCTAssertEqual(
            context.contactManager.contacts.first { $0.id == persisted.id }?.displayName,
            "Authoritative"
        )
    }

    func testBulkDeleteUnlinksCiphersButKeepsThem() async throws {
        let context = try await makeContext()
        context.contactManager.addImported([
            Contact(displayName: "Sten", appleContactID: "bulk-1", source: .imported),
            Contact(displayName: "Vala", appleContactID: "bulk-2", source: .imported),
        ])
        await waitUntil {
            context.contactManager.contacts.filter { $0.source == .imported }.count == 2
        }
        let imported = context.contactManager.contacts.filter { $0.source == .imported }
        let importedIDs = Set(imported.map(\.id))
        await waitUntil {
            context.keyManager.ciphers.filter { cipher in
                cipher.contactID.map(importedIDs.contains) == true
            }.count == 2
        }
        let cipherIDs = context.keyManager.ciphers.compactMap { cipher in
            cipher.contactID.map(importedIDs.contains) == true ? cipher.id : nil
        }

        context.contactManager.delete(ids: importedIDs)
        await waitUntil {
            context.contactManager.contacts.allSatisfy { !importedIDs.contains($0.id) }
                && context.keyManager.ciphers.allSatisfy { cipher in
                    cipher.contactID.map(importedIDs.contains) != true
                }
        }

        XCTAssertEqual(cipherIDs.count, 2)
        for cipherID in cipherIDs {
            let cipher = try XCTUnwrap(
                context.keyManager.ciphers.first { $0.id == cipherID }
            )
            XCTAssertNil(cipher.contactID)
        }
    }

    func testDeleteAllImportedPreservesManualContactsAndCiphers() async throws {
        let context = try await makeContext()
        context.contactManager.add(Contact(displayName: "Manual", source: .manual))
        context.contactManager.addImported([
            Contact(displayName: "Imported", appleContactID: "all-1", source: .imported),
        ])
        await waitUntil {
            context.contactManager.contacts.count == 2
        }
        let imported = try XCTUnwrap(
            context.contactManager.contacts.first { $0.source == .imported }
        )
        await waitUntil {
            context.keyManager.ciphers(forContact: imported.id).count == 1
        }
        let cipherID = try XCTUnwrap(
            context.keyManager.ciphers(forContact: imported.id).first?.id
        )

        context.contactManager.deleteAllImported()
        await waitUntil {
            context.contactManager.contacts.count == 1
                && context.contactManager.contacts.first?.source == .manual
                && context.keyManager.ciphers(forContact: imported.id).isEmpty
        }

        XCTAssertEqual(context.contactManager.contacts.first?.displayName, "Manual")
        XCTAssertNotNil(context.keyManager.ciphers.first { $0.id == cipherID })
    }

    func testBulkDeleteEmptySetIsNoOp() async throws {
        let context = try await makeContext()
        context.contactManager.add(Contact(displayName: "Manual", source: .manual))
        await waitUntil { context.contactManager.contacts.count == 1 }
        let before = context.contactManager.contacts

        context.contactManager.delete(ids: [])

        XCTAssertEqual(context.contactManager.contacts, before)
    }

    private func makeContext() async throws -> Context {
        let integrated = try TestApplicationFactory.makeIntegratedContext()
        let keyManager = KeyManager(service: integrated.service)
        let contactManager = ContactManager(applicationService: integrated.service)
        await waitUntil {
            keyManager.snapshot != nil && !keyManager.isLoading
        }
        return Context(keyManager: keyManager, contactManager: contactManager)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for application state", file: file, line: line)
    }
}

import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class ProgressionVocabularyTests: XCTestCase {
    func testDomainEventRouteClassesEncodeCanonicalCatalogValues() throws {
        let expected: [(DomainEventRouteClass, String)] = [
            (.file, "file"),
            (.customURL, "custom-url"),
            (.qrCode, "qr-code"),
            (.clipboard, "clipboard"),
            (.shareSheet, "share-sheet"),
            (.messages, "messages"),
            (.airDrop, "air-drop"),
            (.fileExport, "file-export"),
            (.qrDisplay, "qr-display"),
            (.any, "any"),
            (.other, "other"),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (route, wireValue) in expected {
            XCTAssertEqual(try encoder.encode(route), Data("\"\(wireValue)\"".utf8))
            XCTAssertEqual(
                try decoder.decode(
                    DomainEventRouteClass.self,
                    from: Data("\"\(wireValue)\"".utf8)
                ),
                route
            )
        }
    }

    func testDomainEventRouteClassesDecodeLegacySchemaOneAliasesCanonically() throws {
        let aliases: [(String, DomainEventRouteClass)] = [
            ("customURL", .customURL),
            ("qrCode", .qrCode),
            ("shareSheet", .shareSheet),
            ("airDrop", .airDrop),
        ]
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for (legacyValue, expected) in aliases {
            let decoded = try decoder.decode(
                DomainEventRouteClass.self,
                from: Data("\"\(legacyValue)\"".utf8)
            )
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(
                try encoder.encode(decoded),
                Data("\"\(expected.rawValue)\"".utf8)
            )
        }

        XCTAssertThrowsError(
            try decoder.decode(
                DomainEventRouteClass.self,
                from: Data("\"recipient-email\"".utf8)
            )
        )
    }

    func testPrivacySafeTokenDescriptionIsAlwaysRedacted() throws {
        let rawValue = String(repeating: "a", count: 32)
        let token = try XCTUnwrap(MessageToken(rawValue: rawValue))

        XCTAssertEqual(token.description, "<redacted-token>")
        XCTAssertEqual(String(describing: token), "<redacted-token>")
        XCTAssertEqual("\(token)", "<redacted-token>")
        XCTAssertFalse(token.description.contains(rawValue))
        XCTAssertEqual(token.rawValue, rawValue)
    }

    func testProgressionRecoveryCapabilityIsHostOnlyAndNeverUIVended() {
        let policy = RuntimePolicy.patternBFoundation

        XCTAssertTrue(policy.vocabulary.contains(RuneScribeCapabilities.progressionRecovery))
        XCTAssertTrue(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionRecovery,
                for: RuneScribeRoles.applicationHost
            )
        )
        XCTAssertFalse(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionRecovery,
                for: RuneScribeRoles.primaryUI
            )
        )
        XCTAssertFalse(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionRecovery,
                for: RuneScribeRoles.core
            )
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.rebuild.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionRecovery
        )
        XCTAssertFalse(
            RuntimeProgressionEndpointCatalog.UIEndpointIDs.contains(
                RuntimeProgressionEndpointCatalog.rebuild.descriptor.endpointID
            )
        )
    }
}

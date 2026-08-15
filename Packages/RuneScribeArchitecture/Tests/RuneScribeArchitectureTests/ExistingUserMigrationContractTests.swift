import Foundation
@_spi(RuntimeExistingUserMigrationAuthority) import RuneScribeContracts
import XCTest

@MainActor
final class ExistingUserMigrationContractTests: XCTestCase {
    func testSnapshotIsCanonicalPrivacySafeAndStrictlyDecoded() throws {
        let tokenA = try XCTUnwrap(Self.token(1))
        let tokenB = try XCTUnwrap(Self.token(2))
        let snapshot = try ExistingUserMigrationSnapshotDTO(ciphers: [
            ExistingUserMigrationCipherDTO(
                cipherToken: tokenB,
                origin: .imported
            ),
            ExistingUserMigrationCipherDTO(
                cipherToken: tokenA,
                origin: .generated
            ),
        ])

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.ciphers.map(\.cipherToken), [tokenA, tokenB])
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "ciphers"])
        let ciphers = try XCTUnwrap(object["ciphers"] as? [[String: Any]])
        XCTAssertTrue(ciphers.allSatisfy {
            Set($0.keys) == ["cipherToken", "origin"]
        })
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in [
            "contact", "delivery", "relationship", "seed", "publicID",
            "keyMaterial",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
        }

        var unknownRoot = object
        unknownRoot["delivered"] = true
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ExistingUserMigrationSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: unknownRoot)
            )
        )

        var unknownEntry = object
        var entryValues = ciphers
        entryValues[0]["contact"] = "forbidden"
        unknownEntry["ciphers"] = entryValues
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ExistingUserMigrationSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: unknownEntry)
            )
        )
    }

    func testSnapshotEnforcesUniqueTokensAnd4096EntryBound() throws {
        let token = try XCTUnwrap(Self.token(1))
        XCTAssertThrowsError(
            try ExistingUserMigrationSnapshotDTO(ciphers: [
                ExistingUserMigrationCipherDTO(
                    cipherToken: token,
                    origin: .generated
                ),
                ExistingUserMigrationCipherDTO(
                    cipherToken: token,
                    origin: .imported
                ),
            ])
        ) {
            XCTAssertEqual(
                $0 as? ExistingUserMigrationContractError,
                .duplicateCipherToken
            )
        }

        let maximum = try (0 ..< ExistingUserMigrationSnapshotDTO.maximumCipherCount)
            .map { index in
                try ExistingUserMigrationCipherDTO(
                    cipherToken: XCTUnwrap(Self.token(index + 10)),
                    origin: index.isMultiple(of: 2) ? .generated : .imported
                )
            }
        let snapshot = try ExistingUserMigrationSnapshotDTO(ciphers: maximum)
        XCTAssertEqual(snapshot.ciphers.count, 4_096)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 1_048_576)

        let overflow = maximum + [
            try ExistingUserMigrationCipherDTO(
                cipherToken: XCTUnwrap(Self.token(5_000)),
                origin: .generated
            ),
        ]
        XCTAssertThrowsError(
            try ExistingUserMigrationSnapshotDTO(ciphers: overflow)
        ) {
            XCTAssertEqual(
                $0 as? ExistingUserMigrationContractError,
                .tooManyCiphers(maximum: 4_096)
            )
        }
    }

    func testSchemaOriginResultAndReceiptWireShapesAreStrict() throws {
        let token = try XCTUnwrap(Self.token(1))
        let base: [String: Any] = [
            "schemaVersion": 1,
            "ciphers": [[
                "cipherToken": token.rawValue,
                "origin": "generated",
            ]],
        ]
        var newer = base
        newer["schemaVersion"] = 2
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ExistingUserMigrationSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: newer)
            )
        ) {
            XCTAssertEqual(
                $0 as? ExistingUserMigrationContractError,
                .unsupportedSchemaVersion
            )
        }
        var invalidOrigin = base
        invalidOrigin["ciphers"] = [[
            "cipherToken": token.rawValue,
            "origin": "legacy",
        ]]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ExistingUserMigrationSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: invalidOrigin)
            )
        )

        let invalidApplied = Data(
            #"{"outcome":"applied","grantTransactionID":"migration.v1","revision":0,"delta":{"changedStatisticCount":0,"completedAchievementCount":0,"completedMilestoneCount":0,"grantedContentCount":0,"grantedEntitlementCount":0,"queuedRevealCount":0}}"#
                .utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ExistingUserMigrationApplyResult.self,
                from: invalidApplied
            )
        )

        struct OuterLedger: Codable, Equatable {
            let receipt: ExistingUserMigrationHandoffReceipt
        }
        let receipt = try ExistingUserMigrationHandoffReceipt(
            transactionID: ExistingUserMigrationTransactionID(rawValue: UUID()),
            snapshotSchemaVersion: 1,
            cipherCount: 1,
            durableAt: Date(timeIntervalSince1970: 12_345.678_901)
        )
        let original = OuterLedger(receipt: receipt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(OuterLedger.self, from: data), original)
    }

    func testPagedHandoffContractsAreBoundedVersionedAndStrict() throws {
        let snapshot = try ExistingUserMigrationSnapshotDTO(ciphers: [
            ExistingUserMigrationCipherDTO(
                cipherToken: XCTUnwrap(Self.token(4_096)),
                origin: .imported
            ),
        ])
        let page = try ExistingUserMigrationPageDTO(
            pageIndex: 1,
            pageCount: 2,
            totalCipherCount: 4_097,
            aggregateDigest: String(repeating: "a", count: 64),
            snapshot: snapshot
        )
        let transactionID = ExistingUserMigrationTransactionID(rawValue: UUID())
        let delivery = ExistingUserMigrationPageDeliveryDTO(
            transactionID: transactionID,
            page: page
        )
        let encoded = try JSONEncoder().encode(delivery)
        XCTAssertLessThan(encoded.count, 1_048_576)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExistingUserMigrationPageDeliveryDTO.self,
                from: encoded
            ),
            delivery
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var pageObject = try XCTUnwrap(object["page"] as? [String: Any])
        pageObject["contact"] = "forbidden"
        object["page"] = pageObject
        XCTAssertThrowsError(try JSONDecoder().decode(
            ExistingUserMigrationPageDeliveryDTO.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        XCTAssertThrowsError(try ExistingUserMigrationPageDTO(
            pageIndex: 2,
            pageCount: 2,
            totalCipherCount: 4_097,
            aggregateDigest: String(repeating: "a", count: 64),
            snapshot: snapshot
        ))

        let accepted = ExistingUserMigrationPageApplyResult.accepted(pageIndex: 1)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExistingUserMigrationPageApplyResult.self,
                from: JSONEncoder().encode(accepted)
            ),
            accepted
        )
        XCTAssertFalse(accepted.isTerminalAcknowledgement)
        XCTAssertTrue(
            ExistingUserMigrationPageApplyResult.outcome(.duplicate)
                .isTerminalAcknowledgement
        )
        let receipt = try ExistingUserMigrationPagedHandoffReceipt(
            transactionID: transactionID,
            handoffSchemaVersion: 2,
            snapshotSchemaVersion: 1,
            cipherCount: 4_097,
            pageCount: 2,
            durableAt: Date(timeIntervalSince1970: 12_345.678)
        )
        XCTAssertEqual(receipt.pageCount, 2)
        XCTAssertThrowsError(try ExistingUserMigrationPagedHandoffReceipt(
            transactionID: transactionID,
            handoffSchemaVersion: 1,
            snapshotSchemaVersion: 1,
            cipherCount: 4_097,
            pageCount: 2,
            durableAt: Date(timeIntervalSince1970: 12_345.678)
        ))
    }

    private static func token(_ index: Int) -> CipherToken? {
        CipherToken(
            rawValue: String(repeating: "c", count: 32)
                + String(format: "%016x", index)
        )
    }
}

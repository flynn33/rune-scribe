import Foundation
import RuneScribeContracts
import XCTest

final class RuntimeSettingsContractTests: XCTestCase {
    func testArtifactSelectionCurrentEncodingIsCanonicalSortedAndRoundTrips() throws {
        let norse = try selection(
            codex: "codex.norse",
            artifact: "relic.norse.dragonwood-plaque",
            kind: .relic
        )
        let moonleaf = try selection(
            codex: "codex.moonleaf",
            artifact: "relic.moonleaf.silver-leaf",
            kind: .relic
        )
        let value = try RuntimeCodexArtifactSelectionMap(
            kind: .relic,
            selections: [norse, moonleaf]
        )

        let encoded = try RuntimeArtifactSelectionCodec.encode(value)
        let decoded = try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
            encoded,
            expectedKind: .relic
        )

        XCTAssertEqual(decoded, value)
        XCTAssertTrue(encoded.rawValue.contains(#""schemaVersion":2"#))
        XCTAssertLessThan(
            encoded.rawValue.range(of: "codex.moonleaf")!.lowerBound,
            encoded.rawValue.range(of: "codex.norse")!.lowerBound
        )
        XCTAssertEqual(try RuntimeArtifactSelectionCodec.encode(decoded), encoded)
    }

    func testArtifactSelectionLegacyReadMigratesAndCurrentWritesRejectLegacy() throws {
        let legacy = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=relic.norse.raven-medallion"
        ))
        let decoded = try RuntimeArtifactSelectionCodec.decodeForRead(
            legacy,
            expectedKind: .relic
        )
        XCTAssertEqual(decoded.encoding, .legacyUnversioned)
        XCTAssertEqual(
            decoded.value[try XCTUnwrap(CodexID(rawValue: "codex.norse"))]?.rawValue,
            "relic.norse.dragonwood-plaque"
        )
        XCTAssertThrowsError(
            try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                legacy,
                expectedKind: .relic
            )
        )
        XCTAssertEqual(
            try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                RuntimeArtifactSelectionCodec.encode(decoded.value),
                expectedKind: .relic
            ),
            decoded.value
        )
    }

    func testArtifactSelectionCanonicalizesEveryLegacyNorseAliasAndRejectsStaleWrites()
        throws
    {
        let aliases: [
            (RuntimeArtifactSelectionKind, String, String)
        ] = NorseArtifactCompatibilityAuthority.relicAliases.map {
            (.relic, $0.key.rawValue, $0.value.rawValue)
        } + NorseArtifactCompatibilityAuthority.sealAliases.map {
            (.seal, $0.key.rawValue, $0.value.rawValue)
        }
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.norse"))

        for (kind, legacy, current) in aliases {
            let legacyText = try XCTUnwrap(RuntimeSettingText(
                rawValue: "codex.norse=\(legacy)"
            ))
            let decoded = try RuntimeArtifactSelectionCodec.decodeForRead(
                legacyText,
                expectedKind: kind
            )
            XCTAssertEqual(decoded.value[codexID]?.rawValue, current, legacy)

            let staleMap = try RuntimeCodexArtifactSelectionMap(
                kind: kind,
                selections: [try selection(
                    codex: codexID.rawValue,
                    artifact: legacy,
                    kind: kind
                )]
            )
            XCTAssertThrowsError(
                try RuntimeArtifactSelectionCodec.encode(staleMap),
                legacy
            ) { error in
                XCTAssertEqual(
                    error as? RuntimeArtifactSelectionContractError,
                    .invalidArtifactID
                )
            }
        }

        let frameID = NorseArtifactCompatibilityAuthority.Current
            .carvedKnotworkFrame.rawValue
        let frameText = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=\(frameID)"
        ))
        let decodedFrame = try RuntimeArtifactSelectionCodec.decodeForRead(
            frameText,
            expectedKind: .frame
        )
        XCTAssertEqual(decodedFrame.value[codexID]?.rawValue, frameID)
        XCTAssertNoThrow(try RuntimeArtifactSelectionCodec.encode(decodedFrame.value))
    }

    func testArtifactSelectionRejectsUnknownNorseButPreservesNonNorseAndNone() throws {
        let unknownText = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=seal.norse.future-seal"
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            unknownText,
            expectedKind: .seal
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .invalidArtifactID
            )
        }

        let unknownMap = try RuntimeCodexArtifactSelectionMap(
            kind: .seal,
            selections: [try selection(
                codex: "codex.norse",
                artifact: "seal.norse.future-seal",
                kind: .seal
            )]
        )
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.encode(unknownMap))

        let moonleaf = try RuntimeCodexArtifactSelectionMap(
            kind: .relic,
            selections: [try selection(
                codex: "codex.moonleaf",
                artifact: "relic.moonleaf.silver-leaf",
                kind: .relic
            )]
        )
        let moonleafEncoded = try RuntimeArtifactSelectionCodec.encode(moonleaf)
        XCTAssertEqual(
            try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                moonleafEncoded,
                expectedKind: .relic
            ),
            moonleaf
        )

        let none = try RuntimeCodexArtifactSelectionMap(kind: .frame).setting(
            nil,
            for: XCTUnwrap(CodexID(rawValue: "codex.norse"))
        )
        XCTAssertNoThrow(try RuntimeArtifactSelectionCodec.encode(none))
    }

    func testArtifactSelectionRejectsDuplicatesFutureMalformedAndWrongKinds() throws {
        let duplicate = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=relic.norse.one;codex.norse=relic.norse.two"
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            duplicate,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .duplicateCodexID
            )
        }

        let future = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"relic","schemaVersion":3,"selections":[]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            future,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .unsupportedVersion(3)
            )
        }

        for raw in [
            "broken",
            "norse=relic.norse.one",
            "codex.norse=seal.norse.one",
            "codex.norse=relic.norse.one;",
        ] {
            let text = try XCTUnwrap(RuntimeSettingText(rawValue: raw))
            XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
                text,
                expectedKind: .relic
            ), raw)
        }

        let unexpected = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"extra":true,"kind":"relic","schemaVersion":1,"selections":[]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            unexpected,
            expectedKind: .relic
        ))

        for schemaVersion in ["true", "false", "1.5"] {
            let text = try XCTUnwrap(RuntimeSettingText(
                rawValue: #"{"kind":"relic","schemaVersion":\#(schemaVersion),"selections":[]}"#
            ))
            XCTAssertThrowsError(
                try RuntimeArtifactSelectionCodec.decodeForRead(text, expectedKind: .relic),
                "schemaVersion=\(schemaVersion) must not decode as an integer"
            )
        }

        let nestedUnexpected = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"relic","schemaVersion":1,"selections":[{"artifactID":"relic.norse.one","codexID":"codex.norse","extra":true}]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            nestedUnexpected,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .unexpectedFields
            )
        }

        let nonCanonical = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"relic", "schemaVersion":2,"selections":[]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
            nonCanonical,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .nonCanonical
            )
        }
    }

    func testArtifactSelectionV2PersistsExplicitOptionalNone() throws {
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.norse"))
        let fallbackSeal = try XCTUnwrap(ArtifactID(rawValue: "seal.norse.valknut"))
        let empty = try RuntimeCodexArtifactSelectionMap(kind: .seal)
        let explicitNone = try empty.setting(nil, for: codexID)

        XCTAssertNil(empty.storedPreference(for: codexID))
        XCTAssertEqual(
            explicitNone.storedPreference(for: codexID),
            RuntimeArtifactSelectionPreference.none
        )
        XCTAssertNil(explicitNone[codexID])
        XCTAssertNil(explicitNone.resolvedArtifactID(
            for: codexID,
            availableArtifactIDs: [fallbackSeal],
            fallbackArtifactID: fallbackSeal
        ))

        let encoded = try RuntimeArtifactSelectionCodec.encode(explicitNone)
        XCTAssertEqual(
            encoded.rawValue,
            #"{"kind":"seal","schemaVersion":2,"selections":[{"artifactID":null,"codexID":"codex.norse"}]}"#
        )
        let decoded = try RuntimeArtifactSelectionCodec.decodeForRead(
            encoded,
            expectedKind: .seal
        )
        XCTAssertEqual(decoded.encoding, .current)
        XCTAssertEqual(
            decoded.value.storedPreference(for: codexID),
            RuntimeArtifactSelectionPreference.none
        )
        XCTAssertEqual(
            try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                encoded,
                expectedKind: .seal
            ),
            explicitNone
        )
    }

    func testArtifactSelectionReadsV1AndUnversionedNoneButWritesOnlyV2() throws {
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.norse"))
        let versionOne = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"frame","schemaVersion":1,"selections":[{"artifactID":"frame.none","codexID":"codex.norse"}]}"#
        ))
        let decodedV1 = try RuntimeArtifactSelectionCodec.decodeForRead(
            versionOne,
            expectedKind: .frame
        )
        XCTAssertEqual(decodedV1.encoding, .legacySchemaVersion(1))
        XCTAssertEqual(
            decodedV1.value.storedPreference(for: codexID),
            RuntimeArtifactSelectionPreference.none
        )
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
            versionOne,
            expectedKind: .frame
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .nonCanonical
            )
        }

        let unversioned = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=frame.none"
        ))
        let decodedUnversioned = try RuntimeArtifactSelectionCodec.decodeForRead(
            unversioned,
            expectedKind: .frame
        )
        XCTAssertEqual(decodedUnversioned.encoding, .legacyUnversioned)
        XCTAssertEqual(
            decodedUnversioned.value.storedPreference(for: codexID),
            RuntimeArtifactSelectionPreference.none
        )

        let canonicalV2 = try RuntimeArtifactSelectionCodec.encode(decodedV1.value)
        XCTAssertTrue(canonicalV2.rawValue.contains(#""artifactID":null"#))
        XCTAssertTrue(canonicalV2.rawValue.contains(#""schemaVersion":2"#))
        XCTAssertNoThrow(try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
            canonicalV2,
            expectedKind: .frame
        ))
    }

    func testArtifactSelectionRejectsNullRelicAndSentinelIDsInV2() throws {
        let nullRelic = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"relic","schemaVersion":2,"selections":[{"artifactID":null,"codexID":"codex.norse"}]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            nullRelic,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .artifactKindMismatch
            )
        }

        for (kind, sentinel) in [
            (RuntimeArtifactSelectionKind.seal, "seal.none"),
            (.frame, "frame.none"),
        ] {
            let text = try XCTUnwrap(RuntimeSettingText(
                rawValue: #"{"kind":"\#(kind.rawValue)","schemaVersion":2,"selections":[{"artifactID":"\#(sentinel)","codexID":"codex.norse"}]}"#
            ))
            XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
                text,
                expectedKind: kind
            )) { error in
                XCTAssertEqual(
                    error as? RuntimeArtifactSelectionContractError,
                    .artifactKindMismatch
                )
            }
        }
    }

    func testArtifactSelectionBoundAndSafeFallback() throws {
        let selections = try (0 ... RuntimeCodexArtifactSelectionMap.maximumSelectionCount).map {
            try selection(
                codex: "codex.test-\($0)",
                artifact: "frame.test-\($0)",
                kind: .frame
            )
        }
        XCTAssertThrowsError(
            try RuntimeCodexArtifactSelectionMap(kind: .frame, selections: selections)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .tooManySelections(
                    maximum: RuntimeCodexArtifactSelectionMap.maximumSelectionCount
                )
            )
        }

        let map = try RuntimeCodexArtifactSelectionMap(
            kind: .frame,
            selections: [try selection(
                codex: "codex.norse",
                artifact: "frame.norse.locked",
                kind: .frame
            )]
        )
        let fallback = try XCTUnwrap(ArtifactID(rawValue: "frame.norse.default"))
        XCTAssertEqual(
            map.resolvedArtifactID(
                for: try XCTUnwrap(CodexID(rawValue: "codex.norse")),
                availableArtifactIDs: [fallback],
                fallbackArtifactID: fallback
            ),
            fallback
        )
        XCTAssertNil(map.resolvedArtifactID(
            for: try XCTUnwrap(CodexID(rawValue: "codex.norse")),
            availableArtifactIDs: []
        ))
    }

    func testSelectedCodexPreferenceHasCanonicalAndLegacyReadPaths() throws {
        let legacy = try XCTUnwrap(RuntimeSettingText(rawValue: "codex.moonleaf"))
        let migrated = try RuntimeSelectedCodexPreferenceCodec.decodeForRead(legacy)
        XCTAssertEqual(migrated.encoding, .legacyUnversioned)
        XCTAssertEqual(migrated.value.codexID.rawValue, "codex.moonleaf")
        XCTAssertThrowsError(
            try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(legacy)
        )

        let canonical = try RuntimeSelectedCodexPreferenceCodec.encode(migrated.value)
        XCTAssertEqual(
            try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(canonical),
            migrated.value
        )
        let nonCanonical = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"schemaVersion":1, "codexID":"codex.moonleaf"}"#
        ))
        XCTAssertThrowsError(
            try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(nonCanonical)
        )
        let future = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"codexID":"codex.moonleaf","schemaVersion":99}"#
        ))
        XCTAssertThrowsError(try RuntimeSelectedCodexPreferenceCodec.decodeForRead(future)) {
            XCTAssertEqual(
                $0 as? RuntimeArtifactSelectionContractError,
                .unsupportedVersion(99)
            )
        }
        XCTAssertThrowsError(try RuntimeSelectedCodexPreference(
            codexID: XCTUnwrap(CodexID(rawValue: "theme.moonleaf"))
        ))

        for schemaVersion in ["true", "false", "1.5"] {
            let text = try XCTUnwrap(RuntimeSettingText(
                rawValue: #"{"codexID":"codex.moonleaf","schemaVersion":\#(schemaVersion)}"#
            ))
            XCTAssertThrowsError(
                try RuntimeSelectedCodexPreferenceCodec.decodeForRead(text),
                "schemaVersion=\(schemaVersion) must not decode as an integer"
            )
        }

        let unexpected = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"codexID":"codex.moonleaf","extra":true,"schemaVersion":1}"#
        ))
        XCTAssertThrowsError(try RuntimeSelectedCodexPreferenceCodec.decodeForRead(unexpected)) {
            XCTAssertEqual(
                $0 as? RuntimeArtifactSelectionContractError,
                .unexpectedFields
            )
        }

        XCTAssertNil(RuntimeSettingText(
            rawValue: String(repeating: "x", count: RuntimeSettingText.maximumUTF8Count + 1)
        ))
    }

    private func selection(
        codex: String,
        artifact: String,
        kind: RuntimeArtifactSelectionKind
    ) throws -> RuntimeCodexArtifactSelection {
        try RuntimeCodexArtifactSelection(
            codexID: XCTUnwrap(CodexID(rawValue: codex)),
            artifactID: XCTUnwrap(ArtifactID(rawValue: artifact)),
            kind: kind
        )
    }
}

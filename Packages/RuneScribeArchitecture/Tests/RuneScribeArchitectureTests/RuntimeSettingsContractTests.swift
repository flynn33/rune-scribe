import Foundation
import RuneScribeContracts
import XCTest

final class RuntimeSettingsContractTests: XCTestCase {
    func testArtifactSelectionCurrentEncodingIsCanonicalSortedAndRoundTrips() throws {
        let norse = try selection(
            codex: "codex.norse",
            artifact: "relic.norse.raven-medallion",
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
            "relic.norse.raven-medallion"
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
            rawValue: #"{"kind":"relic","schemaVersion":2,"selections":[]}"#
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            future,
            expectedKind: .relic
        )) { error in
            XCTAssertEqual(
                error as? RuntimeArtifactSelectionContractError,
                .unsupportedVersion(2)
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

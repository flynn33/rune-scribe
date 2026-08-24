import Foundation
import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class CipherShareLifecycleTests: XCTestCase {
    func testOutboundFontProjectionUsesRequestedNonactiveRegisteredCipher() throws {
        let activeID = UUID(uuidString: "91000000-0000-0000-0000-000000000001")!
        let requestedID = UUID(uuidString: "91000000-0000-0000-0000-000000000002")!
        let active = cipher(
            id: activeID,
            isActive: true,
            fontName: "ActiveRunes-Regular",
            fontSource: .imported,
            fontIsRegistered: true
        )
        let requested = cipher(
            id: requestedID,
            isActive: false,
            fontName: "RequestedRunes-Regular",
            fontSource: .imported,
            fontIsRegistered: true
        )

        let projection = OutboundShareFontPolicy.projection(
            for: requestedID,
            in: [active, requested]
        )

        XCTAssertEqual(
            projection,
            .registeredImportedFont(
                try XCTUnwrap(
                    ThemeFontPostScriptName(rawValue: "RequestedRunes-Regular")
                )
            )
        )
        XCTAssertEqual(
            projection.fontPostScriptNameOverride?.rawValue,
            "RequestedRunes-Regular"
        )
    }

    func testOutboundFontProjectionFallsBackForRequestedUnregisteredCustomCipher() {
        let activeID = UUID(uuidString: "91000000-0000-0000-0000-000000000003")!
        let requestedID = UUID(uuidString: "91000000-0000-0000-0000-000000000004")!
        let active = cipher(
            id: activeID,
            isActive: true,
            fontName: "ActiveRunes-Regular",
            fontSource: .imported,
            fontIsRegistered: true
        )
        let requested = cipher(
            id: requestedID,
            isActive: false,
            fontName: "missing-custom-font",
            fontSource: .imported,
            fontIsRegistered: false
        )

        let projection = OutboundShareFontPolicy.projection(
            for: requestedID,
            in: [active, requested]
        )

        XCTAssertEqual(projection, .themeScriptFallback(.importedFontUnregistered))
        XCTAssertNil(projection.fontPostScriptNameOverride)
        XCTAssertEqual(
            projection.shareFallbackNotice,
            "Custom script unavailable — shares use the Codex script."
        )
    }

    func testOutboundFontProjectionRejectsUnsupportedRegisteredFontName() {
        let cipherID = UUID(uuidString: "91000000-0000-0000-0000-000000000005")!
        let requested = cipher(
            id: cipherID,
            isActive: false,
            fontName: "Unsupported Font Name",
            fontSource: .imported,
            fontIsRegistered: true
        )

        let projection = OutboundShareFontPolicy.projection(
            for: cipherID,
            in: [requested]
        )

        XCTAssertEqual(projection, .themeScriptFallback(.importedFontUnsupported))
        XCTAssertEqual(
            projection.shareFallbackNotice,
            "Custom script unavailable — shares use the Codex script."
        )
    }

    func testOutboundBuilderNeverDerivesOperationFontFromActiveCipher() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
        let builder = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("Sharing", isDirectory: true)
                .appendingPathComponent("OutboundSharePresentationBuilder.swift"),
            encoding: .utf8
        )
        let commands = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("Presentation", isDirectory: true)
                .appendingPathComponent("RuneScribeUISession+Commands.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(builder.contains("activeCipher"))
        XCTAssertTrue(builder.contains("OutboundShareFontPolicy.projection"))
        XCTAssertGreaterThanOrEqual(
            commands.components(separatedBy: "cipherID: cipherID").count - 1,
            2
        )
    }

    func testExportLeaseRejectsOverlapAndIgnoresStaleCompletion() {
        let firstCipherID = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
        let secondCipherID = UUID(uuidString: "92000000-0000-0000-0000-000000000002")!
        let firstOperationID = UUID(uuidString: "92000000-0000-0000-0000-000000000003")!
        let secondOperationID = UUID(uuidString: "92000000-0000-0000-0000-000000000004")!
        var gate = CipherLibraryShareOperationGate()

        XCTAssertTrue(gate.beginExport(
            cipherID: firstCipherID,
            operationID: firstOperationID
        ))
        XCTAssertFalse(gate.beginExport(
            cipherID: secondCipherID,
            operationID: secondOperationID
        ))
        XCTAssertEqual(gate.exportCipherID, firstCipherID)
        XCTAssertFalse(gate.finishExport(operationID: secondOperationID))
        XCTAssertEqual(gate.exportCipherID, firstCipherID)
        XCTAssertTrue(gate.finishExport(operationID: firstOperationID))
        XCTAssertTrue(gate.beginExport(
            cipherID: secondCipherID,
            operationID: secondOperationID
        ))
    }

    func testCipherDeletionAndDisappearanceCancelOnlyOwnedOperations() {
        let exportCipherID = UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
        let shareCipherID = UUID(uuidString: "93000000-0000-0000-0000-000000000002")!
        let exportOperationID = UUID(uuidString: "93000000-0000-0000-0000-000000000003")!
        let shareOperationID = UUID(uuidString: "93000000-0000-0000-0000-000000000004")!
        var gate = CipherLibraryShareOperationGate()
        XCTAssertTrue(gate.beginExport(
            cipherID: exportCipherID,
            operationID: exportOperationID
        ))
        XCTAssertTrue(gate.beginPreparation(
            cipherID: shareCipherID,
            operationID: shareOperationID
        ))

        let deletion = gate.cancelOperations(for: exportCipherID)
        XCTAssertEqual(deletion.export?.operationID, exportOperationID)
        XCTAssertNil(deletion.preparation)
        XCTAssertNil(gate.export)
        XCTAssertEqual(gate.preparation?.operationID, shareOperationID)

        let disappearance = gate.cancelOperations()
        XCTAssertNil(disappearance.export)
        XCTAssertEqual(disappearance.preparation?.operationID, shareOperationID)
        XCTAssertNil(gate.preparation)
    }

    func testCipherLibraryCleanupWiresExportQRAndPreparationResources() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
                .appendingPathComponent("Views", isDirectory: true)
                .appendingPathComponent("CipherLibraryView.swift"),
            encoding: .utf8
        )

        for required in [
            ".onDisappear {\n            isViewActive = false\n            releasePreparedShares()",
            "exportTask?.cancel()",
            "preparationTask?.cancel()",
            "await exportTransfer?.close()",
            "await qr.transfer.close()",
            "shareOperations.cancelOperations(for: cipherID)",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
    }

    func testCipherLibraryPresentsFallbackNoticeAndRespectsTerminalDisposition() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
                .appendingPathComponent("Views", isDirectory: true)
                .appendingPathComponent("CipherLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(").shareFallbackNotice"))
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"cipher.share-fallback\")")
        )
        XCTAssertTrue(
            source.contains("ShareBuilderTerminalDisposition(routeResult: routeResult)")
        )
        XCTAssertTrue(source.contains("case .cancelled:\n                    status = .idle"))
    }

    private func cipher(
        id: UUID,
        isActive: Bool,
        fontName: String,
        fontSource: FontSourceDTO,
        fontIsRegistered: Bool
    ) -> CipherViewState {
        CipherViewState(
            id: id,
            label: id.uuidString,
            origin: .generated,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isActive: isActive,
            contactID: nil,
            delivered: false,
            publicIdentifier: id.uuidString.replacingOccurrences(of: "-", with: ""),
            fontName: fontName,
            fontSource: fontSource,
            fontIsRegistered: fontIsRegistered
        )
    }
}

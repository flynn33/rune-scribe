import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import SwiftUI
import XCTest
@testable import RuneScribeUIModule

@MainActor
final class RootViewPresentationTests: XCTestCase {
    func testTutorialCatalogExplainsArtifactsAndRecipientFlow() {
        let tutorialText = RuneScribeTutorialCatalog.pages.flatMap { page in
            [page.title, page.summary] + page.details
        }.joined(separator: " ")

        for requiredTerm in ["Relic", "Seal", "Frame", "import confirmation", "App Store"] {
            XCTAssertTrue(tutorialText.localizedCaseInsensitiveContains(requiredTerm))
        }
    }

    func testImportAndMessagePresentationsTakePriorityOverTutorial() {
        XCTAssertEqual(
            RootPendingPresentationPolicy.selection(
                showSplash: false,
                isLocked: false,
                hasPendingImport: true,
                hasPendingMessage: true,
                needsTutorial: true
            ),
            .importConfirmation
        )
        XCTAssertEqual(
            RootPendingPresentationPolicy.selection(
                showSplash: false,
                isLocked: false,
                hasPendingImport: false,
                hasPendingMessage: true,
                needsTutorial: true
            ),
            .receivedMessage
        )
        XCTAssertEqual(
            RootPendingPresentationPolicy.selection(
                showSplash: false,
                isLocked: false,
                hasPendingImport: false,
                hasPendingMessage: false,
                needsTutorial: true
            ),
            .tutorial
        )
    }

    func testStorePresentsExactlyOneContributionAndDismissesItsOwner() throws {
        let store = RootViewPresentationStore()
        let moduleID: ModuleIdentifier = "com.runescribe.module.ui"
        let contribution = RootViewContribution(moduleID: moduleID) {
            AnyView(Text("Root"))
        }

        XCTAssertEqual(store.state, .booting)
        try store.present(contribution)
        XCTAssertEqual(store.state, .ready(moduleID: moduleID))
        _ = RuntimePresentedRootView(store: store)

        store.dismiss(moduleID: "com.runescribe.module.other")
        XCTAssertEqual(store.state, .ready(moduleID: moduleID))
        store.dismiss(moduleID: moduleID)
        XCTAssertEqual(store.state, .booting)
    }

    func testStoreRejectsASecondUIOwnerAndSupportsSafeRecovery() throws {
        let store = RootViewPresentationStore()
        let primary: ModuleIdentifier = "com.runescribe.module.ui"
        let second: ModuleIdentifier = "com.runescribe.module.other-ui"
        try store.present(
            RootViewContribution(moduleID: primary) { AnyView(EmptyView()) }
        )

        XCTAssertThrowsError(
            try store.present(
                RootViewContribution(moduleID: second) { AnyView(EmptyView()) }
            )
        ) { error in
            XCTAssertEqual(
                error as? RootContributionError,
                .multiple([second, primary].sorted())
            )
        }
        XCTAssertEqual(store.state, .ready(moduleID: primary))

        store.recover(message: "Please reopen the app.")
        XCTAssertEqual(store.state, .recovery(message: "Please reopen the app."))
    }
}

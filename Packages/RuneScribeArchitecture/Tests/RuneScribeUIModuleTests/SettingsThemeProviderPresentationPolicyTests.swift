import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class SettingsThemeProviderPresentationPolicyTests: XCTestCase {
    func testFailureStatesTakePrecedenceOverSelectedFlag() {
        let cases: [(
            state: ThemeProviderState,
            status: String,
            icon: String
        )] = [
            (
                .locked,
                "Locked",
                "lock.fill"
            ),
            (
                .unavailable,
                "Temporarily unavailable",
                "exclamationmark.circle"
            ),
            (
                .incompatible,
                "Requires a newer app or system",
                "arrow.up.circle"
            ),
            (
                .invalidResources,
                "Unavailable because required resources could not be verified",
                "exclamationmark.circle"
            ),
        ]

        for item in cases {
            let provider = makeProvider(
                state: item.state,
                isSelected: true
            )
            XCTAssertEqual(
                SettingsThemeProviderPresentationPolicy.status(provider),
                item.status
            )
            XCTAssertEqual(
                SettingsThemeProviderPresentationPolicy.visualState(provider),
                item.state == .locked ? .locked : .unavailable
            )
            XCTAssertEqual(
                SettingsThemeProviderPresentationPolicy.icon(provider),
                item.icon
            )
        }
    }

    func testNonavailableStateOverridesSelectedCodexCardArtwork() {
        for state in [
            ThemeProviderState.locked,
            .unavailable,
            .incompatible,
            .invalidResources,
        ] {
            let provider = makeProvider(state: state, isSelected: true)
            XCTAssertEqual(
                RuneScribeUISession.codexCardPreviewRoleCandidates(
                    for: provider
                ),
                state == .locked
                    ? [ThemeResourceRoles.vaultLockedSilhouette]
                    : [ThemeResourceRoles.vaultUnavailable]
            )
        }
    }

    func testAvailableSelectedProviderKeepsSelectedPresentation() {
        let provider = makeProvider(state: .available, isSelected: true)

        XCTAssertEqual(
            SettingsThemeProviderPresentationPolicy.status(provider),
            "Available"
        )
        XCTAssertEqual(
            SettingsThemeProviderPresentationPolicy.visualState(provider),
            .selected
        )
        XCTAssertEqual(
            SettingsThemeProviderPresentationPolicy.icon(provider),
            "checkmark.circle.fill"
        )
    }

    private func makeProvider(
        state: ThemeProviderState,
        isSelected: Bool
    ) -> ThemeProviderSummaryDTO {
        ThemeProviderSummaryDTO(
            codexID: RuneScribeCodexIDs.norse,
            moduleID: RuneScribeModuleIDs.norseTheme,
            displayName: "Norse",
            state: state,
            isOwned: true,
            isSelectable: state == .available,
            isSelected: isSelected
        )
    }
}

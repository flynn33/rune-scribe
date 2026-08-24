import Foundation
import RuneScribeUIRuntime
import SwiftUI

enum SimulatorAccessibilityQualification {
    static let environmentKey = "RUNESCRIBE_QUALIFICATION_ACCESSIBILITY"
    static let requestedValue = "accessibility5-high-contrast-reduced-motion"

    static var isRequested: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[environmentKey] == requestedValue
        #else
        false
        #endif
    }
}

private struct SimulatorAccessibilityQualificationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if SimulatorAccessibilityQualification.isRequested {
            content
                .dynamicTypeSize(.accessibility5)
                .environment(
                    \.runtimeAccessibilityPreferences,
                    RuntimeAccessibilityPreferences(
                        forcesReduceMotion: true,
                        forcesIncreasedContrast: true
                    )
                )
        } else {
            content
        }
    }
}

extension View {
    func runeSimulatorAccessibilityQualification() -> some View {
        modifier(SimulatorAccessibilityQualificationModifier())
    }
}

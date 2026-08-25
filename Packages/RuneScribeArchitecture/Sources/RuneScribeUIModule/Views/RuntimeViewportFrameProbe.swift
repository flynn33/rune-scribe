import SwiftUI

enum RuntimeViewportFrameProbeCoordinateSpace {
    static let name = "runescribe.runtime-viewport-frame-probe"
}

struct RuntimeViewportFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct RuntimeViewportFrameProbeEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var runtimeViewportFrameProbeEnabled: Bool {
        get { self[RuntimeViewportFrameProbeEnabledKey.self] }
        set { self[RuntimeViewportFrameProbeEnabledKey.self] = newValue }
    }
}

private struct RuntimeViewportFrameProbeModifier: ViewModifier {
    @Environment(\.runtimeViewportFrameProbeEnabled) private var isEnabled
    let identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.overlay {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: RuntimeViewportFramePreferenceKey.self,
                        value: [
                            identifier: geometry.frame(
                                in: .named(RuntimeViewportFrameProbeCoordinateSpace.name)
                            ),
                        ]
                    )
                }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func runtimeViewportFrameProbe(_ identifier: String) -> some View {
        modifier(RuntimeViewportFrameProbeModifier(identifier: identifier))
    }
}

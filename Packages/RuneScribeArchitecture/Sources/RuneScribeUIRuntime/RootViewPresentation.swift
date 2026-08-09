import RuneScribeContracts
import SwiftUI

@MainActor
public final class RootViewPresentationStore: ObservableObject {
    @Published public private(set) var state: BootPresentationState = .booting

    private var contribution: RootViewContribution?

    public init() {}

    public func present(_ contribution: RootViewContribution) throws {
        if let current = self.contribution,
           current.moduleID != contribution.moduleID {
            _ = try RootContributionSelector.select(from: [current, contribution])
        }
        self.contribution = contribution
        state = .ready(moduleID: contribution.moduleID)
    }

    public func dismiss(moduleID: ModuleIdentifier) {
        guard contribution?.moduleID == moduleID else { return }
        contribution = nil
        state = .booting
    }

    public func recover(message: String) {
        contribution = nil
        state = .recovery(message: message)
    }

    fileprivate func presentedView() -> AnyView? {
        contribution?.makeView()
    }
}

public struct RuntimePresentedRootView: View {
    @ObservedObject private var store: RootViewPresentationStore

    public init(store: RootViewPresentationStore) {
        self.store = store
    }

    public var body: some View {
        switch store.state {
        case .booting:
            ProgressView()
                .accessibilityLabel("Starting Rune Scribe")
        case .ready:
            if let view = store.presentedView() {
                view
            } else {
                recoveryView(message: "The interface is unavailable.")
            }
        case let .recovery(message):
            recoveryView(message: message)
        }
    }

    private func recoveryView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
            Text("Rune Scribe could not start")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

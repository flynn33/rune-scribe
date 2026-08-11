import RuneScribeContracts
import RuneScribeUIPresentationContracts
import SwiftUI

public enum RootPresentationNotice: Equatable, Sendable {
    case inputRejected
    case inputUnavailable

    public var message: String {
        switch self {
        case .inputRejected:
            "Rune Scribe could not accept that item."
        case .inputUnavailable:
            "Rune Scribe could not open that item right now."
        }
    }
}

@MainActor
public final class RootViewPresentationStore: ObservableObject {
    @Published public private(set) var state: BootPresentationState = .booting
    @Published public private(set) var notice: RootPresentationNotice?

    private var contribution: RootViewContribution?

    public init() {}

    public func runtimeHostAdapter(
        productMetadata: RuneScribeUIProductMetadata
    ) -> RuntimeRootPresentationHostAdapter {
        RuntimeRootPresentationHostAdapter(
            productMetadata: productMetadata,
            present: { [weak self] contribution in
                guard let self else {
                    throw RootContributionError.none
                }
                try self.present(contribution)
            },
            dismiss: { [weak self] moduleID in
                self?.dismiss(moduleID: moduleID)
            }
        )
    }

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
        notice = nil
        state = .recovery(message: message)
    }

    public func presentNotice(_ notice: RootPresentationNotice) {
        self.notice = notice
    }

    public func dismissNotice() {
        notice = nil
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
        ZStack(alignment: .top) {
            presentedContent
            if let notice = store.notice {
                noticeView(notice)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var presentedContent: some View {
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

    private func noticeView(_ notice: RootPresentationNotice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(notice.message)
            Button("Dismiss") {
                store.dismissNotice()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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

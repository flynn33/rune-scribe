import RuneScribeContracts
import SwiftUI

@MainActor
enum ContactImportCommitOutcome: Equatable {
    case imported
    case failed(String)

    var shouldDismiss: Bool {
        if case .imported = self {
            return true
        }
        return false
    }
}

@MainActor
enum ContactImportCommitFlow {
    static func attempt(
        operation: () async throws -> Void
    ) async -> ContactImportCommitOutcome {
        do {
            try await operation()
            return .imported
        } catch {
            return .failed(RuneScribeUISession.message(for: error))
        }
    }
}

/// In-app multi-select importer: lists the device's Apple Contacts with search and
/// check-to-select, and imports only the chosen ones. Used where the system contact
/// picker isn't available (macOS); iOS uses the out-of-process system picker instead.
struct ContactImportPicker: View {
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    /// Importable contacts (those not already in the list), sorted by name.
    @State private var candidates: [ContactViewState] = []
    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var importError: String?

    private enum Phase: Equatable { case loading, denied, failed(String), loaded }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᚲᛟᚾᛏᚪᚲᛏᛋ",
                subtitle: "Import Selected",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Cancel") { dismiss() }]
            )
            content
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .task { await load() }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Derived

    private var filtered: [ContactViewState] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.lowercased().contains(q)
                || $0.phones.contains { $0.lowercased().contains(q) }
                || $0.emails.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            centered { ProgressView().tint(.runeGold) }
        case .denied:
            messageState(icon: "person.crop.circle.badge.exclamationmark",
                         title: "Contacts access is off",
                         detail: "Allow Contacts access for Rune Scribe in System Settings to choose people to import.")
        case .failed(let message):
            messageState(icon: "exclamationmark.triangle",
                         title: "Couldn't load contacts",
                         detail: message)
        case .loaded where candidates.isEmpty:
            messageState(icon: "person.2",
                         title: "Nothing to import",
                         detail: "Every named contact on this device is already in your list.")
        case .loaded:
            VStack(spacing: 0) {
                searchField
                listScroll
                footer
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.runeSilver)
            TextField("Search contacts", text: $search)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.runeSilver)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 14))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(Color.runeParchment))
        .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
            .strokeBorder(Color.runeSilver.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.top, RuneMetrics.pad)
    }

    private var listScroll: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filtered) { row($0) }
                if filtered.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundColor(.runeSilver)
                        .padding(.vertical, 28)
                }
            }
            .padding(RuneMetrics.pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ contact: ContactViewState) -> some View {
        let isOn = selection.contains(contact.id)
        return Button {
            if isOn {
                selection.remove(contact.id)
            } else {
                selection.insert(contact.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn ? .runeBlue : .runeSilver)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let sub = contact.phones.first ?? contact.emails.first {
                        Text(sub)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.runeSilver)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(Color.runeParchment))
            .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder((isOn ? Color.runeBlue : Color.runeSilver).opacity(isOn ? 0.5 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button("Select All") { selection = Set(filtered.map(\.id)) }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .disabled(filtered.isEmpty)
                Button("Clear") { selection.removeAll() }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .disabled(selection.isEmpty)
            }
            Button { commitImport() } label: {
                Label(selection.isEmpty ? "Import" : "Import \(selection.count)",
                      systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneScribButtonStyle())
            .disabled(selection.isEmpty)
        }
        .padding(RuneMetrics.pad)
    }

    private func centered<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageState(icon: String, title: String, detail: String) -> some View {
        centered {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 32)).foregroundColor(.runeSilver.opacity(0.6))
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RuneMetrics.pad)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        let existing = Set(session.contacts.compactMap(\.systemIdentifier))
        do {
            let all = try await session.fetchSystemContacts()
            candidates = all
                .filter {
                    $0.systemIdentifier.map { !existing.contains($0) } ?? true
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            phase = .loaded
        } catch {
            if Self.isContactAccessDenied(error) {
                phase = .denied
            } else {
                phase = .failed(RuneScribeUISession.message(for: error))
            }
        }
    }

    private func commitImport() {
        let chosen = candidates.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        Task {
            let outcome = await ContactImportCommitFlow.attempt {
                _ = try await session.importContacts(chosen)
            }
            switch outcome {
            case .imported:
                dismiss()
            case .failed(let message):
                importError = message
            }
        }
    }

    private static func isContactAccessDenied(_ error: Error) -> Bool {
        guard let productError = error as? RuneScribeProductError,
              case .failure(let failure) = productError else { return false }
        return failure.code == .authorizationDenied
    }
}

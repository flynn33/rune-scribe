import SwiftUI

/// Manage the people you organize ciphers by: add manually, import from Apple Contacts
/// (system picker on iOS, or import-all with permission), rename, and delete. Deleting a
/// contact unlinks its ciphers but never deletes them.
struct ContactsView: View {
    @EnvironmentObject private var contactManager: ContactManager
    @EnvironmentObject private var keyManager: KeyManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAddManual = false
    @State private var newName = ""
    @State private var newPhone = ""
    @State private var newEmail = ""

    @State private var editTarget: Contact?
    @State private var editName = ""
    @State private var showEdit = false

    @State private var deleteTarget: Contact?
    @State private var showDelete = false

    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showBulkDelete = false
    @State private var showRemoveAllImported = false

    #if os(iOS)
    @State private var showPicker = false
    #endif
    @State private var importing = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showSaveError = false

    var body: some View {
        base
            .alert("New Contact", isPresented: $showAddManual) {
                TextField("Name", text: $newName)
                TextField("Phone (optional)", text: $newPhone)
                TextField("Email (optional)", text: $newEmail)
                Button("Add") { addManual() }
                Button("Cancel", role: .cancel) { resetManual() }
            } message: {
                Text("Add a person to organize ciphers by. Stored only on this device.")
            }
            .alert("Rename Contact", isPresented: $showEdit) {
                TextField("Name", text: $editName)
                Button("Save") { commitEdit() }
                Button("Cancel", role: .cancel) { editTarget = nil }
            }
            .alert(deleteTarget.map { "Delete \u{201c}\($0.displayName)\u{201d}?" } ?? "", isPresented: $showDelete) {
                Button("Delete", role: .destructive) { commitDelete() }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                if let target = deleteTarget { deleteMessageText(for: target) }
            }
            .alert("Remove \(selection.count) Contact\(selection.count == 1 ? "" : "s")?", isPresented: $showBulkDelete) {
                Button("Remove", role: .destructive) { commitBulkDelete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("\(selection.count) contact\(selection.count == 1 ? "" : "s") will be removed. Any linked ciphers are unlinked but kept — ciphers are never deleted.")
            }
            .alert("Remove All Imported Contacts?", isPresented: $showRemoveAllImported) {
                Button("Remove", role: .destructive) { commitRemoveAllImported() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("\(contactManager.importedCount) imported contact\(contactManager.importedCount == 1 ? "" : "s") will be removed; manual contacts are kept. Any linked ciphers are unlinked but kept — ciphers are never deleted.")
            }
            .alert("Import Failed", isPresented: $showImportError) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
            .onChange(of: contactManager.lastError) { _, newValue in
                showSaveError = (newValue != nil)
            }
            .alert("Couldn't Save", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text(contactManager.lastError ?? "")
            }
    }

    private var base: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᚲᛟᚾᛏᚪᚲᛏᛋ",
                subtitle: "Contacts",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )
            actionsBar
            ScrollView {
                LazyVStack(spacing: 14) {
                    if contactManager.contacts.isEmpty {
                        emptyState
                    } else {
                        ForEach(contactManager.contacts) { contactCard($0) }
                    }
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            ContactPicker { contactManager.addImported($0) }.ignoresSafeArea()
        }
        #endif
    }

    private var actionsBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { resetManual(); showAddManual = true } label: {
                    Label("Add Manually", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
                #if os(iOS)
                Button { showPicker = true } label: {
                    Label("Choose…", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
                #endif
            }
            Button { importAll() } label: {
                HStack {
                    if importing { ProgressView().scaleEffect(0.8) }
                    Label("Import All from Contacts", systemImage: "square.and.arrow.down.on.square")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .disabled(importing)
            if !contactManager.contacts.isEmpty {
                HStack(spacing: 12) {
                    Button { toggleSelecting() } label: {
                        Label(selecting ? "Done" : "Select", systemImage: selecting ? "checkmark.circle" : "checkmark.circle.badge.questionmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    Button(role: .destructive) { showRemoveAllImported = true } label: {
                        Label("Remove All Imported", systemImage: "person.crop.circle.badge.xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .disabled(contactManager.importedCount == 0)
                }
                if selecting {
                    HStack(spacing: 12) {
                        Button("Select All") { selection = Set(contactManager.contacts.map(\.id)) }
                            .buttonStyle(RuneSecondaryButtonStyle())
                        Button("Clear") { selection.removeAll() }
                            .buttonStyle(RuneSecondaryButtonStyle())
                        Button(role: .destructive) { showBulkDelete = true } label: {
                            Text("Remove Selected (\(selection.count))").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneScribButtonStyle())
                        .disabled(selection.isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.top, RuneMetrics.pad)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2").font(.system(size: 28)).foregroundColor(.runeSilver.opacity(0.5))
            Text("No contacts yet").font(.system(size: 14, weight: .semibold)).foregroundColor(.runeSilver)
            Text("Add people to organize your ciphers by.")
                .font(.system(size: 12)).foregroundColor(.runeSilver.opacity(0.7))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func contactCard(_ contact: Contact) -> some View {
        let linked = keyManager.ciphers(forContact: contact.id).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if selecting {
                    Image(systemName: selection.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selection.contains(contact.id) ? .runeBlue : .runeSilver)
                }
                Text(contact.displayName).font(.system(size: 15, weight: .bold)).foregroundColor(.white).lineLimit(1)
                Spacer()
                badge(contact.source == .imported ? "IMPORTED" : "MANUAL",
                      color: contact.source == .imported ? .runeBlue : .runeSilver)
            }
            if !contact.phones.isEmpty || !contact.emails.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(contact.phones, id: \.self) { metaLine("phone", $0) }
                    ForEach(contact.emails, id: \.self) { metaLine("envelope", $0) }
                }
            }
            Divider().overlay(Color.runeSilver.opacity(0.15))
            HStack(spacing: 10) {
                Text("\(linked) cipher\(linked == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.runeSilver)
                Spacer()
                if !selecting {
                    Button { editTarget = contact; editName = contact.displayName; showEdit = true } label: {
                        Image(systemName: "pencil").foregroundColor(.runeSilver)
                    }.buttonStyle(.plain).help("Rename")
                    Button { deleteTarget = contact; showDelete = true } label: {
                        Image(systemName: "trash").foregroundColor(.red.opacity(0.85))
                    }.buttonStyle(.plain).help("Delete")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(Color.runeParchment))
        .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
            .strokeBorder(Color.runeSilver.opacity(0.15), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggleSelection(contact.id) } }
    }

    private func metaLine(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.runeSilver)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85))
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    }

    private func deleteMessageText(for target: Contact) -> Text {
        let n = keyManager.ciphers(forContact: target.id).count
        return Text(n == 0
            ? "This contact will be removed. No ciphers are linked to it."
            : "This unlinks \(n) cipher\(n == 1 ? "" : "s") but keeps \(n == 1 ? "it" : "them"). Ciphers are never deleted.")
    }

    // MARK: actions
    private func resetManual() { newName = ""; newPhone = ""; newEmail = "" }
    private func addManual() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { resetManual(); return }
        let phones = [newPhone.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let emails = [newEmail.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        contactManager.add(Contact(displayName: name, phones: phones, emails: emails, source: .manual))
        resetManual()
    }
    private func commitEdit() {
        guard var c = editTarget else { return }
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { c.displayName = name; contactManager.update(c) }
        editTarget = nil
    }
    private func commitDelete() {
        if let target = deleteTarget { contactManager.delete(id: target.id) }
        deleteTarget = nil
    }
    private func toggleSelecting() {
        selecting.toggle()
        if !selecting { selection.removeAll() }
    }
    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func commitBulkDelete() {
        contactManager.delete(ids: selection)
        selection.removeAll()
        selecting = false
    }
    private func commitRemoveAllImported() {
        contactManager.deleteAllImported()
        selection.removeAll()
        selecting = false
    }
    private func importAll() {
        importing = true
        Task {
            do {
                let snaps = try await ContactImporter.importAll()
                contactManager.addImported(snaps)
                importing = false
            } catch {
                importError = error is ContactImportError
                    ? "Rune Scribe doesn't have permission to read your contacts. You can enable it in the Settings app."
                    : error.localizedDescription
                showImportError = true
                importing = false
            }
        }
    }
}

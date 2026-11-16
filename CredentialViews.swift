import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Copies to the clipboard on this device only (no Universal Clipboard),
/// and clears it automatically after 30 seconds.
enum Clipboard {
    static func copy(_ string: String, expiresIn seconds: TimeInterval = 30) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: string]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(seconds)
            ]
        )
    }
}

// MARK: - List

struct CredentialListView: View {
    @EnvironmentObject private var store: VaultStore
    @State private var query = ""
    @State private var showNew = false
    @State private var showSettings = false
    @State private var pendingDelete: Credential?

    private var groups: [(key: String, items: [Credential])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? store.credentials : store.credentials.filter {
            $0.organization.localizedCaseInsensitiveContains(q)
        }
        let dict = Dictionary(grouping: filtered) { Self.letter(for: $0.organization) }
        let keys = dict.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return keys.map { (key: $0, items: dict[$0] ?? []) }
    }

    private static func letter(for text: String) -> String {
        let folded = text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.credentials.isEmpty {
                    ContentUnavailableView {
                        Label("No entries", systemImage: "building.2")
                    } description: {
                        Text("Add your first organization with the + button.")
                    } actions: {
                        Button("Add") { showNew = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        if store.undecryptableCount > 0 {
                            Section {
                                Label("\(store.undecryptableCount) entries can't be read with the current key. Check Settings.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        ForEach(groups, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.items) { item in
                                    NavigationLink(value: item.id) {
                                        Text(item.organization).font(.body.weight(.medium))
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { pendingDelete = item } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("My Safe")
            .navigationDestination(for: UUID.self) { CredentialDetailView(id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showNew) { CredentialEditView(original: nil) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                Button("Delete", role: .destructive) { try? store.delete(id: item.id) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("“\(item.organization)” will also be deleted from iCloud.")
            }
        }
    }
}

// MARK: - Detail

struct CredentialDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var reveal = false
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var toast: String?
    @State private var toastTick = 0

    private var credential: Credential? { store.credentials.first { $0.id == id } }

    var body: some View {
        Group {
            if let c = credential {
                List {
                    Section("Organization") { Text(c.organization) }
                    Section("User") {
                        HStack {
                            Text(c.user)
                            Spacer()
                            copyButton(c.user, message: "User copied")
                        }
                    }
                    Section("Password") {
                        HStack {
                            Text(reveal ? c.password : String(repeating: "•", count: 10))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button { reveal.toggle() } label: {
                                Image(systemName: reveal ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(reveal ? "Hide password" : "Show password")
                            copyButton(c.password, message: "Password copied")
                        }
                    }
                    Section {
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("The clipboard is cleared after 30 seconds.")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEdit = true } }
                }
                .sheet(isPresented: $showEdit) { CredentialEditView(original: c) }
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        try? store.delete(id: id)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .navigationTitle(credential?.organization ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .sensoryFeedback(.success, trigger: toastTick)
        .task(id: toastTick) {
            guard toastTick > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            toast = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reveal = false } }
        .onDisappear { reveal = false }
    }

    private func copyButton(_ value: String, message: String) -> some View {
        Button {
            Clipboard.copy(value)
            toast = message
            toastTick += 1
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(message)
    }
}

// MARK: - Add / edit

struct CredentialEditView: View {
    let original: Credential?
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var organization: String
    @State private var user: String
    @State private var password: String
    @State private var showPassword = false
    @State private var errorText: String?

    init(original: Credential?) {
        self.original = original
        _organization = State(initialValue: original?.organization ?? "")
        _user = State(initialValue: original?.user ?? "")
        _password = State(initialValue: original?.password ?? "")
    }

    private var canSave: Bool {
        !organization.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Organization") {
                    TextField("Organization name", text: $organization)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section("User") {
                    TextField("User", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        let item = Credential(
            id: original?.id ?? UUID(),
            organization: organization.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            password: password
        )
        do {
            try store.save(item)
            dismiss()
        } catch {
            errorText = "Couldn't save. Try again."
        }
    }
}

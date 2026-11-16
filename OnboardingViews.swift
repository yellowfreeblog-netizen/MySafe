import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: AppSession
    @State private var confirmCreate = false
    @State private var showKey = false
    @State private var recoveryKey = ""
    @State private var showRestore = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64, weight: .ultraLight))
            Text("My Safe")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text("Your organization logins, encrypted and protected.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 12) {
                Button { confirmCreate = true } label: {
                    Text("Create new vault").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { showRestore = true } label: {
                    Text("Restore with recovery key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(32)
        .confirmationDialog("Create a new vault?", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("Create new vault") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If you already have a My Safe vault in iCloud, use “Restore” instead: a new vault would make your existing data unreadable.")
        }
        .fullScreenCover(isPresented: $showKey) {
            RecoveryKeyView(key: recoveryKey) {
                recoveryKey = ""
                showKey = false
                session.completeSetup()
            }
        }
        .sheet(isPresented: $showRestore) { RestoreView() }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func create() {
        do {
            recoveryKey = try store.createVault()
            showKey = true
        } catch {
            errorText = "Couldn't create the vault."
        }
    }
}

struct RecoveryKeyView: View {
    let key: String
    var onDone: () -> Void
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This is your recovery key. You'll need it to reopen your vault if you lose access to iCloud Keychain or to all your devices. It isn't stored anywhere and won't be shown again.")
                    Text(key)
                        .font(.system(.title3, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    HStack(spacing: 12) {
                        Button { Clipboard.copy(key, expiresIn: 60) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: key) {
                            Label("Save or print", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    Text("Keep it outside the vault, for example printed and stored somewhere safe. Anyone with this key and access to your iCloud can decrypt your data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("I've stored this key somewhere safe", isOn: $saved)
                    Button { onDone() } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!saved)
                }
                .padding(24)
            }
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

struct RestoreView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recovery key", text: $input, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Enter the 52-character key you received when you created the vault. Dashes are optional. iCloud access is required.")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        if busy { ProgressView() } else { Text("Restore") }
                    }
                    .disabled(input.isEmpty || busy)
                }
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func run() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await store.restore(recoveryInput: input)
            input = ""
            session.completeSetup()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

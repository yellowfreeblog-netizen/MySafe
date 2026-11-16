import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoLockSeconds") private var autoLock = 30
    @State private var iCloudStatus = "Checking…"
    @State private var confirmRotate = false
    @State private var confirmDiscard = false
    @State private var newKey = ""
    @State private var showKey = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Security") {
                    Picker("Auto-lock", selection: $autoLock) {
                        Text("Immediately").tag(0)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                    Button("Lock now") {
                        dismiss()
                        session.lock()
                    }
                    Button("Generate new recovery key") { confirmRotate = true }
                }

                Section {
                    if store.iCloudEnabled {
                        LabeledContent("Status", value: iCloudStatus)
                        Button("Sync now") { Task { await store.cloud?.syncNow() } }
                    } else {
                        Text("Turned off in this build of the app.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Only encrypted data is stored in iCloud. Your passwords never leave this device in plain text.")
                }

                if store.undecryptableCount > 0 {
                    Section {
                        Button("Delete \(store.undecryptableCount) unreadable entries", role: .destructive) {
                            confirmDiscard = true
                        }
                    } footer: {
                        Text("These entries were encrypted with a different key than this vault's.")
                    }
                }

                Section("About") {
                    LabeledContent("Encryption", value: "AES-256-GCM")
                    LabeledContent("Keys", value: "Apple Keychain")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { iCloudStatus = await store.cloud?.accountStatusText() ?? "" }
            .confirmationDialog("Generate a new recovery key?", isPresented: $confirmRotate,
                                titleVisibility: .visible) {
                Button("Generate new key", role: .destructive) { rotate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your previous recovery key will stop working.")
            }
            .confirmationDialog("Delete unreadable entries?", isPresented: $confirmDiscard,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.discardUndecryptable() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showKey) {
                RecoveryKeyView(key: newKey) {
                    newKey = ""
                    showKey = false
                }
            }
            .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func rotate() {
        do {
            newKey = try store.rotateRecoveryKey()
            showKey = true
        } catch {
            errorText = "Couldn't generate a new key."
        }
    }
}

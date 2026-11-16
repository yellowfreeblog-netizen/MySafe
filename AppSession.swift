import LocalAuthentication
import SwiftUI

/// Stato dell'app: configurazione iniziale, bloccata, sbloccata.
/// Gestisce Face ID e il blocco automatico.
@MainActor
final class AppSession: ObservableObject {
    enum Phase { case needsSetup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published var message: String?
    /// true per un istante dopo il riconoscimento: il lucchetto si apre prima di mostrare l'elenco.
    @Published private(set) var isOpening = false

    private let store: VaultStore
    private var backgroundedAt: Date?
    private var authenticating = false

    init(store: VaultStore) {
        self.store = store
        self.phase = store.hasKey ? .locked : .needsSetup
    }

    /// Secondi in background dopo i quali l'app si blocca (0 = subito).
    var autoLockSeconds: Int {
        UserDefaults.standard.object(forKey: "autoLockSeconds") as? Int ?? 30
    }

    func completeSetup() {
        message = nil
        phase = .unlocked
    }

    func lock() {
        guard phase == .unlocked else { return }
        store.lock()
        phase = .locked
    }

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            guard phase == .unlocked else { return }
            backgroundedAt = Date()
            if autoLockSeconds == 0 { lock() }
        case .active:
            if phase == .unlocked, let since = backgroundedAt,
               Date().timeIntervalSince(since) >= Double(autoLockSeconds) {
                lock()
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// Face ID, con codice del dispositivo come alternativa.
    /// Se sul dispositivo non c'è un codice, l'archivio resta bloccato.
    func authenticate() async {
        guard phase == .locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set a passcode on this iPhone to use My Safe."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock My Safe to access your credentials"
            )
            guard ok else { return }
            try store.unlock()
            message = nil
            isOpening = true
            let pause: Duration = UIAccessibility.isReduceMotionEnabled ? .zero : .milliseconds(650)
            try? await Task.sleep(for: pause)
            phase = .unlocked
            isOpening = false
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel: message = nil
            default: message = "Authentication failed. Try again."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

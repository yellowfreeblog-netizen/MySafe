import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch session.phase {
            case .needsSetup: OnboardingView()
            case .locked: LockView()
            case .unlocked: CredentialListView()
            }
            // Covers the content in the app switcher.
            if scenePhase != .active && session.phase == .unlocked {
                PrivacyCover()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.phase)
        .onChange(of: scenePhase) { _, newValue in
            session.handle(scenePhase: newValue)
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

struct LockView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: session.isOpening ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 64, weight: .ultraLight))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: session.isOpening)
                .foregroundStyle(session.isOpening ? Color.green : Color.primary)
                .scaleEffect(session.isOpening ? 1.12 : 1)
                .animation(.spring(duration: 0.4), value: session.isOpening)
                .sensoryFeedback(.success, trigger: session.isOpening) { _, new in new }
            Text("My Safe")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text(session.isOpening ? "Unlocked" : "Locked")
                .foregroundStyle(.secondary)
            if let message = session.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                Task { await session.authenticate() }
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            if scenePhase == .active { await session.authenticate() }
        }
    }
}

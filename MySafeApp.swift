import SwiftUI

@main
struct MySafeApp: App {
    @StateObject private var store: VaultStore
    @StateObject private var session: AppSession

    init() {
        let store = VaultStore()
        _store = StateObject(wrappedValue: store)
        _session = StateObject(wrappedValue: AppSession(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(session)
        }
    }
}

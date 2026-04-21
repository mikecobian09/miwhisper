import SwiftUI

@main
struct MiWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520)
                .padding(20)
        }
    }
}

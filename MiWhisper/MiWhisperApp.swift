import SwiftUI

@main
struct MiWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.menuBarSymbolName)
                if appState.isRecording {
                    Text("REC")
                        .font(.caption2)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520)
                .padding(20)
        }
    }
}

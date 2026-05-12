import SwiftUI
import UIKit

@main
struct MiWhisperCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speechController: NativeSpeechController
    @StateObject private var carModeRunWatcher: CarModeRunWatcher
    @StateObject private var carCommandListener: NativeCarCommandListener
    @StateObject private var idleTimerController: NativeIdleTimerController

    init() {
        let speechController = NativeSpeechController()
        _speechController = StateObject(wrappedValue: speechController)
        _carModeRunWatcher = StateObject(wrappedValue: CarModeRunWatcher(speechController: speechController))
        _carCommandListener = StateObject(wrappedValue: NativeCarCommandListener())
        _idleTimerController = StateObject(wrappedValue: NativeIdleTimerController())
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView(
                speechController: speechController,
                carModeRunWatcher: carModeRunWatcher,
                carCommandListener: carCommandListener,
                idleTimerController: idleTimerController
            )
            .onChange(of: scenePhase) { newPhase in
                idleTimerController.handleScenePhase(newPhase)
            }
        }
    }
}

@MainActor
final class NativeIdleTimerController: ObservableObject {
    private var keepScreenAwakeForCarMode = false

    func setCarModeArmed(_ armed: Bool) {
        keepScreenAwakeForCarMode = armed
        apply()
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            apply()
        case .inactive, .background:
            UIApplication.shared.isIdleTimerDisabled = false
        @unknown default:
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func apply() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeForCarMode
    }
}

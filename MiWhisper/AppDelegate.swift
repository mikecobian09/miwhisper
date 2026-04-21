import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState.shared
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        appState.requestInitialPermissions()
        HotkeyMonitor.shared.start()
        CompanionBridge.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompanionBridge.shared.stop()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(appState)
        )
        self.popover = popover

        appState.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButton() }
            .store(in: &cancellables)

        appState.$isTranscribing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusButton() }
            .store(in: &cancellables)

        updateStatusButton()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        button.image = NSImage(
            systemSymbolName: appState.menuBarSymbolName,
            accessibilityDescription: "MiWhisper"
        )
        button.title = appState.isRecording ? "REC" : ""
        button.imagePosition = appState.isRecording ? .imageLeft : .imageOnly
    }
}

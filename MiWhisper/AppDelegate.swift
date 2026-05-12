import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState.shared
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CompanionWatchdog.shared.markAppStarted()
        configureStatusItem()
        appState.requestInitialPermissions()
        appState.syncCompanionWatchdogState()
        HotkeyMonitor.shared.start()
        CompanionBridge.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompanionWatchdog.shared.markIntentionalQuit()
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

final class CompanionWatchdog {
    static let shared = CompanionWatchdog()

    private let label = "com.miwhisper.companion-watchdog"
    private let fileManager = FileManager.default

    private init() {}

    var isInstalled: Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    func install() throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try watchdogScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try launchAgentPlist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        try? runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        try runLaunchctl(["bootstrap", launchDomain, launchAgentURL.path])
        try runLaunchctl(["enable", "\(launchDomain)/\(label)"])
        try runLaunchctl(["kickstart", "-k", "\(launchDomain)/\(label)"])
    }

    func uninstall() {
        try? runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        try? fileManager.removeItem(at: launchAgentURL)
        try? fileManager.removeItem(at: scriptURL)
        try? fileManager.removeItem(at: intentionalQuitURL)
    }

    func markAppStarted() {
        try? fileManager.removeItem(at: intentionalQuitURL)
    }

    func markIntentionalQuit() {
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let payload = ISO8601DateFormatter().string(from: Date())
        try? payload.write(to: intentionalQuitURL, atomically: true, encoding: .utf8)
    }

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MiWhisper/Watchdog", isDirectory: true)
    }

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var scriptURL: URL {
        supportDirectory.appendingPathComponent("miwhisper-watchdog.sh")
    }

    private var intentionalQuitURL: URL {
        supportDirectory.appendingPathComponent("intentional-quit")
    }

    private var launchDomain: String {
        "gui/\(getuid())"
    }

    private var appPath: String {
        Bundle.main.bundlePath
    }

    private var watchdogScript: String {
        """
        #!/bin/bash
        set -u

        APP_PATH=\(shellQuoted(appPath))
        INTENTIONAL_QUIT=\(shellQuoted(intentionalQuitURL.path))

        if /usr/bin/pgrep -x MiWhisper >/dev/null 2>&1; then
          exit 0
        fi

        if [ -f "$INTENTIONAL_QUIT" ]; then
          exit 0
        fi

        if [ -d "$APP_PATH" ]; then
          /usr/bin/open -g "$APP_PATH"
        fi
        """
    }

    private var launchAgentPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>\(xmlEscaped(scriptURL.path))</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StartInterval</key>
          <integer>20</integer>
          <key>StandardOutPath</key>
          <string>\(xmlEscaped(supportDirectory.appendingPathComponent("watchdog.out.log").path))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscaped(supportDirectory.appendingPathComponent("watchdog.err.log").path))</string>
        </dict>
        </plist>
        """
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[MiWhisper][Watchdog] launchctl failed args=%@ error=%@", arguments.joined(separator: " "), error.localizedDescription)
            throw error
        }

        guard process.terminationStatus == 0 else {
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)
                ?? String(data: outputData, encoding: .utf8)
                ?? "launchctl exited with status \(process.terminationStatus)"
            throw NSError(
                domain: "MiWhisper.CompanionWatchdog",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

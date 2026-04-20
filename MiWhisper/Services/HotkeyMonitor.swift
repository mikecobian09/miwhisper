import AppKit
import ApplicationServices
import Foundation

enum HotkeyIntent: String {
    case dictation
    case codexPrompt

    var title: String {
        switch self {
        case .dictation:
            return "Dictation"
        case .codexPrompt:
            return "Codex"
        }
    }
}

final class HotkeyMonitor {
    static let shared = HotkeyMonitor()
    static let didPressHotkeyNotification = Notification.Name("MiWhisperHotkeyPressed")
    static let didReleaseHotkeyNotification = Notification.Name("MiWhisperHotkeyReleased")
    static let didChangeAvailabilityNotification = Notification.Name("MiWhisperHotkeyAvailabilityChanged")
    static let intentUserInfoKey = "intent"

    private static let fnKeyCode: Int64 = 63
    private static let activationDelay: TimeInterval = 0.12

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var pendingActivationTimer: Timer?
    private var isFnDown = false
    private var isCommandDown = false
    private var hasEventTap = false
    private var activeIntent: HotkeyIntent?
    private(set) var isAvailable = false

    func start() {
        registerNSEventMonitors()
        attemptStart()
        scheduleRetryIfNeeded()
    }

    func refresh() {
        registerNSEventMonitors()
        attemptStart()
        scheduleRetryIfNeeded()
    }

    func intent(from notification: Notification) -> HotkeyIntent? {
        guard
            let rawValue = notification.userInfo?[Self.intentUserInfoKey] as? String,
            let intent = HotkeyIntent(rawValue: rawValue)
        else {
            return nil
        }

        return intent
    }

    private func attemptStart() {
        guard eventTap == nil else {
            hasEventTap = true
            updateAvailability()
            return
        }

        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                monitor.hasEventTap = true
                monitor.updateAvailability()
                return Unmanaged.passUnretained(event)
            }

            if type == .flagsChanged {
                monitor.handleCGFlagsChanged(event)
            }

            return Unmanaged.passUnretained(event)
        }

        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let tapsToTry: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]

        var createdTap: CFMachPort?
        for tapLocation in tapsToTry {
            createdTap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: ref
            )

            if createdTap != nil {
                break
            }
        }

        guard let tap = createdTap else {
            hasEventTap = false
            updateAvailability()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        retryTimer?.invalidate()
        retryTimer = nil
        hasEventTap = true
        updateAvailability()
    }

    private func registerNSEventMonitors() {
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        }

        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        }
    }

    private func scheduleRetryIfNeeded() {
        guard eventTap == nil else { return }
        guard retryTimer == nil else { return }

        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            self.attemptStart()
            if self.eventTap != nil {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    private func updateAvailability() {
        let available = hasEventTap
        guard isAvailable != available else { return }
        isAvailable = available
        NotificationCenter.default.post(
            name: Self.didChangeAvailabilityNotification,
            object: nil,
            userInfo: ["isAvailable": available]
        )
    }

    private func handleCGFlagsChanged(_ event: CGEvent) {
        let fnDown = event.flags.contains(.maskSecondaryFn)
        let commandDown = event.flags.contains(.maskCommand)
        updateState(commandDown: commandDown, fnDown: fnDown)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function) ||
            event.cgEvent?.flags.contains(.maskSecondaryFn) == true
        let commandDown = event.modifierFlags.contains(.command) ||
            event.cgEvent?.flags.contains(.maskCommand) == true

        let keyCode = Int64(event.keyCode)
        if keyCode == Self.fnKeyCode || event.type == .flagsChanged {
            updateState(commandDown: commandDown, fnDown: fnDown)
        }
    }

    private func updateState(commandDown: Bool, fnDown: Bool) {
        isCommandDown = commandDown

        guard fnDown != isFnDown else { return }
        isFnDown = fnDown

        if fnDown {
            scheduleActivation()
        } else {
            cancelPendingActivation()
            releaseActiveIntentIfNeeded()
        }
    }

    private func scheduleActivation() {
        cancelPendingActivation()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.activationDelay, repeats: false) { [weak self] _ in
            self?.activateCurrentChord()
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingActivationTimer = timer
    }

    private func cancelPendingActivation() {
        pendingActivationTimer?.invalidate()
        pendingActivationTimer = nil
    }

    private func activateCurrentChord() {
        pendingActivationTimer = nil
        guard isFnDown, activeIntent == nil else { return }

        let intent: HotkeyIntent = isCommandDown ? .codexPrompt : .dictation
        activeIntent = intent

        NotificationCenter.default.post(
            name: Self.didPressHotkeyNotification,
            object: nil,
            userInfo: [Self.intentUserInfoKey: intent.rawValue]
        )
    }

    private func releaseActiveIntentIfNeeded() {
        guard let activeIntent else { return }

        NotificationCenter.default.post(
            name: Self.didReleaseHotkeyNotification,
            object: nil,
            userInfo: [Self.intentUserInfoKey: activeIntent.rawValue]
        )

        self.activeIntent = nil
    }
}

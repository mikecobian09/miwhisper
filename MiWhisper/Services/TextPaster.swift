import AppKit
import ApplicationServices
import Foundation

struct TextPaster {
    struct ClipboardSnapshot {
        let items: [ClipboardSnapshotItem]
    }

    struct ClipboardSnapshotItem {
        let dataByType: [(NSPasteboard.PasteboardType, Data)]
    }

    private static let commandKeyCode: CGKeyCode = 0x37
    private static let vKeyCode: CGKeyCode = 0x09

    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func captureClipboardSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item in
            ClipboardSnapshotItem(
                dataByType: item.types.compactMap { type in
                    guard let data = item.data(forType: type) else {
                        return nil
                    }
                    return (type, data)
                }
            )
        } ?? []

        return ClipboardSnapshot(items: items)
    }

    func restoreClipboardSnapshot(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        let pasteboardItems = snapshot.items.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(pasteboardItems)
    }

    func pasteClipboardContents() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw PasteError.accessibilityPermissionRequired
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: Self.commandKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: Self.commandKeyCode, keyDown: false) else {
            throw PasteError.eventCreationFailed
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }

    func paste(_ text: String) throws {
        copyToClipboard(text)
        try pasteClipboardContents()
    }
}

enum PasteError: LocalizedError {
    case accessibilityPermissionRequired
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to paste into the focused app."
        case .eventCreationFailed:
            return "Could not synthesize the paste keyboard event."
        }
    }
}

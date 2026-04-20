import AppKit
import ApplicationServices
import Foundation

struct AccessibilityTextInsertion {
    struct InsertionContext {
        let precedingCharacter: Character?
        let hasSelection: Bool
    }

    struct FocusedTarget {
        let application: NSRunningApplication
        let focusedElement: AXUIElement?
        let prefersSimulatedPaste: Bool
    }

    func captureFocusedTarget(excluding bundleIdentifier: String?) -> FocusedTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if application.bundleIdentifier == bundleIdentifier {
            return nil
        }

        let focusedElement = captureFocusedElement(for: application)
        return FocusedTarget(
            application: application,
            focusedElement: focusedElement,
            prefersSimulatedPaste: shouldPreferSimulatedPaste(for: application, focusedElement: focusedElement)
        )
    }

    func insert(_ text: String, into target: FocusedTarget) -> Bool {
        guard !text.isEmpty else { return false }
        guard AXIsProcessTrusted() else { return false }
        guard !target.prefersSimulatedPaste else { return false }
        guard let element = target.focusedElement else { return false }

        guard let currentValue = stringValue(of: element) else { return false }
        let replacementRange = selectedRange(in: element, currentValue: currentValue)
        let updatedValue = replaceText(in: currentValue, at: replacementRange, with: text)

        guard setStringValue(updatedValue, on: element) else { return false }

        let newInsertionPoint = replacementRange.location + (text as NSString).length
        setSelectedRange(location: newInsertionPoint, length: 0, on: element)
        return true
    }

    func refreshFocusedTarget(from target: FocusedTarget) -> FocusedTarget {
        let focusedElement = captureFocusedElement(for: target.application)
        return FocusedTarget(
            application: target.application,
            focusedElement: focusedElement,
            prefersSimulatedPaste: shouldPreferSimulatedPaste(
                for: target.application,
                focusedElement: focusedElement
            )
        )
    }

    func insertionContext(for target: FocusedTarget) -> InsertionContext? {
        guard let element = target.focusedElement else {
            return nil
        }

        guard let currentValue = stringValue(of: element) else {
            return nil
        }

        let replacementRange = selectedRange(in: element, currentValue: currentValue)
        let stringValue = currentValue as NSString
        let precedingCharacter: Character?

        if replacementRange.location > 0 {
            let previousCharacterRange = NSRange(location: replacementRange.location - 1, length: 1)
            precedingCharacter = stringValue.substring(with: previousCharacterRange).first
        } else {
            precedingCharacter = nil
        }

        return InsertionContext(
            precedingCharacter: precedingCharacter,
            hasSelection: replacementRange.length > 0
        )
    }

    func precedingTextSnippet(for target: FocusedTarget, maxLength: Int = 120) -> String? {
        guard let element = target.focusedElement else {
            return nil
        }

        guard let currentValue = stringValue(of: element) else {
            return nil
        }

        let replacementRange = selectedRange(in: element, currentValue: currentValue)
        guard replacementRange.location > 0 else {
            return nil
        }

        let stringValue = currentValue as NSString
        let snippetLength = min(maxLength, replacementRange.location)
        let snippetRange = NSRange(location: replacementRange.location - snippetLength, length: snippetLength)
        return stringValue.substring(with: snippetRange)
    }

    private func captureFocusedElement(for application: NSRunningApplication) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard
            result == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)

        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)
        guard pid == application.processIdentifier else {
            return nil
        }

        return focusedElement
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func selectedRange(in element: AXUIElement, currentValue: String) -> NSRange {
        var rawRange: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawRange
        )

        guard
            result == .success,
            let rawRange,
            CFGetTypeID(rawRange) == AXValueGetTypeID()
        else {
            return NSRange(location: (currentValue as NSString).length, length: 0)
        }

        let axValue = unsafeBitCast(rawRange, to: AXValue.self)

        var selection = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &selection) else {
            return NSRange(location: (currentValue as NSString).length, length: 0)
        }

        let stringLength = (currentValue as NSString).length
        let location = max(0, min(selection.location, stringLength))
        let length = max(0, min(selection.length, stringLength - location))
        return NSRange(location: location, length: length)
    }

    private func replaceText(in currentValue: String, at range: NSRange, with text: String) -> String {
        let mutable = NSMutableString(string: currentValue)
        mutable.replaceCharacters(in: range, with: text)
        return mutable as String
    }

    private func setStringValue(_ value: String, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )

        guard result == .success, isSettable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    private func setSelectedRange(location: Int, length: Int, on element: AXUIElement) {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &isSettable
        )

        guard result == .success, isSettable.boolValue else { return }

        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private func shouldPreferSimulatedPaste(for application: NSRunningApplication, focusedElement: AXUIElement?) -> Bool {
        let browserBundleIdentifiers: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi"
        ]

        if let bundleIdentifier = application.bundleIdentifier, browserBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        guard let focusedElement else {
            return false
        }

        guard let role = attributeString(kAXRoleAttribute as CFString, on: focusedElement) else {
            return false
        }

        return role == "AXWebArea"
    }

    private func attributeString(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}

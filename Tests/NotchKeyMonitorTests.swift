// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The island's production event monitor runs against plain doubles. No
/// window is shown, no native monitor is installed and no key is posted.
enum NotchKeyMonitorTests {
    struct NSEvent {
        struct ModifierFlags: OptionSet {
            let rawValue: Int
            static let command = Self(rawValue: 1)
            static let control = Self(rawValue: 2)
            static let option = Self(rawValue: 4)
            static let shift = Self(rawValue: 8)
        }
        enum EventType: UInt { case leftMouseDown = 1, rightMouseDown = 3, keyDown = 10, otherMouseDown = 25 }
        struct EventTypeMask: OptionSet {
            let rawValue: UInt64
            static let leftMouseDown = Self(rawValue: 1 << 1)
            static let rightMouseDown = Self(rawValue: 1 << 3)
            static let keyDown = Self(rawValue: 1 << 10)
            static let otherMouseDown = Self(rawValue: 1 << 25)
        }
        static let mouseLocation = CGPoint.zero
        static var handler: ((Self) -> Self?)?
        var type = EventType.keyDown
        let window: Panel?
        let keyCode: UInt16
        var modifierFlags: ModifierFlags = []
        var charactersIgnoringModifiers: String?
        static func addGlobalMonitorForEvents(matching: EventTypeMask, handler: @escaping (Self) -> Void) -> Any? { nil }
        static func addLocalMonitorForEvents(matching: EventTypeMask, handler: @escaping (Self) -> Self?) -> Any? {
            self.handler = handler
            return 1
        }
    }
    final class Panel { var firstResponder: AnyObject? }
    final class NSTextView {
        let isFieldEditor: Bool
        let delegate: AnyObject? = nil
        var composing = false
        init(isFieldEditor: Bool) { self.isFieldEditor = isFieldEditor }
        func hasMarkedText() -> Bool { composing }
    }
    final class Host {
        var underPointer = false
        func contains(_ point: CGPoint) -> Bool { underPointer }
    }
    final class Mirror {
        final class Model { var shown = true }
        let model = Model(), host = Host()
    }
    final class AppDelegate { func isOverStatusItem(_ point: CGPoint) -> Bool { false } }
    struct Application { let delegate: AnyObject? = nil }
    static let NSApp = Application()
    enum AssistiveKeyboard { static func ownsCocoaPoint(_ point: CGPoint) -> Bool { false } }
    /// What each key did: the gallery toggled, Settings opened or the island stepped back.
    static var actions: [String] = []

    class State {
        var mirrors: [Int: Mirror] = [:]
        var eventMonitors: [Any] = []
        var clickedSinceOpening = false
        var showsKeyboardFocus = false
        var keepsSurfaceOnClick = false
        let panel: Panel? = Panel()
        var windowHost: Host? = Host()
        var modules = NotchModule.allCases
        var selected = NotchModule.controls
        var showingSections = false
        func collapse() { NotchKeyMonitorTests.actions.append("collapse") }
        func openSettings() { NotchKeyMonitorTests.actions.append("settings") }
        func stepBack() { NotchKeyMonitorTests.actions.append("stepBack") }
        func toggleSections() { NotchKeyMonitorTests.actions.append("sections") }
        func select(_ module: NotchModule) { selected = module }
        func handleSectionKey(_ event: NSEvent) -> Bool { false }
        func handleClipboardPasteKey(_ event: NSEvent) -> Bool { false }
        func ownsWindow(_ window: Panel?) -> Bool { window === panel }
    }

    static func run(_ suite: TestSuite) {
        defer {
            NSEvent.handler = nil
            actions = []
        }
        let service = Service()
        service.installEventMonitors()
        let click = NSEvent(type: .leftMouseDown, window: service.panel, keyCode: 0)
        _ = NSEvent.handler?(click)
        _ = NSEvent.handler?(NSEvent(window: Panel(), keyCode: 48))
        suite.expect(!service.showsKeyboardFocus,
                     "pointer input and keys in another window do not expose the island's automatic focus")
        let mirror = Mirror()
        mirror.host.underPointer = true
        service.mirrors[1] = mirror
        let mirrorClick = NSEvent(type: .leftMouseDown, window: Panel(), keyCode: 0)
        actions = []
        _ = NSEvent.handler?(mirrorClick)
        suite.expect(actions.isEmpty, "the local click monitor keeps the island on a visible island copy")
        mirror.model.shown = false
        _ = NSEvent.handler?(mirrorClick)
        suite.expect(actions == ["collapse"], "the local click monitor collapses the island at a hidden copy's old position")
        service.mirrors = [:]
        let tab = NSEvent(window: service.panel, keyCode: 48)
        suite.expect(NSEvent.handler?(tab) != nil && service.showsKeyboardFocus,
                     "Tab restores visible focus and still reaches the controls for navigation")
        _ = NSEvent.handler?(click)
        suite.expect(service.showsKeyboardFocus,
                     "pointer input after keyboard navigation keeps the focused control visible")
        service.showsKeyboardFocus = false
        let backTab = NSEvent(window: service.panel, keyCode: 48, modifierFlags: .shift)
        suite.expect(NSEvent.handler?(backTab) != nil && service.showsKeyboardFocus,
                     "reverse keyboard navigation restores visible focus without consuming Shift-Tab")
        let escape = NSEvent(window: service.panel, keyCode: 53)
        service.selected = .controls
        service.showingSections = false
        service.panel?.firstResponder = nil
        actions = []
        suite.expect(NSEvent.handler?(escape) == nil && actions == ["stepBack"],
                     "Escape steps back through the island")
        actions = []
        let commandK = NSEvent(window: service.panel, keyCode: 40, modifierFlags: .command, charactersIgnoringModifiers: "k")
        suite.expect(NSEvent.handler?(commandK) == nil && actions == ["sections"],
                     "Command-K opens the sections gallery")
        // With no settings button in the island, Command-Comma opens its page.
        actions = []
        let commandComma = NSEvent(window: service.panel, keyCode: 43, modifierFlags: .command,
                                   charactersIgnoringModifiers: ",")
        suite.expect(NSEvent.handler?(commandComma) == nil && actions == ["settings"],
                     "Command-Comma opens the island's settings from inside it")
        // Keep open, Settings and Collapse have no button in the row; besides
        // the secondary-click menu, VoiceOver reaches them as named actions.
        let islandSource = ((try? String(contentsOfFile: "Sources/Brim/UI/Notch/NotchView.swift",
                                         encoding: .utf8)) ?? "")
            .filter { !$0.isWhitespace }
        suite.expect([".accessibilityAction(named:service.pinned?text.unpin:text.pin){service.pinned.toggle()}",
                      ".accessibilityAction(named:l10n.s.menuSettings){service.openSettings()}",
                      ".accessibilityAction(named:text.collapse){service.collapse()}"]
                        .allSatisfy(islandSource.contains),
                     "the open island names Keep open, Settings and Collapse as accessibility actions")
    }
}

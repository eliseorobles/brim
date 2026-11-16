// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Handles side buttons before the hosted SwiftUI controls can consume them.
class SettingsWindow: NSWindow {
    var router = SettingsRouter.shared
    private var navigationButtons: Set<Int> = []

    /// CoreGraphics numbers the first two side buttons after left, right and
    /// middle as 3 and 4. These are what standard Back and Forward buttons on
    /// multi-button mice expose when another driver has not remapped them.
    private static let backButtonNumber = 3
    private static let forwardButtonNumber = 4

    static func navigationMenu(language: AppLanguage) -> NSMenu {
        let strings = SettingsNavigationStrings.localized(language)
        let menu = NSMenu(title: strings.go)
        // The commands other apps declare for Back and Forward.
        menu.addItem(NSMenuItem(title: strings.back, action: #selector(goBack(_:)), keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: strings.forward, action: #selector(goForward(_:)), keyEquivalent: "]"))
        return menu
    }

    private var canNavigate: Bool {
        isKeyWindow && attachedSheet == nil && NSApp.modalWindow == nil
    }

    private func isPageVisible(_ page: SettingsPage) -> Bool {
        FeatureVisibilitySupport.isPageVisible(page, isAvailable: { $0.isAvailable })
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return canNavigate && router.canGoBack(isPageVisible: isPageVisible)
        case #selector(goForward(_:)): return canNavigate && router.canGoForward(isPageVisible: isPageVisible)
        default: return super.validateMenuItem(menuItem)
        }
    }

    @objc func goBack(_ sender: Any?) {
        guard canNavigate else { return }
        router.goBack(isPageVisible: isPageVisible)
    }

    @objc func goForward(_ sender: Any?) {
        guard canNavigate else { return }
        router.goForward(isPageVisible: isPageVisible)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown:
            let button = event.buttonNumber
            guard canNavigate, button == Self.backButtonNumber || button == Self.forwardButtonNumber else {
                super.sendEvent(event)
                return
            }
            navigationButtons.insert(button)
            if button == Self.backButtonNumber { goBack(nil) } else { goForward(nil) }
        case .otherMouseUp:
            // Keep the entire gesture together, even if navigation changes focus.
            if navigationButtons.remove(event.buttonNumber) != nil { return }
            super.sendEvent(event)
        case .otherMouseDragged:
            if navigationButtons.contains(event.buttonNumber) { return }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

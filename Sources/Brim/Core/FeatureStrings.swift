// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum FeatureStrings {
    static func settingsCategories(_ language: AppLanguage) -> SettingsCategoryStrings {
        switch language {
        case .enUS: return .enUS
        }
    }

    static func clipboard(_ language: AppLanguage) -> ClipboardFeatureStrings {
        switch language {
        case .enUS: return .enUS
        }
    }

    static func monitorAlerts(_ language: AppLanguage) -> MonitorAlertFeatureStrings {
        switch language {
        case .enUS: return .enUS
        }
    }

    static func whatsAppDownloads(_ language: AppLanguage) -> WhatsAppDownloadStrings {
        WhatsAppDownloadStrings.localized(language)
    }
}

struct SettingsCategoryStrings {
    let essentials: String
    let files: String
    let utilities: String
    let app: String
    let appManagement: String

    static let enUS = SettingsCategoryStrings(
        essentials: "Essentials",
        files: "Files",
        utilities: "Utilities",
        app: "App",
        appManagement: "App management"
    )
}

struct ClipboardFeatureStrings {
    let title: String
    let historyTitle: String
    let enable: String
    let caption: String
    let localNote: String
    let skipSensitive: String
    let skipSensitiveCaption: String
    let limit: String
    let limitUnlimited: String
    let showInPanel: String
    let shortcut: String
    let shortcutCaption: String
    let clickRowShortcut: String
    let pinned: String
    let recent: String
    let pin: String
    let unpin: String
    let clearRecent: String
    let empty: String
    let disabled: String
    let search: String
    let copy: String
    let copied: String
    let delete: String
    let selectMultiple: String
    let unselectMultiple: String
    let pasteSelectedFormat: String
    let copySelectedFormat: String
    let clearSelection: String
    let moveUp: String
    let moveDown: String
    let noResults: String
    let active: String
    let includeImagesFiles: String
    let includeImagesFilesCaption: String
    let imageEntryLabel: String
    let fileCountFormat: String
    let previewLabel: String
    let edit: String
    let cancel: String
    let save: String
    let autoClearEnable: String
    let autoClearSecondsSuffix: String
    let autoClearOnSleep: String
    let autoClearOnDisplaySleep: String
    let autoClearOnScreenLock: String
    let autoClearCaption: String
    let deleteSelectedFormat: String
    let menuBarPreview: String
    let menuBarPreviewCaption: String
    let menuBarPreviewLength: String
    let menuBarPreviewLengthSuffix: String
    let clearRecentConfirmFormat: String
    let clearRecentConfirmMessage: String
    let historyLayout: String
    let historyLayoutCards: String
    let historyLayoutList: String
    let showSourceAppIconsInList: String

    static let enUS = ClipboardFeatureStrings(
        title: "Clipboard",
        historyTitle: "Clipboard history",
        enable: "Save clipboard history",
        caption: "Stores copied text so you can reuse it later. Everything stays local and can be cleared anytime.",
        localNote: "Everything stays on this Mac. Very large items are ignored.",
        skipSensitive: "Skip text that looks sensitive",
        skipSensitiveCaption: "May skip ordinary text that resembles passwords or tokens. Content marked as confidential by its source app is always excluded.",
        limit: "Limit",
        limitUnlimited: "Unlimited",
        showInPanel: "Show in panel",
        shortcut: "History shortcut",
        shortcutCaption: "Opens a quick window with search, pinned items and ⌘1 to ⌘9 shortcuts for pasting into the previous app.",
        clickRowShortcut: "Click row",
        pinned: "Pinned",
        recent: "Recent",
        pin: "Pin",
        unpin: "Unpin",
        clearRecent: "Clear unpinned",
        empty: "No saved text",
        disabled: "Enable history to start saving copied text.",
        search: "Search copied text",
        copy: "Copy",
        copied: "Copied",
        delete: "Delete item",
        selectMultiple: "Add to pile",
        unselectMultiple: "Remove from pile",
        pasteSelectedFormat: "Paste %d",
        copySelectedFormat: "Copy %d",
        clearSelection: "Clear selection",
        moveUp: "Move up",
        moveDown: "Move down",
        noResults: "No results",
        active: "Saving new text",
        includeImagesFiles: "Also save copied images and files",
        includeImagesFilesCaption: "Images join the history and files are remembered as links to their location. Pin and paste them like any text item.",
        imageEntryLabel: "Image",
        fileCountFormat: "%d files",
        previewLabel: "Preview",
        edit: "Edit",
        cancel: "Cancel",
        save: "Save",
        autoClearEnable: "Auto clear clipboard with a delay of",
        autoClearSecondsSuffix: "seconds",
        autoClearOnSleep: "Clear clipboard on computer sleep",
        autoClearOnDisplaySleep: "Clear clipboard on display sleep",
        autoClearOnScreenLock: "Clear clipboard on screen lock",
        autoClearCaption: "Clears the system clipboard only. Items already saved stay in the history.",
        deleteSelectedFormat: "Delete %d",
        menuBarPreview: "Show latest copy in the menu bar",
        menuBarPreviewCaption: "Shows a shortened preview of your last copy next to the icon. Click it to open the history.",
        menuBarPreviewLength: "Preview length",
        menuBarPreviewLengthSuffix: "characters",
        clearRecentConfirmFormat: "Clear unpinned (%d)?",
        clearRecentConfirmMessage: "Pinned items stay, and so does anything copied after this. This can’t be undone.",
        historyLayout: "History layout",
        historyLayoutCards: "Cards",
        historyLayoutList: "List",
        showSourceAppIconsInList: "Show source app icons in list view"
    )
}

struct MonitorAlertFeatureStrings {
    let section: String
    let caption: String
    let notificationsDenied: String
    let cpu: String
    let cpuTemperature: String
    let disk: String
    let battery: String
    let cpuThreshold: String
    let cpuTemperatureThreshold: String
    let diskThreshold: String
    let batteryThreshold: String
    let cooldown: String
    let cooldown2: String
    let cooldown5: String
    let cooldown15: String
    let cooldown30: String
    let cooldown60: String
    let cpuTitle: String
    let cpuBodyFormat: String
    let cpuTemperatureTitle: String
    let cpuTemperatureBodyFormat: String
    let diskTitle: String
    let diskBodyFormat: String
    let batteryTitle: String
    let batteryBodyFormat: String
    let batteryTemperature: String
    let batteryTemperatureThreshold: String
    let batteryTemperatureTitle: String
    let batteryTemperatureBodyFormat: String

    static let enUS = MonitorAlertFeatureStrings(
        section: "Alerts",
        caption: "Alerts fire when their selected limits are reached. CPU use and temperature alerts ignore spikes shorter than about 12 seconds. The repeat setting only limits repeats of the same alert.",
        notificationsDenied: "Notifications for Brim are off in System Settings, so alerts cannot appear.",
        cpu: "High CPU",
        cpuTemperature: "High CPU temperature",
        disk: "Low disk space",
        battery: "Low battery",
        cpuThreshold: "CPU above",
        cpuTemperatureThreshold: "Temperature above",
        diskThreshold: "Free space below",
        batteryThreshold: "Battery below",
        cooldown: "Repeat the same alert after",
        cooldown2: "2 minutes",
        cooldown5: "5 minutes",
        cooldown15: "15 minutes",
        cooldown30: "30 minutes",
        cooldown60: "1 hour",
        cpuTitle: "High CPU",
        cpuBodyFormat: "CPU stayed above %d%% for a few seconds.",
        cpuTemperatureTitle: "Hot CPU",
        cpuTemperatureBodyFormat: "CPU reached %@.",
        diskTitle: "Low disk space",
        diskBodyFormat: "%@ has less than %d%% free.",
        batteryTitle: "Low battery",
        batteryBodyFormat: "Battery is at %d%%.",
        batteryTemperature: "High battery temperature",
        batteryTemperatureThreshold: "Temperature above",
        batteryTemperatureTitle: "Hot battery",
        batteryTemperatureBodyFormat: "Battery reached %@."
    )
}

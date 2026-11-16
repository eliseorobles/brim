// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Strings for the Features hub and its permissions portal. Same contract as
/// the other FeatureStrings structs: memberwise init with labeled arguments
/// in declaration order, one English static, all in this file.
struct FeatureHubStrings {
    // Page chrome
    let pageTitle: String
    let intro: String
    let tabFeatures: String
    let tabPermissions: String
    let activeCountFormat: String      // "%1$d of %2$d features on"
    let monitorAllOffNote: String
    // Group headers
    let groupClipboardFiles: String
    let groupEnergyDisplay: String
    let groupTools: String
    let groupMonitor: String
    let experimentalBadge: String
    // Permissions portal
    let permissionsIntro: String
    let usedByFormat: String           // "Used by %@"
    let usedByNone: String
    let unusedBanner: String
    let statusGranted: String
    let statusMissing: String
    let statusUnknown: String
    let requestButton: String
    let openSystemSettings: String
    let permAccessibility: String
    let permFullDisk: String
    let permFilesAndFolders: String
    let permNotifications: String
    let permAutomationFinder: String
    let explainAccessibility: String
    let explainFullDisk: String
    let explainFilesAndFolders: String
    let explainNotifications: String
    let explainAutomationFinder: String
    // One-line feature descriptions
    let descClipboardHistory: String
    let descPastePlain: String
    let descKeepAwake: String
    let descCleaner: String
    let descUninstaller: String
    let descHomebrew: String
    let descMonitorCPU: String
    let descMonitorGPU: String
    let descMonitorMemory: String
    let descMonitorNetwork: String
    let descMonitorDisk: String
    let descMonitorPower: String
    // Install metaphor and the restart-to-unload card
    let footerNote: String
    let restartNote: String
    let restartButton: String
    let installButton: String
    let uninstallButton: String
    let installAllButton: String
    let uninstallAllButton: String
    let presetsTitle: String
    let presetsCaption: String
    let presetEssentialName: String
    let presetEssentialDesc: String
    let presetBatteryName: String
    let presetBatteryDesc: String
    let presetApplyButton: String
    let presetConfirmFormat: String
    let presetConfirmApply: String
    let presetConfirmCancel: String
    let energyIdle: String
    let energyPeriodic: String
    let energyHelp: String
    let explainAppManagement: String
    let onboardingSelectedPermissionsTitle: String
    let onboardingNoSelectedPermissions: String
    let onboardingOtherPermissionsTitle: String
    let onboardingOtherPermissionsCaption: String
}

extension FeatureStrings {
    static func hub(_ language: AppLanguage) -> FeatureHubStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

extension FeatureHubStrings {
    static let enUS = FeatureHubStrings(
        pageTitle: "Features",
        intro: "Install only what you use. Whatever you uninstall disappears from the whole app and stops loading.",
        tabFeatures: "Features",
        tabPermissions: "Permissions",
        activeCountFormat: "%1$d of %2$d features installed",
        monitorAllOffNote: "With everything off, the Monitor leaves the panel and the menu bar.",
        groupClipboardFiles: "Clipboard and files",
        groupEnergyDisplay: "Energy and display",
        groupTools: "Tools",
        groupMonitor: "System monitor",
        experimentalBadge: "Experimental",
        permissionsIntro: "What each permission does and which features use it. Other access is requested only when you use it.",
        usedByFormat: "Used by %@",
        usedByNone: "Nothing that is on uses this permission right now.",
        unusedBanner: "You granted this permission, but nothing that is on needs it. If you like, revoke it in System Settings.",
        statusGranted: "Granted",
        statusMissing: "Not granted",
        statusUnknown: "The app can’t check this one",
        requestButton: "Request",
        openSystemSettings: "Open System Settings",
        permAccessibility: "Accessibility",
        permFullDisk: "Full Disk Access",
        permFilesAndFolders: "Files & Folders",
        permNotifications: "Notifications",
        permAutomationFinder: "Finder automation",
        explainAccessibility: "Lets features paste for you and keep the Mac awake by nudging the pointer.",
        explainFullDisk: "Lets the cleaner and the uninstaller find leftover files everywhere.",
        explainFilesAndFolders: "Lets WhatsApp downloads cleanup and the experimental organizer inspect your Downloads folder.",
        explainNotifications: "Lets the app notify you about alerts you turned on.",
        explainAutomationFinder: "Lets the app ask Finder to move files for you.",
        descClipboardHistory: "Keep a local history of what you copy",
        descPastePlain: "Paste text without formatting",
        descKeepAwake: "Keep the Mac awake on demand",
        descCleaner: "Clear caches and junk files",
        descUninstaller: "Remove apps and their leftovers",
        descHomebrew: "Keep Homebrew packages up to date",
        descMonitorCPU: "Processor usage and temperature",
        descMonitorGPU: "Graphics usage and temperature",
        descMonitorMemory: "Memory use and pressure",
        descMonitorNetwork: "Network speed and usage",
        descMonitorDisk: "Disk space and activity",
        descMonitorPower: "Battery, power and charging",
        footerNote: "Uninstalling deletes nothing: the feature just leaves the app and stops loading. Install it again anytime and everything returns as it was.",
        restartNote: "Features uninstalled in this session stay loaded until the app restarts. Restart to unload them from memory now.",
        restartButton: "Restart now",
        installButton: "Install",
        uninstallButton: "Uninstall",
        installAllButton: "Install all",
        uninstallAllButton: "Uninstall all",
        presetsTitle: "Start with a bundle",
        presetsCaption: "One click sets the app up for how you use your Mac. Everything else stays one click away.",
        presetEssentialName: "Essentials",
        presetEssentialDesc: "System monitor, keep awake, clipboard history and AI agents.",
        presetBatteryName: "Battery and quiet",
        presetBatteryDesc: "A lean monitor with battery, memory and processor. Nothing listens to input.",
        presetApplyButton: "Apply",
        presetConfirmFormat: "Install the %1$@ bundle and uninstall the rest? Nothing is deleted, and everything comes back with one click.",
        presetConfirmApply: "Apply bundle",
        presetConfirmCancel: "Cancel",
        energyIdle: "Nothing at rest",
        energyPeriodic: "Checks on an interval",
        energyHelp: "What the feature keeps alive while it is on. Uninstalled features load nothing at all.",
        explainAppManagement: "Lets updates replace or remove apps installed by the package manager.",
        onboardingSelectedPermissionsTitle: "Permissions for your choices",
        onboardingNoSelectedPermissions: "You do not need to grant any permission to finish setup.",
        onboardingOtherPermissionsTitle: "Other permissions",
        onboardingOtherPermissionsCaption: "Optional. Grant these now or later, when a feature needs them."
    )
}

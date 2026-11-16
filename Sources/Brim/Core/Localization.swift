// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// The interface language. The app speaks English only; the type stays so
/// every string table keeps one entry point and dates keep their region.
enum AppLanguage: String, CaseIterable {
    case enUS = "en-US"

    /// Dates and times in this language, arranged the way System Settings
    /// asks: region, 12- or 24-hour clock and first day of the week. A locale
    /// made from the language alone would bring that language's own clock.
    func formattingLocale(system: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(identifier: rawValue)
        components.region = system.region
        components.hourCycle = system.hourCycle
        components.firstDayOfWeek = system.firstDayOfWeek
        return Locale(components: components)
    }
}

/// Source of every user-facing string.
final class L10n: ObservableObject {
    static let shared = L10n()

    let language = AppLanguage.enUS

    var s: Strings { .enUS }

    private init() {}
}

extension Strings {
    /// The catalog for a language, as the feature string tables offer theirs.
    static func localized(_ language: AppLanguage) -> Strings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

/// Flat, compiler-checked catalog of UI strings.
struct Strings {
    // MARK: Menu bar & context menu
    let statusIdleTooltip: String
    let statusActiveUntil: String      // + time
    let statusActiveIndefinite: String
    let menuEnableAwake: String
    let menuDisableAwake: String
    let menuActivateFor: String
    let menuSettings: String
    let menuAbout: String
    let menuQuit: String
    let moreOptions: String
    // Standard application menu bar (App / Edit / Window) shown while one of the
    // app's own windows is focused. Without it, an accessory app has no main menu
    // and the standard shortcuts (Cmd+H/M/W/Q, Cmd+C/V/X/A) do nothing.
    let menuHide: String
    let menuHideOthers: String
    let menuShowAll: String
    let menuEdit: String
    let menuUndo: String
    let menuRedo: String
    /// Named actions an icon-only control borrows so it can say what it
    /// does. No feature owns these, because half a dozen already share them.
    let actionClear: String
    let actionSearch: String
    let menuCut: String
    let menuCopy: String
    let menuPaste: String
    let menuSelectAll: String
    let menuWindow: String
    let menuMinimize: String
    let menuZoom: String
    let menuClose: String

    // MARK: Durations
    let minutes15: String
    let minutes30: String
    let hour1: String
    let hours2: String
    let hours4: String
    let hours8: String
    let indefinitely: String
    let indefinite: String

    // MARK: Panel — header & footer
    let panelSettings: String
    let panelQuit: String

    // MARK: Panel — keep awake card
    let keepAwakeTitle: String
    let keepAwakeEndsIn: String        // + remaining
    let keepAwakeUntilDisabled: String
    let keepAwakeNormalRules: String
    let keepAwakeUntilLabel: String
    let keepAwakeUntilStart: String
    let keepAwakeOptions: String
    let keepAwakeMouseJiggle: String
    let keepAwakeMouseJiggleCaption: String
    let keepAwakeMouseJiggleInterval: String
    let keepAwakeActiveIconLabel: String
    let keepAwakeActiveIconBrim: String
    let keepAwakeActiveIconCoffee: String
    let keepAwakeActiveIconEye: String
    let keepAwakeActiveIconMoon: String
    let keepAwakeActiveIconLight: String
    let keepAwakeIconTintLabel: String
    let keepAwakeIconTintOrange: String
    let keepAwakeIconTintGreen: String
    let keepAwakeIconTintBlue: String
    let keepAwakeIconTintPurple: String
    let keepAwakeIconTintPink: String
    let keepAwakeIconTintNone: String
    let clamshellTitle: String
    let clamshellOnCaption: String
    let clamshellNeedsSession: String
    let clamshellReady: String
    let clamshellNeedsPassword: String

    // MARK: Panel — system monitor
    let systemSection: String
    let temperatures: String
    let cpuLabel: String
    let gpuLabel: String
    let batteryLabel: String
    let usageSection: String
    let memorySection: String
    let memoryPressure: String
    let memorySwapUsed: String
    let memoryCompressed: String
    let memoryCachedFiles: String
    let pressureNormal: String
    let pressureWarning: String
    let pressureCritical: String
    let monitorUnavailable: String
    let energyAppsTitle: String
    let energyAppsIdle: String

    // MARK: Notifications
    let notifySessionEndedTitle: String
    let notifySessionEndedBody: String
    let notifyBatteryTitle: String
    let notifyBatteryBody: String

    // MARK: Administrator prompts (shown by macOS password dialogs)
    let adminPromptClamshellOff: String
    let adminPromptRecover: String
    let adminPromptSudoersInstall: String
    let adminPromptSudoersRemove: String

    // MARK: Settings — window & tabs
    let settingsTitle: String
    let tabGeneral: String
    let tabEnergy: String
    let tabAdvanced: String
    let tabAbout: String

    // MARK: Settings — advanced
    let advancedResetSection: String
    let advancedResetDescription: String
    let advancedClearButton: String
    let advancedCleared: String
    let advancedClearFailed: String
    let advancedClearConfirmTitle: String
    let advancedClearConfirmBody: String
    let advancedUninstallSection: String
    let advancedUninstallDescription: String
    let advancedUninstallButton: String
    let advancedUninstallConfirmTitle: String
    let advancedUninstallConfirmBody: String
    let advancedUninstallFailedTitle: String
    let advancedUninstallFailedBody: String

    // MARK: Settings — general
    let launchAtLogin: String
    let menuBarSection: String
    let showCountdown: String
    let globalHotkeySection: String
    let hotkeyToggle: String
    let hotkeyCaption: String

    // MARK: Settings — energy
    let defaultDurationLabel: String
    let keepAwakeAutoStart: String
    let keepAwakeAutoStartCaption: String
    let batteryDisableBelow: String
    let batteryNever: String
    let batteryProtectionCaption: String
    let configuring: String
    let sudoersFailed: String
    let clamshellExplanation: String
    let dimScreenOnLidCloseTitle: String
    let dimScreenOnLidCloseCaption: String

    // MARK: Settings — shortcuts and paste as plain text
    let quickToolShortcutToggle: String
    let pastePlainName: String
    let pastePlainCaption: String

    // MARK: Feature — complete app uninstaller
    let uninstallerName: String
    let uninstallerEnableCaption: String
    let uninstallerMenuItem: String
    let uninstallerDropTitle: String
    let uninstallerDropSubtitle: String
    let uninstallerChoose: String
    let uninstallerPickerTitle: String
    let uninstallerPickerSearch: String
    let uninstallerPickerEmpty: String
    let uninstallerEmptyNote: String
    let uninstallerFDANote: String
    let uninstallerFDAGrant: String
    let uninstallerFDAHint: String
    let uninstallerFDARelaunch: String
    let uninstallerScanning: String
    let uninstallerRemoving: String
    let uninstallerFoundTitle: String
    let uninstallerSelectedFormat: String   // + selected, total
    let uninstallerSelectAll: String
    let uninstallerRemove: String
    let uninstallerCancel: String
    let uninstallerConfirmationExpired: String
    let uninstallerDoneTitle: String
    let uninstallerFreedFormat: String      // + size string
    let uninstallerSomeFailed: String
    let uninstallerFailedNeedsFDA: String
    let uninstallerFailedMoreFormat: String
    let uninstallerAnother: String
    let uninstallerCatApp: String
    let uninstallerCatSupport: String
    let uninstallerCatCaches: String
    let uninstallerCatPreferences: String
    let uninstallerCatContainers: String
    let uninstallerCatLogs: String
    let uninstallerCatState: String
    let uninstallerCatOther: String
    let uninstallerWatchTrashToggle: String
    let uninstallerWatchTrashCaption: String
    let uninstallerConfirmTrashCleanup: String
    let uninstallerTrashUnavailable: String
    let uninstallerRefusedNotApp: String
    let uninstallerRefusedSystemFormat: String        // + app name
    let uninstallerRefusedSharedFormat: String        // + app name
    let uninstallerRefusedNestedFormat: String        // + app name
    let uninstallerRefusedSelfFormat: String          // + Advanced tab name
    let uninstallerRefusedLinkFormat: String          // + app name
    let uninstallerRefusedUnidentifiedFormat: String  // + app name
    let uninstallerPickerHiddenNote: String

    // MARK: Shared buttons
    let cleanNowTitle: String
    let clearFieldButton: String

    // MARK: Feature — Homebrew manager
    let homebrewName: String
    let homebrewEnableCaption: String
    let homebrewMissingTitle: String
    let homebrewMissingBody: String
    let homebrewInstallHomebrew: String
    let homebrewInstallHomebrewCaption: String
    let homebrewInstallHomebrewOpened: String
    let homebrewShellSetupTitle: String
    let homebrewShellSetupBody: String
    let homebrewShellSetupButton: String
    let homebrewShellSetupOpened: String
    let homebrewRefresh: String
    let homebrewCheckPackages: String
    let homebrewTrustTitle: String
    let homebrewTrustCaption: String
    let homebrewTrustButton: String
    let homebrewSearchPlaceholder: String
    let homebrewKeyboardHint: String
    let homebrewSearchButton: String
    let homebrewSearchResults: String
    let homebrewInstalled: String
    let homebrewAll: String
    let homebrewFormulas: String
    let homebrewCasks: String
    let homebrewNoPackages: String
    let homebrewDependencies: String
    let homebrewGroupDependencies: String
    let homebrewOrphans: String
    let homebrewOrphansNote: String
    let homebrewDependencyUpdatesFormat: String
    let homebrewNoSelection: String
    let homebrewDetailsTitle: String
    let homebrewInstall: String
    let homebrewUninstall: String
    let homebrewUpgrade: String
    let homebrewUpgradeAll: String
    let homebrewUpdateHomebrew: String
    let homebrewAllPackages: String
    let homebrewOpenTerminal: String
    let homebrewCancelOperation: String
    let homebrewClearLog: String
    let homebrewLastLogView: String
    let homebrewLastLogHide: String
    let homebrewVersion: String
    let homebrewDescription: String
    let homebrewHomepage: String
    let homebrewPopularity: String
    let homebrewPopularityFormat: String
    let homebrewInstalledBadge: String
    let homebrewNotInstalledBadge: String
    let homebrewUpdates: String
    let homebrewUpdateAvailableBadge: String
    let homebrewLatestVersion: String
    let homebrewConfirmInstallTitle: String
    let homebrewConfirmInstallBodyFormat: String
    let homebrewConfirmUninstallTitle: String
    let homebrewConfirmUninstallBodyFormat: String
    let homebrewConfirmUpgradeTitle: String
    let homebrewConfirmUpgradeBodyFormat: String
    let homebrewConfirmUpgradeAllTitle: String
    let homebrewConfirmUpgradeAllBody: String
    let homebrewConfirmUpdateHomebrewTitle: String
    let homebrewConfirmUpdateHomebrewBody: String
    let homebrewTerminalFallback: String
    let homebrewLoading: String
    let homebrewSearchEmpty: String
    let homebrewOperationInstallFormat: String
    let homebrewOperationUninstallFormat: String
    let homebrewOperationUpgradeFormat: String
    let homebrewOperationUpgradeAll: String
    let homebrewOperationUpdateHomebrew: String
    let homebrewOperationInstalledFormat: String
    let homebrewOperationUninstalledFormat: String
    let homebrewOperationUpgradedFormat: String
    let homebrewOperationUpgradedAll: String
    let homebrewOperationUpdatedHomebrew: String
    let homebrewOperationFailedFormat: String
    let homebrewOperationCancelled: String
    let homebrewOperationPreparing: String
    let homebrewOperationDownloading: String
    let homebrewOperationInstalling: String
    let homebrewOperationUninstalling: String
    let homebrewOperationUpgrading: String
    let homebrewOperationFinalizing: String
    let homebrewOperationRefreshing: String
    let homebrewOperationTerminal: String
    let homebrewOperationElapsedFormat: String
    let homebrewOperationShowDetails: String
    let homebrewOperationHideDetails: String
    let homebrewOperationTechnicalLog: String
    let homebrewOperationProgressUnknown: String

    // MARK: Shortcuts
    let shortcutLabel: String

    // MARK: Panel — per-app breakdown
    let breakdownMeasuring: String

    // MARK: Panel — edit mode
    let resetToDefaultHelp: String

    // MARK: Beta badge
    let betaBadgeLabel: String

    // MARK: Permissions (shared by Settings & onboarding)
    let permissionRequired: String
    let permissionAccessibility: String
    let permissionGranted: String
    let permissionMissing: String
    let permissionOpenSettings: String
    let permissionRequest: String
    let permissionRestartNote: String

    // MARK: About
    let aboutDescription: String
    let versionPrefix: String
    let reviewIntro: String

    // MARK: Onboarding
    let obContinue: String
    let obBack: String
    let obStart: String
    let obStepWelcomeTitle: String
    let obStepWelcomeBody: String
    let obWelcomeBullet1Title: String
    let obWelcomeBullet1Body: String
    let obWelcomeBullet2Title: String
    let obWelcomeBullet2Body: String
    let obWelcomeBullet3Title: String
    let obWelcomeBullet3Body: String
    let obStepDoneTitle: String
    let obStepDoneBody: String
    let obDoneHint: String
    let obPurposeTitle: String
    let obPurposeBody: String
    let obPurposeSkip: String

    // MARK: Settings — monitor / menu bar metrics
    let tabMonitor: String
    let monitorMenuBarSection: String
    let monitorMenuBarPreview: String
    let monitorMenuBarCaption: String
    let monitorCombineTemperatures: String
    let monitorCombineTemperaturesCaption: String
    let monitorSeparateMenuBarMetrics: String
    let monitorSeparateMenuBarMetricsCaption: String
    let monitorNetworkUploadFirst: String
    let monitorShowCPU: String
    let monitorShowMemory: String
    let monitorShowNetwork: String
    let monitorShowPowerLabel: String
    let monitorIntervalLabel: String
    let monitorInterval1: String
    let monitorInterval2: String
    let monitorInterval5: String
    let monitorPanelSection: String
    let betaBadge: String
    let betaFeatureWarning: String

    // MARK: Panel — network
    let networkSection: String
    let networkIPAddresses: String
    let networkLocalIP: String
    let networkDownload: String
    let networkUpload: String
    let networkThisSession: String
    let networkMeasuring: String
    let networkApps: String
    let networkAppsIdle: String

    // MARK: Panel — disk
    let diskSection: String
    let diskUsed: String
    let diskMenuBarStyleLabel: String
    let diskMenuBarUsedPercentage: String
    let diskMenuBarAvailableSpace: String
    let diskMenuBarUsedSpace: String
    let diskAvailable: String
    let diskPurgeable: String
    let diskInternal: String
    let diskExternal: String
    let diskSelect: String
    let diskRead: String
    let diskWrite: String
    let diskSMARTStatus: String
    let diskSMARTUnavailable: String
    let diskTotalRead: String
    let diskTotalWritten: String
    let diskTemperature: String
    let diskHealth: String
    let diskPowerCycles: String
    let diskPowerOnHours: String
    let diskEject: String
    let diskEjectAll: String
    let diskEjecting: String
    let diskReadyToRemove: String
    let diskEjectFailed: String
    let diskProtectionCaption: String
    let diskNoExternal: String
    let diskOpenInFinder: String
    let diskStorageSettings: String
    let diskNoDisks: String

    // MARK: Panel — power
    let powerSection: String
    let powerSystem: String
    let powerAdapter: String
    let powerBattery: String
    let powerCharging: String
    let powerOnBattery: String
    let powerPluggedIn: String
    let powerUnavailable: String
    let powerAdapterMaxFormat: String   // + rated watts, e.g. "30 W max"
    let monitorShowGPU: String
    let monitorShowCPUTemperature: String
    let monitorShowGPUTemperature: String
    let monitorShowBatteryTemperature: String
    let monitorShowPeripheralBattery: String
    let peripheralBatteryNoDevices: String
    let monitorGraphsSection: String

    // MARK: Onboarding menu bar setup
    let menuBarSpacingLabel: String
    let menuBarSpacingStandard: String
    let menuBarSpacingCompact: String
    let menuBarHideIconToggle: String
    let menuBarHideIconCaption: String
    let monitorMemoryPressureDot: String
    // MARK: System uptime, battery health, speed test
    let systemUptime: String
    let batteryCharge: String
    let powerHealth: String
    let powerCycles: String
    let speedTestRun: String
    let speedTestAgain: String
    let speedTestLatency: String
    let speedTestTesting: String
    let speedTestFailed: String

    // MARK: Per-item panel config (Settings + onboarding)
    let monitorShowInPanel: String
    let disclosureExpanded: String
    let disclosureCollapsed: String
    let panelHideItem: String
    let panelShowItem: String
    let panelHiddenItem: String
    let monitorItemUptime: String
    let monitorItemNetSpeed: String
    let monitorItemNetTotals: String
    let monitorItemNetTest: String
    let monitorItemDiskUsage: String
    let monitorItemDiskActivity: String
    let monitorItemDiskSMART: String
    let monitorItemDiskProtection: String
    let monitorItemDiskTools: String
    let monitorPanelConfigHint: String
    let monitorOrderHint: String

    // MARK: Panel — section titles
    let utilitiesSection: String
    let quickControlsSection: String

    // MARK: Settings — shortcuts page, search and the menu bar icon
    let shortcutsPageCaption: String
    let shortcutsPageTitle: String
    let settingsSearchPlaceholder: String
    let showMenuBarIcon: String
    let menuBarIconStillHiddenTitle: String
    let menuBarIconStillHiddenBody: String
    let menuBarIconManagerHintFormat: String  // + manager name (twice)
    let menuBarIconDisallowedBody: String

    // MARK: Configurable shortcuts
    let shortcutRecording: String
    let shortcutReset: String
    let shortcutNone: String
    let shortcutClear: String
    let shortcutInvalid: String
    let shortcutPressKeys: String
    let shortcutEscapeHint: String
    let shortcutDeleteHint: String
    let shortcutNotCaptured: String
    let shortcutConflictFormat: String
    let shortcutTakeOverOffer: String
    let shortcutTakeOverAction: String
    let shortcutTakeOverCaption: String
    let shortcutTakeOverDismiss: String
    let shortcutUnavailable: String

    // MARK: Cleaner
    let cleanerName: String
    let cleanerIntroTitle: String
    let cleanerIntroCaption: String
    let cleanerScan: String
    let cleanerScanning: String
    let cleanerCleaning: String
    let cleanerCatLeftovers: String
    let cleanerCatLoginItems: String
    let cleanerCatCaches: String
    let cleanerCatLogs: String
    let cleanerCatDeveloper: String
    let cleanerCatTrash: String
    let cleanerLeftoversNote: String
    let cleanerLoginItemsNote: String
    let cleanerTrashNote: String
    let cleanerCatDeviceBackups: String
    let cleanerDeviceBackupsCaption: String
    let cleanerCatScreenshots: String
    let cleanerScreenshotsCaptionFormat: String
    let cleanerScreenshotsSettingCaption: String
    let cleanerScreenshotsAfterFormat: String
    let cleanerNothingFound: String
    let cleanerDoneNote: String
    let cleanerAgain: String
    let cleanerRevealInFinder: String
    let cleanerPanelCaption: String
    let cleanerSafeSection: String
    let cleanerOptionalSection: String
    let cleanerCatOtherCaches: String
    let cleanerCachesCaption: String
    let cleanerLogsCaption: String
    let cleanerDeveloperCaption: String
    let cleanerLoginItemsCaption: String
    let cleanerLeftoversCaption: String
    let cleanerOtherCachesCaption: String
    let cleanerCleanSizeFormat: String      // + size string
    let cleanerScheduleTitle: String
    let cleanerScheduleOff: String
    let cleanerScheduleDaily: String
    let cleanerScheduleWeekly: String
    let cleanerScheduleCaption: String
    let cleanerScheduleLastFormat: String   // + size string
    let cleanerAutoNotificationFormat: String  // + size string
    let cleanerScheduleNextFormat: String   // + relative date and time
    let cleanerScheduleRanFormat: String    // + relative date and time
    let cleanerScheduleNotifyToggle: String
    let cleanerNotifDenied: String
    let cleanerNotifOpenSettings: String
    let launchAtLoginNeedsApplications: String
    let launchAtLoginNeedsApproval: String
    let monitorOpenActivityMonitor: String
    let monitorMemoryMetricLabel: String
    let memoryMetricUsed: String
    let memoryMetricApp: String
    let keepAwakeRightClickToggle: String
    let keepAwakeRightClickToggleCaption: String
    let uninstallerHomebrewPackageFormat: String
    let uninstallerHomebrewCheckFailed: String
}

// MARK: - English (US)

extension Strings {
    static let enUS = Strings(
        statusIdleTooltip: "Brim: normal sleep",
        statusActiveUntil: "Brim: awake until",
        statusActiveIndefinite: "Brim: awake indefinitely",
        menuEnableAwake: "Enable keep awake",
        menuDisableAwake: "Disable keep awake",
        menuActivateFor: "Activate for…",
        menuSettings: "Settings…",
        menuAbout: "About Brim",
        menuQuit: "Quit Brim",
        moreOptions: "More options",
        menuHide: "Hide Brim",
        menuHideOthers: "Hide Others",
        menuShowAll: "Show All",
        menuEdit: "Edit",
        menuUndo: "Undo",
        menuRedo: "Redo",
        actionClear: "Clear",
        actionSearch: "Search",
        menuCut: "Cut",
        menuCopy: "Copy",
        menuPaste: "Paste",
        menuSelectAll: "Select All",
        menuWindow: "Window",
        menuMinimize: "Minimize",
        menuZoom: "Zoom",
        menuClose: "Close",

        minutes15: "15 minutes",
        minutes30: "30 minutes",
        hour1: "1 hour",
        hours2: "2 hours",
        hours4: "4 hours",
        hours8: "8 hours",
        indefinitely: "Indefinitely",
        indefinite: "Indefinite",

        panelSettings: "Settings",
        panelQuit: "Quit",

        keepAwakeTitle: "Keep awake",
        keepAwakeEndsIn: "Ends in",
        keepAwakeUntilDisabled: "Active until you turn it off",
        keepAwakeNormalRules: "The Mac follows its normal energy rules",
        keepAwakeUntilLabel: "Until",
        keepAwakeUntilStart: "Start",
        keepAwakeOptions: "Options",
        keepAwakeMouseJiggle: "Move pointer slightly",
        keepAwakeMouseJiggleCaption: "During a session, moves the pointer a little at the chosen interval.",
        keepAwakeMouseJiggleInterval: "Interval",
        keepAwakeActiveIconLabel: "Active icon",
        keepAwakeActiveIconBrim: "Brim",
        keepAwakeActiveIconCoffee: "Coffee",
        keepAwakeActiveIconEye: "Eye",
        keepAwakeActiveIconMoon: "Moon",
        keepAwakeActiveIconLight: "Lightbulb",
        keepAwakeIconTintLabel: "Active icon color",
        keepAwakeIconTintOrange: "Orange",
        keepAwakeIconTintGreen: "Green",
        keepAwakeIconTintBlue: "Blue",
        keepAwakeIconTintPurple: "Purple",
        keepAwakeIconTintPink: "Pink",
        keepAwakeIconTintNone: "No color",
        clamshellTitle: "Keep going with the lid closed",
        clamshellOnCaption: "Sleep fully disabled. Mind the power",
        clamshellNeedsSession: "Applied whenever “Keep awake” is active",
        clamshellReady: "Ready. Toggles without a password",
        clamshellNeedsPassword: "Will ask for the administrator password once",

        systemSection: "System",
        temperatures: "Temperatures",
        cpuLabel: "CPU",
        gpuLabel: "GPU",
        batteryLabel: "Battery",
        usageSection: "Hardware usage",
        memorySection: "Memory",
        memoryPressure: "Pressure",
        memorySwapUsed: "Swap used",
        memoryCompressed: "Compressed",
        memoryCachedFiles: "Cached files",
        pressureNormal: "Normal",
        pressureWarning: "Caution",
        pressureCritical: "Critical",
        monitorUnavailable: "Sensors unavailable on this Mac",
        energyAppsTitle: "Apps using significant energy",
        energyAppsIdle: "No significant energy use",

        notifySessionEndedTitle: "Session ended",
        notifySessionEndedBody: "Time is up. The Mac will sleep normally again.",
        notifyBatteryTitle: "Brim disabled",
        notifyBatteryBody: "Low battery. Normal sleep was restored to protect the charge.",
        adminPromptClamshellOff: "Brim needs your password to restore the Mac’s normal sleep.",
        adminPromptRecover: "Brim quit while the Mac’s sleep was disabled. Enter the password to restore normal sleep.",
        adminPromptSudoersInstall: "Brim will create a restricted rule (pmset disablesleep only) to toggle closed-lid mode without asking for a password. This is the only time the password is needed.",
        adminPromptSudoersRemove: "Brim will remove the password-free closed-lid rule.",

        settingsTitle: "Brim Settings",
        tabGeneral: "General",
        tabEnergy: "Energy",
        tabAdvanced: "Advanced",
        tabAbout: "About",
        advancedResetSection: "Permissions",
        advancedResetDescription: "Removes every permission you granted Brim (Accessibility, Full Disk Access and others), the login item and the closed-lid rule. Useful to start fresh or before uninstalling. The app stays installed.",
        advancedClearButton: "Clear all permissions",
        advancedCleared: "Permissions cleared.",
        advancedClearFailed: "Some permissions or the closed-lid rule could not be removed. Try again and allow the password request if it appears.",
        advancedClearConfirmTitle: "Clear all permissions?",
        advancedClearConfirmBody: "Features that need permissions will stop working until you grant them again. Your settings are kept.",
        advancedUninstallSection: "Uninstall",
        advancedUninstallDescription: "Does all of the above, then removes the preferences, the stored data and your list of Claude accounts in ~/.config, and moves Brim to the Trash. The app quits when done. You can reinstall anytime.",
        advancedUninstallButton: "Uninstall Brim completely",
        advancedUninstallConfirmTitle: "Uninstall Brim?",
        advancedUninstallConfirmBody: "Brim will clear its permissions, remove its preferences and its list of Claude accounts, and move to the Trash, then quit. This can’t be undone from the app, but it stays in the Trash until you empty it.",
        advancedUninstallFailedTitle: "Uninstall stopped",
        advancedUninstallFailedBody: "Brim could not put back a system setting it changed: sleep or fan speed. Nothing was removed. Try again and allow the password request if it appears.",

        launchAtLogin: "Launch at login",
        menuBarSection: "Menu bar",
        showCountdown: "Show remaining time next to the icon",
        globalHotkeySection: "Global shortcut",
        hotkeyToggle: "Enable shortcut for “Keep awake”",
        hotkeyCaption: "Works in any app, no extra permissions.",

        defaultDurationLabel: "Default duration",
        keepAwakeAutoStart: "Keep Awake when Brim opens",
        keepAwakeAutoStartCaption: "Starts a session with the default duration.",
        batteryDisableBelow: "Disable when battery drops below",
        batteryNever: "Never",
        batteryProtectionCaption: "Keeps a forgotten session from draining the MacBook battery.",
        configuring: "Configuring…",
        sudoersFailed: "Couldn’t turn on closed-lid mode. Try again.",
        clamshellExplanation: "“Keep going with the lid closed” fully disables sleep while “Keep awake” is active and is reverted automatically when the session ends or the app quits. Prefer using it plugged in.",
        dimScreenOnLidCloseTitle: "Dim the display to zero",
        dimScreenOnLidCloseCaption: "Dims the display when the lid closes and brings the brightness back when it opens.",

        quickToolShortcutToggle: "Global shortcut",
        pastePlainName: "Paste as plain text",
        pastePlainCaption: "Pastes what you copied without colors, fonts or formatting. The original stays on the clipboard.",




        uninstallerName: "Uninstaller",
        uninstallerEnableCaption: "Removes an app together with the caches, preferences, logs and leftovers it leaves behind.",
        uninstallerMenuItem: "Uninstall an app…",
        uninstallerDropTitle: "Drag an app here",
        uninstallerDropSubtitle: "or choose one to scan",
        uninstallerChoose: "Choose app…",
        uninstallerPickerTitle: "Choose app",
        uninstallerPickerSearch: "Search apps",
        uninstallerPickerEmpty: "No apps found",
        uninstallerEmptyNote: "Nothing is removed without your confirmation.",
        uninstallerFDANote: "Grant Full Disk Access for a more thorough scan.",
        uninstallerFDAGrant: "Grant access…",
        uninstallerFDAHint: "Turn Brim on in the list. If it isn’t there, click + and pick Brim from Applications. Access only applies after you reopen the app.",
        uninstallerFDARelaunch: "Relaunch now",
        uninstallerScanning: "Scanning files…",
        uninstallerRemoving: "Moving to the Trash…",
        uninstallerFoundTitle: "found",
        uninstallerSelectedFormat: "%d of %d selected",
        uninstallerSelectAll: "Select all",
        uninstallerRemove: "Move to Trash",
        uninstallerCancel: "Cancel",
        uninstallerConfirmationExpired: "This confirmation is no longer valid. Review the current items and confirm again.",
        uninstallerDoneTitle: "Done!",
        uninstallerFreedFormat: "%@ removed",
        uninstallerSomeFailed: "Some items couldn’t be moved to the Trash.",
        uninstallerFailedNeedsFDA: "Sandboxed app data can only be moved with Full Disk Access. The administrator password does not stand in for it.",
        uninstallerFailedMoreFormat: "and %d more",
        uninstallerAnother: "Uninstall another",
        uninstallerCatApp: "Application",
        uninstallerCatSupport: "Support",
        uninstallerCatCaches: "Caches",
        uninstallerCatPreferences: "Preferences",
        uninstallerCatContainers: "Containers",
        uninstallerCatLogs: "Logs",
        uninstallerCatState: "Saved state",
        uninstallerCatOther: "Other",
        uninstallerWatchTrashToggle: "Offer cleanup when an app is moved to the Trash",
        uninstallerWatchTrashCaption: "Opens the Uninstaller when you delete an app in Finder. Needs Full Disk Access.",
        uninstallerConfirmTrashCleanup: "If you moved this app to the Trash to uninstall it, confirm to move its selected data to the Trash too. If the app is updating, cancel to keep its data.",
        uninstallerTrashUnavailable: "Cleanup requires moving the last installed copy from an Applications folder to the Trash. Data is kept while the app is installed or updating.",
        uninstallerRefusedNotApp: "Only apps can be uninstalled.",
        uninstallerRefusedSystemFormat: "%@ can’t be uninstalled because it’s part of macOS.",
        uninstallerRefusedSharedFormat: "%@ can’t be uninstalled here because it shares files with macOS or other apps.",
        uninstallerRefusedNestedFormat: "%@ can’t be uninstalled on its own because it’s part of another app.",
        uninstallerRefusedSelfFormat: "Brim can’t uninstall itself here. Use Settings › %@ instead.",
        uninstallerRefusedLinkFormat: "%@ can’t be uninstalled because it’s a link to an app stored elsewhere.",
        uninstallerRefusedUnidentifiedFormat: "%@ can’t be uninstalled because it can’t be identified as an app.",
        uninstallerPickerHiddenNote: "Apps that are part of macOS or made by Apple aren’t listed.",

        cleanNowTitle: "Clean now",
        clearFieldButton: "Clear field",

        homebrewName: "Homebrew",
        homebrewEnableCaption: "Search, install and remove formulae and casks.",
        homebrewMissingTitle: "Homebrew not found",
        homebrewMissingBody: "Brim can open the official Homebrew installer in your terminal. It shows the steps and asks for your password if needed.",
        homebrewInstallHomebrew: "Install Homebrew",
        homebrewInstallHomebrewCaption: "When the installer finishes, come back here and click Refresh.",
        homebrewInstallHomebrewOpened: "Installer opened in your terminal.",
        homebrewShellSetupTitle: "Finish terminal setup",
        homebrewShellSetupBody: "Homebrew is installed, but your terminal may not find the brew command yet. Brim can open the setup command in your terminal.",
        homebrewShellSetupButton: "Set up terminal",
        homebrewShellSetupOpened: "Command opened in your terminal. Then come back here and click Refresh.",
        homebrewRefresh: "Refresh",
        homebrewCheckPackages: "Check packages",
        homebrewTrustTitle: "Tap not trusted yet",
        homebrewTrustCaption: "Homebrew now asks for your confirmation before using third party taps. Trust %@ to continue.",
        homebrewTrustButton: "Trust and continue",
        homebrewSearchPlaceholder: "Search packages",
        homebrewKeyboardHint: "Space or Return closes the macOS panel. Use the search button.",
        homebrewSearchButton: "Search",
        homebrewSearchResults: "Results",
        homebrewInstalled: "Installed",
        homebrewAll: "All",
        homebrewFormulas: "Formulae",
        homebrewCasks: "Casks",
        homebrewNoPackages: "No packages found",
        homebrewDependencies: "Dependencies",
        homebrewGroupDependencies: "Group dependencies",
        homebrewOrphans: "No longer needed",
        homebrewOrphansNote: "Installed as dependencies, but no installed package needs them any more.",
        homebrewDependencyUpdatesFormat: "Dependency updates: %d",
        homebrewNoSelection: "Select an installed package or search for a new one.",
        homebrewDetailsTitle: "Package details",
        homebrewInstall: "Install",
        homebrewUninstall: "Uninstall",
        homebrewUpgrade: "Update",
        homebrewUpgradeAll: "Update all",
        homebrewUpdateHomebrew: "Update Homebrew",
        homebrewAllPackages: "packages",
        homebrewOpenTerminal: "Open terminal",
        homebrewCancelOperation: "Cancel",
        homebrewClearLog: "Clear log",
        homebrewLastLogView: "View last log",
        homebrewLastLogHide: "Hide last log",
        homebrewVersion: "Version",
        homebrewDescription: "Type",
        homebrewHomepage: "Open website",
        homebrewPopularity: "Popularity",
        homebrewPopularityFormat: "%@ installs in %@ days",
        homebrewInstalledBadge: "Installed",
        homebrewNotInstalledBadge: "Not installed",
        homebrewUpdates: "Updates",
        homebrewUpdateAvailableBadge: "Update available",
        homebrewLatestVersion: "Latest",
        homebrewConfirmInstallTitle: "Install with Homebrew?",
        homebrewConfirmInstallBodyFormat: "Homebrew will download and install %@. Dependencies may also be installed.",
        homebrewConfirmUninstallTitle: "Uninstall with Homebrew?",
        homebrewConfirmUninstallBodyFormat: "Homebrew will uninstall %@. Configuration files may remain on the system.",
        homebrewConfirmUpgradeTitle: "Update with Homebrew?",
        homebrewConfirmUpgradeBodyFormat: "Homebrew will download and apply the latest version of %@. Dependencies may also be updated.",
        homebrewConfirmUpgradeAllTitle: "Update all with Homebrew?",
        homebrewConfirmUpgradeAllBody: "Homebrew will download and apply the latest versions for packages with updates available. Dependencies may also be updated.",
        homebrewConfirmUpdateHomebrewTitle: "Update Homebrew?",
        homebrewConfirmUpdateHomebrewBody: "Homebrew will fetch the latest information and then reload your packages.",
        homebrewTerminalFallback: "This operation needs your terminal to ask for the administrator password. Brim does not capture passwords.",
        homebrewLoading: "Loading…",
        homebrewSearchEmpty: "No results",
        homebrewOperationInstallFormat: "Installing %@",
        homebrewOperationUninstallFormat: "Uninstalling %@",
        homebrewOperationUpgradeFormat: "Updating %@",
        homebrewOperationUpgradeAll: "Updating packages",
        homebrewOperationUpdateHomebrew: "Updating Homebrew",
        homebrewOperationInstalledFormat: "%@ installed.",
        homebrewOperationUninstalledFormat: "%@ uninstalled.",
        homebrewOperationUpgradedFormat: "%@ updated.",
        homebrewOperationUpgradedAll: "Packages updated.",
        homebrewOperationUpdatedHomebrew: "Homebrew updated.",
        homebrewOperationFailedFormat: "Could not finish %@.",
        homebrewOperationCancelled: "Operation cancelled.",
        homebrewOperationPreparing: "Preparing…",
        homebrewOperationDownloading: "Downloading files…",
        homebrewOperationInstalling: "Installing files…",
        homebrewOperationUninstalling: "Removing files…",
        homebrewOperationUpgrading: "Updating files…",
        homebrewOperationFinalizing: "Finishing…",
        homebrewOperationRefreshing: "Refreshing list…",
        homebrewOperationTerminal: "Continue in your terminal.",
        homebrewOperationElapsedFormat: "%@ elapsed",
        homebrewOperationShowDetails: "Show details",
        homebrewOperationHideDetails: "Hide details",
        homebrewOperationTechnicalLog: "Technical details",
        homebrewOperationProgressUnknown: "Homebrew has not reported a percentage yet.",


        shortcutLabel: "Shortcut",

        breakdownMeasuring: "Measuring…",

        resetToDefaultHelp: "Default",

        betaBadgeLabel: "Beta",

        permissionRequired: "Permission required",
        permissionAccessibility: "Accessibility",
        permissionGranted: "Granted",
        permissionMissing: "Not granted",
        permissionOpenSettings: "Open System Settings…",
        permissionRequest: "Grant access",
        permissionRestartNote: "macOS may ask to reopen the app after granting.",

        aboutDescription: "A utility hub for your Mac.\nSystem monitor, cleaner, app tools and the Dynamic Island, right in the menu bar.",
        versionPrefix: "Version",
        reviewIntro: "Review introduction",

        obContinue: "Continue",
        obBack: "Back",
        obStart: "Open Brim",
        obStepWelcomeTitle: "Welcome to Brim",
        obStepWelcomeBody: "A discreet menu bar utility that makes everyday macOS more practical.",
        obWelcomeBullet1Title: "Energy under control",
        obWelcomeBullet1Body: "Keep the Mac awake for as long as you want, even with the lid closed.",
        obWelcomeBullet2Title: "A clear view of the system",
        obWelcomeBullet2Body: "CPU, GPU and battery temperatures, hardware usage and memory pressure in real time.",
        obWelcomeBullet3Title: "A tidy Mac",
        obWelcomeBullet3Body: "Clean junk files, remove apps completely and keep every app up to date.",
        obStepDoneTitle: "All set!",
        obStepDoneBody: "Brim is already looking after your Mac.",
        obDoneHint: "Look for the Brim icon in the menu bar, at the top right of the screen.",
        obPurposeTitle: "What brought you here?",
        obPurposeBody: "Choose a ready setup or select exactly what you want to use.",
        obPurposeSkip: "You can add or remove features later in Settings.",

        tabMonitor: "Monitor",
        monitorMenuBarSection: "In the menu bar",
        monitorMenuBarPreview: "Menu bar preview",
        monitorMenuBarCaption: "Choose what appears next to the icon in the menu bar.",
        monitorCombineTemperatures: "Combine usage and temperature",
        monitorCombineTemperaturesCaption: "When usage and temperature for the same item are enabled, show them in one block.",
        monitorSeparateMenuBarMetrics: "Separate metrics into their own items",
        monitorSeparateMenuBarMetricsCaption: "Separates active blocks in the menu bar and keeps usage and temperature together when combine is on.",
        monitorNetworkUploadFirst: "Upload above download",
        monitorShowCPU: "CPU",
        monitorShowMemory: "Memory",
        monitorShowNetwork: "Network",
        monitorShowPowerLabel: "Power",
        monitorIntervalLabel: "Update every",
        monitorInterval1: "1 second",
        monitorInterval2: "2 seconds",
        monitorInterval5: "5 seconds",
        monitorPanelSection: "In the panel",
        betaBadge: "BETA",
        betaFeatureWarning: "Beta. You may run into some bugs.",

        networkSection: "Network",
        networkIPAddresses: "IP addresses",
        networkLocalIP: "Local IPv4",
        networkDownload: "Download",
        networkUpload: "Upload",
        networkThisSession: "This session",
        networkMeasuring: "Measuring…",
        networkApps: "Apps using network",
        networkAppsIdle: "No apps using network now",

        diskSection: "Disks",
        diskUsed: "used",
        diskMenuBarStyleLabel: "Disk display",
        diskMenuBarUsedPercentage: "Used percentage",
        diskMenuBarAvailableSpace: "Available space",
        diskMenuBarUsedSpace: "Used space",
        diskAvailable: "available",
        diskPurgeable: "purgeable",
        diskInternal: "Internal",
        diskExternal: "External",
        diskSelect: "Select disk",
        diskRead: "Read",
        diskWrite: "Write",
        diskSMARTStatus: "Status",
        diskSMARTUnavailable: "SMART unavailable for this disk",
        diskTotalRead: "Total read",
        diskTotalWritten: "Total written",
        diskTemperature: "Temperature",
        diskHealth: "Health",
        diskPowerCycles: "Power cycles",
        diskPowerOnHours: "Power on hours",
        diskEject: "Eject",
        diskEjectAll: "Eject all",
        diskEjecting: "Ejecting…",
        diskReadyToRemove: "Ready to remove",
        diskEjectFailed: "Could not eject",
        diskProtectionCaption: "Eject before unplugging.",
        diskNoExternal: "No external disk ready to eject.",
        diskOpenInFinder: "Open",
        diskStorageSettings: "Storage",
        diskNoDisks: "No mounted disks found.",

        powerSection: "Power",
        powerSystem: "System",
        powerAdapter: "Adapter",
        powerBattery: "Battery",
        powerCharging: "Charging",
        powerOnBattery: "On battery",
        powerPluggedIn: "Plugged in",
        powerUnavailable: "Power metrics unavailable on this Mac",
        powerAdapterMaxFormat: "%@ max",
        monitorShowGPU: "GPU",
        monitorShowCPUTemperature: "CPU temperature",
        monitorShowGPUTemperature: "GPU temperature",
        monitorShowBatteryTemperature: "Battery temperature",
        monitorShowPeripheralBattery: "Peripheral battery",
        peripheralBatteryNoDevices: "No devices found",
        monitorGraphsSection: "Graphs",

        menuBarSpacingLabel: "Menu bar spacing",
        menuBarSpacingStandard: "Standard",
        menuBarSpacingCompact: "Compact",
        menuBarHideIconToggle: "Hide the app icon while metrics are shown",
        menuBarHideIconCaption: "The icon returns by itself when metrics leave the bar and while “Keep awake” runs.",
        monitorMemoryPressureDot: "Pressure dot",
        systemUptime: "Up for",
        batteryCharge: "Charge",
        powerHealth: "Battery health",
        powerCycles: "Cycles",
        speedTestRun: "Speed test",
        speedTestAgain: "Test again",
        speedTestLatency: "Latency",
        speedTestTesting: "Testing…",
        speedTestFailed: "Test failed",

        monitorShowInPanel: "Show in panel",
        disclosureExpanded: "Expanded",
        disclosureCollapsed: "Collapsed",
        panelHideItem: "Hide from panel",
        panelShowItem: "Show in panel",
        panelHiddenItem: "Hidden",
        monitorItemUptime: "Uptime",
        monitorItemNetSpeed: "Live speed",
        monitorItemNetTotals: "Session totals",
        monitorItemNetTest: "Speed test",
        monitorItemDiskUsage: "Disk usage",
        monitorItemDiskActivity: "Live activity",
        monitorItemDiskSMART: "SMART",
        monitorItemDiskProtection: "External protection",
        monitorItemDiskTools: "Tools",
        monitorPanelConfigHint: "Open a block to choose what it shows.",
        monitorOrderHint: "Drag to reorder the panel sections and use the eye to show or hide each one.",

        utilitiesSection: "Utilities",
        quickControlsSection: "Controls",

        shortcutsPageCaption: "Edit every global shortcut from the features installed on this Mac. Inactive shortcuts stay saved but do not run.",
        shortcutsPageTitle: "Keyboard shortcuts",
        settingsSearchPlaceholder: "Search settings",
        showMenuBarIcon: "Show menu bar icon",
        menuBarIconStillHiddenTitle: "The icon is still hidden",
        menuBarIconStillHiddenBody: "The icon was rebuilt, but macOS did not give it a visible spot. The menu bar is probably out of room: remove some menu bar icons (or close apps with long menus) and try again.",
        menuBarIconManagerHintFormat: "%@ is open and may be keeping the icon in its hidden section. Look for Brim there, or set %@ to always show Brim.",
        menuBarIconDisallowedBody: "macOS is keeping Brim out of the menu bar. Open System Settings > Menu Bar, find Brim in the app list and turn on “Allow in the Menu Bar”. The icon appears as soon as the switch is on.",
        shortcutRecording: "Press the new shortcut",
        shortcutReset: "Reset",
        shortcutNone: "None",
        shortcutClear: "Remove shortcut",
        shortcutInvalid: "Use at least Control, Option or Command with a key.",
        shortcutPressKeys: "Press keys",
        shortcutEscapeHint: "Escape cancels.",
        shortcutDeleteHint: "Delete clears.",
        shortcutNotCaptured: "Nothing was captured. macOS or another app already uses that combination. Try another one.",
        shortcutConflictFormat: "This shortcut is already used by %@.",
        shortcutTakeOverOffer: "macOS uses %@ for one of its own shortcuts.",
        shortcutTakeOverAction: "Take over while Brim runs",
        shortcutTakeOverCaption: "macOS gets the key back whenever Brim is not running or this feature is off.",
        shortcutTakeOverDismiss: "Don’t take over",
        shortcutUnavailable: "macOS rejected this shortcut. Choose another one.",
        cleanerName: "Cleaner",
        cleanerIntroTitle: "Clean up your Mac",
        cleanerIntroCaption: "Scans for leftovers from uninstalled apps, caches, logs and the Trash. You review everything first and removed items go to the Trash.",
        cleanerScan: "Scan",
        cleanerScanning: "Scanning…",
        cleanerCleaning: "Cleaning…",
        cleanerCatLeftovers: "Leftovers from uninstalled apps",
        cleanerCatLoginItems: "Orphaned startup items",
        cleanerCatCaches: "Caches",
        cleanerCatLogs: "Logs",
        cleanerCatDeveloper: "Developer junk",
        cleanerCatTrash: "Trash",
        cleanerLeftoversNote: "Found by analysis and left unchecked. Check the path before ticking.",
        cleanerLoginItemsNote: "The entry under Login Items disappears after restarting the Mac.",
        cleanerTrashNote: "Emptying the Trash is permanent.",
        cleanerCatDeviceBackups: "iPhone backups",
        cleanerDeviceBackupsCaption: "Old iPhone and iPad backups take a big slice of the storage macOS calls Other. Remove only the ones you no longer need; a new backup is made when you plug the device in again.",
        cleanerCatScreenshots: "Forgotten screenshots",
        cleanerScreenshotsCaptionFormat: "Screenshots you have not opened in %d days that still have the name and folder macOS gave them. Ones you renamed or moved never show up here.",
        cleanerScreenshotsSettingCaption: "The scan lists the screenshots you have not opened for this long, unchecked, with their total size.",
        cleanerScreenshotsAfterFormat: "After %d days",
        cleanerNothingFound: "Nothing to clean. Your Mac is tidy.",
        cleanerDoneNote: "Items went to the Trash and can be recovered from there.",
        cleanerAgain: "Scan again",
        cleanerRevealInFinder: "Reveal in Finder",
        cleanerPanelCaption: "App leftovers, caches and logs",
        cleanerSafeSection: "Safe cleanup",
        cleanerOptionalSection: "Optional, review first",
        cleanerCatOtherCaches: "Other caches",
        cleanerCachesCaption: "Temporary files apps rebuild on their own.",
        cleanerLogsCaption: "Old diagnostic logs.",
        cleanerDeveloperCaption: "Xcode build and simulator leftovers.",
        cleanerLoginItemsCaption: "Startup entries left by apps that no longer exist.",
        cleanerLeftoversCaption: "Files left behind by apps you uninstalled.",
        cleanerOtherCachesCaption: "Safe to remove, nothing breaks. Apps may open slower once and downloaded content, like offline music, downloads again.",
        cleanerCleanSizeFormat: "Clean %@",
        cleanerScheduleTitle: "Automatic cleanup",
        cleanerScheduleOff: "Off",
        cleanerScheduleDaily: "Daily",
        cleanerScheduleWeekly: "Weekly",
        cleanerScheduleCaption: "Cleans only the safe part on its own at the chosen time and sends everything to the Trash.",
        cleanerScheduleLastFormat: "The last automatic cleanup freed %@.",
        cleanerAutoNotificationFormat: "%@ freed and sent to the Trash.",
        cleanerScheduleNextFormat: "Next cleanup %@.",
        cleanerScheduleRanFormat: "Last automatic cleanup %@.",
        cleanerScheduleNotifyToggle: "Notify when done",
        cleanerNotifDenied: "Brim notifications are turned off in the system.",
        cleanerNotifOpenSettings: "Open Notification Settings…",
        launchAtLoginNeedsApplications: "The app is running from a place that cannot open at login. Drag Brim to the Applications folder, open it from there and turn this on again.",
        launchAtLoginNeedsApproval: "The login item is registered, but macOS still needs your approval. In System Settings, allow Brim to open at login and to run in the background.",
        monitorOpenActivityMonitor: "Open Activity Monitor",
        monitorMemoryMetricLabel: "Measure memory as",
        memoryMetricUsed: "Memory Used",
        memoryMetricApp: "App Memory",
        keepAwakeRightClickToggle: "Right-click the menu bar icon to toggle Keep Awake",
        keepAwakeRightClickToggleCaption: "Replaces the right-click context menu.",
        uninstallerHomebrewPackageFormat: "%@ will also be removed from Homebrew.",
        uninstallerHomebrewCheckFailed: "Could not verify whether Homebrew manages this app. Refresh to try again, or uninstall it from Homebrew."
    )
}

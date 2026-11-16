// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Carbon.HIToolbox
import Foundation

/// Every UserDefaults key used by the app, in one place.
enum DefaultsKey {
    static let appearance = "appAppearance"               // AppAppearance.rawValue
    static let liquidGlassEnabled = "liquidGlassEnabled"  // Liquid Glass in windows and panels on macOS 26+
    static let notchLiquidGlassEnabled = "notchLiquidGlassEnabled" // Dynamic Island glass, independently controlled
    static let clamshellPreferred = "clamshellPreferred"  // apply closed-lid mode to every session
    static let dimScreenOnLidClose = "dimScreenOnLidClose" // dim the built-in display to zero while the lid is closed
    static let onboardingStep = "onboardingStep"          // resume point if onboarding is interrupted
    static let featuresOnboardingVersion = "featuresOnboardingVersion" // last feature-tour marker handled
    static let defaultDuration = "defaultDurationMinutes" // 0 = indefinite
    static let batteryLimit = "batteryLimitPercent"       // 0 = never
    static let keepAwakeAutoStart = "keepAwakeAutoStart"  // start Keep Awake when the app launches
    static let keepAwakeRightClickToggle = "keepAwakeRightClickToggle"
    static let keepAwakeAllowDisplaySleep = "keepAwakeAllowDisplaySleep"
    static let keepAwakeExternalDisplay = "keepAwakeExternalDisplay"
    static let keepAwakeConnectedToPower = "keepAwakeConnectedToPower"
    static let keepAwakeRunningApps = "keepAwakeRunningApps"
    static let keepAwakeRunningAppBundleIDs = "keepAwakeRunningAppBundleIDs"
    // Match mode over the automation conditions: false is Any (one matching
    // condition starts a session), true is All (every enabled condition has
    // to match, and losing one ends the session). Issue #1587.
    static let keepAwakeAutomationRequireAll = "keepAwakeAutomationRequireAll"
    static let keepAwakePauseWhenLocked = "keepAwakePauseWhenLocked"
    static let keepAwakeSwitchUsesUntil = "keepAwakeSwitchUsesUntil" // panel switch restarts the Until chip
    static let keepAwakeUntilTime = "keepAwakeUntilTime"  // last picked end time; 0 = none yet
    // The running manual session's end (0 = indefinite) and selected preset, if any.
    // Absent when there is no session to resume. Live state, never backed up.
    static let keepAwakeSessionEnd = "keepAwakeSessionEnd"
    static let keepAwakeMouseJiggleEnabled = "keepAwakeMouseJiggleEnabled"
    static let keepAwakeMouseJiggleInterval = "keepAwakeMouseJiggleIntervalMinutes"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let launchAtLoginWanted = "launchAtLoginWanted"  // the user's choice; the system record can be lost
    static let keepAwakeShortcut = "keepAwakeShortcut"    // GlobalShortcut storage value
    static let keepAwakeIconTint = "keepAwakeIconTint"    // KeepAwakeIconTint.rawValue
    static let keepAwakeActiveIcon = "keepAwakeActiveIcon" // KeepAwakeActiveIcon.rawValue
    static let showCountdown = "showCountdownInMenuBar"
    static let statusItemPlacementGeneration = "statusItemPlacementGeneration"
    static let hasOnboarded = "hasOnboarded"
    static let sleepDisabledFlag = "vorssDisabledSleep"   // internal guard for pmset disablesleep
    static let dimmedDisplaySavedBrightness = "vorssDimmedDisplaySavedBrightness" // internal guard for closed-lid screen dimming recovery
    // Machine state, never exported: the system shortcuts this process owns,
    // so a launch after a crash can restore them.
    static let systemShortcutsSuppressed = "systemShortcutsSuppressed"
    // Storage keys of shortcuts the user chose to take over from macOS. A
    // preference, exported.
    static let systemShortcutTakeOverKeys = "systemShortcutTakeOverKeys"
    // Set while a start is under way and cleared once the app has run
    // healthily for a while, or when it is quit properly. Found still set at
    // the next start, it means the previous one died on the way up.
    static let startupDidNotFinish = "startupDidNotFinish"
    static let cleanerScheduleFrequency = "cleanerScheduleFrequency"    // off | daily | weekly
    static let cleanerScheduleHour = "cleanerScheduleHour"
    static let cleanerScheduleMinute = "cleanerScheduleMinute"
    static let cleanerScheduleWeekday = "cleanerScheduleWeekday"        // 1 Sunday ... 7 Saturday
    static let cleanerScheduleNotify = "cleanerScheduleNotify"
    static let cleanerLastAutoRun = "cleanerLastAutoRun"                // Double, epoch seconds
    static let cleanerLastAutoFreed = "cleanerLastAutoFreed"            // Int bytes
    static let cleanerLastAutoFailed = "cleanerLastAutoFailed"          // Int items left in place
    static let cleanerScreenshotAgeDays = "cleanerScreenshotAgeDays"    // Int, 0 = off
    // Confirmed WhatsApp downloads in the top level of ~/Downloads.
    static let whatsAppDownloadsEnabled = "whatsAppDownloadsEnabled"
    static let whatsAppDownloadsAutomaticEnabled = "whatsAppDownloadsAutomaticEnabled"
    static let whatsAppDownloadsCategories = "whatsAppDownloadsCategories" // comma-joined category ids
    static let whatsAppDownloadsRetentionDays = "whatsAppDownloadsRetentionDays"
    static let whatsAppDownloadsNotify = "whatsAppDownloadsNotify"
    static let whatsAppDownloadsIncludeExisting = "whatsAppDownloadsIncludeExisting"
    static let whatsAppDownloadsAutomaticStartDate = "whatsAppDownloadsAutomaticStartDate"
    static let whatsAppDownloadsLastAutoRun = "whatsAppDownloadsLastAutoRun"
    static let whatsAppDownloadsLastCleanup = "whatsAppDownloadsLastCleanup"
    static let whatsAppDownloadsLastCleanupCount = "whatsAppDownloadsLastCleanupCount"
    static let whatsAppDownloadsLastCleanupBytes = "whatsAppDownloadsLastCleanupBytes"
    static let whatsAppDownloadsLastCleanupFailed = "whatsAppDownloadsLastCleanupFailed"
    static let whatsAppDownloadsLastCleanupAutomatic = "whatsAppDownloadsLastCleanupAutomatic"
    static let whatsAppDownloadsExclusions = "whatsAppDownloadsExclusions" // device:inode ids
    static let whatsAppDownloadsAccessConfirmed = "whatsAppDownloadsAccessConfirmed"
    // Experimental organizer for confirmed WhatsApp downloads.
    static let whatsAppOrganizerEnabled = "whatsAppOrganizerEnabled"
    static let whatsAppOrganizerDestinationPath = "whatsAppOrganizerDestinationPath"
    static let whatsAppOrganizerDelayMinutes = "whatsAppOrganizerDelayMinutes"
    static let whatsAppOrganizerCategories = "whatsAppOrganizerCategories"
    static let whatsAppOrganizerLayout = "whatsAppOrganizerLayout"
    static let whatsAppOrganizerDuplicateAction = "whatsAppOrganizerDuplicateAction"
    static let whatsAppOrganizerRecords = "whatsAppOrganizerRecords"
    static let whatsAppOrganizerUndoTransaction = "whatsAppOrganizerUndoTransaction"
    static let whatsAppOrganizerLastRun = "whatsAppOrganizerLastRun"
    static let whatsAppOrganizerLastMoved = "whatsAppOrganizerLastMoved"
    static let whatsAppOrganizerLastDuplicates = "whatsAppOrganizerLastDuplicates"
    static let whatsAppOrganizerLastFailed = "whatsAppOrganizerLastFailed"
    static let settingsWindowWidth = "settingsWindowWidth"     // last user-chosen content size (0 = unset)
    static let settingsWindowHeight = "settingsWindowHeight"
    static let panelUtilityUninstaller = "panelUtilityUninstaller"
    static let uninstallerWatchesTrash = "uninstallerWatchesTrash"
    static let killProcessGroupRelated = "killProcessGroupRelated"
    static let killProcessSortBy = "killProcessSortBy" // cpu | memory | name | pid
    static let killProcessSortAscending = "killProcessSortAscending"
    static let panelUtilityCleaner = "panelUtilityCleaner"
    static let panelUtilityHomebrew = "panelUtilityHomebrew"
    static let homebrewGroupDependencies = "homebrewGroupDependencies"
    static let panelUtilityAppUpdates = "panelUtilityAppUpdates"
    static let appUpdatesCheckFrequency = "appUpdatesCheckFrequency"  // off | daily | weekly
    static let appUpdatesIncludeHomebrewApps = "appUpdatesIncludeHomebrewApps"
    static let appUpdatesIncludeAppStore = "appUpdatesIncludeAppStore"
    static let appUpdatesIncludeOnlineCatalog = "appUpdatesIncludeOnlineCatalog"
    static let appUpdatesNotify = "appUpdatesNotify"
    static let appUpdatesRules = "appUpdatesRules" // JSON, portable bundle-ID rules
    static let appUpdatesLastCheck = "appUpdatesLastCheck"            // Double, epoch seconds
    static let appUpdatesLastCount = "appUpdatesLastCount"
    // Findings already announced once, so a pending update nobody installs
    // does not speak up again after every relaunch.
    static let appUpdatesNotifiedIDs = "appUpdatesNotifiedIDs"
    static let panelUtilityClipboard = "panelUtilityClipboard"
    // Show/hide whole panel sections that have no monitorShow* key of their own.
    static let panelShowKeepAwake = "panelShowKeepAwake"
    static let panelShowUtilities = "panelShowUtilities"
    static let panelShowControls = "panelShowControls"

    // System monitor — live metrics shown next to the menu bar icon (opt-in).
    static let menuBarCPU = "menuBarCPU"
    static let menuBarGPU = "menuBarGPU"
    static let menuBarMemory = "menuBarMemory"
    static let menuBarCPUTemperature = "menuBarCPUTemperature"
    static let menuBarGPUTemperature = "menuBarGPUTemperature"
    static let menuBarBatteryTemperature = "menuBarBatteryTemperature"
    static let menuBarNetwork = "menuBarNetwork"
    static let menuBarDiskUsage = "menuBarDiskUsage"
    static let menuBarDiskActivity = "menuBarDiskActivity"
    static let menuBarBattery = "menuBarBattery"
    static let menuBarBatteryTime = "menuBarBatteryTime"
    static let menuBarPeripheralBattery = "menuBarPeripheralBattery"
    static let menuBarConnectedDevices = "menuBarConnectedDevices"
    static let menuBarPower = "menuBarPower"
    static let menuBarFanSpeed = "menuBarFanSpeed"
    static let menuBarMetricSpacing = "menuBarMetricSpacing" // standard | compact
    static let menuBarMetricAppearance = "menuBarMetricAppearance" // values | bars
    static let menuBarUsageBarNormalColor = "menuBarUsageBarNormalColor" // #RRGGBB
    static let menuBarUsageBarElevatedColor = "menuBarUsageBarElevatedColor" // #RRGGBB
    static let menuBarUsageBarCriticalColor = "menuBarUsageBarCriticalColor" // #RRGGBB
    static let menuBarUsageBarMediumThreshold = "menuBarUsageBarMediumThreshold" // percent
    static let menuBarUsageBarHighThreshold = "menuBarUsageBarHighThreshold" // percent
    static let menuBarHideIconWithMetrics = "menuBarHideIconWithMetrics" // glyph hides while metrics render in the main item
    static let menuBarIconSymbol = "menuBarIconSymbol" // system symbol name drawn instead of the glyph; empty keeps the glyph
    static let menuBarMetricOrder = "menuBarMetricOrder" // comma-separated MenuBarMetric raw values
    static let menuBarCombineTemperatures = "menuBarCombineTemperatures" // usage/charge + temperature in one block when possible
    static let menuBarSeparateMetrics = "menuBarSeparateMetrics" // one status item per active metric
    static let menuBarNetworkUploadFirst = "menuBarNetworkUploadFirst" // network menu bar block shows upload above download
    static let menuBarLabelStyle = "menuBarLabelStyle"     // compact | classic
    static let menuBarMemoryStyle = "menuBarMemoryStyle"   // dot | percent | both
    static let menuBarDiskStyle = "menuBarDiskStyle"       // percent | free | used
    static let monitorMemoryMetric = "monitorMemoryMetric" // used | app
    static let monitorInterval = "monitorIntervalSeconds"  // sampling cadence: 1/2/5
    static let temperatureUnit = "temperatureUnit"          // celsius | fahrenheit
    // System monitor — which blocks appear in the panel.
    static let monitorShowSystem = "monitorShowSystem"
    static let monitorShowNetwork = "monitorShowNetwork"
    static let monitorShowDisk = "monitorShowDisk"
    static let monitorShowPower = "monitorShowPower"
    static let panelShowFanControl = "panelShowFanControl"
    static let fanControlMode = "fanControlMode"
    static let fanControlCoolingLevel = "fanControlCoolingLevel"
    static let fanControlCurves = "fanControlCurves"
    // Re-apply the last manual speed or curve when the app opens and after wake.
    static let fanControlResume = "fanControlResume"
    // Machine-only: the control the user left running while resume is on,
    // cleared when they return to System so it never outlives that choice.
    static let fanControlResumeConfiguration = "fanControlResumeConfiguration"
    // Machine-only recovery state. A true value means the helper must confirm
    // automatic fan control before this marker can be cleared.
    static let fanControlRecoveryNeeded = "fanControlRecoveryNeeded"
    static let fanControlHelperVersion = "fanControlHelperVersion"
    // System monitor — per-metric history graphs (each independently toggleable).
    static let monitorGraphCPU = "monitorGraphCPU"
    static let monitorGraphGPU = "monitorGraphGPU"
    static let monitorGraphMemory = "monitorGraphMemory"
    static let monitorGraphNetwork = "monitorGraphNetwork"
    static let monitorGraphDisk = "monitorGraphDisk"
    static let monitorGraphPower = "monitorGraphPower"
    static let monitorGraphBattery = "monitorGraphBattery"
    static let monitorGraphScale = "monitorGraphScale"
    // System monitor — per-item visibility inside each panel section.
    static let monitorSysTemps = "monitorSysTemps"
    static let monitorSysCPU = "monitorSysCPU"
    static let monitorSysCPUCores = "monitorSysCPUCores"
    static let monitorSysGPU = "monitorSysGPU"
    static let monitorSysBattery = "monitorSysBattery"
    static let monitorSysMemory = "monitorSysMemory"
    static let monitorSysAlerts = "monitorSysAlerts"
    static let monitorSysUptime = "monitorSysUptime"
    static let monitorSysConnectedDevices = "monitorSysConnectedDevices"
    static let monitorNetSpeed = "monitorNetSpeed"
    static let monitorNetApps = "monitorNetApps"
    static let monitorNetTotals = "monitorNetTotals"
    static let monitorNetAddresses = "monitorNetAddresses"
    static let monitorNetTest = "monitorNetTest"
    static let networkSpeedUnit = "networkSpeedUnit" // bytes | bits, for every live network speed readout
    static let monitorDiskUsage = "monitorDiskUsage"
    static let monitorDiskActivity = "monitorDiskActivity"
    static let monitorDiskSMART = "monitorDiskSMART"
    static let monitorDiskProtection = "monitorDiskProtection"
    static let monitorDiskTools = "monitorDiskTools"
    static let monitorPwrTemperature = "monitorPwrTemperature"
    static let monitorPwrSystem = "monitorPwrSystem"
    static let monitorPwrAdapter = "monitorPwrAdapter"
    static let monitorPwrBattery = "monitorPwrBattery"
    static let monitorPwrTimeRemaining = "monitorPwrTimeRemaining"
    static let monitorPwrHealth = "monitorPwrHealth"
    static let monitorPwrPeripherals = "monitorPwrPeripherals"
    // System monitor — optional notifications for sustained or actionable conditions.
    static let monitorAlertCPU = "monitorAlertCPU"
    static let monitorAlertCPUTemperature = "monitorAlertCPUTemperature"
    static let monitorAlertBatteryTemperature = "monitorAlertBatteryTemperature"
    static let monitorAlertDisk = "monitorAlertDisk"
    static let monitorAlertBattery = "monitorAlertBattery"
    static let monitorAlertCPUThreshold = "monitorAlertCPUThreshold"
    static let monitorAlertCPUTemperatureThreshold = "monitorAlertCPUTemperatureThreshold"
    static let monitorAlertBatteryTemperatureThreshold = "monitorAlertBatteryTemperatureThreshold"
    static let monitorAlertDiskFreePercent = "monitorAlertDiskFreePercent"
    static let monitorAlertBatteryPercent = "monitorAlertBatteryPercent"
    static let monitorAlertCooldownMinutes = "monitorAlertCooldownMinutes"
    // Menu panel layout — the order the major sections appear in and which are
    // collapsed, both comma-joined section ids (see PanelSectionID). Absent keys
    // mean the canonical order and nothing collapsed, so no defaults registration.
    static let panelSectionOrder = "panelSectionOrder"
    static let panelUtilityOrder = "panelUtilityOrder"
    static let panelSystemOrder = "panelSystemOrder"
    static let panelNetworkOrder = "panelNetworkOrder"
    static let panelDiskOrder = "panelDiskOrder"
    static let panelPowerOrder = "panelPowerOrder"
    static let panelCollapsedSections = "panelCollapsedSections"
    static let panelCollapsedResetVersion = "panelCollapsedResetVersion"

    // Clipboard history — text only, opt-in and local.
    static let clipboardHistoryEnabled = "clipboardHistoryEnabled"
    static let clipboardHistoryEntries = "clipboardHistoryEntries"
    static let clipboardHistoryLimit = "clipboardHistoryLimit"
    static let clipboardHistoryRetentionDays = "clipboardHistoryRetentionDays" // 0 keeps items until the limit drops them
    // A separate opt-in from the old, enabled-by-default text heuristic.
    static let clipboardHistoryFilterSensitiveText = "clipboardHistoryFilterSensitiveText"
    static let clipboardHistoryIncludeImagesFiles = "clipboardHistoryIncludeImagesFiles" // capture copied images and files too
    static let clipboardHistoryIgnoredApps = "clipboardHistoryIgnoredApps" // apps whose copies are never saved
    static let clipboardHistoryQuickPreview = "clipboardHistoryQuickPreview"
    static let clipboardHistoryShowSourceAppIcons = "clipboardHistoryShowSourceAppIcons" // source app icons beside list entries
    static let clipboardHistoryLayout = "clipboardHistoryLayout" // cards | list, how the history window shows entries
    static let clipboardHistoryWindowWidth = "clipboardHistoryWindowWidth" // the list window's chosen size
    static let clipboardHistoryWindowHeight = "clipboardHistoryWindowHeight"
    static let clipboardHistoryWindowX = "clipboardHistoryWindowX"
    static let clipboardHistoryWindowY = "clipboardHistoryWindowY"
    static let clipboardHistoryMenuBarPreview = "clipboardHistoryMenuBarPreview" // show latest copy next to the menu bar icon
    static let clipboardHistoryMenuBarPreviewLength = "clipboardHistoryMenuBarPreviewLength" // characters shown before truncating

    // Auto clear: wipes the system pasteboard on a delay or on sleep and lock.
    // Deliberately outside the clipboardHistory family, since it clears the
    // pasteboard without touching saved entries, and runs with capture off.
    static let clipboardAutoClearOnDelay = "clipboardAutoClearOnDelay"
    static let clipboardAutoClearDelay = "clipboardAutoClearDelaySeconds" // seconds since the last copy
    static let clipboardAutoClearOnSleep = "clipboardAutoClearOnSleep"
    static let clipboardAutoClearOnDisplaySleep = "clipboardAutoClearOnDisplaySleep"
    static let clipboardAutoClearOnScreenLock = "clipboardAutoClearOnScreenLock"

    static let diskEjectExcludedVolumes = "diskEjectExcludedVolumes" // volume names/UUIDs excluded from Eject all disks
    // Paste as plain text and the clipboard history shortcut.
    static let pastePlainEnabled = "pastePlainEnabled"
    static let pastePlainShortcut = "pastePlainShortcut"
    static let clipboardHistoryShortcutEnabled = "clipboardHistoryShortcutEnabled"
    static let clipboardHistoryShortcut = "clipboardHistoryShortcut"

    static let panelUtilityPortManager = "panelUtilityPortManager"

    // Optional top-of-screen workspace and activity presentations.
    static let notchIdleContent = "notchIdleContent"
    static let notchHiddenControls = "notchHiddenControls"
    static let notchControlOrder = "notchControlOrder"
    static let notchSize = "notchSize"
    static let notchOutlineEnabled = "notchOutlineEnabled"
    static let notchHideMenuBarGap = "notchHideMenuBarGap"
    static let notchCustomWidth = "notchCustomWidth"
    static let notchCustomHeight = "notchCustomHeight"
    // Fits the island to one Mac's camera housing; never backed up.
    static let notchCameraFitWidth = "notchCameraFitWidth"
    static let notchCameraFitHeight = "notchCameraFitHeight"
    static let notchHapticFeedback = "notchHapticFeedback"
    static let notchTranslucentBackground = "notchTranslucentBackground"
    static let notchAppPanel = "notchAppPanel"
    static let notchHidesMenuBarIcon = "notchHidesMenuBarIcon" // the island takes the glyph's place while it is on
    static let notchKeepAwakeActivity = "notchKeepAwakeActivity" // a running Keep Awake session in the closed island
    static let notchHoverExpands = "notchHoverExpands"
    // AI agents: what the island reads from Claude Code, Codex, OpenCode and GitHub Copilot, and shows.
    static let notchAgentsEnabled = "notchAgentsEnabled"
    static let notchAgentsClaude = "notchAgentsClaude"
    static let notchAgentsCodex = "notchAgentsCodex"
    /// The Codex homes, `CODEX_HOME` folders, that get limits cards of their own.
    static let notchAgentsCodexProfiles = "notchAgentsCodexProfiles"
    static let notchAgentsOpenCode = "notchAgentsOpenCode"
    static let notchAgentsCopilot = "notchAgentsCopilot"
    static let notchAgentsCardOrder = "notchAgentsCardOrder"
    static let notchAgentsHiddenCards = "notchAgentsHiddenCards"
    static let notchAgentsPeriod = "notchAgentsPeriod"
    static let notchAgentsLimitDisplay = "notchAgentsLimitDisplay"
    static let notchAgentsLimitFocus = "notchAgentsLimitFocus"
    static let notchAgentsLiveActivity = "notchAgentsLiveActivity"
    static let notchAgentsReadout = "notchAgentsReadout"
    static let notchAgentsFinishAlert = "notchAgentsFinishAlert"
    static let notchAgentsFinishMinimum = "notchAgentsFinishMinimum"
    static let notchAgentsLimitAlert = "notchAgentsLimitAlert"
    static let notchAgentsLimitThreshold = "notchAgentsLimitThreshold"
    static let notchAgentsDailyBudget = "notchAgentsDailyBudget"
    static let notchEnabled = "notchEnabled"
    static let notchDisplay = "notchDisplay"
    // How the island looks on a display without a camera housing.
    static let notchSilhouette = "notchSilhouette"
    // The capsule's size and place, fitted by hand on such a display.
    static let notchCapsuleFitWidth = "notchCapsuleFitWidth"
    static let notchCapsuleFitHeight = "notchCapsuleFitHeight"
    static let notchCapsuleFitDrop = "notchCapsuleFitDrop"
    static let notchOpenOnHover = "notchOpenOnHover"
    static let notchShortcutEnabled = "notchShortcutEnabled"
    static let notchShortcut = "notchShortcut"
    static let notchHideInFullscreen = "notchHideInFullscreen"
    static let notchHoverInFullscreen = "notchHoverInFullscreen"
    static let notchHideUntilHover = "notchHideUntilHover"
    static let notchHiddenShowsActivity = "notchHiddenShowsActivity"
    static let notchCoversMenus = "notchCoversMenus"
    static let notchLowBatteryTint = "notchLowBatteryTint"
    static let notchLowBatteryThreshold = "notchLowBatteryThreshold"
    static let notchLowBatteryEarly = "notchLowBatteryEarly"
    static let notchLowBatteryEarlyThreshold = "notchLowBatteryEarlyThreshold"
    static let notchLowBatteryMenuBar = "notchLowBatteryMenuBar"
    static let notchHoverDelay = "notchHoverDelay"
    static let notchCloseDelay = "notchCloseDelay"
    static let notchReturnHome = "notchReturnHome"
    static let notchHomeModule = "notchHomeModule"
    static let notchOpensActivity = "notchOpensActivity"
    static let notchHiddenModules = "notchHiddenModules"
    static let notchModuleOrder = "notchModuleOrder"
    static let notchQuickAccessLayout = "notchQuickAccessLayout"
    static let notchQuickAccessSide = "notchQuickAccessSide"
    static let notchQuickAccessSecond = "notchQuickAccessSecond"
    static let notchQuickAccessThird = "notchQuickAccessThird"
    static let notchInputSource = "notchInputSource"
    static let notchBattery = "notchBattery"
    static let notchClipboard = "notchClipboard"
    static let notchClipboardWindow = "notchClipboardWindow"
    static let notchClipboardCardSize = "notchClipboardCardSize"
    static let notchShowInCaptures = "notchShowInCaptures"
    static let notchLockScreen = "notchLockScreen" // working AI agents and the padlock over the lock screen
    static let notchLockSounds = "notchLockSounds" // padlock sounds as the Mac locks and unlocks
    static let panelControlNotch = "panelControlNotch"

    // Dev-build only: force the beta UI for local testing.
    static let simulateBetaUI = "simulateBetaUI"

    /// Features hub availability layer, one key per AppFeature raw value.
    /// Registered true: unavailable features vanish from every surface and
    /// hold no resources, without ever touching their own enable keys.
    static func featureAvailable(_ id: String) -> String { "featureAvailable.\(id)" }
}

/// Bump `currentFeatureSet` when first-run feature defaults need a quiet marker.
enum OnboardingInfo {
    // 2: system monitor, configurable panel and menu bar metrics.
    // 3: app languages and support settings.
    // 4: navigable menu panel sections.
    static let currentFeatureSet = 4
}

enum KeepAwakeIconTint: String, CaseIterable, Identifiable {
    case orange, green, blue, purple, pink, none

    var id: String { rawValue }

    static var current: KeepAwakeIconTint {
        Defaults.sanitizedKeepAwakeIconTint(
            UserDefaults.standard.string(forKey: DefaultsKey.keepAwakeIconTint)
        )
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .orange: return strings.keepAwakeIconTintOrange
        case .green: return strings.keepAwakeIconTintGreen
        case .blue: return strings.keepAwakeIconTintBlue
        case .purple: return strings.keepAwakeIconTintPurple
        case .pink: return strings.keepAwakeIconTintPink
        case .none: return strings.keepAwakeIconTintNone
        }
    }
}

enum KeepAwakeActiveIcon: String, CaseIterable, Identifiable {
    case brim, coffee, eye, moon, light

    var id: String { rawValue }

    static var current: KeepAwakeActiveIcon {
        Defaults.sanitizedKeepAwakeActiveIcon(
            UserDefaults.standard.string(forKey: DefaultsKey.keepAwakeActiveIcon)
        )
    }

    var systemSymbolName: String? {
        switch self {
        case .brim: return nil
        case .coffee: return "cup.and.saucer.fill"
        case .eye: return "eye.fill"
        case .moon: return "moon.fill"
        case .light: return "lightbulb.fill"
        }
    }

    /// Nudge down the menu bar canvas, in points. Symbols carrying their mass
    /// above the shape's middle — steam over a cup, a bulb over its base — read
    /// as sitting high when their ink is centered geometrically.
    var menuBarDrop: CGFloat {
        switch self {
        case .coffee: return 1
        case .light: return 0.5
        case .brim, .eye, .moon: return 0
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .brim: return strings.keepAwakeActiveIconBrim
        case .coffee: return strings.keepAwakeActiveIconCoffee
        case .eye: return strings.keepAwakeActiveIconEye
        case .moon: return strings.keepAwakeActiveIconMoon
        case .light: return strings.keepAwakeActiveIconLight
        }
    }
}

enum Defaults {

    static let allowedDurations = [0, 15, 30, 60, 120, 240, 480]
    static let allowedKeepAwakeMouseJiggleIntervals = [1, 2, 5, 10, 15]
    static let allowedBatteryLimits = [0, 5, 10, 15, 20]
    static let allowedMonitorIntervals = [1, 2, 5]
    static let allowedMenuBarMetricSpacings = ["standard", "compact"]
    static let allowedMenuBarMetricAppearances = ["values", "bars"]
    static let defaultMenuBarMetricOrder = [
        "cpu", "cpuTemperature",
        "gpu", "gpuTemperature",
        "memory",
        "battery", "batteryTime", "batteryTemperature", "peripheralBattery",
        "network", "diskUsage", "diskActivity", "connectedDevices", "power", "fanSpeed",
    ]
    static let allowedMenuBarLabelStyles = ["compact", "classic"]
    static let allowedMenuBarMemoryStyles = ["dot", "percent", "both"]
    static let allowedMonitorMemoryMetrics = ["used", "app"]
    static let allowedClipboardHistoryLimits = [20, 50, 100, 250, 500, 1_000, 10_000, 0]
    static let allowedClipboardHistoryRetentionDays = [1, 7, 30, 90, 365, 0]
    static let allowedClipboardAutoClearDelayRange = 5...3_600
    static let defaultClipboardAutoClearDelay = 20
    static let allowedClipboardMenuBarPreviewLengthRange = 5...50
    static let defaultClipboardMenuBarPreviewLength = 20
    static let allowedMonitorAlertCooldowns = [2, 5, 15, 30, 60]

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.appearance: AppAppearance.fallback.rawValue,
        DefaultsKey.liquidGlassEnabled: false,
        DefaultsKey.notchLiquidGlassEnabled: false,
        DefaultsKey.clamshellPreferred: false,
        DefaultsKey.dimScreenOnLidClose: false,
        DefaultsKey.defaultDuration: 0,
        DefaultsKey.batteryLimit: 10,
        DefaultsKey.keepAwakeAutoStart: false,
        DefaultsKey.keepAwakeRightClickToggle: false,
        DefaultsKey.keepAwakeAllowDisplaySleep: false,
        DefaultsKey.keepAwakeExternalDisplay: false,
        DefaultsKey.keepAwakeConnectedToPower: false,
        DefaultsKey.keepAwakeRunningApps: false,
        DefaultsKey.keepAwakeRunningAppBundleIDs: [String](),
        DefaultsKey.keepAwakeAutomationRequireAll: false,
        DefaultsKey.keepAwakePauseWhenLocked: false,
        DefaultsKey.keepAwakeSwitchUsesUntil: false,
        DefaultsKey.keepAwakeUntilTime: 0.0,
        DefaultsKey.keepAwakeMouseJiggleEnabled: false,
        DefaultsKey.keepAwakeMouseJiggleInterval: 5,
        DefaultsKey.hotkeyEnabled: true,
        DefaultsKey.launchAtLoginWanted: false,
        DefaultsKey.keepAwakeShortcut: "control+option+command:40",
        DefaultsKey.keepAwakeIconTint: KeepAwakeIconTint.orange.rawValue,
        DefaultsKey.keepAwakeActiveIcon: KeepAwakeActiveIcon.brim.rawValue,
        DefaultsKey.showCountdown: false,
        DefaultsKey.cleanerScheduleFrequency: "off",
        DefaultsKey.cleanerScheduleHour: 9,
        DefaultsKey.cleanerScheduleMinute: 0,
        DefaultsKey.cleanerScheduleWeekday: 2,
        DefaultsKey.cleanerScheduleNotify: true,
        DefaultsKey.cleanerLastAutoRun: 0.0,
        DefaultsKey.cleanerLastAutoFreed: 0,
        DefaultsKey.cleanerLastAutoFailed: 0,
        DefaultsKey.cleanerScreenshotAgeDays: CleanerPolicy.defaultScreenshotAgeDays,
        DefaultsKey.whatsAppDownloadsEnabled: false,
        DefaultsKey.whatsAppDownloadsAutomaticEnabled: false,
        DefaultsKey.whatsAppDownloadsCategories: "image,video,audio",
        DefaultsKey.whatsAppDownloadsRetentionDays: 7,
        DefaultsKey.whatsAppDownloadsNotify: true,
        DefaultsKey.whatsAppDownloadsIncludeExisting: false,
        DefaultsKey.whatsAppDownloadsAutomaticStartDate: 0.0,
        DefaultsKey.whatsAppDownloadsLastAutoRun: 0.0,
        DefaultsKey.whatsAppDownloadsLastCleanup: 0.0,
        DefaultsKey.whatsAppDownloadsLastCleanupCount: 0,
        DefaultsKey.whatsAppDownloadsLastCleanupBytes: 0,
        DefaultsKey.whatsAppDownloadsLastCleanupFailed: 0,
        DefaultsKey.whatsAppDownloadsLastCleanupAutomatic: false,
        DefaultsKey.whatsAppDownloadsExclusions: [String](),
        DefaultsKey.whatsAppDownloadsAccessConfirmed: false,
        DefaultsKey.whatsAppOrganizerEnabled: false,
        DefaultsKey.whatsAppOrganizerDestinationPath: "",
        DefaultsKey.whatsAppOrganizerDelayMinutes: 5,
        DefaultsKey.whatsAppOrganizerCategories: "image,video,audio,document,archive,other",
        DefaultsKey.whatsAppOrganizerLayout: "flat",
        DefaultsKey.whatsAppOrganizerDuplicateAction: "trashNew",
        DefaultsKey.whatsAppOrganizerRecords: Data(),
        DefaultsKey.whatsAppOrganizerUndoTransaction: Data(),
        DefaultsKey.whatsAppOrganizerLastRun: 0.0,
        DefaultsKey.whatsAppOrganizerLastMoved: 0,
        DefaultsKey.whatsAppOrganizerLastDuplicates: 0,
        DefaultsKey.whatsAppOrganizerLastFailed: 0,
        DefaultsKey.notchIdleContent: NotchIdleContent.none.rawValue,
        DefaultsKey.notchHiddenControls: NotchControlItem.defaultHidden,
        DefaultsKey.notchControlOrder: "",
        DefaultsKey.notchSize: NotchSize.spacious.rawValue,
        DefaultsKey.notchOutlineEnabled: false,
        DefaultsKey.notchHideMenuBarGap: false,
        DefaultsKey.notchCustomWidth: NotchSize.defaultWidth,
        DefaultsKey.notchCustomHeight: NotchSize.defaultHeight,
        DefaultsKey.notchCameraFitWidth: 0.0,
        DefaultsKey.notchCameraFitHeight: 0.0,
        DefaultsKey.notchHapticFeedback: true,
        DefaultsKey.notchTranslucentBackground: false,
        DefaultsKey.notchAppPanel: false,
        DefaultsKey.notchHidesMenuBarIcon: false,
        DefaultsKey.notchKeepAwakeActivity: false,
        DefaultsKey.notchHoverExpands: true,
        DefaultsKey.notchAgentsEnabled: false,
        DefaultsKey.notchAgentsClaude: true,
        DefaultsKey.notchAgentsCodex: true,
        DefaultsKey.notchAgentsCodexProfiles: "",
        DefaultsKey.notchAgentsOpenCode: true,
        DefaultsKey.notchAgentsCopilot: true,
        DefaultsKey.notchAgentsCardOrder: "",
        DefaultsKey.notchAgentsHiddenCards: "",
        DefaultsKey.notchAgentsPeriod: AgentPeriod.today.rawValue,
        DefaultsKey.notchAgentsLimitDisplay: NotchAgentLimitDisplay.remaining.rawValue,
        DefaultsKey.notchAgentsLimitFocus: NotchAgentLimitFocus.mostUsed.rawValue,
        DefaultsKey.notchAgentsLiveActivity: true,
        DefaultsKey.notchAgentsReadout: NotchAgentReadout.elapsed.rawValue,
        DefaultsKey.notchAgentsFinishAlert: true,
        DefaultsKey.notchAgentsFinishMinimum: NotchAgentSupport.defaultFinishMinimum,
        DefaultsKey.notchAgentsLimitAlert: true,
        DefaultsKey.notchAgentsLimitThreshold: NotchAgentSupport.defaultLimitThreshold,
        DefaultsKey.notchAgentsDailyBudget: 0.0,
        DefaultsKey.notchEnabled: false,
        DefaultsKey.notchDisplay: NotchDisplay.automatic.rawValue,
        DefaultsKey.notchSilhouette: NotchSilhouette.capsule.rawValue,
        DefaultsKey.notchCapsuleFitWidth: 0.0,
        DefaultsKey.notchCapsuleFitHeight: 0.0,
        DefaultsKey.notchCapsuleFitDrop: 0.0,
        DefaultsKey.notchOpenOnHover: false,
        DefaultsKey.notchShortcutEnabled: false,
        DefaultsKey.notchShortcut: GlobalShortcut.notchDefault.storageValue,
        DefaultsKey.notchHideInFullscreen: false,
        DefaultsKey.notchHoverInFullscreen: false,
        DefaultsKey.notchHideUntilHover: false,
        DefaultsKey.notchHiddenShowsActivity: false,
        DefaultsKey.notchCoversMenus: true,
        DefaultsKey.notchLowBatteryTint: false,
        DefaultsKey.notchLowBatteryThreshold: NotchSupport.defaultLowBatteryThreshold,
        DefaultsKey.notchLowBatteryEarly: false,
        DefaultsKey.notchLowBatteryEarlyThreshold: NotchSupport.defaultEarlyBatteryThreshold,
        DefaultsKey.notchLowBatteryMenuBar: true,
        DefaultsKey.notchHoverDelay: NotchSupport.defaultHoverDelay,
        DefaultsKey.notchCloseDelay: NotchSupport.defaultCloseDelay,
        DefaultsKey.notchReturnHome: false,
        DefaultsKey.notchHomeModule: NotchModule.controls.rawValue,
        DefaultsKey.notchOpensActivity: true,
        DefaultsKey.notchHiddenModules: "",
        DefaultsKey.notchModuleOrder: "",
        DefaultsKey.notchQuickAccessLayout: Data(),
        DefaultsKey.notchInputSource: true,
        DefaultsKey.notchBattery: true,
        DefaultsKey.notchClipboard: true,
        DefaultsKey.notchClipboardWindow: true,
        DefaultsKey.notchClipboardCardSize: NotchClipboardCardSize.comfortable.rawValue,
        DefaultsKey.notchShowInCaptures: true,
        DefaultsKey.notchLockScreen: false,
        DefaultsKey.notchLockSounds: false,
        DefaultsKey.panelControlNotch: true,
        DefaultsKey.panelUtilityUninstaller: true,
        DefaultsKey.uninstallerWatchesTrash: false,
        DefaultsKey.killProcessGroupRelated: true,
        DefaultsKey.killProcessSortBy: "cpu",
        DefaultsKey.killProcessSortAscending: false,
        DefaultsKey.panelUtilityCleaner: true,
        DefaultsKey.panelUtilityHomebrew: true,
        DefaultsKey.homebrewGroupDependencies: true,
        DefaultsKey.panelUtilityAppUpdates: true,
        // The list itself costs nothing until it is opened; only the
        // background check keeps a timer, so it starts off.
        DefaultsKey.appUpdatesCheckFrequency: AppUpdatesSupport.CheckFrequency.off.rawValue,
        DefaultsKey.appUpdatesIncludeHomebrewApps: true,
        DefaultsKey.appUpdatesIncludeAppStore: true,
        DefaultsKey.appUpdatesIncludeOnlineCatalog: true,
        DefaultsKey.appUpdatesNotify: true,
        DefaultsKey.appUpdatesRules: "[]",
        DefaultsKey.appUpdatesLastCheck: 0.0,
        DefaultsKey.appUpdatesLastCount: 0,
        DefaultsKey.appUpdatesNotifiedIDs: [String](),
        DefaultsKey.panelUtilityClipboard: true,
        DefaultsKey.panelShowKeepAwake: true,
        DefaultsKey.panelShowUtilities: true,
        DefaultsKey.panelShowControls: true,
        // Menu bar metrics start off (the icon stays clean) and are opt-in.
        // The panel shows every monitoring block by default; users hide what
        // they don't want.
        DefaultsKey.monitorInterval: 2,
        DefaultsKey.temperatureUnit: TemperatureUnit.celsius.rawValue,
        DefaultsKey.menuBarCPUTemperature: false,
        DefaultsKey.menuBarGPUTemperature: false,
        DefaultsKey.menuBarBatteryTemperature: false,
        DefaultsKey.menuBarBatteryTime: false,
        DefaultsKey.menuBarDiskUsage: false,
        DefaultsKey.menuBarDiskActivity: false,
        DefaultsKey.menuBarPeripheralBattery: false,
        DefaultsKey.menuBarConnectedDevices: false,
        DefaultsKey.menuBarFanSpeed: false,
        DefaultsKey.menuBarMetricSpacing: "compact",  // owner's call: compact by default in 3.1.8
        DefaultsKey.menuBarMetricAppearance: "values",
        DefaultsKey.menuBarUsageBarNormalColor: "#64D2FF",
        DefaultsKey.menuBarUsageBarElevatedColor: "#FFD60A",
        DefaultsKey.menuBarUsageBarCriticalColor: "#FF453A",
        DefaultsKey.menuBarUsageBarMediumThreshold: 70,
        DefaultsKey.menuBarUsageBarHighThreshold: 90,
        DefaultsKey.menuBarHideIconWithMetrics: false,
        DefaultsKey.menuBarIconSymbol: "",
        DefaultsKey.menuBarMetricOrder: defaultMenuBarMetricOrder.joined(separator: ","),
        DefaultsKey.menuBarCombineTemperatures: true,
        DefaultsKey.menuBarSeparateMetrics: false,
        DefaultsKey.menuBarNetworkUploadFirst: false,
        DefaultsKey.menuBarLabelStyle: "compact",
        DefaultsKey.menuBarMemoryStyle: "percent",
        DefaultsKey.menuBarDiskStyle: "percent",
        DefaultsKey.monitorMemoryMetric: "used",
        DefaultsKey.monitorShowSystem: true,
        DefaultsKey.monitorShowNetwork: true,
        DefaultsKey.monitorShowDisk: true,
        DefaultsKey.monitorShowPower: true,
        DefaultsKey.panelShowFanControl: true,
        DefaultsKey.fanControlMode: FanControlMode.system.rawValue,
        DefaultsKey.fanControlCoolingLevel: FanControlPolicy.defaultCoolingLevel,
        DefaultsKey.fanControlCurves: FanControlConfiguration.defaultCurvesStorage,
        DefaultsKey.fanControlResume: false,
        DefaultsKey.fanControlResumeConfiguration: "",
        DefaultsKey.fanControlRecoveryNeeded: false,
        DefaultsKey.fanControlHelperVersion: "",
        DefaultsKey.monitorGraphCPU: true,
        DefaultsKey.monitorGraphGPU: true,
        DefaultsKey.monitorGraphMemory: true,
        DefaultsKey.monitorGraphNetwork: true,
        DefaultsKey.monitorGraphDisk: true,
        DefaultsKey.monitorGraphPower: true,
        DefaultsKey.monitorGraphBattery: true,
        DefaultsKey.monitorGraphScale: true,
        // Every per-item block shows by default; users hide what they don't want.
        DefaultsKey.monitorSysTemps: true,
        DefaultsKey.monitorSysCPU: true,
        DefaultsKey.monitorSysCPUCores: true,
        DefaultsKey.monitorSysGPU: true,
        DefaultsKey.monitorSysBattery: true,
        DefaultsKey.monitorSysMemory: true,
        DefaultsKey.monitorSysAlerts: true,
        DefaultsKey.monitorSysUptime: true,
        DefaultsKey.monitorSysConnectedDevices: true,
        DefaultsKey.monitorNetSpeed: true,
        DefaultsKey.monitorNetApps: true,
        DefaultsKey.monitorNetTotals: true,
        DefaultsKey.monitorNetAddresses: true,
        DefaultsKey.monitorNetTest: true,
        DefaultsKey.networkSpeedUnit: NetworkSpeedUnit.bytes.rawValue,
        DefaultsKey.monitorDiskUsage: true,
        DefaultsKey.monitorDiskActivity: true,
        DefaultsKey.monitorDiskSMART: true,
        DefaultsKey.monitorDiskProtection: true,
        DefaultsKey.monitorDiskTools: true,
        DefaultsKey.monitorPwrTemperature: true,
        DefaultsKey.monitorPwrSystem: true,
        DefaultsKey.monitorPwrAdapter: true,
        DefaultsKey.monitorPwrBattery: true,
        DefaultsKey.monitorPwrTimeRemaining: true,
        DefaultsKey.monitorPwrHealth: true,
        DefaultsKey.monitorPwrPeripherals: false,
        DefaultsKey.monitorAlertCPU: false,
        DefaultsKey.monitorAlertCPUTemperature: false,
        DefaultsKey.monitorAlertBatteryTemperature: false,
        DefaultsKey.memoryNotify: true,
        DefaultsKey.monitorAlertDisk: false,
        DefaultsKey.monitorAlertBattery: false,
        DefaultsKey.monitorAlertCPUThreshold: 90,
        DefaultsKey.monitorAlertCPUTemperatureThreshold: 90,
        DefaultsKey.monitorAlertBatteryTemperatureThreshold: 40,
        DefaultsKey.monitorAlertDiskFreePercent: 10,
        DefaultsKey.monitorAlertBatteryPercent: 15,
        DefaultsKey.monitorAlertCooldownMinutes: 15,
        DefaultsKey.clipboardHistoryEnabled: false,
        DefaultsKey.clipboardHistoryLimit: 50,
        DefaultsKey.clipboardHistoryRetentionDays: 0,
        DefaultsKey.clipboardHistoryFilterSensitiveText: false,
        DefaultsKey.clipboardHistoryIncludeImagesFiles: true,
        DefaultsKey.clipboardHistoryIgnoredApps: [String](),
        DefaultsKey.clipboardHistoryQuickPreview: false,
        DefaultsKey.clipboardHistoryShowSourceAppIcons: false,
        DefaultsKey.clipboardHistoryLayout: ClipboardHistoryLayout.list.rawValue,
        DefaultsKey.clipboardHistoryWindowWidth: 0.0,
        DefaultsKey.clipboardHistoryWindowHeight: 0.0,
        DefaultsKey.clipboardHistoryMenuBarPreview: false,
        DefaultsKey.clipboardHistoryMenuBarPreviewLength: Defaults.defaultClipboardMenuBarPreviewLength,
        DefaultsKey.clipboardAutoClearOnDelay: false,
        DefaultsKey.clipboardAutoClearDelay: Defaults.defaultClipboardAutoClearDelay,
        DefaultsKey.clipboardAutoClearOnSleep: false,
        DefaultsKey.clipboardAutoClearOnDisplaySleep: false,
        DefaultsKey.clipboardAutoClearOnScreenLock: false,
        DefaultsKey.diskEjectExcludedVolumes: [String](),
        DefaultsKey.pastePlainEnabled: false,
        DefaultsKey.pastePlainShortcut: GlobalShortcut.pastePlainDefault.storageValue,
        DefaultsKey.clipboardHistoryShortcutEnabled: true,
        DefaultsKey.clipboardHistoryShortcut: GlobalShortcut.clipboardDefault.storageValue,
        DefaultsKey.panelUtilityPortManager: true,
    ]

    static func register() {
        let defaults = UserDefaults.standard
        migrateClipboardSensitiveTextOptIn(in: defaults)
        migrateLiquidGlassIsland(in: defaults)
        migrateWhatsAppDownloadsEnabled(in: defaults)
        migrateBatteryTemperatureVisibility(in: defaults)
        migratePowerPeripheralsVisibility(in: defaults)
        migrateMonitorAlertMemory(in: defaults)
        defaults.register(defaults: registeredDefaults)
        defaults.register(defaults: AppFeature.availabilityDefaults)
        migrateUtilityOrderForAppUpdates(in: defaults)
    }

    /// Start text filtering off for existing installations as well. A distinct
    /// key keeps older backups from re-enabling the previous on-by-default
    /// heuristic, while preserving choices made after this update.
    static func migrateClipboardSensitiveTextOptIn(in defaults: UserDefaults) {
        defaults.removeObject(forKey: "clipboardHistorySkipSensitive")
    }

    /// Existing users keep the island's previous glass choice. The island
    /// value is saved once, even when off, so turning on glass for other
    /// windows later never reaches the island on the next launch.
    static func migrateLiquidGlassIsland(in defaults: UserDefaults,
                                         domainName: String? = Bundle.main.bundleIdentifier) {
        guard let domainName else { return }
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        guard saved[DefaultsKey.notchLiquidGlassEnabled] == nil else { return }
        defaults.set(saved[DefaultsKey.liquidGlassEnabled] as? Bool ?? false,
                     forKey: DefaultsKey.notchLiquidGlassEnabled)
    }

    static func migrateBatteryTemperatureVisibility(in defaults: UserDefaults) {
        guard defaults.object(forKey: DefaultsKey.monitorPwrTemperature) == nil else { return }
        defaults.set(defaults.object(forKey: DefaultsKey.monitorSysTemps) as? Bool ?? true,
                     forKey: DefaultsKey.monitorPwrTemperature)
    }

    /// The Power card listed peripheral batteries only while the menu bar
    /// showed them. Copy that choice once, before defaults are registered,
    /// so an update keeps the same card and starts no Bluetooth reads that
    /// were not running. The value is saved even when off: turning on the
    /// menu bar item later must not change the card at the next launch.
    static func migratePowerPeripheralsVisibility(in defaults: UserDefaults) {
        guard defaults.object(forKey: DefaultsKey.monitorPwrPeripherals) == nil else { return }
        defaults.set(defaults.bool(forKey: DefaultsKey.menuBarPeripheralBattery),
                     forKey: DefaultsKey.monitorPwrPeripherals)
    }

    /// The Monitor's critical-memory alert is gone: the Memory module's
    /// notification is the one memory notification. Someone who had the old
    /// alert on keeps being notified (on is also the new default), and the
    /// old key goes.
    static func migrateMonitorAlertMemory(in defaults: UserDefaults) {
        let oldKey = "monitorAlertMemory"
        guard defaults.object(forKey: oldKey) != nil else { return }
        if defaults.bool(forKey: oldKey) { defaults.set(true, forKey: DefaultsKey.memoryNotify) }
        defaults.removeObject(forKey: oldKey)
    }

    /// The downloads cleanup for a messaging app used to sit in Cleaner for
    /// everyone. Keep it visible only when someone already turned automatic
    /// cleanup or the organizer on; everyone else gets the new off-by-default
    /// choice.
    static func migrateWhatsAppDownloadsEnabled(in defaults: UserDefaults) {
        guard defaults.object(forKey: DefaultsKey.whatsAppDownloadsEnabled) == nil else {
            return
        }
        let alreadyUsing = defaults.bool(forKey: DefaultsKey.whatsAppDownloadsAutomaticEnabled)
            || defaults.bool(forKey: DefaultsKey.whatsAppOrganizerEnabled)
        if alreadyUsing {
            defaults.set(true, forKey: DefaultsKey.whatsAppDownloadsEnabled)
        }
    }

    /// App updates joins the panel next to the other app-management tools
    /// instead of at the end of a long list, without disturbing the rest of
    /// a layout the user arranged.
    static func migrateUtilityOrderForAppUpdates(in defaults: UserDefaults) {
        guard let storedOrder = defaults.object(forKey: DefaultsKey.panelUtilityOrder) as? String else {
            return
        }
        defaults.set(utilityOrderWithAppUpdates(storedOrder).joined(separator: ","),
                     forKey: DefaultsKey.panelUtilityOrder)
    }

    static func utilityOrderWithAppUpdates(_ storedOrder: String) -> [String] {
        var ids = storedOrder.split(separator: ",").map(String.init)
        guard !ids.contains("appUpdates") else { return ids }
        let anchor = ids.firstIndex(of: "cleaner") ?? min(1, ids.count)
        ids.insert("appUpdates", at: anchor)
        return ids
    }

    static func sanitizedDefaultDuration(_ minutes: Int) -> Int {
        allowedDurations.contains(minutes) ? minutes : 0
    }

    static func sanitizedBatteryLimit(_ percent: Int) -> Int {
        allowedBatteryLimits.contains(percent) ? percent : 10
    }

    static func sanitizedKeepAwakeMouseJiggleInterval(_ minutes: Int) -> Int {
        allowedKeepAwakeMouseJiggleIntervals.contains(minutes) ? minutes : 5
    }

    static func sanitizedKeepAwakeIconTint(_ rawValue: String?) -> KeepAwakeIconTint {
        guard let rawValue,
              let tint = KeepAwakeIconTint(rawValue: rawValue) else {
            return .orange
        }
        return tint
    }

    static func sanitizedKeepAwakeActiveIcon(_ rawValue: String?) -> KeepAwakeActiveIcon {
        guard let rawValue,
              let icon = KeepAwakeActiveIcon(rawValue: rawValue) else {
            return .brim
        }
        return icon
    }

    /// A typed symbol name without the spaces around it; empty keeps the
    /// Brim glyph. Whether this Mac has the symbol is left to the menu
    /// bar drawing, since a backup can carry a name from a newer macOS.
    static func sanitizedMenuBarIconSymbol(_ rawValue: String?) -> String {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// What the menu bar icon field saves as it is typed: a name this Mac has
    /// a symbol for, nothing for the Brim icon, and otherwise the name
    /// the field opened with, so a typo never leaves a valid half behind.
    static func menuBarIconSymbolToSave(typed: String?, opening: String,
                                        exists: (String) -> Bool) -> String {
        let name = sanitizedMenuBarIconSymbol(typed)
        return name.isEmpty || exists(name) ? name : opening
    }

    /// The symbols the menu bar icon gallery offers after the Brim icon:
    /// solid shapes that still read at menu bar size, all present on macOS 14
    /// (some under older names, which later versions still accept). Keep
    /// Awake's symbols stay out, so an active session still stands out.
    static let menuBarIconGallery = [
        "bolt.fill", "star.fill", "heart.fill", "flame.fill", "sparkles", "leaf.fill",
        "drop.fill", "snowflake", "sun.max.fill", "moon.stars.fill", "cloud.fill", "mountain.2.fill",
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill",
        "circle.lefthalf.filled", "circle.hexagongrid.fill", "infinity",
        "command", "cpu.fill", "memorychip.fill", "gauge.with.dots.needle.67percent",
        "fanblades.fill", "gearshape.fill", "terminal.fill", "waveform",
        "wand.and.stars", "key.fill", "crown.fill", "gamecontroller.fill", "headphones",
        "music.note", "paperplane.fill", "pawprint.fill", "cat.fill", "hare.fill", "tortoise.fill",
    ]

    static func sanitizedMonitorInterval(_ seconds: Int) -> Int {
        allowedMonitorIntervals.contains(seconds) ? seconds : 2
    }

    /// Clamps rather than falling back to the default: a typed 4 becoming 5 is
    /// the correction the person meant, a typed 4 becoming 20 is not.
    static func sanitizedClipboardAutoClearDelay(_ seconds: Int) -> Int {
        min(max(seconds, allowedClipboardAutoClearDelayRange.lowerBound),
            allowedClipboardAutoClearDelayRange.upperBound)
    }

    /// Same clamping reasoning as sanitizedClipboardAutoClearDelay above.
    static func sanitizedClipboardMenuBarPreviewLength(_ characters: Int) -> Int {
        min(max(characters, allowedClipboardMenuBarPreviewLengthRange.lowerBound),
            allowedClipboardMenuBarPreviewLengthRange.upperBound)
    }

    static func sanitizedMenuBarMetricSpacing(_ spacing: String) -> String {
        // Corrupt values fall back to the registered default (compact).
        allowedMenuBarMetricSpacings.contains(spacing) ? spacing : "compact"
    }

    static func sanitizedMenuBarMetricAppearance(_ appearance: String) -> String {
        allowedMenuBarMetricAppearances.contains(appearance) ? appearance : "values"
    }

    static func sanitizedMenuBarMetricOrder(_ raw: String) -> [String] {
        let defaults = defaultMenuBarMetricOrder
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in raw.split(separator: ",").map({ String($0) }) {
            let values = rawValue == "temperature"
                ? ["cpuTemperature", "gpuTemperature", "batteryTemperature"]
                : [rawValue]
            for value in values {
                guard defaults.contains(value), !seen.contains(value) else { continue }
                seen.insert(value)
                result.append(value)
            }
        }
        for value in defaults where !seen.contains(value) {
            result.append(value)
        }
        return result
    }

    static func sanitizedMenuBarLabelStyle(_ style: String) -> String {
        allowedMenuBarLabelStyles.contains(style) ? style : "compact"
    }

    static func sanitizedMenuBarMemoryStyle(_ style: String) -> String {
        allowedMenuBarMemoryStyles.contains(style) ? style : "percent"
    }

    static func sanitizedMonitorMemoryMetric(_ metric: String) -> String {
        allowedMonitorMemoryMetrics.contains(metric) ? metric : "used"
    }

    static func sanitizedClipboardHistoryLimit(_ value: Int) -> Int {
        allowedClipboardHistoryLimits.contains(value) ? value : 50
    }

    static func sanitizedClipboardHistoryRetentionDays(_ value: Int) -> Int {
        allowedClipboardHistoryRetentionDays.contains(value) ? value : 0
    }

    static func sanitizedMonitorAlertCooldown(_ value: Int) -> Int {
        allowedMonitorAlertCooldowns.contains(value) ? value : 15
    }

    static func sanitizedPercent(_ value: Int, fallback: Int, range: ClosedRange<Int>) -> Int {
        range.contains(value) ? value : fallback
    }

    static func sanitizedBundleIdentifierList(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bundleIDs {
            // A mouse exception list also carries the path of a program that
            // has no bundle identifier (issue #1009), and a file name may
            // legally end in a space. Trimming one would store a spelling the
            // running program never reports, so only an identifier is trimmed.
            let bundleID = AppIdentity.isExecutablePathIdentity(raw)
                ? raw
                : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(bundleID)
        }
        return result
    }

    static func sanitizedDiskExclusionList(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in list {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = item.lowercased()
            guard !item.isEmpty, seen.insert(lower).inserted else { continue }
            result.append(item)
        }
        return result
    }

    static func sanitizedPanelItemOrder(_ raw: String, defaultOrder: [String]) -> [String] {
        let allowed = Set(defaultOrder)
        var seen = Set<String>()
        var result: [String] = []
        for id in raw.split(separator: ",").map(String.init) {
            guard allowed.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in defaultOrder where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

}

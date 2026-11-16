// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Every feature the Features hub can switch off entirely. The raw value is
/// the stable identity persisted inside the availability key, so cases can be
/// added but never renamed.
///
/// Availability is a layer ABOVE each feature's own enable key: an unavailable
/// feature disappears from Settings, the menu panel and the menu bar, and its
/// service tears down (and never instantiates on the next launch). Turning a
/// feature back on restores saved enable choices. A first install turns on its
/// primary control when no enable choice was saved before.
enum AppFeature: String, CaseIterable {
    // Clipboard
    case clipboardHistory, pastePlain
    // Energy
    case keepAwake
    // Tools
    case cleaner, uninstaller, homebrew, appUpdates, killProcess, portManager
    // Dynamic Island, then its extensions
    case notch, notchAgents
    // System monitor, one entry per metric family (temperatures live with
    // their parent metric: CPU temp with CPU, battery temp with power).
    case monitorCPU, monitorGPU, monitorMemory, monitorNetwork, monitorDisk, monitorPower, connectedDevices, fanControl
}

/// Hub sections, in display order.
enum FeatureGroup: String, CaseIterable {
    case clipboardFiles, energyDisplay, tools, dynamicIsland, monitor
}

/// System permissions surfaced by the hub's transparency portal.
enum AppPermission: String, CaseIterable {
    case accessibility, fullDiskAccess, filesAndFolders, notifications, automationFinder, appManagement
}

enum PermissionPollingSupport {
    static func interval(visibleSurfaceCount: Int,
                         accessibilityIsNeeded: Bool,
                         accessibilityIsGranted: Bool) -> TimeInterval? {
        guard visibleSurfaceCount > 0 || accessibilityIsNeeded else {
            return nil
        }
        if visibleSurfaceCount > 0 || !accessibilityIsGranted {
            return 2.5
        }
        return 60
    }
}

extension AppFeature {
    var group: FeatureGroup {
        switch self {
        case .clipboardHistory, .pastePlain:
            return .clipboardFiles
        case .keepAwake:
            return .energyDisplay
        case .cleaner, .uninstaller, .homebrew, .appUpdates, .killProcess, .portManager:
            return .tools
        case .notch, .notchAgents:
            return .dynamicIsland
        case .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork, .monitorDisk, .monitorPower,
             .connectedDevices, .fanControl:
            return .monitor
        }
    }

    var symbolName: String {
        switch self {
        case .clipboardHistory: return "doc.on.clipboard"
        case .pastePlain: return "doc.plaintext"
        case .keepAwake: return "moon.zzz.fill"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .homebrew: return "shippingbox"
        case .appUpdates: return "arrow.down.app"
        case .notchAgents: return "sparkles"
        case .notch: return "macbook"
        case .killProcess: return "xmark.octagon"
        case .portManager: return "network"
        case .monitorCPU: return "cpu"
        case .monitorGPU: return "rectangle.connected.to.line.below"
        case .monitorMemory: return "memorychip"
        case .monitorNetwork: return "network"
        case .monitorDisk: return "internaldrive"
        case .monitorPower: return "bolt.fill"
        case .connectedDevices: return "cable.connector"
        case .fanControl: return "fanblades.fill"
        }
    }

    var availabilityKey: String { DefaultsKey.featureAvailable(rawValue) }

    var isBeta: Bool { self == .fanControl || self == .killProcess }

    /// Availability read straight from defaults. Existing features stay
    /// available on update; explicit beta opt-ins may start unavailable.
    var isAvailable: Bool {
        isAvailable(in: .standard)
    }

    func isAvailable(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: availabilityKey)
    }

    /// The feature's own enable keys; any one being true means the feature is
    /// engaged. Empty means the feature works on demand (a panel tile, a
    /// context-menu action), so being available already counts as engaged for
    /// the permissions portal.
    var enabledKeys: [String] {
        switch self {
        case .notchAgents: return [DefaultsKey.notchAgentsEnabled]
        case .notch: return [DefaultsKey.notchEnabled]
        case .clipboardHistory: return [DefaultsKey.clipboardHistoryEnabled]
        case .pastePlain: return [DefaultsKey.pastePlainEnabled]
        case .keepAwake, .cleaner, .uninstaller, .homebrew, .appUpdates, .killProcess, .portManager,
             .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork, .monitorDisk, .monitorPower,
             .connectedDevices, .fanControl:
            return []
        }
    }

    /// Registered defaults are visible through `object(forKey:)`, so only the
    /// persistent domain can tell a fresh install from a saved off choice.
    /// A first install turns on the feature's main behavior.
    func enableOnFirstInstall(in defaults: UserDefaults, savedValues: [String: Any]) {
        guard !enabledKeys.contains(where: { savedValues[$0] != nil }) else { return }
        for key in enabledKeys.prefix(1) {
            defaults.set(true, forKey: key)
        }
    }

    /// Which permissions the feature can use at all. Whether it is using them
    /// RIGHT NOW is answered by `activeFeatures(using:)`, which also applies
    /// the dynamic rules (the island needs Accessibility only for its clipboard
    /// window, the monitor only notifies when an alert is on, and so on).
    var permissions: [AppPermission] {
        switch self {
        // Session logs and the saved limits sit in the home folder, outside
        // every protected location, and no sign-in or keychain item is used.
        case .notchAgents: return []
        case .notch: return [.accessibility]
        case .pastePlain: return [.accessibility]
        case .keepAwake: return [.accessibility]
        case .cleaner: return [.fullDiskAccess, .filesAndFolders, .notifications]
        case .uninstaller: return [.fullDiskAccess, .automationFinder]
        case .homebrew: return [.appManagement]
        case .appUpdates: return [.notifications, .appManagement]
        case .monitorCPU, .monitorMemory, .monitorDisk, .monitorPower: return [.notifications]
        case .clipboardHistory, .monitorGPU, .monitorNetwork, .connectedDevices, .fanControl, .killProcess,
             .portManager:
            return []
        }
    }

    /// Broad grants worth explaining during first run. Permissions used only
    /// by an optional sub-feature stay contextual, at the moment that control
    /// is actually used.
    var onboardingPermissions: [AppPermission] {
        switch self {
        case .keepAwake, .cleaner, .uninstaller, .homebrew, .appUpdates:
            return []
        default:
            return permissions.filter { $0 == .accessibility }
        }
    }

    static func features(in group: FeatureGroup) -> [AppFeature] {
        allCases.filter { $0.group == group }
    }

    /// Whether a Mac that never chose this feature has it installed. Most
    /// people updating never saved an availability, so this list IS their
    /// install: moving a feature out of it uninstalls it for all of them,
    /// which is why a test pins it. The switch has no default on purpose, so
    /// every new feature is placed here by decision. New features belong on
    /// the opt-in side: an update should never grow the panel and Settings on
    /// its own, and the Features page and release notes are where they get
    /// installed. A feature split out of an existing one needs a migration
    /// that copies its parent's availability instead.
    var installedByDefault: Bool {
        switch self {
        case .clipboardHistory, .pastePlain, .keepAwake,
             .cleaner, .uninstaller, .homebrew, .appUpdates,
             .notch, .notchAgents,
             .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork, .monitorDisk, .monitorPower,
             .connectedDevices:
            return true
        case .killProcess, .portManager, .fanControl:
            return false
        }
    }

    /// Registered defaults keep every feature an update already had and leave
    /// opt-in features and explicit betas uninstalled.
    static var availabilityDefaults: [String: Any] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.availabilityKey, $0.installedByDefault) })
    }

    /// Features that are available, engaged and using `permission` right now.
    /// Readers are injectable so the logic stays testable without touching
    /// real UserDefaults.
    static func activeFeatures(using permission: AppPermission,
                               isAvailable: (AppFeature) -> Bool,
                               boolFor: (String) -> Bool,
                               stringFor: (String) -> String?) -> [AppFeature] {
        allCases.filter { feature in
            guard feature.permissions.contains(permission), isAvailable(feature) else { return false }
            let keys = feature.enabledKeys
            guard keys.isEmpty || keys.contains(where: boolFor) else { return false }
            switch (feature, permission) {
            case (.notch, .accessibility):
                return boolFor(DefaultsKey.notchClipboardWindow) && isAvailable(.clipboardHistory)
            case (.keepAwake, .accessibility):
                return boolFor(DefaultsKey.keepAwakeMouseJiggleEnabled)
            case (.monitorCPU, .notifications):
                return boolFor(DefaultsKey.monitorAlertCPU) || boolFor(DefaultsKey.monitorAlertCPUTemperature)
            case (.monitorMemory, .notifications):
                // The Memory module's own notification, its one memory notifier.
                return boolFor(DefaultsKey.memoryNotify)
            case (.monitorDisk, .notifications):
                return boolFor(DefaultsKey.monitorAlertDisk)
            case (.monitorPower, .notifications):
                return boolFor(DefaultsKey.monitorAlertBattery)
                    || boolFor(DefaultsKey.monitorAlertBatteryTemperature)
            case (.appUpdates, .notifications):
                return AppUpdatesSupport.CheckFrequency
                    .sanitized(stringFor(DefaultsKey.appUpdatesCheckFrequency)) != .off
                    && boolFor(DefaultsKey.appUpdatesNotify)
            case (.cleaner, .filesAndFolders):
                return boolFor(DefaultsKey.whatsAppDownloadsEnabled)
            case (.cleaner, .notifications):
                let cleanerNotifies = (stringFor(DefaultsKey.cleanerScheduleFrequency) ?? "off") != "off"
                    && boolFor(DefaultsKey.cleanerScheduleNotify)
                let whatsAppNotifies = boolFor(DefaultsKey.whatsAppDownloadsEnabled)
                    && (boolFor(DefaultsKey.whatsAppDownloadsAutomaticEnabled)
                        || boolFor(DefaultsKey.whatsAppOrganizerEnabled))
                    && boolFor(DefaultsKey.whatsAppDownloadsNotify)
                return cleanerNotifies || whatsAppNotifies
            default:
                return true
            }
        }
    }

    /// Monitor alert keys and the metric feature each one belongs to. An
    /// alert only counts while its metric is available in the hub.
    static let monitorAlertPairs: [(key: String, feature: AppFeature)] = [
        (DefaultsKey.monitorAlertCPU, .monitorCPU),
        (DefaultsKey.monitorAlertCPUTemperature, .monitorCPU),
        (DefaultsKey.monitorAlertBatteryTemperature, .monitorPower),
        (DefaultsKey.monitorAlertDisk, .monitorDisk),
        (DefaultsKey.monitorAlertBattery, .monitorPower),
    ]

    static func anyMonitorAlertEnabled(isAvailable: (AppFeature) -> Bool,
                                       boolFor: (String) -> Bool) -> Bool {
        monitorAlertPairs.contains { boolFor($0.key) && isAvailable($0.feature) }
    }

    /// Runtime convenience over the injectable core.
    static func activeFeatures(using permission: AppPermission,
                               defaults: UserDefaults = .standard) -> [AppFeature] {
        activeFeatures(using: permission,
                       isAvailable: { defaults.bool(forKey: $0.availabilityKey) },
                       boolFor: { defaults.bool(forKey: $0) },
                       stringFor: { defaults.string(forKey: $0) })
    }
}

extension AppPermission {
    var symbolName: String {
        switch self {
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "externaldrive.badge.person.crop"
        case .filesAndFolders: return "folder.badge.person.crop"
        case .notifications: return "bell.badge"
        case .automationFinder: return "gearshape.2"
        case .appManagement: return "app.badge"
        }
    }
}

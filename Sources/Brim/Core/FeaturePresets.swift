// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// One-click starting points for the Features hub. A preset is a shape, not a
/// prison: applying one installs and engages its features and uninstalls the
/// rest, but nothing is deleted — every feature keeps its settings and comes
/// back with one click, exactly like any hub install.
enum FeaturePreset: String, CaseIterable, Identifiable {
    case essential, battery

    var id: String { rawValue }

    /// A clean install starts from the small Essential set before any feature
    /// binding runs. Updates keep every existing availability choice, and an
    /// interrupted setup keeps the selection already applied on its purpose
    /// step.
    static func prepareFirstRunAvailability(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: DefaultsKey.hasOnboarded),
              defaults.integer(forKey: DefaultsKey.onboardingStep) == 0
        else { return }
        let selected = FeaturePreset.essential.features
        for feature in AppFeature.allCases {
            defaults.set(selected.contains(feature), forKey: feature.availabilityKey)
        }
    }

    /// The features the preset keeps installed.
    var features: Set<AppFeature> {
        switch self {
        case .essential:
            // Everything that works without a permission prompt, an
            // administrator password or a Bluetooth grant. Keep Awake asks for
            // Accessibility only for its optional mouse jiggle, and the
            // monitor for notifications only once an alert is turned on.
            return [.keepAwake, .clipboardHistory, .killProcess, .portManager, .notchAgents,
                    .monitorCPU, .monitorGPU, .monitorMemory,
                    .monitorNetwork, .monitorDisk, .monitorPower]
        case .battery:
            // The lean monitor: battery, memory pressure and the processor,
            // with nothing that listens to input events.
            return [.monitorCPU, .monitorMemory, .monitorPower]
        }
    }

    var symbolName: String {
        switch self {
        case .essential: return "star.fill"
        case .battery: return "battery.75percent"
        }
    }
}

/// The honest, curated cost label each feature earns in the hub: what the
/// feature keeps alive WHILE IT IS ON. Uninstalled features load nothing at
/// all, which is the hub's own promise. Static by design — pretending to
/// measure per-feature cost live would be theater.
enum FeatureEnergyProfile: String {
    /// Nothing at rest: on-demand tools, shortcut-driven actions and
    /// system-notification listeners.
    case idle
    /// Samples or polls on an interval while active or visible.
    case periodic
}

extension AppFeature {
    var energyProfile: FeatureEnergyProfile {
        switch self {
        // Log changes arrive as file events; a timer keeps countdowns and
        // limits current while the section is on.
        case .notch, .notchAgents: return .periodic
        case .clipboardHistory,
             .monitorCPU, .monitorGPU, .monitorMemory,
             .monitorNetwork, .monitorDisk, .monitorPower, .connectedDevices:
            return .periodic
        case .pastePlain, .keepAwake, .cleaner, .uninstaller, .homebrew, .fanControl,
             .killProcess, .portManager:
            return .idle
        case .appUpdates:
            // The list is on demand; only a background schedule keeps a timer.
            return AppUpdatesSupport.CheckFrequency.sanitized(
                UserDefaults.standard.string(forKey: DefaultsKey.appUpdatesCheckFrequency)) == .off
                ? .idle : .periodic
        }
    }
}

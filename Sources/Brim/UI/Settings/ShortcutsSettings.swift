// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The central editor for every global shortcut belonging to an installed
/// feature. It writes the same preferences as each feature page, so there is
/// still one setting and one registration path for every action.
struct ShortcutsSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @AppStorage(DefaultsKey.keepAwakeShortcut) private var keepAwakeShortcut = GlobalShortcut.keepAwakeDefault.storageValue

    private var text: ShortcutSettingsStrings { FeatureStrings.shortcuts(l10n.language) }
    private var hub: FeatureHubStrings { FeatureStrings.hub(l10n.language) }

    private var availableRoles: [GlobalShortcutRole] {
        GlobalShortcutRole.availableRoles(isAvailable: { $0.isAvailable })
    }

    private var visibleGroups: [FeatureGroup] {
        FeatureGroup.allCases.filter { group in
            availableRoles.contains { $0.feature.group == group }
        }
    }

    var body: some View {
        Form {
            Section {
                Text(l10n.s.shortcutsPageCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleGroups, id: \.self) { group in
                Section(groupTitle(group)) {
                    ForEach(availableRoles.filter { $0.feature.group == group }) { role in
                        roleRow(role)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func roleRow(_ role: GlobalShortcutRole) -> some View {
        let title = role.title(l10n.s)
        let featureTitle = role.feature.hubTitle(l10n.s, hub: hub)
        let active = hasAssignedShortcut(role) && role.requiredEnableKeys.allSatisfy {
            UserDefaults.standard.bool(forKey: $0)
        }
        return ShortcutPreferenceRow(
            role: role,
            label: title,
            symbolName: role.feature.symbolName,
            contextLabel: title != featureTitle ? featureTitle : nil,
            statusText: active ? text.active : text.inactive,
            statusIsActive: active,
            includeInactiveConflicts: true,
            onChange: {
                FeatureRuntime.shared.sync([role.feature])
            }
        )
    }

    private func hasAssignedShortcut(_ role: GlobalShortcutRole) -> Bool {
        role.assignedShortcut(storedValue: { key in
            key == DefaultsKey.keepAwakeShortcut ? keepAwakeShortcut : UserDefaults.standard.string(forKey: key)
        }) != nil
    }

    private func groupTitle(_ group: FeatureGroup) -> String {
        switch group {
        case .clipboardFiles: return hub.groupClipboardFiles
        case .energyDisplay: return hub.groupEnergyDisplay
        case .tools: return hub.groupTools
        case .dynamicIsland: return FeatureStrings.notch(l10n.language).title
        case .monitor: return hub.groupMonitor
        }
    }
}

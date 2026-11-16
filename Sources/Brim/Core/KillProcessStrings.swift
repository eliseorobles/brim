// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Strings for the Kill Process feature. Same contract as the other
/// FeatureStrings structs: memberwise init in declaration order, one English
/// static, all in this file.
struct KillProcessFeatureStrings {
    let pageTitle: String
    let hubDescription: String
    let searchPlaceholder: String
    let columnProcess: String
    let columnCPU: String
    let columnMemory: String
    let columnPID: String
    let groupToggle: String
    let groupCaption: String
    let refreshTooltip: String
    let processCountFormat: String
    let killButton: String
    let forceKillButton: String
    let killAllFormat: String
    let killTreeButton: String
    let restartButton: String
    let copyPID: String
    let copyPath: String
    let emptyStateTitle: String
    let confirmKillFormat: String
    let confirmForceKillFormat: String
    let confirmKillAllFormat: String
    let confirmKillTreeFormat: String
    let adminPromptFormat: String
}

extension FeatureStrings {
    static func killProcess(_ language: AppLanguage) -> KillProcessFeatureStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

extension KillProcessFeatureStrings {
    static let enUS = KillProcessFeatureStrings(
        pageTitle: "Kill Process",
        hubDescription: "Search running processes and force quit, restart, or kill process trees",
        searchPlaceholder: "Filter by name",
        columnProcess: "Process",
        columnCPU: "CPU",
        columnMemory: "Memory",
        columnPID: "PID",
        groupToggle: "Group related processes",
        groupCaption: "Groups helper processes under the app responsible for them.",
        refreshTooltip: "Refresh",
        processCountFormat: "Processes: %d",
        killButton: "Kill",
        forceKillButton: "Force Kill",
        killAllFormat: "Kill All “%@”",
        killTreeButton: "Kill Process Tree",
        restartButton: "Restart",
        copyPID: "Copy PID",
        copyPath: "Copy Path",
        emptyStateTitle: "No Processes Found",
        confirmKillFormat: "Kill %@?",
        confirmForceKillFormat: "Force Kill %@?",
        confirmKillAllFormat: "Kill all “%@” processes?",
        confirmKillTreeFormat: "Kill %@ and all its child processes?",
        adminPromptFormat: "Brim needs administrator access to end “%@”."
    )
}

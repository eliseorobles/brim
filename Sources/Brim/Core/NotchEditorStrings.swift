// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NotchEditorStrings {
    let layout: String
    let content: String
    let activity: String
    let behavior: String
    let layoutHint: String
    let addButton: String
    let editButton: String
    let removeButton: String
    let buttonName: String
    let position: String
    let bottom: String
    let sectionActions: String
    let quickActions: String
    let findAction: String
    let reorderHint: String
    let opening: String
    let clickOpen: String
    let hoverPreview: String
    let hoverExpand: String
    let hiddenUntilHover: String
    let hiddenShowsActivity: String
    let hiddenShowsActivityHint: String
    let resting: String
    let destinations: String
    let separate: String
    let feedback: String
    let privacy: String
    let reopening: String
    let lastPage: String
    let openActivity: String
    let openActivityHint: String
    let activationTime: String
    let activationTimeHint: String
    let activationTimeFormat: String
    let closeTime: String
    let closeTimeHint: String
    let enableFeatureFormat: String
    let enableSettingFormat: String
    let showPageFormat: String
    let appPanelHint: String
    let hideMenuBarIcon: String
    let hideMenuBarIconHint: String
    let sections: String
    let sectionsHint: String
    let preview: String
    let hiddenInIsland: String
    let openFeatures: String
    let noOptions: String
    let controlsSummary: String
    let clipboardSummary: String
    let systemSummary: String
    let agentsSummary: String

    func enableFeature(_ title: String) -> String { String(format: enableFeatureFormat, title) }
    func enableSetting(_ title: String) -> String { String(format: enableSettingFormat, title) }
    func showPage(_ title: String) -> String { String(format: showPageFormat, title) }

    /// One line on what a section of the island shows.
    func summary(_ module: NotchModule) -> String {
        switch module {
        case .controls: return controlsSummary
        case .clipboard: return clipboardSummary
        case .system: return systemSummary
        case .agents: return agentsSummary
        }
    }
}

extension FeatureStrings {
    static func notchEditor(_ language: AppLanguage) -> NotchEditorStrings {
        switch language {
        case .enUS: return NotchEditorStrings(
            layout: "Layout",
            content: "Content",
            activity: "Activity",
            behavior: "Behavior",
            layoutHint: "Click + to add a button. Drag buttons around the island. Click a button to edit it.",
            addButton: "Add button",
            editButton: "Edit button",
            removeButton: "Remove button",
            buttonName: "Name",
            position: "Position",
            bottom: "Bottom",
            sectionActions: "Open a section",
            quickActions: "Quick actions",
            findAction: "Find an action",
            reorderHint: "Drag to reorder. Click the checkmark to show or hide.",
            opening: "Opening",
            clickOpen: "Click to open",
            hoverPreview: "Preview on hover",
            hoverExpand: "Expand on hover",
            hiddenUntilHover: "Hidden until hover",
            hiddenShowsActivity: "Show activity and indicators",
            hiddenShowsActivityHint: "Comes into view while an activity runs or an indicator shows, then hides again.",
            resting: "At rest",
            destinations: "Where things open",
            separate: "Separate window",
            feedback: "Indicators",
            privacy: "Privacy",
            reopening: "When reopening",
            lastPage: "Last page",
            openActivity: "Open the visible activity",
            openActivityHint: "When the closed island shows an activity, such as AI agents at work, it opens on that page instead.",
            activationTime: "Activation time",
            activationTimeHint: "Keep the pointer over the island for this long to open it.",
            activationTimeFormat: "%.2f s",
            closeTime: "Closing time",
            closeTimeHint: "Wait this long after the pointer leaves the island before closing it.",
            enableFeatureFormat: "Enable “%@” in Features.",
            enableSettingFormat: "Enable “%@” in its settings.",
            showPageFormat: "Show “%@” on the Content tab.",
            appPanelHint: "Choose where clicking the Brim menu bar icon opens the app panel, on any display.",
            hideMenuBarIcon: "Hide the menu bar icon",
            hideMenuBarIconHint: "Settings and the app panel open from Dynamic Island. The icon returns when the island is off or hidden in full screen.",
            sections: "Sections",
            sectionsHint: "Drag to reorder. Uncheck a section to hide it from the island.",
            preview: "Preview",
            hiddenInIsland: "Hidden from the island",
            openFeatures: "Open Features",
            noOptions: "This section has no options.",
            controlsSummary: "Your shortcuts.",
            clipboardSummary: "What you copied recently, ready to paste again.",
            systemSummary: "CPU, memory, disk, network and battery at a glance.",
            agentsSummary: "Claude Code, Codex, OpenCode and GitHub Copilot usage, limits and costs."
        )
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NotchStrings {
    let title: String
    let enable: String
    let description: String
    let menuBarAccessHint: String
    let display: String
    let automatic: String
    let builtIn: String
    let mainDisplay: String
    let followPointer: String
    let allDisplays: String
    let hover: String
    let modules: String
    let events: String
    let clipboardActivity: String
    let privacy: String
    let open: String
    let collapse: String
    let pin: String
    let unpin: String
    let panel: String
    let empty: String
    let inputSource: String
    let battery: String
    let onBattery: String
    let charging: String
    let charged: String
    let lowBattery: String
    let controls: String
    let system: String
    let disabled: String
    let files: String
    let hideInFullscreen: String
    let hoverInFullscreen: String
    let showInCaptures: String
    let tools: String
    let size: String
    let showOutline: String
    let compact: String
    let spacious: String
    let hoverExpand: String
    let appPanel: String
    let idleContent: String
    let idleNone: String
    let coverMenus: String
    let coverMenusHint: String
    let controlShortcuts: String
    let activity: String
    let custom: String
    let width: String
    let maximumHeight: String
    let sizeHint: String
    let cameraFit: String
    let height: String
    let cameraFitHint: String
    let hideMenuBarGap: String
    let hideMenuBarGapHint: String
    let withoutNotch: String
    let capsuleShape: String
    let notchShape: String
    let withoutNotchUnreached: String
    let showOnAllDisplays: String
    let capsuleFit: String
    let fromTop: String
    let capsuleFitHint: String
    let hapticFeedback: String
    let switchSection: String
    let sectionsTitle: String
    let searchSections: String
    let sectionKeyboardHint: String
    let quickAccessLeft: String
    let quickAccessRight: String
    let translucentBackground: String
    let translucentBackgroundHint: String
    let translucentBackgroundGlassHint: String
}

extension FeatureStrings {
    static func notch(_ language: AppLanguage) -> NotchStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

extension NotchStrings {
    static let enUS = NotchStrings(
        title: "Dynamic Island",
        enable: "Enable Dynamic Island",
        description: "Your controls, AI agents and everyday tools, together at the top of your screen. Optional. Turn it off to keep using the separate panels.",
        menuBarAccessHint: "Allow Accessibility so Dynamic Island can appear on this display without covering the menus.",
        display: "Display",
        automatic: "Automatic",
        builtIn: "Built-in display",
        mainDisplay: "Main display",
        followPointer: "Follow pointer",
        allDisplays: "All displays",
        hover: "Open when the pointer rests on the Dynamic Island",
        modules: "What appears",
        events: "More options",
        clipboardActivity: "Notify when something is copied",
        privacy: "Copied content stays private until you open the clipboard. These options follow the original feature’s settings.",
        open: "Open Dynamic Island",
        collapse: "Collapse",
        pin: "Keep open",
        unpin: "Allow automatic closing",
        panel: "Open app panel",
        empty: "Choose what appears in Dynamic Island settings.",
        inputSource: "Input source",
        battery: "Battery",
        onBattery: "On battery",
        charging: "Charging",
        charged: "Fully charged",
        lowBattery: "Low battery",
        controls: "Controls",
        system: "System",
        disabled: "Enable the corresponding feature to use it here.",
        files: "Files",
        hideInFullscreen: "Hide content in full screen",
        hoverInFullscreen: "Hidden until hover in full screen",
        showInCaptures: "Show in screenshots and videos",
        tools: "Tools",
        size: "Size",
        showOutline: "Show outline",
        compact: "Compact",
        spacious: "Spacious",
        hoverExpand: "Expand fully on hover",
        appPanel: "Open the app panel in the Dynamic Island",
        idleContent: "While inactive",
        idleNone: "Nothing",
        coverMenus: "Show over the menus",
        coverMenusHint: "Keeps Keep Awake, AI agents and other compact activity on screen when the menu bar has no room, covering the menus beside the camera.",
        controlShortcuts: "Controls and shortcuts",
        activity: "Activity",
        custom: "Custom",
        width: "Width",
        maximumHeight: "Maximum height",
        sizeHint: "Controls stay compact. Longer lists use up to this height.",
        cameraFit: "Notch fit",
        height: "Height",
        cameraFitHint: "If an edge of the notch shows around Dynamic Island, adjust these values until it disappears.",
        hideMenuBarGap: "Hide gap below notch",
        hideMenuBarGapHint: "Extends Dynamic Island to the bottom of the menu bar to hide the thin strip below the notch.",
        withoutNotch: "Displays without a notch",
        capsuleShape: "Capsule",
        notchShape: "Notch",
        withoutNotchUnreached: "With the Display chosen on the Behavior tab, Dynamic Island doesn’t appear on these displays.",
        showOnAllDisplays: "Show on all displays",
        capsuleFit: "Capsule fit",
        fromTop: "Distance from top",
        capsuleFitHint: "Resizes the capsule and lowers it from the top of the screen on displays without a notch.",
        hapticFeedback: "Haptic feedback",
        switchSection: "Switch section",
        sectionsTitle: "Explore",
        searchSections: "Find a section",
        sectionKeyboardHint: "Use the arrow keys, then press Return",
        quickAccessLeft: "Left",
        quickAccessRight: "Right",
        translucentBackground: "Translucent background",
        translucentBackgroundHint: "When open, Dynamic Island blurs what is behind it with the system’s own material.",
        translucentBackgroundGlassHint: "Liquid Glass is on, so Dynamic Island uses it instead."
    )

}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Plain-language copy for the General page: one short line per control and
/// one per panel section, so the page explains itself without paragraphs.
struct GeneralSettingsStrings {
    let appearanceCaption: String
    let launchAtLoginCaption: String
    let liquidGlassCaption: String
    let liquidGlassOtherWindows: String
    let panelIntro: String
    let panelReorderHint: String
    let menuBarIconTitle: String
    let menuBarIconCaption: String
    let menuBarIconOther: String
    let menuBarIconOtherCaption: String
    let menuBarIconUnknown: String
    let menuBarIconReset: String
    let iconMissingTitle: String
    let iconMissingCaption: String
    let sectionKeepAwake: String
    let sectionSystem: String
    let sectionNetwork: String
    let sectionDisks: String
    let sectionPower: String
    let sectionFanControl: String
    let sectionUtilities: String
    let sectionControls: String
}

extension FeatureStrings {
    static func generalSettings(_ language: AppLanguage) -> GeneralSettingsStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

extension GeneralSettingsStrings {
    static let enUS = GeneralSettingsStrings(
        appearanceCaption: "Applies to Brim’s own windows and panels, not to the whole Mac.",
        launchAtLoginCaption: "Opens by itself every time you turn on your Mac.",
        liquidGlassCaption: "See-through, glass-like panels.",
        liquidGlassOtherWindows: "Other windows and panels",
        panelIntro: "Click Brim’s icon in the menu bar to open the panel. Its tabs appear in this order.",
        panelReorderHint: "Drag to reorder. Switch off anything you don’t need.",
        menuBarIconTitle: "Menu bar icon",
        menuBarIconCaption: "Choose the icon Brim shows in the menu bar.",
        menuBarIconOther: "Other symbol",
        menuBarIconOtherCaption: "Type the name of any SF Symbol. Leave it empty to use the Brim icon.",
        menuBarIconUnknown: "This Mac has no symbol with that name.",
        menuBarIconReset: "Use the Brim icon",
        iconMissingTitle: "Can’t find the icon?",
        iconMissingCaption: "A crowded menu bar can hide it, especially on Macs with a notch.",
        sectionKeepAwake: "Keeps your Mac awake for as long as you want.",
        sectionSystem: "Processor, graphics and memory at a glance.",
        sectionNetwork: "Internet speed and which apps are using it.",
        sectionDisks: "Free space and disk activity.",
        sectionPower: "Battery, charging and power use.",
        sectionFanControl: "Fan speeds and your own fan curve.",
        sectionUtilities: "Cleaner, uninstaller, updates and other tools.",
        sectionControls: "Switch Dynamic Island on or off."
    )
}

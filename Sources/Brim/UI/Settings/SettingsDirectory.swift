// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Only values that change which controls exist belong in the search cache key.
struct SettingsSearchState: Equatable {
    struct Hardware: Equatable {
        let battery, notchedDisplay, plainDisplay: Bool
    }

    let hardware: Hardware
    let bars, batteryRest, capsule, customSize: Bool
    private let switches: Set<String>

    init(defaults: UserDefaults, hardware: Hardware) {
        self.hardware = hardware
        bars = defaults.string(forKey: DefaultsKey.menuBarMetricAppearance) == "bars"
        batteryRest = defaults.string(forKey: DefaultsKey.notchIdleContent) == NotchIdleContent.battery.rawValue
        capsule = defaults.string(forKey: DefaultsKey.notchSilhouette) != NotchSilhouette.notch.rawValue
        customSize = defaults.string(forKey: DefaultsKey.notchSize) == NotchSize.custom.rawValue
        switches = Set([
            DefaultsKey.clamshellPreferred, DefaultsKey.keepAwakeMouseJiggleEnabled,
            DefaultsKey.notchClipboardWindow, DefaultsKey.notchLowBatteryTint, DefaultsKey.notchLowBatteryEarly,
            DefaultsKey.notchHideInFullscreen, DefaultsKey.notchHoverInFullscreen, DefaultsKey.notchOpenOnHover,
            DefaultsKey.notchHideUntilHover, DefaultsKey.notchHoverExpands, DefaultsKey.notchAgentsClaude,
            DefaultsKey.notchAgentsLiveActivity, DefaultsKey.notchAgentsFinishAlert, DefaultsKey.notchAgentsLimitAlert,
            DefaultsKey.monitorAlertCPU,
            DefaultsKey.monitorAlertCPUTemperature, DefaultsKey.monitorAlertDisk,
            DefaultsKey.monitorAlertBattery, DefaultsKey.monitorAlertBatteryTemperature,
        ].filter { defaults.bool(forKey: $0) })
    }

    func on(_ key: String) -> Bool { switches.contains(key) }
}

extension SettingsSearchState {
    static var current: Self {
        Self(defaults: .standard, hardware: Hardware(
            battery: PowerSampler.hasInternalBattery, notchedDisplay: NotchSupport.hasNotchedDisplay,
            plainDisplay: NotchSupport.hasDisplayWithoutNotch))
    }
}

/// One Settings page as the sidebar and its search present it.
struct SettingsDirectoryItem: Identifiable {
    let page: SettingsPage
    let title: String
    let icon: String
    let terms: [SettingsSearchTerms]
    var id: SettingsPage { page }

    init(page: SettingsPage, title: String, icon: String,
         keywords: [String] = [],
         featureKeywords: [(feature: AppFeature, titles: [String])] = [],
         terms: [SettingsSearchTerms] = []) {
        self.page = page
        self.title = title
        self.icon = icon
        self.terms = [SettingsSearchTerms(keywords)]
            + featureKeywords.map { SettingsSearchTerms($0.titles, feature: $0.feature) } + terms
    }
}

/// The single map of the Settings window: sections, pages, icons and search
/// keywords. The sidebar draws its tool list from these pages and its search
/// searches them. One list, so a page added here is findable everywhere.
enum SettingsDirectory {
    /// Shared pages whose tools cover the page without a separate overview row.
    private static let toolOnlyPages: Set<SettingsPage> = [.energy, .clipboard]

    /// Keep the directory's destinations, but show the most useful groups
    /// first and separate everyday controls from the longer tool list.
    static func sidebarSections(_ s: Strings,
                                language: AppLanguage,
                                isAvailable: (AppFeature) -> Bool) -> [SettingsSidebarSection] {
        let hub = FeatureStrings.hub(language)
        let grouped: [SettingsSidebarSection] = sections(
            s, language: language, state: .current
        ).enumerated().compactMap { index, section -> SettingsSidebarSection? in
                let items = section.items.flatMap { pageItem -> [SettingsSidebarItem] in
                    var rows = SettingsSidebarSupport.items(
                        page: pageItem.page, title: pageItem.title, icon: pageItem.icon,
                        preferredFeatures: pageItem.terms.compactMap(\.feature),
                        includePage: !toolOnlyPages.contains(pageItem.page),
                        isAvailable: isAvailable) { feature in
                            if feature == .clipboardHistory {
                                return FeatureStrings.clipboard(language).historyTitle
                            }
                            return feature.hubTitle(s, hub: hub, language: language)
                        }
                    if pageItem.page == .general {
                        rows.insert(SettingsSidebarItem(
                            id: .setting(.panelConfiguration),
                            destination: FeatureSettingsDestination(
                                .general, sectionAnchor: .panelConfiguration),
                            title: s.menuBarSection, icon: "menubar.rectangle"), at: 1)
                    }
                    return rows
                }
                guard !items.isEmpty else { return nil }
                return SettingsSidebarSection(id: index, title: section.title, items: items)
            }
        guard let essentials = grouped.first(where: { $0.id == 0 }) else { return grouped }
        let categories = FeatureStrings.settingsCategories(language)
        // Monitor keeps its tool rows, such as Fan Control, beside it.
        let core = essentials.items.filter { item in
            switch item.id {
            case .page(.general), .page(.features),
                 .setting(.panelConfiguration): return true
            default: return item.destination.page == .monitor
            }
        }
        let island = grouped.first(where: { $0.id == 3 })?.items.filter { $0.id == .page(.notch) } ?? []
        let energy: [SettingsSidebarItem] = essentials.items.filter {
            $0.destination.page == .energy
        }
        func rows(_ id: Int) -> [SettingsSidebarItem] {
            grouped.first(where: { $0.id == id })?.items ?? []
        }
        let featured = [
            SettingsSidebarSection(id: 0, title: categories.essentials,
                                   items: Array(core.prefix(3)) + island + Array(core.dropFirst(3))),
            SettingsSidebarSection(id: 5, title: hub.groupEnergyDisplay, items: energy),
            SettingsSidebarSection(id: 1, title: categories.files, items: rows(1)),
        ]
        let remaining = grouped.filter { ![0, 1, 3].contains($0.id) }
        return [featured[0]] + featured.dropFirst().filter { !$0.items.isEmpty } + remaining
    }

    /// Destination-aware rows for the Settings search.
    static func searchItems(_ s: Strings,
                            language: AppLanguage,
                            state: SettingsSearchState = .current) -> [SettingsSearchItem] {
        let pageItems = sections(s, language: language, state: state)
            .flatMap(\.items).map { item in
                SettingsSearchItem(id: .page(item.page),
                                   destination: FeatureSettingsDestination(item.page),
                                   title: item.title,
                                   icon: item.icon,
                                   terms: item.terms)
            }
        let hub = FeatureStrings.hub(language)
        let featureItems = SettingsSearchSupport.featureItems(language: language) { feature in
            feature.hubTitle(s, hub: hub, language: language)
        }
        var items = SettingsSearchSupport.combinedItems(pageItems: pageItems,
                                                        featureItems: featureItems)
        items.append(SettingsSearchItem(
            id: .setting(.panelConfiguration),
            destination: FeatureSettingsDestination(
                .general, sectionAnchor: .panelConfiguration),
            title: s.menuBarSection, icon: "menubar.rectangle",
            keywords: [s.showMenuBarIcon, FeatureStrings.generalSettings(language).menuBarIconTitle,
                       FeatureStrings.generalSettings(language).iconMissingTitle, "SF Symbols"]))
        let alerts = FeatureStrings.monitorAlerts(language)
        items.append(SettingsSearchItem(
            id: .setting(.monitorAlerts), destination: FeatureSettingsDestination(.monitor, sectionAnchor: .monitorAlerts),
            title: alerts.section, icon: "bell", keywords: [alerts.cooldown], terms: [
                .init([alerts.cpu, alerts.cpuTemperature], feature: .monitorCPU),
                .init([alerts.cpuThreshold], feature: .monitorCPU, when: state.on(DefaultsKey.monitorAlertCPU)),
                .init([alerts.cpuTemperatureThreshold], feature: .monitorCPU, when: state.on(DefaultsKey.monitorAlertCPUTemperature)),
                .init([alerts.disk], feature: .monitorDisk),
                .init([alerts.diskThreshold], feature: .monitorDisk, when: state.on(DefaultsKey.monitorAlertDisk)),
                .init([alerts.battery, alerts.batteryTemperature], feature: .monitorPower, when: state.hardware.battery),
                .init([alerts.batteryThreshold], feature: .monitorPower,
                      when: state.hardware.battery && state.on(DefaultsKey.monitorAlertBattery)),
                .init([alerts.batteryTemperatureThreshold], feature: .monitorPower,
                      when: state.hardware.battery && state.on(DefaultsKey.monitorAlertBatteryTemperature)),
            ]))
        return items
    }

    static func sections(_ s: Strings,
                         language: AppLanguage,
                         state: SettingsSearchState)
        -> [(title: String, items: [SettingsDirectoryItem])] {
        let categories = FeatureStrings.settingsCategories(language)
        let barStyle = FeatureStrings.menuBarAppearance(language)
        let notch = FeatureStrings.notch(language)
        let notchEditor = FeatureStrings.notchEditor(language)
        let notchAgents = FeatureStrings.notchAgents(language)
        let claudeAccounts = FeatureStrings.claudeAccounts(language)
        let notchLowBattery = NotchLowBatteryStrings.localized(language)
        var liquidGlass: [String] = []
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            liquidGlass = [FeatureStrings.appearance(language).liquidGlass,
                           FeatureStrings.generalSettings(language).liquidGlassOtherWindows]
        }
#endif
        let activities = FeatureStrings.notchActivities(language)
        let lockScreen = FeatureStrings.notchLockScreen(language)
        let hover = state.on(DefaultsKey.notchOpenOnHover)
        let hideFullscreen = state.on(DefaultsKey.notchHideInFullscreen)
        let hoverDelay = hover || (hideFullscreen && state.on(DefaultsKey.notchHoverInFullscreen))
        let batteryRest = state.hardware.battery && state.batteryRest
        let tintedBattery = batteryRest && state.on(DefaultsKey.notchLowBatteryTint)
        let islandTerms: [SettingsSearchTerms] = [
            .init([notchEditor.layout, notch.size, notch.translucentBackground, notch.showOutline], notch: .layout),
            .init([notch.width, notch.maximumHeight], notch: .layout, when: state.customSize),
            .init([notch.cameraFit, notch.hideMenuBarGap, notch.width, notch.height],
                  notch: .layout, when: state.hardware.notchedDisplay),
            .init([notch.withoutNotch], notch: .layout, when: state.hardware.plainDisplay),
            .init([notch.capsuleFit, notch.width, notch.height, notch.fromTop],
                  notch: .layout, when: state.hardware.plainDisplay && state.capsule),
            .init([activities.keepAwakeActivity], notch: .module(.controls)),
            .init([notch.clipboardActivity, "clipboard"], feature: .clipboardHistory, notch: .module(.clipboard)),
            .init([FeatureStrings.notchClipboardSize(language).entrySize], feature: .clipboardHistory,
                  notch: .module(.clipboard), when: state.on(DefaultsKey.notchClipboardWindow)),
            .init([notchAgents.title, "Claude", "Codex", "OpenCode", "GitHub Copilot", "AI", "tokens", notchAgents.resetsCard,
                   notchAgents.limitsAs, notchAgents.limitFocus, notchAgents.liveActivity, notchAgents.finishAlert,
                   notchAgents.limitAlert, notchAgents.budget], feature: .notchAgents, notch: .module(.agents)),
            .init([notchAgents.readout], feature: .notchAgents, notch: .module(.agents), when: state.on(DefaultsKey.notchAgentsLiveActivity)),
            .init([notchAgents.finishAfter], feature: .notchAgents, notch: .module(.agents), when: state.on(DefaultsKey.notchAgentsFinishAlert)),
            .init([notchAgents.limitAt], feature: .notchAgents, notch: .module(.agents), when: state.on(DefaultsKey.notchAgentsLimitAlert)),
            .init([claudeAccounts.title, claudeAccounts.newSessionsUse, claudeAccounts.shellTitle, claudeAccounts.statusLineTitle,
                   claudeAccounts.shareTitle, claudeAccounts.mcpTitle], feature: .notchAgents,
                  notch: .module(.agents), when: state.on(DefaultsKey.notchAgentsClaude)),
            .init([notchEditor.activity, notchEditor.resting, notch.coverMenus, notchEditor.feedback, notch.inputSource,
                   lockScreen.title, lockScreen.sounds, lockScreen.show], notch: .activity),
            .init([notchLowBattery.title], feature: .monitorPower, notch: .activity, when: batteryRest),
            .init([notchLowBattery.threshold, notchLowBattery.early, notchLowBattery.menuBar],
                  feature: .monitorPower, notch: .activity, when: tintedBattery),
            .init([notchLowBattery.earlyThreshold], feature: .monitorPower, notch: .activity,
                  when: tintedBattery && state.on(DefaultsKey.notchLowBatteryEarly)),
            .init([notchEditor.behavior, notchEditor.opening, s.quickToolShortcutToggle,
                   notch.hapticFeedback, notchEditor.reopening,
                   notchEditor.openActivity, notch.display, notch.hideInFullscreen, notchEditor.destinations,
                   notch.panel, notchEditor.privacy, notch.showInCaptures,
                   notchEditor.hideMenuBarIcon], notch: .behavior),
            .init([notchEditor.hiddenShowsActivity], notch: .behavior, when: hover && state.on(DefaultsKey.notchHideUntilHover)),
            .init([notchEditor.activationTime], notch: .behavior, when: hoverDelay),
            .init([notchEditor.closeTime], notch: .behavior, when: hoverDelay && state.on(DefaultsKey.notchHoverExpands)),
            .init([notch.hoverInFullscreen], notch: .behavior, when: hideFullscreen),
        ]
        return [
            (categories.essentials, [
                SettingsDirectoryItem(page: .general, title: s.tabGeneral, icon: "gearshape",
                                       keywords: [s.launchAtLogin,
                                                  FeatureStrings.appearance(language).label,
                                                  FeatureStrings.appearance(language).dark] + liquidGlass,
                                       // The first title of each feature places its sidebar row,
                                       // so these follow the sidebar's order.
                                       featureKeywords: [
                                        (.keepAwake, [s.globalHotkeySection, s.hotkeyToggle]),
                                       ]),
                // Searching any feature name lands here even when the feature
                // is hidden, so the hub is always the way back.
                SettingsDirectoryItem(page: .features, title: FeatureStrings.hub(language).pageTitle,
                                       icon: "square.grid.2x2",
                                       featureKeywords: AppFeature.allCases.map {
                                        ($0, [$0.hubTitle(s, hub: FeatureStrings.hub(language), language: language)])
                                       }),
                SettingsDirectoryItem(page: .energy, title: s.tabEnergy, icon: "bolt.fill",
                                       featureKeywords: [
                                        (.keepAwake, [s.keepAwakeTitle, s.clamshellTitle,
                                                      s.defaultDurationLabel, s.showCountdown,
                                                      s.keepAwakeActiveIconLabel,
                                                      s.keepAwakeActiveIconCoffee,
                                                      s.keepAwakeActiveIconEye,
                                                      FeatureStrings.keepAwakeAutomation(language)
                                                        .externalDisplayToggle,
                                                      FeatureStrings.keepAwakeAutomation(language)
                                                        .powerToggle,
                                                      FeatureStrings.keepAwakeAutomation(language)
                                                        .pauseWhenLockedToggle,
                                                      FeatureStrings.keepAwakeDisplaySleep(language)
                                                        .allowDisplaySleep,
                                                      s.keepAwakeOptions, s.keepAwakeAutoStart,
                                                      s.keepAwakeRightClickToggle, s.keepAwakeMouseJiggle]),
                                       ], terms: [
                                        .init([s.dimScreenOnLidCloseTitle], feature: .keepAwake,
                                              when: state.on(DefaultsKey.clamshellPreferred)),
                                        .init([s.keepAwakeMouseJiggleInterval], feature: .keepAwake,
                                              when: state.on(DefaultsKey.keepAwakeMouseJiggleEnabled)),
                                        .init([s.batteryDisableBelow], feature: .keepAwake, when: state.hardware.battery),
                                       ]),
                SettingsDirectoryItem(page: .monitor, title: s.tabMonitor, icon: "chart.line.uptrend.xyaxis",
                                       keywords: [s.menuBarSpacingLabel, s.menuBarHideIconToggle, barStyle.label,
                                                  barStyle.bars, barStyle.values, s.monitorSeparateMenuBarMetrics,
                                                  s.monitorIntervalLabel, s.temperatures, GraphScaleStrings.localized(language).title],
                                       featureKeywords: [
                                        (.monitorMemory, [s.monitorMemoryPressureDot, s.monitorMemoryMetricLabel]),
                                        (.monitorNetwork, [FeatureStrings.monitorLayout(language).networkSpeedUnit]),
                                        (.fanControl, [FeatureStrings.fanControl(language).menuBarTitle]),
                                       ], terms: [
                                        .init([s.monitorCombineTemperatures], when: !state.bars),
                                        .init([barStyle.customize, barStyle.normalColor, barStyle.mediumColor, barStyle.highColor,
                                               barStyle.mediumFrom, barStyle.highFrom], when: state.bars),
                                       ]),
            ]),
            (categories.files, [
                SettingsDirectoryItem(page: .clipboard, title: FeatureStrings.clipboard(language).title,
                                       icon: "doc.on.clipboard",
                                       featureKeywords: [
                                        (.clipboardHistory, [FeatureStrings.clipboard(language).limit,
                                                             FeatureStrings.clipboardRetention(language).title,
                                                             FeatureStrings.clipboard(language).historyLayout,
                                                             FeatureStrings.clipboard(language).skipSensitive,
                                                             FeatureStrings.clipboard(language).autoClearEnable,
                                                             FeatureStrings.clipboard(language).autoClearOnSleep,
                                                             FeatureStrings.clipboard(language)
                                                                .autoClearOnDisplaySleep,
                                                             FeatureStrings.clipboard(language)
                                                                .autoClearOnScreenLock,
                                                             FeatureStrings.clipboardIgnoredApps(language)
                                                                .listTitle]),
                                        (.pastePlain, [s.pastePlainName]),
                                       ]),
            ]),
            // Everything about the apps installed on the Mac lives together:
            // what is out of date, what is junk and what should go.
            (categories.appManagement, [
                SettingsDirectoryItem(page: .appUpdates,
                                      title: FeatureStrings.appUpdates(language).pageTitle,
                                      icon: "arrow.down.app",
                                      keywords: [FeatureStrings.appUpdates(language).checkNow,
                                                 FeatureStrings.appUpdates(language).frequencyLabel,
                                                 FeatureStrings.appUpdates(language).appStoreBadge,
                                                 s.homebrewName]),
                SettingsDirectoryItem(page: .cleaner, title: s.cleanerName, icon: "sparkles",
                                      keywords: [s.cleanerScheduleTitle,
                                                 FeatureStrings.whatsAppDownloads(language).title,
                                                 FeatureStrings.whatsAppDownloads(language).automatic,
                                                 FeatureStrings.whatsAppDownloads(language).fileTypes]),
                SettingsDirectoryItem(page: .homebrew, title: s.homebrewName, icon: "shippingbox"),
                SettingsDirectoryItem(page: .uninstaller, title: s.uninstallerName, icon: "trash",
                                      keywords: [s.uninstallerWatchTrashToggle]),
                SettingsDirectoryItem(page: .killProcess,
                                      title: FeatureStrings.killProcess(language).pageTitle,
                                      icon: "xmark.octagon",
                                      keywords: ["force quit", "process", "cpu", "memory", "kill"]),
                SettingsDirectoryItem(page: .portManager,
                                      title: FeatureStrings.portManager(language).title,
                                      icon: "network",
                                      keywords: ["port", "ports", "listening", "socket", "PID", "kill port"]),
                SettingsDirectoryItem(page: .memory,
                                      title: FeatureStrings.memory(language).title,
                                      icon: "memorychip",
                                      keywords: [FeatureStrings.memory(language).leftovers,
                                                 FeatureStrings.memory(language).heavyIdle,
                                                 FeatureStrings.memory(language).autoCleanTitle,
                                                 FeatureStrings.memory(language).idleAfterTitle,
                                                 FeatureStrings.memory(language).keepTitle,
                                                 FeatureStrings.memory(language).notifyTitle,
                                                 "RAM", "memory pressure", "orphan", "leftover"]),
                SettingsDirectoryItem(page: .claudeAccounts,
                                      title: FeatureStrings.claudeAccounts(language).title,
                                      icon: "person.2",
                                      keywords: [FeatureStrings.claudeAccounts(language).commandsTitle,
                                                 FeatureStrings.claudeAccounts(language).shellTitle,
                                                 FeatureStrings.claudeAccounts(language).statusLineTitle,
                                                 FeatureStrings.claudeAccounts(language).mcpTitle,
                                                 "Claude", "account", "accounts", "cc", "cx", "sign in", "MCP"]),
            ]),
            (categories.utilities, [
                SettingsDirectoryItem(page: .notch,
                                      title: notch.title,
                                      icon: "macbook",
                                      keywords: [notch.description, "notch"], terms: islandTerms),
            ]),
            (categories.app, [
                SettingsDirectoryItem(page: .shortcuts, title: s.shortcutsPageTitle, icon: "command"),
                SettingsDirectoryItem(page: .advanced, title: s.tabAdvanced, icon: "wrench.and.screwdriver"),
                SettingsDirectoryItem(page: .about, title: s.tabAbout, icon: "info.circle",
                                      keywords: [s.reviewIntro]),
            ]),
        ]
    }
}

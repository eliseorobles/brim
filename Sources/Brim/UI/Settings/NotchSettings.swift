// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NotchSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var notch = NotchService.shared
    @ObservedObject private var router = SettingsRouter.shared
    @AppStorage(DefaultsKey.notchAgentsEnabled) private var agentsEnabled = false
    @AppStorage(DefaultsKey.notchEnabled) private var enabled = false
    @AppStorage(DefaultsKey.notchDisplay) private var display = NotchDisplay.automatic.rawValue
    @AppStorage(DefaultsKey.notchSilhouette) private var silhouette = NotchSilhouette.capsule.rawValue
    @AppStorage(DefaultsKey.notchOpenOnHover) private var hover = false
    @AppStorage(DefaultsKey.notchShortcutEnabled) private var shortcutEnabled = false
    @AppStorage(DefaultsKey.notchHideInFullscreen) private var hideInFullscreen = false
    @AppStorage(DefaultsKey.notchHoverInFullscreen) private var hoverInFullscreen = false
    @AppStorage(DefaultsKey.notchHideUntilHover) private var hideUntilHover = false
    @AppStorage(DefaultsKey.notchHiddenShowsActivity) private var hiddenShowsActivity = false
    @AppStorage(DefaultsKey.notchCoversMenus) private var coversMenus = true
    @AppStorage(DefaultsKey.notchHoverDelay) private var hoverDelay = NotchSupport.defaultHoverDelay
    @AppStorage(DefaultsKey.notchCloseDelay) private var closeDelay = NotchSupport.defaultCloseDelay
    @AppStorage(DefaultsKey.notchReturnHome) private var returnHome = false
    @AppStorage(DefaultsKey.notchHomeModule) private var homeModule = NotchModule.controls.rawValue
    @AppStorage(DefaultsKey.notchOpensActivity) private var opensActivity = true
    @AppStorage(DefaultsKey.notchHiddenModules) private var hidden = ""
    @AppStorage(DefaultsKey.notchModuleOrder) private var order = ""
    @AppStorage(DefaultsKey.notchInputSource) private var inputSource = true
    @AppStorage(DefaultsKey.notchBattery) private var battery = true
    @AppStorage(DefaultsKey.notchClipboard) private var clipboard = true
    @AppStorage(DefaultsKey.notchClipboardWindow) private var clipboardWindow = true
    @AppStorage(DefaultsKey.notchClipboardCardSize) private var clipboardCardSize = NotchClipboardCardSize.comfortable.rawValue
    @AppStorage(DefaultsKey.notchIdleContent) private var idle = NotchIdleContent.none.rawValue
    @AppStorage(DefaultsKey.notchLowBatteryTint) private var lowBatteryTint = false
    @AppStorage(DefaultsKey.notchLowBatteryThreshold) private var lowBatteryThreshold = NotchSupport.defaultLowBatteryThreshold
    @AppStorage(DefaultsKey.notchLowBatteryEarly) private var earlyBatteryWarning = false
    @AppStorage(DefaultsKey.notchLowBatteryEarlyThreshold) private var earlyBatteryThreshold = NotchSupport.defaultEarlyBatteryThreshold
    @AppStorage(DefaultsKey.notchLowBatteryMenuBar) private var lowBatteryMenuBar = true
    @AppStorage(DefaultsKey.notchHiddenControls) private var hiddenControls = NotchControlItem.defaultHidden
    @AppStorage(DefaultsKey.notchControlOrder) private var controlOrder = ""
    @AppStorage(DefaultsKey.notchShowInCaptures) private var showInCaptures = true
    @AppStorage(DefaultsKey.notchLockScreen) private var lockScreen = false
    @AppStorage(DefaultsKey.notchLockSounds) private var lockSounds = false
    @AppStorage(DefaultsKey.notchSize) private var size = NotchSize.spacious.rawValue
    @AppStorage(DefaultsKey.notchOutlineEnabled) private var outlineEnabled = false
    @AppStorage(DefaultsKey.notchHideMenuBarGap) private var hideMenuBarGap = false
    @AppStorage(DefaultsKey.notchCustomWidth) private var customWidth = NotchSize.defaultWidth
    @AppStorage(DefaultsKey.notchCustomHeight) private var customHeight = NotchSize.defaultHeight
    @AppStorage(DefaultsKey.notchCameraFitWidth) private var cameraFitWidth = 0.0
    @AppStorage(DefaultsKey.notchCameraFitHeight) private var cameraFitHeight = 0.0
    @AppStorage(DefaultsKey.notchCapsuleFitWidth) private var capsuleFitWidth = 0.0
    @AppStorage(DefaultsKey.notchCapsuleFitHeight) private var capsuleFitHeight = 0.0
    @AppStorage(DefaultsKey.notchCapsuleFitDrop) private var capsuleFitDrop = 0.0
    @AppStorage(DefaultsKey.notchHapticFeedback) private var hapticFeedback = true
    @AppStorage(DefaultsKey.notchTranslucentBackground) private var translucentBackground = false
    @AppStorage(DefaultsKey.notchLiquidGlassEnabled) private var liquidGlass = false
    @AppStorage(DefaultsKey.notchAppPanel) private var appPanel = false
    @AppStorage(DefaultsKey.notchHidesMenuBarIcon) private var hidesMenuBarIcon = false
    @AppStorage(DefaultsKey.notchKeepAwakeActivity) private var keepAwakeActivity = false
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var clipboardHistoryEnabled = false
    @AppStorage(DefaultsKey.notchHoverExpands) private var hoverExpand = true
    @AppStorage(DefaultsKey.notchQuickAccessLayout) private var accessData = Data()
    @State private var tab = NotchSettingsTab.layout
    @State private var selectedModule = NotchModule.controls
    @State private var draggingModule: NotchModule?
    @State private var draggingControl: NotchControlItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }
    private var editor: NotchEditorStrings { FeatureStrings.notchEditor(l10n.language) }

    private var configuration: [String] {
        [String(enabled), idle, hiddenControls, controlOrder, size,
         String(outlineEnabled), String(hideMenuBarGap),
         String(customWidth), String(customHeight), String(cameraFitWidth), String(cameraFitHeight),
         String(capsuleFitWidth), String(capsuleFitHeight), String(capsuleFitDrop), String(hapticFeedback),
         String(appPanel),
         String(hoverExpand), String(hideUntilHover), String(hiddenShowsActivity), String(hideInFullscreen),
         String(hoverInFullscreen), String(coversMenus),
         display, silhouette, String(hover), hidden, order, String(inputSource),
         String(battery), String(clipboard), String(clipboardWindow), clipboardCardSize,
         String(showInCaptures),
         String(returnHome), homeModule, String(opensActivity),
         String(agentsEnabled), String(keepAwakeActivity), String(shortcutEnabled)]
    }

    private var access: Binding<NotchQuickAccessConfiguration> {
        Binding(get: { NotchQuickAccessConfiguration.stored() }, set: { accessData = $0.encoded })
    }

    private var orderedModules: [NotchModule] {
        let stored = order.split(separator: ",").compactMap { NotchModule(rawValue: String($0)) }
        var seen = Set<NotchModule>()
        return (stored + NotchModule.allCases).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(text.title).font(.title2.bold())
                    Text(text.description).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(text.enable, isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    .disabled(!AppFeature.notch.isAvailable).accessibilityLabel(text.enable)
            }
            if enabled, AppFeature.notch.isAvailable, !(hover && hideUntilHover && !hiddenShowsActivity), !notch.geometry.isNotched, !permissions.accessibility {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text.menuBarAccessHint)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PermissionRow()
                }
            }
            NotchSettingsTabRow(tab: $tab, language: l10n.language,
                                canOpen: enabled) { NotchService.shared.open() }
            if tab == .content {
                GeometryReader { proxy in contentEditor(in: proxy.size) }
            } else {
                pageScroll
            }
        }
        .padding(.horizontal, 22).padding(.top, 22)
        .onChange(of: configuration) { _, _ in NotchService.shared.syncWithPreferences() }
        .onChange(of: accessData) { _, _ in NotchService.shared.syncWithPreferences() }
        .onChange(of: tab) { _, _ in draggingModule = nil; draggingControl = nil }
        .onAppear(perform: revealDestination)
        .onChange(of: router.requestID) { _, _ in revealDestination() }
    }

    private var pageScroll: some View {
        ScrollView {
            Group {
                switch tab {
                case .layout: layoutPage
                case .content: EmptyView()
                case .activity: activityPage
                case .behavior: behaviorPage
                }
            }.padding(.bottom, 22)
        }.id(tab)
    }

    private func revealDestination() {
        guard let location = router.destination.notchLocation else { return }
        if case .module(let module) = location { selectedModule = module }
        tab = location.tab
    }

    private var layoutPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            NotchLayoutEditor(configuration: access, size: $size, width: $customWidth, height: $customHeight) {
                selectedModule = .controls; tab = .content
            }
            SettingsCard(title: text.size) {
                HStack(spacing: 10) {
                    choice(text.compact, symbol: "rectangle.compress.vertical", selected: size == NotchSize.compact.rawValue) { size = NotchSize.compact.rawValue }
                    choice(text.spacious, symbol: "rectangle.expand.vertical", selected: size == NotchSize.spacious.rawValue) { size = NotchSize.spacious.rawValue }
                    choice(text.custom, symbol: "arrow.up.left.and.arrow.down.right", selected: size == NotchSize.custom.rawValue) { size = NotchSize.custom.rawValue }
                }
                if size == NotchSize.custom.rawValue {
                    // One grid starts both sliders at the same edge in every language.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        dimensionSlider(text.width, value: $customWidth, range: NotchSize.widthRange, fallback: NotchSize.defaultWidth)
                        dimensionSlider(text.maximumHeight, value: $customHeight, range: NotchSize.heightRange, fallback: NotchSize.defaultHeight)
                    }
                    Text(text.sizeHint).font(.caption).foregroundStyle(.secondary)
                }
                // Liquid Glass takes the open island's background when it is
                // on and is already see-through, so the switch reads on and
                // changes nothing then.
                switchRow("drop.halffull", text.translucentBackground,
                          caption: liquidGlassIsOn ? text.translucentBackgroundGlassHint : text.translucentBackgroundHint,
                          isOn: liquidGlassIsOn ? .constant(true) : $translucentBackground)
                    .disabled(liquidGlassIsOn)
            }
            // Only a display without a camera can float the island.
            if NotchSupport.hasDisplayWithoutNotch {
                SettingsCard(title: text.withoutNotch) {
                    HStack(spacing: 10) {
                        silhouetteChoice(.capsule, title: text.capsuleShape)
                        silhouetteChoice(.notch, title: text.notchShape)
                    }
                    // An island kept on a camera, or away with the lid closed,
                    // shows neither shape, so the card says where to change that.
                    if enabled, !NotchService.reachesDisplayWithoutNotch(NotchDisplay(rawValue: display) ?? .automatic) {
                        Text(text.withoutNotchUnreached).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(text.showOnAllDisplays) { display = NotchDisplay.all.rawValue }
                    }
                }
                if NotchSilhouette(rawValue: silhouette) ?? .capsule == .capsule {
                    SettingsCard(title: text.capsuleFit) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            // Even widths keep the capsule centred on whole points.
                            fitSlider(text.width, card: text.capsuleFit, value: $capsuleFitWidth,
                                      range: NotchCapsuleFit.widthRange, step: 2)
                            fitSlider(text.height, card: text.capsuleFit, value: $capsuleFitHeight,
                                      range: NotchCapsuleFit.heightRange, step: 1)
                            fitSlider(text.fromTop, card: text.capsuleFit, value: $capsuleFitDrop,
                                      range: NotchCapsuleFit.dropRange, step: 1)
                        }
                        Text(text.capsuleFitHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard {
                switchRow("capsule", text.showOutline, isOn: $outlineEnabled)
            }
            // Only a physical camera has an outline to match.
            if NotchSupport.hasNotchedDisplay {
                SettingsCard(title: text.cameraFit) {
                    switchRow("rectangle.topthird.inset.filled", text.hideMenuBarGap,
                              caption: text.hideMenuBarGapHint, isOn: $hideMenuBarGap)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        // Whole points keep the island centred on the camera's pixels.
                        fitSlider(text.width, card: text.cameraFit, value: $cameraFitWidth,
                                  range: NotchCameraFit.widthRange, step: 1)
                        fitSlider(text.height, card: text.cameraFit, value: $cameraFitHeight,
                                  range: NotchCameraFit.heightRange, step: 0.5)
                    }
                    Text(text.cameraFitHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Whether the open island draws Liquid Glass, by the island's own rule.
    /// Reduce Transparency keeps it black, so the switch then shows the saved
    /// choice as it does with the glass off.
    private var liquidGlassIsOn: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *) { return liquidGlass && !reduceTransparency }
#endif
        return false
    }

    /// The sections in a list of their own, the chosen one's options beside
    /// it, and the island as it will look. A wide window keeps the preview
    /// in a column that never scrolls away; a narrow one puts it above the
    /// options, so they keep the height of the window either way.
    private func contentEditor(in size: CGSize) -> some View {
        let wide = size.width >= 940
        let listWidth: CGFloat = wide ? 216 : 196
        let previewWidth = wide ? min(560, ((size.width - listWidth - 32) * 0.5).rounded()) : 0
        let detailWidth = max(0, size.width - listWidth - 16 - (wide ? previewWidth + 16 : 0))
        return HStack(alignment: .top, spacing: 16) {
            sectionList
                .frame(width: listWidth, height: size.height, alignment: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let module = selectedModule
                    let available = module.isAvailable()
                    NotchSectionHeader(module: module, shown: isShown(module),
                                       reason: available ? nil : moduleFeature(module).map { $0.enableReason(l10n) } ?? text.disabled) {
                        SettingsRouter.shared.request(FeatureSettingsDestination(.features), targetFeature: moduleFeature(module))
                    }
                    if !wide { preview(width: detailWidth, limit: 280) }
                    if available, hasOptions(module) {
                        SettingsCard { moduleOptions(module) }
                    } else if available {
                        Text(editor.noOptions).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 22)
            }
            .id(selectedModule)
            .frame(width: detailWidth)
            if wide {
                preview(width: previewWidth, limit: size.height)
                    .frame(width: previewWidth)
            }
        }
    }

    private func preview(width: CGFloat, limit: CGFloat) -> some View {
        NotchIslandPreview(module: selectedModule, hidden: !isShown(selectedModule))
            .frame(height: NotchIslandPreview.height(width: width, limit: limit))
    }

    /// Every section in the island's order, each with the switch that shows it.
    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.sections).font(.headline)
                Text(editor.sectionsHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(orderedModules) { module in
                            NotchSectionListRow(module: module, included: moduleBinding(module), available: module.isAvailable(),
                                                selected: selectedModule == module,
                                                order: Binding(get: { orderedModules },
                                                               set: { order = $0.map(\.rawValue).joined(separator: ",") }),
                                                dragging: $draggingModule) { selectedModule = module }
                                .id(module)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                // A section chosen from the island itself may sit low in the list.
                .onAppear { reader.scrollTo(selectedModule) }
                .onChange(of: selectedModule) { _, module in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { reader.scrollTo(module) }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func isShown(_ module: NotchModule) -> Bool {
        module.isAvailable() && moduleBinding(module).wrappedValue
    }

    /// The system page arranges itself in the island.
    private func hasOptions(_ module: NotchModule) -> Bool {
        module != .system
    }

    @ViewBuilder private func moduleOptions(_ module: NotchModule) -> some View {
        switch module {
        case .controls:
            Text(text.controlShortcuts).font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                ForEach(orderedShortcuts) { item in
                    PanelReorderableItem(item: item,
                        order: Binding(get: { orderedShortcuts }, set: { controlOrder = $0.map(\.rawValue).joined(separator: ",") }),
                        dragging: $draggingControl) {
                        toggleCard(item.title(l10n), symbol: item.symbol, value: controlBinding(item), available: item.isAvailable(),
                                   reason: controlReason(item), reservesReason: !orderedShortcuts.allSatisfy { $0.isAvailable() },
                                   unavailableAction: controlUnavailableAction(item))
                    }
                }
            }
            Divider()
            let activities = FeatureStrings.notchActivities(l10n.language)
            SettingsFeatureSwitchRow(symbol: NotchControlItem.keepAwake.symbol, title: activities.keepAwakeActivity,
                                     caption: activities.keepAwakeActivityHint, isOn: $keepAwakeActivity, feature: .keepAwake)
        case .clipboard:
            destination(FeatureStrings.clipboard(l10n.language).title, symbol: "doc.on.clipboard", value: $clipboardWindow, available: AppFeature.clipboardHistory.isAvailable)
            switchRow("doc.on.clipboard", text.clipboardActivity, caption: text.privacy, isOn: $clipboard)
            if clipboardWindow, AppFeature.clipboardHistory.isAvailable {
                let size = FeatureStrings.notchClipboardSize(l10n.language)
                VStack(alignment: .leading, spacing: 6) {
                    // Read as the page reads it, so a value it does not know shows comfortable here too.
                    SettingsChoiceRow(symbol: "rectangle.compress.vertical", title: size.entrySize,
                                      selection: Binding(get: { NotchClipboardCardSize(stored: clipboardCardSize) },
                                                         set: { clipboardCardSize = $0.rawValue })) {
                        Text(size.compact).tag(NotchClipboardCardSize.compact)
                        Text(size.comfortable).tag(NotchClipboardCardSize.comfortable)
                    }
                    Text(size.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, settingsRowTextInset)
                }
            }
        case .agents:
            NotchAgentsSettingsControls()
        case .system:
            EmptyView()
        }
    }

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: editor.resting) {
                HStack(alignment: .top, spacing: 10) {
                    idleChoice(.none, title: text.idleNone, symbol: "minus")
                    if PowerSampler.hasInternalBattery {
                        idleChoice(.battery, title: text.battery, symbol: "battery.75percent",
                                   reason: AppFeature.monitorPower.enableReason(l10n)) { AppFeature.monitorPower.showInFeatures() }
                    }
                    // Offered once the section is on, and kept while it is the
                    // saved choice, waiting like the others.
                    if NotchSupport.canRest(with: .agents) || idle == NotchIdleContent.agents.rawValue {
                        idleChoice(.agents, title: FeatureStrings.notchAgents(l10n.language).restingTitle, symbol: "sparkles",
                                   reason: pageReason(.agents, feature: .notchAgents), fix: pageAction(.agents, feature: .notchAgents))
                    }
                }
                if restingChoice == .battery { lowBatteryControls }
                switchRow("menubar.rectangle", text.coverMenus, caption: text.coverMenusHint, isOn: $coversMenus)
            }
            SettingsCard(title: editor.feedback) {
                // A Mac without a battery has no battery notices, so that card
                // is left out rather than shown waiting for Power.
                let hasBattery = PowerSampler.hasInternalBattery
                let batteryAvailable = AppFeature.monitorPower.isAvailable
                let clipboardAvailable = AppFeature.clipboardHistory.isAvailable && clipboardHistoryEnabled
                    && NotchSupport.modules().contains(.clipboard)
                let reserves = ![batteryAvailable || !hasBattery, clipboardAvailable].allSatisfy { $0 }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    if hasBattery {
                        toggleCard(text.battery, symbol: "battery.75percent", value: $battery, available: batteryAvailable,
                                   reason: AppFeature.monitorPower.enableReason(l10n), reservesReason: reserves,
                                   unavailableAction: { AppFeature.monitorPower.showInFeatures() })
                    }
                    toggleCard(FeatureStrings.clipboard(l10n.language).title, symbol: "doc.on.clipboard", value: $clipboard,
                               available: clipboardAvailable, reason: clipboardFeedbackReason, reservesReason: reserves,
                               unavailableAction: { openClipboardFeedbackSetup() })
                    // A layout change is read straight from the system, so
                    // this card never waits on another feature.
                    toggleCard(text.inputSource, symbol: "keyboard", value: $inputSource,
                               available: true, reservesReason: reserves)
                }
            }
            let locked = FeatureStrings.notchLockScreen(l10n.language)
            SettingsCard(title: locked.title) {
                switchRow("lock.display", locked.show, caption: locked.showHint, isOn: $lockScreen)
                switchRow("speaker.wave.2", locked.sounds, caption: locked.soundsHint, isOn: $lockSounds)
            }
        }
    }

    private var behaviorPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: editor.opening) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    choice(editor.clickOpen, symbol: "cursorarrow", selected: !hover) { hideUntilHover = false; hover = false }
                    choice(editor.hoverPreview, symbol: "rectangle.topthird.inset.filled", selected: hover && !hoverExpand && !hideUntilHover) { hideUntilHover = false; hover = true; hoverExpand = false }
                    choice(editor.hoverExpand, symbol: "arrow.up.left.and.arrow.down.right", selected: hover && hoverExpand && !hideUntilHover) { hideUntilHover = false; hover = true; hoverExpand = true }
                    choice(editor.hiddenUntilHover, symbol: "eye.slash", selected: hover && hideUntilHover) { hover = true; hoverExpand = true; hideUntilHover = true }
                }
                if hover && hideUntilHover {
                    switchRow("sparkles", editor.hiddenShowsActivity,
                              caption: hiddenShowsActivity ? editor.hiddenShowsActivityHint : nil, isOn: $hiddenShowsActivity)
                }
                if hover || (hideInFullscreen && hoverInFullscreen) {
                    hoverDelayControl
                    if hoverExpand { closeDelayControl }
                }
                switchRow("keyboard", l10n.s.quickToolShortcutToggle, isOn: $shortcutEnabled)
                if shortcutEnabled {
                    ShortcutPreferenceRow(role: .notch) {
                        NotchService.shared.syncWithPreferences()
                    }
                    .padding(.leading, settingsRowTextInset)
                    if notch.shortcutRegistrationFailed {
                        Text(l10n.s.shortcutUnavailable)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, settingsRowTextInset)
                    }
                }
                switchRow("waveform.path", text.hapticFeedback, isOn: $hapticFeedback)
                SettingsRow(symbol: "arrow.uturn.backward", title: editor.reopening) {
                    Picker(editor.reopening, selection: Binding(get: {
                        guard returnHome else { return "" }
                        return NotchModule(rawValue: homeModule) != nil
                            || NotchReopeningDestination(rawValue: homeModule) != nil
                            ? homeModule : NotchModule.controls.rawValue
                    }, set: { value in
                        returnHome = !value.isEmpty
                        if returnHome { homeModule = value }
                    })) {
                        Text(editor.lastPage).tag("")
                        Text(text.panel).tag(NotchReopeningDestination.appPanel.rawValue)
                        Text(text.sectionsTitle).tag(NotchReopeningDestination.explore.rawValue)
                        ForEach(NotchSupport.modules()) { module in
                            Text(module.title(l10n.language)).tag(module.rawValue)
                        }
                        if let saved = NotchModule(rawValue: homeModule), !NotchSupport.modules().contains(saved) {
                            Text(saved.title(l10n.language)).tag(homeModule).disabled(true)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                switchRow("livephoto", editor.openActivity, caption: editor.openActivityHint, isOn: $opensActivity)
            }
            SettingsCard(title: text.display) {
                switchRow("arrow.up.left.and.arrow.down.right", text.hideInFullscreen, isOn: $hideInFullscreen)
                if hideInFullscreen {
                    switchRow("cursorarrow", text.hoverInFullscreen, isOn: $hoverInFullscreen)
                        .padding(.leading, settingsRowTextInset)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    // A mode this version no longer offers is treated as automatic, as the island does.
                    choice(text.automatic, symbol: "display.2",
                           selected: (NotchDisplay(rawValue: display) ?? .automatic) == .automatic) { display = NotchDisplay.automatic.rawValue }
                    choice(text.builtIn, symbol: "laptopcomputer", selected: display == NotchDisplay.builtIn.rawValue) { display = NotchDisplay.builtIn.rawValue }
                    choice(text.mainDisplay, symbol: "display", selected: display == NotchDisplay.main.rawValue) { display = NotchDisplay.main.rawValue }
                    choice(text.followPointer, symbol: "cursorarrow.motionlines",
                           selected: display == NotchDisplay.pointer.rawValue) { display = NotchDisplay.pointer.rawValue }
                    choice(text.allDisplays, symbol: "rectangle.on.rectangle",
                           selected: display == NotchDisplay.all.rawValue) { display = NotchDisplay.all.rawValue }
                }
            }
            SettingsCard(title: editor.destinations) {
                destination(text.panel, symbol: "bubble.middle.top", value: $appPanel)
                Text(editor.appPanelHint).font(.caption).foregroundStyle(.secondary)
                switchRow("menubar.rectangle", editor.hideMenuBarIcon, caption: editor.hideMenuBarIconHint,
                          isOn: $hidesMenuBarIcon)
                destination(FeatureStrings.clipboard(l10n.language).title, symbol: "doc.on.clipboard", value: $clipboardWindow, available: AppFeature.clipboardHistory.isAvailable)
            }
            SettingsCard(title: editor.privacy) {
                switchRow("camera.viewfinder", text.showInCaptures, isOn: $showInCaptures)
            }
        }
    }

    /// The resting charge can turn red once it runs low, and amber a little
    /// earlier, at levels the person picks.
    @ViewBuilder private var lowBatteryControls: some View {
        let strings = NotchLowBatteryStrings.localized(l10n.language)
        switchRow("battery.25percent", strings.title, caption: strings.caption, isOn: $lowBatteryTint)
        if lowBatteryTint {
            let red = NotchSupport.sanitizedLowBatteryThreshold(lowBatteryThreshold)
            levelSlider(strings.threshold, range: NotchSupport.batteryLevelScale,
                        value: Binding(get: { red },
                                       set: {
                                           lowBatteryThreshold = NotchSupport.sanitizedLowBatteryThreshold($0)
                                           // Raising red past amber carries amber along above it.
                                           earlyBatteryThreshold = NotchSupport.earlyBatteryThreshold(earlyBatteryThreshold,
                                                                                                     above: lowBatteryThreshold)
                                       }))
            switchRow("battery.50percent", strings.early, caption: strings.earlyCaption, isOn: $earlyBatteryWarning)
            if earlyBatteryWarning {
                // Both sliders share one fixed scale; amber stops just above red.
                levelSlider(strings.earlyThreshold, range: NotchSupport.batteryLevelScale,
                            value: Binding(get: { NotchSupport.earlyBatteryThreshold(earlyBatteryThreshold, above: red) },
                                           set: { earlyBatteryThreshold = NotchSupport.earlyBatteryThreshold($0, above: red) }))
            }
            switchRow("menubar.rectangle", strings.menuBar, isOn: $lowBatteryMenuBar)
        }
    }

    private func levelSlider(_ title: String, range: ClosedRange<Int>, value: Binding<Int>) -> some View {
        let formatted = "\(value.wrappedValue)%"
        let slider = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: slider, in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                Text(title)
            }.labelsHidden().accessibilityValue(formatted)
        }.padding(.leading, settingsRowTextInset)
    }

    private var hoverDelayControl: some View {
        delayControl(editor.activationTime, hint: editor.activationTimeHint, value: $hoverDelay,
                     range: NotchSupport.hoverDelayRange, sanitize: NotchSupport.sanitizedHoverDelay)
    }

    private var closeDelayControl: some View {
        delayControl(editor.closeTime, hint: editor.closeTimeHint, value: $closeDelay,
                     range: NotchSupport.closeDelayRange, sanitize: NotchSupport.sanitizedCloseDelay)
    }

    private func delayControl(_ title: String, hint: String, value stored: Binding<Double>,
                              range: ClosedRange<Double>, sanitize: @escaping (Double) -> Double) -> some View {
        let value = Binding(get: { sanitize(stored.wrappedValue) }, set: { stored.wrappedValue = sanitize($0) })
        let formatted = String(format: editor.activationTimeFormat, locale: Locale(identifier: l10n.language.rawValue), value.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.05) {
                Text(title)
            }.labelsHidden().accessibilityValue(formatted)
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 68).padding(8)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Each outline in a slice of menu bar, drawn as the island draws it.
    private func silhouetteChoice(_ item: NotchSilhouette, title: String) -> some View {
        let selected = (NotchSilhouette(rawValue: silhouette) ?? .capsule) == item
        return Button { silhouette = item.rawValue } label: {
            VStack(spacing: 10) {
                NotchSilhouetteSample(silhouette: item)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 68).padding(8)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func showModule(_ module: NotchModule) {
        selectedModule = module
        tab = .content
    }

    /// A control that opens a page is off while that page is hidden, or while
    /// the feature behind it is disabled; the others follow their feature.
    private func controlReason(_ item: NotchControlItem) -> String {
        switch item.setupRequirement {
        case .feature(let feature): return feature.enableReason(l10n)
        case .page(let module, let feature): return pageReason(module, feature: feature)
        case .none: return text.disabled
        }
    }

    private func controlUnavailableAction(_ item: NotchControlItem) -> (() -> Void)? {
        switch item.setupRequirement {
        case .feature(let feature):
            return { feature.showInFeatures() }
        case .page(let module, let feature):
            return pageAction(module, feature: feature)
        case .none: return nil
        }
    }

    /// The one feature a page needs; System accepts any of several.
    private func moduleFeature(_ module: NotchModule) -> AppFeature? {
        switch module {
        case .controls, .system: return nil
        case .clipboard: return .clipboardHistory
        case .agents: return .notchAgents
        }
    }

    private func pageReason(_ module: NotchModule, feature: AppFeature?) -> String {
        if let feature, !feature.isAvailable { return feature.enableReason(l10n) }
        return editor.showPage(module.title(l10n.language))
    }

    /// Where pageReason leads: Features while the feature is uninstalled,
    /// otherwise the section on the Content tab.
    private func pageAction(_ module: NotchModule, feature: AppFeature?) -> () -> Void {
        {
            if let feature, !feature.isAvailable { feature.showInFeatures() }
            else { showModule(module) }
        }
    }

    private var clipboardFeedbackReason: String {
        let title = FeatureStrings.clipboard(l10n.language).title
        if !AppFeature.clipboardHistory.isAvailable { return AppFeature.clipboardHistory.enableReason(l10n) }
        if !clipboardHistoryEnabled { return editor.enableSetting(FeatureStrings.clipboard(l10n.language).enable) }
        return editor.showPage(title)
    }

    private func openClipboardFeedbackSetup() {
        if !AppFeature.clipboardHistory.isAvailable { AppFeature.clipboardHistory.showInFeatures() }
        else if !clipboardHistoryEnabled { router.request(AppFeature.clipboardHistory.settingsDestination) }
        else { showModule(.clipboard) }
    }

    private func toggleCard(_ title: String, symbol: String, value: Binding<Bool>, available: Bool, reason: String? = nil,
                            reservesReason: Bool = false, unavailableAction: (() -> Void)? = nil) -> some View {
        NotchEditorItem(symbol: symbol, title: title, included: value, available: available,
                        unavailableReason: available ? nil : reason ?? text.disabled,
                        unavailableAction: unavailableAction, reservesReason: reservesReason) {
            value.wrappedValue.toggle()
        }
    }

    /// What the closed island rests with while it is on, by its own rule. The
    /// island switch stands apart, so with the island off this still shows
    /// what it would rest with. A saved battery reading on a Mac without a
    /// battery rests with nothing.
    private var restingChoice: NotchIdleContent {
        let choice = NotchSupport.idleContent()
        return choice == .battery && !PowerSampler.hasInternalBattery ? .none : choice
    }

    /// A resting choice. One the island cannot rest with just now stays
    /// choosable, dimmed, with what brings it back under it. The choice the
    /// island rests with is marked, and a saved one that waits keeps a fainter
    /// mark.
    private func idleChoice(_ item: NotchIdleContent, title: String, symbol: String,
                            reason: String? = nil, fix: @escaping () -> Void = {}) -> some View {
        let waits = reason != nil && !NotchSupport.canRest(with: item)
        let marked = restingChoice == item || (waits && idle == item.rawValue)
        return VStack(spacing: 6) {
            Button { idle = item.rawValue } label: {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        if item != .none {
                            Image(systemName: symbol).font(.system(size: 11))
                            RoundedRectangle(cornerRadius: 4).fill(.black).frame(width: 20, height: 12)
                            Text(item == .agents ? "62%" : "76%").font(.system(size: 9, weight: .medium))
                        } else { Color.clear.frame(width: 50, height: 12) }
                    }.foregroundStyle(.white).padding(10).background(.black, in: Capsule())
                    Text(title).font(.system(size: 11, weight: .medium))
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(marked ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityAddTraits(restingChoice == item ? .isSelected : [])
                // VoiceOver selects what the island rests with. A saved choice
                // that waits says it is hidden from the island, and the link
                // under it says why.
                .accessibilityValue(waits && idle == item.rawValue ? editor.hiddenInIsland : "")
                .opacity(waits ? 0.45 : 1)
            if waits, let reason {
                Button(reason, action: fix)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func destination(_ title: String, symbol: String, value: Binding<Bool>, available: Bool = true) -> some View {
        SettingsChoiceRow(symbol: symbol, title: title, selection: value) {
            Text(text.title).tag(true)
            Text(editor.separate).tag(false)
        }.disabled(!available)
    }

    /// An option with its icon, one line and a switch, like every other page.
    private func switchRow(_ symbol: String, _ title: String, caption: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title, caption: caption) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func dimensionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, fallback: Double) -> some View {
        let bounded = Binding(get: { NotchSize.clamped(value.wrappedValue, to: range, fallback: fallback) },
                              set: { value.wrappedValue = NotchSize.clamped($0, to: range, fallback: fallback) })
        return GridRow {
            // The slider carries the name for VoiceOver.
            Text(title).fixedSize().accessibilityHidden(true)
            Slider(value: bounded, in: range, step: 10) { Text(title) }.labelsHidden()
            Text(Int(bounded.wrappedValue), format: .number)
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
        }
    }

    /// A correction around zero, signed so the untouched value reads as none.
    private func fitSlider(_ title: String, card: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double) -> some View {
        let bounded = Binding(get: { NotchSize.clamped(value.wrappedValue, to: range, fallback: 0) },
                              set: { value.wrappedValue = NotchSize.clamped($0, to: range, fallback: 0) })
        let formatted = bounded.wrappedValue.formatted(.number.sign(strategy: .always(includingZero: false))
            .precision(.fractionLength(0...1)).locale(Locale(identifier: l10n.language.rawValue)))
        return GridRow {
            Text(title).fixedSize().accessibilityHidden(true)
            // Other cards have sliders with the same names.
            Slider(value: bounded, in: range, step: step) { Text("\(card), \(title)") }.labelsHidden()
                .accessibilityValue(formatted)
            Text(formatted).monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
        }
    }
    private var orderedShortcuts: [NotchControlItem] {
        let stored = controlOrder.split(separator: ",").compactMap { NotchControlItem(rawValue: String($0)) }
        var seen = Set<NotchControlItem>()
        return (stored + NotchControlItem.allCases).filter { seen.insert($0).inserted }
    }

    private func controlBinding(_ item: NotchControlItem) -> Binding<Bool> {
        Binding {
            !hiddenControls.split(separator: ",").contains(Substring(item.rawValue))
        } set: { shown in
            var values = Set(hiddenControls.split(separator: ",").map(String.init))
            if shown { values.remove(item.rawValue) } else { values.insert(item.rawValue) }
            hiddenControls = values.sorted().joined(separator: ",")
        }
    }

    private func moduleBinding(_ module: NotchModule) -> Binding<Bool> {
        Binding {
            (module != .agents || agentsEnabled)
                && !hidden.split(separator: ",").contains(Substring(module.rawValue))
        } set: { shown in
            if module == .agents { agentsEnabled = shown }
            var values = Set(hidden.split(separator: ",").map(String.init))
            if shown { values.remove(module.rawValue) } else { values.insert(module.rawValue) }
            hidden = values.sorted().joined(separator: ",")
        }
    }

}

extension NotchControlItem: PanelOrderItem {}

/// A standard menu bar on a display without a camera, at half size, with
/// the resting island in it.
private struct NotchSilhouetteSample: View {
    let silhouette: NotchSilhouette

    var body: some View {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
                                     cameraWidth: 0, menuBarHeight: 24, silhouette: silhouette)
        let island = geometry.restingSize(showsContent: false)
        ZStack(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: geometry.menuBarHeight)
            // Menus on the left and status items on the right, clear of the island.
            HStack(spacing: 9) {
                ForEach([26, 36, 30], id: \.self) { width in
                    Capsule().fill(.primary.opacity(0.22)).frame(width: CGFloat(width), height: 8)
                }
                Spacer(minLength: 0)
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.primary.opacity(0.22)).frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: geometry.menuBarHeight)
            NotchShape.island(height: island.height, geometry: geometry).fill(.black)
                .frame(width: island.width, height: island.height)
        }
        .frame(width: 400, height: 48, alignment: .top)
        .background(.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(0.5)
        .frame(width: 200, height: 24)
        .accessibilityHidden(true)
    }
}

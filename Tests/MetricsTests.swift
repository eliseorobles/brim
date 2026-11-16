// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// The runner lists every independently selectable suite. A filtered run says
// exactly which suites ran; an unknown or empty selection is an error.
@main
struct MetricsTests {
    static func main() {
        // A child this binary starts for a test runs one probe and exits
        // (FileEventStreamTests: the real FSEvents backend under a 256
        // descriptor limit, which only a separate process can lower safely).
        if CommandLine.arguments.dropFirst().first == FileEventStreamTests.descriptorProbeFlag {
            exit(FileEventStreamTests.descriptorProbe(Array(CommandLine.arguments.dropFirst(2))))
        }
        let suite = TestSuite()
        let groups: [(String, () -> Void)] = [
            ("brim", { BrimForkTests.run(suite) }),
            ("claude-accounts", {
                BrimClaudeAccountsTests.run(suite)
                BrimClaudeAccountsAppTests.run(suite)
                BrimClaudeSignInTests.run(suite)
                BrimClaudeMCPTests.run(suite)
            }),
            ("claude-own-folders", { BrimClaudeAccountsTests.ownFolderChecks(suite) }),
            ("file-events", {
                FileEventStreamTests.run(suite)
                FileEventStreamTests.descriptorChecks(suite)
            }),
            ("memory", {
                BrimMemoryTests.run(suite)
                BrimMemoryTests.reviewFixes(suite)
                BrimMemoryTests.runawayAndAlerts(suite)
            }),
            ("harness", {
                TestHarnessTests.run(suite)
                PreferenceNamespaceTests.run(suite)
            }),
            ("metrics", {
                MetricsFeatureTests.run(suite)
                DiskCapacityTests.run(suite)
                MenuBarBatteryWarningTests.run(suite)
                ProcessNameContract.run(suite)
                SystemMonitorCPUTests.run(suite)
                SystemMonitorPlanTests.run(suite)
                SystemSectionBreakdownTests.run(suite)
                PeripheralBatteryLifecycleTests.run(suite)
            }),
            ("clipboard", {
                ClipboardFeatureTests.run(suite)
                ClipboardFeatureTests.listShortcutAndFoldingChecks(suite)
                PastePlainTests.run(suite)
            }),
            ("screens", { PointerScreenContract.run(suite) }),
            ("preferences", { PreferencesFeatureTests.run(suite) }),
            ("app-management", {
                AppManagementFeatureTests.run(suite)
                AppManagementFeatureTests.systemApplicationChecks(suite)
                AppIdentityTests.run(suite)
            }),
            ("overlays", {
                OverlayPanelTests.run(suite)
                OverlayPanelTests.accessibilityChecks(suite)
            }),
            ("repository", { RepositoryFeatureTests.run(suite) }),
            ("transient-paste", { TransientPasteTests.run(suite) }),
            ("notch", {
                NotchTests.run(suite)
                NotchCompactTests.run(suite)
                NotchCapsuleTests.run(suite)
                NotchSettingsTabRowTests.run(suite)
                NotchPresentationProbeArgumentTests.run(suite)
            }),
            ("menu-bar", { MenuBarFeatureTests.run(suite) }),
            ("agents", { NotchAgentTests.run(suite) }),
            ("features", {
                FeatureCatalogTests.run(suite)
                MenuPanelSectionGateContract.run(suite)
            }),
            ("shortcut-clearing", { ShortcutClearingTests.run(suite) }),
            ("utilities", {
                UtilitiesFeatureTests.run(suite)
                UtilitiesFeatureTests.killProcessStringChecks(suite)
                PortManagerRefreshTests.run(suite)
            }),
            ("settings", {
                SettingsFeatureTests.run(suite)
                SettingsFeatureTests.windowActivationChecks(suite)
                SettingsSearchCoverageTests.run(suite)
                SettingsWindowTests.run { suite.expect($0, $1) }
                NotchSettingsChoiceTests.run(suite)
                MonitorTokenTests.run(suite)
            }),
            ("feature-hub-layout", { FeatureHubLayoutTests.run(suite) }),
            ("keyboard", {
                KeyboardFeatureTests.run(suite)
                KeyboardFeatureTests.systemShortcutChecks(suite)
                KeyboardFeatureTests.sessionActivityChecks(suite)
                AssistiveKeyboardTests.run(suite)
            }),
            ("storage", { StorageFeatureTests.run(suite) }),
            ("network", {
                NetworkFeatureTests.run(suite)
                SpeedTestTests.run(suite)
                NetworkAddressTests.run { suite.expect($0, $1) }
            }),
            ("app-updates", {
                UpdateFeatureTests.run(suite)
                LaunchAtLoginSettingsTests.run(suite)
                OnboardingCompletionTests.run(suite)
                AppUpdateHandoffTests.run(suite)
                AppUpdatesContract.run(suite)
                AppUpdateRulesContract.run(suite)
            }),
            ("localization", {
                LocalizationTests.run(suite)
                LocalizationFeatureContractTests.run(suite)
                LocalizationFeatureContractTests.sortingChecks(suite)
            }),
            ("cleaner", {
                CleanerEligibilityTests.run(suite)
                CleanerLastRunContract.run(suite)
                CleanerScanFlowTests.run(suite)
                CleanerLayoutTests.run(suite)
            }),
            ("uninstaller", {
                HomebrewOwnershipTests.run(suite)
                HomebrewOperationLogRetentionTests.run(suite)
                UninstallerFlowTests.run(suite)
                UninstallerTrashTests.run(suite)
                UninstallerBulkSelectionTests.run(suite)
                MixedStateCheckboxTests.run(suite)
                SelfUninstallContract.run(suite)
            }),
            ("force-quit", { ProcessForceQuitTests.run(suite) }),
            ("keep-awake", {
                MenuPanelToggleLabelContract.run(suite)
                KeepAwakeLidSleepTests.run { suite.expect($0, $1) }
                KeepAwakeTimerHandoffTests.run { suite.expect($0, $1) }
            }),
        ]
        var selected = Set<String>()
        var listOnly = false
        for argument in CommandLine.arguments.dropFirst() {
            if argument == "--list" {
                listOnly = true
                continue
            }
            guard argument.hasPrefix("--suite="),
                  groups.contains(where: { $0.0 == String(argument.dropFirst(8)) }) else {
                fputs("Unknown test selection: \(argument)\n", stderr)
                exit(2)
            }
            selected.insert(String(argument.dropFirst(8)))
        }
        if listOnly {
            groups.forEach { print($0.0) }
            exit(0)
        }
        for (name, body) in groups where selected.isEmpty || selected.contains(name) {
            suite.run(name, body)
        }
        suite.finish()
    }
}

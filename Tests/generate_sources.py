#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

"""Compile selected production methods against test doubles, without an app.

Bodies are read verbatim on every build, never copied into a maintained fixture.
The narrow declaration/indentation contract fails closed if a method moves or
changes shape; the Swift compiler then checks the generated source normally.
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/generated-tests"


def declaration(path, prefix, scope=None, *, closing="}"):
    lines = (ROOT / path).read_text().splitlines(keepends=True)
    lower, upper = 0, len(lines)
    if scope is not None:
        scopes = [i for i, line in enumerate(lines) if line.startswith(scope)]
        if len(scopes) != 1:
            raise ValueError(f"Expected one scope {scope!r} in {path}")
        lower = scopes[0] + 1
        upper = next(i for i in range(lower, len(lines)) if lines[i].rstrip() == "}")
    starts = [i for i in range(lower, upper) if lines[i].startswith(prefix)]
    if len(starts) != 1:
        raise ValueError(f"Expected one declaration {prefix!r} in {path}")
    start = starts[0]
    indent = prefix[:len(prefix) - len(prefix.lstrip())]
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip() == indent + closing)
    body = "".join(lines[start:end + 1])
    return f'#sourceLocation(file: {json.dumps(path)}, line: {start + 1})\n{body}\n#sourceLocation()\n'


WRITTEN = set()


def write(name, text):
    WRITTEN.add(name)
    path = OUTPUT / name
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def prune():
    """A test deleted with its generator block must not leave its old output
    in the folder the test binary compiles wholesale."""
    for path in OUTPUT.glob("*.swift"):
        if path.name not in WRITTEN:
            path.unlink()


def availability_declaration(path, prefix):
    return declaration(path, prefix).replace(".feature.isAvailable", ".feature.isAvailable(in: ReviewDefaults.current)")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    shortcut_row = "Sources/Brim/UI/ShortcutRecorderButton.swift"
    # Keep the registrars, takeover ownership and recording lifecycle intact.
    # Only the existing preference-reader arguments point at the isolated suite;
    # Carbon, WindowServer, windows and unrelated features are boundary doubles.
    def shortcut_preferences(body):
        if body.count(".assignedShortcut()") != 1:
            raise ValueError("Expected one shortcut preference reader in the registrar")
        return (body.replace(".assignedShortcut()",
                             ".assignedShortcut(storedValue: { UserDefaults.standard.string(forKey: $0) })")
                .replace("AppFeature.keepAwake.isAvailable",
                         "AppFeature.keepAwake.isAvailable(in: UserDefaults.standard)"))

    row_actions = "".join(declaration(shortcut_row, prefix).replace("private func", "func", 1)
                          for prefix in ["    private func clear()", "    private func reset()",
                                         "    private func save(_ shortcut:"])
    if row_actions.count("excluding: role,") != 1 or row_actions.count("includeInactive: includeInactiveConflicts)") != 1:
        raise ValueError("Expected one injectable role-conflict lookup in the shortcut row")
    row_actions = row_actions.replace(
        "excluding: role,",
        "excluding: role, isOn: { UserDefaults.standard.bool(forKey: $0) }, "
        "isAvailable: { $0.isAvailable(in: UserDefaults.standard) },")
    row_actions = row_actions.replace(
        "includeInactive: includeInactiveConflicts)",
        "includeInactive: includeInactiveConflicts, "
        "storedValue: { UserDefaults.standard.string(forKey: $0) })")
    write("ShortcutClearing.swift", "import AppKit\nimport Carbon.HIToolbox\nimport Combine\n"
          + "extension ShortcutClearingTests {\n"
          + shortcut_preferences(declaration("Sources/Brim/Services/HotkeyManager.swift",
                                              "final class HotkeyManager:"))
          + declaration("Sources/Brim/Services/QuickTools/QuickToolHotkey.swift", "final class QuickToolHotkey {")
          + declaration("Sources/Brim/Services/SystemShortcutTakeover.swift", "enum SystemShortcutTakeover {")
          + declaration("Sources/Brim/Services/ShortcutCapture.swift", "enum ShortcutCapture {")
          + declaration(shortcut_row, "final class RecorderButton:")
          + "final class Row: RowState {\n" + row_actions
          + "}\n}\n")
    write("TransientPasteRuntime.swift", "import AppKit\nimport Carbon.HIToolbox\nimport CoreGraphics\n"
          + "extension TransientPasteTests {\n"
          + declaration("Sources/Brim/Services/TransientPaste.swift", "final class TransientPaste {")
              .replace("NSPasteboard.general", "TransientPasteTests.pasteboard")
          + "}\n")
    general = "Sources/Brim/UI/Settings/GeneralSettings.swift"
    write("LaunchAtLoginSettings.swift", "import Foundation\n"
          + "extension LaunchAtLoginSettingsTests.View {\n"
          + "".join(declaration(general, prefix).replace("private func", "func", 1)
                    for prefix in ["    private func refreshLaunchAtLogin()",
                                   "    private func setLaunchAtLogin("])
          + "}\n")
    cleaner_view = "Sources/Brim/UI/Cleaner/CleanerView.swift"
    feature_hub = "Sources/Brim/UI/Settings/FeatureHubSettings.swift"
    write("FeatureHubLayout.swift", "import AppKit\nimport SwiftUI\nextension FeatureHubLayoutTests.Page {\n"
          + "".join(declaration(feature_hub, prefix).replace("    private var", "    var", 1)
                    for prefix in ["    private var content:", "    private var restartCard:"])
          + "}\nextension FeatureHubLayoutTests {\n"
          + declaration("Sources/Brim/UI/Settings/SettingsCard.swift", "struct SettingsCard<")
          + "}\n"
          + declaration(feature_hub, "private struct FeatureHubScrollAnchor:"))
    write("CleanerLayout.swift", "import SwiftUI\nextension CleanerLayoutTests.Results {\n"
          + "".join(declaration(cleaner_view, prefix).replace("    private ", "    @ViewBuilder\n    ", 1)
                    for prefix in ["    private var resultsState:", "    private var resultsGroups:",
                                   "    private func section("])
          + "}\n")
    write("NotchActivityPicker.swift", "import SwiftUI\n"
          + declaration("Sources/Brim/UI/Notch/NotchView.swift", "struct NotchShape: Shape {")
          + declaration("Sources/Brim/UI/Notch/NotchView.swift", "struct NotchActivityPicker: View {"))
    write("NotchModuleTitle.swift", "import Foundation\nextension NotchModule {\n"
          + declaration("Sources/Brim/UI/Notch/NotchView.swift", "    func title(_ language: AppLanguage)",
                        scope="extension NotchModule: PanelOrderItem {")
          + "}\n")
    panel = "Sources/Brim/App/AppDelegate.swift"
    write("OnboardingCompletion.swift", "import AppKit\nimport Foundation\n"
          + "extension OnboardingCompletionTests {\nfinal class Host: Fixture {\n"
          + "".join(declaration(panel, prefix).replace("    private ", "    ", 1) for prefix in [
              "    func windowWillClose(", "    private func markOnboardingComplete()"])
          + "}\n}\n")
    write("MenuPanelRecovery.swift", "import AppKit\nimport Foundation\n"
          + "extension MenuPanelRecoveryTests {\nfinal class Host: Fixture {\n"
          + "".join(declaration(panel, prefix).replace("private ", "") for prefix in [
              "    private struct PanelAnchor", "    private func statusButtonMidX(",
              "    private func statusScreen(", "    private func positionSettingsWindow(",
              "    private var freshStatusClick:", "    private func captureStatusClick(",
              "    private func correctedPopoverMidX(", "    private func resolvePanelAnchor(",
              "    private func frameStillDescribesMenuBar(", "    private func statusFrameNeedsAnchorOverride(",
              "    private func anchorVisibleFrame(", "    private func applyPopoverDriftFrame(",
              "    private func beginPopoverDriftCorrection(window: NSWindow, anchor: PanelAnchor) {",
              "    private func armPopoverDriftCorrection(", "    private func endPopoverDriftCorrection(",
              "    private func showPopover(", "    func popoverWillClose(", "    func popoverDidClose(",
              "    private func finishPopoverClose(",
              "    private func releasePanelResources(", "    private func anchorAfterForeignClose(",
              "    private func reopenPanelAfterForeignClose(", "    private func shouldDismissPopover(",
              "    private var popoverIsOpen:", "    private func showMetricPanel(",
              "    private func reanchorMetricPopover(", "    private func switchMetricPopover(",
              "    private func beginPanelActivationTracking(", "    private func updatePanelActivationSource(",
              "    private func endPanelActivationTracking(", "    private func returnActivation(",
              "    private func runPopoverCloseCompletions(",
              "    private struct PanelPresentation", "    private func beginPanelPresentationWatch(",
              "    private func logPanelPresentation(", "    private func endPanelPresentationWatch(",
              "    private static func milliseconds(",
              "    private func closePopoverNow(", "    private func fadeOutPopover(",
              "    private func finishPopoverFadeOut(", "    private func closePopoverWithoutAnimation("])
          .replace(", privacy: .public", "")
          .replace("func endPanelActivationTracking()", "@discardableResult func endPanelActivationTracking()")
          + "func closePopover(animated: Bool = true, reason: PanelCloseReason) { closePopoverNow(animated: animated, reason: reason, completion: nil) }\n"
          + "var popoverAnchor: PanelAnchor?\nvar lastGoodPanelAnchor: PanelAnchor?\n"
          + "var panelPresentation: PanelPresentation?\nvar panelPresentationSerial = 0\nvar panelPresentationObservers: [NSObjectProtocol] = []\n"
          + "}\n}\n")
    write("MenuPanelKey.swift", "import Foundation\nimport Carbon.HIToolbox\n"
          + "extension MenuPanelKeyTests {\nfinal class Host: Fixture {\n"
          + "".join(declaration(panel, prefix).replace("private ", "", 1) for prefix in [
              "    private func handlePopoverKeyDown(", "    private func isPlainPopoverHoldKey(",
              "    private func isTextEditingActive("])
          + "}\n}\n")
    menu_panel = "Sources/Brim/UI/MenuPanel/MenuPanelView.swift"
    fan_control = "Sources/Brim/Services/FanControl/FanControlService.swift"
    write("FanControlResume.swift", "import Foundation\n"
          + "extension FanControlResumeContract {\nfinal class Service: Fixture {\n"
          + "".join(declaration(fan_control, prefix)
                    .replace("@objc private func", "func", 1)
                    .replace("private static var", "static var", 1)
                    .replace("private func", "func", 1) for prefix in [
                        "    static func recoverIfNeeded(", "    func syncWithPreferences(",
                        "    func returnToSystem(", "    func resumePreferenceDidChange(",
                        "    private static var resumableConfiguration:", "    private func resume(",
                        "    private static var helperAwaitsRegistration:",
                        "    private func rememberForResume(", "    private func stopIdleWorkIfPossible(",
                        "    @objc private func workspaceDidWake("])
          + "}\n}\n")
    write("FanControlRecovery.swift", "import Foundation\n"
          + "extension FanControlRecoveryContract {\nfinal class Controller: Fixture {\n"
          + "".join(declaration("Sources/FanControlHelper/main.swift", prefix)
                    .replace("private func", "func", 1) for prefix in [
                        "    private func requestedLevel(", "    private func performRestore(",
                        "    private func watchdogTick()", "    private func stopWatchdogIfIdle()"])
          + "}\n}\n")
    fan_hardware = "Sources/Brim/Services/FanControl/FanControlHardware.swift"
    write("FanControlHardwareContract.swift", "import Foundation\nextension FanControlHardwareContract {\n"
          + declaration(fan_hardware, "enum FanControlHardwareError:")
          + declaration(fan_hardware, "final class FanControlHardware {")
          + "}\n")
    clipboard = "Sources/Brim/Services/Clipboard/ClipboardHistoryService.swift"
    pending_restore = [line for line in (ROOT / clipboard).read_text().splitlines(keepends=True)
                       if line.startswith("    private var pendingRestore:")]
    if len(pending_restore) != 1:
        raise ValueError("Expected one pending clipboard restore declaration")
    write("ClipboardCaptureRestore.swift", "import AppKit\nimport Foundation\nimport Combine\n"
          + "extension ClipboardCaptureRestoreTests {\nfinal class Service: Fixture {\n"
          + pending_restore[0].replace("private ", "", 1)
          + declaration(clipboard, "    @Published private(set) var entries:")
          + "".join(declaration(clipboard, prefix).replace("private ", "", 1) for prefix in [
              "    private enum CapturedContent", "    private func captureIfChanged(",
              "    private static func readPasteboard(", "    private func matchingEntry(",
              "    private func stop()", "    private func promote(", "    private func touch(",
              "    private var firstRecentIndex:", "    private func normalizeEntryOrder(",
              "    private func insertPromoted("])
          + "func setEntries(_ values: [ClipboardHistoryEntry]) { entries = values }\n"
          + "}\n}\n")
    write("ClipboardPreview.swift", "import Foundation\nimport Combine\n"
          + "extension ClipboardPreviewContract {\nfinal class Service: Fixture {\n"
          + declaration(clipboard, "    @Published private(set) var entries:")
          + declaration(clipboard, "    func updateText(")
          + "".join(declaration(clipboard, prefix).replace("private ", "", 1) for prefix in [
              "    func togglePin(", "    func clearRecent(", "    var recentEntries:", "    var recentEntriesSnapshot:",
              "    func copy(_ entry:", "    func copy(_ selectedEntries:", "    private func touch(",
              "    private var firstRecentIndex:", "    private func normalizeEntryOrder(",
              "    func filteredEntries(", "    var filteredQuickEntries:", "    var selectedQuickEntry:",
              "    func moveQuickSelection(", "    func removeSelectedQuickEntries(",
              "    private var quickBatchEntries:", "    private func quickEntriesForPrimaryAction(",
              "    private func selectedQuickIndex(", "    private func promote(",
              "    private func insertPromoted("])
          + "func setEntries(_ values: [ClipboardHistoryEntry]) { entries = values }\n"
          + "}\n}\n")
    ports = "Sources/Brim/Services/PortManager/PortManagerService.swift"
    write("PortManagerRefresh.swift", "import Darwin\nimport Foundation\n"
          + "extension PortManagerRefreshTests {\nfinal class Service: Fixture {\n"
          + declaration(ports, "    func refresh(")
          + declaration(ports, "    private static func snapshot(").replace("private static", "static", 1)
          + declaration(ports, "    private static func startTimes(").replace("private static", "static", 1)
          + "}\n}\n")
    write("ProcessName.swift", "import Foundation\n"
          + "extension ProcessNameContract {\nfinal class Lookup: Fixture {\n"
          + declaration("Sources/Brim/Services/ResponsibleProcess.swift", "    static func displayName(")
          + "}\n}\n")
    disk_sampler = "Sources/Brim/Services/Metrics/DiskSampler.swift"
    write("DiskCapacity.swift", "import Foundation\nextension DiskCapacityTests {\n"
          + "final class Sampler: Fixture {\n"
          + "".join(declaration(disk_sampler, prefix).replace("    private ", "    ", 1)
                    for prefix in ["    private struct DiskMetadata {", "    private struct MountedVolume {",
                                   "    func sample(", "    private static func bestCounter(",
                                   "    private func metadata(", "    private func sortVolumes(",
                                   "    private static func mountedVolumes(", "    private static func importantFree(",
                                   "    private static func positiveUInt(_ value: Int?)",
                                   "    private static func positiveUInt(_ value: Int64?)"])
          + "}\nfinal class Alerts {\n"
          + declaration("Sources/Brim/Services/SystemMonitor/MonitorAlertService.swift",
                        "    private func lowDisk(").replace("private func", "func", 1)
          + "}\n}\n")
    write("SystemMonitorCPU.swift", "import Darwin\nimport Foundation\n"
          + "extension SystemMonitorCPUTests {\nfinal class Monitor: Fixture {\n"
          + declaration("Sources/Brim/Services/SystemMonitor/SystemMonitor.swift",
                        "    private func readCPUUsage(").replace("private func", "func", 1)
          + "}\n}\n")
    monitor = "Sources/Brim/Services/SystemMonitor/SystemMonitor.swift"
    write("SystemMonitorPlan.swift", "import Foundation\n"
          + "extension SystemMonitorPlanTests {\n"
          + declaration(monitor, "struct SystemMonitorPanelNeeds")
          + "final class Monitor: Fixture {\n"
          + declaration(monitor, "    private struct SamplingPlan").replace("private struct", "struct", 1)
          + declaration(monitor, "    private func currentPlan(").replace("private func", "func", 1)
          + "}\n"
          # What the panel and its details ask the monitor for, as shipped.
          + "enum MetricDetailKind {\n"
          + "\n".join(line for line in declaration("Sources/Brim/UI/MenuPanel/MetricDetailView.swift",
                                                   "enum MetricDetailKind:").splitlines()
                      if line.startswith("    case "))
          + "\n" + declaration("Sources/Brim/UI/MenuPanel/MetricDetailView.swift", "    var monitorNeeds:",
                               scope="enum MetricDetailKind:")
          + "}\nfinal class Panel: PanelFixture {\n"
          + declaration("Sources/Brim/UI/MenuPanel/MenuPanelView.swift",
                        "    private var monitorNeeds:").replace("private var", "var", 1)
          + "}\n}\n")
    write("SystemSectionBreakdown.swift", "import Foundation\n"
          + "extension SystemSectionBreakdownTests {\nfinal class Section: Fixture {\n"
          + declaration("Sources/Brim/UI/MenuPanel/SystemSection.swift",
                        "    private func refreshBreakdown(").replace("private func", "func", 1)
          + declaration("Sources/Brim/UI/MenuPanel/SystemSection.swift",
                        "    private func toggleCPUApps(").replace("private func", "func", 1)
          + "}\n}\n")
    uninstall = "Sources/Brim/Services/Uninstall/AppUninstaller.swift"
    write("QuickPaste.swift", "import Foundation\n"
          + "extension ClipboardFeatureTests.QuickPasteHost {\n"
          + declaration("Sources/Brim/Services/Clipboard/ClipboardHistoryService.swift",
                        "    private func pasteIntoPreviousApp(").replace("private func", "func", 1)
          + "}\n")
    write("ClipboardPanelPlacement.swift", "import AppKit\n"
          + "extension ClipboardFeatureTests.PanelPlacementHost {\n"
          + "".join(declaration(clipboard, prefix).replace("private func", "func", 1) for prefix in [
              "    private func observePanelGeometry(", "    private func savePanelPosition(",
              "    private func refreshQuickLayout(", "    private func panelMinimumContentSize(",
              "    private func preferredPanelSize(", "    private func savePanelSize(",
              "    private func position(", "    private func resize("])
          + "}\nextension ClipboardFeatureTests {\n"
          + declaration(clipboard, "private final class ClipboardPanelSizeLimit").replace(
              "private final class", "final class", 1)
          + "}\n")
    paste_plain = "Sources/Brim/Services/QuickTools/PastePlainService.swift"
    write("PastePlain.swift", "import AppKit\nimport UniformTypeIdentifiers\n"
          + "extension PastePlainTests {\nfinal class Service: Fixture {\n"
          + "".join(declaration(paste_plain, prefix).replace("private func", "func", 1)
                    for prefix in ["    func performPastePlain()", "    private func pastePlain(",
                                   "    static func plainText("])
          + "}\n}\nextension PastePlainTests.OriginalPasteHost {\n"
          + declaration("Sources/Brim/Services/TransientPaste.swift", "    func pasteCurrentContents(")
          + "}\n")
    write("ClipboardSource.swift", "import Foundation\n"
          + "extension ClipboardFeatureTests.SourceHost {\n"
          + declaration("Sources/Brim/Services/Clipboard/ClipboardIgnoredApps.swift",
                        "    func sourceSinceLastCheck(")
          + "}\n")
    write("CommandBarFeatureNames.swift", "import Foundation\nextension AppFeature {\n"
          + declaration("Sources/Brim/UI/Settings/FeatureHubSettings.swift", "    func hubTitle(")
          + "}\n")
    write("PointerScreen.swift", "import AppKit\n"
          + "extension PointerScreenContract.Screen {\n"
          + declaration("Sources/Brim/Core/AppKitExtensions.swift", "    static var withMouse:")
          + "}\n")
    write("MixedStateCheckbox.swift", "import AppKit\nimport SwiftUI\n"
          + declaration("Sources/Brim/UI/SharedUI.swift", "struct MixedStateCheckbox:"))
    write("UninstallerFlow.swift", "import AppKit\nimport Carbon.HIToolbox\nimport Combine\n"
          + "extension UninstallerFlowTests {\n"
          + declaration(uninstall, "    enum Phase:")
          + declaration(uninstall, "    enum Category:")
          + "final class Uninstaller: UninstallerState {\nstatic let shared = Uninstaller()\n"
          + "".join(line + "\n" for line in (ROOT / uninstall).read_text().splitlines()
                    if line.startswith(("    var selectedSize:", "    var totalSize:")))
          + "".join(declaration(uninstall, prefix) for prefix in [
              "    var selectedHomebrewPackage:", "    var isRemovingWithHomebrew:",
              "    var isRemoving: Bool", "    var canRemoveSelected: Bool", "    func select(appURL:",
              "    func retryHomebrewCheck()",
              "    func reset()", "    func setInclude(", "    func setAllIncluded(",
              "    var bulkSelection:", "    struct HomebrewRemovalConfirmation",
              "    var homebrewRemovalConfirmation:", "    func removeSelectedWithHomebrew("])
          + "}\n}\n")
    # Run the whole selection and removal model. Only the platform inputs and
    # the final Trash destination are redirected into the disposable home.
    trash_model = declaration(uninstall, "final class AppUninstaller:")
    for system, fixture in [
        ("FileManager.default.homeDirectoryForCurrentUser", "fixtureHome"),
        ("fm.homeDirectoryForCurrentUser", "fixtureHome"),
        ("NSHomeDirectory()", "fixtureHome.path"),
        ("UninstallerSupport.searchFolders(", "fixtureFolders("),
        ("roots: spotlightRoots(home: home)", "roots: []"),
        ("!codeSignatureIsValid(at: appURL)", "fixtureGroups[appURL] == nil"),
        ("= codeSigningIdentity(at:", "= fixtureSigningIdentity(at:"),
        ("fm.trashItem(at: item.url, resultingItemURL: nil)", "moveToFixtureTrash(item.url)"),
    ]:
        if system not in trash_model:
            raise ValueError(f"Uninstaller Trash fixture no longer redirects {system}")
        trash_model = trash_model.replace(system, fixture)
    write("UninstallerTrash.swift", "import AppKit\nimport Combine\nimport CoreServices\nimport Security\n"
          + "extension UninstallerTrashTests {\n" + trash_model
          + "enum Watcher {\n" + declaration("Sources/Brim/Services/Uninstall/TrashAppWatcher.swift",
                                            "    private func offer(").replace("private func offer(", "static func offer(")
          + "}\nfinal class Delegate: WindowHost {\n"
          + declaration("Sources/Brim/App/AppDelegate.swift", "    func openUninstaller(for ")
          + "}\n}\n")
    homebrew = "Sources/Brim/Services/Homebrew/HomebrewManager.swift"
    write("AppUpdatesOperationLog.swift", "extension HomebrewOperationLogRetentionTests.Updates {\n"
          + declaration("Sources/Brim/UI/AppUpdates/AppUpdatesListView.swift",
                        "    private var operationLog:").replace("private var", "var", 1)
          + "}\n")
    write("HomebrewOwnership.swift", "import Foundation\n"
          + "extension HomebrewOwnershipTests.Manager {\n"
          + declaration(homebrew, "    func packageManagingApplication(")
          + declaration(homebrew, "    private func finishOwnershipLoad(")
          + "}\n")
    directory = "Sources/Brim/UI/Settings/SettingsDirectory.swift"
    write("ZoomSettingsDirectory.swift", "import Foundation\n"
          + declaration(directory, "struct SettingsSearchState:")
          + declaration(directory, "struct SettingsDirectoryItem:")
          + "enum SettingsDirectory {\n"
          + declaration(directory, "    static func sections(")
          + declaration(directory, "    static func searchItems(")
              .replace("state: SettingsSearchState = .current", "state: SettingsSearchState")
          + "}\nextension SettingsFeatureTests.IslandSettings {\n"
          + declaration("Sources/Brim/UI/Settings/NotchSettings.swift", "    private func revealDestination()")
              .replace("private func", "func", 1)
          + "}\n")
    cleaner = "Sources/Brim/Services/Cleaner/JunkCleaner.swift"
    write("CleanerEligibilityBodies.swift", "import Foundation\nextension CleanerEligibilityTests {\n"
          + declaration(cleaner, "    private static let leftoverRoots:", closing="]")
          + declaration(cleaner, "    private static func isDirectLeftoverRootChild(")
          + declaration(cleaner, "    private static func hasLivingOwner(")
          + declaration(cleaner, "    private static func hasLivingLeftoverOwner(")
          + "".join(declaration(cleaner, "    private static func " + name)
                    .replace("private static func", "static func", 1)
                    for name in ["scanLeftovers(", "appendLeftovers(", "scanCaches(", "scanLogs(",
                                 "scanOrphanedLaunchPlists(", "directorySize(", "fileSize(", "sorted(",
                                 "scanScreenshots(", "isScreenCapture(", "extendedAttribute("])
          + declaration(cleaner, "    private static func leftoverOwner(")
          + declaration(cleaner, "    private static func containerOwner(")
          + declaration(cleaner, "    private static func mayRemove(")
          + "static func owner(_ url: URL, metadata: Bool = false) -> String? {\n"
          + "leftoverOwner(entry: url.lastPathComponent, url: url, usesContainerMetadata: metadata)\n}\n"
          + "static func canRemove(_ item: Item, installed: Set<String> = []) -> Bool {\n"
          + "mayRemove(item, installed: installed)\n}\n}\n")
    write("CleanerScanFlow.swift", "import Foundation\nextension CleanerScanFlowTests {\n"
          + declaration(cleaner, "    enum Phase:")
          + "final class Scanner: ScannerState {\nstatic let shared = Scanner()\n"
          + "".join(declaration(cleaner, prefix) for prefix in ["    func reset()", "    func scan("])
          + "}\n}\n")


    write("CleanerLastRun.swift", "import Foundation\nextension CleanerLastRunContract {\n"
          + "final class Scheduler: SchedulerState {\n"
          + declaration("Sources/Brim/Services/Cleaner/CleanerScheduler.swift", "    private func finishRun(")
            .replace("private func", "func", 1)
          + "}\nfinal class Card: CardState {\n"
          + declaration("Sources/Brim/UI/Cleaner/CleanerView.swift", "    private var lastRunLine:")
            .replace("private var", "var", 1)
          + "}\n}\n")

    updates = "Sources/Brim/Services/AppUpdates/AppUpdatesService.swift"
    write("AppUpdateHandoff.swift", "import Foundation\nextension AppUpdateHandoffTests {\n"
          + "final class Service: State {\n"
          + "".join(declaration(updates, prefix).replace("private func", "func", 1)
                    for prefix in ["    var updateHandoffPending:", "    private func handOff(",
                                   "    func applicationBecameActive()", "    func consumeUpdateHandoffReturn()"])
          + "}\n}\n")
    loader = "Sources/Brim/Services/AppUpdates/AppUpdateFeedLoader.swift"
    # Only the network configuration, clock and declaration visibility change.
    # The loader, batch loop, catalog matching and fallback resolution stay verbatim.
    write("AppUpdates.swift", "import Foundation\nimport Darwin\nextension AppUpdatesContract {\n"
          + declaration(loader, "final class AppUpdateFeedLoader:")
          + "final class Service {\nlet workQueue = DispatchQueue(label: \"app-updates.contract\")\n"
          + "let clock = Clock()\n"
          + "static let onlineCatalogCacheLifetime: TimeInterval = 60 * 60\n"
          + "var onlineCatalogCache: (loadedAt: Foundation.Date, entries: [AppUpdatesSupport.CatalogEntry])?\n"
          + "lazy var catalogSession = URLSession(configuration: URLSessionConfiguration.ephemeral)\n"
          + declaration(updates, "    private struct SourceResult {").replace("private struct", "struct", 1)
          + declaration(updates, "    private func publisherFindings(").replace("private func", "func", 1).replace("Date()", "self.clock.now()")
          + declaration(updates, "    private func onlineCatalogFindings(").replace("private func", "func", 1).replace("Date()", "self.clock.now()")
          + declaration(updates, "    private func onlineResult(").replace("private func", "func", 1)
          + "}\n}\n")
    # Rule mutations and completion stay verbatim; only declaration visibility changes.
    write("AppUpdateRules.swift", "import CoreServices\nimport Foundation\nextension AppUpdateRulesContract {\n"
          + "final class Service: State {\n"
          + "".join(declaration(updates, prefix).replace("private func", "func", 1)
                    .replace("private static func scannedApp(", "static func scannedApp(", 1)
                    for prefix in ["    func skipVersion(", "    func excludeApp(", "    func addExclusion(",
                                   "    private func setRule(", "    private func storeRule(",
                                   "    func removeRule(",
                                   "    private func saveRules(", "    private func reloadRules(",
                                   "    private func applyRules(", "    private func finishCheck(",
                                   "    private static func announcedIDs(", "    private static func saveAnnouncedIDs(",
                                   "    private static func scannedApp(", "    private static func isOwnBundle("])
          + "}\n}\n")
    usage = "Sources/Brim/Services/SystemMonitor/ProcessUsageService.swift"
    write("ProcessForceQuit.swift", "import Darwin\nimport Foundation\n"
          + "extension ProcessForceQuitTests {\n"
          + declaration(usage, "struct ProcessUsage:")
          + "final class Service {\nprivate let maximumCachedRows = 60\n"
          + declaration(usage, "    func canForceQuit(")
          + declaration(usage, "    private static func executableName(")
          + declaration(usage, "    private func withForceQuitIdentity(").replace("private func", "func", 1)
          + declaration(usage, "    private static func processExisted(")
          + declaration(usage, "    private func groupedByApp(").replace("private func", "func", 1)
          + declaration(usage, "    private func groupedNetworkByApp(").replace("private func", "func", 1)
          + "}\n}\n")
    write("NotchActivationButton.swift", "import AppKit\n"
          + declaration("Sources/Brim/Services/Notch/NotchWindowHost.swift", "final class NotchActivationButton:"))
    write("NotchPanel.swift", "import AppKit\n"
          + declaration("Sources/Brim/Services/Notch/NotchWindowHost.swift", "final class NotchPanel:"))
    write("OverlayPanelDeclaration.swift", "import AppKit\n"
          + declaration("Sources/Brim/UI/OverlayPanel.swift", "class OverlayPanel:"))
    notch = "Sources/Brim/Services/Notch/NotchService.swift"
    write("NotchFullscreen.swift", "import CoreGraphics\nimport Foundation\nextension NotchFullscreenTests {\n"
          + declaration("Sources/Brim/Services/SpaceWindowBridge.swift", "    struct Topology {")
          + "final class Service: State {\n"
          + declaration(notch, "    var acceptsUserInteraction: Bool {")
          + declaration(notch, "    var acceptsSystemFeedback: Bool {")
          + declaration(notch, "    private func updateFullscreenVisibility(").replace("private func", "func", 1)
          + declaration(notch, "    private func fullscreenEnvironmentDidChange()").replace("private func", "func", 1)
          + "}\n}\n")
    write("NotchNotice.swift", "import AppKit\n" + declaration(notch, "struct NotchNotice:"))
    agent_view = "Sources/Brim/UI/Notch/NotchAgentsView.swift"
    write("NotchAgentLimitReading.swift", "import SwiftUI\nextension NotchAgentLimitReadingTests {\n"
          + declaration(agent_view, "private struct NotchAgentLimitReading:").replace("private struct", "struct", 1)
          + declaration(agent_view, "private struct NotchAgentInlineLabel:")
          + "}\n")
    write("NotchCompact.swift", "import AppKit\nimport Carbon.HIToolbox\nimport SwiftUI\nextension NotchCompactTests {\n"
          + declaration("Sources/Brim/UI/Notch/NotchComponents.swift", "struct NotchRail<")
          + "}\n"
          + "extension NotchCompactTests.Page {\n"
          + declaration("Sources/Brim/UI/Notch/NotchView.swift", "    private var pageSize:")
              .replace("private var", "var", 1).replace("NotchSupport.controls()", "controls")
          + "}\n")
    canvas = "Sources/Brim/Services/Notch/NotchWindowHost.swift"
    write("NotchMissionControlPolling.swift", "import Foundation\n"
          + "extension NotchMissionControlPollingTests {\nfinal class Host: State {\n"
          + "".join(declaration(canvas, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private func syncMissionControlMonitoring()", "    private var missionControlCheckInterval:",
              "    private func updateMissionControlTimer()", "    private func refreshMissionControlState("])
          + "}\n}\n")
    write("NotchHover.swift", "import AppKit\nextension NotchHoverTests {\nfinal class Service: State {\n"
          + declaration(notch, "    func show(_ incoming:").replace("NotchSupport.routes(incoming.event)", "true")
            .replace("    func", "    @discardableResult\n    func", 1)
          + "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private var hiddenUntilHover:", "    private var hiddenAtRestInFullscreen:",
              "    private var hoverOpeningEnabled:", "    private var watchesHiddenHover:", "    func hover(",
              "    private func syncHoverExitMonitoring(", "    private func removeHoverExitMonitors(",
              "    var showsCompactActivityPicker:",
              "    private func missionControlDidRestore()",
              "    private func syncNoticeWithPreferences(", "    private func scheduleNoticeDismissal(",
              "    private func dismissNotice(", "    private func endDeparture(", "    private var noticeCanPresent:",
              "    private func syncHiddenHoverMonitoring(", "    private func removeHiddenHoverMonitors("])
          .replace("NotchSupport.routes(notice.event)", "routes(notice.event)")
          .replace("NotchSupport.hiddenShowsActivity()", "hiddenShowsActivity")
          .replace("NotchSupport.closeDelay()", "NotchSupport.sanitizedCloseDelay(UserDefaults.standard.closeDelay)")
          + "}\n}\n")
    write("NotchScreenEdgeClicks.swift", "import AppKit\nextension NotchScreenEdgeClickTests.State {\n"
          + declaration(notch, "    func capsuleNoticeSurface(")
          + "}\nextension NotchScreenEdgeClickTests {\nfinal class Service: State {\n"
          + "func open(_ module: NotchModule? = nil) { openings += 1; opened = module; expanded = true; syncScreenEdgeClicks() }\n"
          + "func refreshPresentation(animated: Bool) { syncScreenEdgeClicks() }\n"
          + "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
              "    var stripNotice:", "    private var noticeCanPresent:", "    var acceptsUserInteraction:",
              "    var acceptsSystemFeedback:", "    func activateNotice(",
              "    private func applyMenuSpace(",
              "    private var screenEdgeClickArea:", "    private func syncScreenEdgeClicks(",
              "    private func handleScreenEdgeEvent(", "    private func handleScreenEdgeClick(",
              "    private func removeScreenEdgeClickMonitors("])
          .replace("NotchSupport.routes(selectedNotice.event)", "self.routesNotices")
          + "}\n}\n")
    write("NotchClickElsewhere.swift", "import AppKit\nextension NotchClickElsewhereTests {\nfinal class Service: State {\n"
          + declaration(notch, "    private func clickedElsewhere(").replace("    private ", "    ", 1)
          + "}\n}\n")
    write("NotchScreenRefresh.swift", "import Foundation\n\nextension NotchScreenRefreshContract {\nfinal class Service: State {\n"
          + declaration(notch, "    private func schedulePreferenceSync()").replace("private func", "func", 1)
          + declaration(notch, "    private func screenParametersDidChange()").replace("private func", "func", 1)
          + declaration(notch, "    private func invalidateMenuSpace(").replace("private func", "func", 1)
          + declaration(notch, "    private func applicationDidActivate()").replace("private func", "func", 1)
          + declaration(notch, "    private func stopMenuSpaceMonitoring()")
          + declaration(notch, "    private func syncMenuSpaceMonitoring()").replace("private func", "func", 1)
              .replace("AXIsProcessTrusted()", "accessibilityGranted")
              .replace("NotchSupport.coversMenus()", "coversMenus")
              .replace("NotchSupport.hiddenShowsActivity()", "hiddenShowsActivity")
          + declaration(notch, "    private func syncPointerFollowing()").replace("private func", "func", 1)
          + declaration(notch, "    private func removePointerMonitors()").replace("private func", "func", 1)
          + declaration(notch, "    private var canFollowPointer:").replace("private var", "var", 1)
          + declaration(notch, "    private func schedulePointerFollow()").replace("private func", "func", 1)
          + declaration(notch, "    private func followPointer()").replace("private func", "func", 1)
          + declaration(notch, "    private func move(to screen:").replace("private func", "func", 1)
          + declaration(notch, "    private func cancelRelocation()").replace("private func", "func", 1)
          + "}\n}\n")
    write("NotchMirrors.swift", "import AppKit\nextension NotchMirrorContract {\nfinal class Service: State {\n"
          + "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private func syncMirrors()", "    private func mirrorSurface(", "    private func mirrorSideRoom(",
              "    private func closeMirrors()", "    private func updateFullscreenDisplays()",
              "    private func bringIsland("])
          .replace("NotchSupport.hidesUntilHover()", "hidesUntilHover")
          .replace("NotchSupport.hiddenShowsActivity()", "hiddenShowsActivity")
          .replace("NotchSupport.coversMenus()", "coversMenus")
          .replace("NotchSupport.showsInCaptures()", "showsInCaptures")
          .replace("UserDefaults.standard.bool(forKey: DefaultsKey.notchOutlineEnabled)", "outlineEnabled")
          .replace("UserDefaults.standard.bool(forKey: DefaultsKey.notchHideInFullscreen)", "hidesInFullscreen")
          .replace("FeatureStrings.notch(L10n.shared.language).open", "openTitle")
          + "}\n}\n")
    visibility = "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
        "    private var hiddenUntilHover:", "    var fullscreenCompact:", "    var idleContent:", "    var compactActivity:",
        "    var compactActivities:", "    var showsCompactActivityPicker:", "    var compactActivityGeometry:",
        "    private func compactGeometry(", "    var surfaceSize:", "    var surfaceShift:",
        "    private func syncVisibleConsumers(", "    private func releaseMonitor("])
    for call in ["NotchSupport.hiddenShowsActivity()", "NotchSupport.idleContent()", "UserDefaults.standard",
                 "AppFeature.monitorDisk.isAvailable", "AppFeature.fanControl.isAvailable",
                 "AppFeature.connectedDevices.isAvailable"]:
        if call not in visibility:
            raise ValueError(f"Expected {call!r} in the island's visibility members")
    for call in ["NotchSupport.hiddenShowsActivity", "NotchSupport.idleContent"]:
        visibility = visibility.replace(call + "()", call + "(in: ReviewDefaults.current)")
    visibility = visibility.replace("UserDefaults.standard", "ReviewDefaults.current!")
    for feature in ["monitorDisk", "fanControl", "connectedDevices"]:
        visibility = visibility.replace(f"AppFeature.{feature}.isAvailable",
                                        f"AppFeature.{feature}.isAvailable(in: ReviewDefaults.current)")
    write("NotchVisibility.swift", "import Foundation\nextension NotchVisibilityTests {\nfinal class Service: State {\n"
          + visibility + "}\n}\n")
    write("NotchSectionScrollRoute.swift", "import AppKit\nextension NotchSectionPagingTests {\nfinal class Service: State {\n"
          + "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private func handleSectionScroll("])
          + "}\n}\n")
    write("NotchKeyMonitor.swift", "import Foundation\nextension NotchKeyMonitorTests {\nfinal class Service: State {\n"
          + declaration(notch, "    private func installEventMonitors()").replace("private func", "func", 1)
          + declaration(notch, "    private func clickedElsewhere()").replace("private func", "func", 1)
          + "}\n}\n")
    write("NotchPresentationRefresh.swift", "import AppKit\nimport Foundation\nimport Combine\nimport SwiftUI\n"
          + "extension NotchPresentationRefreshContract {\nfinal class Service: State {\n"
          + "func resignPanelKey() { panel?.resignKey() }\n"
          + "func hover(_ entered: Bool) {\n"
          + "inside = windowHost?.containsHover(NSEvent.mouseLocation) == true\n"
          + "hoverState.update(pointerInside: inside)\n}\n"
          + "".join(declaration(notch, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private func missionControlDidRestore()",
              "    var stripNotice:", "    private var noticeCanPresent:",
              "    private func dismissNotice(", "    private func endDeparture(", "    private func mutatePresentation("])
          + declaration(notch, "    private var hiddenUntilHover:").replace("private var", "var", 1)
              .replace("NotchSupport.hiddenShowsActivity()", "hiddenShowsActivity")
          + declaration(notch, "    private var hiddenAtRestInFullscreen:").replace("private var", "var", 1)
          + declaration(notch, "    var acceptsUserInteraction:")
          + declaration(notch, "    var acceptsSystemFeedback:")
          + declaration(notch, "    var showsSystemFeedback:")
              .replace("NotchSupport.hiddenShowsActivity()", "hiddenShowsActivity")
          + declaration(notch, "    var usesGlassSurface:")
          + declaration(notch, "    var expandedGeometry:").replace("var expandedGeometry", "override var expandedGeometry", 1)
          + declaration(notch, "    private func switchCompactSelection(").replace("private func", "func", 1)
          + declaration(notch, "    func refreshPresentation(")
              .replace("NotchSupport.coversMenus()", "UserDefaults.standard.coversMenus")
          + declaration(notch, "    private func applyMenuSpace(").replace("private func", "func", 1)
          + "}\n}\nextension NotchPresentationRefreshContract.Host {\n"
          + declaration(canvas, "    func setMouseEventsIgnored(")
          + declaration(canvas, "    private func restoreFromMissionControl(").replace("private func", "func", 1)
          + "}\n")
    metric_view = "Sources/Brim/UI/MenuPanel/MetricDetailView.swift"
    renderer = "Sources/Brim/App/MenuBarRenderer.swift"
    # Keep the battery branch and its real drawing path intact; unrelated
    # monitor readings are outside this isolated warning-color contract.
    battery_segments = declaration(renderer, "    private static func blockSegments(")
    prefix, switch, cases = battery_segments.partition("            switch metric {\n")
    _, battery_case, rest = cases.partition("            case .battery, .batteryTemperature:\n")
    battery_body, next_case, _ = rest.partition("            case .batteryTime:\n")
    if not switch or not battery_case or not next_case:
        raise ValueError("Expected the battery branch in blockSegments")
    for line in ["        let usesBars = appearance == .bars\n",
                 "        var renderedCPU = false\n", "        var renderedGPU = false\n"]:
        if line not in prefix:
            raise ValueError("Expected the unrelated activity state in blockSegments")
        prefix = prefix.replace(line, "")
    battery_segments = (prefix + switch + battery_case + battery_body
                        + "            }\n        }\n        return blockJoined(groups, style: style)\n    }\n#sourceLocation()\n")
    battery_warning = declaration(renderer, "    private static func batteryWarning(")
    connection = "externalConnected: power?.externalConnected ?? false)"
    if connection not in battery_warning:
        raise ValueError("Expected the battery warning's power connection")
    battery_warning = battery_warning.replace(connection, connection[:-1] + ", in: ReviewDefaults.current)")
    spacing = "Sources/Brim/App/MenuBarSpacingSupport.swift"
    write("MenuBarBatteryWarning.swift", "import AppKit\nextension MenuBarBatteryWarningTests {\n"
          + declaration("Sources/Brim/Services/SystemMonitor/SystemMonitor.swift", "enum MemoryPressure {")
          + declaration("Sources/Brim/Services/Metrics/PowerSampler.swift", "struct PowerReading {")
          + declaration(renderer, "enum MenuBarSegment {")
          + declaration(renderer, "enum MenuBarBlockStyle {")
          + "".join(declaration(spacing, prefix).replace("UserDefaults.standard", "ReviewDefaults.current!")
                    for prefix in ["enum MenuBarMetricSpacing:", "enum MenuBarMetricAppearance:"])
          + "}\nextension MenuBarBatteryWarningTests.Renderer {\n"
          + (battery_segments + battery_warning).replace("private static", "static")
              .replace("UserDefaults.standard", "ReviewDefaults.current!")
          + "".join(declaration(renderer, prefix).replace("private static", "static")
                    .replace("UserDefaults.standard", "ReviewDefaults.current!") for prefix in [
                        "    static func attributed(", "    private static func metricBlockAttachment(",
                        "    private static func metricBlockImage(", "    private static func batteryBlockAttachment(",
                        "    private static func batteryBlockImage(", "    private static func blockImageCost(",
                        "    private static func dynamicTextAttributes(", "    static func nsColor(for warning:",
                        "    static func nsColor(for pressure:", "    private static func temperatureCompact(",
                        "    private static func temperatureLabel(", "    private static func combinedComponentValue("])
          + "}\n")
    metric_cases = "\n".join(line for line in declaration(metric_view, "enum MetricDetailKind:").splitlines()
                             if line.startswith("    case "))
    menu_metric_cases = "\n".join(line for line in declaration(renderer, "enum MenuBarMetric:").splitlines()
                                  if line.startswith("    case "))
    # toggle() fits on one line, which declaration() cannot bound.
    toggle = [line for line in (ROOT / notch).read_text().splitlines(keepends=True)
              if line.startswith("    func toggle() {")]
    if len(toggle) != 1 or not toggle[0].rstrip().endswith("}"):
        raise ValueError("Expected a one-line toggle() in NotchService")
    write("NotchDestinations.swift", "import Foundation\n\nextension NotchDestinationContract {\n"
          + "enum MetricDetailKind: String {\n" + metric_cases + "\n}\n"
          + "enum MenuBarMetric: String, CaseIterable {\n" + menu_metric_cases + "\n"
          + declaration(renderer, "    var feature: AppFeature")
          + declaration(metric_view, "    var detailKind:") + "}\n"
          + "final class Service: State {\n"
          + "func syncWithPreferences() { presentationSyncs += 1; refreshModules(); syncVisibleConsumers() }\n"
          + availability_declaration(notch, "    private func metricIsAvailable(")
          + declaration(notch, "    private func refreshModules(")
              .replace("NotchSupport.modules()", "NotchSupport.modules(in: ReviewDefaults.current)")
          + declaration(notch, "    func open(_ module:")
              .replace("NotchSupport.isEnabled()", "NotchSupport.isEnabled(in: ReviewDefaults.current)")
          + "func removeHoverExitMonitors() {}\n"
          + declaration(notch, "    func showClipboard(")
              .replace("NotchSupport.routesClipboardWindow()", "NotchSupport.routesClipboardWindow(in: ReviewDefaults.current)")
          + declaration(notch, "    func resignPanelKey()")
          + declaration(notch, "    func toggleSections()")
          + declaration(notch, "    func goBack()")
          + declaration(notch, "    private func stepBack()").replace("private func", "func", 1)
          + declaration(notch, "    func setPageLayer(")
          + declaration(notch, "    func openAppPanel(")
          + declaration(notch, "    func showMetric(")
          + declaration(notch, "    var reopeningDestination:")
              .replace("UserDefaults.standard", "ReviewDefaults.current!")
          + declaration(notch, "    func openActivity(")
              .replace("UserDefaults.standard", "ReviewDefaults.current!")
          + declaration(notch, "    var reopeningModule:")
          + declaration(notch, "    private func updateSession(").replace("private func", "func", 1)
              .replace("NotchLockScreenSupport.playsSounds()", "NotchLockScreenSupport.playsSounds(in: ReviewDefaults.current)")
          # The press handler the initializer installs, run on demand.
          + declaration(notch, "    private init() {").replace("    private init()", "    func installHotkey()", 1)
          + declaration(notch, "    func toggleFromShortcut()") + toggle[0]
          + declaration(notch, "    private func syncShortcut()").replace("private func", "func", 1)
              .replace("NotchSupport.holdsShortcut()", "NotchSupport.holdsShortcut(in: ReviewDefaults.current)")
          + "}\n}\n")
    settings_card = "Sources/Brim/UI/Settings/SettingsCard.swift"
    text_inset = next(line for line in (ROOT / settings_card).read_text().splitlines()
                      if line.startswith("let settingsRowTextInset:"))
    # The Features page's wording and route live outside the tests, so the
    # row's copy speaks the feature's name and goes nowhere.
    feature_row = declaration(settings_card, "struct SettingsFeatureSwitchRow")
    for call, stand_in in [("feature.enableReason(l10n)", "feature.rawValue"), ("feature.showInFeatures()", "_ = feature")]:
        if call not in feature_row:
            raise ValueError(f"Expected {call!r} in SettingsFeatureSwitchRow")
        feature_row = feature_row.replace(call, stand_in)
    write("NotchSettingsChoice.swift", "import SwiftUI\n" + text_inset + "\n\nextension NotchSettingsChoiceTests {\n"
          + "struct MenuBarGlyph: View { var body: some View { EmptyView() } }\n"
          + "final class FeatureRuntime: ObservableObject {\nstatic let shared = FeatureRuntime()\nvar installed = true\n"
          + "func isAvailable(_ feature: AppFeature) -> Bool { installed }\n}\n"
          + declaration(settings_card, "struct SettingsCard<")
          + declaration(settings_card, "struct SettingsRow<")
          + feature_row
          + declaration(settings_card, "struct SettingsChoiceRow<")
          + declaration(settings_card, "struct SettingsMenuRow<")
          + "struct Destination: View {\nlet language: AppLanguage\nlet title: String\n"
          + "var text: NotchStrings { FeatureStrings.notch(language) }\n"
          + "var editor: NotchEditorStrings { FeatureStrings.notchEditor(language) }\n"
          + 'var body: some View { destination(title, symbol: "tray.full", value: .constant(true)) }\n'
          + declaration("Sources/Brim/UI/Settings/NotchSettings.swift", "    private func destination(")
          # The clipboard's entry size, its value as Settings stored it.
          + "}\nstruct ClipboardEntrySize: View {\nlet language: AppLanguage\n"
          + "@State var clipboardCardSize = NotchClipboardCardSize.comfortable.rawValue\n"
          + "var size: NotchClipboardSizeStrings { FeatureStrings.notchClipboardSize(language) }\n"
          + "var body: some View {\n"
          + declaration("Sources/Brim/UI/Settings/NotchSettings.swift",
                        '                    SettingsChoiceRow(symbol: "rectangle.compress.vertical"')
          + "}\n"
          + "}\nstruct Limits: View {\nlet language: AppLanguage\n"
          + "@State var limitDisplay = NotchAgentLimitDisplay.remaining.rawValue\n"
          + "var text: NotchAgentStrings { FeatureStrings.notchAgents(language) }\n"
          + "var body: some View {\n"
          + declaration("Sources/Brim/UI/Settings/NotchAgentsSettings.swift",
                        "            SettingsChoiceRow(symbol: NotchAgentCard.limits.symbol")
          + "}\n}\n"
          # The AI agents card's menu rows, each with the indent it has there.
          + "".join(f"struct {name}: View {{\nlet language: AppLanguage\n"
                    + "@State var readout = NotchAgentReadout.elapsed.rawValue\n"
                    + "@State var finishMinimum = NotchAgentSupport.defaultFinishMinimum\n"
                    + "@State var limitThreshold = NotchAgentSupport.defaultLimitThreshold\n"
                    + "@State var dailyBudget = 0.0\n"
                    + "@State var limitFocus = NotchAgentLimitFocus.mostUsed.rawValue\n"
                    + "var text: NotchAgentStrings { FeatureStrings.notchAgents(language) }\n"
                    + "var locale: Locale { language.formattingLocale() }\n"
                    + "var body: some View {\nGroup {\n"
                    + declaration("Sources/Brim/UI/Settings/NotchAgentsSettings.swift", prefix)
                    + "}\n" + (".padding(.leading, settingsRowTextInset)\n" if indented else "") + "}\n}\n"
                    for name, prefix, indented in [
                        ("Readout", '                SettingsMenuRow(symbol: "camera.metering.center.weighted"', True),
                        ("FinishAfter", '                SettingsMenuRow(symbol: "timer"', True),
                        ("LimitAt", '                SettingsMenuRow(symbol: "gauge.with.dots.needle.67percent"', True),
                        ("Budget", '            SettingsMenuRow(symbol: "dollarsign.circle"', False),
                        ("LimitFocus", '            SettingsMenuRow(symbol: "rectangle.topthird.inset.filled"', False)])
          + "}\n")
    # The clipboard page's size, keys, pointer and highlight handling, on a page that only keeps their state.
    clipboard_view = "Sources/Brim/UI/Notch/NotchClipboardView.swift"
    write("NotchClipboardPage.swift", "import SwiftUI\nextension NotchClipboardPageTests {\n"
          + "@MainActor final class Page {\nstruct ClipboardHistoryEntry {\nlet id: UUID\nvar text = \"\"\nvar isPinned = false\n"
          + "var cardPreview: String { HistoryEntry(text: text).cardPreview }\n}\n"
          + "var preview = false\nvar reduceMotion = true\nvar cardSize = NotchClipboardCardSize.compact.rawValue\n"
          + "var hoveredID: UUID?\nvar expandedID: UUID?\n"
          + "var dwell: (id: UUID, task: Task<Void, Never>)?\nvar closing: (id: UUID, task: Task<Void, Never>)?\n"
          + "var entries: [ClipboardHistoryEntry] = []\nvar highlightedID: UUID?\nvar keysMoved = false\n"
          + "var query = \"\"\nvar searchOpen = false\nvar searching = false\nvar activated: [UUID] = []\n"
          + "func activate(_ entry: ClipboardHistoryEntry) { activated.append(entry.id) }\n"
          # The list the page scrolls, which only records where it was asked to go.
          + "var size = CGSize(width: 504, height: 180)\n"
          + "final class ScrollViewProxy {\nvar scrolls: [(id: UUID, anchor: UnitPoint?)] = []\n"
          + "func scrollTo(_ id: UUID, anchor: UnitPoint? = nil) { scrolls.append((id, anchor)) }\n}\n"
          + "".join(declaration(clipboard_view, prefix).replace("    private ", "    ", 1) for prefix in [
              "    private func appeared()", "    private func queryChanged(",
              "    private var comfortable: Bool {", "    private var rowHeight: CGFloat {", "    private func hover(",
              "    private func openSearch()", "    private func closeSearch()", "    private func handleKey(",
              "    private func openText(", "    private func searchHighlight(", "    private func follow(",
              "    private func thumbnail<"])
          + "}\n}\n")
    # The panel's tabs and the rows they hold, as shipped.
    menu_panel = "Sources/Brim/UI/MenuPanel/MenuPanelView.swift"
    panel_layout = (ROOT / "Sources/Brim/UI/MenuPanel/PanelLayout.swift").read_text()
    order_item = next(line for line in panel_layout.splitlines() if line.startswith("protocol PanelOrderItem:"))
    write("MenuPanelSectionGates.swift", "import Foundation\n\n" + order_item + "\n"
          + "extension MenuPanelSectionGateContract {\n"
          + declaration("Sources/Brim/UI/MenuPanel/PanelLayout.swift", "enum PanelSectionID:")
          + "".join(declaration(menu_panel, prefix).replace("private enum", "enum", 1)
                    for prefix in ["private enum UtilityPanelItem:"])
          + "}\n")

    # The Developer probe's modes and argument check, outside its development-only file.
    probe = "Sources/Brim/Support/NotchPresentationProbe.swift"
    write("NotchPresentationProbeArguments.swift", "import Foundation\n\nextension NotchPresentationProbeArgumentTests {\n"
          + "enum Probe {\n"
          + "".join(declaration(probe, prefix, scope="enum NotchPresentationProbe {")
                    for prefix in ["    enum Mode:", "    static func isRequested("])
          + "}\n}\n")



    keep_awake = "Sources/Brim/Services/KeepAwakeManager.swift"
    keep_awake_methods = [
        "    func refreshPasswordlessStatus(",
        "    func toggle(",
        "    func syncWithFeatures(",
        "    func activate(minutes:",
        "    func activate(until date:",
        "    func startLastPick(",
        "    func activateOnLaunchIfNeeded(",
        "    private func saveManualSession(",
        "    private func restoreSessionIfNeeded(",
        "    func extend(minutes:",
        "    func resumeAfterSystemTeardown(",
        "    private func activate(end:",
        "    func deactivate(reason:",
        "    private func scheduleEnd(",
        "    private func continueAutomaticallyAfterTimerIfNeeded(",
        "    private func automationConditionsHold(",
        "    private func automaticSessionAllowedByBatteryProtection(",
        "    private func startBatteryWatch(",
        "    private func stopBatteryWatch(",
        "    private func checkBattery(",
        "    func batteryProtectionPercent(",
        "    private func applyClamshellPreference(",
        "    private func prepareClamshellPreference(",
        "    private func finishClamshellSetup(",
        "    private func markClamshellSetupFailed(",
        "    private func enableClamshell(",
        "    private func disableClamshell(",
        "    private func sleepIfLidAlreadyClosed(",
        "    func recoverIfNeeded(",
        "    private func finishRecovery(",
        "    private var clamshellNeedsRestore:",
        "    private func finishClamshellRestore(",
        "    private func recoverDimmedDisplayIfNeeded(",
        "    private func syncLidDimmingObserver(",
        "    private func lidStateMayHaveChangedForDimming(",
        "    private func applyDimmingAction(",
        "    private func attemptDisplayRestore(",
    ]
    write("KeepAwakeLidSleep.swift", "import Foundation\nimport os\n\nextension KeepAwakeLidSleepContract {\n"
          # The extracted dimming bodies unwrap `Unmanaged<KeepAwakeManager>`
          # for the IOKit callback's context; this makes that name resolve to
          # the fixture's own class instead of leaving it undefined.
          + "typealias KeepAwakeManager = Service\n"
          + "final class Service {\n"
          + "static let log = Logger(subsystem: \"brim.tests\", category: \"keep-awake\")\n"
          + "var isActive = false\nvar sessionPausedForScreenLock = false\n"
          + "var isTerminating = false\nvar clamshellEnablePending = false\nvar clamshellRestorePending = false\n"
          + "var clamshellOperationGeneration = 0\nvar clamshellSetupID: UUID?\n"
          + "var lidSleepGeneration = 0\nvar lidSleepAttemptsRemaining = 0\n"
          + "var clamshellSetupInProgress = false\nvar clamshellSetupFailed = false\n"
          + "var clamshellSetupRetried = false\nvar passwordlessClamshell = true\n"
          + "var recoveryCompleted = false\nvar launchActivationPending = true\nvar screenLocked = false\nvar assertionsHeld = false\n"
          + "var automationSuppressedUntilConditionsClear = false\n"
          + "var endTimer: Timer?\nvar batteryTimer: Timer?\nvar endDate: Date?\nvar sessionTrigger: SessionTrigger?\nvar sessionMinutes: Int?\n"
          + "var activeAutomationConditions = Set<KeepAwakeAutomationCondition>()\n"
          + "var matchingConditions = Set<KeepAwakeAutomationCondition>()\n"
          + "func currentMatchingAutomationConditions() -> Set<KeepAwakeAutomationCondition> { matchingConditions }\n"
          + "func currentEnabledAutomationConditions() -> Set<KeepAwakeAutomationCondition> { [.power] }\n"
          + "func automationRequiresAllConditions() -> Bool { false }\n"
          + "var onSessionEnded: ((EndReason) -> Void)?\n"
          + "var lidDimmingNotificationPort: IONotificationPortRef?\nvar lidDimmingNotification: io_object_t = 0\n"
          + "var lidClosedForDimming: Bool?\nvar savedDisplayBrightness: Double?\n"
          + declaration(keep_awake, "    @Published private(set) var clamshellActive = false {")
                .replace("@Published private(set) ", "", 1)
          + declaration(keep_awake, "    @Published var clamshellPreferred:").replace("@Published ", "", 1)
          + declaration(keep_awake, "    @Published var dimScreenOnLidClose: Bool {").replace("@Published ", "", 1)
          + "init() { clamshellPreferred = true; dimScreenOnLidClose = false }\n"
          + "func syncScreenLockMonitoring() {}\nfunc applyAssertions() { assertionsHeld = true }\n"
          + "func releaseAssertions() { assertionsHeld = false }\nfunc syncMouseJiggleTimer() {}\n"
          + "func stopMouseJiggleTimer() {}\nfunc stopAutomationMonitoring() {}\nfunc syncWithPreferences() {}\n"
          + "static func lidSleepIsAllowed() -> Bool { KeepAwakeAutomationSupport.lidSleepIsAllowed("
          + "systemAllowsSleep: policy, externalDisplayConnected: externalDisplay, "
          + "connectedToPower: connectedToPower, assertions: assertions) }\n"
          + "".join(declaration(keep_awake, prefix).replace("private ", "", 1) for prefix in keep_awake_methods)
          + "}\n}\n"
          + "extension KeepAwakeLidSleepContract.Sudoers {\n"
          + declaration("Sources/Brim/Services/ShellSupport.swift", "    static func isConfigured()")
          + declaration("Sources/Brim/Services/ShellSupport.swift", "    static func restoreSleepWithAuthorization(")
          + "}\n")
    write("KeepAwakeTimerHandoff.swift", "import Foundation\n\nextension KeepAwakeTimerHandoffContract {\n"
          + "final class Service {\nvar sessionTrigger = SessionTrigger.manual\n"
          + "var automationSuppressedUntilConditionsClear = false\n"
          + "var activeAutomationConditions: Set<KeepAwakeAutomationCondition> = []\n"
          + "var enabled: Set<KeepAwakeAutomationCondition> = []\n"
          + "var matching: Set<KeepAwakeAutomationCondition> = []\n"
          + "var requireAll = false\nvar batteryAllows = true\n"
          + "var activations: [(end: Date?, trigger: SessionTrigger)] = []\n"
          + "func automaticSessionAllowedByBatteryProtection() -> Bool { batteryAllows }\n"
          + "func currentMatchingAutomationConditions() -> Set<KeepAwakeAutomationCondition> { matching }\n"
          + "func currentEnabledAutomationConditions() -> Set<KeepAwakeAutomationCondition> { enabled }\n"
          + "func automationRequiresAllConditions() -> Bool { requireAll }\n"
          + "func activate(end: Date?, trigger: SessionTrigger) { activations.append((end, trigger)) }\n"
          + declaration(keep_awake, "    private func continueAutomaticallyAfterTimerIfNeeded()")
            .replace("private func", "func", 1)
          + "}\n}\n")


    self_uninstall = "Sources/Brim/Services/SelfUninstall.swift"
    write("SelfUninstallRemoval.swift", "import Foundation\n\nextension SelfUninstallContract {\nenum Host {\n"
          + "static let bundleID = \"test\"\n"
          + "static func suspendInputInterceptors() { events.append(\"suspend\") }\n"
          + "static func restoreSleepBeforeRemoval() -> Bool { events.append(\"sleep\"); return sleepRestoreAllowed }\n"
          + "static func detachFanControl() -> Bool { events.append(\"fan\"); return detachAllowed }\n"
          + "static func detachLoginItem() { events.append(\"login\") }\n"
          + "static func removePreferences() { events.append(\"preferences\") }\n"
          # The real step deletes ~/.config/brim/claude; its own tests run it
          # on scratch folders (BrimClaudeAccountsAppTests.stateRemoval).
          + "static func removeClaudeAccounts() { events.append(\"claude\") }\n"
          + "static func trashOwnBundleAndQuit() { events.append(\"trash\") }\n"
          + declaration(self_uninstall, "    private static func detachFromSystem()")
            .replace("private static", "static", 1)
          + declaration(self_uninstall, "    static func clearPermissions(")
          + declaration(self_uninstall, "    static func uninstallCompletely(")
          + declaration(self_uninstall, "    private static func removeSudoersRuleIfPresent(")
          + declaration(self_uninstall, "    private static func resetTCC(")
            .replace("private static", "@discardableResult static", 1)
          + "}\n}\n")

    factories = []
    pattern = r"static\s+func\s+(\w+)\s*\(\s*_\s+\w+:\s*AppLanguage\s*\)\s*->"
    for path in sorted((ROOT / "Sources/Brim/Core").glob("*Strings.swift")):
        source = path.read_text()
        if "extension FeatureStrings" in source or "enum FeatureStrings" in source:
            scopes = re.findall(r"(?:extension|enum) FeatureStrings \{(.*?)^\}", source, re.S | re.M)
            names = [name for scope in scopes for name in re.findall(pattern, scope)]
            if not names:
                raise ValueError(f"No language factory found in {path}")
            factories.extend(names)
    if not factories or len(factories) != len(set(factories)):
        raise ValueError("Missing or duplicate localization factories")
    write("LocalizationCatalog.swift", "extension LocalizationTests {\n"
          + "static let factories: [(String, (AppLanguage) -> Any)] = [\n"
          + "".join(f'("{name}", {{ FeatureStrings.{name}($0) }}),\n' for name in factories)
          + "]\n}\n")


    write("AgentUsageEventDelivery.swift", "import Foundation\n"
          + "extension AgentUsageEventDeliveryTests {\nfinal class Host: Fixture {\n"
          + declaration("Sources/Brim/Services/AgentUsage/AgentUsageService.swift",
                        "    private func report(").replace("private func", "func", 1)
          + "}\n}\n")


    write("AgentUsageArchiveSave.swift", "import Foundation\n"
          + "extension AgentUsageArchiveSaveTests {\nfinal class Host: Fixture {\n"
          + declaration("Sources/Brim/Services/AgentUsage/AgentUsageService.swift",
                        "    private func saveProgress(").replace("private func", "func", 1)
          + "}\n}\n")

    write("AgentUsageArchiveSettle.swift", "import Foundation\n"
          + "extension AgentUsageArchiveSettleTests {\nfinal class Host: Fixture {\n"
          + declaration("Sources/Brim/Services/AgentUsage/AgentUsageService.swift",
                        "    private func settleArchive(").replace("private func", "func", 1)
          + "}\n}\n")

    write("AgentUsageRead.swift", "import Foundation\n"
          + "extension AgentUsageReadTests {\nfinal class Host: Fixture {\n"
          + "".join(declaration("Sources/Brim/Services/AgentUsage/AgentUsageService.swift", prefix)
                    .replace("private func", "func", 1)
                    .replace("func read(", "@discardableResult func read(", 1)
                    for prefix in ["    private func start(", "    private func read(", "    private func filesChanged("])
          + "}\n}\n")

    # Claude's limits come from ClaudeAccountsService, which has its
    # own tests; the single-account reading and check schedule are gone.
    (OUTPUT / "AgentClaudeServerService.swift").unlink(missing_ok=True)

    write("AgentUsagePolling.swift", "import Foundation\n"
          + "extension AgentUsagePollingTests {\nfinal class Host: Fixture {\n"
          + declaration("Sources/Brim/Services/AgentUsage/AgentUsageService.swift",
                        "    private func syncPolling(").replace("private func", "func", 1)
          + "}\n}\n")



    # Memory ends a process group through Kill Process's verified
    # signal path; its tests run that path, as shipped, on a child they own.
    kill = "Sources/Brim/Services/KillProcess/KillProcessService.swift"
    write("BrimMemoryKill.swift", "import Darwin\nimport Foundation\n"
          + "extension BrimMemoryTests {\nenum Kill {\n"
          + declaration(kill, "    private struct KillTarget {").replace("private struct", "struct", 1)
          + declaration(kill, "    enum VerifiedSignal:")
          + declaration(kill, "    static func signalVerified(")
          + declaration(kill, "    static func isProtected(")
          + "".join(declaration(kill, prefix).replace("private static", "static", 1)
                    for prefix in ["    private static func identityMatches(", "    private static func currentStartTime("])
          + "}\n}\n")
    # The memory list's rows from the shared table, as shipped: every
    # process is either measured or named as not measured.
    write("BrimMemoryUsage.swift", "import Foundation\n"
          + "extension BrimMemoryTests {\nenum Usage {\n"
          + declaration(usage, "struct ProcessUsage:")
          + declaration(usage, "    static func memoryRows(")
          + "}\n}\n")


if __name__ == "__main__":
    main()
    prune()

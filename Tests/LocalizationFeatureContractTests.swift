// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import VMStatisticsCompat

enum LocalizationFeatureContractTests {
    static func run(_ suite: TestSuite) {
        func expectFormat(_ format: String, _ expected: [String], _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) {
            let actual = TestFormat.parse(format)?.conversions ?? ["invalid format"]
            suite.expect(actual == expected, "\(label): got \(actual), expected \(expected)",
                         file: file, line: line)
        }
        // MARK: Localization format contracts

        let localizedStrings = LocalizationTests.languages
        // Thirty-six feature string sets were held to the no-em-dash rule and
        // the main one never was, so a caption in every language carried a
        // pair of them.
        for (language, strings) in localizedStrings {
            let values = Mirror(reflecting: strings).children.compactMap { $0.value as? String }
            suite.expect(values.allSatisfy { !$0.contains("\u{2014}") },
                   "no em-dash in visible strings (\(language.rawValue))")
            suite.expect(!strings.homebrewGroupDependencies.isEmpty,
                   "the installed-package grouping choice is labeled (\(language.rawValue))")
        }
        // A label that says work is under way ends with the ellipsis character,
        // the way the system's own do, not with three periods. Earlier catalogs
        // differed on this, so it was not an intentional language choice.
        for (language, strings) in localizedStrings {
            let working = [strings.homebrewOperationPreparing, strings.homebrewOperationDownloading,
                           strings.homebrewOperationInstalling, strings.homebrewOperationUninstalling,
                           strings.homebrewOperationUpgrading, strings.homebrewOperationFinalizing,
                           strings.homebrewOperationRefreshing]
            suite.expect(working.allSatisfy { !$0.contains("...") && $0.contains("…") },
                   "work in progress ends with the ellipsis character in \(language.rawValue)")
        }
        for (language, strings) in localizedStrings {
            let prefix = "localization \(language.rawValue)"
            expectFormat(strings.uninstallerSelectedFormat, ["d", "d"], "\(prefix) uninstaller selected format")
            expectFormat(strings.uninstallerFreedFormat, ["@"], "\(prefix) uninstaller freed format")
            for format in [strings.uninstallerRefusedSystemFormat, strings.uninstallerRefusedSharedFormat,
                           strings.uninstallerRefusedNestedFormat, strings.uninstallerRefusedSelfFormat,
                           strings.uninstallerRefusedLinkFormat, strings.uninstallerRefusedUnidentifiedFormat] {
                expectFormat(format, ["@"], "\(prefix) uninstaller refusal format")
            }
            expectFormat(strings.uninstallerRefusedNotApp, [], "\(prefix) uninstaller not-an-app note")
            expectFormat(strings.uninstallerPickerHiddenNote, [], "\(prefix) uninstaller unlisted apps note")
            expectFormat(strings.powerAdapterMaxFormat, ["@"], "\(prefix) adapter max format")
            suite.expect(!strings.keepAwakeRightClickToggle.isEmpty
                   && !strings.keepAwakeRightClickToggleCaption.isEmpty
                   && !strings.keepAwakeRightClickToggle.contains("—")
                   && !strings.keepAwakeRightClickToggleCaption.contains("—"),
                   "\(prefix) right-click Keep Awake labels are present without em dash")
            expectFormat(strings.homebrewConfirmInstallBodyFormat, ["@"], "\(prefix) Homebrew install format")
            expectFormat(strings.homebrewConfirmUninstallBodyFormat, ["@"], "\(prefix) Homebrew uninstall format")
            expectFormat(strings.homebrewConfirmUpgradeBodyFormat, ["@"], "\(prefix) Homebrew upgrade format")
            suite.expect(!strings.homebrewUpgradeAll.isEmpty, "\(prefix) Homebrew update all title is present")
            suite.expect(!strings.homebrewUpdateHomebrew.isEmpty, "\(prefix) Homebrew update Homebrew title is present")
            suite.expect(!strings.diskAvailable.isEmpty
                   && !strings.diskPurgeable.isEmpty
                   && !strings.diskAvailable.contains("—")
                   && !strings.diskPurgeable.contains("—"),
                   "\(prefix) disk available and purgeable labels are present without em dash")
            suite.expect(!strings.networkApps.isEmpty, "\(prefix) network app usage title is present")
            suite.expect(!strings.networkAppsIdle.isEmpty, "\(prefix) network app idle text is present")
            suite.expect(!strings.monitorOpenActivityMonitor.isEmpty
                   && !strings.monitorOpenActivityMonitor.contains("—"),
                   "\(prefix) Activity Monitor action is present without em dash")
            suite.expect(!strings.memoryCompressed.isEmpty
                   && !strings.memoryCompressed.contains("—")
                   && !strings.memoryCachedFiles.isEmpty
                   && !strings.memoryCachedFiles.contains("—"),
                   "\(prefix) memory compressed and cached labels are present without em dash")
            suite.expect(!strings.launchAtLoginNeedsApplications.isEmpty
                   && !strings.launchAtLoginNeedsApplications.contains("—"),
                   "\(prefix) launch at login location note is present without em dash")
            // Shortcut recording: the waiting cap, the two hints under the row
            // and the honest message for a combination that never arrived (#308).
            let shortcutCaptureStrings = [strings.shortcutPressKeys, strings.shortcutEscapeHint,
                                          strings.shortcutDeleteHint, strings.shortcutNotCaptured,
                                          strings.shortcutRecording, strings.shortcutInvalid]
            suite.expect(shortcutCaptureStrings.allSatisfy { !$0.isEmpty && !$0.contains("—") },
                   "\(prefix) shortcut recording strings are present without em dash")
            suite.expect(!ShortcutRecordingCaption.text(strings, canClear: false).isEmpty
                   && !ShortcutRecordingCaption.text(strings, canClear: false)
                       .contains(strings.shortcutDeleteHint),
                   "\(prefix) a field that cannot clear never promises that Delete clears")
            suite.expect(ShortcutRecordingCaption.text(strings, canClear: true)
                       .contains(strings.shortcutDeleteHint),
                   "\(prefix) a field that can clear says so")
            suite.expect(strings.shortcutPressKeys.count <= 16,
                   "\(prefix) the waiting cap stays short enough for the field")
            suite.expect(!strings.reviewIntro.isEmpty, "\(prefix) the intro review label is present")
            suite.expect(!strings.homebrewConfirmUpgradeAllTitle.isEmpty, "\(prefix) Homebrew update all confirmation title is present")
            suite.expect(!strings.homebrewConfirmUpgradeAllBody.isEmpty, "\(prefix) Homebrew update all confirmation body is present")
            suite.expect(!strings.homebrewConfirmUpdateHomebrewTitle.isEmpty, "\(prefix) Homebrew update Homebrew confirmation title is present")
            suite.expect(!strings.homebrewConfirmUpdateHomebrewBody.isEmpty, "\(prefix) Homebrew update Homebrew confirmation body is present")
            expectFormat(strings.homebrewPopularityFormat, ["@", "@"], "\(prefix) Homebrew popularity format")
            expectFormat(strings.homebrewOperationInstallFormat, ["@"], "\(prefix) Homebrew operation install format")
            expectFormat(strings.homebrewOperationUninstallFormat, ["@"], "\(prefix) Homebrew operation uninstall format")
            expectFormat(strings.homebrewOperationUpgradeFormat, ["@"], "\(prefix) Homebrew operation upgrade format")
            suite.expect(!strings.homebrewOperationUpgradeAll.isEmpty, "\(prefix) Homebrew operation update all is present")
            suite.expect(!strings.homebrewOperationUpdateHomebrew.isEmpty, "\(prefix) Homebrew operation update Homebrew is present")
            expectFormat(strings.homebrewOperationInstalledFormat, ["@"], "\(prefix) Homebrew operation installed format")
            expectFormat(strings.homebrewOperationUninstalledFormat, ["@"], "\(prefix) Homebrew operation uninstalled format")
            expectFormat(strings.homebrewOperationUpgradedFormat, ["@"], "\(prefix) Homebrew operation upgraded format")
            suite.expect(!strings.homebrewOperationUpgradedAll.isEmpty, "\(prefix) Homebrew operation updated all is present")
            suite.expect(!strings.homebrewOperationUpdatedHomebrew.isEmpty, "\(prefix) Homebrew operation updated Homebrew is present")
            expectFormat(strings.homebrewOperationFailedFormat, ["@"], "\(prefix) Homebrew operation failed format")
            expectFormat(strings.homebrewOperationElapsedFormat, ["@"], "\(prefix) Homebrew operation elapsed format")

        }
        let infoPlist = NSDictionary(contentsOfFile: "Resources/Info.plist") as? [String: Any]
        let bundleLocalizations = infoPlist?["CFBundleLocalizations"] as? [String] ?? []
        suite.expect(bundleLocalizations == ["en"], "the bundle declares English as its only localization")
        let automationPrompt = infoPlist?["NSAppleEventsUsageDescription"] as? String ?? ""
        suite.expect(automationPrompt.contains("Finder") && automationPrompt.contains("Trash"),
               "the Automation prompt names the one target the kept features script, the Finder's Trash")
        suite.expect(["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
                      "NSCalendarsFullAccessUsageDescription", "NSCameraUseContinuityCameraDeviceType"]
                        .allSatisfy { infoPlist?[$0] == nil },
               "no usage prompt remains for a resource no kept feature reads")
        let organizerFolderPromptKeys = [
            "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
            "NSNetworkVolumesUsageDescription", "NSRemovableVolumesUsageDescription",
        ]
        suite.expect(organizerFolderPromptKeys.allSatisfy {
                   !(infoPlist?[$0] as? String ?? "").isEmpty
               },
               "the organizer declares every supported custom destination permission")
        // The permission prompts live in Info.plist itself: a localized
        // InfoPlist.strings would override them in one language only.
        let localizedInfoPlists = (try? FileManager.default.contentsOfDirectory(
            atPath: "Resources"))?.filter { $0.hasSuffix(".lproj") } ?? []
        suite.expect(localizedInfoPlists.isEmpty, "no localized resource folders ship beside the English Info.plist")
        // The fan helper's launchd plist ships with the release identifier in
        // three places, and every build rewrites each one for its variant so
        // the two apps can run side by side. A fourth mention added without a
        // matching rewrite would leave the Developer build asking launchd for a
        // service that is registered under the other name, and fan control
        // would just never answer.
        let helperTemplate = (try? String(contentsOfFile: "Resources/fan-control.plist", encoding: .utf8)) ?? ""
        suite.expect(!helperTemplate.isEmpty, "the helper template reads back")
        let identity = (try? String(contentsOfFile: "Tools/identity.sh", encoding: .utf8)) ?? ""
        let releaseHelperID = identity.contains("BRIM_RELEASE_BUNDLE_ID=\"com.roblesconsulting.brim\"")
            ? "com.roblesconsulting.brim.fan-control" : "<Tools/identity.sh names another release ID>"
        let mentions = helperTemplate.components(separatedBy: releaseHelperID).count - 1
        suite.expect(mentions == 3,
               "the helper template names the release service exactly where the build rewrites it (\(mentions))")
        let buildText = (try? String(contentsOfFile: "build.sh", encoding: .utf8)) ?? ""
        for key in ["Set :Label $FAN_HELPER_ID",
                    "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID",
                    "Delete :MachServices\"",
                    "Add :MachServices dict",
                    "Add :MachServices:$FAN_HELPER_ID bool true"] {
            suite.expect(buildText.contains(key), "every build rewrites \(key)")
        }
        // Every shortcut the app ships with is written to disk as a string and
        // read back on the next launch. One that does not survive the trip
        // would leave that feature with no shortcut at all, on a fresh install,
        // with nothing to show for it.
        let defaultShortcuts: [(String, GlobalShortcut)] = [
            ("clipboardDefault", GlobalShortcut.clipboardDefault),
            ("keepAwakeDefault", GlobalShortcut.keepAwakeDefault),
            ("notchDefault", GlobalShortcut.notchDefault),
            ("pastePlainDefault", GlobalShortcut.pastePlainDefault),
        ]
        var brokenShortcuts: [String] = []
        for (name, shortcut) in defaultShortcuts {
            guard let restored = GlobalShortcut(storageValue: shortcut.storageValue),
                  restored.storageValue == shortcut.storageValue else {
                brokenShortcuts.append(name)
                continue
            }
        }
        suite.expect(brokenShortcuts.isEmpty,
               "a default shortcut survives being written and read back (\(brokenShortcuts.joined(separator: ", ")))")
    }
}

extension LocalizationFeatureContractTests {
    static func sortingChecks(_ suite: TestSuite) {
        // A plain sort orders by Unicode scalar, which throws every accented
        // name past Z. Lists of names people read are sorted by the rules of
        // the language instead, and the onboarding one is on the first screen
        // anyone sees.
        let accented = ["Zebra", "Ímã", "Área"]
        suite.expect(accented.sorted() == ["Zebra", "Área", "Ímã"],
               "a plain sort really does put accented names after Z")
        suite.expect(accented.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                == ["Área", "Ímã", "Zebra"],
               "the localized compare is what puts them where a reader expects")
        let onboardingSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Onboarding/OnboardingView.swift",
            encoding: .utf8)) ?? ""
        suite.expect(!onboardingSource.isEmpty, "the onboarding source reads back for its sorting check")
        let onboardingCode = onboardingSource.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        suite.expect(!onboardingCode.contains(".sorted()\n"),
               "onboarding sorts the names it shows by the rules of the language")
    }
}

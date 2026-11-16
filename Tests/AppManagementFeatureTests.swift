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

enum AppManagementFeatureTests {
    static func run(_ suite: TestSuite) {
        let registeredDefaults = Defaults.registeredDefaults
        suite.expect(registeredDefaults[DefaultsKey.panelUtilityCleaner] as? Bool == true,
               "the cleaner row is visible in the panel utilities like its siblings")
        suite.expect(registeredDefaults[DefaultsKey.cleanerScheduleFrequency] as? String == "off",
               "automatic cleanup is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.cleanerScheduleHour] as? Int == 9
               && registeredDefaults[DefaultsKey.cleanerScheduleMinute] as? Int == 0
               && registeredDefaults[DefaultsKey.cleanerScheduleWeekday] as? Int == 2,
               "the schedule defaults to nine in the morning on Mondays")
        suite.expect(registeredDefaults[DefaultsKey.cleanerScheduleNotify] as? Bool == true,
               "the schedule reports its outcome unless the user opts out")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppDownloadsEnabled] as? Bool == false,
               "WhatsApp downloads stay hidden until the user turns them on")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppDownloadsAutomaticEnabled] as? Bool == false,
               "WhatsApp automatic cleanup is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppDownloadsCategories] as? String
               == "image,video,audio",
               "WhatsApp cleanup starts with conservative media categories")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppDownloadsRetentionDays] as? Int == 7,
               "WhatsApp downloads keep a seven day default window")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppDownloadsAccessConfirmed] as? Bool == false,
               "WhatsApp cleanup never probes Downloads in the background before explicit access")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppOrganizerEnabled] as? Bool == false,
               "the experimental WhatsApp organizer is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.whatsAppOrganizerDelayMinutes] as? Int == 5
                && registeredDefaults[DefaultsKey.whatsAppOrganizerLayout] as? String == "flat"
                && registeredDefaults[DefaultsKey.whatsAppOrganizerDuplicateAction] as? String
                    == "trashNew",
               "the organizer starts with a five minute grace period and safe duplicate policy")
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        func scheduleDate(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: day,
                                                  hour: hour, minute: minute)) ?? Date()
        }
        suite.expect(CleanerSchedule.nextFireDate(after: scheduleDate(9, 8, 0), frequency: .daily,
                                            hour: 9, minute: 0, weekday: 2,
                                            calendar: utcCalendar) == scheduleDate(9, 9, 0),
               "a daily schedule still due today fires today")
        suite.expect(CleanerSchedule.nextFireDate(after: scheduleDate(9, 10, 0), frequency: .daily,
                                            hour: 9, minute: 0, weekday: 2,
                                            calendar: utcCalendar) == scheduleDate(10, 9, 0),
               "a daily schedule already past fires tomorrow")
        suite.expect(CleanerSchedule.nextFireDate(after: scheduleDate(9, 10, 0), frequency: .weekly,
                                            hour: 9, minute: 0, weekday: 2,
                                            calendar: utcCalendar) == scheduleDate(13, 9, 0),
               "a weekly Monday schedule queried on Thursday fires next Monday")
        suite.expect(CleanerSchedule.nextFireDate(after: scheduleDate(9, 10, 0), frequency: .off,
                                            hour: 9, minute: 0, weekday: 2,
                                            calendar: utcCalendar) == nil,
               "an off schedule never fires")
        suite.expect(CleanerSchedule.missedRun(now: scheduleDate(9, 10, 0),
                                         lastRun: scheduleDate(8, 9, 30),
                                         frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                         calendar: utcCalendar),
               "a fire that passed while the Mac was off counts as missed")
        suite.expect(!CleanerSchedule.missedRun(now: scheduleDate(9, 10, 0),
                                          lastRun: scheduleDate(9, 9, 30),
                                          frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                          calendar: utcCalendar),
               "a run that already happened today is not missed")
        suite.expect(!CleanerSchedule.missedRun(now: scheduleDate(9, 10, 0), lastRun: nil,
                                          frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                          calendar: utcCalendar),
               "enabling the schedule never triggers a surprise first run")
        suite.expect(CleanerSchedule.hour24(hour12: 12, isPM: false) == 0
               && CleanerSchedule.hour24(hour12: 12, isPM: true) == 12
               && CleanerSchedule.hour24(hour12: 1, isPM: true) == 13
               && CleanerSchedule.hour24(hour12: 11, isPM: false) == 11,
               "twelve hour picks map to the right clock hours, midnight and noon included")
        suite.expect(CleanerSchedule.hour12Components(fromHour24: 0) == (12, false)
               && CleanerSchedule.hour12Components(fromHour24: 12) == (12, true)
               && CleanerSchedule.hour12Components(fromHour24: 18) == (6, true)
               && CleanerSchedule.hour12Components(fromHour24: 9) == (9, false),
               "clock hours split back into the twelve hour pickers")
        suite.expect((0...23).allSatisfy { hour in
                   let parts = CleanerSchedule.hour12Components(fromHour24: hour)
                   return CleanerSchedule.hour24(hour12: parts.hour12, isPM: parts.isPM) == hour
               },
               "every hour of the day round trips through the twelve hour pickers")

        // MARK: WhatsApp downloads

        let whatsAppEnabledSuite = "brim.tests.whatsapp.enabled"
        if let migrationDefaults = UserDefaults(suiteName: whatsAppEnabledSuite) {
            migrationDefaults.removePersistentDomain(forName: whatsAppEnabledSuite)
            Defaults.migrateWhatsAppDownloadsEnabled(in: migrationDefaults)
            suite.expect(migrationDefaults.object(forKey: DefaultsKey.whatsAppDownloadsEnabled) == nil,
                   "an untouched setup keeps WhatsApp downloads off by leaving the new switch unset")
            migrationDefaults.set(true, forKey: DefaultsKey.whatsAppDownloadsAutomaticEnabled)
            Defaults.migrateWhatsAppDownloadsEnabled(in: migrationDefaults)
            suite.expect(migrationDefaults.bool(forKey: DefaultsKey.whatsAppDownloadsEnabled),
                   "an existing automatic WhatsApp cleanup keeps its Cleaner surface")
            migrationDefaults.removePersistentDomain(forName: whatsAppEnabledSuite)
            migrationDefaults.set(true, forKey: DefaultsKey.whatsAppOrganizerEnabled)
            Defaults.migrateWhatsAppDownloadsEnabled(in: migrationDefaults)
            suite.expect(migrationDefaults.bool(forKey: DefaultsKey.whatsAppDownloadsEnabled),
                   "an existing WhatsApp organizer keeps its Cleaner surface")
            migrationDefaults.removePersistentDomain(forName: whatsAppEnabledSuite)
            migrationDefaults.set(true, forKey: DefaultsKey.whatsAppDownloadsAccessConfirmed)
            Defaults.migrateWhatsAppDownloadsEnabled(in: migrationDefaults)
            suite.expect(migrationDefaults.object(forKey: DefaultsKey.whatsAppDownloadsEnabled) == nil,
                   "only opening Downloads does not keep the WhatsApp Cleaner surface")
            migrationDefaults.set(false, forKey: DefaultsKey.whatsAppDownloadsEnabled)
            Defaults.migrateWhatsAppDownloadsEnabled(in: migrationDefaults)
            suite.expect(!migrationDefaults.bool(forKey: DefaultsKey.whatsAppDownloadsEnabled),
                   "the WhatsApp downloads migration preserves a newer off choice")
            migrationDefaults.removePersistentDomain(forName: whatsAppEnabledSuite)
        } else {
            suite.expect(false, "WhatsApp downloads migration suite can be created")
        }
        suite.expect(WhatsAppDownloadSupport.isWhatsAppAgent("WhatsApp")
                && WhatsAppDownloadSupport.isWhatsAppAgent(" whatsapp ")
                && !WhatsAppDownloadSupport.isWhatsAppAgent("SomeBrowser")
                && !WhatsAppDownloadSupport.isWhatsAppAgent(nil),
               "only an explicit WhatsApp quarantine agent is trusted")
        suite.expect(WhatsAppDownloadSupport.category(contentTypeIdentifier: "public.jpeg",
                                                 extension: "jpeg") == .image
                && WhatsAppDownloadSupport.category(contentTypeIdentifier: "public.mpeg-4",
                                                     extension: "mp4") == .video
                && WhatsAppDownloadSupport.category(contentTypeIdentifier: "public.mp3",
                                                     extension: "mp3") == .audio
                && WhatsAppDownloadSupport.category(contentTypeIdentifier: "com.adobe.pdf",
                                                     extension: "pdf") == .document
                && WhatsAppDownloadSupport.category(contentTypeIdentifier: nil,
                                                     extension: "zip") == .archive,
               "WhatsApp files land in the expected user-facing buckets")
        suite.expect(WhatsAppDownloadSupport.isIncompleteFile(extension: "download")
                && WhatsAppDownloadSupport.isIncompleteFile(extension: "PART")
                && !WhatsAppDownloadSupport.isIncompleteFile(extension: "pdf"),
               "partial downloads can never become cleanup candidates")
        let whatsNow = scheduleDate(20, 12, 0)
        let whatsOld = scheduleDate(10, 12, 0)
        let whatsRecent = scheduleDate(19, 12, 0)
        suite.expect(WhatsAppDownloadSupport.isOldEnough(downloadedAt: whatsOld,
                                                   modifiedAt: whatsOld,
                                                   now: whatsNow, retentionDays: 7,
                                                   calendar: utcCalendar),
               "an untouched old WhatsApp download passes retention")
        suite.expect(!WhatsAppDownloadSupport.isOldEnough(downloadedAt: whatsOld,
                                                    modifiedAt: whatsRecent,
                                                    now: whatsNow, retentionDays: 7,
                                                    calendar: utcCalendar),
               "a recent edit postpones WhatsApp cleanup")
        suite.expect(!WhatsAppDownloadSupport.isEligibleForAutomaticCleanup(
                    category: .image, downloadedAt: whatsOld, modifiedAt: whatsOld,
                    now: whatsNow, retentionDays: 7, enabledCategories: [.image],
                    includeExisting: false, automaticStartDate: whatsRecent),
               "future-only automation leaves pre-existing downloads alone")
        suite.expect(WhatsAppDownloadSupport.isEligibleForAutomaticCleanup(
                    category: .image, downloadedAt: whatsOld, modifiedAt: whatsOld,
                    now: whatsNow, retentionDays: 7, enabledCategories: [.image],
                    includeExisting: true, automaticStartDate: whatsRecent),
               "explicitly including existing downloads admits old matches")
        let downloadsRoot = URL(fileURLWithPath: "/Users/test/Downloads")
        suite.expect(WhatsAppDownloadSupport.isDirectChild(
                    URL(fileURLWithPath: "/Users/test/Downloads/file.pdf"), of: downloadsRoot)
                && !WhatsAppDownloadSupport.isDirectChild(
                    URL(fileURLWithPath: "/Users/test/Downloads/folder/file.pdf"), of: downloadsRoot)
                && !WhatsAppDownloadSupport.isDirectChild(
                    URL(fileURLWithPath: "/Users/test/Documents/file.pdf"), of: downloadsRoot),
               "WhatsApp cleanup accepts only direct children of Downloads")
        let organizedFile = URL(fileURLWithPath: "/Users/test/Downloads/WhatsApp/2026/07/file.pdf")
        suite.expect(WhatsAppDownloadSupport.isDescendant(organizedFile, of: downloadsRoot)
                && !WhatsAppDownloadSupport.isDescendant(downloadsRoot, of: downloadsRoot)
                && !WhatsAppDownloadSupport.isDescendant(
                    URL(fileURLWithPath: "/Users/test/Download/file.pdf"), of: downloadsRoot),
               "organized cleanup accepts descendants without path-prefix confusion")
        let fourMinutesAgo = whatsNow.addingTimeInterval(-4 * 60)
        let sixMinutesAgo = whatsNow.addingTimeInterval(-6 * 60)
        suite.expect(!WhatsAppDownloadSupport.isStableForOrganization(
                    downloadedAt: sixMinutesAgo, modifiedAt: fourMinutesAgo,
                    now: whatsNow, delayMinutes: 5)
                && WhatsAppDownloadSupport.isStableForOrganization(
                    downloadedAt: sixMinutesAgo, modifiedAt: sixMinutesAgo,
                    now: whatsNow, delayMinutes: 5)
                && WhatsAppDownloadSupport.sanitizedOrganizerDelayMinutes(999) == 5,
               "organization waits for both download and modification activity to settle")
        let undoCreatedAt = whatsNow.addingTimeInterval(-6 * 86_400)
        suite.expect(WhatsAppDownloadSupport.organizerUndoIsValid(
                    createdAt: undoCreatedAt, now: whatsNow)
                && !WhatsAppDownloadSupport.organizerUndoIsValid(
                    createdAt: whatsNow.addingTimeInterval(-7 * 86_400), now: whatsNow)
                && !WhatsAppDownloadSupport.organizerUndoIsValid(
                    createdAt: whatsNow.addingTimeInterval(1), now: whatsNow),
               "organizer undo is executable only during its seven day window")
        suite.expect(WhatsAppDownloadSupport.organizerRelativeComponents(
                    layout: .flat, category: .image, date: whatsNow,
                    calendar: utcCalendar).isEmpty
                && WhatsAppDownloadSupport.organizerRelativeComponents(
                    layout: .category, category: .image, date: whatsNow,
                    calendar: utcCalendar) == ["Images"]
                && WhatsAppDownloadSupport.organizerRelativeComponents(
                    layout: .month, category: .image, date: whatsNow,
                    calendar: utcCalendar) == ["2026", "07"],
               "the organizer produces stable flat, type and month folder layouts")
        let volumeA = NSData(bytes: [0x67, 0x45, 0x64, 0x00] as [UInt8], length: 4)
        let volumeB = NSData(bytes: [0x69, 0x98, 0x66, 0x00] as [UInt8], length: 4)
        suite.expect(WhatsAppDownloadSupport.isSameVolume(
                    source: volumeA,
                    destination: NSData(bytes: [0x67, 0x45, 0x64, 0x00] as [UInt8], length: 4)),
               "two equal volume identifiers are one volume even as separate objects")
        suite.expect(!WhatsAppDownloadSupport.isSameVolume(source: volumeA, destination: volumeB),
               "two different volume identifiers never skip the destination check")
        suite.expect(!WhatsAppDownloadSupport.isSameVolume(source: NSNumber(value: 1),
                                                     destination: NSString(string: "1")),
               "unequal identities that print the same string still take the verified path")
        suite.expect(!WhatsAppDownloadSupport.isSameVolume(source: volumeA, destination: nil)
                && !WhatsAppDownloadSupport.isSameVolume(source: nil, destination: volumeB)
                && !WhatsAppDownloadSupport.isSameVolume(source: nil, destination: nil),
               "an unknown volume identity keeps the verified copy rather than an unchecked rename")
        suite.expect(WhatsAppDownloadSupport.nextAutomaticCheck(
                    after: scheduleDate(20, 8, 0), calendar: utcCalendar) == scheduleDate(20, 9, 0)
                && WhatsAppDownloadSupport.nextAutomaticCheck(
                    after: scheduleDate(20, 10, 0), calendar: utcCalendar) == scheduleDate(21, 9, 0),
               "the hidden daily WhatsApp check targets nine in the morning")
        suite.expect(WhatsAppDownloadSupport.missedAutomaticCheck(
                    now: scheduleDate(20, 12, 0), lastRun: scheduleDate(19, 9, 0),
                    calendar: utcCalendar)
                && !WhatsAppDownloadSupport.missedAutomaticCheck(
                    now: scheduleDate(20, 8, 0), lastRun: scheduleDate(19, 9, 0),
                    calendar: utcCalendar)
                && !WhatsAppDownloadSupport.missedAutomaticCheck(
                    now: scheduleDate(20, 12, 0), lastRun: nil, calendar: utcCalendar),
               "missed WhatsApp checks recover after nine without a first-enable surprise")
        BrimIdentity.bundleIdentifier = "com.roblesconsulting.brim"    // as if installed
        suite.expect(CleanerSupport.isProtectedBundleID("com.apple.Music")
               && CleanerSupport.isProtectedBundleID("com.apple")
               && CleanerSupport.isProtectedBundleID("group.com.apple.notes")
               && CleanerSupport.isProtectedBundleID("com.roblesconsulting.brim"),
               "system domains and this app can never be junk owners")
        suite.expect(!CleanerSupport.isProtectedBundleID("com.vendor.editor"),
               "third party identifiers are eligible for the leftover check")
        suite.expect(UninstallerSupport.verifiedBundleID("com.vendor.editor") == "com.vendor.editor"
               && UninstallerSupport.verifiedBundleID("com.vendor.editor.helper") == "com.vendor.editor.helper"
               && UninstallerSupport.verifiedBundleID("test.editor") == "test.editor"
               && UninstallerSupport.verifiedBundleID("editor.test") == "editor.test",
               "the uninstaller accepts exact third party bundle identifiers, two-component IDs, and embedded helpers")
        suite.expect(UninstallerSupport.verifiedBundleID(nil) == nil
               && UninstallerSupport.verifiedBundleID("") == nil
               && UninstallerSupport.verifiedBundleID("plain-name") == nil
               && UninstallerSupport.verifiedBundleID("com.vendor../escape") == nil
               && UninstallerSupport.verifiedBundleID("com.roblesconsulting.brim") == nil
               && UninstallerSupport.verifiedBundleID("com.apple.system") == nil,
               "malformed, protected and current app identifiers never enter uninstall paths")
        let selectionFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-uninstaller-selection-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: selectionFixture, withIntermediateDirectories: true)
        func selectionBundle(_ name: String, bundleID: String) -> URL {
            let app = selectionFixture.appendingPathComponent(name, isDirectory: true)
            let info = app.appendingPathComponent("Contents/Info.plist")
            try? FileManager.default.createDirectory(at: info.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                               format: .xml, options: 0) {
                try? data.write(to: info)
            }
            return app
        }
        let editorApp = selectionBundle("Editor.app", bundleID: "com.vendor.editor")
        suite.expect(UninstallerSupport.selection(for: URL(string: "https://example.com/App.app")!) == nil,
               "a web address is refused before loading an app bundle")
        let editorSelection = UninstallerSupport.selection(for: editorApp)
        suite.expect(editorSelection?.bundleID == "com.vendor.editor"
               && editorSelection?.url == editorApp.standardizedFileURL,
               "a complete third party app bundle is accepted with its standardized path")
        let appleEditorApp = selectionBundle("AppleEditor.app", bundleID: "com.apple.editor")
        suite.expect(UninstallerSupport.selection(for: appleEditorApp) == nil,
               "an Apple bundle identifier is refused before it can claim uninstall paths")
        let aliasApp = selectionFixture.appendingPathComponent("Alias.app")
        try? FileManager.default.createSymbolicLink(at: aliasApp, withDestinationURL: editorApp)
        suite.expect(UninstallerSupport.selection(for: aliasApp) == nil,
               "an app symlink is refused instead of selecting its destination")
        let bareApp = selectionFixture.appendingPathComponent("Bare.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: bareApp, withIntermediateDirectories: true)
        suite.expect(UninstallerSupport.selection(for: bareApp) == nil,
               "a bundle without Info.plist is refused before a scan starts")
        func writeInfo(_ bundleID: String, to info: URL) {
            try? FileManager.default.createDirectory(at: info.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0) {
                try? data.write(to: info)
            }
        }
        // A bundle with its Info.plist at the top and nothing else is an
        // iPhone app's own bundle out of its wrapper, not a Mac app.
        let flatApp = selectionFixture.appendingPathComponent("Flat.app", isDirectory: true)
        writeInfo("com.vendor.flat", to: flatApp.appendingPathComponent("Info.plist"))
        suite.expect(Bundle(url: flatApp)?.bundleIdentifier == "com.vendor.flat"
               && UninstallerSupport.selection(for: flatApp) == nil,
               "a bare iPhone-style bundle with no Contents/Info.plist is refused")
        // Bundle(url:) caches by path for the whole process, so a different
        // app that later sits at a path already read (a Trash name reused
        // after Empty Trash) must still be read from disk.
        let reusedApp = selectionFixture.appendingPathComponent("Reused.app", isDirectory: true)
        writeInfo("com.vendor.first", to: reusedApp.appendingPathComponent("Contents/Info.plist"))
        let firstReused = UninstallerSupport.selection(for: reusedApp)?.bundleID
        _ = Bundle(url: reusedApp)?.bundleIdentifier
        try? FileManager.default.removeItem(at: reusedApp)
        writeInfo("com.vendor.second", to: reusedApp.appendingPathComponent("Contents/Info.plist"))
        suite.expect(firstReused == "com.vendor.first"
               && UninstallerSupport.selection(for: reusedApp)?.bundleID == "com.vendor.second"
               && UninstallerSupport.bundleIdentifier(of: reusedApp) == "com.vendor.second",
               "a different app at a path already read is selected by its own bundle ID")
        let reviewed = UninstallerSupport.selection(for: reusedApp)
        suite.expect(reviewed?.isCurrent == true, "the current selection matches its app on disk")
        let reusedInfo = reusedApp.appendingPathComponent("Contents/Info.plist")
        try? Data(contentsOf: reusedInfo).write(to: reusedInfo, options: .atomic)
        suite.expect(reviewed?.isCurrent == false,
               "replacing the Info.plist invalidates the earlier selection")
        // An iPhone or iPad app installed on a Mac with Apple silicon (#1582):
        // the App Store keeps the real bundle in Wrapper with its Info.plist at
        // the top, and Bundle reads it through the WrappedBundle link.
        func wrapper(_ name: String, link: String, bundleID: String, bundle: String? = nil) -> URL {
            let app = selectionFixture.appendingPathComponent(name + ".app", isDirectory: true)
            writeInfo(bundleID, to: app.appendingPathComponent((bundle ?? "Wrapper/\(name).app") + "/Info.plist"))
            try? FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("WrappedBundle").path, withDestinationPath: link)
            return app
        }
        let mimoApp = wrapper("Mimo", link: "Wrapper/Mimo.app", bundleID: "com.vendor.mimo")
        let mimoInfo = mimoApp.appendingPathComponent("Wrapper/Mimo.app/Info.plist")
        let mimoSelection = UninstallerSupport.selection(for: mimoApp)
        suite.expect(Bundle(url: mimoApp)?.bundleIdentifier == "com.vendor.mimo"
               && mimoSelection?.bundleID == "com.vendor.mimo"
               && mimoSelection?.url == mimoApp.standardizedFileURL
               && mimoSelection?.infoIdentity == UninstallerSupport.fileIdentity(at: mimoInfo),
               "an iPhone or iPad app's wrapper is accepted and keeps its inner Info.plist as proof")
        // The scan and the removal trust a selection again only while the
        // wrapper and its inner Info.plist are the files it verified.
        func stillSelected(_ app: URL, _ selection: UninstallerSupport.Selection?) -> Bool {
            UninstallerSupport.applicationIdentityMatches(app, appIdentity: selection?.identity,
                                                          infoIdentity: selection?.infoIdentity)
        }
        suite.expect(stillSelected(mimoApp, mimoSelection),
               "a selected iPhone or iPad app still matches its selection when the scan ends")
        let swappedApp = wrapper("Swapped", link: "Wrapper/Swapped.app", bundleID: "com.vendor.swapped")
        let swappedInfo = swappedApp.appendingPathComponent("Wrapper/Swapped.app/Info.plist")
        let swappedSelection = UninstallerSupport.selection(for: swappedApp)
        // An atomic write puts the same contents in a new file.
        try? Data(contentsOf: swappedInfo).write(to: swappedInfo, options: .atomic)
        suite.expect(swappedSelection != nil && !stillSelected(swappedApp, swappedSelection),
               "a wrapper whose inner Info.plist was replaced no longer matches its selection")
        let resealedSelection = UninstallerSupport.selection(for: swappedApp)
        // A new wrapper folder takes over the same inner bundle, so only the
        // wrapper itself changes. The old folder stays aside so the new one
        // cannot reuse its inode.
        let oldSwappedApp = selectionFixture.appendingPathComponent("Swapped Old.app", isDirectory: true)
        try? FileManager.default.moveItem(at: swappedApp, to: oldSwappedApp)
        try? FileManager.default.createDirectory(at: swappedApp, withIntermediateDirectories: true)
        for item in ["Wrapper", "WrappedBundle"] {
            try? FileManager.default.moveItem(at: oldSwappedApp.appendingPathComponent(item),
                                              to: swappedApp.appendingPathComponent(item))
        }
        suite.expect(resealedSelection != nil
               && UninstallerSupport.selection(for: swappedApp)?.infoIdentity == resealedSelection?.infoIdentity
               && !stillSelected(swappedApp, resealedSelection),
               "a wrapper replaced by another copy no longer matches its selection")
        // Bundle prefers the wrapped bundle over a Contents folder, so the
        // proof has to be the Info.plist the verified identifier came from.
        let mixedApp = wrapper("Mixed", link: "Wrapper/Mixed.app", bundleID: "com.vendor.mixed")
        writeInfo("com.vendor.contents", to: mixedApp.appendingPathComponent("Contents/Info.plist"))
        suite.expect(Bundle(url: mixedApp)?.bundleIdentifier == "com.vendor.mixed"
               && UninstallerSupport.infoPlistURL(in: mixedApp).path
                   == mixedApp.appendingPathComponent("Wrapper/Mixed.app/Info.plist").path,
               "a wrapper with a Contents folder too is proved by the bundle Bundle reads")
        // Bundle follows only a relative link, with no trailing slash, to a
        // lowercase .app inside Wrapper. Each other link must read as no
        // wrapper too.
        // Appended to the wrapper, "/Wrapper/Rooted.app" lands inside Wrapper,
        // so only the leading slash turns that one down.
        let refusedLinks = [
            ("leaves the Wrapper folder",
             wrapper("Escaping", link: "../Editor.app", bundleID: "com.vendor.escaping")),
            ("is absolute",
             wrapper("Absolute", link: selectionFixture
                 .appendingPathComponent("Absolute.app/Wrapper/Absolute.app").path,
                 bundleID: "com.vendor.absolute")),
            ("starts with a slash",
             wrapper("Rooted", link: "/Wrapper/Rooted.app", bundleID: "com.vendor.rooted")),
            ("ends in a slash",
             wrapper("Slashed", link: "Wrapper/Slashed.app/", bundleID: "com.vendor.slashed")),
            ("names no .app",
             wrapper("Plain", link: "Wrapper/Plain", bundleID: "com.vendor.plain", bundle: "Wrapper/Plain")),
            ("names an uppercase .APP",
             wrapper("Upper", link: "Wrapper/Upper.APP", bundleID: "com.vendor.upper", bundle: "Wrapper/Upper.APP")),
            ("points to another folder",
             wrapper("Elsewhere", link: "Other/Elsewhere.app", bundleID: "com.vendor.elsewhere",
                     bundle: "Other/Elsewhere.app")),
        ]
        for (rule, app) in refusedLinks {
            suite.expect(Bundle(url: app)?.bundleIdentifier == nil
                   && UninstallerSupport.wrappedBundleURL(in: app) == nil
                   && UninstallerSupport.selection(for: app) == nil,
                   "a WrappedBundle link that \(rule) is no wrapper, as Bundle reads it")
        }
        // A tool or helper inside another app's bundle belongs to that app:
        // removing it alone would break the app it ships in.
        let hostedApp = selectionBundle("Host.app/Contents/Applications/Tool.app", bundleID: "com.vendor.host.tool")
        suite.expect(Bundle(url: hostedApp)?.bundleIdentifier == "com.vendor.host.tool"
               && UninstallerSupport.selection(for: hostedApp) == nil,
               "an app inside another app's bundle is refused")
        // Every refusal names its rule, so the drop zone can say it (#1582).
        func refusal(_ url: URL) -> UninstallerSupport.Refusal? {
            if case let .failure(reason) = UninstallerSupport.evaluate(url) { return reason }
            return nil
        }
        let ownApp = selectionBundle("Copy.app", bundleID: "com.roblesconsulting.brim.dev")
        let plainFolder = selectionFixture.appendingPathComponent("Folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        let document = selectionFixture.appendingPathComponent("Notes.txt")
        try? Data("notes".utf8).write(to: document)
        suite.expect(refusal(URL(string: "https://example.com/App.app")!) == .notAnApp
               && refusal(document) == .notAnApp
               && refusal(plainFolder) == .notAnApp
               && refusal(appleEditorApp) == .sharedIdentifier
               && refusal(ownApp) == .thisApp
               && refusal(aliasApp) == .link
               && refusal(bareApp) == .unidentified
               && refusal(flatApp) == .unidentified
               && refusal(hostedApp) == .insideAnotherApp
               && refusal(editorApp) == nil && refusal(mimoApp) == nil,
               "each refused selection reports the rule that refused it")
        let systemApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        suite.expect(!FileManager.default.fileExists(atPath: systemApp.path) || refusal(systemApp) == .systemApp,
               "an app that is part of macOS is refused as a system app")
        for language in AppLanguage.allCases {
            let strings = Strings.localized(language)
            let named: [UninstallerSupport.Refusal] = [.systemApp, .sharedIdentifier, .insideAnotherApp,
                                                       .link, .unidentified]
            suite.expect(named.allSatisfy {
                       UninstallerSupport.RefusedApp(name: "Editor 7", refusal: $0)
                           .message(strings).contains("Editor 7")
                   }
                   && UninstallerSupport.RefusedApp(name: "Editor 7", refusal: .thisApp)
                       .message(strings).contains(strings.tabAdvanced)
                   && !UninstallerSupport.RefusedApp(name: "Editor 7", refusal: .notAnApp)
                       .message(strings).isEmpty,
                   "every refusal reads as a sentence that names the app in \(language.rawValue)")
        }
        let listedRoot = selectionFixture.appendingPathComponent("Listed", isDirectory: true)
        try? FileManager.default.createDirectory(at: listedRoot, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: mimoApp, to: listedRoot.appendingPathComponent("Mimo.app"))
        suite.expect(InstalledApps.installedApplications(roots: [listedRoot]).map(\.name) == ["Mimo"],
               "the application walk lists a wrapper once, not the bundle inside it")
        try? FileManager.default.removeItem(at: selectionFixture)
        // While the Finder shows every extension, the file manager spells an
        // app's name with its ".app" ("Google Chrome.app"). The lists read it
        // without, as the application walk above already does.
        suite.expect(InstalledApps.displayName(fromFinderName: "Google Chrome.app") == "Google Chrome",
               "an app's name is shown without the .app the file manager adds while the Finder shows every extension")
        suite.expect(InstalledApps.displayName(fromFinderName: "Calculadora") == "Calculadora",
               "an app's name that carries no extension is shown as it is")
        suite.expect(InstalledApps.displayName(fromFinderName: "Foo.App") == "Foo.App",
               "only a lowercase .app at the end of a name is taken off, as the application walk does")
        if InstalledApps.url(for: "com.apple.finder") != nil {
            suite.expect(!InstalledApps.name(for: "com.apple.finder").hasSuffix(".app"),
                   "an installed app is named without .app, whatever the Finder's setting for extensions")
        }
        suite.expect(InstalledApps.name(for: "/opt/game/runtime/bin/java", finderName: { _ in "java.app" }) == "java",
               "an app is named from the file manager's name without its .app")
        suite.expect(InstalledApps.name(for: "com.example.not-installed.app") == "com.example.not-installed.app",
               "an identifier that names no installed app is shown as it is, even when it ends in .app")
        for path in ["Sources/Brim/UI/Uninstall/UninstallerView.swift",
                     "Sources/Brim/UI/MenuPanel/PanelUninstallerView.swift"] {
            let pickerSource = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            suite.expect(pickerSource.contains("UninstallerSupport.offeredApplications()"),
                   "\(path) offers only the apps the shared selection checks accept")
            suite.expect(pickerSource.contains("return uninstaller.select(appURL: app)"),
                   "\(path) springs a refused drop back instead of accepting it")
            suite.expect(pickerSource.contains("UninstallRefusalNote(refusal: refusal")
                   && pickerSource.contains("emptyNote: l10n.s.uninstallerPickerHiddenNote"),
                   "\(path) says why a drop was refused and why an app is not listed")
            suite.expect(pickerSource.components(separatedBy: "uninstaller.clearRefusal()").count == 3,
                   "\(path) drops an old refusal note when it opens and when it closes")
        }
        let uninstallAppURL = URL(fileURLWithPath: "/Applications/Editor.app")
        suite.expect(UninstallerSupport.isNestedBundle(
                   URL(fileURLWithPath: "/Applications/Editor.app/Contents/Library/LoginItems/Background.app"),
                   in: uninstallAppURL)
               && !UninstallerSupport.isNestedBundle(uninstallAppURL, in: uninstallAppURL)
               && !UninstallerSupport.isNestedBundle(
                   URL(fileURLWithPath: "/Applications/Editor.app-copy/Contents/Background.app"),
                   in: uninstallAppURL)
               && !UninstallerSupport.isNestedBundle(nil, in: uninstallAppURL),
               "the uninstaller stops only background apps nested inside the selected bundle")
        suite.expect(!UninstallerSupport.sharedDataIsExclusive(
            selectedURL: URL(fileURLWithPath: "/Users/test/Downloads/Editor.app"),
            bundleID: "com.vendor.editor",
            knownApplications: [
                (URL(fileURLWithPath: "/Users/test/Downloads/Editor.app"), "com.vendor.editor"),
                (URL(fileURLWithPath: "/Applications/Editor.app"), "com.vendor.editor"),
            ])
            && UninstallerSupport.sharedDataIsExclusive(
                selectedURL: URL(fileURLWithPath: "/Applications/Editor.app"),
                bundleID: "com.vendor.editor",
                knownApplications: [
                    (URL(fileURLWithPath: "/Applications/Editor.app"), "com.vendor.editor"),
                    (URL(fileURLWithPath: "/Applications/Other.app"), "com.vendor.other"),
                ]),
               "shared app data is eligible only when no other installed copy owns the bundle identifier")
        suite.expect(UninstallerSupport.sharedDataIsExclusive(
            selectedURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            bundleID: "com.vendor.editor.helper",
            knownApplications: [
                (URL(fileURLWithPath: "/Applications/Editor.app/Contents/Helpers/Helper.app"),
                 "com.vendor.editor.helper"),
            ])
            && UninstallerSupport.applicationIsInTrustedInstallRoot(
                URL(fileURLWithPath: "/Applications/Editor.app"),
                home: URL(fileURLWithPath: "/Users/test"))
            && !UninstallerSupport.applicationIsInTrustedInstallRoot(
                URL(fileURLWithPath: "/Users/test/Downloads/Editor.app"),
                home: URL(fileURLWithPath: "/Users/test")),
               "embedded helpers belong to the selected app while unregistered download copies never own shared data")
        let trashHome = URL(fileURLWithPath: "/Users/test")
        suite.expect(!UninstallerSupport.applicationIsInTrustedInstallRoot(
                URL(fileURLWithPath: "/Users/test/.Trash/Editor.app"), home: trashHome)
            && !UninstallerSupport.applicationIsInTrustedInstallRoot(
                URL(fileURLWithPath: "/Users/test/.Trash/Old Stuff/Editor.app"), home: trashHome)
            && !UninstallerSupport.isInTrash(
                URL(fileURLWithPath: "/Users/test/.Trash"), home: trashHome),
               "a Trash path alone never grants ownership of shared data")
        let uninstallCandidateIDs: Set<String> = ["com.vendor.editor", "com.vendor.editor.helper"]
        suite.expect(UninstallerSupport.exclusiveBundleIDs(
                   uninstallCandidateIDs,
                   selectedURL: uninstallAppURL,
                   knownApplications: []) == uninstallCandidateIDs
               && UninstallerSupport.exclusiveBundleIDs(
                   uninstallCandidateIDs,
                   selectedURL: uninstallAppURL,
                   knownApplications: [
                       (URL(fileURLWithPath: "/Applications/Other.app"),
                        "com.vendor.editor.helper"),
                   ]) == ["com.vendor.editor"],
               "package removal preserves helper candidates while excluding an owner installed elsewhere")
        let uninstallIDs: Set<String> = ["com.vendor.editor", "com.vendor.editor.helper"]
        let leftoverIdentity = UninstallerSupport.identity(
            bundleIDs: uninstallIDs, displayNames: ["Editor", "Editor.app"])
        suite.expect(leftoverIdentity.nameTokens.contains("editor")
               && !leftoverIdentity.nameTokens.contains("helper"),
               "display names become match tokens and helper suffixes do not")
        suite.expect(UninstallerSupport.leftoverMatch("Editor", identity: leftoverIdentity) == .related
               && UninstallerSupport.leftoverMatch("com.vendor.editor.plist", identity: leftoverIdentity) == .exact
               && UninstallerSupport.leftoverMatch(
                   "com.vendor.editor.B787EFF9-B8E2-5296-96AF-DF9D3CD3AC4F.plist",
                   identity: leftoverIdentity) == .exact
               && UninstallerSupport.leftoverMatch("COM.VENDOR.EDITOR.PLIST", identity: leftoverIdentity) == .exact
               && UninstallerSupport.leftoverMatch("Editor.prefPane", identity: leftoverIdentity) == .related
               && UninstallerSupport.leftoverMatch(
                   "ABCD123456.com.vendor.editor", identity: leftoverIdentity) == .none
               && UninstallerSupport.leftoverMatch(
                   "group.com.vendor.editor", identity: leftoverIdentity) == .none
               && UninstallerSupport.leftoverMatch(
                   "com.wrapper.com.vendor.editor", identity: leftoverIdentity) == .none
               && UninstallerSupport.leftoverMatch("Google", identity: leftoverIdentity) == .none
               && UninstallerSupport.leftoverMatch("com.vendor.editor2", identity: leftoverIdentity) == .none
               && UninstallerSupport.leftoverMatch(
                   "com.vendor.editor.extra", identity: leftoverIdentity) == .related
               && UninstallerSupport.leftoverMatch(
                   "com.vendor.editor.helper.plist", identity: leftoverIdentity) == .exact
               && UninstallerSupport.leftoverMatch("Editorial", identity: leftoverIdentity) == .related
               && UninstallerSupport.leftoverMatch("Editor/Nested", identity: leftoverIdentity) == .none,
               "owned identifiers are exact, while prefixes and names stay optional without unsigned wrappers")
        let technicalIdentity = UninstallerSupport.technicalIdentity(leftoverIdentity)
        suite.expect(UninstallerSupport.leftoverMatch("Editor", identity: technicalIdentity) == .none
               && UninstallerSupport.leftoverMatch(
                   "com.vendor.editor.plist", identity: technicalIdentity) == .exact,
               "sensitive roots accept technical ownership and never a display name")
        suite.expect(UninstallerSupport.leftoverEntryMatches(
                   "Editor_2024-01-01-120000_Mac.plist",
                   identity: leftoverIdentity, crashReporter: true)
               && !UninstallerSupport.leftoverEntryMatches(
                   "Editor_2024-01-01-120000_Mac.plist",
                   identity: leftoverIdentity, crashReporter: false),
               "crash reports may use the app name as a prefix only in that folder")
        suite.expect(UninstallerSupport.ownerBundleID(for: "com.vendor.editor.helper.plist",
                                                identity: leftoverIdentity)
                == "com.vendor.editor.helper"
               && UninstallerSupport.ownerBundleID(for: "Editor", identity: leftoverIdentity)
                == "com.vendor.editor",
               "a helper identifier wins when it is in the name, otherwise the app identifier owns a name match")
        suite.expect(UninstallerSupport.normalizedToken("Example App 2") == "exampleapp2"
               && UninstallerSupport.nameWithoutTrailingVersion("Example App 2") == "Example App"
               && UninstallerSupport.nameWithoutTrailingVersion("Example App Nightly") == "Example App"
               && UninstallerSupport.leftoverMatch(
                   "Example App",
                   identity: UninstallerSupport.identity(bundleIDs: ["com.vendor.exampleapp"],
                                                         displayNames: ["Example App 2"])) == .related
               && UninstallerSupport.leftoverEntryMatches(
                   "ExampleApp2.plist",
                   identity: UninstallerSupport.identity(bundleIDs: ["com.vendor.exampleapp"],
                                                         displayNames: ["Example App 2"])),
               "spaces and trailing version numbers do not hide a leftover named after the app")
        let twoPartIdentity = UninstallerSupport.identity(
            primaryBundleID: "test.editor",
            bundleIDs: ["test.editor"],
            displayNames: ["Editor", "Editor.app"])
        suite.expect(twoPartIdentity.nameTokens.contains("editor")
               && twoPartIdentity.bundleIDs.contains("test.editor"),
               "two-part bundle identifiers yield both display name tokens and exact bundle IDs")
        suite.expect(UninstallerSupport.leftoverMatch("Editor", identity: twoPartIdentity) == .related
               && UninstallerSupport.leftoverMatch("editor", identity: twoPartIdentity) == .related
               && UninstallerSupport.leftoverMatch("test.editor.plist", identity: twoPartIdentity) == .exact
               && UninstallerSupport.leftoverMatch("test.editor", identity: twoPartIdentity) == .exact
               && UninstallerSupport.leftoverMatch("test.editor.helper", identity: twoPartIdentity) == .related
               && UninstallerSupport.leftoverMatch("Unrelated", identity: twoPartIdentity) == .none,
               "two-part bundle identifiers match exact and related leftovers correctly")
        suite.expect(UninstallerSupport.identity(primaryBundleID: "com.vendor.browser",
                                           bundleIDs: ["com.vendor.browser"],
                                           displayNames: ["Vendor Browser"]).nameTokens.contains("browser"),
               "the last identifier component is a token when it names the app")
        let browserIdentity = UninstallerSupport.identity(primaryBundleID: "com.vendor.browser",
                                                          bundleIDs: ["com.vendor.browser"],
                                                          displayNames: ["Vendor Browser"])
        let browserListings = [
            UninstallerSupport.DirListing(name: "Vendor", children: [
                UninstallerSupport.DirListing(name: "Browser", children: []),
                UninstallerSupport.DirListing(name: "Docs", children: []),
            ]),
            UninstallerSupport.DirListing(name: "SuiteApp", children: [
                UninstallerSupport.DirListing(name: "logs", children: []),
            ]),
            UninstallerSupport.DirListing(name: "com.vendor.browser", children: []),
        ]
        suite.expect(UninstallerSupport.leftoverHitRecords(
                   listings: browserListings,
                   identity: browserIdentity,
                   extraChildDepth: 1).map(\.path) == ["Vendor/Browser", "com.vendor.browser"],
               "a leftover nested under a vendor folder is found without taking the whole vendor folder")
        suite.expect(UninstallerSupport.leftoverHitRecords(
                   listings: browserListings,
                   identity: browserIdentity,
                   extraChildDepth: 0).map(\.path) == ["com.vendor.browser"],
               "vendor nesting is not searched when the folder is a leaf location")
        suite.expect(UninstallerSupport.leftoverHitRecords(
                   listings: [UninstallerSupport.DirListing(name: "Browser", children: [
                       UninstallerSupport.DirListing(name: "com.vendor.browser", children: [])
                   ])],
                   identity: browserIdentity,
                   extraChildDepth: 1).map(\.path) == ["Browser/com.vendor.browser"],
               "an exact child wins over a broader related parent folder")
        suite.expect(UninstallerSupport.leftoverHitRecords(
                   listings: [UninstallerSupport.DirListing(
                       name: "Unrelated.component", children: [],
                       bundleIdentifier: "com.vendor.browser")],
                   identity: browserIdentity,
                   extraChildDepth: 0).first?.confidence == .exact,
               "plugin bundle metadata finds a component whose filename does not identify the app")
        suite.expect(UninstallerSupport.leftoverHitRecords(
                   listings: [UninstallerSupport.DirListing(name: "Vendor", children: [
                       UninstallerSupport.DirListing(name: "Mid", children: [
                           UninstallerSupport.DirListing(name: "Editor", children: [])
                       ])
                   ])],
                   identity: leftoverIdentity,
                   extraChildDepth: 2).map(\.path) == ["Vendor/Mid/Editor"],
               "Application Support is searched two levels for vendor/mid/app nesting")
        let teamedIdentity = UninstallerSupport.identity(
            bundleIDs: ["com.vendor.editor"], displayNames: [],
            teamIDs: ["abcd123456"], groupIDs: ["group.com.vendor.editor"])
        suite.expect(UninstallerSupport.leftoverMatch("ABCD123456.com.other", identity: teamedIdentity) == .related
               && UninstallerSupport.leftoverMatch(
                   "ABCD123456.com.vendor.editor", identity: teamedIdentity) == .exact
               && UninstallerSupport.leftoverMatch(
                   "ZZZZ123456.com.vendor.editor", identity: teamedIdentity) == .none
               && UninstallerSupport.leftoverMatch("group.com.vendor.editor", identity: teamedIdentity) == .exact
               && UninstallerSupport.matchingGroupID(
                   "group.com.vendor.editor", identity: teamedIdentity) == "group.com.vendor.editor"
               && UninstallerSupport.containerMetadataMatches("com.vendor.editor",
                                                              identity: leftoverIdentity) == .exact,
               "team prefixes are related, app groups and container metadata keep the exact owner")
        let leftoverFolders = UninstallerSupport.searchFolders(
            home: URL(fileURLWithPath: "/Users/tester"), darwinCache: nil, darwinTemp: nil)
        suite.expect(leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/Library/Group Containers" && $0.kind == .containers
                   && $0.readsContainerMetadata && !$0.allowsNameMatches
                   && $0.requiresSignedGroup
               })
               && leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/Library/PreferencePanes" && $0.kind == .other
               })
               && leftoverFolders.contains(where: {
                   $0.url.path.hasSuffix("CrashReporter") && $0.crashReporter
               })
               && leftoverFolders.contains(where: { $0.url.path == "/private/var/db/receipts" })
               && leftoverFolders.contains(where: { $0.url.path.hasSuffix("/Automator") })
               && leftoverFolders.contains(where: { $0.url.path.hasSuffix("/Frameworks") })
               && leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/.config" && !$0.allowsNameMatches
               })
               && leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/Library/Preferences/ByHost"
                       && !$0.allowsNameMatches
               })
               && leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/Library/Caches/com.apple.nsurlsessiond/Downloads"
                       && !$0.allowsNameMatches
               })
               && !leftoverFolders.contains(where: { $0.url.path.contains("/Desktop") })
               && leftoverFolders.contains(where: {
                   $0.url.path == "/Users/tester/Library/Application Support" && $0.extraChildDepth == 2
               }),
               "leftover search covers Library support, plugins and receipts, not the Desktop")
        let spotlightQuery = UninstallerSupport.leftoverSpotlightExpression(identity: leftoverIdentity) ?? ""
        suite.expect(spotlightQuery.contains("com.vendor.editor")
               && spotlightQuery.contains("editor")
               && UninstallerSupport.leftoverSpotlightPathIsAllowed(
                    "/Users/tester/Library/Caches/Editor",
                    roots: [URL(fileURLWithPath: "/Users/tester/Library")])
               && !UninstallerSupport.leftoverSpotlightPathIsAllowed(
                    "/Users/tester/Desktop/Editor",
                    roots: [URL(fileURLWithPath: "/Users/tester/Library")]),
               "Spotlight leftovers stay inside Library-like roots")
        let spotlightGroupIdentity = UninstallerSupport.spotlightIdentity(
            for: "/Users/tester/Library/Group Containers/group.com.vendor.editor",
            identity: teamedIdentity)
        let spotlightLaunchIdentity = UninstallerSupport.spotlightIdentity(
            for: "/Users/tester/Library/LaunchAgents/Editor.plist",
            identity: teamedIdentity)
        suite.expect(spotlightGroupIdentity.bundleIDs.isEmpty
               && spotlightGroupIdentity.groupIDs == ["group.com.vendor.editor"]
               && spotlightLaunchIdentity.nameTokens.isEmpty,
               "Spotlight preserves signed-group and technical-only rules for sensitive roots")
        let safetyFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-uninstaller-\(UUID().uuidString)", isDirectory: true)
        let safetyRoot = safetyFixture.appendingPathComponent("root", isDirectory: true)
        let outsideRoot = safetyFixture.appendingPathComponent("outside", isDirectory: true)
        let safeFile = safetyRoot.appendingPathComponent("safe.plist")
        let replacementFile = safetyRoot.appendingPathComponent("replacement.plist")
        let outsideFile = outsideRoot.appendingPathComponent("foreign.plist")
        let link = safetyRoot.appendingPathComponent("link", isDirectory: true)
        try? FileManager.default.createDirectory(at: safetyRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: safeFile.path, contents: Data("old".utf8))
        _ = FileManager.default.createFile(atPath: replacementFile.path, contents: Data("new".utf8))
        _ = FileManager.default.createFile(atPath: outsideFile.path, contents: Data("foreign".utf8))
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideRoot)
        let originalFileIdentity = UninstallerSupport.fileIdentity(at: safeFile)
        let safePathWasAccepted = UninstallerSupport.removalPathIsSafe(safeFile, within: safetyRoot)
        let linkedPathWasRejected = !UninstallerSupport.removalPathIsSafe(
            link.appendingPathComponent("foreign.plist"), within: safetyRoot)
        try? FileManager.default.removeItem(at: safeFile)
        try? FileManager.default.moveItem(at: replacementFile, to: safeFile)
        suite.expect(safePathWasAccepted && linkedPathWasRejected
               && originalFileIdentity != nil
               && UninstallerSupport.fileIdentity(at: safeFile) != originalFileIdentity,
               "removal stays inside its scan root, rejects symlink escapes and detects path replacement")
        // A failed lookup is not necessarily absence, and links can remain
        // even after their destination has disappeared.
        let absentFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-absent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: absentFixture, withIntermediateDirectories: true)
        let presentChild = absentFixture.appendingPathComponent("StillHere.app")
        try? "bundle".write(to: presentChild, atomically: true, encoding: .utf8)
        suite.expect(!UninstallerSupport.isConfirmedAbsent(at: presentChild),
               "a path that still exists is not confirmed absent")
        try? FileManager.default.removeItem(at: presentChild)
        suite.expect(UninstallerSupport.isConfirmedAbsent(at: presentChild),
               "a missing child under a readable parent is confirmed absent")
        let danglingLink = absentFixture.appendingPathComponent("Dangling.app")
        let danglingMade = symlink("/tmp/brim-missing-target-\(UUID().uuidString)",
                                   danglingLink.path) == 0
        suite.expect(danglingMade
               && !UninstallerSupport.isConfirmedAbsent(at: danglingLink),
               "a dangling symlink still occupies an entry and is not confirmed absent")
        try? FileManager.default.removeItem(at: danglingLink)
        let nestedParent = absentFixture.appendingPathComponent("NestedParent", isDirectory: true)
        let nestedChild = nestedParent.appendingPathComponent("Gone.app")
        try? FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
        try? "x".write(to: nestedChild, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: nestedParent)
        suite.expect(UninstallerSupport.isConfirmedAbsent(at: nestedChild),
               "when the item and its parent folder are both gone, absence is confirmed")
        let inaccessibleParent = absentFixture.appendingPathComponent("Restricted", isDirectory: true)
        let inaccessibleChild = inaccessibleParent.appendingPathComponent("StillHere.app")
        try? FileManager.default.createDirectory(at: inaccessibleParent, withIntermediateDirectories: true)
        let restrictedCreated = FileManager.default.createFile(atPath: inaccessibleChild.path, contents: Data("x".utf8))
        suite.expect(restrictedCreated, "the permission fixture exists before access changes")
        if geteuid() != 0 {
            let accessRestricted = chmod(inaccessibleParent.path, 0) == 0
            suite.expect(accessRestricted && !UninstallerSupport.isConfirmedAbsent(at: inaccessibleChild),
                   "a file that becomes inaccessible after selection remains a failure")
            let missingInRestrictedParent = inaccessibleParent.appendingPathComponent("Absent.app")
            suite.expect(!UninstallerSupport.isConfirmedAbsent(at: missingInRestrictedParent),
                   "absence below an inaccessible parent is not assumed")
            suite.expect(chmod(inaccessibleParent.path, 0o700) == 0,
                   "the permission fixture restores access")
        }
        suite.expect(UninstallerSupport.fileIdentity(at: inaccessibleChild) != nil,
               "the inaccessible file remains present")
        let invalidChild = inaccessibleChild.appendingPathComponent("Child")
        suite.expect(!UninstallerSupport.isConfirmedAbsent(at: invalidChild),
               "a parent replaced by a regular file is not treated as a confirmed removal")
        let loop = absentFixture.appendingPathComponent("Loop")
        let loopCreated = symlink("Loop", loop.path) == 0
        suite.expect(loopCreated && !UninstallerSupport.isConfirmedAbsent(at: loop.appendingPathComponent("Child")),
               "a symbolic link loop is an error, not confirmed absence")
        try? FileManager.default.removeItem(at: inaccessibleChild)
        suite.expect(UninstallerSupport.isConfirmedAbsent(at: inaccessibleChild),
               "the previously inaccessible file is recognized as absent only after removal")
        try? FileManager.default.removeItem(at: absentFixture)
        try? FileManager.default.removeItem(at: safetyFixture)
        func sourceBody(of source: String, from opening: String, to closing: String) -> String {
            guard let start = source.range(of: opening),
                  let end = source.range(of: closing, range: start.upperBound..<source.endIndex)
            else { return "" }
            return String(source[start.upperBound..<end.lowerBound])
        }
        // Building the installed-apps oracle walks the application folders, and
        // the removal guard reads it under `.leftovers` alone — with leftover
        // rows unchecked by default, the common clean must not pay for that
        // walk. JunkCleaner is not part of this test binary, so pin the gate
        // and the premise that makes an empty oracle safe at their source.
        let junkCleanerSource = (try? String(
            contentsOfFile: "Sources/Brim/Services/Cleaner/JunkCleaner.swift",
            encoding: .utf8)) ?? ""
        let cleanSelectedBody = sourceBody(of: junkCleanerSource, from: "func cleanSelected(",
                                           to: "private static func mayRemove")
        suite.expect(cleanSelectedBody.contains("chosen.contains { $0.category == .leftovers }")
               && cleanSelectedBody.contains("? Self.installedBundleIDs() : []")
               && !cleanSelectedBody.contains("let installed = Self.installedBundleIDs()"),
               "a clean builds the installed-apps oracle only when a leftover row is selected")
        let mayRemoveBody = sourceBody(of: junkCleanerSource, from: "private static func mayRemove",
                                       to: "private static func trashViaFinder")
        let leftoverBranch = mayRemoveBody.range(of: "if item.category == .leftovers")
        suite.expect(mayRemoveBody.components(separatedBy: "installed: installed").count == 2,
               "the removal guard consults the installed-apps oracle exactly once")
        suite.expect(leftoverBranch.map { branch in
                   mayRemoveBody.range(of: "installed: installed",
                                       range: branch.upperBound..<mayRemoveBody.endIndex) != nil
               } == true,
               "the removal guard reads the installed-apps oracle inside its leftovers branch")
        // The known-application roster opens every installed app, and only the
        // shared-data claims read it. AppUninstaller is not part of this test
        // binary either, so pin the gate that keeps a removal that cannot claim
        // shared data from paying for the roster.
        let appUninstallerSource = (try? String(
            contentsOfFile: "Sources/Brim/Services/Uninstall/AppUninstaller.swift",
            encoding: .utf8)) ?? ""
        let removeSelectedBody = sourceBody(of: appUninstallerSource, from: "func removeSelected()",
                                            to: "func removeSelectedWithHomebrew(")
        suite.expect(removeSelectedBody.contains("guard canRemoveSelected, selectedHomebrewPackage == nil else { return }"),
               "ordinary removal enforces the tested verification gate and cannot bypass a managed package")
        suite.expect(removeSelectedBody.contains("let knownApplications = mayClaimSharedData"),
               "a removal builds the known-application roster only when it may claim shared data")
        let finishHomebrewBody = sourceBody(of: appUninstallerSource,
                                            from: "private func finishRemovalAfterHomebrew",
                                            to: "private static func trashViaFinder")
        suite.expect(!finishHomebrewBody.isEmpty,
               "the Homebrew follow-up removal source reads back for its shape check")
        // Package completion must preserve ownership of the remaining choices
        // while counting the app only after its removal is confirmed.
        let markedPackageRemoval = finishHomebrewBody.range(of: "homebrewRemovedApplication = true")
        let firstRemoveSelected = finishHomebrewBody.range(of: "removeSelected()")
        suite.expect(markedPackageRemoval != nil
                && firstRemoveSelected.map { markedPackageRemoval!.upperBound < $0.lowerBound } == true
                && finishHomebrewBody.contains("setInclude(false, for: app.id)")
                && finishHomebrewBody.contains("isConfirmedAbsent")
                && finishHomebrewBody.contains("homebrewRemovalSize = app.size"),
               "after package removal the flag is set before trash, and size is credited only after confirmed absence")
        suite.expect(removeSelectedBody.contains("try fm.trashItem(at: item.url, resultingItemURL: nil)")
                && removeSelectedBody.contains("isConfirmedAbsent")
                && removeSelectedBody.contains("stubborn.append(item)")
                && removeSelectedBody.contains("freed += item.size"),
               "a path is counted freed only when its absence is confirmed, not on a bare fileExists miss")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.editor.prefPane")
                == "com.vendor.editor",
               "preference panes map to their owning bundle identifier")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "im.riot.app.plist") == "im.riot.app"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.Service.plist") == "com.vendor.Service"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.Dictionary.savedState")
                == "com.vendor.Dictionary"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "io.app.plist") == "io.app",
               "only the entry's own extension is removed, not an identifier component spelled like one")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.editor.app") == "com.vendor.editor"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.editor.PLIST") == "com.vendor.editor",
               "a single payload extension still unwraps to its owner in any letter case")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "app-0.0.409") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "0.0.409") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "1.57.0") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.v2.editor")
                == "com.v2.editor",
               "version directories never become deletion ownership evidence")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "MCXTools.log") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "LKDC-setup.log") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "install.LOG") == nil,
               "a plain log file name is never read as an uninstalled app's identifier")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.editor.log")
                == "com.vendor.editor",
               "a log named after its app still unwraps to that app")
        let supportRoot = URL(fileURLWithPath: "/Users/tester/Library/Application Support")
        suite.expect(CleanerSupport.isDirectChild(
                   supportRoot.appendingPathComponent("com.vendor.editor"), of: supportRoot)
               && !CleanerSupport.isDirectChild(
                   supportRoot.appendingPathComponent("vendor/app-0.0.409"), of: supportRoot),
               "the general Cleaner accepts only direct children of each leftover root")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName:
               "com.vendor.editor.Helper.B787EFF9-B8E2-5296-96AF-DF9D3CD3AC4F.plist")
                == "com.vendor.editor.Helper"
               && CleanerSupport.bundleIDCandidate(fromEntryName:
               "com.vendor.B787EFF9-B8E2-5296-96AF-DF9D3CD3AC4F.editor") == nil
               && CleanerSupport.bundleIDCandidate(fromEntryName: "ABCD123456.com.vendor.editor")
                == "com.vendor.editor",
               "ByHost UUIDs and team prefixes unwrap to the owning identifier")
        suite.expect(CleanerSupport.hasSharedContainerWrapper("group.com.vendor.editor")
               && CleanerSupport.hasSharedContainerWrapper("ABCD123456.com.vendor.editor")
               && !CleanerSupport.hasSharedContainerWrapper("abcd123456.com.vendor.editor")
               && !CleanerSupport.hasSharedContainerWrapper("com.vendor.editor"),
               "the general Cleaner leaves shared-container wrappers to signed app-specific scans")
        let helperAppIdentity = UninstallerSupport.identity(
            primaryBundleID: "com.vendor.chat",
            bundleIDs: ["com.vendor.chat", "com.vendor.chat.helper.Renderer", "com.vendor.chat.helper.GPU"],
            displayNames: ["Chat App"])
        suite.expect(!helperAppIdentity.nameTokens.contains("renderer")
               && !helperAppIdentity.nameTokens.contains("gpu")
               && helperAppIdentity.nameTokens.contains("chatapp")
               && UninstallerSupport.leftoverMatch("renderer.log", identity: helperAppIdentity) == .none
               && !UninstallerSupport.leftoverSpotlightPathIsAllowed(
                    "/Users/tester/Library/Application Support/OtherApp/logs/sub/renderer.log",
                    roots: [URL(fileURLWithPath: "/Users/tester/Library/Application Support")]),
               "helper subprocess roles and deeply nested foreign logs are never claimed as leftovers")
        suite.expect(CleanerSupport.isProtectedBundleID("systemgroup.com.apple.icloud.searchpartyd.sharedsettings")
               && CleanerSupport.isProtectedBundleID("243LU875E5.groups.com.apple.podcasts")
               && CleanerSupport.isProtectedBundleID("developer.apple.wwdc")
               && CleanerSupport.isProtectedBundleID("is.workflow.my.app"),
               "system domains stay protected in every wrapping, team prefixes included")
        suite.expect(CleanerSupport.sharedInfrastructurePrefixes.allSatisfy {
                   CleanerSupport.isProtectedBundleID($0)
               },
               "embedded updaters and crash reporters can never be junk owners")
        suite.expect(CleanerSupport.isProtectedBundleID("io.sentry.Native")
               && CleanerSupport.isProtectedBundleID("ORG.SPARKLE-PROJECT.Sparkle")
               && CleanerSupport.isProtectedBundleID("com.google.Keystone.Agent"),
               "anything inside a shared infrastructure domain stays protected, in any letter case")
        suite.expect(!CleanerSupport.isProtectedBundleID("com.segmentfault.reader")
               && !CleanerSupport.isProtectedBundleID("com.amplitudestudios.Humankind")
               && !CleanerSupport.isProtectedBundleID("io.sentrybox.Mac")
               && !CleanerSupport.isProtectedBundleID("org.swiftbar.app")
               && UninstallerSupport.verifiedBundleID("com.amplitudestudios.Humankind")
                == "com.amplitudestudios.Humankind",
               "another vendor whose name merely starts like a shared domain is an ordinary app")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "systemgroup.com.apple.icloud.sharedsettings.plist")
               == "com.apple.icloud.sharedsettings",
               "systemgroup wrappers unwrap to the real owner")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName:
               "com.vendor.B787EFF9-B8E2-5296-96AF-DF9D3CD3AC4F.editor") == nil,
               "a UUID in the middle of a name stays unattributable")
        suite.expect(CleanerSupport.containsUUIDComponent("x.B787EFF9-B8E2-5296-96AF-DF9D3CD3AC4F")
               && !CleanerSupport.containsUUIDComponent("com.vendor.editor"),
               "the UUID detector matches dashed UUIDs and nothing else")
        suite.expect(CleanerSupport.sharesVendorNamespace(candidate: "com.vendor.backgroundtool",
                                                    withInstalled: ["com.vendor.editor"])
               && CleanerSupport.sharesVendorNamespace(candidate: "com.publisher.agent",
                                                       withInstalled: ["com.publisher.browser"]),
               "a vendor's updaters are owned while any app of that vendor is installed")
        suite.expect(!CleanerSupport.sharesVendorNamespace(candidate: "com.vendor.editor",
                                                     withInstalled: ["com.publisher.browser"]),
               "different vendors never own each other")
        suite.expect(!CleanerSupport.sharesVendorNamespace(candidate: "io.github.account.tool",
                                                     withInstalled: ["io.github.other.app"]),
               "code hosting namespaces are shared by unrelated developers and never match")
        suite.expect(CleanerPolicy.precheckCacheEntry("Homebrew")
               && CleanerPolicy.precheckCacheEntry("com.vendor.editor"),
               "download caches and third party app caches start checked")
        suite.expect(!CleanerPolicy.precheckCacheEntry("PlainVendorFolder")
               && !CleanerPolicy.precheckCacheEntry("com.apple.Music")
               && !CleanerPolicy.precheckCacheEntry("com.spotify.client")
               && !CleanerPolicy.precheckCacheEntry("ms-playwright"),
               "system, sensitive and unattributable caches start unchecked")
        suite.expect(CleanerPolicy.isExcludedCacheEntry("com.spotify.client")
               && CleanerPolicy.isExcludedCacheEntry("COM.SPOTIFY.CLIENT")
               && CleanerPolicy.isExcludedCacheEntry("com.spotify.client.helper"),
               "caches holding installed customizations are excluded even when all caches are selected")
        suite.expect(!CleanerPolicy.isExcludedCacheEntry("com.vendor.editor")
               && !CleanerPolicy.isExcludedCacheEntry("ms-playwright"),
               "ordinary and downloadable sensitive caches remain available for review")
        suite.expect(CleanerSupport.Category.deviceBackups.rawValue == 6
               && CleanerSupport.Category.screenshots.rawValue == 7
               && CleanerSupport.Category.allCases.count == 8,
               "device backups and screenshots joined the cleaner with stable category ids")
        suite.expect(!CleanerPolicy.precheckDeviceBackups,
               "device backups never start checked, they are the user's safety net")
        suite.expect(!CleanerPolicy.precheckScreenshots
               && registeredDefaults[DefaultsKey.cleanerScreenshotAgeDays] as? Int == 30
               && CleanerPolicy.sanitizedScreenshotAgeDays(-3) == 0,
               "forgotten screenshots start unchecked after a 30 day default")
        // CleanerScheduler and CleanerView are outside this test binary, so
        // pin escalation at the call sites: the unattended pass must never
        // reach Finder's administrator prompt, and no default lets a later
        // automatic caller inherit it.
        let compact = { (path: String) -> String in
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).joined()
        }
        let schedulerCode = compact("Sources/Brim/Services/Cleaner/CleanerScheduler.swift")
        let cleanerViewCode = compact("Sources/Brim/UI/Cleaner/CleanerView.swift")
        suite.expect(schedulerCode.components(separatedBy: "cleanSelected(").count == 2
               && schedulerCode.contains("cleanSelected(escalate:false)")
               && schedulerCode.contains("notifyIfWanted(freed:freed,failed:failed)"),
               "the scheduled clean never escalates and reports what it left in place")
        suite.expect(junkCleanerSource.contains("func cleanSelected(escalate: Bool) {")
               && cleanerViewCode.components(separatedBy: "cleanSelected(").count == 2
               && cleanerViewCode.contains("cleanSelected(escalate:true)"),
               "cleanSelected has no default escalation and the manual clean still asks")
        suite.expect(schedulerCode.contains("cleaner.scan(attended:false)")
               && cleanerViewCode.contains("cleaner.scan(attended:true)"),
               "only a scan someone started reads the screenshot folders")
        suite.expect(CleanerPolicy.developerJunkPaths.contains("/Library/Developer/Xcode/iOS DeviceSupport")
               && CleanerPolicy.developerJunkPaths.contains("/Library/Developer/Xcode/watchOS DeviceSupport"),
               "stale DeviceSupport symbol caches count as developer junk")
        suite.expect(CleanerSupport.looksLikeBundleID("com.vendor.editor")
               && CleanerSupport.looksLikeBundleID("com.foo.Bar-Helper_2")
               && CleanerSupport.looksLikeBundleID("test.editor")
               && CleanerSupport.looksLikeBundleID("editor.test")
               && CleanerSupport.looksLikeBundleID("com.foo"),
               "reverse DNS names and two-component bundle identifiers are recognized")
        suite.expect(!CleanerSupport.looksLikeBundleID("VendorFolder")
               && !CleanerSupport.looksLikeBundleID("Editor")
               && !CleanerSupport.looksLikeBundleID("com..foo")
               && !CleanerSupport.looksLikeBundleID(".com.foo")
               && !CleanerSupport.looksLikeBundleID("com.foo.")
               && !CleanerSupport.looksLikeBundleID("com.foo.bár"),
               "plain names, empty parts and odd characters never match by name")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "com.vendor.editor.plist") == "com.vendor.editor"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "test.editor.plist") == "test.editor"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "group.com.foo.bar") == "com.foo.bar"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "group.test.editor") == "test.editor"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "ABCD123456.test.editor") == "test.editor"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.foo.bar.savedState") == "com.foo.bar"
               && CleanerSupport.bundleIDCandidate(fromEntryName: "com.foo.bar.binarycookies") == "com.foo.bar",
               "entry names map to their owning bundle identifier")
        suite.expect(CleanerSupport.bundleIDCandidate(fromEntryName: "VendorFolder") == nil,
               "folders without a bundle shaped name are never candidates")
        suite.expect(CleanerSupport.isOwned(candidate: "com.vendor.editor.startuphelper",
                                      byInstalled: ["com.vendor.editor"]),
               "embedded helper identifiers are owned by their installed app")
        suite.expect(CleanerSupport.isOwned(candidate: "com.maker",
                                      byInstalled: ["com.maker.app"]),
               "a family prefix of an installed app counts as owned")
        suite.expect(!CleanerSupport.isOwned(candidate: "com.vendor.editor", byInstalled: ["com.publisher.browser"]),
               "identifiers with no installed relative are unowned")
        suite.expect(!CleanerSupport.isOwned(candidate: "com.makerapp.tool", byInstalled: ["com.maker.app"]),
               "prefix ownership requires a dot boundary, not a string prefix")
        suite.expect(CleanerSupport.isOwnedSupportDomain("Battle.net", byInstalled: ["net.battle.app"])
               && CleanerSupport.isOwnedSupportDomain("maker.com", byInstalled: ["com.maker"]),
               "a domain named support folder is owned by the installed app under its reverse")
        suite.expect(!CleanerSupport.isOwnedSupportDomain("battle.net", byInstalled: ["net.battlefield.app"])
               && !CleanerSupport.isOwnedSupportDomain("battle.net", byInstalled: ["com.battle.app"])
               && !CleanerSupport.isOwnedSupportDomain("github.io", byInstalled: ["io.github.someone.tool"])
               && !CleanerSupport.isOwnedSupportDomain("com.maker.app", byInstalled: ["app.maker.com"]),
               "reverse ownership needs a dot boundary, two parts and no hosting namespace")
        suite.expect(CleanerSupport.executablePaths(inLaunchPlist: [
                   "Program": "/Applications/Gone.app/Contents/MacOS/agent",
                   "ProgramArguments": ["/usr/local/bin/gone-tool", "--flag"],
                   "BundleProgram": "Contents/MacOS/relative",
               ]) == ["/Applications/Gone.app/Contents/MacOS/agent", "/usr/local/bin/gone-tool"],
               "launch plists yield their absolute executables and skip relative ones")
        let bareCommand = CleanerSupport.executablePaths(inLaunchPlist: [
                   "Program": "rsync", "ProgramArguments": ["sh", "-c", "rsync -a ~/a /Volumes/b"],
               ])
        suite.expect(bareCommand.isEmpty
               && !CleanerSupport.launchPlistIsRemovableOrphan(label: "local.backup", executables: bareCommand,
                                                               executableExists: { _ in false }),
               "an agent that runs a bare command from launchd's search path is never offered as an orphan")
        suite.expect(CleanerSupport.launchPlistIsRemovableOrphan(label: "com.vendor.editor.launchdaemon",
                                                           executables: ["/Applications/Gone.app/x"],
                                                           executableExists: { _ in false }),
               "a plist whose executables are all gone is a removable orphan")
        suite.expect(!CleanerSupport.launchPlistIsRemovableOrphan(label: "com.vendor.editor.launchdaemon",
                                                            executables: ["/bin/ls"],
                                                            executableExists: { _ in true }),
               "a plist with a living executable is never an orphan")
        suite.expect(!CleanerSupport.launchPlistIsRemovableOrphan(label: "com.apple.something",
                                                            executables: ["/gone"],
                                                            executableExists: { _ in false })
               && !CleanerSupport.launchPlistIsRemovableOrphan(label: nil,
                                                               executables: [],
                                                               executableExists: { _ in false }),
               "system agents and undecidable plists are never offered")
        suite.expect(registeredDefaults[DefaultsKey.panelCollapsedSections] == nil,
               "panel collapsed sections intentionally has no registered default")
        suite.expect(registeredDefaults[DefaultsKey.panelUtilityOrder] == nil,
               "panel utility order intentionally has no registered default")
        suite.expect(Defaults.sanitizedDefaultDuration(60) == 60, "valid default duration is preserved")
        suite.expect(Defaults.sanitizedDefaultDuration(999) == 0, "invalid default duration falls back to indefinite")
        suite.expect(Defaults.sanitizedBatteryLimit(15) == 15, "valid battery limit is preserved")
        suite.expect(Defaults.sanitizedBatteryLimit(100) == 10, "invalid battery limit falls back to default")
        suite.expect(Defaults.sanitizedClipboardHistoryLimit(1_000) == 1_000,
               "larger clipboard history limits are preserved")
        suite.expect(Defaults.sanitizedClipboardHistoryLimit(999) == 50,
               "unsupported clipboard history limits fall back to default")
        suite.expect(Defaults.sanitizedMonitorInterval(5) == 5, "valid monitor interval is preserved")
        suite.expect(Defaults.sanitizedMonitorInterval(7) == 2, "invalid monitor interval falls back to default")
        suite.expect(Defaults.sanitizedMenuBarLabelStyle("classic") == "classic", "valid label style is preserved")
        suite.expect(Defaults.sanitizedMenuBarLabelStyle("bad") == "compact", "invalid label style falls back to compact")
        suite.expect(Defaults.sanitizedMenuBarMemoryStyle("percent") == "percent", "percent memory style is preserved")
        suite.expect(Defaults.sanitizedMenuBarMemoryStyle("dot") == "dot", "valid memory style is preserved")
        suite.expect(Defaults.sanitizedMenuBarMemoryStyle("both") == "both", "combined memory style is preserved")
        suite.expect(Defaults.sanitizedMenuBarMemoryStyle("bad") == "percent", "invalid memory style falls back to percent")
        suite.expect(Defaults.sanitizedMenuBarMetricOrder("cpu,gpu,memory,network,battery,power")
               == ["cpu", "gpu", "memory", "network", "battery", "power",
                   "cpuTemperature", "gpuTemperature", "batteryTime", "batteryTemperature", "peripheralBattery", "diskUsage", "diskActivity", "connectedDevices", "fanSpeed"],
               "menu bar metric order appends temperature sensors without rewriting existing saved order")
        suite.expect(Defaults.sanitizedMenuBarMetricOrder("temperature,cpu,cpu,bad")
               == ["cpuTemperature", "gpuTemperature", "batteryTemperature",
                   "cpu", "gpu", "memory", "battery", "batteryTime", "peripheralBattery", "network", "diskUsage", "diskActivity", "connectedDevices", "power", "fanSpeed"],
               "menu bar metric order migrates the old generic temperature value")
        suite.expect(Defaults.sanitizedBundleIdentifierList([" com.example.One ", "", "com.example.One", "com.example.Two"])
               == ["com.example.One", "com.example.Two"],
               "bundle id lists are trimmed and deduplicated")
        suite.expect(Defaults.sanitizedPanelItemOrder("uninstaller,homebrew,homebrew,bad",
                                                defaultOrder: ["homebrew", "media", "uninstaller", "cleanURL", "cleaning"])
               == ["uninstaller", "homebrew", "media", "cleanURL", "cleaning"],
               "panel item order keeps saved valid items first and appends defaults")
    }
}

extension AppManagementFeatureTests {
    static func systemApplicationChecks(_ suite: TestSuite) {
        suite.expect(InstalledApps.isSystemApplication(
                    at: URL(fileURLWithPath: "/System/Applications/SystemUtility.app"))
                && InstalledApps.isSystemApplication(
                    at: URL(fileURLWithPath: "/Library/Apple/SystemUtility.app"))
                && !InstalledApps.isSystemApplication(
                    at: URL(fileURLWithPath: "/Applications/UserUtility.app")),
               "app controls never offer system apps to the uninstaller")
    }
}

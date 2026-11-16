// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Production selection and removal transitions run with controlled scan
/// callbacks. Files are disposable bundles; no installed apps or Trash are used.
enum UninstallerFlowTests {
    struct Leftover: Equatable {
        let id = UUID()
        let url: URL
        var category: Category = .app
        var size: Int64 = 0
        var confidence: UninstallerSupport.LeftoverMatch = .exact
        var include = true
    }
    struct Target {
        let name: String
        let bundleID: String?
        let url: URL
        let icon: NSImage
    }
    final class Observation {
        var canceled = false
        func cancel() { canceled = true }
    }
    enum Queue {
        enum QoS { case userInitiated, utility }
        static var pending: [() -> Void] = []
        static var main: Queue.Type { Self.self }
        static func global(qos: QoS) -> Queue.Type { Self.self }
        static func async(execute: @escaping () -> Void) { pending.append(execute) }
        static func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { pending.append(execute) }
        static func concurrentPerform(iterations: Int, execute: (Int) -> Void) {
            for index in 0..<iterations { execute(index) }
        }
        static func drain() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }
    struct Package: Equatable {
        let id: String
        var displayName: String { id }
    }
    final class Brew {
        struct Status {
            enum Action { case uninstall }
            enum Result { case running, succeeded }
            let action: Action
            let package: Package?
            let result: Result
            var isActive: Bool { result == .running }
        }
        static let shared = Brew()
        var checkedURL: URL?
        var callback: ((Result<Package?, HomebrewOwnershipError>) -> Void)?
        @Published var operationStatus: Status?
        var operation: Status?
        var uninstalled: [String] = []
        var canStart = true
        func packageManagingApplication(at url: URL, completion: @escaping (Result<Package?, HomebrewOwnershipError>) -> Void) {
            checkedURL = url
            callback = completion
        }
        func uninstall(_ package: Package, fromUninstaller: Bool) {
            guard canStart, fromUninstaller else { return }
            uninstalled.append(package.id)
            operation = Status(action: .uninstall, package: package, result: .running)
            operationStatus = operation
        }
    }
    enum HUD {
        static var messages: [String] = []
        static func show(icon: String, message: String) { messages.append(message) }
    }
    class UninstallerState {
        typealias DispatchQueue = Queue
        typealias HomebrewManager = Brew
        typealias HomebrewPackage = Package
        typealias QuickToolHUD = HUD
        typealias L10n = Localization
        var phase: Phase = .empty
        var target: Target?
        var refusal: UninstallerSupport.RefusedApp?
        var homebrewPackage: Package?
        var homebrewCheckFailed = false
        var homebrewRemovalSize: Int64 = 0
        var homebrewRemovedApplication = false
        var homebrewRemovalObservation: AnyCancellable?
        var targetSelection: UninstallerSupport.Selection?
        var targetTrashMove: UninstallerSupport.TrashMove?
        var allowedRemovalPaths = Set<String>()
        var items: [Leftover] = []
        var scanCancellation: UninstallerSupport.ScanCancellation?
        static func allBundleIDs(in url: URL, fm: FileManager) -> Set<String> { [] }
        static func knownApplicationURLs(candidateBundleIDs: Set<String>) -> [URL] { [] }
        static func applicationBundleIdentifiers(in urls: [URL]) -> [(url: URL, bundleID: String)] { [] }
        static func exclusiveOwnedBundleIDs(in url: URL, candidates: Set<String>, knownApplicationIDs: [(url: URL, bundleID: String)]) -> Set<String> { [] }
        static func trashMoveIsCurrent(_ move: UninstallerSupport.TrashMove) -> Bool { false }
        static func signingIdentity(in url: URL, requireValidSignature: Bool) -> (teamIDs: Set<String>, groupIDs: Set<String>) { ([], []) }
        static func exclusiveGroupIDs(_ ids: Set<String>, selectedURL: URL, knownApplications: [URL]) -> Set<String> { [] }
        static var collects = 0
        static func collect(appURL: URL, primaryBundleID: String, exclusiveBundleIDs: Set<String>, teamIDs: Set<String>, exclusiveGroupIDs: Set<String>, cancellation: UninstallerSupport.ScanCancellation) -> [Leftover] {
            collects += 1
            return [Leftover(url: appURL)]
        }
        func removeSelected() { if !items.isEmpty { phase = .removing } }
        var completedRemovals: [String] = []
        func finishRemovalAfterHomebrew(package: Package) { completedRemovals.append(package.id) }
    }
    final class Localization {
        static let shared = Localization()
        let s = Text()
        struct Text {
            let uninstallerRemoving = "Removing"
            let uninstallerSelectionUnavailable = "Unavailable"
            let uninstallerConfirmationExpired = "Expired"
        }
    }
    static func run(_ suite: TestSuite) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("uninstaller-flow-\(UUID())")
        defer {
            Queue.pending = []
            Brew.shared.callback = nil
            Brew.shared.operationStatus = nil
            Uninstaller.shared.phase = .empty
            Uninstaller.shared.reset()
            try? fm.removeItem(at: root)
        }
        do {
            func makeApp(_ name: String) throws -> URL {
                let url = root.appendingPathComponent(name + ".app", isDirectory: true)
                let contents = url.appendingPathComponent("Contents", isDirectory: true)
                try fm.createDirectory(at: contents, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: [
                    "CFBundleIdentifier": "org.example.fixture.\(name)",
                    "CFBundlePackageType": "APPL", "CFBundleName": name,
                ], format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
                return url
            }
            let a = try makeApp("First")
            let b = try makeApp("Second")
            let uninstaller = Uninstaller.shared
            suite.expect(uninstaller.select(appURL: a) && uninstaller.phase == .scanning,
                         "an accepted selection starts its scan")
            Queue.drain()
            let lateScan = Brew.shared.callback
            uninstaller.reset()
            lateScan?(.success(nil))
            suite.expect(uninstaller.phase == .empty && uninstaller.target == nil,
                         "canceling while scanning prevents its late result from returning")
            UninstallerState.collects = 0
            _ = uninstaller.select(appURL: a)
            uninstaller.reset()
            Queue.drain()
            suite.expect(UninstallerState.collects == 0 && uninstaller.phase == .empty,
                         "canceling a scan stops its background work instead of letting it run to the end")
            _ = uninstaller.select(appURL: a)
            Queue.drain()
            let canceledScan = Brew.shared.callback
            uninstaller.reset()
            _ = uninstaller.select(appURL: a)
            canceledScan?(.success(nil))
            suite.expect(uninstaller.phase == .scanning && uninstaller.items.isEmpty,
                         "a canceled scan cannot deliver into a new scan of the same app")
            uninstaller.reset()
            Queue.pending = []
            _ = uninstaller.select(appURL: a)
            Queue.drain()
            Brew.shared.callback?(.success(nil))
            suite.expect(uninstaller.phase == .results && uninstaller.items.count == 1,
                         "current scan delivers the accepted app")
            suite.expect(uninstaller.canRemoveSelected, "a verified unmanaged app can be removed")
            // Homebrew is asked when the scan starts, so it may answer first.
            _ = uninstaller.select(appURL: a)
            Brew.shared.callback?(.success(nil))
            suite.expect(uninstaller.phase == .scanning && uninstaller.items.isEmpty,
                         "a Homebrew answer alone does not end the scan")
            Queue.drain()
            suite.expect(uninstaller.phase == .results && uninstaller.items.count == 1,
                         "the scan finishing after Homebrew answered delivers the results")
            _ = uninstaller.select(appURL: a)
            Queue.drain()
            Brew.shared.callback?(.failure(.unavailable))
            suite.expect(uninstaller.phase == .results && uninstaller.homebrewCheckFailed
                         && !uninstaller.canRemoveSelected && uninstaller.homebrewRemovalConfirmation == nil,
                         "failed Homebrew detection preserves review but authorizes neither removal route")
            let failedScan = Brew.shared.callback
            uninstaller.retryHomebrewCheck()
            suite.expect(uninstaller.phase == .scanning && !uninstaller.canRemoveSelected,
                         "retry checks the same app again before enabling removal")
            Queue.drain()
            Brew.shared.callback?(.success(Package(id: "recovered")))
            failedScan?(.failure(.unavailable))
            suite.expect(uninstaller.canRemoveSelected && !uninstaller.homebrewCheckFailed
                         && uninstaller.homebrewRemovalConfirmation?.package.id == "recovered",
                         "a successful retry restores package confirmation and ignores late replies from the old scan")
            uninstaller.phase = .removing
            let originalItems = uninstaller.items
            suite.expect(!uninstaller.select(appURL: b)
                         && uninstaller.target?.url == a && uninstaller.items == originalItems,
                         "choosing another app during a removal preserves the active operation")
            uninstaller.reset()
            suite.expect(uninstaller.phase == .removing && uninstaller.target?.url == a,
                         "other surfaces cannot reset an active plain removal")
            uninstaller.setInclude(false, for: originalItems[0].id)
            suite.expect(uninstaller.items == originalItems, "an active removal keeps its captured selection")
            uninstaller.phase = .results
            uninstaller.homebrewPackage = Package(id: "first")
            Brew.shared.operationStatus = .init(action: .uninstall, package: Package(id: "first"), result: .running)
            let observation = Observation()
            uninstaller.homebrewRemovalObservation = AnyCancellable(observation.cancel)
            _ = uninstaller.select(appURL: b)
            uninstaller.reset()
            suite.expect(!observation.canceled && uninstaller.target?.url == a && uninstaller.homebrewPackage?.id == "first",
                         "a new selection or reset cannot discard package cleanup in progress")
            Brew.shared.operationStatus = nil
            uninstaller.phase = .done(freed: 1, failed: [])
            uninstaller.reset()
            suite.expect(uninstaller.phase == .empty && observation.canceled,
                         "a finished operation can be dismissed normally")
            suite.expect(!uninstaller.select(appURL: root.appendingPathComponent("Missing.app"))
                         && uninstaller.target == nil && uninstaller.refusal != nil,
                         "a vanished application is refused without opening an empty review")
            let link = root.appendingPathComponent("Link.app")
            try fm.createSymbolicLink(at: link, withDestinationURL: b)
            suite.expect(!uninstaller.select(appURL: link), "a symlink cannot be accepted as a removable bundle")
            suite.expect(uninstaller.refusal == UninstallerSupport.RefusedApp(name: "Link", refusal: .link)
                         && uninstaller.phase == .empty && uninstaller.target == nil,
                         "a refused selection keeps the empty state and records why")
            uninstaller.reset()
            suite.expect(uninstaller.refusal == nil, "a reset drops the last refusal")
            suite.expect(!uninstaller.select(appURL: link) && uninstaller.refusal != nil,
                         "the symlink is refused again before another app is chosen")
            _ = uninstaller.select(appURL: b)
            suite.expect(uninstaller.refusal == nil, "an accepted selection clears the last refusal")
            uninstaller.reset()
            _ = uninstaller.select(appURL: a)
            Queue.drain()
            Brew.shared.callback?(.success(Package(id: "first")))
            if let confirmation = uninstaller.homebrewRemovalConfirmation, let app = uninstaller.items.first {
                uninstaller.setInclude(false, for: app.id)
                uninstaller.removeSelectedWithHomebrew(confirmation: confirmation)
                uninstaller.setInclude(true, for: app.id)
                uninstaller.homebrewPackage = Package(id: "second")
                uninstaller.removeSelectedWithHomebrew(confirmation: confirmation)
                uninstaller.homebrewPackage = Package(id: "first")
                let shownTarget = uninstaller.target
                uninstaller.target = Target(name: "Second", bundleID: nil, url: b, icon: NSImage())
                uninstaller.removeSelectedWithHomebrew(confirmation: confirmation)
                uninstaller.target = shownTarget
                suite.expect(Brew.shared.uninstalled.isEmpty && HUD.messages.count == 3,
                             "a Homebrew confirmation for other rows, another package or another app runs nothing, found \(Brew.shared.uninstalled)")
                let previous = Brew.Status(action: .uninstall, package: confirmation.package, result: .succeeded)
                Brew.shared.operationStatus = previous
                Brew.shared.canStart = false
                uninstaller.removeSelectedWithHomebrew(confirmation: confirmation)
                suite.expect(uninstaller.homebrewRemovalObservation == nil && uninstaller.completedRemovals.isEmpty
                             && Brew.shared.operationStatus?.result == .succeeded,
                             "an unavailable command preserves the previous run without acting on its completion")
                Brew.shared.canStart = true
                uninstaller.removeSelectedWithHomebrew(confirmation: confirmation)
                suite.expect(Brew.shared.uninstalled == ["first"] && uninstaller.completedRemovals.isEmpty,
                             "confirming the same package again starts a fresh removal")
                Brew.shared.operation = nil
                Brew.shared.operationStatus = previous
                suite.expect(uninstaller.completedRemovals == ["first"] && uninstaller.homebrewRemovalObservation == nil,
                             "only the new completion finishes the removal")
            } else {
                suite.expect(false, "a Homebrew-managed app offers a package confirmation")
            }
            suite.expect(Defaults.registeredDefaults[DefaultsKey.uninstallerWatchesTrash] as? Bool == false,
                         "the Trash cleanup offer starts off")
        } catch {
            suite.expect(false, "uninstaller fixture failed: \(error)")
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin

/// Offers to review an app moved from an Applications folder to the local Trash.
/// Builds on the approach first proposed by ilim-cell in #3755.
///
/// Three kqueue folder watches (/Applications, ~/Applications when it exists,
/// and the Trash) fire only when a top-level entry is added, removed or
/// renamed, never for writes inside an app, so an Xcode or Chrome update
/// costs a listing per top-level change instead of a flood of file events.
/// Each event lists the three folders (UninstallerSupport.TrashListing) and
/// compares the listing with the one before, on a utility queue; a move is
/// offered on the main thread.
final class TrashAppWatcher {
    static let shared = TrashAppWatcher()

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "brim.uninstaller.trash-watch", qos: .utility)
    /// Main thread.
    private var running = false
    // Confined to `queue`.
    private var sources: [DispatchSourceFileSystemObject] = []
    private var listing: UninstallerSupport.TrashListing?

    private init() {}

    func syncWithPreferences() {
        precondition(Thread.isMainThread)
        let wanted = AppFeature.uninstaller.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.uninstallerWatchesTrash)
            && Permissions.shared.fullDiskAccess
        wanted ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let folders = UninstallerSupport.TrashListing.folders(home: home)
            for folder in folders.applications + [folders.trash] {
                let descriptor = open(folder.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                       eventMask: [.write, .link, .rename, .delete],
                                                                       queue: queue)
                source.setEventHandler { [weak self] in self?.changed() }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                sources.append(source)
            }
            listing = UninstallerSupport.TrashListing.read(home: home)
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        queue.async { [self] in
            for source in sources { source.cancel() }
            sources = []
            listing = nil
        }
    }

    /// On `queue`: one listing step.
    private func changed() {
        guard let previous = listing else { return }
        let current = UninstallerSupport.TrashListing.read(home: home)
        listing = current
        for move in UninstallerSupport.TrashListing.moves(from: previous, to: current, home: home) {
            DispatchQueue.main.async { [self] in offer(move) }
        }
    }

    private func offer(_ move: UninstallerSupport.TrashMove) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              AppUninstaller.shared.canOfferTrashCleanup(of: move) else { return }
        appDelegate()?.openUninstaller(for: move.selection.url, trashMove: move)
    }
}

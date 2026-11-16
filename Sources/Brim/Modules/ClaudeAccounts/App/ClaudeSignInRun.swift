// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// One `claude auth login` that Brim runs as its own child (ClaudeSignIn).
/// The child gets stdin from /dev/null; its output is kept, bounded, only for
/// the error text. brim-claude, its BROWSER, writes the sign-in link to
/// `urlFile`; a DispatchSource on that folder says when (no polling), and
/// the link is read, handed over and the file deleted at once. Foundation
/// only, so the tests run it with stand-ins for `claude` and the browser.
final class ClaudeSignInRun: @unchecked Sendable {
    struct Exit: Equatable {
        var status: Int32
        /// Claude Code's output, for the error text only.
        var output: String
        var timedOut: Bool
        /// Ended by cancel(); the child is gone when this arrives.
        var cancelled: Bool
    }

    enum Event: Equatable {
        case link(URL)
        /// brim-claude refused the link Claude Code gave (ClaudeHelper.browser).
        case refused
        case finished(Exit)
    }

    let urlFile: String
    private let refusedFile: String
    private let directory: String
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: TimeInterval
    /// Called on the run's own queue.
    private let deliver: (Event) -> Void
    private let cancellation = BoundedProcessCancellation()
    private let childQueue = DispatchQueue(label: "brim.claude-signin.child", qos: .userInitiated)
    private let watchQueue = DispatchQueue(label: "brim.claude-signin.watch", qos: .userInitiated)
    // Confined to watchQueue.
    private var source: DispatchSourceFileSystemObject?
    private var linkSeen = false
    private var refusalSeen = false
    private var cancelled = false

    init(executable: String, arguments: [String], environment: [String: String], urlFile: String,
         timeout: TimeInterval = ClaudeSignIn.timeout, deliver: @escaping (Event) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.urlFile = urlFile
        refusedFile = ClaudeSignIn.refusedFile(forURLFile: urlFile)
        directory = (urlFile as NSString).deletingLastPathComponent
        self.timeout = timeout
        self.deliver = deliver
    }

    /// Makes the folder (mode 0700), watches it, then starts the child.
    func start() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0, ClaudeSignIn.isPrivateDirectory(directory) else {
            throw ClaudeFileError.posix("make \(directory) private", errno)
        }
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { throw ClaudeFileError.posix("watch \(directory)", errno) }
        watchQueue.sync {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                                   queue: watchQueue)
            source.setEventHandler { [weak self] in self?.look() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        let executable = executable, arguments = arguments, environment = environment, timeout = timeout
        let cancellation = cancellation
        childQueue.async { [self] in
            let result = BoundedProcessRunner.run(executable, arguments, timeout: timeout, maxOutputBytes: 16 << 10,
                                                  environment: environment, cancellation: cancellation,
                                                  input: FileHandle.nullDevice)
            watchQueue.async { [self] in
                // A link written just before the exit still counts.
                look()
                stopWatching()
                let exit = Exit(status: result.status, output: String(decoding: result.output, as: UTF8.self),
                                timedOut: result.timedOut, cancelled: cancelled)
                deliver(.finished(exit))
            }
        }
    }

    /// Ends Brim's own child (and nothing else) and deletes the link file.
    /// `.finished` still arrives, marked cancelled, once the child is gone.
    func cancel() {
        watchQueue.async { [self] in
            cancelled = true
            removeFiles()
        }
        cancellation.cancel()
    }

    // MARK: On watchQueue

    private func look() {
        guard !cancelled else { return }
        if !linkSeen, let data = ClaudeFileIO.read(urlFile, limit: ClaudeSignIn.linkLimit) {
            unlink(urlFile)
            if let link = ClaudeSignIn.acceptedLink(String(decoding: data, as: UTF8.self)) {
                linkSeen = true
                deliver(.link(link))
            } else {
                refusalSeen = true
                deliver(.refused)
            }
        }
        if !refusalSeen, ClaudeFileIO.isRegularFile(refusedFile) {
            unlink(refusedFile)
            refusalSeen = true
            deliver(.refused)
        }
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        removeFiles()
    }

    private func removeFiles() {
        unlink(urlFile)
        unlink(refusedFile)
    }
}

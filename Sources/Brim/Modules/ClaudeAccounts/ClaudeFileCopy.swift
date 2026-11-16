// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// What copying one folder into another does, file by file.
struct ClaudeFolderMerge: Equatable {
    struct Copy: Equatable {
        enum Kind: Equatable {
            /// The destination has no such file.
            case new
            /// The destination holds a strict byte-prefix of the source: an
            /// older copy of the same append-only transcript.
            case replace
            /// The destination holds different bytes: kept, and the source
            /// goes beside it under <stem>.from-<tag>.<ext>.
            case keptBeside
        }

        var from: String
        var to: String
        var kind: Kind
        /// For a replace: both files as planned. The replace happens only
        /// while both still are (ClaudeSync.place).
        var planned: (from: ClaudeSync.Stamp, to: ClaudeSync.Stamp)?

        static func == (a: Copy, b: Copy) -> Bool {
            a.from == b.from && a.to == b.to && a.kind == b.kind && a.planned?.from == b.planned?.from && a.planned?.to == b.planned?.to
        }
    }

    var copies: [Copy] = []
    /// Files the destination already has, byte for byte.
    var identical = 0

    var isEmpty: Bool { copies.isEmpty }
    func count(_ kind: Copy.Kind) -> Int { copies.filter { $0.kind == kind }.count }
}

/// Merges one Claude Code config folder into another (tidy up, backups),
/// never over a file: an identical file is skipped, an older copy of the
/// same append-only transcript (a strict byte-prefix) is replaced, and a
/// differing file is kept, with the new one beside it; and the byte
/// comparisons ClaudeSync uses. Copies are APFS clones (no extra disk);
/// copyfile(3) with COPYFILE_CLONE clones when the volume can and copies
/// the bytes when it cannot (another volume), a runtime capability check of
/// the system call itself.
enum ClaudeFileCopy {
    // MARK: Plan

    /// What copying `source` (a folder) into `destination` would do.
    static func plan(from source: String, into destination: String, tag: String) -> ClaudeFolderMerge {
        var merge = ClaudeFolderMerge()
        var planned = Set<String>()
        walk(source, into: destination, tag: tag, merge: &merge, planned: &planned)
        return merge
    }

    private static func walk(_ source: String, into destination: String, tag: String,
                             merge: inout ClaudeFolderMerge, planned: inout Set<String>) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []).sorted()
        // A copy held out of view while its conversation is open elsewhere
        // (ClaudeSync's check-out) is a prefix of that open copy: not merged.
        for name in names where name != ".DS_Store" && name != ClaudeSync.checkoutFolder {
            let from = source + "/" + name
            let to = destination + "/" + name
            if ClaudeFileIO.isDirectory(from) {
                if !ClaudeFileIO.exists(to) || ClaudeFileIO.isDirectory(to, followingLinks: true) {
                    walk(from, into: to, tag: tag, merge: &merge, planned: &planned)
                } else {
                    // A file where the source has a folder: the folder goes
                    // whole beside it.
                    walk(from, into: free(name, in: destination, tag: tag, planned: planned), tag: tag,
                         merge: &merge, planned: &planned)
                }
                continue
            }
            file(from, to: to, tag: tag, merge: &merge, planned: &planned)
        }
    }

    private static func file(_ from: String, to: String, tag: String,
                             merge: inout ClaudeFolderMerge, planned: inout Set<String>) {
        if !ClaudeFileIO.exists(to) && !planned.contains(to) {
            merge.copies.append(.init(from: from, to: to, kind: .new))
            planned.insert(to)
        } else if identical(from, to) {
            merge.identical += 1
        } else if !planned.contains(to), let fromStamp = ClaudeSync.stamp(from), let toStamp = ClaudeSync.stamp(to),
                  isStrictPrefix(to, of: from) {
            merge.copies.append(.init(from: from, to: to, kind: .replace, planned: (fromStamp, toStamp)))
            planned.insert(to)
        } else {
            let name = (to as NSString).lastPathComponent
            let folder = (to as NSString).deletingLastPathComponent
            var number = 1
            while true {
                let candidate = folder + "/" + keptName(name, tag: tag, number: number)
                if !ClaudeFileIO.exists(candidate) && !planned.contains(candidate) {
                    merge.copies.append(.init(from: from, to: candidate, kind: .keptBeside))
                    planned.insert(candidate)
                    return
                }
                if identical(from, candidate) {
                    merge.identical += 1
                    return
                }
                number += 1
            }
        }
    }

    private static func free(_ name: String, in destination: String, tag: String, planned: Set<String>) -> String {
        var number = 1
        while true {
            let candidate = destination + "/" + keptName(name, tag: tag, number: number)
            if !ClaudeFileIO.exists(candidate) && !planned.contains(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: Apply

    /// Carries a plan out, copy by copy; stops at the first failure. An
    /// older copy is replaced the way ClaudeSync replaces one (a clone beside
    /// it, renamed over it), and only while it and its source are as planned.
    static func apply(_ merge: ClaudeFolderMerge) throws {
        for copy in merge.copies {
            switch copy.kind {
            case .new, .keptBeside: try clone(copy.from, to: copy.to)
            case .replace:
                guard let planned = copy.planned else { throw ClaudeFileError.posix("replace \(copy.to)", EINVAL) }
                try ClaudeSync.place(copy.from, stamp: planned.from, at: copy.to, expect: .file(planned.to))
            }
        }
    }

    /// Clones one file (or link) with its dates and mode, never over
    /// anything; missing parent folders are made with mode 0700.
    static func clone(_ from: String, to: String) throws {
        let parent = (to as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // COPYFILE_CLONE implies EXCL, NOFOLLOW_SRC and the file's metadata.
        guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw ClaudeFileError.posix("copy \(from)", errno)
        }
    }

    // MARK: Comparing

    /// Two regular files with the same bytes, or two links with the same
    /// destination. Read in pieces: transcripts reach hundreds of MB.
    static func identical(_ a: String, _ b: String) -> Bool {
        if ClaudeFileIO.isSymlink(a) || ClaudeFileIO.isSymlink(b) {
            return ClaudeFileIO.isSymlink(a) && ClaudeFileIO.isSymlink(b)
                && ClaudeFileIO.linkDestination(a) == ClaudeFileIO.linkDestination(b)
        }
        guard let sizeA = size(a), let sizeB = size(b), sizeA == sizeB else { return false }
        return samePrefix(a, b, length: sizeA)
    }

    /// `shorter` is a regular file whose bytes begin `longer` and are fewer.
    static func isStrictPrefix(_ shorter: String, of longer: String) -> Bool {
        guard let small = size(shorter), let large = size(longer), small < large else { return false }
        return samePrefix(shorter, longer, length: small)
    }

    /// The size of a regular file (not a link); nil otherwise.
    static func size(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    private static func samePrefix(_ a: String, _ b: String, length: Int64) -> Bool {
        guard let first = FileHandle(forReadingAtPath: a), let second = FileHandle(forReadingAtPath: b) else { return false }
        defer {
            try? first.close()
            try? second.close()
        }
        var left = length
        while left > 0 {
            let piece = Int(min(left, 1 << 20))
            let x = (try? first.read(upToCount: piece)) ?? Data()
            let y = (try? second.read(upToCount: piece)) ?? Data()
            if x.count != piece || x != y { return false }
            left -= Int64(piece)
        }
        return true
    }

    // MARK: Names

    /// "claude-stern" for "/Users/x/.claude-stern": the tag a differing file
    /// from that folder is kept under.
    static func folderTag(_ folder: String) -> String {
        var name = (folder as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let tag = String(name.map { allowed.contains($0) ? $0 : "-" })
        return tag.isEmpty ? "account" : tag
    }

    /// "<stem>.from-<tag>.<ext>", then "<stem>.from-<tag>.2.<ext>", …
    static func keptName(_ name: String, tag: String, number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ".from-" + tag + (number > 1 ? ".\(number)" : "")
        return ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
    }

    /// The merge in words: "copy 2 file(s); replace 1 older copy; keep 1
    /// differing file(s) beside the existing ones; skip 3 identical file(s)".
    static func describe(_ merge: ClaudeFolderMerge, done: Bool = false) -> String {
        var parts: [String] = []
        let fresh = merge.count(.new)
        let replaced = merge.count(.replace)
        let kept = merge.copies.filter { $0.kind == .keptBeside }
        if fresh > 0 { parts.append((done ? "copied" : "copy") + " \(fresh) file(s)") }
        if replaced > 0 { parts.append((done ? "replaced" : "replace") + " \(replaced) older cop\(replaced == 1 ? "y" : "ies")") }
        if !kept.isEmpty {
            let names = kept.prefix(3).map { ($0.to as NSString).lastPathComponent }.joined(separator: ", ")
            parts.append("\(done ? "kept" : "keep") \(kept.count) differing file(s) beside the existing ones (\(names)\(kept.count > 3 ? ", …" : ""))")
        }
        if merge.identical > 0 { parts.append((done ? "skipped" : "skip") + " \(merge.identical) identical file(s)") }
        return parts.isEmpty ? "nothing to copy" : parts.joined(separator: "; ")
    }
}

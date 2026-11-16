// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

// The runaway brake (T-52). The decision of 2026-11-15: "end it
// automatically and log it somewhere in brim". On 2026-11-15 a GreenUp
// XCTest runner went from start to a 561 GB footprint in 150 s; Brim's
// memory-tight episode opened about 40 s before macOS began killing apps for
// low swap, and Brim only reported it. Overnight before that a
// chrome-headless-shell reached 93 GB the same way.

extension DefaultsKey {
    /// When the newest runaway the person dismissed from the Memory panel
    /// was ended (seconds since 1970): the line stays until then.
    static let memoryRunawaySeen = "brimMemoryRunawaySeen"
}

/// A runaway is one process of the person's own whose own footprint is more
/// than half of physical memory while a memory-tight episode is open. Only a
/// process Brim already offers End for qualifies (`MemoryHolder.canEnd`):
/// never another user's or root's, never Brim, launchd, WindowServer,
/// loginwindow or any system-protected process, never an app's or the
/// system's executable, an agent, an IDE, a terminal, a shell, a
/// self-daemonizing tool or anything on the Keep list.
enum MemoryRunawayBrake {
    /// More than half of physical memory (hw.memsize / 2): 64 GB of 128 GB.
    static func threshold(physicalMemory: UInt64) -> UInt64 { physicalMemory / 2 }

    /// The process to end now, nil when there is none: the biggest holder
    /// over the threshold that qualifies and is not `excluded` (being ended
    /// already, or signalled by the brake before). Nothing outside an episode.
    static func target(_ holders: [MemoryHolder], threshold: UInt64, memoryTight: Bool,
                       excluded: Set<ProcessIdentity>) -> MemoryHolder? {
        guard memoryTight, threshold > 0 else { return nil }
        return holders.filter { holder in
            guard !holder.isSystem, holder.canEnd, let bytes = holder.memory.footprint else { return false }
            return bytes > threshold && !excluded.contains(holder.identity)
        }
        .max { ($0.memory.footprint ?? 0, $1.identity.pid) < ($1.memory.footprint ?? 0, $0.identity.pid) }
    }

    /// The brake's read between scans, from one table read of own
    /// processes' footprints (with arguments and folders, for the labels and
    /// the protections): the biggest own footprint, and every own process
    /// over the threshold as a holder, judged like a "Biggest now" row.
    static func read(_ records: [ProcessRecord], context: MemoryContext, threshold: UInt64) -> MemoryRunawayRead {
        let own = records.filter { !$0.restricted && $0.uid == context.uid && $0.pid != context.ownPID }
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let over = own.filter { ($0.footprint ?? 0) > threshold }.map { record in
            MemoryHolders.holder(record, byPID: byPID, context: context, history: MemoryHolderHistory(),
                                 thresholds: MemoryHolderThresholds())
        }
        return MemoryRunawayRead(largestOwn: own.compactMap(\.footprint).max(), over: over)
    }

    /// Right before each signal (SIGTERM, and SIGKILL five seconds later):
    /// the same process (pid and kernel start time), still the person's own
    /// and one Brim may end, and still over the threshold. Any read that
    /// fails is a no.
    static func stillRunaway(_ identity: ProcessIdentity, fresh: ProcessRecord?, threshold: UInt64,
                             context: MemoryContext) -> Bool {
        guard let fresh, fresh.identity == identity, !fresh.restricted, fresh.uid == context.uid,
              let bytes = fresh.footprint, bytes > threshold else { return false }
        return MemoryHolders.canEnd(fresh, context: context)
    }

    /// One process read fresh for `stillRunaway`, with its arguments and
    /// folder (an agent or a protected tool is told by them).
    static func freshRecord(pid: pid_t) -> ProcessRecord? {
        guard var record = ProcessTable.record(pid: pid) else { return nil }
        guard !record.restricted else { return record }
        record.arguments = ProcessTable.arguments(pid: pid)
        record.workingDirectory = ProcessTable.workingDirectory(pid: pid)
        return record
    }
}

/// What one brake read found.
struct MemoryRunawayRead: Equatable {
    /// The biggest footprint among the person's own processes.
    var largestOwn: UInt64?
    /// Own processes over the threshold, as holders.
    var over: [MemoryHolder]
}

/// How soon the brake reads again while an episode is open. The interval is
/// short because a runaway is fast: the GreenUp runner grew about 3.6 GB/s,
/// from 20 GB to past the 64 GB threshold in about 12 s, and the episode
/// opened 40 s before macOS started killing apps. 3 s while an own process
/// holds a quarter of the threshold (16 GB) or more, 5 s otherwise; none
/// outside an episode or while the Mac sleeps. A locked screen keeps
/// reading: both runaways came while nobody was at the Mac.
enum MemoryRunawayWatch {
    static let near: TimeInterval = 3
    static let far: TimeInterval = 5

    static func next(after reading: Date, memoryTight: Bool, asleep: Bool, largestOwn: UInt64?,
                     threshold: UInt64) -> Date? {
        guard memoryTight, !asleep, threshold > 0 else { return nil }
        return reading.addingTimeInterval((largestOwn ?? 0) >= threshold / 4 ? near : far)
    }
}

/// The line at the top of the Memory panel: the newest runaway Brim ended
/// that the person has not dismissed.
enum MemoryRunawayNotice {
    static func unseen(_ log: MemoryActivityLog, seenThrough: Date?) -> MemoryActivityEntry? {
        log.entries.first { entry in
            entry.kind == .runawayEnded && (seenThrough.map { entry.date > $0 } ?? true)
        }
    }

    static func seenThrough(_ defaults: UserDefaults) -> Date? {
        (defaults.object(forKey: DefaultsKey.memoryRunawaySeen) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func markSeen(_ entry: MemoryActivityEntry, in defaults: UserDefaults) {
        defaults.set(entry.date.timeIntervalSince1970, forKey: DefaultsKey.memoryRunawaySeen)
    }
}

extension MemoryActivityEntry {
    /// The brake's entry: the holder's name and project, its command line,
    /// its footprint read right before SIGTERM and the threshold it crossed.
    static func runaway(_ holder: MemoryHolder, bytes: UInt64, threshold: UInt64, command: Command?,
                        at date: Date) -> MemoryActivityEntry {
        var entry = MemoryActivityEntry(date: date, kind: .runawayEnded,
                                        title: MemoryFormat.title(name: holder.name, count: 1, project: holder.project),
                                        reasons: [], commands: command.map { [$0] } ?? [])
        entry.runawayBytes = bytes
        entry.runawayThreshold = threshold
        return entry
    }

    /// A memory alert the system did not show (notifications off or never
    /// allowed), kept so a missed alert can be read later.
    static func alertNotShown(title: String, body: String, text: MemoryStrings, at date: Date) -> MemoryActivityEntry {
        var entry = MemoryActivityEntry(date: date, kind: .alertNotShown,
                                        title: String(format: text.alertNotShownFormat, title, body), reasons: [])
        entry.outcome = .nothingToDo
        return entry
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// A process as the kernel names it: its pid and the start time the kernel
/// keeps for it, in microseconds since 1970. A pid alone is reused, so every
/// destructive action carries both and checks both again right before it acts.
struct ProcessIdentity: Hashable, Codable, Sendable {
    let pid: pid_t
    let startedAt: UInt64
}

/// What a process's sockets are doing, read from libproc (never lsof).
struct ProcessSockets: Equatable, Sendable {
    /// TCP ports in LISTEN.
    var listeningTCP: [UInt16] = []
    /// UDP sockets bound to a local port with no peer: a UDP server.
    var boundUDP: [UInt16] = []
    /// Unix-domain sockets that accept connections (listen() was called), by
    /// path ("" for an unnamed one): a local server, such as a tmux, emacs
    /// or broker daemon serving its clients over a socket file.
    var listeningLocal: [String] = []
    /// TCP connections in ESTABLISHED, plus UDP sockets with a peer.
    var established = 0

    var isListening: Bool { !listeningTCP.isEmpty || !boundUDP.isEmpty || !listeningLocal.isEmpty }
    /// Every listening port, once each, lowest first.
    var ports: [UInt16] { Array(Set(listeningTCP + boundUDP)).sorted() }

    mutating func add(_ other: ProcessSockets) {
        listeningTCP += other.listeningTCP
        boundUDP += other.boundUDP
        listeningLocal += other.listeningLocal
        established += other.established
    }
}

/// What Brim knows about a process's memory. "Could not read" is never 0.
enum ProcessMemory: Equatable, Sendable {
    /// The person's own process: ri_phys_footprint.
    case footprint(UInt64)
    /// Another user's process alone in its resource coalition: the
    /// coalition's footprint is its own.
    case systemFootprint(UInt64)
    /// A resource coalition shared by several processes: its total, carried
    /// by its lowest pid only, never one process's own size.
    case coalitionTotal(UInt64, members: Int)
    case unknown

    /// This process's own footprint, when known exactly.
    var footprint: UInt64? {
        switch self {
        case .footprint(let bytes), .systemFootprint(let bytes): return bytes
        case .coalitionTotal, .unknown: return nil
        }
    }

    /// What the row carries: its own footprint or its group's total.
    var bytes: UInt64? {
        switch self {
        case .footprint(let bytes), .systemFootprint(let bytes), .coalitionTotal(let bytes, _): return bytes
        case .unknown: return nil
        }
    }
}

/// One row of the process table. Every number comes from libproc; arguments,
/// working directory and sockets are read only when asked, and arguments and
/// the working directory only for the person's own processes.
///
/// Another user's process (root's daemons, WindowServer) is a `restricted`
/// row: the kernel gives a caller that is not root only its short record
/// (parent, group, owner, flags, name) and its path, and refuses its
/// terminal, footprint and CPU time. Its footprint and CPU read as unknown,
/// never 0. With `.systemMemory` the table also reads its start time from
/// `kinfo_proc` and its memory from its resource coalition. Such a row still
/// has no identity to act on: `ProcessTable.startTime(pid:)` reads bsdinfo
/// only and stays nil for it, so no destructive path can match it.
struct ProcessRecord: Equatable, Sendable {
    var pid: pid_t
    var ppid: pid_t
    var pgid: pid_t
    var uid: uid_t
    /// pbi_flags (PROC_FLAG_*).
    var flags: UInt32
    /// The controlling terminal's device (e_tdev); `ProcessRecord.noTerminal`
    /// when there is none.
    var terminal: UInt32
    /// Kernel start time, microseconds since 1970: the identity half a pid
    /// lacks. The same number KillProcessService checks before a signal.
    /// For a restricted row, 0 unless `.systemMemory` read it from kinfo_proc.
    var startedAt: UInt64
    /// The short executable name the kernel keeps (pbi_name, else pbi_comm).
    var name: String
    /// The executable's full path, "" when libproc will not say.
    var path: String
    /// What Activity Monitor's Memory column shows, never RSS; `.unknown`
    /// when it could not be read.
    var memory: ProcessMemory
    /// User plus system CPU time since the process started, in seconds; nil
    /// when the kernel refused the read.
    var cpuTime: TimeInterval?
    /// User plus system CPU time of the children it has reaped
    /// (ri_child_user_time + ri_child_system_time), in seconds: the work a
    /// shell loop or a supervisor does in short-lived children, which its
    /// own `cpuTime` never shows. Nil when unreadable.
    var reapedChildrenCPUTime: TimeInterval? = 0
    var arguments: [String]? = nil
    var workingDirectory: String? = nil
    var sockets: ProcessSockets? = nil
    /// Only the kernel's short record could be read (another user's
    /// process): no terminal, footprint or CPU time of its own.
    var restricted = false

    /// NODEV, (dev_t)-1, as e_tdev carries it.
    static let noTerminal = UInt32.max
    /// PROC_FLAG_CONTROLT, sys/proc_info.h.
    static let controllingTerminalFlag: UInt32 = 0x80

    var identity: ProcessIdentity { ProcessIdentity(pid: pid, startedAt: startedAt) }

    /// This process's own footprint in bytes, nil when unknown.
    var footprint: UInt64? { memory.footprint }

    /// No controlling terminal at all: no tty device and the flag clear.
    var hasNoTerminal: Bool { terminal == Self.noTerminal && flags & Self.controllingTerminalFlag == 0 }

    /// The executable's file name: the last path component, else the kernel's name.
    var executableName: String {
        path.isEmpty ? name : (path as NSString).lastPathComponent
    }

    /// The CPU the process and the children it reaped have used: what the
    /// Memory module's idle test measures. Nil when either is unreadable.
    var totalCPUTime: TimeInterval? {
        guard let cpuTime, let reapedChildrenCPUTime else { return nil }
        return cpuTime + reapedChildrenCPUTime
    }

    /// The paths the protection rules read: the executable's path, or, when
    /// libproc will not give it (a binary replaced while it runs), argv[0]
    /// when that is a path. Only ever used to protect more, never less.
    var protectionPaths: [String] {
        guard path.isEmpty else { return [path] }
        guard let first = arguments?.first, first.hasPrefix("/") else { return [] }
        return [first]
    }

    /// When the process started, from its kernel start time.
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt) / 1_000_000) }
}

/// The one process enumerator: every feature that lists processes (the memory
/// breakdown, Kill Process, Brim's Memory module) reads this table instead of
/// running `ps`, `top` or `lsof`. One pass is proc_listallpids, then for each
/// pid proc_pidinfo(PROC_PIDTBSDINFO) (parent, group, owner, terminal, flags,
/// start time), proc_pid_rusage(RUSAGE_INFO_V4) (footprint, CPU time in mach
/// ticks, converted with mach_timebase_info) and proc_pidpath. The kernel
/// gives PROC_PIDTBSDINFO and the rusage only for the caller's own processes
/// (or to root); every other process is listed from PROC_PIDT_SHORTBSDINFO,
/// which it gives for all, as a `restricted` row. `.systemMemory` adds more
/// per-pid reads to that one pass (never a second enumerator): each pid's
/// resource coalition (PROC_PIDCOALITIONINFO), each coalition's usage
/// (coalition_info_resource_usage, which the kernel gives without root) and
/// restricted rows' start times from kinfo_proc.
enum ProcessTable {
    struct Options: OptionSet, Sendable {
        let rawValue: Int
        /// argv from KERN_PROCARGS2, own processes only.
        static let arguments = Options(rawValue: 1)
        /// The current directory, own processes only.
        static let workingDirectory = Options(rawValue: 2)
        /// TCP and UDP sockets (PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO).
        static let sockets = Options(rawValue: 4)
        /// Other users' memory from their resource coalitions, verified
        /// against own processes first, plus their kinfo_proc start times.
        static let systemMemory = Options(rawValue: 8)
    }

    /// Every process the kernel lists right now. A process that ends between
    /// the listing and its own read is left out.
    static func snapshot(options: Options = [], ownUID: uid_t = getuid()) -> [ProcessRecord] {
        let timebase = Self.timebase
        var records: [ProcessRecord] = []
        let all = pids()
        records.reserveCapacity(all.count)
        // One argument buffer for the whole pass, never zero-filled: the
        // kernel says how many bytes it wrote and only those are parsed.
        // (A fresh zeroed kern.argmax buffer per pid was about 800 MB of
        // allocation per scan.)
        let argumentBuffer = options.contains(.arguments)
            ? UnsafeMutableRawBufferPointer.allocate(byteCount: argumentBufferSize, alignment: 1) : nil
        defer { argumentBuffer?.deallocate() }
        for pid in all {
            guard var record = record(pid: pid, timebase: timebase) else { continue }
            if record.uid == ownUID {
                if let argumentBuffer { record.arguments = arguments(pid: pid, buffer: argumentBuffer) }
                if options.contains(.workingDirectory) { record.workingDirectory = workingDirectory(pid: pid) }
            }
            if options.contains(.sockets) { record.sockets = sockets(pid: pid) }
            if options.contains(.systemMemory), record.restricted, let started = kernelStartTime(pid: pid) {
                record.startedAt = started
            }
            records.append(record)
        }
        if options.contains(.systemMemory) { applySystemMemory(&records) }
        return records
    }

    /// Every pid the kernel lists, pid 0 left out.
    static func pids() -> [pid_t] {
        // The count can grow between the sizing call and the listing; the
        // margin covers that, and a full buffer is asked again larger.
        var capacity = max(64, Int(proc_listallpids(nil, 0))) + 64
        for _ in 0..<3 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_listallpids(bytes.baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { return [] }
            if Int(count) < capacity {
                return buffer.prefix(Int(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    /// One process's row, or nil when it is gone or unreadable.
    static func record(pid: pid_t) -> ProcessRecord? {
        record(pid: pid, timebase: timebase)
    }

    /// The kernel start time of `pid` (microseconds since 1970), nil when the
    /// pid is gone. The identity every destructive path compares. It reads
    /// bsdinfo only, which the kernel refuses for other users' processes, so
    /// a root process can never match.
    static func startTime(pid: pid_t) -> UInt64? {
        bsdInfo(pid).map { $0.pbi_start_tvsec &* 1_000_000 &+ $0.pbi_start_tvusec }
    }

    /// Whether `identity` still names the same live process.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        startTime(pid: identity.pid) == identity.startedAt
    }

    /// Cumulative user + system CPU nanoseconds per pid: the light pass the
    /// CPU breakdown samples as deltas (no bsdinfo, path or arguments).
    static func cpuNanoseconds() -> [pid_t: UInt64] {
        guard let timebase = Self.timebase else { return [:] }
        var result: [pid_t: UInt64] = [:]
        let all = pids()
        result.reserveCapacity(all.count)
        for pid in all {
            guard let usage = rusage(pid) else { continue }
            let total = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
            guard !total.overflow,
                  let nanoseconds = nanoseconds(ticks: total.partialValue, timebase: timebase) else { continue }
            result[pid] = nanoseconds
        }
        return result
    }

    /// The physical footprint of one process in bytes, nil when gone.
    static func footprint(pid: pid_t) -> UInt64? {
        rusage(pid).map(\.ri_phys_footprint)
    }

    // MARK: Arguments

    /// argv as the process was started (KERN_PROCARGS2), nil when unreadable;
    /// the kernel gives it only for the caller's own processes.
    static func arguments(pid: pid_t) -> [String]? {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: argumentBufferSize, alignment: 1)
        defer { buffer.deallocate() }
        return arguments(pid: pid, buffer: buffer)
    }

    /// argv into a buffer the caller reuses across pids.
    static func arguments(pid: pid_t, buffer: UnsafeMutableRawBufferPointer) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
        return parseArguments(buffer: UnsafeRawBufferPointer(buffer), size: size)
    }

    /// The first `size` bytes of a reused buffer, as KERN_PROCARGS2 wrote
    /// them; whatever an earlier pid left past them is never read.
    static func parseArguments(buffer: UnsafeRawBufferPointer, size: Int) -> [String]? {
        parseProcessArguments(UnsafeRawBufferPointer(rebasing: buffer[0..<min(max(0, size), buffer.count)]))
    }

    /// Reads a KERN_PROCARGS2 buffer: argc (a 32-bit int), the executable
    /// path, NUL padding, then argc NUL-terminated arguments (the environment
    /// that follows is never read).
    static func parseProcessArguments<Bytes: Collection>(_ bytes: Bytes) -> [String]?
    where Bytes.Element == UInt8 {
        let data = Array(bytes)
        guard data.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc >= 0, argc < 65_536 else { return nil }
        var index = 4
        // The executable path, then the NULs that pad it.
        while index < data.count, data[index] != 0 { index += 1 }
        while index < data.count, data[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < data.count {
            let start = index
            while index < data.count, data[index] != 0 { index += 1 }
            arguments.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    // MARK: Working directory

    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: Sockets

    /// The process's TCP, UDP and listening Unix-domain sockets, nil when its
    /// descriptors cannot be read (another user's process, or gone).
    /// proc_pidinfo reports a refused or failed read as 0 with errno set, not
    /// as -1, so 0 counts as "no descriptors" only while errno stays clear.
    static func sockets(pid: pid_t) -> ProcessSockets? {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 || (needed == 0 && errno == 0) else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        errno = 0
        let used = descriptors.withUnsafeMutableBytes { bytes in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard used > 0 || (used == 0 && errno == 0) else { return nil }
        return collectSockets(descriptors: Array(descriptors.prefix(Int(used) / stride))) { descriptor in
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            errno = 0
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                return (nil, errno == 0 ? EIO : errno)
            }
            return (info, 0)
        }
    }

    /// The sockets among a descriptor list, read one by one with `read`. A
    /// descriptor closed between the listing and its read (EBADF) is
    /// skipped; any other failed read makes the whole answer unknown (nil),
    /// never "no socket", so a refused read can't pass for a quiet process.
    static func collectSockets(descriptors: [proc_fdinfo],
                               read: (Int32) -> (info: socket_fdinfo?, errno: Int32)) -> ProcessSockets? {
        var result = ProcessSockets()
        let socketType = UInt32(PROX_FDTYPE_SOCKET)
        for descriptor in descriptors where descriptor.proc_fdtype == socketType {
            let reading = read(descriptor.proc_fd)
            guard let info = reading.info else {
                if reading.errno == EBADF { continue }
                return nil
            }
            let socket = info.psi
            if Int(socket.soi_kind) == Int(SOCKINFO_UN) {
                // SO_ACCEPTCONN: listen() was called, so it serves clients.
                // A connected pair (a pipe between two processes) is not.
                guard Int32(socket.soi_options) & SO_ACCEPTCONN != 0 else { continue }
                let path = withUnsafeBytes(of: socket.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                result.listeningLocal.append(path)
            } else if Int(socket.soi_kind) == Int(SOCKINFO_TCP) {
                let tcp = socket.soi_proto.pri_tcp
                let port = Self.port(tcp.tcpsi_ini.insi_lport)
                if tcp.tcpsi_state == TSI_S_LISTEN {
                    result.listeningTCP.append(port)
                } else if tcp.tcpsi_state == TSI_S_ESTABLISHED {
                    result.established += 1
                }
            } else if Int(socket.soi_kind) == Int(SOCKINFO_IN), socket.soi_protocol == IPPROTO_UDP {
                let udp = socket.soi_proto.pri_in
                if udp.insi_fport != 0 {
                    result.established += 1
                } else if udp.insi_lport != 0 {
                    result.boundUDP.append(Self.port(udp.insi_lport))
                }
            }
        }
        return result
    }

    // MARK: Other users' memory (resource coalitions)

    /// One resource coalition's usage, as coalition_info_resource_usage
    /// fills `struct coalition_resource_usage`.
    struct CoalitionUsage: Equatable, Sendable {
        var tasksStarted: UInt64
        var tasksExited: UInt64
        /// phys_footprint: footprint, compressed and swapped pages included.
        var footprint: UInt64
        /// Tasks alive in it now (the kernel's started minus exited).
        var liveTasks: UInt64 { tasksStarted >= tasksExited ? tasksStarted - tasksExited : 0 }
    }

    /// A restricted row's memory from its coalition's reading. A coalition
    /// footprint counts as one process's only when that process is alone in
    /// it (one live task, one member seen); otherwise it is a group total,
    /// carried by one member, the others unknown. Unverified or unread is
    /// unknown, never 0.
    static func systemMemory(coalitionBytes: UInt64?, liveTasks: UInt64?, membersSeen: Int,
                             carriesTotal: Bool, verified: Bool) -> ProcessMemory {
        guard verified, let bytes = coalitionBytes, bytes > 0 else { return .unknown }
        if liveTasks == 1, membersSeen == 1 { return .systemFootprint(bytes) }
        guard carriesTotal else { return .unknown }
        return .coalitionTotal(bytes, members: max(Int(clamping: liveTasks ?? 0), membersSeen))
    }

    /// Whether the coalition footprint means what Brim reads it as, checked
    /// on coalitions whose members are all the person's own, readable, and
    /// all seen (`coalition`: its phys_footprint, `ownSum`: the members'
    /// ri_phys_footprint, read right around it). A struct size can't
    /// validate a field's meaning; this can. A sample matches within
    /// max(1 MiB, 2%). True: at least 3 match and at most one in five is off.
    /// False: at least 3 are off and at most one in five matches (a wrong
    /// field is off nearly everywhere). Nil: too few samples, or mixed, so
    /// the next snapshot asks again. Review fix, T-42: one mismatch used to
    /// reject the read for the life of the process, and an ordinary
    /// allocation between two reads was enough to make one.
    static func coalitionReadVerified(_ samples: [(coalition: UInt64, ownSum: UInt64)]) -> Bool? {
        var matches = 0
        var mismatches = 0
        for sample in samples {
            if withinTolerance(sample.coalition, sample.ownSum) { matches += 1 } else { mismatches += 1 }
        }
        if matches >= 3, matches >= 4 * mismatches { return true }
        if mismatches >= 3, mismatches >= 4 * matches { return false }
        return nil
    }

    /// Two footprints that agree: within max(1 MiB, 2%) of the larger.
    static func withinTolerance(_ first: UInt64, _ second: UInt64) -> Bool {
        let difference = first > second ? first - second : second - first
        return difference <= max(UInt64(1 << 20), max(first, second) / 50)
    }

    /// PROC_PIDCOALITIONINFO (sys/proc_info.h; not in the SDK's Swift
    /// overlay): `struct proc_pidcoalitioninfo { uint64_t coalition_id[2];
    /// uint64_t reserved1, reserved2, reserved3; }`, 40 bytes, the
    /// resource coalition at index 0. The kernel gives it for every pid.
    private static let coalitionInfoFlavor: Int32 = 20
    private static let coalitionInfoSize: Int32 = 40

    static func resourceCoalition(pid: pid_t) -> UInt64? {
        var ids = [UInt64](repeating: 0, count: 5)
        let read = ids.withUnsafeMutableBytes { bytes in
            proc_pidinfo(pid, coalitionInfoFlavor, 0, bytes.baseAddress, coalitionInfoSize)
        }
        guard read == coalitionInfoSize, ids[0] != 0 else { return nil }
        return ids[0]
    }

    /// coalition_info_resource_usage is exported by libsystem_kernel but not
    /// declared in the SDK, so it is looked up once, as ResponsibleProcess
    /// looks up its private symbol. Missing: every system row stays unknown.
    private typealias CoalitionUsageFunction = @convention(c) (UInt64, UnsafeMutableRawPointer?, Int) -> Int32
    private static let coalitionUsageFunction: CoalitionUsageFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                                 "coalition_info_resource_usage") else { return nil }
        return unsafeBitCast(symbol, to: CoalitionUsageFunction.self)
    }()

    /// One coalition's usage: a zeroed 1024-byte buffer (larger than any
    /// `struct coalition_resource_usage` so far), tasks_started at offset
    /// 0, tasks_exited at 8, phys_footprint at 320.
    static func coalitionUsage(_ coalition: UInt64) -> CoalitionUsage? {
        guard let function = coalitionUsageFunction else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let status = buffer.withUnsafeMutableBytes { bytes in function(coalition, bytes.baseAddress, bytes.count) }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            CoalitionUsage(tasksStarted: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                           tasksExited: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                           footprint: raw.loadUnaligned(fromByteOffset: 320, as: UInt64.self))
        }
    }

    /// The verification's verdict, kept for the life of the process once
    /// it is true or false; nil retries on the next snapshot.
    private static let coalitionVerdictLock = NSLock()
    private static var coalitionVerdict: Bool?

    /// Whether this OS's coalition reads have been verified (nil: not yet).
    static var coalitionReadsVerified: Bool? {
        coalitionVerdictLock.lock()
        defer { coalitionVerdictLock.unlock() }
        return coalitionVerdict
    }

    /// The most own coalitions one verification compares.
    private static let maximumVerificationSamples = 32

    private static func applySystemMemory(_ records: inout [ProcessRecord]) {
        guard coalitionUsageFunction != nil else { return }
        let known = coalitionReadsVerified
        let verdict = assignSystemMemory(&records, verdict: known, coalition: resourceCoalition(pid:),
                                         usage: coalitionUsage, footprint: footprint(pid:))
        guard known == nil, let verdict else { return }
        coalitionVerdictLock.lock()
        coalitionVerdict = verdict
        coalitionVerdictLock.unlock()
    }

    /// Sets restricted rows' memory from their resource coalitions, first
    /// verifying the read on own coalitions when no verdict is known yet.
    /// Returns the verdict it used or reached (nil: still undecided, and
    /// every restricted row left unknown).
    /// `footprint` reads one process's footprint now. The verification
    /// compares each coalition with its members read right before and right
    /// after it, not with the table's footprints: those were read earlier in
    /// a walk over every process, and an app allocating in between made a
    /// mismatch that rejected the read. A sample whose members moved more
    /// than the tolerance between the two reads says nothing and is dropped.
    static func assignSystemMemory(_ records: inout [ProcessRecord], verdict known: Bool?,
                                   coalition: (pid_t) -> UInt64?, usage: (UInt64) -> CoalitionUsage?,
                                   footprint: (pid_t) -> UInt64?) -> Bool? {
        var members: [UInt64: [Int]] = [:]
        for index in records.indices {
            guard let id = coalition(records[index].pid) else { continue }
            members[id, default: []].append(index)
        }
        var verdict = known
        if verdict == nil {
            var samples: [(coalition: UInt64, ownSum: UInt64)] = []
            func sum(_ pids: [pid_t]) -> UInt64? {
                let read = pids.compactMap(footprint)
                return read.count == pids.count ? read.reduce(0, +) : nil
            }
            for (id, indices) in members.sorted(by: { $0.key < $1.key }) where samples.count < maximumVerificationSamples {
                guard indices.allSatisfy({ !records[$0].restricted && records[$0].footprint != nil }) else { continue }
                let pids = indices.map { records[$0].pid }
                guard let before = sum(pids), let reading = usage(id), let after = sum(pids),
                      reading.liveTasks == UInt64(indices.count), withinTolerance(before, after) else { continue }
                samples.append((reading.footprint, before / 2 + after / 2))
            }
            verdict = coalitionReadVerified(samples)
        }
        guard verdict == true else { return verdict }
        for (id, indices) in members where indices.contains(where: { records[$0].restricted }) {
            // Mixed with the person's own processes: their footprints are
            // already counted, so the restricted rows stay unknown.
            guard indices.allSatisfy({ records[$0].restricted }) else { continue }
            let reading = usage(id)
            let carrier = indices.min { records[$0].pid < records[$1].pid }
            for index in indices {
                records[index].memory = systemMemory(coalitionBytes: reading?.footprint, liveTasks: reading?.liveTasks,
                                                     membersSeen: indices.count, carriesTotal: index == carrier,
                                                     verified: true)
            }
        }
        return verdict
    }

    /// A process's kernel start time from kinfo_proc (kp_proc.p_starttime),
    /// which the kernel gives for every pid, root's included. Only ever a
    /// label (growth is keyed by pid + start time); never an identity to act on.
    static func kernelStartTime(pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0 else { return nil }
        return UInt64(start.tv_sec) &* 1_000_000 &+ UInt64(start.tv_usec)
    }

    // MARK: Internals

    private static func record(pid: pid_t, timebase: mach_timebase_info_data_t?) -> ProcessRecord? {
        guard let info = bsdInfo(pid) else { return restrictedRecord(pid: pid) }
        let usage = rusage(pid)
        // A refused or failed usage read is unknown, never 0: a busy group
        // read as 0 CPU would look idle.
        var cpu: TimeInterval?
        var children: TimeInterval?
        if let usage, let timebase {
            cpu = seconds(usage.ri_user_time, usage.ri_system_time, timebase: timebase)
            children = seconds(usage.ri_child_user_time, usage.ri_child_system_time, timebase: timebase)
        }
        let shortName = cString(info.pbi_name).isEmpty ? cString(info.pbi_comm) : cString(info.pbi_name)
        return ProcessRecord(pid: pid,
                             ppid: pid_t(bitPattern: info.pbi_ppid),
                             pgid: pid_t(bitPattern: info.pbi_pgid),
                             uid: info.pbi_uid,
                             flags: info.pbi_flags,
                             terminal: info.e_tdev,
                             startedAt: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec,
                             name: shortName,
                             path: path(pid),
                             memory: usage.map { .footprint($0.ri_phys_footprint) } ?? .unknown,
                             cpuTime: cpu,
                             reapedChildrenCPUTime: children)
    }

    /// Two mach-tick counters summed, in seconds; nil on overflow.
    private static func seconds(_ first: UInt64, _ second: UInt64, timebase: mach_timebase_info_data_t) -> TimeInterval? {
        let total = first.addingReportingOverflow(second)
        guard !total.overflow, let nanoseconds = nanoseconds(ticks: total.partialValue, timebase: timebase) else { return nil }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    /// A process whose full record the kernel refuses (another user's, to a
    /// caller that is not root): its short record and path, nil when it is
    /// gone. The short record's flags carry PROC_FLAG_CONTROLT as the full
    /// one does; the terminal device is not in it.
    private static func restrictedRecord(pid: pid_t) -> ProcessRecord? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessRecord(pid: pid,
                             ppid: pid_t(bitPattern: info.pbsi_ppid),
                             pgid: pid_t(bitPattern: info.pbsi_pgid),
                             uid: info.pbsi_uid,
                             flags: info.pbsi_flags,
                             terminal: ProcessRecord.noTerminal,
                             startedAt: 0,
                             name: cString(info.pbsi_comm),
                             path: path(pid),
                             memory: .unknown,
                             cpuTime: nil,
                             reapedChildrenCPUTime: nil,
                             restricted: true)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return status == 0 ? info : nil
    }

    private static func path(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// insi_lport and insi_fport hold a 16-bit port in network byte order.
    private static func port(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }

    private static let timebase: mach_timebase_info_data_t? = {
        var info = mach_timebase_info_data_t()
        return mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0 ? info : nil
    }()

    /// Mach ticks to nanoseconds (MetricFormat's overflow-checked conversion).
    private static func nanoseconds(ticks: UInt64, timebase: mach_timebase_info_data_t) -> UInt64? {
        MetricFormat.machTimeNanoseconds(ticks, numerator: timebase.numer, denominator: timebase.denom)
    }

    /// kern.argmax: the largest argv + environment the kernel accepts.
    private static let argumentBufferSize: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()
}

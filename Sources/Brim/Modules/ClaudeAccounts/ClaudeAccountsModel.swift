// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CryptoKit
import Darwin
import Foundation

// Brim's Claude Code accounts. Each account is one Claude Code config folder,
// selected by CLAUDE_CONFIG_DIR; Claude Code signs in and refreshes its own
// tokens there. Nothing in this folder reads, copies, refreshes or writes a
// Claude credential or keychain item.
//
// These files use Foundation and CryptoKit only: the app compiles them, and so
// does the brim-claude helper (Sources/BrimClaude), which runs inside every
// Claude Code session as its status line and must start fast.

// MARK: - Account key

/// The name Brim gives an account's state (live/<key>.json, readings,
/// accounts.json ids).
enum ClaudeAccountKey {
    static let defaultKey = "default"

    /// "default" for the default account (CLAUDE_CONFIG_DIR unset, folder ""),
    /// otherwise the first 8 hex digits of SHA-256 over the exact folder string
    /// in NFC. That is the suffix Claude Code gives the folder's keychain item;
    /// only the path string is hashed, nothing is read from the keychain.
    static func key(forFolder folder: String) -> String {
        guard !folder.isEmpty else { return defaultKey }
        let digest = SHA256.hash(data: Data(folder.precomposedStringWithCanonicalMapping.utf8))
        return ClaudeHex.string(digest.prefix(4))
    }

    /// The folder a Claude Code process runs on, from its environment: the
    /// exact CLAUDE_CONFIG_DIR string, or "" when it is unset or empty (Claude
    /// Code treats an empty value as unset).
    static func folder(environment: [String: String]) -> String {
        environment[ClaudeLaunchEnvironment.configDirectoryVariable] ?? ""
    }
}

enum ClaudeHex {
    static func string<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Usage

/// Where a window's numbers came from: a session's status line ("live", the
/// latest API response headers), Claude Code's saved copy in .claude.json
/// ("cache", written by /usage and get_usage), or Brim's own get_usage check
/// ("check").
enum ClaudeUsageSource: String, Codable, Equatable {
    case live, cache, check
}

/// One plan window: the 5-hour session window or the weekly one.
struct ClaudeUsageWindow: Equatable {
    /// Percent of the window used, 0...100 (a server may report more than 100).
    var utilization: Double
    var resetsAt: Date?
    var observedAt: Date
    var source: ClaudeUsageSource
}

/// A weekly window that counts only one model's use, as "Fable".
struct ClaudeScopedWindow: Equatable {
    /// The server's label for the model bucket (scope.model.display_name).
    var model: String
    var utilization: Double
    var resetsAt: Date?
    /// limits[].is_active: whether this row is the one the account is
    /// currently being measured against. Unknown for get_usage's model_scoped.
    var active: Bool?
    var observedAt: Date
    var source: ClaudeUsageSource

    var window: ClaudeUsageWindow {
        ClaudeUsageWindow(utilization: utilization, resetsAt: resetsAt, observedAt: observedAt, source: source)
    }
}

/// What is known about one account's plan limits. Each window carries its own
/// observation time and source, because a merged reading combines feeds
/// (ClaudeAccountRanking.merge): per window, the newest observation wins.
struct ClaudeAccountReading: Equatable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    var scoped: [ClaudeScopedWindow] = []
    /// When a full report (the server's limits[] list, from .claude.json or a
    /// get_usage check) said which scoped windows exist: a scoped window
    /// observed before it and missing from it is gone (ClaudeAccountRanking.merge).
    /// nil for the status line, which never reports scoped windows. Saved in
    /// accounts.json beside the windows that survived it, because folders
    /// that share a sign-in are merged from there (brim-claude): without it,
    /// another folder's older reading would bring a dropped window back.
    var scopedReportedAt: Date? = nil

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil && scoped.isEmpty }

    /// The newest observation among the windows.
    var observedAt: Date? {
        ([fiveHour?.observedAt, sevenDay?.observedAt] + scoped.map(\.observedAt)).compactMap { $0 }.max()
    }

    /// The source of the newest observation.
    var source: ClaudeUsageSource? {
        let all: [(Date, ClaudeUsageSource)] = [fiveHour, sevenDay].compactMap { $0.map { ($0.observedAt, $0.source) } }
            + scoped.map { ($0.observedAt, $0.source) }
        var best: (Date, ClaudeUsageSource)?
        for item in all {
            if let current = best, item.0 < current.0 { continue }
            best = item
        }
        return best?.1
    }

    func scopedWindow(model: String) -> ClaudeScopedWindow? {
        scoped.first { $0.model.lowercased() == model.lowercased() }
    }
}

// MARK: - Accounts

/// One account. `id` is always ClaudeAccountKey.key(forFolder: folder): it is
/// written to accounts.json for readability and recomputed when read.
struct ClaudeAccount: Equatable {
    var label: String
    /// The exact CLAUDE_CONFIG_DIR string, never normalized (the keychain item
    /// is keyed to this spelling). "" is the default account, launched with
    /// CLAUDE_CONFIG_DIR removed.
    var folder: String
    var accountUuid: String?
    /// The organization the sign-in uses (oauthAccount.organizationUuid):
    /// plan limits belong to it, so one login in two organizations (a
    /// personal plan and a team seat) is two Claude accounts.
    var organizationUuid: String?
    var email: String?
    /// A short plan label, as "Max 20x".
    var plan: String?
    /// false once the folder's .claude.json has no oauthAccount; nil when not
    /// known yet. Only false makes an account "signed out" for ranking.
    var signedIn: Bool?
    /// The email the person expects this folder to hold (ClaudeAccountList):
    /// set for the one folder of each account in their list, nil for a
    /// folder that is no account's (a duplicate). The label follows it.
    var expectedEmail: String?

    init(label: String, folder: String, accountUuid: String? = nil, organizationUuid: String? = nil,
         email: String? = nil, plan: String? = nil, signedIn: Bool? = nil, expectedEmail: String? = nil) {
        self.label = label
        self.folder = folder
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.email = email
        self.plan = plan
        self.signedIn = signedIn
        self.expectedEmail = expectedEmail
    }

    var id: String { ClaudeAccountKey.key(forFolder: folder) }
    var isDefault: Bool { folder.isEmpty }

    /// The email the folder is signed in to now, while it is not known to be
    /// signed out.
    var heldEmail: String? { signedIn == false ? nil : email }

    /// The folder is signed in to another account than the one expected
    /// there: work on that account must not start in it.
    var holdsWrongAccount: Bool {
        guard let expectedEmail, let held = heldEmail else { return false }
        return !ClaudeAccountList.sameEmail(held, expectedEmail)
    }

    /// The folder Claude Code keeps this account's settings, sessions and
    /// transcripts in: ~/.claude for the default account.
    func configDirectory(home: String) -> String {
        ClaudeSessionIndex.configDirectory(forFolder: folder, home: home)
    }

    /// ~/.claude first, then each account's config folder, once each: every
    /// folder a conversation or a repo's memory can be in. The one list the
    /// helper's move and resume, its pick-time memory sync and the app's
    /// memory watcher all use.
    static func configDirectories(home: String, accounts: [ClaudeAccount]) -> [String] {
        var directories = [ClaudeSessionIndex.configDirectory(forFolder: "", home: home)]
        for account in accounts where !directories.contains(account.configDirectory(home: home)) {
            directories.append(account.configDirectory(home: home))
        }
        return directories
    }

    /// The account's global config: ~/.claude.json for the default account,
    /// <folder>/.claude.json otherwise.
    func configFile(home: String) -> String {
        ClaudeUsageDecoding.configFile(forFolder: folder, home: home)
    }
}

/// Which account new sessions start on: the ranking's choice, or one account.
enum ClaudeNewSessions: Equatable {
    case auto
    case account(String)

    static let autoValue = "auto"

    var rawValue: String {
        switch self {
        case .auto: return Self.autoValue
        case .account(let id): return id
        }
    }

    init(rawValue: String) {
        self = rawValue.isEmpty || rawValue == Self.autoValue ? .auto : .account(rawValue)
    }
}

/// ~/.config/brim/claude/accounts.json. Written by the app only, atomically,
/// and only when it changes; the helpers only read it.
struct ClaudeAccountsFile: Equatable {
    static let currentVersion = 1

    var version: Int = ClaudeAccountsFile.currentVersion
    var accounts: [ClaudeAccount]
    var newSessions: ClaudeNewSessions = .auto
    /// Keyed by account id.
    var readings: [String: ClaudeAccountReading] = [:]
    /// The person answered "Any other Claude accounts?" (added one, or said
    /// that was all).
    var othersAsked = false

    init(accounts: [ClaudeAccount], newSessions: ClaudeNewSessions = .auto,
         readings: [String: ClaudeAccountReading] = [:], othersAsked: Bool = false) {
        self.accounts = accounts
        self.newSessions = newSessions
        self.readings = readings
        self.othersAsked = othersAsked
    }

    func account(id: String) -> ClaudeAccount? {
        accounts.first { $0.id == id }
    }

    /// The accounts that answer to their label (`cc <label>`, `cx --to`):
    /// every folder but a duplicate (ClaudeAccountList.isDuplicate), whose
    /// own label is what it held before and which runs as its account.
    var named: [ClaudeAccount] {
        accounts.filter { !ClaudeAccountList.isDuplicate($0, in: accounts) }
    }

    /// What a name given to `cc <name>`, `cx --to <name>` or `brim-claude
    /// account-name` stands for: one account, none, or several.
    enum NameMatch: Equatable {
        case one(ClaudeAccount)
        case none
        /// Labels that differ only in case.
        case several([ClaudeAccount])
    }

    /// The one name rule every command uses: a label as written, ignoring
    /// case, among the named accounts; then an account id; then an exact
    /// config folder (with `home`, ~/.claude names the default account).
    /// Never a prefix or a part of a name (T-50: `cx --to sparkfx` must not
    /// guess sparkfx.ai). `labelsOnly` stops after the labels: the guess at
    /// a lone `claude <word>` asks only about a name `cc` lists, never an
    /// internal id such as "default".
    func match(_ name: String, home: String? = nil, labelsOnly: Bool = false) -> NameMatch {
        let lowered = name.lowercased()
        let labelled = named.filter { $0.label.lowercased() == lowered }
        if labelled.count > 1 { return .several(labelled) }
        if let account = labelled.first { return .one(account) }
        if labelsOnly { return .none }
        if let account = accounts.first(where: { $0.id == name })
            ?? accounts.first(where: { !$0.folder.isEmpty && $0.folder == name })
            ?? home.flatMap({ home in accounts.first { $0.isDefault && $0.configDirectory(home: home) == name } }) {
            return .one(account)
        }
        return .none
    }
}

/// live/<key>.json: what the newest status line of a session on this account
/// reported. Written by `brim-claude statusline` only when a whole-number
/// percent, a reset time, the model or the session changes.
struct ClaudeLiveFile: Equatable {
    struct Window: Equatable {
        var usedPercentage: Double
        var resetsAt: Date?
    }

    struct Model: Equatable {
        var id: String?
        var displayName: String?
    }

    var observedAt: Date
    var folder: String
    var sessionId: String?
    var cwd: String?
    var model: Model?
    var fiveHour: Window?
    var sevenDay: Window?

    var key: String { ClaudeAccountKey.key(forFolder: folder) }

    /// The windows as a reading from the "live" source.
    var reading: ClaudeAccountReading? {
        let window = { (window: Window?) -> ClaudeUsageWindow? in
            window.map { ClaudeUsageWindow(utilization: $0.usedPercentage, resetsAt: $0.resetsAt,
                                           observedAt: observedAt, source: .live) }
        }
        let reading = ClaudeAccountReading(fiveHour: window(fiveHour), sevenDay: window(sevenDay))
        return reading.isEmpty ? nil : reading
    }

    /// Use within one window only grows. A render whose number for the
    /// window `previous` holds (the same renewal, to the second) is lower came
    /// from an older API response, as when an idle session draws again, so
    /// the higher number stays.
    mutating func keepHigherUse(than previous: ClaudeLiveFile?) {
        func higher(_ window: Window?, _ old: Window?) -> Window? {
            guard var window, let old, let renewal = Self.wholeSecond(window.resetsAt),
                  renewal == Self.wholeSecond(old.resetsAt), old.usedPercentage > window.usedPercentage else { return window }
            window.usedPercentage = old.usedPercentage
            return window
        }
        fiveHour = higher(fiveHour, previous?.fiveHour)
        sevenDay = higher(sevenDay, previous?.sevenDay)
    }

    /// Whether `self` says something `previous` does not: a whole-number
    /// percent, a reset time (to the second), the model or the session.
    func differs(from previous: ClaudeLiveFile?) -> Bool {
        guard let previous else { return true }
        func same(_ a: Window?, _ b: Window?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?):
                return Self.wholePercent(a.usedPercentage) == Self.wholePercent(b.usedPercentage)
                    && Self.wholeSecond(a.resetsAt) == Self.wholeSecond(b.resetsAt)
            default: return false
            }
        }
        return !(same(fiveHour, previous.fiveHour) && same(sevenDay, previous.sevenDay)
                 && model?.id == previous.model?.id && sessionId == previous.sessionId
                 && folder == previous.folder)
    }

    /// Never traps: Int(_:) on a Double outside Int's range would end the
    /// process, and the status line must never fail its session.
    static func wholePercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000), 1_000_000).rounded())
    }

    /// nil for a time no Int64 holds (never traps).
    static func wholeSecond(_ date: Date?) -> Int64? {
        date.flatMap { Int64(exactly: $0.timeIntervalSince1970.rounded()) }
    }
}

// MARK: - State paths

/// Brim's shared Claude state: ~/.config/brim/claude (mode 0700), or the
/// folder BRIM_CLAUDE_STATE_DIR names (tests).
struct ClaudeAccountsPaths: Equatable {
    static let stateDirectoryVariable = "BRIM_CLAUDE_STATE_DIR"

    /// The folder under ~/.config: "brim", or "brim-dev" for Brim
    /// (Developer). The two builds run side by side, and each keeps its own
    /// accounts, live readings, requests and install record. build.sh
    /// compiles the app and its brim-claude with the same variant flag.
    #if BRIM_DEVELOPMENT
    static let variantFolder = "brim-dev"
    #else
    static let variantFolder = "brim"
    #endif

    let stateDirectory: String

    init(stateDirectory: String) {
        self.stateDirectory = stateDirectory
    }

    init(environment: [String: String], home: String) {
        if let custom = environment[Self.stateDirectoryVariable], custom.hasPrefix("/") {
            stateDirectory = custom
        } else {
            stateDirectory = home + "/.config/" + Self.variantFolder + "/claude"
        }
    }

    /// This process's: its environment and home folder.
    static var current: ClaudeAccountsPaths {
        let environment = ProcessInfo.processInfo.environment
        return ClaudeAccountsPaths(environment: environment, home: ClaudeHome.path(environment: environment))
    }

    var accountsFile: String { stateDirectory + "/accounts.json" }
    var liveDirectory: String { stateDirectory + "/live" }
    /// Helpers touch a file here to ask the app for a fresh get_usage check;
    /// the app watches the folder with FSEvents and deletes what it handled.
    var requestsDirectory: String { stateDirectory + "/requests" }
    /// sessions/<session id>.json: the account each session ran on
    /// (ClaudeSessionOwners), written by the status line.
    var sessionsDirectory: String { stateDirectory + "/sessions" }
    /// The folders' own MCP server configurations, saved before the MCP
    /// mirror replaced them (ClaudeMCPBackup).
    var mcpBackupsDirectory: String { stateDirectory + "/mcp-backups" }
    /// <token>.url: the sign-in link brim-claude hands over while Brim runs
    /// a sign-in (ClaudeSignIn). Mode 0700; swept when the app starts.
    var signInDirectory: String { stateDirectory + "/signin" }

    func liveFile(key: String) -> String { liveDirectory + "/" + key + ".json" }
    func sessionFile(_ sessionId: String) -> String { sessionsDirectory + "/" + sessionId + ".json" }

    /// Creates the folder (and the state folder above it) with mode 0700.
    func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// The person's home: HOME when it is an absolute path, else the system's.
enum ClaudeHome {
    static func path(environment: [String: String]) -> String {
        if let home = environment["HOME"], home.hasPrefix("/"), home.count > 1 {
            return home.hasSuffix("/") ? String(home.dropLast()) : home
        }
        return NSHomeDirectory()
    }
}

// MARK: - Files

enum ClaudeFileError: Error, Equatable {
    /// What failed ("open /x", a verb and a path) and errno.
    case posix(String, Int32)
    /// Another writer holds the file's lock (ClaudeFileIO.TemporaryName.stableLocked):
    /// this write is skipped rather than waiting.
    case busy

    /// In words, for the person: "Could not open /x: Permission denied."
    var message: String {
        switch self {
        case .posix(let what, let code):
            return "Could not \(what)" + (code == 0 ? "." : ": " + String(cString: strerror(code)) + ".")
        case .busy:
            return "Could not write: another write to the same file is in progress."
        }
    }

    /// Any error in words: this one's message, else the system's own.
    static func message(_ error: Error) -> String {
        (error as? ClaudeFileError)?.message ?? error.localizedDescription
    }
}

enum ClaudeFileIO {
    /// How writeAtomically names its temporary file.
    enum TemporaryName {
        /// `.<name>.<pid>.<random>.tmp`, made exclusively: any number of
        /// writers at once, no lock file. For user files such as rc files.
        case unique
        /// `.<name>.tmp`, the same name on every write, under an exclusive
        /// `flock` on `.<name>.lock` (kept). A write that finds the lock held
        /// throws `ClaudeFileError.busy` at once. For files rewritten all the
        /// time by short-lived processes (the status line's live file): every
        /// unique name is a new path in fseventsd's event table, about 10,000
        /// a day for that file alone.
        case stableLocked
    }

    /// Writes through a temporary file in the same folder and a rename, so a
    /// reader sees the old content or the new, never a part.
    static func writeAtomically(_ data: Data, to path: String, mode: mode_t = 0o600,
                                temporary naming: TemporaryName = .unique) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary: String
        let flags: Int32
        var lock: Int32 = -1
        switch naming {
        case .unique:
            temporary = "\(directory)/.\(name).\(getpid()).\(UInt32.random(in: 0 ... .max)).tmp"
            flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
        case .stableLocked:
            let lockPath = "\(directory)/.\(name).lock"
            lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw ClaudeFileError.posix("open \(lockPath)", errno) }
            if flock(lock, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                close(lock)
                if code == EWOULDBLOCK { throw ClaudeFileError.busy }
                throw ClaudeFileError.posix("lock \(lockPath)", code)
            }
            temporary = "\(directory)/.\(name).tmp"
            flags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
        }
        // Closing the lock's descriptor releases it.
        defer { if lock >= 0 { close(lock) } }
        let descriptor = open(temporary, flags, mode)
        guard descriptor >= 0 else { throw ClaudeFileError.posix("open \(temporary)", errno) }
        var failure: ClaudeFileError?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .posix("write \(temporary)", errno)
                    return
                }
                offset += written
            }
        }
        // The mode asked for, whatever the umask took away.
        if failure == nil, fchmod(descriptor, mode) != 0 { failure = .posix("chmod \(temporary)", errno) }
        close(descriptor)
        if failure == nil, rename(temporary, path) != 0 { failure = .posix("rename \(path)", errno) }
        if let failure {
            unlink(temporary)
            throw failure
        }
    }

    /// The file's bytes, or nil when it is missing, not a regular file or
    /// larger than `limit`.
    static func read(_ path: String, limit: Int = 8 << 20) -> Data? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= limit else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ path: String, followingLinks: Bool = false) -> Bool {
        var info = stat()
        let status = followingLinks ? stat(path, &info) : lstat(path, &info)
        return status == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// Where a symlink points, as written in the link.
    static func linkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// The path with every symlink resolved; the path itself when it does not
    /// exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - JSON

/// Reading JSON values that came through JSONSerialization without trusting
/// their types.
enum ClaudeJSON {
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// A finite number; a JSON true or false is not one.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A share of a window, held to 0...1000: a server may report a little
    /// over 100, and nothing larger means anything (or fits every use).
    static func percent(_ value: Any?) -> Double? {
        number(value).map { min(max($0, 0), 1_000) }
    }

    /// An ISO 8601 date with any number of fractional digits, or epoch
    /// seconds (epoch milliseconds when the number is that large); nil
    /// outside ClaudeDate.plausible.
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return ClaudeDate.epoch(seconds)
        }
        guard let text = string(value) else { return nil }
        return ClaudeDate.parse(text).flatMap(ClaudeDate.plausible)
    }

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [])
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ClaudeDate.format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                guard let date = ClaudeDate.epoch(seconds) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a plausible time: \(seconds)")
                }
                return date
            }
            let text = try container.decode(String.self)
            guard let date = ClaudeDate.parse(text).flatMap(ClaudeDate.plausible) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date: \(text)")
            }
            return date
        }
        return decoder
    }
}

enum ClaudeDate {
    /// 2000-01-01 and 2200-01-01 UTC: every time Claude Code or Brim records
    /// falls between them, and every whole second between them fits an Int64.
    static let earliest = Date(timeIntervalSince1970: 946_684_800)
    static let latest = Date(timeIntervalSince1970: 7_258_118_400)

    /// The date, or nil outside earliest...latest.
    static func plausible(_ date: Date) -> Date? {
        date >= earliest && date <= latest ? date : nil
    }

    /// Epoch seconds, or milliseconds when the number is that large.
    static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return plausible(Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value))
    }

    /// "2026-11-15T14:00:00Z": whole seconds, UTC.
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded()))
    }

    /// ISO 8601 with a "Z" or "+hh:mm" zone and any number of fractional
    /// digits ("2026-11-17T10:00:00.197432+00:00").
    static func parse(_ text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let tee = text.firstIndex(of: "T"), let dot = text[tee...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber { end = text.index(after: end) }
            let digits = text[text.index(after: dot)..<end]
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: whole) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}

// MARK: - Codable

extension ClaudeUsageWindow: Codable {
    enum CodingKeys: String, CodingKey {
        case utilization, resetsAt = "resets_at", observedAt = "observed_at", source
    }
}

extension ClaudeScopedWindow: Codable {
    enum CodingKeys: String, CodingKey {
        case model, utilization, resetsAt = "resets_at", active, observedAt = "observed_at", source
    }
}

extension ClaudeAccountReading: Codable {
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", scoped, observedAt = "observed_at", source
        case scopedReportedAt = "scoped_reported_at"
    }

    /// A window as written, whose observation may be left to the reading's.
    private struct Wire: Decodable {
        var model: String?
        var utilization: Double
        var resetsAt: Date?
        var active: Bool?
        var observedAt: Date?
        var source: ClaudeUsageSource?

        enum CodingKeys: String, CodingKey {
            case model, utilization, resetsAt = "resets_at", active, observedAt = "observed_at", source
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let observed = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let source = try container.decodeIfPresent(ClaudeUsageSource.self, forKey: .source)
        func window(_ wire: Wire?) -> ClaudeUsageWindow? {
            guard let wire, let at = wire.observedAt ?? observed else { return nil }
            return ClaudeUsageWindow(utilization: wire.utilization, resetsAt: wire.resetsAt, observedAt: at,
                                     source: wire.source ?? source ?? .cache)
        }
        fiveHour = window(try container.decodeIfPresent(Wire.self, forKey: .fiveHour))
        sevenDay = window(try container.decodeIfPresent(Wire.self, forKey: .sevenDay))
        scoped = (try container.decodeIfPresent([Wire].self, forKey: .scoped) ?? []).compactMap { wire in
            guard let model = wire.model, let at = wire.observedAt ?? observed else { return nil }
            return ClaudeScopedWindow(model: model, utilization: wire.utilization, resetsAt: wire.resetsAt,
                                      active: wire.active, observedAt: at, source: wire.source ?? source ?? .cache)
        }
        scopedReportedAt = try container.decodeIfPresent(Date.self, forKey: .scopedReportedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try container.encodeIfPresent(sevenDay, forKey: .sevenDay)
        try container.encode(scoped, forKey: .scoped)
        try container.encodeIfPresent(scopedReportedAt, forKey: .scopedReportedAt)
        try container.encodeIfPresent(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

extension ClaudeAccount: Codable {
    enum CodingKeys: String, CodingKey {
        case id, label, folder, accountUuid, organizationUuid, email, plan, signedIn, expectedEmail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: try container.decode(String.self, forKey: .label),
                  folder: try container.decode(String.self, forKey: .folder),
                  accountUuid: try container.decodeIfPresent(String.self, forKey: .accountUuid),
                  organizationUuid: try container.decodeIfPresent(String.self, forKey: .organizationUuid),
                  email: try container.decodeIfPresent(String.self, forKey: .email),
                  plan: try container.decodeIfPresent(String.self, forKey: .plan),
                  signedIn: try container.decodeIfPresent(Bool.self, forKey: .signedIn),
                  expectedEmail: try container.decodeIfPresent(String.self, forKey: .expectedEmail))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(folder, forKey: .folder)
        try container.encodeIfPresent(accountUuid, forKey: .accountUuid)
        try container.encodeIfPresent(organizationUuid, forKey: .organizationUuid)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encodeIfPresent(signedIn, forKey: .signedIn)
        try container.encodeIfPresent(expectedEmail, forKey: .expectedEmail)
    }
}

extension ClaudeAccountsFile: Codable {
    enum CodingKeys: String, CodingKey {
        case version, accounts, newSessions, readings, othersAsked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        accounts = try container.decode([ClaudeAccount].self, forKey: .accounts)
        newSessions = ClaudeNewSessions(rawValue: try container.decodeIfPresent(String.self, forKey: .newSessions) ?? "")
        readings = try container.decodeIfPresent([String: ClaudeAccountReading].self, forKey: .readings) ?? [:]
        othersAsked = try container.decodeIfPresent(Bool.self, forKey: .othersAsked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(newSessions.rawValue, forKey: .newSessions)
        try container.encode(readings, forKey: .readings)
        if othersAsked { try container.encode(othersAsked, forKey: .othersAsked) }
    }

    /// accounts.json from disk; nil when it is missing or unreadable.
    static func load(_ paths: ClaudeAccountsPaths) -> ClaudeAccountsFile? {
        guard let data = ClaudeFileIO.read(paths.accountsFile, limit: 4 << 20) else { return nil }
        return try? ClaudeJSON.decoder().decode(ClaudeAccountsFile.self, from: data)
    }

    func encoded() throws -> Data {
        try ClaudeJSON.encoder().encode(self)
    }

    /// Writes accounts.json (the app's job) when its content changed; returns
    /// whether it wrote.
    @discardableResult
    func save(_ paths: ClaudeAccountsPaths) throws -> Bool {
        let data = try encoded()
        if ClaudeFileIO.read(paths.accountsFile, limit: 4 << 20) == data { return false }
        try paths.ensureDirectory(paths.stateDirectory)
        try ClaudeFileIO.writeAtomically(data, to: paths.accountsFile)
        return true
    }
}

extension ClaudeLiveFile.Window: Codable {
    enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
}

extension ClaudeLiveFile.Model: Codable {
    enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
}

extension ClaudeLiveFile: Codable {
    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at", folder, sessionId = "session_id", cwd, model,
             fiveHour = "five_hour", sevenDay = "seven_day"
    }

    static func load(_ path: String) -> ClaudeLiveFile? {
        guard let data = ClaudeFileIO.read(path, limit: 1 << 20) else { return nil }
        return try? ClaudeJSON.decoder().decode(ClaudeLiveFile.self, from: data)
    }

    /// Every live file, keyed by account key.
    static func loadAll(_ paths: ClaudeAccountsPaths) -> [String: ClaudeLiveFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.liveDirectory)) ?? []
        var files: [String: ClaudeLiveFile] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let file = load(paths.liveDirectory + "/" + name) else { continue }
            files[file.key] = file
        }
        return files
    }
}

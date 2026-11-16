// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// A line fseventsd logged that the Memory module keeps as evidence.
enum MemoryDaemonLogEvent: Equatable {
    /// "event table has grown too large" (or "fname table …"): fseventsd's
    /// own warning. Supporting evidence only: it can come days before a
    /// stall, or never.
    case tableTooLarge(at: Date)
    /// "SLOWDOWN: client … (pid N) sleeping due to too many errors": a
    /// client fseventsd is throttling.
    case slowdown(pid: pid_t, at: Date)
}

/// What the Memory module knows about kinds of processes: dev runtimes, tools
/// that daemonize on purpose, language servers, agents, and what is never
/// touched. Pure lists and matchers, so the tests read the same rules the app
/// runs. A path alone never decides anything: every rule here is one input to
/// MemoryClassifier, which also checks the process group, its parents, its
/// terminal, its CPU and its sockets.
enum MemoryRules {
    // MARK: Dev signature (leftover test e)

    /// Runtimes a dev leftover is made of, by executable name.
    static func isDevRuntime(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("python") { return true }   // python, python3, python3.12
        return ["node", "bun", "deno", "ruby", "java", "go", "cargo", "dotnet", "esbuild"].contains(lower)
    }

    /// A process that carries a positive dev signature: a dev runtime, a path
    /// in a dev environment, a test runner's arguments, or a Claude Code
    /// Bash-tool shell.
    static func hasDevSignature(_ record: ProcessRecord, home: String) -> Bool {
        if isDevRuntime(record.executableName) || isDevRuntime(record.name) { return true }
        if isDevPath(record.path, home: home) { return true }
        let arguments = record.arguments ?? []
        if let first = arguments.first, isDevPath(first, home: home) { return true }
        return isTestRunnerArguments(arguments) || isMultiprocessingChild(arguments) || isClaudeShell(arguments)
    }

    /// A path inside a dev environment. A Homebrew path is not one: every
    /// formula lives there, tmux and emacs as much as node, and proc_pidpath
    /// resolves each to its Cellar folder. Homebrew's runtimes still count by
    /// their executable name (node, python3.12).
    static func isDevPath(_ path: String, home: String) -> Bool {
        guard !path.isEmpty else { return false }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix + ".pyenv/") || path.hasPrefix(homePrefix + ".nvm/") { return true }
        return path.contains("/.venv/") || path.contains("/node_modules/")
    }

    /// pytest, xdist, jest workers, vitest, `node --test`.
    static func isTestRunnerArguments(_ arguments: [String]) -> Bool {
        let joined = arguments.joined(separator: " ")
        if joined.contains("pytest") || joined.contains("xdist") || joined.contains("jest-worker")
            || joined.contains("vitest") { return true }
        guard let first = arguments.first else { return false }
        return (first as NSString).lastPathComponent == "node" && arguments.dropFirst().contains("--test")
    }

    /// Python multiprocessing's spawned workers and resource tracker.
    static func isMultiprocessingChild(_ arguments: [String]) -> Bool {
        arguments.contains { $0.contains("multiprocessing.spawn") || $0.contains("multiprocessing.resource_tracker") }
    }

    /// A Claude Code Bash-tool shell: it sources a snapshot from a Claude
    /// config folder (~/.claude or ~/.claude-<name>).
    static func isClaudeShell(_ arguments: [String]) -> Bool {
        arguments.contains { $0.contains("/shell-snapshots/") && $0.contains("/.claude") }
    }

    // MARK: Never leftovers

    /// Helpers that daemonize on purpose and must outlive their app: never
    /// listed at all.
    static func isIntentionalDaemonizer(_ record: ProcessRecord) -> Bool {
        let name = record.executableName.lowercased()
        return name.hasSuffix("crashpad_handler") || name == "crashpad"
    }

    /// Dev tools that start a background server of their own and are meant to
    /// stay, and session keepers: shown for information, never ended for the
    /// person, whether their group's leader lives (fork + setsid) or is gone
    /// (a double fork).
    static func isSelfDaemonizingTool(_ record: ProcessRecord) -> Bool {
        if isSessionKeeper(record) { return true }
        let name = record.executableName.lowercased()
        let tools: Set<String> = ["adb", "watchman", "ollama", "postgres", "redis-server", "mongod", "mysqld",
                                  "mariadbd", "memcached", "colima", "limactl", "docker", "dockerd", "sccache",
                                  "gpg-agent", "ssh-agent", "nats-server", "emulator", "qemu-system-aarch64"]
        if tools.contains(name) { return true }
        let arguments = (record.arguments ?? []).joined(separator: " ")
        return name == "java" && (arguments.contains("GradleDaemon") || arguments.contains("KotlinCompileDaemon")
                                    || arguments.contains("bazel"))
    }

    /// Terminal multiplexers and editor daemons: a detached tmux, screen,
    /// zellij, dtach or abduco server, a mosh-server, or `emacs --daemon`.
    /// Each holds live sessions, their running jobs and unsaved buffers,
    /// looks exactly like a leftover (ppid 1, no terminal, a Unix socket
    /// only), and is never this module's to end.
    static func isSessionKeeper(_ record: ProcessRecord) -> Bool {
        let keepers: Set<String> = ["tmux", "screen", "zellij", "mosh-server", "dtach", "abduco"]
        for name in [record.executableName, record.name] {
            let lower = name.lowercased()
            if keepers.contains(lower) || lower.hasPrefix("emacs") { return true }   // emacs, emacs-30.1
        }
        return false
    }

    /// launchd started it as an XPC service.
    static func isXPCService(_ record: ProcessRecord) -> Bool {
        record.protectionPaths.contains { $0.contains(".xpc/Contents/MacOS/") }
    }

    /// Homebrew-installed: a `brew services` job when launchd runs it.
    static func isHomebrew(_ record: ProcessRecord) -> Bool {
        record.protectionPaths.contains { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/usr/local/") }
    }

    /// An app's, a system daemon's or Apple's own executable: such a process
    /// leads its own group because launchd started it, and is never a
    /// leftover (apps are judged as apps, in Heavy & idle).
    static func isAppOrSystemExecutable(_ record: ProcessRecord) -> Bool {
        record.protectionPaths.contains { path in
            path.contains(".app/Contents/") || path.contains(".xpc/Contents/MacOS/") || path.hasPrefix("/System/")
                || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/")
        }
    }

    // MARK: Protected

    /// System and session processes that are never ended: Kill Process's
    /// list and the session's own furniture.
    static func isSystemProtected(_ record: ProcessRecord) -> Bool {
        if KillProcessSupport.isProtected(pid: record.pid, name: record.executableName, path: record.path) { return true }
        let names: Set<String> = ["dock", "systemuiserver", "controlcenter", "coreaudiod", "notificationcenter",
                                  "finder", "windowserver", "loginwindow"]
        return names.contains(record.executableName.lowercased()) || names.contains(record.name.lowercased())
    }

    /// Agents: Claude Code, Codex, ChatGPT and Claude.
    static func isAgent(_ record: ProcessRecord) -> Bool {
        agentKind(record) != nil
    }

    enum Agent: String { case claude, codex }

    static func agentKind(_ record: ProcessRecord) -> Agent? {
        // Case matters: "claude" is the CLI, "Claude" the desktop app (a
        // protected tool). Claude Code's binary may be named after its
        // version, in a versions folder; an npm install runs under node.
        let arguments = record.arguments ?? []
        let first = arguments.first.map { ($0 as NSString).lastPathComponent }
        var names = [record.executableName, record.name]
        if let first {
            names.append(first)
            // `node /…/claude`: the script names the tool, never a `-c` string.
            if ["node", "bun"].contains(first), arguments.count > 1 {
                names.append((arguments[1] as NSString).lastPathComponent)
            }
        }
        if names.contains("claude") { return .claude }
        // The versioned binary is also run under other names (its bundled
        // ugrep, say); only as itself is it a session.
        if record.path.contains("/claude/versions/"), first == nil { return .claude }
        if names.contains("codex") { return .codex }
        return nil
    }

    /// IDEs, terminals, agents' apps, containers and virtual machines: their
    /// processes are never ended by this module.
    static func isProtectedTool(_ record: ProcessRecord) -> Bool {
        if isAgent(record) { return true }
        let apps = ["/Xcode.app/", "/Visual Studio Code.app/", "/Visual Studio Code - Insiders.app/", "/Cursor.app/",
                    "/Zed.app/", "/Terminal.app/", "/iTerm.app/", "/Warp.app/", "/Ghostty.app/", "/kitty.app/",
                    "/Alacritty.app/", "/WezTerm.app/", "/Claude.app/", "/ChatGPT.app/", "/Codex.app/",
                    "/Docker.app/", "/OrbStack.app/", "/UTM.app/", "/Parallels Desktop.app/", "/VMware Fusion.app/"]
        for path in record.protectionPaths {
            if apps.contains(where: path.contains) { return true }
            if path.contains("/JetBrains/") || path.contains("/Applications/IntelliJ") || path.contains("/Applications/PyCharm")
                || path.contains("/Applications/WebStorm") || path.contains("/Applications/GoLand")
                || path.contains("/Applications/Android Studio.app/") { return true }
        }
        let name = record.executableName.lowercased()
        return name.hasPrefix("com.docker.") || ["colima", "limactl", "vfkit", "orbstack"].contains(name)
            || name.hasPrefix("qemu-system-")
    }

    static func isTerminalShell(_ record: ProcessRecord) -> Bool {
        let name = record.executableName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["zsh", "bash", "fish", "sh", "dash", "tcsh", "nu"].contains(name)
    }

    // MARK: Running now

    /// A test run's top process, an actual test driver: `xcodebuild test`,
    /// a pytest (or xdist) parent, a `node --test` parent, vitest, a jest
    /// worker. testmanagerd is not one: Xcode starts it for a run and it
    /// stays alive long after, so it says nothing about a run by itself.
    static func isTestRunRoot(_ record: ProcessRecord) -> Bool {
        if isXcodeTestDriver(record) { return true }
        let name = record.executableName.lowercased()
        let arguments = record.arguments ?? []
        guard isDevRuntime(name) || name == "pytest" else { return false }
        return isTestRunnerArguments(arguments) && !isMultiprocessingChild(arguments)
    }

    /// The xcodebuild actions that run tests.
    static let xcodebuildTestActions: Set<String> = ["test", "test-without-building"]

    /// xcodebuild running tests: while one lives, a test plan may be using
    /// Simulators, so nothing Simulator-related is offered. An xcodebuild
    /// that only builds is not a test run; one whose arguments could not be
    /// read counts as one, so a Simulator is never offered on a guess.
    static func isXcodeTestDriver(_ record: ProcessRecord) -> Bool {
        guard record.executableName.lowercased() == "xcodebuild" else { return false }
        guard let arguments = record.arguments else { return true }
        return arguments.dropFirst().contains { xcodebuildTestActions.contains($0) }
    }

    /// Xcode's test daemon. It belongs to a test run only while an
    /// `xcodebuild test` lives; otherwise it is an idle daemon, never a run.
    static func isXcodeTestDaemon(_ record: ProcessRecord) -> Bool {
        record.executableName.lowercased() == "testmanagerd"
    }

    // MARK: Long-running helpers

    enum LanguageServer: String { case sourceKit, sourceKitLSP, pylance, typeScript, rustAnalyzer, gopls, clangd, java, kotlin }

    static func languageServer(_ record: ProcessRecord) -> LanguageServer? {
        let name = record.executableName
        if name == "SourceKitService" { return .sourceKit }
        if name == "sourcekit-lsp" { return .sourceKitLSP }
        if name == "rust-analyzer" { return .rustAnalyzer }
        if name == "gopls" { return .gopls }
        if name == "clangd" { return .clangd }
        let arguments = (record.arguments ?? []).joined(separator: " ").lowercased()
        if arguments.contains("pylance") { return .pylance }
        if arguments.contains("tsserver") { return .typeScript }
        if arguments.contains("jdtls") || arguments.contains("org.eclipse.jdt.ls") { return .java }
        if arguments.contains("kotlin-language-server") { return .kotlin }
        return nil
    }

    /// An MCP server started through `npm exec` / `npx` (the wrapper a CLI
    /// keeps per server). npm retitles itself, so its argv reads
    /// ["npm exec xcodebuildmcp@latest mcp", "", …]: words, not elements.
    static func isMCPWrapper(_ record: ProcessRecord) -> Bool {
        let words = (record.arguments ?? []).flatMap { $0.split(separator: " ").map(String.init) }
        guard words.contains(where: { $0.lowercased().contains("mcp") }) else { return false }
        let tools = words.prefix(3).map { ($0 as NSString).lastPathComponent.lowercased() }
        return tools.contains("npx") || (tools.contains { $0 == "npm" || $0 == "npm-cli.js" } && words.contains("exec"))
    }

    /// The Simulator device a launchd_sim serves, and whether it is a clone a
    /// test plan made (the `testing` device set, XCTestDevices).
    static func simulatorDevice(_ record: ProcessRecord) -> (udid: String, clone: Bool)? {
        guard record.executableName == "launchd_sim" else { return nil }
        let text = ([record.path] + (record.arguments ?? [])).joined(separator: " ")
        for marker in ["/XCTestDevices/", "/Devices/"] {
            guard let range = text.range(of: marker) else { continue }
            let udid = String(text[range.upperBound...].prefix(36))
            guard UUID(uuidString: udid) != nil else { continue }
            return (udid, marker == "/XCTestDevices/")
        }
        return nil
    }

    // MARK: launchd

    /// The pids of running jobs in `launchctl list` output (columns PID,
    /// Status, Label; "-" for a job that is not running).
    static func launchdJobPIDs(fromList output: String) -> Set<pid_t> {
        var pids = Set<pid_t>()
        for line in output.split(separator: "\n").dropFirst() {
            let first = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            if let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 { pids.insert(pid) }
        }
        return pids
    }

    // MARK: fseventsd

    /// macOS's file-event daemon: root's, at its framework path. Its memory
    /// leak (54 GB on this Mac, 2026-11-14) is the one Brim names.
    static func isFSEventsDaemon(_ record: ProcessRecord) -> Bool {
        record.uid == 0 && record.executableName == "fseventsd"
            && record.path.hasSuffix("/FSEvents.framework/Versions/A/Support/fseventsd")
    }

    /// What the person runs in Terminal to restart it (launchd starts it
    /// again). Brim never runs it: it has no root, and never asks for it.
    static let fseventsdRestartCommand = "sudo killall fseventsd"

    /// The `log stream` predicate for the lines Brim keeps. The format
    /// strings are fseventsd's own (macOS 27.2): "event table has grown too
    /// large. (filled %d / mask 0x%x)" and "SLOWDOWN: client %p (pid %d)
    /// sleeping due to too many errors (num usleeps %d)".
    static let daemonLogPredicate = "process == \"fseventsd\" AND (eventMessage BEGINSWITH \"event table has grown too large\""
        + " OR eventMessage BEGINSWITH \"fname table has grown too large\" OR eventMessage BEGINSWITH \"SLOWDOWN: client\")"

    /// One `log stream --style ndjson` line, as evidence: nil for any other
    /// line (the stream's header, a line from another message).
    static func daemonLogEvent(ndjsonLine line: String, receivedAt: Date = Date()) -> MemoryDaemonLogEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String else { return nil }
        let at = (object["timestamp"] as? String).flatMap(logTimestamp) ?? receivedAt
        if message.hasPrefix("event table has grown too large") || message.hasPrefix("fname table has grown too large") {
            return .tableTooLarge(at: at)
        }
        guard message.hasPrefix("SLOWDOWN: client"), let open = message.range(of: "(pid ") else { return nil }
        let digits = message[open.upperBound...].prefix { $0.isNumber }
        guard let pid = pid_t(digits), pid > 0 else { return nil }
        return .slowdown(pid: pid, at: at)
    }

    /// "2026-11-14 19:11:03.123456-0800", as `log` writes timestamps.
    private static func logTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter.date(from: text)
    }

    /// Whether a `log stream` child recorded by an earlier Brim (one that
    /// crashed before ending it) is still that child: same pid and start
    /// time, `/usr/bin/log`, and adopted by launchd. Anything else is not
    /// ours to end.
    static func shouldEndLeftoverLogChild(recorded: ProcessIdentity?, current: ProcessRecord?) -> Bool {
        guard let recorded, let current, !current.restricted, recorded.startedAt != 0 else { return false }
        return current.identity == recorded && current.path == "/usr/bin/log" && current.ppid == 1
    }

    /// The identity of a child this app just spawned. bsdinfo is refused for
    /// a child that already exited (a zombie) while the kernel's own record
    /// still has its start time, and the child stays unreaped, so its pid
    /// cannot be reused, until this app reaps it. Nil only when the kernel
    /// has no such process at all. Review fix, T-42: a failed bsdinfo read
    /// used to drop the child after one WNOHANG wait, leaving a running
    /// child unowned or a zombie unreaped while another one was started.
    static func spawnedChildIdentity(pid: pid_t, bsdStart: UInt64?, kernelStart: UInt64?) -> ProcessIdentity? {
        guard pid > 0, let startedAt = [bsdStart, kernelStart].compactMap({ $0 }).first(where: { $0 > 0 }) else { return nil }
        return ProcessIdentity(pid: pid, startedAt: startedAt)
    }

    // MARK: Header

    /// The rule for heavy work (a full build, a test suite): wait while
    /// the compressor holds more than about 10 GB.
    static let heavyWorkCompressedLimit: UInt64 = 10 << 30

    static func roomForHeavyWork(compressed: UInt64) -> Bool { compressed <= heavyWorkCompressedLimit }

    // MARK: Labels

    /// A short project name for a leftover: the pyenv environment, the folder
    /// holding a virtualenv or node_modules, else the working directory.
    static func projectHint(_ record: ProcessRecord, home: String) -> String? {
        // argv before the path: a pyenv virtualenv's interpreter resolves to
        // the base version's binary, while argv keeps the environment's name.
        let candidates = (record.arguments ?? []).prefix(2) + [record.path]
        for path in candidates {
            if let range = path.range(of: "/.pyenv/versions/") {
                let name = path[range.upperBound...].split(separator: "/").first.map(String.init)
                if let name, !name.isEmpty { return name }
            }
            for marker in ["/.venv/", "/node_modules/"] {
                if let range = path.range(of: marker) {
                    let folder = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
                    if !folder.isEmpty { return folder }
                }
            }
        }
        if let directory = record.workingDirectory, directory != home, directory != "/" {
            return (directory as NSString).lastPathComponent
        }
        return nil
    }

    /// Whether a Keep-list entry names this process: its executable name or
    /// the start of its path, without regard to case.
    static func isKept(_ record: ProcessRecord, keep: [String]) -> Bool {
        let name = record.executableName.lowercased()
        let path = record.path.lowercased()
        return keep.contains { entry in
            let wanted = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !wanted.isEmpty else { return false }
            return wanted == name || (wanted.hasPrefix("/") && path.hasPrefix(wanted))
        }
    }
}

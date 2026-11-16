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

enum RepositoryFeatureTests {
    private struct SourceRead: Sendable {
        let path: String
        let source: String?
        let lines: [String]
        let error: String?
    }

    private final class SourceReadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [SourceRead] = []

        func append(contentsOf batch: [SourceRead]) {
            lock.withLock { reads.append(contentsOf: batch) }
        }

        func sortedReads() -> [SourceRead] {
            lock.withLock { reads.sorted { $0.path < $1.path } }
        }
    }

    private struct RepositorySnapshot {
        let swiftPaths: [String]
        let swiftSources: [String: String]
        let swiftLines: [String: [String]]
        let enumerationError: String?
        let readTimedOut: Bool
        let unreadablePaths: [String]
        let emptyPaths: [String]

        init(fileManager: FileManager = .default) {
            let paths: [String]
            var traversalError: String?
            do {
                paths = Array(Set(try fileManager.subpathsOfDirectory(atPath: "Sources")
                    .filter { $0.hasSuffix(".swift") }
                    .map { "Sources/" + $0 })).sorted()
            } catch {
                paths = []
                traversalError = String(describing: error)
            }

            let workerCount = min(paths.count, max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
            let collector = SourceReadCollector()
            let queue = OperationQueue()
            queue.name = "RepositorySnapshot.SourceReads"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = max(1, workerCount)
            let readGroup = DispatchGroup()
            let operations: [Operation] = (0..<workerCount).map { workerIndex in
                readGroup.enter()
                return BlockOperation {
                    defer { readGroup.leave() }
                    var batch: [SourceRead] = []
                    batch.reserveCapacity((paths.count + workerCount - 1) / workerCount)
                    for index in stride(from: workerIndex, to: paths.count, by: workerCount) {
                        let path = paths[index]
                        do {
                            let source = try String(contentsOfFile: path, encoding: .utf8)
                            batch.append(SourceRead(path: path, source: source,
                                                   lines: source.components(separatedBy: "\n"),
                                                   error: nil))
                        } catch {
                            batch.append(SourceRead(path: path, source: nil, lines: [],
                                                   error: String(describing: error)))
                        }
                    }
                    collector.append(contentsOf: batch)
                }
            }
            queue.addOperations(operations, waitUntilFinished: false)
            let timedOut = readGroup.wait(timeout: .now() + 15) == .timedOut
            if timedOut { queue.cancelAllOperations() }

            let reads = collector.sortedReads()
            let sources = Dictionary(uniqueKeysWithValues: reads.compactMap { read in
                read.source.map { (read.path, $0) }
            })
            let lines = Dictionary(uniqueKeysWithValues: reads.compactMap { read in
                read.source.map { _ in (read.path, read.lines) }
            })

            swiftPaths = paths
            swiftSources = sources
            swiftLines = lines
            enumerationError = traversalError
            readTimedOut = timedOut
            unreadablePaths = reads.compactMap { read in
                read.error.map { "\(read.path): \($0)" }
            }
            emptyPaths = reads.compactMap { read in
                guard let source = read.source,
                      source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) == nil else { return nil }
                return read.path
            }
        }

        func source(at path: String) -> String {
            swiftSources[path] ?? ""
        }

        func lines(at path: String) -> [String] {
            swiftLines[path] ?? []
        }
    }

    static func run(_ suite: TestSuite) {
        func expectEqual(_ actual: String, _ expected: String, _ label: String,
                         file: StaticString = #filePath, line: UInt = #line) {
            suite.expect(actual == expected, "\(label): got \(actual), expected \(expected)",
                         file: file, line: line)
        }
        let repository = RepositorySnapshot()
        suite.expect(repository.enumerationError == nil,
               "the Swift source corpus is enumerable: \(repository.enumerationError ?? "")")
        suite.expect(!repository.swiftPaths.isEmpty,
               "the Swift source corpus contains files")
        suite.expect(!repository.readTimedOut,
               "the Swift source corpus finishes reading inside its bounded deadline")
        suite.expect(repository.unreadablePaths.isEmpty,
               "every Swift source is readable: \(repository.unreadablePaths)")
        suite.expect(repository.emptyPaths.isEmpty,
               "no Swift source is empty: \(repository.emptyPaths)")
        let requiredSourcePaths = [
            "Sources/Brim/Services/Homebrew/HomebrewManager.swift",
            "Sources/Brim/Services/Metrics/DiskSampler.swift",
            "Sources/Brim/Services/SelfUninstall.swift",
            "Sources/Brim/Support/Uninstaller.swift",
            "Sources/Brim/UI/Theme.swift",
        ]
        let missingSourcePaths = requiredSourcePaths.filter {
            repository.swiftSources[$0] == nil
        }
        suite.expect(missingSourcePaths.isEmpty,
               "every directly inspected Swift source is present: \(missingSourcePaths)")
        let buildScript = (try? String(contentsOfFile: "build.sh", encoding: .utf8)) ?? ""
        suite.expect(!buildScript.isEmpty, "build.sh is readable for repository contracts")

        // MARK: Homebrew command building and parsing

        let homebrewManagerSource = repository.source(
            at: "Sources/Brim/Services/Homebrew/HomebrewManager.swift")
        let homebrewRunStreaming = homebrewManagerSource.components(separatedBy: "func runStreaming(")
            .dropFirst().first?.components(separatedBy: "private func appendLog").first ?? ""
        suite.expect(homebrewRunStreaming.contains("brewSilenceTimeout")
                && !homebrewRunStreaming.contains("waitUntilExit"),
               "Homebrew operations wait on a bounded semaphore, not waitUntilExit")

        suite.expect(HomebrewPackageKind.allCases == [.cask, .formula],
               "Homebrew package kinds keep casks before formulae")
        suite.expect(HomebrewCommandBuilder.isValidToken("jq"), "simple Homebrew token is valid")
        suite.expect(HomebrewCommandBuilder.isValidToken("python@3.14"), "versioned formula token is valid")
        suite.expect(HomebrewCommandBuilder.isValidToken("visual-studio-code"), "cask token is valid")
        suite.expect(HomebrewCommandBuilder.isValidToken("homebrew/cask-fonts/font-iosevka"), "tapped token is valid")
        suite.expect(!HomebrewCommandBuilder.isValidToken(""), "empty Homebrew token is invalid")
        suite.expect(HomebrewCommandBuilder.untrustedTapName(fromOutput:
            "Error: Refusing to load formula foo from untrusted tap someone/sometap.\nRun `brew trust someone/sometap` to trust it.")
            == "someone/sometap",
               "untrusted tap name is extracted from Homebrew's refusal")
        suite.expect(HomebrewCommandBuilder.untrustedTapName(fromOutput: "Error: no such formula") == nil,
               "other Homebrew errors extract no tap")
        suite.expect(HomebrewCommandBuilder.untrustedTapName(fromOutput:
            "from untrusted tap ../evil") == nil,
               "a tap name that fails token validation is rejected")
        let trustCommand = HomebrewCommandBuilder.trustTap(brewPath: "/opt/homebrew/bin/brew", tap: "someone/sometap")
        suite.expect(trustCommand.arguments == ["trust", "--tap", "someone/sometap"],
               "trust command targets the tap explicitly")
        suite.expect(!HomebrewCommandBuilder.isValidToken("-bad"), "leading dash Homebrew token is invalid")
        suite.expect(!HomebrewCommandBuilder.isValidToken("../bad"), "path traversal Homebrew token is invalid")
        suite.expect(!HomebrewCommandBuilder.isValidToken("bad token"), "spaced Homebrew token is invalid")

        let brewPath = "/opt/homebrew/bin/brew"
        let cask = HomebrewPackage(kind: .cask, name: "sample-tool",
                                   displayName: "Sample Tool", desc: nil,
                                   installedVersion: nil, stableVersion: nil, homepage: nil)
        suite.expect(HomebrewCommandBuilder.search(brewPath: brewPath, kind: .formula, query: "jq").arguments
               == ["search", "--formula", "jq"],
               "formula search command uses separated arguments")
        suite.expect(HomebrewCommandBuilder.outdated(brewPath: brewPath).arguments
               == ["outdated", "--json=v2"],
               "Homebrew outdated command uses read-only JSON v2 output")
        suite.expect(HomebrewCommandBuilder.update(brewPath: brewPath).arguments
               == ["update"],
               "Homebrew update command refreshes Homebrew metadata")
        suite.expect(HomebrewCommandBuilder.install(brewPath: brewPath, package: cask).arguments
               == ["install", "--cask", "sample-tool"],
               "cask install command uses --cask")
        suite.expect(HomebrewCommandBuilder.uninstall(brewPath: brewPath, package: cask).arguments
               == ["uninstall", "--cask", "sample-tool"],
               "cask uninstall command uses --cask")
        suite.expect(HomebrewCommandBuilder.upgrade(brewPath: brewPath, package: cask).arguments
               == ["upgrade", "--cask", "sample-tool"],
               "cask upgrade command uses --cask")
        let formula = HomebrewPackage(kind: .formula, name: "jq",
                                      displayName: "jq", desc: nil,
                                      installedVersion: "1.8.1", stableVersion: nil, homepage: nil)
        suite.expect(HomebrewCommandBuilder.upgrade(brewPath: brewPath, package: formula).arguments
               == ["upgrade", "jq"],
               "formula upgrade command uses separated arguments")
        suite.expect(HomebrewCommandBuilder.upgradeAll(brewPath: brewPath).arguments
               == ["upgrade"],
               "Homebrew update all command upgrades all outdated packages")

        // brew exits non-zero when it could not do all of a run, not only when it
        // did none of it, so the installed and outdated lists have to be re-read
        // after a failed operation too. Read from the source: the refresh happens
        // inside a completion closure that no unit test can drive.
        let managerSource = homebrewManagerSource
        suite.expect(!managerSource.isEmpty, "HomebrewManager source is readable for the refresh checks")
        let managerCode = managerSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let refreshCalls = managerCode
            .components(separatedBy: "self.refreshInstalled(clearingError: false)").count - 1
        suite.expect(refreshCalls == 3,
               "the cancelled, needs-terminal and failed operation paths all re-read, "
               + "found \(refreshCalls)")
        let guardedBannerClears = managerCode
            .components(separatedBy: "if clearingError { errorMessage = nil }").count - 1
        suite.expect(guardedBannerClears == 2,
               "both banner clears in refreshInstalled are behind its parameter, so the reason "
               + "a failed operation gave survives the refresh that follows it, found "
               + "\(guardedBannerClears)")
        suite.expect(HomebrewOperation.Action.install.runningSystemImage == "arrow.down.circle.fill",
               "Homebrew install status uses a download icon")
        suite.expect(HomebrewOperation.Action.uninstall.runningSystemImage == "trash.circle.fill",
               "Homebrew uninstall status uses a trash icon")
        suite.expect(HomebrewOperation.Action.upgrade.runningSystemImage == "arrow.up.circle.fill",
               "Homebrew package update status uses an update icon")
        suite.expect(HomebrewOperation.Action.updateHomebrew.runningSystemImage == "arrow.triangle.2.circlepath",
               "Homebrew metadata refresh status uses a refresh icon")
        suite.expect(HomebrewOperation.Action.uninstall.clearsSelectionOnSuccess,
               "Homebrew uninstall clears details for the package that left the installed list")
        suite.expect(!HomebrewOperation.Action.install.clearsSelectionOnSuccess
                && !HomebrewOperation.Action.upgrade.clearsSelectionOnSuccess,
               "Homebrew install and upgrade preserve package details after success")
        suite.expect(HomebrewCommandBuilder.needsTerminalFallback(output: "sudo: a terminal is required to read the password"),
               "sudo terminal error triggers Homebrew terminal fallback")
        suite.expect(HomebrewCommandBuilder.installerCommand == #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
               "Homebrew installer command matches the official install script entrypoint")
        // The terminal handoff: a script the person's own terminal runs once in
        // their own shell, leaving nothing behind (issue #598).
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("brim-terminal-script-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // A stand-in login shell that writes down the arguments it was given.
            let shell = folder.appendingPathComponent("shell")
            let received = folder.appendingPathComponent("received")
            try? "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(HomebrewCommandBuilder.shellQuote(received.path))\n"
                .write(to: shell, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
            let command = #"eval (/opt/homebrew/bin/brew shellenv fish); echo "it's $HOME" 'a\b'"#
            let script = try? HomebrewTerminalScript.write(command: command, shellPath: shell.path, directory: folder)
            let permissions = script
                .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }
            suite.expect(script?.pathExtension == "" && permissions?.intValue == 0o700,
                   "the terminal script has no extension, so macOS opens it in the terminal the person chose, "
                   + "and only they can read or run it")
            if let script {
                let process = Process()
                process.executableURL = script
                try? process.run()
                process.waitUntilExit()
            }
            let arguments = (try? String(contentsOf: received, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
            suite.expect(arguments == ["-l", "-i", "-c", command, ""],
                   "the terminal script hands the command, unchanged, to the person's own shell as a login "
                   + "and interactive shell, the way Terminal ran it before, found \(arguments)")
            suite.expect(script.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false,
                   "the terminal script deletes itself as it runs")
            do {
                for shellPath in ["/bin/csh", "/bin/tcsh"] {
                    let output = folder.appendingPathComponent(URL(fileURLWithPath: shellPath).lastPathComponent)
                    let command = "/usr/bin/printf '%s' 'terminal handoff' > "
                        + HomebrewCommandBuilder.shellQuote(output.path)
                    let script = try HomebrewTerminalScript.write(command: command,
                                                                   shellPath: shellPath, directory: folder)
                    let process = Process()
                    process.executableURL = script
                    let input = Pipe()
                    process.standardInput = input
                    try process.run()
                    try input.fileHandleForWriting.close()
                    process.waitUntilExit()
                    suite.expect(process.terminationStatus == 0
                                 && (try? String(contentsOf: output, encoding: .utf8)) == "terminal handoff",
                                 "the production terminal script runs commands in \(shellPath)")
                    suite.expect(!FileManager.default.fileExists(atPath: script.path),
                                 "the \(shellPath) terminal script removes itself")
                }
            } catch {
                suite.expect(false, "could not run the csh terminal handoff: \(error)")
            }
            suite.expect((try? HomebrewTerminalScript.write(command: command, shellPath: shell.path,
                                                            directory: folder.appendingPathComponent("missing"))) == nil,
                   "a terminal script that cannot be written reports an error instead of opening nothing")
        }
        expectEqual(HomebrewCommandBuilder.shellProfilePath(homeDirectory: "/Users/test", shellPath: "/bin/zsh"),
                    "/Users/test/.zprofile",
                    "Homebrew shell setup uses zprofile for zsh")
        expectEqual(HomebrewCommandBuilder.shellProfilePath(homeDirectory: "/Users/test", shellPath: "/bin/bash"),
                    "/Users/test/.bash_profile",
                    "Homebrew shell setup uses bash_profile for bash")
        expectEqual(HomebrewCommandBuilder.shellProfilePath(homeDirectory: "/Users/test", shellPath: "/opt/homebrew/bin/fish"),
                    "/Users/test/.config/fish/config.fish",
                    "Homebrew shell setup uses the interactive shell config")
        expectEqual(HomebrewCommandBuilder.shellEnvLine(brewPath: brewPath, shellPath: "/bin/zsh"),
                    #"eval "$(/opt/homebrew/bin/brew shellenv)""#,
                    "Homebrew shell setup line uses brew shellenv")
        expectEqual(HomebrewCommandBuilder.shellEnvLine(brewPath: brewPath, shellPath: "/opt/homebrew/bin/fish"),
                    "eval (/opt/homebrew/bin/brew shellenv fish)",
                    "Homebrew shell setup line matches the interactive shell")
        expectEqual(HomebrewAnalytics.url(kind: .formula).absoluteString,
                    "https://formulae.brew.sh/api/analytics/install-on-request/homebrew-core/30d.json",
                    "Homebrew formula popularity uses install-on-request analytics")
        expectEqual(HomebrewAnalytics.url(kind: .cask).absoluteString,
                    "https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/30d.json",
                    "Homebrew cask popularity uses cask install analytics")
        do {
            let originalLocale = MetricFormat.locale
            defer { MetricFormat.locale = originalLocale }
            // Run independently of both the Mac's region and other suites.
            for (region, thousands, millions) in [
                ("en_US_POSIX", "1.2K", "1.2M"),
                ("pt_BR", "1,2K", "1,2M"),
            ] {
                MetricFormat.locale = Locale(identifier: region)
                expectEqual(HomebrewAnalytics.compactCount(999), "999",
                            "Homebrew popularity under 1K stays plain in \(region)")
                expectEqual(HomebrewAnalytics.compactCount(1_250), thousands,
                            "Homebrew popularity compacts thousands in \(region)")
                expectEqual(HomebrewAnalytics.compactCount(1_200_000), millions,
                            "Homebrew popularity compacts millions in \(region)")
            }
        }
        let shellSetupCommand = HomebrewCommandBuilder.shellConfigCommand(brewPath: brewPath,
                                                                          homeDirectory: "/Users/test",
                                                                          shellPath: "/bin/zsh")
        suite.expect(shellSetupCommand.hasPrefix("/bin/sh -c ")
                && shellSetupCommand.contains("PROFILE=/Users/test/.zprofile")
                && shellSetupCommand.hasSuffix(#"; eval "$(/opt/homebrew/bin/brew shellenv)"; brew --version"#),
               "Homebrew shell setup command targets the detected profile")
        suite.expect(shellSetupCommand.contains(#"grep -qxF "$LINE""#),
               "Homebrew shell setup command avoids duplicate profile lines")
        let alternateShellSetupCommand = HomebrewCommandBuilder.shellConfigCommand(
            brewPath: brewPath,
            homeDirectory: "/Users/test",
            shellPath: "/opt/homebrew/bin/fish"
        )
        suite.expect(alternateShellSetupCommand.hasPrefix("/bin/sh -c ")
                && alternateShellSetupCommand.contains("/bin/mkdir -p /Users/test/.config/fish")
                && alternateShellSetupCommand.hasSuffix("; eval (/opt/homebrew/bin/brew shellenv fish); brew --version"),
               "Homebrew shell setup creates and activates the interactive shell config")

        // The login shell's exports reach brew through an allowlist (issue #1290).
        let loginShell = HomebrewEnvironment.loginShellCommand(shellPath: "/bin/zsh")
        suite.expect(loginShell.executable == "/bin/zsh"
                && loginShell.arguments.contains("-l")
                && loginShell.arguments.contains("-i")
                && (loginShell.arguments.last?.hasSuffix("/usr/bin/env -0") ?? false)
                && (loginShell.arguments.last?.contains(HomebrewEnvironment.dumpMarker) ?? false),
               "Homebrew asks the user's shell as a login and interactive shell, so ~/.zshrc is read too, "
               + "and marks where the NUL-separated environment starts")
        let envDump = Data(("HOME=/Users/test\0https_proxy=http://127.0.0.1:7890\0MULTI=a\nb\0"
                            + "EQUALS=x=y\0EMPTY=\0noequals\0Welcome back\nHOMEBREW_API_DOMAIN=https://mirror.example/api\0").utf8)
        let parsedEnvironment = HomebrewEnvironment.parse(nullSeparated: envDump)
        expectEqual(parsedEnvironment["https_proxy"] ?? "", "http://127.0.0.1:7890",
                    "Homebrew environment parser reads a NAME=value entry")
        expectEqual(parsedEnvironment["MULTI"] ?? "", "a\nb",
                    "Homebrew environment parser keeps a newline inside a value; NUL is the only separator")
        expectEqual(parsedEnvironment["EQUALS"] ?? "", "x=y",
                    "Homebrew environment parser splits on the first equals sign only")
        suite.expect(parsedEnvironment["EMPTY"] == "" && parsedEnvironment["noequals"] == nil,
               "Homebrew environment parser keeps an empty value and drops an entry without one")
        suite.expect(!parsedEnvironment.keys.contains { $0.contains("Welcome") || $0.hasPrefix("HOMEBREW_") },
               "Homebrew environment parser drops an entry whose name is not an identifier, "
               + "such as startup output glued to the variable behind it")
        // What a real `bash -i` does: "no job control in this shell" on the shared
        // pipe, with no NUL of its own, so the first variable rides in behind it.
        let noisyDump = Data(("bash: no job control in this shell\nWelcome back\n"
                              + HomebrewEnvironment.dumpMarker
                              + "https_proxy=http://127.0.0.1:7890\0HOMEBREW_API_DOMAIN=https://mirror.example/api\0").utf8)
        let parsedNoisy = HomebrewEnvironment.parse(nullSeparated: noisyDump)
        expectEqual(parsedNoisy["https_proxy"] ?? "", "http://127.0.0.1:7890",
                    "Homebrew keeps the first variable of the dump when a startup file printed before it")
        expectEqual(parsedNoisy["HOMEBREW_API_DOMAIN"] ?? "", "https://mirror.example/api",
                    "Homebrew reads the rest of a dump that startup output preceded")
        suite.expect(parsedNoisy.count == 2,
               "Homebrew takes nothing a startup file printed as a variable, found \(parsedNoisy.keys.sorted())")
        let echoedMarker = Data(("startup echoed " + HomebrewEnvironment.dumpMarker + " itself\n"
                                 + HomebrewEnvironment.dumpMarker + "no_proxy=localhost\0").utf8)
        expectEqual(HomebrewEnvironment.parse(nullSeparated: echoedMarker)["no_proxy"] ?? "", "localhost",
                    "Homebrew takes the last marker, so a startup file echoing it cannot cut the dump short")
        let passedThrough = HomebrewEnvironment.passthrough([
            "PATH": "/tmp/evil:/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "HOME": "/Users/test",
            "SHELL": "/bin/zsh", "HTTP_PROXY": "http://127.0.0.1:7890", "https_proxy": "http://127.0.0.1:7890",
            "ALL_PROXY": "socks5://127.0.0.1:7891", "no_proxy": "localhost", "HOMEBREW_API_DOMAIN": "https://mirror.example/api",
            "HOMEBREW_BOTTLE_DOMAIN": "https://mirror.example", "HOMEBREWX": "no", "homebrew_lower": "no",
        ])
        suite.expect(Set(passedThrough.keys) == ["https_proxy", "ALL_PROXY", "no_proxy",
                                           "HOMEBREW_API_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN"],
               "Homebrew passes through only the proxy names brew itself keeps and HOMEBREW_* settings, "
               + "found \(passedThrough.keys.sorted())")
        suite.expect(HomebrewEnvironment.exportsFromLoginShell(shellPath: "").isEmpty
                && HomebrewEnvironment.exportsFromLoginShell(shellPath: "/nonexistent/shell", timeout: 1).isEmpty,
               "Homebrew contributes nothing when there is no login shell or it cannot start")
        suite.expect(HomebrewEnvironment.exportsFromLoginShell(shellPath: "/bin/sh").keys
                .allSatisfy(HomebrewEnvironment.isPassedThrough),
               "Homebrew never hands a login shell's whole environment to brew")
        let plainLogin = HomebrewEnvironment.loginShellCommand(shellPath: "/bin/zsh", interactive: false)
        suite.expect(plainLogin.arguments.contains("-l") && !plainLogin.arguments.contains("-i")
                && plainLogin.arguments.last == loginShell.arguments.last,
               "Homebrew's fallback asks for the same dump from a plain login shell")
        let resolvingEnvironment = HomebrewEnvironment.loginShellEnvironment(base: ["HOME": "/Users/test"])
        suite.expect(HomebrewEnvironment.resolvingVariable == "BRIM_RESOLVING_ENVIRONMENT"
                && resolvingEnvironment == ["HOME": "/Users/test", "BRIM_RESOLVING_ENVIRONMENT": "1"],
               "Homebrew runs the login shell with BRIM_RESOLVING_ENVIRONMENT=1 on top of the app's environment")
        // A real zsh reading startup files from a scratch ZDOTDIR, so the user's own are never touched.
        let zdotdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-login-shell-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zdotdir) }
        func startupExports(zshrc: String) -> [String: String] {
            try? "export HOMEBREW_API_DOMAIN=https://mirror.example/api\n"
                .write(to: zdotdir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
            try? zshrc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return HomebrewEnvironment.exportsFromLoginShell(
                shellPath: "/bin/zsh",
                baseEnvironment: ["HOME": zdotdir.path, "ZDOTDIR": zdotdir.path, "PATH": "/usr/bin:/bin"])
        }
        let zshrcExports = startupExports(zshrc: "export https_proxy=http://127.0.0.1:7890\n"
                                          + "export HOMEBREW_SEEN_RESOLVING=$BRIM_RESOLVING_ENVIRONMENT\n")
        suite.expect(zshrcExports["HOMEBREW_API_DOMAIN"] == "https://mirror.example/api"
                && zshrcExports["https_proxy"] == "http://127.0.0.1:7890",
               "Homebrew reads exports from both ~/.zprofile and ~/.zshrc, found \(zshrcExports.keys.sorted())")
        expectEqual(zshrcExports["HOMEBREW_SEEN_RESOLVING"] ?? "", "1",
                    "Homebrew's login shell exposes BRIM_RESOLVING_ENVIRONMENT to startup files")
        // A multiplexer autostart that fails without a terminal and exits, or an exec into another shell.
        for takeover in ["multiplexer_autostart_failed_without_a_terminal=1; exit 0", "exec /bin/sh -c true"] {
            let fallbackExports = startupExports(zshrc: takeover + "\n")
            expectEqual(fallbackExports["HOMEBREW_API_DOMAIN"] ?? "", "https://mirror.example/api",
                        "Homebrew falls back to the plain login run when ~/.zshrc ends the shell early: \(takeover)")
        }
        suite.expectClose(HomebrewProgressParser.progressFraction(in: "######## 42.5%") ?? -1,
                    0.425,
                    "Homebrew progress parser reads percentage output")
        suite.expect(HomebrewProgressParser.phase(in: "==> Downloading https://example.com/file",
                                            action: .install) == .downloading,
               "Homebrew progress parser detects downloads")
        suite.expect(HomebrewProgressParser.phase(in: "==> Installing Cask sample-tool",
                                            action: .install) == .installing,
               "Homebrew progress parser detects installs")
        suite.expect(HomebrewProgressParser.phase(in: "==> Uninstalling Cask sample-tool",
                                            action: .uninstall) == .uninstalling,
               "Homebrew progress parser detects uninstalls")
        suite.expect(HomebrewProgressParser.phase(in: "==> Upgrading sample-formula",
                                            action: .upgrade) == .upgrading,
               "Homebrew progress parser detects upgrades")
        suite.expect(HomebrewProgressParser.phase(in: "Already up-to-date.",
                                            action: .updateHomebrew) == .refreshing,
               "Homebrew progress parser detects metadata refresh")
        suite.expect(HomebrewProgressParser.activity(in: "\u{001B}[32m==> Moving App 'Sample.app'\u{001B}[0m")
               == "Moving App 'Sample.app'",
               "Homebrew progress parser cleans activity lines")
        suite.expect(HomebrewProgressParser.visibleError(from: "$ brew install x\nError: Cask failed")
               == "Error: Cask failed",
               "Homebrew progress parser hides command lines from visible errors")

        let homebrewJSON = """
        {
          "formulae": [
            {
              "name": "sample-formula",
              "full_name": "sample-formula",
              "desc": "Sample formula",
              "homepage": "https://example.com/sample-formula",
              "versions": { "stable": "1.8.1" },
              "installed": [{ "version": "1.8.1" }]
            },
            {
              "name": "tapped-formula",
              "full_name": "example/tap/tapped-formula",
              "desc": "Formula from a third-party tap",
              "homepage": "https://example.com/tapped-formula",
              "versions": { "stable": "2.0.0" },
              "installed": [{ "version": "1.0.0" }]
            }
          ],
          "casks": [
            {
              "token": "sample-tool",
              "name": ["Sample Tool"],
              "desc": "Sample cask",
              "homepage": "https://example.com/sample-tool",
              "version": "1.108.1",
              "installed": "1.107.0"
            },
            {
              "token": "tapped-tool",
              "full_token": "example/tap/tapped-tool",
              "name": ["Tapped Tool"],
              "desc": "Cask from a third-party tap",
              "homepage": "https://example.com/tapped-tool",
              "version": "2.0.0",
              "installed": "1.0.0"
            }
          ]
        }
        """
        let homebrewPackages = (try? HomebrewParser.parseInfoJSON(Data(homebrewJSON.utf8))) ?? []
        suite.expect(homebrewPackages.count == 4, "Homebrew JSON parser keeps formulae and casks")
        suite.expect(homebrewPackages.first?.kind == .cask,
               "Homebrew JSON parser sorts casks before formulae")
        suite.expect(homebrewPackages.first(where: { $0.name == "sample-formula" })?.installedVersion == "1.8.1",
               "Homebrew parser reads installed formula version")
        let tappedFormula = homebrewPackages.first { $0.name == "example/tap/tapped-formula" }
        suite.expect(tappedFormula?.displayName == "example/tap/tapped-formula",
               "Homebrew parser keeps the canonical name for a formula from a tap")
        suite.expect(homebrewPackages.first(where: { $0.name == "sample-tool" })?.displayName == "Sample Tool",
               "Homebrew parser reads cask display name")
        let tappedCask = homebrewPackages.first { $0.name == "tapped-tool" }
        suite.expect(tappedCask != nil,
               "Homebrew parser identifies a cask from a tap by its short token")
        suite.expect(tappedCask?.displayName == "Tapped Tool",
               "Homebrew parser keeps the human-readable name for a cask from a tap")
        let cleanCommandPackages = (try? HomebrewParser.parseInfoCommandOutput(homebrewJSON)) ?? []
        suite.expect(cleanCommandPackages.count == 4,
               "Homebrew command output parser keeps clean JSON")
        let noisyHomebrewOutput = """
        Warning: Skipping some beta metadata
        {"notice": "not package data"}
        \(homebrewJSON)
        Warning: A newer Homebrew beta changed an optional field
        """
        let noisyCommandPackages = (try? HomebrewParser.parseInfoCommandOutput(noisyHomebrewOutput)) ?? []
        suite.expect(noisyCommandPackages.count == 4,
               "Homebrew command output parser accepts warnings around JSON")
        suite.expect(noisyCommandPackages.first(where: { $0.name == "sample-tool" })?.installedVersion == "1.107.0",
               "Homebrew command output parser keeps package data from noisy output")
        suite.expect((try? HomebrewParser.parseInfoCommandOutput("Warning: no JSON here")) == nil,
               "Homebrew command output parser rejects output without valid JSON")
        let outdatedJSON = """
        {
          "formulae": [
            {
              "name": "fmt",
              "installed_versions": ["12.1.0"],
              "current_version": "12.2.0",
              "pinned": false
            },
            {
              "name": "example/tap/tapped-formula",
              "installed_versions": ["1.0.0"],
              "current_version": "2.0.0",
              "pinned": false
            }
          ],
          "casks": [
            {
              "name": "sample-tool",
              "installed_versions": ["1.107.0"],
              "current_version": "1.108.1",
              "pinned": true
            },
            {
              "name": "tapped-tool",
              "installed_versions": ["1.0.0"],
              "current_version": "2.0.0",
              "pinned": false
            }
          ]
        }
        """
        let outdatedPackages = (try? HomebrewParser.parseOutdatedJSON(Data(outdatedJSON.utf8))) ?? [:]
        suite.expect(outdatedPackages.count == 4,
               "Homebrew outdated parser keeps formulae and casks")
        suite.expect(outdatedPackages["formula:fmt"]?.versionSummary == "12.1.0 -> 12.2.0",
               "Homebrew outdated parser renders installed to current version")
        suite.expect(outdatedPackages["cask:sample-tool"]?.isPinned == true,
               "Homebrew outdated parser reads pinned status")
        suite.expect(tappedFormula.flatMap { outdatedPackages[$0.id] }?.currentVersion == "2.0.0",
               "Homebrew installed and outdated data use the same ID for tapped formulae")
        suite.expect(tappedCask?.id == "cask:tapped-tool",
               "Homebrew installed cask data stays on the short token brew outdated reports")
        suite.expect(tappedCask.flatMap { outdatedPackages[$0.id] }?.currentVersion == "2.0.0",
               "Homebrew installed and outdated data use the same short-token ID for tapped casks")
        let noisyOutdatedOutput = """
        Warning: Homebrew updated metadata
        {"notice": "not outdated data"}
        \(outdatedJSON)
        """
        let noisyOutdatedPackages = (try? HomebrewParser.parseOutdatedCommandOutput(noisyOutdatedOutput)) ?? [:]
        suite.expect(noisyOutdatedPackages["formula:fmt"]?.currentVersion == "12.2.0",
               "Homebrew outdated command output parser accepts warnings around JSON")
        let orderingPackages = [
            HomebrewPackage(kind: .cask, name: "alpha-tool", displayName: "Alpha Tool",
                            desc: nil, installedVersion: "1.0", stableVersion: nil, homepage: nil),
            HomebrewPackage(kind: .cask, name: "beta-tool", displayName: "Beta Tool",
                            desc: nil, installedVersion: "1.0", stableVersion: nil, homepage: nil,
                            update: HomebrewPackageUpdate(kind: .cask, name: "beta-tool",
                                                          installedVersions: ["1.0"],
                                                          currentVersion: "2.0", isPinned: false)),
            HomebrewPackage(kind: .formula, name: "gamma-tool", displayName: "Gamma Tool",
                            desc: nil, installedVersion: "1.0", stableVersion: nil, homepage: nil,
                            update: HomebrewPackageUpdate(kind: .formula, name: "gamma-tool",
                                                          installedVersions: ["1.0"],
                                                          currentVersion: "2.0", isPinned: false)),
            HomebrewPackage(kind: .formula, name: "delta-tool", displayName: "Delta Tool",
                            desc: nil, installedVersion: "1.0", stableVersion: nil, homepage: nil)
        ]
        suite.expect(HomebrewPackageOrdering.updatesFirst(orderingPackages).map(\.name)
               == ["beta-tool", "gamma-tool", "alpha-tool", "delta-tool"],
               "Homebrew installed packages keep all pending updates first without reordering either group")
        let dependencyJSON = """
        {
          "formulae": [
            { "name": "app-a", "full_name": "app-a",
              "installed": [{ "version": "1", "installed_on_request": true,
                              "runtime_dependencies": [{ "full_name": "shared-lib" }, { "full_name": "deep-lib" }] }] },
            { "name": "app-b", "full_name": "example/tap/app-b",
              "installed": [{ "version": "1", "installed_on_request": true,
                              "runtime_dependencies": [{ "full_name": "shared-lib" }, { "full_name": "example/tap/tap-lib" }] }] },
            { "name": "shared-lib", "full_name": "shared-lib",
              "installed": [{ "version": "2", "installed_on_request": false,
                              "runtime_dependencies": [{ "full_name": "deep-lib" }] }] },
            { "name": "deep-lib", "full_name": "deep-lib",
              "installed": [{ "version": "3", "installed_on_request": false, "runtime_dependencies": [] }] },
            { "name": "tap-lib", "full_name": "example/tap/tap-lib",
              "installed": [{ "version": "4", "installed_on_request": false, "runtime_dependencies": [] }] },
            { "name": "cask-lib", "full_name": "cask-lib",
              "installed": [{ "version": "5", "installed_on_request": false, "runtime_dependencies": [] }] },
            { "name": "orphan-lib", "full_name": "orphan-lib",
              "installed": [{ "version": "6", "installed_on_request": false, "runtime_dependencies": [] }] }
          ],
          "casks": [
            { "token": "cask-app", "name": ["Cask App"], "installed": "1",
              "depends_on": { "formula": ["cask-lib"] } }
          ]
        }
        """
        let dependencyPackages = (try? HomebrewParser.parseInfoJSON(Data(dependencyJSON.utf8))) ?? []
        let folded = HomebrewDependencyGraph.fold(dependencyPackages, installed: dependencyPackages)
        let flat = HomebrewDependencyGraph.display(dependencyPackages,
                                                   installed: dependencyPackages,
                                                   groupDependencies: false)
        suite.expect(flat.rows.map(\.id) == dependencyPackages.map(\.id)
                     && flat.rows.count == dependencyPackages.count
                     && flat.dependencies.isEmpty
                     && flat.orphans.isEmpty,
                     "Homebrew flat mode retains every installed row in its incoming order and shows no nested duplicates or orphans")
        let grouped = HomebrewDependencyGraph.display(dependencyPackages,
                                                      installed: dependencyPackages,
                                                      groupDependencies: true)
        suite.expect(grouped.rows.map(\.id) == folded.rows.map(\.id)
                     && Set(grouped.dependencies.keys) == Set(folded.dependencies.keys)
                     && grouped.orphans.map(\.id) == folded.orphans.map(\.id),
                     "Homebrew grouped mode preserves the existing dependency layout")
        suite.expect(folded.rows.map(\.name) == ["cask-app", "app-a", "example/tap/app-b"]
                     && folded.orphans.map(\.name) == ["orphan-lib"],
                     "Homebrew keeps requested packages as rows and lists a dependency nothing needs as an orphan, found \(folded.rows.map(\.name)) and \(folded.orphans.map(\.name))")
        suite.expect(folded.dependencies["formula:app-a"]?.map(\.name) == ["deep-lib", "shared-lib"],
                     "Homebrew lists direct and transitive dependencies under a requested formula")
        suite.expect(folded.dependencies["formula:example/tap/app-b"]?.map(\.name)
                     == ["deep-lib", "example/tap/tap-lib", "shared-lib"],
                     "Homebrew lists a shared dependency under each parent and resolves tapped names")
        suite.expect(folded.dependencies["cask:cask-app"]?.map(\.name) == ["cask-lib"],
                     "Homebrew lists a cask's formula dependencies under the cask")
        let withUpdate = HomebrewPackageOrdering.updatesFirst(dependencyPackages.map { package in
            var package = package
            if package.name == "shared-lib" {
                package.update = HomebrewPackageUpdate(kind: .formula, name: "shared-lib",
                                                       installedVersions: ["2"], currentVersion: "3", isPinned: false)
            }
            return package
        })
        let updateFolded = HomebrewDependencyGraph.fold(withUpdate, installed: withUpdate)
        let flatWithUpdate = HomebrewDependencyGraph.display(withUpdate,
                                                             installed: withUpdate,
                                                             groupDependencies: false)
        suite.expect(flatWithUpdate.rows.map(\.id) == withUpdate.map(\.id)
                     && flatWithUpdate.rows.first?.name == "shared-lib",
                     "Homebrew flat mode keeps update-first ordering and includes dependencies as top-level rows")
        suite.expect(updateFolded.rows.map(\.name) == ["app-a", "example/tap/app-b", "cask-app"]
                     && updateFolded.dependencies["formula:app-a"]?.map(\.name) == ["deep-lib", "shared-lib"],
                     "Homebrew keeps a dependency with an update under its parents and moves those parents up, found \(updateFolded.rows.map(\.name))")
        let orphanUpdate = HomebrewPackageOrdering.updatesFirst(dependencyPackages.map { package in
            var package = package
            if package.name == "orphan-lib" {
                package.update = HomebrewPackageUpdate(kind: .formula, name: "orphan-lib",
                                                       installedVersions: ["6"], currentVersion: "7", isPinned: false)
            }
            return package
        })
        let orphanUpdateFolded = HomebrewDependencyGraph.fold(orphanUpdate, installed: orphanUpdate)
        suite.expect(orphanUpdateFolded.orphans.map(\.name) == ["orphan-lib"]
                     && !orphanUpdateFolded.rows.contains { $0.name == "orphan-lib" },
                     "Homebrew keeps an orphan with an update in the unneeded group, found \(orphanUpdateFolded.rows.map(\.name))")
        let formulaOnly = dependencyPackages.filter { $0.kind == .formula }
        let flatFormulaOnly = HomebrewDependencyGraph.display(formulaOnly,
                                                              installed: dependencyPackages,
                                                              groupDependencies: false)
        suite.expect(flatFormulaOnly.rows.count == formulaOnly.count
                     && flatFormulaOnly.rows.allSatisfy { $0.kind == .formula },
                     "Homebrew flat mode keeps the active filter and its displayed count")
        let formulaOnlyFolded = HomebrewDependencyGraph.fold(formulaOnly, installed: dependencyPackages)
        suite.expect(formulaOnlyFolded.rows.map(\.name).contains("cask-lib")
                     && formulaOnlyFolded.orphans.map(\.name) == ["orphan-lib"],
                     "Homebrew shows a cask's dependency as a row, not an orphan, when the filter hides the cask")
        let oldBrewPackages = (try? HomebrewParser.parseInfoJSON(Data(dependencyJSON
            .replacingOccurrences(of: "\"installed_on_request\": true,", with: "")
            .replacingOccurrences(of: "\"installed_on_request\": false,", with: "").utf8))) ?? []
        let oldBrewFolded = HomebrewDependencyGraph.fold(oldBrewPackages, installed: oldBrewPackages)
        suite.expect(oldBrewFolded.rows.count == 8 && oldBrewFolded.dependencies.isEmpty && oldBrewFolded.orphans.isEmpty,
                     "Homebrew keeps the flat list when brew does not report installed_on_request, found \(oldBrewFolded.rows.count)")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.homebrewGroupDependencies] as? Bool == true,
                     "Homebrew grouping remains the default")
        let searchPackages = HomebrewParser.parseSearchOutput("sample-formula\nbad token\nsample-filter\nsample-tool\n",
                                                              kind: .formula,
                                                              installed: homebrewPackages)
        suite.expect(searchPackages.map(\.name) == ["sample-formula", "sample-filter", "sample-tool"],
               "Homebrew search parser keeps valid one-token results")
        let analyticsJSON = """
        {
          "category": "formula_install_on_request",
          "formulae": {
            "sample-formula": [
              { "formula": "sample-formula", "count": "21,557" },
              { "formula": "sample-formula --HEAD", "count": "30" }
            ],
            "sample-filter": [
              { "formula": "sample-filter", "count": "42,001" }
            ]
          }
        }
        """
        let popularity = (try? HomebrewAnalytics.parse(Data(analyticsJSON.utf8), kind: .formula)) ?? [:]
        suite.expect(popularity["sample-formula"]?.count == 21_557,
               "Homebrew analytics parser prefers the exact formula count")
        suite.expect(popularity["sample-filter"]?.rank == 1,
               "Homebrew analytics parser ranks by count")
        let rankedPackages = HomebrewAnalytics.enrichAndSort(searchPackages, popularity: popularity)
        suite.expect(rankedPackages.map(\.name) == ["sample-filter", "sample-formula", "sample-tool"],
               "Homebrew search results sort by popularity first")
        suite.expect(rankedPackages.first?.popularity?.compactCount == "42K",
               "Homebrew search results keep compact popularity")
        var newlyInstalled = rankedPackages[0]
        newlyInstalled.installedVersion = "2.0"
        let afterInstall = HomebrewSearchResults.reconciled(rankedPackages, installed: [newlyInstalled])
        suite.expect(afterInstall.first?.isInstalled == true
                     && afterInstall.first?.popularity == rankedPackages.first?.popularity,
                     "Homebrew search shows an installed package without losing its popularity")
        let afterUninstall = HomebrewSearchResults.reconciled(afterInstall, installed: [])
        suite.expect(afterUninstall.first?.isInstalled == false
                     && afterUninstall.map(\.id) == rankedPackages.map(\.id),
                     "Homebrew search returns to an installable result after uninstall")

        // MARK: Repository-wide source contracts

        // Reading a file is not a drawing step. The watermark logo was being
        // decoded inside the preview's body, so every frame of an opacity
        // drag re-read it from disk; it is loaded once per chosen file now,
        // which is what a task is for.
        let uiPrefix = "Sources/Brim/UI/"
        let allUIFiles = repository.swiftPaths.filter { $0.hasPrefix(uiPrefix) }
        var decodingInBody: [String] = []
        for path in allUIFiles {
            let lines = repository.lines(at: path)
            for (index, line) in lines.enumerated() {
                let reads = line.contains("NSImage(contentsOfFile:")
                    || line.contains("Data(contentsOf:")
                guard reads else { continue }
                let around = lines[max(0, index - 6)...min(lines.count - 1, index + 2)]
                if !around.contains(where: { $0.contains(".task(") || $0.contains("func ")
                                             || $0.contains("Task {") }) {
                    decodingInBody.append("\(path):\(index + 1)")
                }
            }
        }
        suite.expect(decodingInBody.isEmpty,
               "a view reads a file once, never while drawing (\(decodingInBody.joined(separator: ", ")))")

        // An unpinned borderless Menu claims the free width of its row on
        // macOS 15 and starves whatever shares that row (issue #569), so the
        // rule is checked for every borderless menu in the app rather than for
        // the one this fix touches. Kill Process is the one deliberate
        // exception: its row controls take a shared minimum width so the Kill
        // button and the menu beside it line up down the list.
        let borderlessMenuException = "KillProcess/KillProcessView"
        var unpinnedBorderlessMenus: [String] = []
        let uiFiles = allUIFiles.filter { !$0.contains(" 2") }
        for path in uiFiles where !path.contains(borderlessMenuException) {
            let file = String(path.dropFirst(uiPrefix.count))
            let lines = repository.lines(at: path)
            for (index, line) in lines.enumerated()
            where line.contains(".menuStyle(.borderlessButton)") {
                // Read to the end of the menu's own modifier chain: the next
                // line that is neither a modifier nor a comment belongs to
                // something else.
                var pinned = false
                var cursor = index + 1
                while cursor < lines.count {
                    let text = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard text.hasPrefix(".") || text.hasPrefix("//") else { break }
                    if text.hasPrefix(".fixedSize()") { pinned = true; break }
                    cursor += 1
                }
                if !pinned { unpinnedBorderlessMenus.append("\(file):\(index + 1)") }
            }
        }
        suite.expect(!uiFiles.isEmpty && unpinnedBorderlessMenus.isEmpty,
               "every borderless menu keeps its own size, across \(uiFiles.count) "
               + "scanned files: \(unpinnedBorderlessMenus)")

        // `waitUntilAllOperationsAreFinished` has no deadline, and the window
        // walk that used it runs on the main thread while its operations run on
        // the shared dispatch pool. Once unrelated work had taken every worker
        // in that pool, not one operation started and the wait never returned,
        // taking the whole app with it (issue #971).
        let appPrefix = "Sources/Brim/"
        let appSources = repository.swiftPaths.filter {
            $0.hasPrefix(appPrefix) && !$0.contains(" 2")
        }
        var unboundedOperationWaits: [String] = []
        for path in appSources {
            let file = String(path.dropFirst(appPrefix.count))
            for (index, line) in repository.lines(at: path).enumerated()
            where line.contains("waitUntilAllOperationsAreFinished") {
                unboundedOperationWaits.append("\(file):\(index + 1)")
            }
        }
        suite.expect(!appSources.isEmpty && unboundedOperationWaits.isEmpty,
               "no operation queue is waited on without a deadline: \(unboundedOperationWaits)")

        // Asking an application element for its role switches a Chromium app's
        // renderers into full accessibility mode for the rest of the process's
        // life. Both scans report real line numbers, so comments are excluded
        // in the predicate rather than removed from the source.
        func isCommentLine(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        var applicationRoleReads: [String] = []
        for path in appSources {
            let file = String(path.dropFirst(appPrefix.count))
            let lines = repository.lines(at: path)
            var applicationElements: Set<String> = []
            for line in lines where line.contains("AXUIElementCreateApplication(") {
                let assigned = (line.components(separatedBy: "=").first ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ")
                guard assigned.count == 2, assigned[0] == "let" || assigned[0] == "var" else { continue }
                applicationElements.insert(assigned[1])
            }
            for (index, line) in lines.enumerated()
            where line.contains("kAXRoleAttribute")
                && !isCommentLine(line)
                && applicationElements.contains(where: { line.contains("(\($0), ") }) {
                applicationRoleReads.append("\(file):\(index + 1)")
            }
        }
        suite.expect(!appSources.isEmpty && applicationRoleReads.isEmpty,
               "no application element is ever asked for its role: \(applicationRoleReads)")

        // A walk up kAXParent reaches an application element without naming it,
        // so every such walk must stop before asking that parent for its role.
        var unguardedParentWalks: [String] = []
        for path in appSources {
            let file = String(path.dropFirst(appPrefix.count))
            let lines = repository.lines(at: path)
            for (index, line) in lines.enumerated()
            where line.contains("role(of: parent)") && !isCommentLine(line) {
                let guarded = lines[max(0, index - 3)..<index]
                    .contains { $0.contains("isApplicationElement(parent)") && !isCommentLine($0) }
                if !guarded { unguardedParentWalks.append("\(file):\(index + 1)") }
            }
        }
        suite.expect(!appSources.isEmpty && unguardedParentWalks.isEmpty,
               "a walk up the parent chain stops at the application element: \(unguardedParentWalks)")

        // Availability is only ever written by the runtime that gates it, so a
        // new install surface cannot walk around the hardware check.
        var availabilityWriters: Set<String> = []
        for path in repository.swiftPaths {
            let writes = repository.lines(at: path).contains {
                $0.contains(".set(") && $0.contains("availabilityKey")
            }
            if writes { availabilityWriters.insert((path as NSString).lastPathComponent) }
        }
        suite.expect(availabilityWriters == ["FeatureRuntime.swift", "FeaturePresets.swift"],
               "feature availability is written only where the hardware gate runs, "
               + "found \(availabilityWriters.sorted())")

        var bareActivationYields: [String] = []
        for path in repository.swiftPaths
        where (path as NSString).lastPathComponent != "ActivationHandoff.swift"
            && repository.source(at: path).contains("yieldActivation") {
            bareActivationYields.append((path as NSString).lastPathComponent)
        }
        suite.expect(!repository.swiftPaths.isEmpty && bareActivationYields.isEmpty,
               "activation is yielded only through ActivationHandoff, "
               + "found a bare yield in \(bareActivationYields.sorted()) "
               + "across \(repository.swiftPaths.count) scanned files")

        // Dropping the last Swift reference does not deregister an event tap;
        // every literal tap creation needs a matching invalidation or removal.
        var tapOwnersWithoutInvalidate: [String] = []
        var tapOwners = 0
        for path in appSources {
            let code = repository.lines(at: path)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let taps = code.components(separatedBy: "CGEvent.tapCreate").count - 1
            guard taps > 0 else { continue }
            tapOwners += 1
            let invalidations = code.components(separatedBy: "CFMachPortInvalidate").count - 1
                + (code.components(separatedBy: "PointerTapRunLoop.remove(").count - 1)
            if invalidations < taps {
                let file = String(path.dropFirst(appPrefix.count))
                tapOwnersWithoutInvalidate.append("\(file) (\(taps) taps, \(invalidations) invalidated)")
            }
        }
        suite.expect(tapOwners > 0 && tapOwnersWithoutInvalidate.isEmpty,
               "every event tap owner invalidates its port on teardown, across "
               + "\(tapOwners) scanned owners: \(tapOwnersWithoutInvalidate)")

        // MARK: Localization source contracts

        // Visible localization source uses typographic apostrophes rather than
        // typewriter marks.
        let localizationSourcePaths = repository.swiftPaths.filter { path in
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            return folder == "Sources/Brim/Core"
                && (name.hasSuffix("Strings.swift") || name == "Localization.swift")
        }
        var typewriterMarks: [String] = []
        for path in localizationSourcePaths {
            for (index, line) in repository.lines(at: path).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard let opening = line.firstIndex(of: "\""),
                      let closing = line.lastIndex(of: "\""), opening < closing else { continue }
                if line[opening..<closing].contains("'") {
                    typewriterMarks.append("\(path):\(index + 1)")
                }
            }
        }
        suite.expect(typewriterMarks.isEmpty,
               "visible text curls its apostrophes (\(typewriterMarks.prefix(6).joined(separator: ", ")))")

        let themeSource = repository.source(at: "Sources/Brim/UI/Theme.swift")
        let raisedReads = themeSource
            .components(separatedBy: "accessibilityDisplayShouldIncreaseContrast").count - 1
        suite.expect(raisedReads == 1,
               "the panel outline answers raised contrast, and nothing else pretends to")

        // Every formatted decimal explicitly chooses its locale. Long calls
        // may put that locale on either of the next two lines.
        var regionlessDecimals: [String] = []
        for path in repository.swiftPaths {
            let lines = repository.lines(at: path)
            for (index, line) in lines.enumerated() {
                let statement = lines[index...min(index + 2, lines.count - 1)].joined()
                guard line.contains("String(format:"), !statement.contains("locale:") else { continue }
                let piece = line.components(separatedBy: "String(format:").dropFirst().first ?? ""
                let format = piece.components(separatedBy: "\"").dropFirst().first ?? ""
                if format.contains("f") && format.contains("%") {
                    regionlessDecimals.append("\(path):\(index + 1)")
                }
            }
        }
        suite.expect(regionlessDecimals.isEmpty,
               "a decimal on screen names its region (\(regionlessDecimals.joined(separator: ", ")))")

        // Purgeable space is queried only for writable volumes.
        let samplerCode = repository.lines(
            at: "Sources/Brim/Services/Metrics/DiskSampler.swift")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        suite.expect(!samplerCode.isEmpty, "the disk sampler reads back for its shape check")
        let bulkKeys = samplerCode.components(separatedBy: "let keys: Set<URLResourceKey>")
            .dropFirst().first?.components(separatedBy: "]").first ?? ""
        suite.expect(!bulkKeys.contains("volumeAvailableCapacityForImportantUsageKey")
                && bulkKeys.contains("volumeIsReadOnlyKey"),
               "the bulk volume fetch asks nothing that only a writable volume can answer")
        suite.expect(samplerCode.contains("guard !isReadOnly,"),
               "purgeable space is read only where there is something to purge")

        // Every Strings field that reaches String(format:) is a valid format.
        var formatFields: Set<String> = []
        for path in repository.swiftPaths {
            for piece in repository.source(at: path).components(separatedBy: "String(format:").dropFirst() {
                let head = piece.prefix(120)
                guard let comma = head.firstIndex(of: ",") else { continue }
                let expression = head[head.startIndex..<comma]
                guard let dot = expression.lastIndex(of: ".") else { continue }
                let name = expression[expression.index(after: dot)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    formatFields.insert(name)
                }
            }
        }
        suite.expect(formatFields.count > 10, "the format fields were found to compare (\(formatFields.count))")
        let invalidFormats = Mirror(reflecting: Strings.enUS).children.compactMap { child -> String? in
            guard let label = child.label, formatFields.contains(label),
                  let text = child.value as? String, TestFormat.parse(text) == nil else { return nil }
            return label
        }
        suite.expect(invalidFormats.isEmpty,
               "every format string parses (\(invalidFormats.prefix(5).joined(separator: ", ")))")

        // Every literal SF Symbol name resolves on the test system.
        var symbolNames: Set<String> = []
        for path in repository.swiftPaths {
            for piece in repository.source(at: path).components(separatedBy: "systemName: \"").dropFirst() {
                guard let end = piece.firstIndex(of: "\"") else { continue }
                let name = String(piece[piece.startIndex..<end])
                if !name.isEmpty, !name.contains("\\") { symbolNames.insert(name) }
            }
        }
        suite.expect(symbolNames.count > 50, "the symbol names were found (\(symbolNames.count))")
        var missingSymbols: [String] = []
        for name in symbolNames.sorted()
        where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            missingSymbols.append(name)
        }
        suite.expect(missingSymbols.isEmpty,
               "every symbol the app draws exists (\(missingSymbols.joined(separator: ", ")))")

        // Every literal resource name requested by Swift is shipped or staged
        // by the build.
        var namedResources: Set<String> = []
        for path in repository.swiftPaths {
            let text = repository.source(at: path)
            for marker in ["url(forResource: \"", "path(forResource: \"", "NSImage(named: \""] {
                for piece in text.components(separatedBy: marker).dropFirst() {
                    guard let end = piece.firstIndex(of: "\"") else { continue }
                    let name = String(piece[piece.startIndex..<end])
                    if !name.isEmpty, !name.contains("\\") { namedResources.insert(name) }
                }
            }
        }
        suite.expect(namedResources.count >= 5, "the named resources were found (\(namedResources.count))")
        var shippedNames: Set<String> = []
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: "Resources")) ?? [] {
            let file = (path as NSString).lastPathComponent
            shippedNames.insert((file as NSString).deletingPathExtension)
            shippedNames.insert(file)
        }
        suite.expect(!buildScript.isEmpty, "the build script reads back for its resource names")
        for word in buildScript.components(separatedBy: CharacterSet(charactersIn: " \n\t\"'()")) {
            let file = (word as NSString).lastPathComponent
            guard !file.isEmpty else { continue }
            shippedNames.insert((file as NSString).deletingPathExtension)
            shippedNames.insert(file)
        }
        let absentResources = namedResources.filter { !shippedNames.contains($0) }.sorted()
        suite.expect(absentResources.isEmpty,
               "every file the app asks for by name is in the bundle (\(absentResources.joined(separator: ", ")))")

        // Embedded Finder scripts are compiled only when they run, so verify
        // that every multiline tell/repeat block balances here.
        var unbalancedScripts: [String] = []
        for path in repository.swiftPaths {
            let text = repository.source(at: path)
            for chunk in text.components(separatedBy: "\"\"\"").enumerated()
            where chunk.offset % 2 == 1 && chunk.element.contains("tell application") {
                let body = chunk.element.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                func opens(_ word: String, closing: String, inline: (String) -> Bool) -> Bool {
                    let started = body.filter { $0.hasPrefix(word + " ") && !inline($0) }.count
                    let ended = body.filter { $0 == closing }.count
                    return started != ended
                }
                let name = (path as NSString).lastPathComponent
                if opens("tell", closing: "end tell", inline: { $0.contains(" to ") }) {
                    unbalancedScripts.append("\(name):tell")
                }
                if opens("repeat", closing: "end repeat", inline: { _ in false }) {
                    unbalancedScripts.append("\(name):repeat")
                }
            }
        }
        suite.expect(unbalancedScripts.isEmpty,
               "every embedded script closes what it opens (\(unbalancedScripts.joined(separator: ", ")))")

        // Absolute command-line tool paths embedded in Swift must exist.
        var toolPaths: Set<String> = []
        for path in repository.swiftPaths {
            for piece in repository.source(at: path).components(separatedBy: "\"/").dropFirst() {
                guard let end = piece.firstIndex(of: "\"") else { continue }
                let candidate = "/" + piece[piece.startIndex..<end]
                guard candidate.hasPrefix("/bin/") || candidate.hasPrefix("/usr/bin/")
                        || candidate.hasPrefix("/usr/sbin/") else { continue }
                guard !candidate.contains(" "), !candidate.contains("\\") else { continue }
                toolPaths.insert(candidate)
            }
        }
        suite.expect(toolPaths.count >= 15, "the system tools were found (\(toolPaths.count))")
        let missingTools = toolPaths.sorted().filter {
            !FileManager.default.fileExists(atPath: $0)
        }
        suite.expect(missingTools.isEmpty,
               "every system tool the app runs is where it expects (\(missingTools.joined(separator: ", ")))")

        // MARK: Result

        // MARK: Every temp dir build.sh stages in is swept when the script ends
        // `mktemp -d` lands outside the repo, so a dir the script does not
        // remove survives the run — a successful one as much as a failed one.
        // The sweep is therefore a trap, and a staging dir added later leaks on
        // every build until it is named in cleanup(). The names are read out of
        // the script so the two cannot drift apart.
        // The trap has to be installed before the first dir exists: a failure
        // between `mktemp -d` and a later `trap` leaks exactly as before.
        let sweepInstalled = buildScript.range(of: "trap cleanup EXIT")?.lowerBound
        let firstStaged = buildScript.range(of: "mktemp -d")?.lowerBound
        suite.expect(sweepInstalled != nil && firstStaged != nil && sweepInstalled! < firstStaged!,
               "build.sh installs the temp dir sweep before it stages the first dir")
        // zsh runs the EXIT trap on HUP but not on INT or TERM, so the signals
        // have to reach it through `exit` or Ctrl-C leaks the staged bundle.
        let signalsRouted = buildScript.range(of: "trap 'exit 1' INT TERM HUP")?.lowerBound
        suite.expect(signalsRouted != nil && firstStaged != nil && signalsRouted! < firstStaged!,
               "build.sh routes interrupts through the sweep before it stages the first dir")
        let cleanupBody = buildScript.components(separatedBy: "cleanup() {")
            .dropFirst().first?.components(separatedBy: "\n}").first ?? ""
        let stagedTempDirs = buildScript.components(separatedBy: "=\"$(mktemp -d)\"")
            .dropLast()
            .compactMap {
                $0.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
                    .last.map(String.init)
            }
        suite.expect(!stagedTempDirs.isEmpty, "the staged temp dirs read back out of build.sh")
        // A dir reached through a path suffix — `X="$(mktemp -d)/name"` — puts
        // the parent in no variable at all, which is how the bundle staging dir
        // leaked. Every call has to be captured whole to be sweepable.
        suite.expect(buildScript.components(separatedBy: "mktemp -d").count - 1 == stagedTempDirs.count,
               "every mktemp -d in build.sh is a whole capture — no path suffix, no other spelling")
        for variable in Set(stagedTempDirs) {
            suite.expect(cleanupBody.contains("\"$\(variable)\""),
                   "temp dir \(variable) is swept by build.sh cleanup()")
            // The sweep runs under `set -u` before the dir is staged: an entry
            // whose variable is not empty first aborts cleanup() at that line,
            // leaving everything listed below it unswept and the exit status
            // untouched. The empty assignment is the third line of the pattern.
            // The leading newline keeps ICON_TMP off STAGE_ICON_TMP.
            let initialized = buildScript.range(of: "\n\(variable)=\"\"")?.lowerBound
            suite.expect(initialized != nil && sweepInstalled != nil && initialized! < sweepInstalled!,
                   "temp dir \(variable) is empty before the sweep is installed")
        }

        // BrimForkTests checks the signing contract.

        // MARK: Uninstallation paths stay aligned across SelfUninstall and Tools/uninstall.sh
        let selfUninstallSource = repository.source(
            at: "Sources/Brim/Services/SelfUninstall.swift")
        let uninstallScriptSource = (try? String(contentsOfFile: "Tools/uninstall.sh",
                                                encoding: .utf8)) ?? ""
        suite.expect(!selfUninstallSource.isEmpty && !uninstallScriptSource.isEmpty,
               "uninstall sources read back for uninstallation alignment check")
        suite.expect(!selfUninstallSource.contains("removeInstallationKey")
                && !uninstallScriptSource.contains("delete-generic-password"),
               "uninstalling touches no Keychain item")
        let requiredSubpaths = ["Library/Application Support", "Library/Caches", "Library/HTTPStorages"]
        for subpath in requiredSubpaths {
            suite.expect(selfUninstallSource.contains(subpath) && uninstallScriptSource.contains(subpath),
                   "both in-app and script uninstall sweep \(subpath)")
        }
        suite.expect(uninstallScriptSource.contains("Library/Preferences/ByHost"),
               "script uninstall sweeps ByHost preferences")
        // A key the app no longer writes or clears can only be stale: the
        // removed Space order feature's recovery marker once made the script
        // refuse to uninstall, every time, with nothing left to clear it.
        let defaultsSource = repository.source(at: "Sources/Brim/Core/Defaults.swift")
        let scriptKeys = uninstallScriptSource.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #"defaults read "$BUNDLE" "#) else { return nil }
            return line[range.upperBound...].split(separator: " ").first.map(String.init)
        }
        suite.expect(!scriptKeys.isEmpty && scriptKeys.allSatisfy { defaultsSource.contains("\"\($0)\"") }
                && !uninstallScriptSource.contains("spaces")
                && !uninstallScriptSource.contains("Screen Recording"),
               "script uninstall reads only preference keys the app still defines: \(scriptKeys)")
        // zsh passes a plain string to a command as one word, so the script
        // keeps the closed-lid rule names in an array. They must be the files
        // the app looks for, under the current name and every earlier one.
        func sudoersRuleFiles(_ text: String) -> Set<String> {
            Set(text.components(separatedBy: CharacterSet(charactersIn: " \n\t\"(),"))
                .filter { $0.hasPrefix("/etc/sudoers.d/") })
        }
        let appRuleFiles = sudoersRuleFiles(
            repository.source(at: "Sources/Brim/Services/ShellSupport.swift"))
        let scriptRuleFiles = sudoersRuleFiles(uninstallScriptSource.components(separatedBy: "\n")
            .first { $0.hasPrefix("RULES=(") } ?? "")
        suite.expect(!appRuleFiles.isEmpty && scriptRuleFiles == appRuleFiles,
               "script uninstall looks for the same closed-lid rule files as the app: \(scriptRuleFiles.sorted())")
        // Restoring sleep used to be fired and forgotten at both exits. A
        // failure there leaves `pmset disablesleep 1` set system-wide, and
        // removal deletes the flag that launch-time recovery reads before it
        // reads the setting, so nothing repairs it afterwards — a reinstall
        // included.
        let uninstallerSource = repository.source(
            at: "Sources/Brim/Support/Uninstaller.swift")
        suite.expect(!uninstallerSource.isEmpty,
               "uninstaller entry point reads back for the sleep restore check")
        suite.expect(!selfUninstallSource.contains("_ = Sudoers.pmsetDisableSleep")
                && !uninstallerSource.contains("_ = Sudoers.pmsetDisableSleep"),
               "neither uninstall path discards the result of restoring sleep")
        suite.expect(selfUninstallSource.contains("guard restoreSleepBeforeRemoval() else")
                && selfUninstallSource.contains("guard detachFromSystem() else")
                && selfUninstallSource.contains("restoreSleepBeforeRemoval() -> Bool")
                && selfUninstallSource.contains("guard detachFanControl() else")
                && selfUninstallSource.contains("FanControlService.restoreAndUnregisterForRemoval()")
                && selfUninstallSource.contains("adminPromptRecover")
                && selfUninstallSource.contains("verification.status == 0"),
               "in-app uninstall aborts unless fans and normal sleep are restored before removal")
        suite.expect(uninstallScriptSource.contains("SleepDisabled"),
               "script uninstall reads the sleep setting back for itself")
        suite.expect(selfUninstallSource.contains("PastePlainService.shared.suspend()"),
               "the permission teardown stops the persistent keyboard tap")
    }
}

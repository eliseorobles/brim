// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CryptoKit
import Foundation

/// Brim's own contracts: who it is, that it names neither upstream nor an
/// upstream host, that it ships its own artwork, and how its build signs and
/// installs. Each "Vorssaint" below is deliberate: the credit, or a name the
/// fork must never claim.
///
/// Like every suite, it runs from the repository root.
enum BrimForkTests {
    static func run(_ suite: TestSuite) {
        identity(suite)
        upstreamHosts(suite)
        upstreamName(suite)
        brand(suite)
        buildContract(suite)
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Lines that are not shell comments.
    private static func shellCode(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// The value of `NAME="value"` in a shell file.
    private static func shellValue(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.hasPrefix(name + "=\"") {
            let value = line.dropFirst(name.count + 2)
            return value.firstIndex(of: "\"").map { String(value[..<$0]) }
        }
        return nil
    }

    // MARK: Identity

    private static func identity(_ suite: TestSuite) {
        let saved = BrimIdentity.bundleIdentifier
        defer { BrimIdentity.bundleIdentifier = saved }

        // A bare binary (this runner, `--selftest`) has no bundle ID, and then
        // nothing counts as Brim's: no self-check may claim another app.
        BrimIdentity.bundleIdentifier = nil

        for running in ["com.roblesconsulting.brim", "com.roblesconsulting.brim.dev"] {
            BrimIdentity.bundleIdentifier = running
            suite.expect(BrimIdentity.owns("com.roblesconsulting.brim")
                    && BrimIdentity.owns("com.roblesconsulting.brim.dev")
                    && BrimIdentity.owns("com.roblesconsulting.brim.fan-control")
                    && BrimIdentity.owns("com.roblesconsulting.brim.dev.now-playing")
                    && BrimIdentity.owns("53X2V2R96G.com.roblesconsulting.brim")
                    && BrimIdentity.owns("group.com.roblesconsulting.brim")
                    && BrimIdentity.owns("COM.RoblesConsulting.Brim"),
                   "\(running) owns both builds, their helpers and their containers, in any case")
            suite.expect(!BrimIdentity.owns("com.roblesconsulting.brimstone")
                    && !BrimIdentity.owns("com.roblesconsulting")
                    && !BrimIdentity.owns("com.vorssaint.utils")
                    && !BrimIdentity.owns("com.vorssaint.utils.dev")
                    && !BrimIdentity.owns("brim.tests.switcher.shortcut")
                    && !BrimIdentity.owns("")
                    && !BrimIdentity.owns(nil),
                   "\(running) never claims Vorssaint's IDs or a name that merely starts like its own")
        }

        suite.expect(AppInfo.name == "Brim", "the app calls itself Brim")
        suite.expect(BrimIdentity.upstreamCredit.contains("Vorssaint")
                && BrimIdentity.upstreamCredit.contains("GPL-3.0-or-later"),
               "the About surfaces credit Vorssaint and its license, as the GPL asks")
        suite.expect(Sudoers.rulePath == "/etc/sudoers.d/brim-clamshell",
               "the closed-lid rule is Brim's own file, never upstream's")

        // Tools/identity.sh names the bundles; the Swift side must agree with it.
        let identity = read("Tools/identity.sh")
        suite.expect(!identity.isEmpty, "Tools/identity.sh reads back")
        let release = shellValue("BRIM_RELEASE_BUNDLE_ID", in: identity)
        let developer = shellValue("BRIM_DEVELOPER_BUNDLE_ID", in: identity)
        suite.expect(release == "com.roblesconsulting.brim"
                && developer == (release ?? "") + BrimIdentity.developerSuffix,
               "the Developer bundle ID is the release ID plus the suffix BrimIdentity strips")
        suite.expect(shellValue("BRIM_RELEASE_APP_NAME", in: identity) == AppInfo.name
                && shellValue("BRIM_RELEASE_EXECUTABLE", in: identity) == "Brim"
                && shellValue("BRIM_DEVELOPER_APP_NAME", in: identity) == "Brim (Developer)"
                && shellValue("BRIM_DEVELOPER_EXECUTABLE", in: identity) == "BrimDeveloper",
               "both variants carry Brim's names")
        suite.expect(shellValue("BRIM_COPYRIGHT", in: identity) == AppInfo.copyright,
               "Info.plist's copyright is the one Settings › About shows")
        let team = shellValue("BRIM_TEAM_ID", in: identity)
        let fanControl = read("Sources/Brim/Services/FanControl/FanControlXPC.swift")
        suite.expect(team == "53X2V2R96G"
                && fanControl.contains("static let teamID = \"53X2V2R96G\""),
               "the build signs with the team the fan helper link pins")
    }

    // MARK: Upstream services

    /// No Swift file names an upstream host: every service that talked to
    /// one is gone from the fork.
    private static func upstreamHosts(_ suite: TestSuite) {
        guard let pattern = try? NSRegularExpression(pattern:
                #"vorssaint\.com\b|api\.github\.com/repos|githubusercontent\.com/vorssaint|github\.com/vorssaint|buymeacoffee\.com|discord\.gg/|x\.com/vorssaint"#,
                options: [.caseInsensitive]) else {
            suite.expect(false, "the upstream host pattern compiles")
            return
        }
        var scanned = 0
        var offenders: [String] = []
        let files = FileManager.default.enumerator(atPath: "Sources")?.compactMap { $0 as? String } ?? []
        for file in files where file.hasSuffix(".swift") {
            let path = "Sources/" + file
            let text = read(path)
            scanned += 1
            let range = NSRange(text.startIndex..., in: text)
            if pattern.firstMatch(in: text, range: range) != nil {
                offenders.append(path)
            }
        }
        suite.expect(scanned > 100, "the upstream host scan reads the Swift sources (\(scanned))")
        suite.expect(offenders.isEmpty,
               "no Swift file names an upstream host: \(offenders.sorted())")
    }

    /// Brim calls itself Brim everywhere it ships: no Swift source and no
    /// resource names upstream, in a string, an identifier or a comment. The
    /// exceptions are the GPL notices at the top of upstream's files and
    /// BrimIdentity, which holds the credit the About surfaces show.
    private static func upstreamName(_ suite: TestSuite) {
        let credit = "Sources/Brim/Core/BrimIdentity.swift"
        var scanned = 0
        var offenders: [String] = []
        for root in ["Sources", "Resources"] {
            let files = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []
            for file in files {
                let path = root + "/" + file
                guard path != credit, let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                scanned += 1
                for (index, line) in text.components(separatedBy: "\n").enumerated()
                    where line.range(of: "vorssaint", options: .caseInsensitive) != nil
                        && line.trimmingCharacters(in: .whitespaces) != "// Copyright (C) 2026 Vorssaint" {
                    offenders.append("\(path):\(index + 1)")
                }
            }
        }
        suite.expect(scanned > 100, "the upstream name scan reads Sources and Resources (\(scanned))")
        suite.expect(offenders.isEmpty, "nothing Brim ships names upstream: \(offenders)")
        let creditLines = read(credit).components(separatedBy: "\n")
            .filter { $0.contains("\"") && $0.contains("Vorssaint") }
        suite.expect(creditLines == ["    static let upstreamCredit = \"Based on Vorssaint, GPL-3.0-or-later\""],
               "BrimIdentity's only upstream literal is the credit: \(creditLines)")
        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil)) as? [String: Any]
        suite.expect(plist?["CFBundleIdentifier"] as? String == "com.roblesconsulting.brim"
                && plist?["CFBundleName"] as? String == "Brim"
                && plist?["NSHumanReadableCopyright"] as? String == AppInfo.copyright,
               "the Info.plist template carries the release build's identity")
    }

    /// Resources/Brand, where the app icon, the adaptive icon and the menu bar
    /// glyph come from, holds Brim's artwork and never upstream's.
    private static func brand(_ suite: TestSuite) {
        func sha256(_ path: String) -> String? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        // SHA-256 of upstream's AppIcon-Default.png, logo.png and adaptive-icon mark.
        let upstream: Set<String> = [
            "412a5f35b0ae3967628a893aca37e909e83b1c4454cafe23d4c204347ea5f131",
            "4584a73d3805c6a1d2ba240f7309ba2b1ed41a750f1461c00177fede66f225b2",
            "881c9deae9a2c0bb949a2d1d07a71436eed0491e18026d78bc0f9c281f1e61e6",
        ]
        let files = FileManager.default.enumerator(atPath: "Resources/Brand")?.compactMap { $0 as? String } ?? []
        let hashes = files.compactMap { sha256("Resources/Brand/" + $0) }
        suite.expect(hashes.count >= 4 && upstream.isDisjoint(with: hashes),
               "no file in Resources/Brand is upstream's artwork (\(files.sorted()))")
        let icon = read("Resources/Brand/AppIcon.icon/icon.json")
        suite.expect(icon.contains("\"brim-mark.svg\"")
                && FileManager.default.fileExists(atPath: "Resources/Brand/AppIcon.icon/Assets/brim-mark.svg")
                && FileManager.default.fileExists(atPath: "Resources/Brand/AppIcon-Default.png")
                && FileManager.default.fileExists(atPath: "Resources/Brand/logo.png"),
               "the adaptive icon draws Brim's mark, and the icon and glyph masters are in place")
        let makeIcon = read("Tools/MakeIcon.swift")
        let makeBrand = read("Tools/MakeBrimBrand.swift")
        suite.expect(makeIcon.contains("\"Resources/Brand/logo.png\"") && makeIcon.contains("\"Resources/Brand/AppIcon-Default.png\"")
                && makeBrand.contains("appendingPathComponent(\"Resources/Brand\")"),
               "the icon build reads Resources/Brand, which Tools/MakeBrimBrand.swift writes")
    }

    // MARK: Build

    private static func buildContract(_ suite: TestSuite) {
        let build = read("build.sh")
        suite.expect(!build.isEmpty, "build.sh reads back")
        let buildCode = shellCode(build)
        suite.expect(buildCode.contains { $0.trimmingCharacters(in: .whitespaces) == "source Tools/identity.sh" },
               "build.sh takes both variants' names from Tools/identity.sh")

        // The build compiles the checkout itself: no rewritten copy of the tree.
        suite.expect(!build.contains("brim-src") && !build.contains("rebrand") && !build.contains("Brim/build.zsh")
                && !FileManager.default.fileExists(atPath: "Brim/tools")
                && !FileManager.default.fileExists(atPath: "Brim/build.zsh"),
               "there is no rewritten source tree, rewriter or second build script")

        // Signing never creates a keychain or rewrites the search list; upstream's
        // self-signed identity and its setup script are gone.
        suite.expect(!FileManager.default.fileExists(atPath: "Tools/setup-signing.sh"),
               "there is no script that creates a signing keychain")
        for forbidden in ["create-keychain", "list-keychains", "unlock-keychain", "default-keychain",
                          "delete-keychain", "LEGACY_IDENTITY", "setup-signing"] {
            suite.expect(!buildCode.contains { $0.contains(forbidden) }, "build.sh never uses \(forbidden)")
        }
        suite.expect(buildCode.contains { $0.contains("OU=$BRIM_TEAM_ID") }
                && buildCode.contains { $0.contains("BRIM_SIGN_IDENTITY") }
                && buildCode.contains { $0.contains("certificate leaf[subject.OU] = \\\"$BRIM_TEAM_ID\\\"") },
               "the identity is the one BRIM_SIGN_IDENTITY names or one of Brim's team, and each signature is checked against it")

        // Installing touches only this variant's app, found by its full path.
        suite.expect(!buildCode.contains { $0.contains("pkill") || $0.contains("Vorss:Vorss") },
               "install never stops a process by name or removes upstream's apps")
        suite.expect(!buildCode.contains { $0.contains("hw.logicalcpu") }
                && buildCode.filter { $0.contains("-j \"$BRIM_JOBS\"") }.count == 2,
               "both compiles cap their jobs with BRIM_JOBS")
        suite.expect(buildCode.contains { $0.trimmingCharacters(in: .whitespaces) == "Sources/Brim/Core/BrimIdentity.swift" },
               "the test binary compiles Sources/Brim/Core/BrimIdentity.swift")
        suite.expect(buildCode.contains { $0.contains("-module-name BrimTests") },
               "the test module is BrimTests")
    }
}

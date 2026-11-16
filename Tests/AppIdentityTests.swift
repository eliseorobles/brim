// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// The identity an app list stores for a picked or running program, and the
/// installed and running app rows the keep-awake automation and clipboard
/// ignore lists offer.
enum AppIdentityTests {
    static func run(_ suite: TestSuite) {
        suite.expect(Defaults.sanitizedBundleIdentifierList(["  com.example.a  ", "", "com.example.a", "com.example.b"])
                == ["com.example.a", "com.example.b"],
               "an app list drops blanks, spaces and repeats")

        // A program started from a launcher — the Java process behind a game
        // is the reported one — has no bundle identifier at all, so the file
        // being run stands in as its identity (issue #1009). An app that has
        // an identifier keeps answering only to that, so nothing already
        // listed changes meaning.
        suite.expect(AppIdentity.identity(bundleID: "com.example.modeler",
                                                 executablePath: "/Applications/Modeler.app/Contents/MacOS/Modeler")
                == "com.example.modeler",
               "an app with a bundle identifier answers to it and not to its executable")
        suite.expect(AppIdentity.identity(bundleID: nil,
                                                 executablePath: "/opt/game/runtime/bin/java")
                == "/opt/game/runtime/bin/java",
               "a program with no bundle identifier answers to the file being run")
        suite.expect(AppIdentity.identity(bundleID: nil, executablePath: nil) == nil
                && AppIdentity.identity(bundleID: nil, executablePath: "java") == nil,
               "a program with nothing to be named by is never listed by accident")
        suite.expect(AppIdentity.isExecutablePathIdentity("/opt/game/runtime/bin/java")
                && !AppIdentity.isExecutablePathIdentity("com.example.modeler"),
               "a stored path is told from a bundle identifier by its leading slash")
        suite.expect(InstalledApps.name(for: "/opt/game/runtime/bin/java") == "java",
               "a listed program path is shown by its file name, not the whole path")

        // The stored path is the one the file sheet handed back and the
        // matched one is the file the running program reports, and the same
        // file arrives at the two ends under different names as soon as
        // anything on the way is a link — measured on this Mac, the sheet
        // answers /private/tmp/… for a file the running program answers
        // /tmp/… for. Both ends resolve, so they meet.
        let identityRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-identity-\(getpid())", isDirectory: true)
        let runtimeBinary = identityRoot.appendingPathComponent("runtime/bin/launcher")
        try? FileManager.default.createDirectory(at: runtimeBinary.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runtimeBinary.path, contents: Data())
        let linkedBinary = identityRoot.appendingPathComponent("launcher")
        try? FileManager.default.createSymbolicLink(at: linkedBinary, withDestinationURL: runtimeBinary)
        let pickedThroughLink = AppIdentity.executablePathIdentity(linkedBinary.path)
        let reportedByTheSystem = AppIdentity.identity(bundleID: nil,
                                                                    executablePath: runtimeBinary.path)
        suite.expect(pickedThroughLink != nil
                && pickedThroughLink != linkedBinary.path
                && pickedThroughLink == reportedByTheSystem,
               "a program picked through a link stores the file it links to")

        // A file sheet that takes programs can be walked into a bundle, and
        // what is stored has to be what the system will report once the file
        // runs. Measured on this Mac: a bundle's own executable run straight
        // from disk is reported as com.example.withid, while a runtime shipped
        // deeper in that same bundle — the shape issue #1009 is about — is
        // reported with no identifier and stays a path. Filing that runtime
        // under the app above it would break the case this all exists for.
        func makeTestBundle(_ name: String, identifier: String?) -> URL {
            let bundle = identityRoot.appendingPathComponent("\(name).app")
            for file in ["Contents/MacOS/\(name)", "Contents/runtime/bin/java"] {
                let url = bundle.appendingPathComponent(file)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            var info: [String: Any] = ["CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
            if let identifier { info["CFBundleIdentifier"] = identifier }
            if let plist = try? PropertyListSerialization.data(fromPropertyList: info,
                                                               format: .xml,
                                                               options: 0) {
                try? plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            }
            return bundle
        }
        let namedBundle = makeTestBundle("Modeler", identifier: "com.example.modeler")
        let namelessBundle = makeTestBundle("Bare", identifier: nil)
        suite.expect(AppIdentity.pickedIdentity(for: namedBundle) == "com.example.modeler"
                && AppIdentity.pickedIdentity(
                    for: namedBundle.appendingPathComponent("Contents/MacOS/Modeler"))
                    == "com.example.modeler",
               "an app is stored by its identifier whether its bundle or the binary inside it was picked")
        let bundledRuntime = namedBundle.appendingPathComponent("Contents/runtime/bin/java")
        suite.expect(AppIdentity.pickedIdentity(for: bundledRuntime)
                == AppIdentity.executablePathIdentity(bundledRuntime.path),
               "a runtime shipped inside an app keeps its own path, never the identifier of the app above it")
        suite.expect(AppIdentity.pickedIdentity(for: namelessBundle)
                == AppIdentity.executablePathIdentity(
                    namelessBundle.appendingPathComponent("Contents/MacOS/Bare").path),
               "an app whose Info.plist names no identifier is stored by the binary it runs")
        suite.expect(AppIdentity.pickedIdentity(for: runtimeBinary)
                == AppIdentity.executablePathIdentity(runtimeBinary.path),
               "a program that is not packaged as an app is stored by its own file")
        try? FileManager.default.removeItem(at: identityRoot)

        // The list sanitizer runs over stored entries, and a file name may
        // legally end in a space: trimming a path would look for a spelling
        // the running program never reports, so only an identifier is trimmed.
        suite.expect(Defaults.sanitizedBundleIdentifierList(["/opt/game/bin/java ", " com.example.a "])
                == ["/opt/game/bin/java ", "com.example.a"],
               "a stored path keeps its exact file name while an identifier is trimmed")

        suite.expect(InstalledApps.location(for: "com.example.modeler") == nil,
               "a bundle identifier names its app on its own and carries no location")
        suite.expect(InstalledApps.location(for: NSHomeDirectory() + "/runtimes/zulu-8.jre/bin/java")
                == "~/runtimes/zulu-8.jre/bin",
               "a path identity is located by its directory, spelled from home")
        suite.expect(InstalledApps.location(for: "/opt/game/bin/java") == "/opt/game/bin",
               "a path outside home keeps its absolute directory")

        // Running programs that are not packaged as apps (issue #865): a bare
        // executable run under .regular activation policy (e.g. a game
        // launcher's runtime process) answers to its resolved file path when it
        // has no bundle identifier, while an ordinary .app bundle keeps its
        // bundle row and background/accessory processes stay excluded.
        let runningTestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-running-\(getpid())", isDirectory: true)
        let runningTargetBinary = runningTestRoot.appendingPathComponent("bin/java")
        let runningSymlinkBinary = runningTestRoot.appendingPathComponent("bin/java_link")
        try? FileManager.default.createDirectory(at: runningTargetBinary.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runningTargetBinary.path, contents: Data())
        try? FileManager.default.createSymbolicLink(at: runningSymlinkBinary, withDestinationURL: runningTargetBinary)
        let resolvedRunningPath = AppIdentity.executablePathIdentity(runningTargetBinary.path)

        let regularBareApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: nil,
            bundleURL: runningSymlinkBinary,
            executableURL: runningSymlinkBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        if let regularBareApp, let resolvedRunningPath {
            suite.expect(regularBareApp.identity == resolvedRunningPath
                    && regularBareApp.bundleID == nil
                    && regularBareApp.name == "java"
                    && regularBareApp.url.path == resolvedRunningPath,
                   "a running regular bare executable produces a path row with its resolved path identity")
        } else {
            suite.expect(false, "a running regular bare executable resolves its path row setup")
        }

        let runningWrapper = runningTestRoot.appendingPathComponent("zulu-8.jre", isDirectory: true)
        let runningWrapperBinary = runningWrapper.appendingPathComponent("bin/java")
        try? FileManager.default.createDirectory(at: runningWrapperBinary.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runningWrapperBinary.path, contents: Data())
        let wrapperBareApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: nil,
            bundleURL: runningWrapper,
            executableURL: runningWrapperBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        let resolvedWrapperPath = AppIdentity.executablePathIdentity(runningWrapperBinary.path)
        if let wrapperBareApp, let resolvedWrapperPath {
            suite.expect(wrapperBareApp.identity == resolvedWrapperPath
                    && wrapperBareApp.bundleID == nil
                    && wrapperBareApp.url.path == resolvedWrapperPath,
                   "a running executable inside a non-app wrapper produces a path row")
        } else {
            suite.expect(false, "a non-app wrapper executable resolves its path row setup")
        }

        let appBundleURL = URL(fileURLWithPath: "/Applications/TextEdit.app")
        let regularBundleApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: "com.apple.TextEdit",
            bundleURL: appBundleURL,
            executableURL: appBundleURL.appendingPathComponent("Contents/MacOS/TextEdit"),
            localizedName: "TextEdit",
            acceptsExecutables: true
        )
        suite.expect(regularBundleApp != nil
                && regularBundleApp?.identity == "com.apple.TextEdit"
                && regularBundleApp?.bundleID == "com.apple.TextEdit"
                && regularBundleApp?.url == appBundleURL
                && regularBundleApp?.name == "TextEdit",
               "a running regular app bundle produces an unchanged bundle row")

        let accessoryBareApp = InstalledApps.runningApplication(
            activationPolicy: .accessory,
            bundleID: nil,
            bundleURL: nil,
            executableURL: runningTargetBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        let prohibitedBareApp = InstalledApps.runningApplication(
            activationPolicy: .prohibited,
            bundleID: nil,
            bundleURL: nil,
            executableURL: runningTargetBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        suite.expect(accessoryBareApp == nil && prohibitedBareApp == nil,
               "an accessory or prohibited bare executable is ignored")

        let embeddedBundleBareApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: "com.example.embedded",
            bundleURL: nil,
            executableURL: runningTargetBinary,
            localizedName: "embedded_tool",
            acceptsExecutables: true
        )
        suite.expect(embeddedBundleBareApp != nil
                && embeddedBundleBareApp?.identity == "com.example.embedded"
                && embeddedBundleBareApp?.bundleID == "com.example.embedded"
                && embeddedBundleBareApp?.identity != runningTargetBinary.path,
               "a bare executable that reports a bundle identifier uses that identifier and not its path")

        let duplicateProcessApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: nil,
            bundleURL: nil,
            executableURL: runningTargetBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        if let regularBareApp, let duplicateProcessApp, let resolvedRunningPath {
            let deduplicated = InstalledApps.deduplicatedAndFiltered(
                [regularBareApp, duplicateProcessApp],
                excluding: []
            )
            suite.expect(deduplicated.count == 1
                    && deduplicated.first?.identity == resolvedRunningPath,
                   "duplicate processes with the same path identity collapse to one entry")

            let excludedPathApps = InstalledApps.deduplicatedAndFiltered(
                [regularBareApp],
                excluding: [resolvedRunningPath]
            )
            let unexcludedPathApps = InstalledApps.deduplicatedAndFiltered(
                [regularBareApp],
                excluding: ["/other/path/java"]
            )
            suite.expect(excludedPathApps.isEmpty && unexcludedPathApps.count == 1,
                   "an exclusion set containing a path identity drops that program")
        } else {
            suite.expect(false, "running path identities resolve before they are deduplicated or excluded")
        }

        let reverseJavaApps = InstalledApps.deduplicatedAndFiltered([
            InstalledApps.InstalledApp(id: "/runtimes/zulu/bin/java",
                                       name: "java",
                                       bundleID: nil,
                                       url: URL(fileURLWithPath: "/runtimes/zulu/bin/java"),
                                       isSystem: false,
                                       explicitIdentity: "/runtimes/zulu/bin/java"),
            InstalledApps.InstalledApp(id: "/runtimes/temurin/bin/java",
                                       name: "java",
                                       bundleID: nil,
                                       url: URL(fileURLWithPath: "/runtimes/temurin/bin/java"),
                                       isSystem: false,
                                       explicitIdentity: "/runtimes/temurin/bin/java")
        ], excluding: [])
        suite.expect(reverseJavaApps.compactMap(\.identity) == ["/runtimes/temurin/bin/java", "/runtimes/zulu/bin/java"],
               "same-named executable rows sort by identity")

        let unacceptedBareApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: nil,
            bundleURL: nil,
            executableURL: runningTargetBinary,
            localizedName: "java",
            acceptsExecutables: false
        )
        suite.expect(unacceptedBareApp == nil,
               "a bare executable is omitted when the caller does not accept executables")

        let emptyIdentifierBareApp = InstalledApps.runningApplication(
            activationPolicy: .regular,
            bundleID: "",
            bundleURL: runningSymlinkBinary,
            executableURL: runningSymlinkBinary,
            localizedName: "java",
            acceptsExecutables: true
        )
        suite.expect(emptyIdentifierBareApp == nil,
               "an empty bundle identifier is dropped, as the taps would never match it")

        try? FileManager.default.removeItem(at: runningTestRoot)

        // The picker lives outside this binary and stores from AppBundleList.
        // An identity taken raw there silently matches nothing (issue #1009),
        // so what it may hand on is pinned rather than the spelling it happens
        // to use today — a second way into the list, dropping a file onto it
        // among them, has to go through the same resolver as the sheet does.
        let pickerLines = ((try? String(
            contentsOfFile: "Sources/Brim/UI/Settings/AppBundleList.swift",
            encoding: .utf8)) ?? "").components(separatedBy: "\n")
        var resolvedAddSites: [String] = []
        var rawAddSites: [String] = []
        for (index, line) in pickerLines.enumerated()
        where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("onAdd(") {
            let added = (line.components(separatedBy: "onAdd(").last?
                .components(separatedBy: ")").first ?? "").trimmingCharacters(in: .whitespaces)
            let nearbyLines = pickerLines[..<index].suffix(4)
            if nearbyLines.contains(where: {
                $0.contains("let \(added) =") && $0.contains("AppIdentity.")
            }) {
                resolvedAddSites.append("AppBundleList.swift:\(index + 1)")
            } else {
                rawAddSites.append("AppBundleList.swift:\(index + 1) adds \(added)")
            }
        }
        suite.expect(!resolvedAddSites.isEmpty && rawAddSites.isEmpty,
               "every value the picker adds is one AppIdentity resolved: \(rawAddSites)")

        // A list row's location caption is what tells path identities apart —
        // every bundled runtime displays as "java" (issue #1009) — and sibling
        // runtimes differ only after a long shared directory prefix, so the
        // caption must truncate from the HEAD: cutting the middle or tail
        // would hide the one component that differs. Neither picker is
        // compiled into this binary, so their shapes are pinned here.
        let appPickerLines = ((try? String(
            contentsOfFile: "Sources/Brim/UI/Uninstall/AppPickerView.swift",
            encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let captionPickerLines = ["AppBundleList.swift": pickerLines,
                                  "AppPickerView.swift": appPickerLines]
        var captionFiles: [String] = []
        for (file, lines) in captionPickerLines {
            let sourceLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if sourceLines.contains(where: { $0.contains("InstalledApps.location(for:") })
                && sourceLines.contains(where: { $0.contains(".truncationMode(") && $0.contains(".head") }) {
                captionFiles.append(file)
            }
        }
        suite.expect(captionFiles.count == captionPickerLines.count,
               "each path identity picker shows where its file sits and truncates from the head: "
                   + "\(captionFiles)")

        // The leading-slash test IS the rule that tells a stored path from a
        // bundle identifier. A second spelling of it drifts the day the rule
        // learns a new shape — a ~ path, a file URL — so every file that
        // handles an identity asks isExecutablePathIdentity instead of
        // re-testing the prefix.
        var slashRuleSites: [String] = []
        for file in ["Services/InstalledApps.swift", "Core/Defaults.swift"] {
            let ruleLines = ((try? String(contentsOfFile: "Sources/Brim/\(file)",
                                          encoding: .utf8)) ?? "").components(separatedBy: "\n")
            if ruleLines.count <= 1 { slashRuleSites.append("\(file) unreadable") }
            for (index, line) in ruleLines.enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && line.contains("hasPrefix(\"/\")") {
                slashRuleSites.append("\(file):\(index + 1)")
            }
        }
        suite.expect(slashRuleSites.count == 1
                && slashRuleSites[0].hasPrefix("Services/InstalledApps.swift:"),
               "the leading-slash rule is spelled once, inside isExecutablePathIdentity: \(slashRuleSites)")
    }
}

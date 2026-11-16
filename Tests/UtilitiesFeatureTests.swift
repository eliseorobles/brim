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

enum UtilitiesFeatureTests {
    static func run(_ suite: TestSuite) {
        // MARK: Port manager parser

        let lsofFixture = """
        p123
        cExample Server
        PTCP
        n127.0.0.1:3000
        n127.0.0.1:3000
        n[::1]:3000
        n*:3001
        p456
        cOther Server
        PTCP
        n*:3000
        """
        let parsedPorts = PortManagerSupport.parseLsof(lsofFixture)
        suite.expect(parsedPorts.map(\.port) == [3000, 3000, 3000, 3001],
               "port parser keeps every distinct listening endpoint and removes exact duplicates")
        suite.expect(parsedPorts.filter { $0.pid == 123 }.count == 3,
               "port parser keeps multiple ports and address families for one process")

        let invalidEndpointFixture = """
        p789
        cNo Port Process
        PTCP
        n*:4000
        n127.0.0.1
        """
        let parsedInvalid = PortManagerSupport.parseLsof(invalidEndpointFixture)
        suite.expect(parsedInvalid.count == 1 && parsedInvalid.first?.port == 4000,
               "port parser ignores address lines that lack a port instead of pairing with previous port")

        // MARK: Port manager all-interfaces marker (issue #1785)

        let exposedFixture = """
        p321
        cDev Server
        PTCP
        n*:5173
        n0.0.0.0:8000
        n[::]:8001
        n127.0.0.1:8002
        n[::1]:8003
        n192.168.1.20:8004
        n[fe80::1]:8005
        """
        let exposed = Dictionary(uniqueKeysWithValues: PortManagerSupport.parseLsof(exposedFixture)
            .map { ($0.port, PortManagerSupport.listensOnAllInterfaces($0.address)) })
        suite.expect(exposed[5173] == true && exposed[8000] == true && exposed[8001] == true,
               "wildcard IPv4 and IPv6 binds from lsof are marked as listening on all interfaces")
        suite.expect(exposed[8002] == false && exposed[8003] == false,
               "loopback binds stay unmarked because only this Mac can reach them")
        suite.expect(exposed[8004] == false && exposed[8005] == false,
               "a bind to one specific address is not reported as all interfaces")
        suite.expect(!PortManagerSupport.listensOnAllInterfaces("*")
                && !PortManagerSupport.listensOnAllInterfaces(":80")
                && !PortManagerSupport.listensOnAllInterfaces(""),
               "an endpoint without a host part is not marked")

        // MARK: Port manager browser destinations (issue #1787)

        for (address, expected) in [
            ("*:3000", "http://localhost:3000"),
            ("0.0.0.0:3000", "http://127.0.0.1:3000"),
            ("[::]:3000", "http://[::1]:3000"),
            ("127.0.0.1:3000", "http://127.0.0.1:3000"),
            ("[::1]:3000", "http://[::1]:3000"),
            ("192.168.1.20:3000", "http://192.168.1.20:3000"),
            ("[fe80::1%en0]:3000", "http://[fe80::1%25en0]:3000"),
        ] {
            let entries = PortManagerSupport.parseLsof("p321\ncServer\nPTCP\nn\(address)\n")
            suite.expect(entries.first.flatMap { PortManagerSupport.browserURL(for: $0) }?.absoluteString == expected,
                   "opening \(address) uses a reachable HTTP destination and preserves IPv6 scope")
        }
        let udp = PortManagerSupport.parseLsof("p321\ncServer\nPUDP\nn*:5353\n")
        suite.expect(udp.count == 1 && udp.first.flatMap { PortManagerSupport.browserURL(for: $0) } == nil,
               "UDP rows retain copy actions but have no browser destination")
        for (address, port) in [("", 3000), ("127.0.0.1", 3000), (":3000", 3000), ("*:0", 0), ("*:65536", 65536)] {
            let entry = PortManagerEntry(port: port, protocolName: "TCP", address: address,
                                         pid: 321, processName: "Server", startedAt: nil)
            suite.expect(PortManagerSupport.browserURL(for: entry) == nil,
                   "an incomplete endpoint or invalid port has no browser destination")
        }

        for lang in AppLanguage.allCases {
            let strings = FeatureStrings.portManager(lang)
            suite.expect(!strings.copyPort.isEmpty && !strings.copyAddress.isEmpty,
                   "port row copy actions have labels in \(lang)")
            suite.expect(!strings.hubDescription.isEmpty,
                   "port manager has a non-empty hub description for \(lang)")
            suite.expect(!strings.allInterfaces.isEmpty && !strings.allInterfacesHelp.isEmpty
                   && !strings.allInterfaces.contains("\u{2014}")
                   && !strings.allInterfacesHelp.contains("\u{2014}"),
                   "the all-interfaces marker is labelled and explained in \(lang)")
            if lang != .enUS {
                suite.expect(strings.allInterfaces != PortManagerFeatureStrings.enUS.allInterfaces,
                       "the all-interfaces marker is translated for \(lang)")
            }
        }
        suite.expect(Defaults.registeredDefaults[DefaultsKey.panelUtilityPortManager] as? Bool == true,
               "the port manager panel row ships visible like its siblings")

        // MARK: Port manager row numbers

        // An integer interpolated into Text("…") is formatted for the locale, so
        // port 5173 read "5,173" in English and "5.173" in Portuguese.
        for path in ["Sources/Brim/UI/PortManager/PortManagerView.swift",
                     "Sources/Brim/UI/MenuPanel/PanelPortManagerView.swift"] {
            let rowSource = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            suite.expect(rowSource.contains("Text(String(entry.port))")
                   && !rowSource.contains("\\(entry.port)") && !rowSource.contains("\\(entry.pid)"),
                   "\(path) shows ports and PIDs without a thousands separator")
        }

        // MARK: Disk eject

        suite.expect(DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: true,
                                                    isEjectable: false, isLocal: true,
                                                    isRootFileSystem: false)
                && DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: false,
                                                        isEjectable: true, isLocal: true,
                                                        isRootFileSystem: false),
               "external removable or ejectable local volumes are offered")
        suite.expect(DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: false,
                                                    isEjectable: false, isLocal: true,
                                                    isRootFileSystem: false),
               "an external drive with fixed media is offered, the common desk drive")
        suite.expect(DiskEjectSupport.shouldOfferEject(isInternal: true, isRemovable: true,
                                                    isEjectable: true, isLocal: true,
                                                    isRootFileSystem: false),
               "media that comes out of an internal reader is offered")
        suite.expect(!DiskEjectSupport.shouldOfferEject(isInternal: true, isRemovable: false,
                                                     isEjectable: false, isLocal: true,
                                                     isRootFileSystem: false),
               "internal fixed drives are never ejected")
        suite.expect(!DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: true,
                                                     isEjectable: true, isLocal: false,
                                                     isRootFileSystem: false),
               "network volumes are never ejected")
        suite.expect(!DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: true,
                                                     isEjectable: true, isLocal: true,
                                                     isRootFileSystem: true),
               "the volume the Mac booted from is never ejected, even on an external drive")
        suite.expect(!DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: false,
                                                     isEjectable: true, isLocal: true,
                                                     isRootFileSystem: false,
                                                     volumeName: "Time Machine",
                                                     excludedVolumes: ["time machine"]),
               "a volume matching an excluded name case-insensitively is not offered for eject")
        suite.expect(!DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: true,
                                                     isEjectable: true, isLocal: true,
                                                     isRootFileSystem: false,
                                                     volumeName: "SD Card",
                                                     volumeUUID: "1234-5678-ABCD",
                                                     excludedVolumes: ["1234-5678-abcd"]),
               "a volume matching an excluded UUID is not offered for eject")
        suite.expect(DiskEjectSupport.shouldOfferEject(isInternal: false, isRemovable: true,
                                                    isEjectable: true, isLocal: true,
                                                    isRootFileSystem: false,
                                                    volumeName: "USB Flash",
                                                    excludedVolumes: ["Time Machine"]),
               "a volume not on the exclusion list is offered for eject")
        suite.expect(Defaults.sanitizedDiskExclusionList(["  Backup  ", "backup", "", "  ", "Photos", "PHOTOS"])
                == ["Backup", "Photos"],
               "sanitized disk exclusion list trims and deduplicates case-insensitively")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.diskEjectExcludedVolumes] is [String],
               "disk eject exclusions are registered as an empty string array")

        // MARK: A dropped identifier
        suite.expect(DiskEjectSupport.isExcluded(volumeName: "SD Card",
                                              volumeUUID: "1234-5678-ABCD",
                                              mountPath: "/Volumes/SD Card",
                                              excludedVolumes: ["1234-5678-abcd"])
                && !DiskEjectSupport.isExcluded(volumeName: "SD Card",
                                                   volumeUUID: nil,
                                                   mountPath: "/Volumes/SD Card",
                                                   excludedVolumes: ["1234-5678-abcd"]),
               "an excluded volume UUID is honoured only when the caller hands the UUID over")
        let diskExclusionsListCode = ((try? String(
            contentsOfFile: "Sources/Brim/UI/Settings/DiskExclusionsList.swift",
            encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        suite.expect(diskExclusionsListCode.contains(".volumeUUIDStringKey")
                && diskExclusionsListCode.contains("DiskEjectSupport.isExcluded("),
               "the exclusions picker asks the shared exclusion test, UUID included, not a name-only one")

    }
}

extension UtilitiesFeatureTests {
    static func killProcessStringChecks(_ suite: TestSuite) {
        // A count in front of a noun makes the noun agree with it, and one
        // string cannot hold every form, so the count goes last behind a label.
        for language in AppLanguage.allCases {
            let processes = FeatureStrings.killProcess(language).processCountFormat
            suite.expect(!processes.hasPrefix("%d"),
                   "the process count does not put a bare number in front of a noun in \(language.rawValue)")
        }
    }
}

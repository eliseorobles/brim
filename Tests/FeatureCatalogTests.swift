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

enum FeatureCatalogTests {
    static func run(_ suite: TestSuite) {
        func expectFormat(_ format: String, _ expected: [String], _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) {
            let actual = TestFormat.parse(format)?.conversions ?? ["invalid format"]
            suite.expect(actual == expected, "\(label): got \(actual), expected \(expected)",
                         file: file, line: line)
        }
        // MARK: Features hub catalog

        suite.expect(AppFeature.allCases.count == 19, "feature catalog has 19 features")
        suite.expect(Set(AppFeature.allCases.map(\.rawValue)).count == AppFeature.allCases.count,
               "feature ids are unique")
        suite.expect(AppFeature.allCases.map(\.rawValue) == [
            "clipboardHistory", "pastePlain", "keepAwake",
            "cleaner", "uninstaller", "homebrew", "appUpdates", "killProcess", "portManager",
            "notch", "notchAgents",
            "monitorCPU", "monitorGPU", "monitorMemory", "monitorNetwork", "monitorDisk", "monitorPower",
            "connectedDevices", "fanControl",
        ], "feature ids are stable (they persist inside availability keys)")

        let installSuiteName = "brim.tests.feature-install.\(UUID().uuidString)"
        if let installDefaults = UserDefaults(suiteName: installSuiteName) {
            func savedValues() -> [String: Any] {
                installDefaults.persistentDomain(forName: installSuiteName) ?? [:]
            }
            for feature in AppFeature.allCases where !feature.enabledKeys.isEmpty {
                feature.enableOnFirstInstall(in: installDefaults, savedValues: savedValues())
                suite.expect(feature.enabledKeys.contains {
                    savedValues()[$0] as? Bool == true
                }, "a new \(feature.rawValue) install saves an enabled main control")
                for key in feature.enabledKeys { installDefaults.removeObject(forKey: key) }
            }
            installDefaults.removePersistentDomain(forName: installSuiteName)
        } else {
            suite.expect(false, "feature install defaults suite can be created")
        }
        let runtimeSource = (try? String(contentsOfFile: "Sources/Brim/App/FeatureRuntime.swift",
                                         encoding: .utf8)) ?? ""
        suite.expect(runtimeSource.contains(
            "setAvailable(AppFeature.allCases, available, enablingFirstInstalls: false)"),
               "install all makes features available without switching on their behavior")

        // Most updating installs never saved an availability, so this list is
        // what they have: a feature leaving it would vanish for all of them.
        let installedOnUpdate: Set<String> = [
            "clipboardHistory", "pastePlain", "keepAwake",
            "cleaner", "uninstaller", "homebrew", "appUpdates",
            "notch", "notchAgents",
            "monitorCPU", "monitorGPU", "monitorMemory", "monitorNetwork", "monitorDisk", "monitorPower",
            "connectedDevices",
        ]
        suite.expect(AppFeature.availabilityDefaults.count == AppFeature.allCases.count
                && Set(AppFeature.allCases.filter {
                    (AppFeature.availabilityDefaults[$0.availabilityKey] as? Bool) == true
                }.map(\.rawValue)) == installedOnUpdate
                && AppFeature.allCases.allSatisfy {
                    AppFeature.availabilityDefaults[$0.availabilityKey] as? Bool == $0.installedByDefault
                },
               "every feature an update already had stays installed and every other one ships uninstalled")

        suite.expect(FeatureGroup.allCases.map { AppFeature.features(in: $0).count }.reduce(0, +)
                == AppFeature.allCases.count,
               "every feature belongs to exactly one group")
        suite.expect(!FeatureGroup.allCases.contains { AppFeature.features(in: $0).isEmpty },
               "no hub group is empty")
        suite.expect(AppFeature.features(in: .dynamicIsland) == [.notch, .notchAgents],
               "the Dynamic Island heads its own hub section, followed by its AI agents page")
        // AI agents also runs Claude accounts and the panel's Claude section
        // without the island, so uninstalling or unticking the island must
        // never take it along.
        let hubSource = (try? String(contentsOfFile: "Sources/Brim/UI/Settings/FeatureHubSettings.swift",
                                     encoding: .utf8)) ?? ""
        let pickerSource = (try? String(contentsOfFile: "Sources/Brim/UI/Onboarding/OnboardingView.swift",
                                        encoding: .utf8)) ?? ""
        suite.expect(!hubSource.isEmpty && !pickerSource.isEmpty
                && hubSource.contains("FeatureRuntime.shared.setAvailable([feature], install)")
                && !pickerSource.contains("subtract("),
               "uninstalling the island changes only the island; AI agents stays as it is")
        suite.expect(AppPermission.allCases.map(\.rawValue) == [
            "accessibility", "fullDiskAccess", "filesAndFolders", "notifications",
            "automationFinder", "appManagement",
        ], "permission portal contains every supported permission")
        let onboardingViewSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Onboarding/OnboardingView.swift",
            encoding: .utf8)) ?? ""
        suite.expect(onboardingViewSource.contains("let features = Set(AppFeature.allCases.filter(\\.isAvailable))")
                && onboardingViewSource.contains("_selectedFeatures = State(initialValue: features)"),
               "the first setup screen starts with the prepared features, including the settings file's selections")
        let additionalPermissionsAlignment =
            #"DisclosureGroup\(isExpanded: \$showingOtherPermissions\) \{\s+"#
            + #"VStack\(alignment: \.leading, spacing: 14\)"#
        suite.expect(onboardingViewSource.range(
            of: additionalPermissionsAlignment,
            options: .regularExpression) != nil,
               "the additional onboarding permission rows share one leading edge")
        suite.expect(FeaturePreset.essential.features.flatMap(\.onboardingPermissions).isEmpty,
               "the essential first-run choice asks for no broad permission")
        suite.expect(AppFeature.cleaner.onboardingPermissions.isEmpty,
               "contextual grants are not requested during first setup")
        suite.expect(AppFeature.fanControl.group == .monitor
                && AppFeature.fanControl.enabledKeys.isEmpty
                && AppFeature.fanControl.permissions.isEmpty
                && AppFeature.fanControl.energyProfile == .idle
                && AppFeature.fanControl.isBeta
                && !AppFeature.monitorPower.isBeta,
               "fan control is an on-demand beta with no broad permission")

        // MARK: Hardware-gated installs

        suite.expect(FeaturePreset.allCases.allSatisfy { !$0.features.contains(.fanControl) },
               "no first-run preset installs a feature whose hardware the Mac may lack")

        let featureHubSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Settings/FeatureHubSettings.swift",
            encoding: .utf8)) ?? ""
        let onboardingFeatureSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Onboarding/OnboardingView.swift",
            encoding: .utf8)) ?? ""
        suite.expect(featureHubSource.contains("installBlockedReason")
                && onboardingFeatureSource.contains("installBlockedReason"),
               "both feature pickers refuse an unsupported install from the same rule")
        suite.expect(featureHubSource.contains("installableCount"),
               "the hub counts against what this Mac can install, so install-all can finish")
        // The first top-level member opened by `declaration`, with comment lines
        // and whitespace dropped, so a layout check reads structure only.
        func compactMember(_ declaration: String, in source: String) -> String {
            let code = source
                .components(separatedBy: declaration).dropFirst().first?
                .components(separatedBy: "\n    }\n").first ?? ""
            return code.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined()
                .filter { !$0.isWhitespace }
        }
        // The lazy stack remained after #2270 and still appears in the hang
        // reports for #2311/#2642. Guard the eager layout here; the layout
        // suite checks scroll geometry and the offscreen notice changes.
        let compactHubContent = compactMember("private var content: some View {", in: featureHubSource)
        suite.expect(compactHubContent.contains("ScrollView{VStack(")
                && !compactHubContent.contains("LazyVStack("),
               "the Features page measures its cards eagerly instead of estimating their height during scrolling")
        // The first-run feature picker had the same loop: its lazy stack sat in
        // the step's plain stack under the onboarding scroll view and froze the
        // app while scrolling the catalog. Same kind of source check.
        let purposeStepSource = onboardingFeatureSource
            .components(separatedBy: "private struct PurposeStep: View {").dropFirst().first ?? ""
        let compactPurposeBody = compactMember("var body: some View {", in: purposeStepSource)
        suite.expect(compactPurposeBody.contains("ForEach(FeatureGroup.allCases")
                && !compactPurposeBody.contains("LazyVStack("),
               "the onboarding feature picker measures its cards eagerly instead of estimating their height during scrolling")
        // A lazy stack on the Monitor page re-measures and re-anchors its rows
        // without settling once the Bars options make the menu bar card taller,
        // which hangs Settings on the first scroll. The same kind of source
        // check: it keeps the eager stack and the preview above the scroll
        // view, not the scrolling itself.
        let monitorSettingsSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Settings/MonitorSettings.swift",
            encoding: .utf8)) ?? ""
        let compactMonitorBody = compactMember("var body: some View {", in: monitorSettingsSource)
        let monitorPreviewAboveScroll: Bool = {
            guard let preview = compactMonitorBody.range(of: "MenuBarMetricsPreview()"),
                  let scroll = compactMonitorBody.range(of: "ScrollView{VStack(") else { return false }
            return preview.upperBound <= scroll.lowerBound
        }()
        suite.expect(compactMonitorBody.hasPrefix("VStack(spacing:0){")
                && monitorPreviewAboveScroll
                && !compactMonitorBody.contains("LazyVStack("),
               "the Monitor page lays its rows out eagerly, with the live preview above its scroll view")
        suite.expect((Defaults.registeredDefaults[DefaultsKey.panelShowFanControl] as? Bool) == true,
               "installing fan control reveals its panel section by default")

        // MARK: Fan Control safety policy

        suite.expect(FanControlPolicy.coolingDuration == 15 * 60
                && FanControlPolicy.heartbeatLimit < 10,
               "the legacy session stays bounded while current control loses ownership quickly")
        suite.expect(FanControlPolicy.isAutomaticMode(0)
                && FanControlPolicy.isAutomaticMode(3)
                && !FanControlPolicy.isAutomaticMode(1)
                && !FanControlPolicy.isAutomaticMode(2)
                && !FanControlPolicy.isAutomaticMode(.max),
               "fan ownership accepts firmware automatic modes and rejects manual or unknown modes")
        suite.expect(FanControlPolicy.fanCount(from: 1) == 1
                && FanControlPolicy.fanCount(from: 8) == 8
                && FanControlPolicy.fanCount(from: 0) == nil
                && FanControlPolicy.fanCount(from: 9) == nil
                && FanControlPolicy.fanCount(from: 1.5) == nil
                && FanControlPolicy.fanCount(from: .nan) == nil,
               "fan discovery accepts only a small integral hardware count")
        suite.expect(FanControlPolicy.validBounds(minimum: 1_200, maximum: 5_800)
                && !FanControlPolicy.validBounds(minimum: -1, maximum: 5_800)
                && !FanControlPolicy.validBounds(minimum: 5_800, maximum: 5_800)
                && !FanControlPolicy.validBounds(minimum: 1_200, maximum: 25_000),
               "fan bounds must be finite, ordered and physically sane")
        suite.expect(FanControlPolicy.validReading(0)
                && FanControlPolicy.validReading(8_000)
                && !FanControlPolicy.validReading(-1)
                && !FanControlPolicy.validReading(.infinity),
               "fan readings stay within a safe display and verification range")
        suite.expect(FanControlPolicy.minimumCoolingLevel == 0
                && FanControlPolicy.maximumCoolingLevel == 100
                && FanControlPolicy.defaultCoolingLevel == 100
                && FanControlPolicy.validCoolingLevel(0)
                && FanControlPolicy.validCoolingLevel(55)
                && FanControlPolicy.validCoolingLevel(100)
                && !FanControlPolicy.validCoolingLevel(-5)
                && !FanControlPolicy.validCoolingLevel(26),
               "manual cooling accepts the full bounded five-percent scale")
        suite.expect(FanControlPolicy.coolingTargetRPM(minimum: 1_200, maximum: 5_800,
                                                 level: 0) == 1_200
                && FanControlPolicy.coolingTargetRPM(minimum: 1_200, maximum: 5_800,
                                                     level: 25) == 2_350
                && FanControlPolicy.coolingTargetRPM(minimum: 1_200, maximum: 5_800,
                                                     level: 100) == 5_800
                && FanControlPolicy.coolingTargetRPM(minimum: 5_800, maximum: 5_800,
                                                     level: 100) == nil,
               "manual targets map the full percentage scale into reported hardware bounds")
        suite.expect(FanControlPolicy.targetRPMMatches(target: 3_121, expected: 3_121)
                && FanControlPolicy.targetRPMMatches(target: 3_122, expected: 3_121)
                && FanControlPolicy.targetRPMMatches(target: 1_201.5, expected: 1_200)
                && !FanControlPolicy.targetRPMMatches(target: 3_500, expected: 3_121)
                && !FanControlPolicy.targetRPMMatches(target: 1_205, expected: 1_200)
                && !FanControlPolicy.targetRPMMatches(target: .nan, expected: 1_200),
               "fan target verification allows a narrow tolerance and rejects stale or malformed targets")
        suite.expect(FanControlPolicy.forceTestSatisfied(keyExists: false, writeSucceeded: false)
                && FanControlPolicy.forceTestSatisfied(keyExists: false, writeSucceeded: true)
                && FanControlPolicy.forceTestSatisfied(keyExists: true, writeSucceeded: true)
                && !FanControlPolicy.forceTestSatisfied(keyExists: true, writeSucceeded: false),
               "the manual-mode fallback needs the force-test override only where the Mac exposes it")

        let defaultCurve = FanControlConfiguration.defaultCurve
        suite.expect(FanControlPolicy.validConfiguration(.manual(level: 0))
                && FanControlPolicy.validConfiguration(.manual(level: 100))
                && FanControlPolicy.validConfiguration(.curve([defaultCurve]))
                && FanControlPolicy.interpolatedCoolingLevel(points: defaultCurve.points,
                                                             temperature: 40) == 0
                && FanControlPolicy.interpolatedCoolingLevel(points: defaultCurve.points,
                                                             temperature: 60) == 50
                && FanControlPolicy.interpolatedCoolingLevel(points: defaultCurve.points,
                                                             temperature: 61) == 55
                && FanControlPolicy.interpolatedCoolingLevel(points: defaultCurve.points,
                                                             temperature: 80) == 100,
               "the default curve starts at 50 degrees, reaches maximum at 70 and rounds safely up")
        let coolingTemperature = [
            FanControlTemperatureReading(source: .hottestSoC, celsius: 59),
        ]
        suite.expect(FanControlPolicy.curveCoolingLevel(curves: [defaultCurve],
                                                  temperatures: coolingTemperature,
                                                  previousLevel: 50) == 50
                && FanControlPolicy.curveCoolingLevel(
                    curves: [defaultCurve],
                    temperatures: [.init(source: .hottestSoC, celsius: 57)],
                    previousLevel: 50
                ) == 45,
               "a cooling curve uses two-degree hysteresis before lowering fan speed")
        let cpuCurve = FanControlCurve(
            sensor: .averageCPU,
            points: [FanControlCurvePoint(temperature: 40, coolingLevel: 0),
                     FanControlCurvePoint(temperature: 80, coolingLevel: 80)]
        )
        let curveTemperatures = [
            FanControlTemperatureReading(source: .hottestSoC, celsius: 54),
            FanControlTemperatureReading(source: .averageCPU, celsius: 70),
        ]
        suite.expect(FanControlPolicy.curveCoolingLevel(curves: [defaultCurve, cpuCurve],
                                                  temperatures: curveTemperatures) == 60
                && FanControlPolicy.curveCoolingLevel(curves: [defaultCurve, cpuCurve],
                                                      temperatures: [curveTemperatures[0]]) == nil,
               "several temperature rules use their highest demand and require every selected sensor")
        let duplicateCurves = [defaultCurve,
                               FanControlCurve(sensor: .hottestSoC, points: cpuCurve.points)]
        let descendingCurve = FanControlCurve(
            sensor: .averageCPU,
            points: [FanControlCurvePoint(temperature: 50, coolingLevel: 80),
                     FanControlCurvePoint(temperature: 70, coolingLevel: 40)]
        )
        suite.expect(!FanControlPolicy.validCurves(duplicateCurves)
                && !FanControlPolicy.validCurves([descendingCurve])
                && FanControlConfiguration.decodeCurves(
                    FanControlConfiguration.encodeCurves([defaultCurve]) ?? "") == [defaultCurve]
                && FanControlConfiguration.decodeCurves("not json") == nil,
               "stored curves reject duplicate sensors, unsafe slopes and malformed data")
        let resumedManual = FanControlConfiguration.manual(level: 100)
        let resumedCurves = FanControlConfiguration.curve([defaultCurve, cpuCurve])
        suite.expect(FanControlConfiguration.decodeResume(
                    FanControlConfiguration.encodeResume(resumedManual) ?? "") == resumedManual
                && FanControlConfiguration.decodeResume(
                    FanControlConfiguration.encodeResume(resumedCurves) ?? "") == resumedCurves,
               "a resumed manual speed or curve comes back exactly as the user applied it")
        suite.expect(FanControlConfiguration.encodeResume(
                    FanControlConfiguration(mode: .system, manualLevel: 100, curves: [])) == nil
                && FanControlConfiguration.encodeResume(.manual(level: 37)) == nil
                && FanControlConfiguration.encodeResume(.curve([descendingCurve])) == nil
                && FanControlConfiguration.decodeResume(
                    #"{"curves":[],"manualLevel":100,"mode":"system"}"#) == nil
                && FanControlConfiguration.decodeResume(
                    #"{"curves":[],"manualLevel":37,"mode":"manual"}"#) == nil
                && FanControlConfiguration.decodeResume("") == nil
                && FanControlConfiguration.decodeResume("not json") == nil,
               "only a valid manual speed or curve is ever kept or brought back after a restart")
        FanControlResumeContract.run(suite)
        FanControlRecoveryContract.run(suite)
        FanControlHardwareContract.run(suite)
        let addedPoints = FanControlPolicy.addingCurvePoint(to: defaultCurve.points)
        suite.expect(FanControlPolicy.nextCurvePoint(for: defaultCurve.points) == FanControlCurvePoint(temperature: 60, coolingLevel: 50)
                && addedPoints == [
                    FanControlCurvePoint(temperature: 50, coolingLevel: 0),
                    FanControlCurvePoint(temperature: 60, coolingLevel: 50),
                    FanControlCurvePoint(temperature: 70, coolingLevel: 100),
                ]
                && FanControlPolicy.validCurve(FanControlCurve(sensor: .hottestSoC, points: addedPoints ?? [])),
               "adding a fan curve point calculates the intermediate point and produces a valid sorted curve")
        var iterativePoints = defaultCurve.points
        while let next = FanControlPolicy.addingCurvePoint(to: iterativePoints) {
            iterativePoints = next
        }
        suite.expect(iterativePoints.count == FanControlPolicy.maximumCurvePointCount
                && FanControlPolicy.validCurve(FanControlCurve(sensor: .hottestSoC, points: iterativePoints))
                && FanControlPolicy.nextCurvePoint(for: iterativePoints) == nil
                && FanControlPolicy.addingCurvePoint(to: iterativePoints) == nil,
               "adding fan curve points fills up to the maximum point limit with strictly valid curves")
        let secondCurve = FanControlCurve(sensor: .averageCPU,
                                          points: defaultCurve.points)
        var updatedCurves = [defaultCurve, secondCurve]
        if let secondPoints = FanControlPolicy.addingCurvePoint(to: updatedCurves[1].points) {
            updatedCurves[1].points = secondPoints
        }
        let storedUpdatedCurves = FanControlConfiguration.decodeCurves(
            FanControlConfiguration.encodeCurves(updatedCurves) ?? ""
        )
        suite.expect(updatedCurves.count == 2
                && updatedCurves.first == defaultCurve
                && updatedCurves[1].points == addedPoints
                && storedUpdatedCurves == updatedCurves,
               "adding a point to the second fan curve preserves every valid stored curve")
        let m3FanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Te05", 44), ("Tf4E", 53), ("Tf4F", 76)],
            gpuReadings: [48],
            platform: .appleM3Family
        )
        suite.expectClose(m3FanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    53,
                    "M3 fan curves include the hottest mapped Tf CPU core")
        suite.expectClose(m3FanTemperatures.first { $0.source == .averageCPU }?.celsius ?? -1,
                    48.5,
                    "M3 fan curves exclude auxiliary Tf readings from the CPU average")
        let m4MaxPlatform = TemperatureSensorSelector.platform(
            brandString: "Apple M4 Max", modelIdentifier: "Mac16,5",
            performanceCoreCount: 10, efficiencyCoreCount: 4
        )
        let otherM4MaxConfigurations: [(String?, Int?, Int?)] = [
            ("Mac16,5", 12, 4), ("Mac16,6", 10, 4), ("Mac16,5", 10, 3),
            (nil, 10, 4), ("Mac16,5", nil, 4), ("Mac16,5", 10, nil),
            (nil, nil, nil),
        ]
        for (model, performance, efficiency) in otherM4MaxConfigurations {
            let platform = TemperatureSensorSelector.platform(
                brandString: "Apple M4 Max", modelIdentifier: model,
                performanceCoreCount: performance, efficiencyCoreCount: efficiency
            )
            let temperatures = FanControlPolicy.aggregatedTemperatures(
                cpuReadings: [("Tp01", 80), ("Te05", 60), ("Tpx5", 100), ("Tp3X", 110)],
                gpuReadings: [40], platform: platform
            )
            let expectedReadings: [(FanControlTemperatureSource, Double, Int)] = [
                (.hottestCPU, 80, 80), (.averageCPU, 70, 60),
                (.hottestSoC, 80, 80), (.averageSoC, 60, 40),
            ]
            for (source, expected, expectedLevel) in expectedReadings {
                suite.expectClose(temperatures.first { $0.source == source }?.celsius ?? -1,
                                  expected, "other M4 Max configurations preserve existing CPU and SoC fan inputs")
                let curve = FanControlCurve(sensor: source, points: [
                    .init(temperature: 40, coolingLevel: 0), .init(temperature: 90, coolingLevel: 100),
                ])
                suite.expect(FanControlPolicy.curveCoolingLevel(curves: [curve],
                                                               temperatures: temperatures) == expectedLevel,
                             "other M4 Max configurations keep CPU and SoC curves evaluable at their existing levels")
            }
            let auxiliaryOnly = FanControlPolicy.aggregatedTemperatures(
                cpuReadings: [("Tp0M", 88)], gpuReadings: [40], platform: platform
            )
            suite.expect(!auxiliaryOnly.contains { $0.source == .hottestCPU || $0.source == .averageCPU },
                         "other M4 Max configurations still require mapped readings for CPU fan inputs")
            suite.expectClose(auxiliaryOnly.first { $0.source == .hottestSoC }?.celsius ?? -1,
                              40, "missing mapped CPU readings retain the existing GPU-only SoC fallback")
        }
        for (name, sample) in [("loaded", M4MaxTemperatureFixtures.loaded),
                               ("parked", M4MaxTemperatureFixtures.parked),
                               ("idle", M4MaxTemperatureFixtures.idle)] {
            let temperatures = FanControlPolicy.aggregatedTemperatures(
                cpuReadings: sample.cpu + [("Tp3X", 110)],
                gpuReadings: sample.gpu, platform: m4MaxPlatform
            )
            suite.expectClose(temperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                              sample.hottest, "M4 Max hottest CPU uses measured \(name) regions")
            suite.expectClose(temperatures.first { $0.source == .averageCPU }?.celsius ?? -1,
                              sample.average, "M4 Max CPU mean excludes auxiliary and invalid \(name) readings")
            suite.expectClose(temperatures.first { $0.source == .hottestSoC }?.celsius ?? -1,
                              sample.hottest, "M4 Max hottest SoC excludes auxiliary CPU hotspots when \(name)")
            let hottestCurve = FanControlCurve(sensor: .hottestCPU,
                                              points: FanControlConfiguration.defaultCurve.points)
            suite.expect(FanControlPolicy.curveCoolingLevel(curves: [hottestCurve],
                                                           temperatures: temperatures) == sample.defaultLevel,
                         "M4 Max \(name) temperatures reach CPU curve evaluation")
            let balancedCurve = FanControlCurve(sensor: .hottestSoC, points: [
                .init(temperature: 60, coolingLevel: 0), .init(temperature: 95, coolingLevel: 100),
            ])
            suite.expect(FanControlPolicy.curveCoolingLevel(curves: [balancedCurve],
                                                           temperatures: temperatures) == sample.balancedLevel,
                         "M4 Max \(name) hottest SoC reaches shadow curve evaluation")
        }
        let m4MaxUnavailable = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Tex0", .nan), ("Tex1", .infinity), ("Tex2", 9), ("Tex3", 125),
                          ("Tpx0", 0), ("Tpx1", -4), ("Tp0M", 88)],
            gpuReadings: [51], platform: m4MaxPlatform
        )
        suite.expect(!m4MaxUnavailable.contains { $0.source == .hottestCPU || $0.source == .averageCPU },
                     "M4 Max fan CPU sources stay unavailable when no mapped region answers")
        suite.expectClose(m4MaxUnavailable.first { $0.source == .hottestSoC }?.celsius ?? -1,
                          51, "M4 Max SoC fallback preserves GPU-only readings")
        let missingCPUCurve = FanControlCurve(sensor: .hottestCPU,
                                             points: FanControlConfiguration.defaultCurve.points)
        suite.expect(FanControlPolicy.curveCoolingLevel(curves: [missingCPUCurve],
                                                       temperatures: m4MaxUnavailable) == nil,
                     "M4 Max CPU curves reject missing mapped readings instead of using auxiliaries")
        let m4MaxPartial = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Tex1", 53.234375), ("Tpx5", .nan), ("Tp0M", 88)],
            gpuReadings: [59], platform: m4MaxPlatform
        )
        suite.expectClose(m4MaxPartial.first { $0.source == .averageCPU }?.celsius ?? -1,
                          53.234375, "one valid M4 Max region remains a valid CPU curve input")
        suite.expectClose(m4MaxPartial.first { $0.source == .hottestSoC }?.celsius ?? -1,
                          59, "M4 Max hottest SoC still includes a genuinely hotter GPU")
        let unmappedFanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Tp00", 48), ("Tp0W", 113)],
            gpuReadings: [],
            platform: .unmappedAppleSilicon
        )
        suite.expect(unmappedFanTemperatures.isEmpty,
               "fan curves reject unknown Apple Silicon sensors instead of treating them as CPU")
        // Apple M1 MacBook Pro 13-inch (MacBookPro17,1) under load. It carries
        // none of the first M1 layout's keys; its Tg keys read zero.
        let m1AlternateCPUReadings: [(key: String, value: Double)] = [
            ("Te0a", 62.95), ("Te0z", 65.42), ("Te3a", 59.55), ("Te3z", 80.88),
            ("Tp2a", 71.69), ("Tp2z", 90.19), ("Tp3a", 75.11), ("Tp3b", 82.51),
            ("Tp4a", 71.72), ("Tp5a", 67.30), ("Tp7a", 71.16), ("Tp8a", 74.52),
            ("Tp9a", 72.42), ("Tp9z", 93.88),
        ]
        let m1AlternateFanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: m1AlternateCPUReadings,
            gpuReadings: [0, 0],
            platform: TemperatureSensorSelector.platform(brandString: "Apple M1")
        )
        suite.expectClose(m1AlternateFanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    75.11,
                    "M1 fan curves follow the hottest core of the second M1 layout")
        suite.expectClose(m1AlternateFanTemperatures.first { $0.source == .averageCPU }?.celsius ?? -1,
                    69.60,
                    "M1 fan curves average only the a variants of the second layout", tol: 0.01)
        suite.expectClose(m1AlternateFanTemperatures.first { $0.source == .hottestSoC }?.celsius ?? -1,
                    75.11,
                    "the default SoC curve has a reading on the second M1 layout")
        suite.expect(m1AlternateFanTemperatures.first { $0.source == .hottestGPU } == nil,
               "zero GPU keys do not become a fan curve reading")
        let invalidM1Temperatures: [Double?] = [nil, 0, 9.99, 125, .nan, .infinity]
        for invalidTemperature in invalidM1Temperatures {
            let unavailableCores = m1AlternateCPUReadings.compactMap { reading -> (key: String, value: Double)? in
                guard reading.key.hasSuffix("a") else { return reading }
                return invalidTemperature.map { (reading.key, $0) }
            }
            let unavailableTemperatures = FanControlPolicy.aggregatedTemperatures(
                cpuReadings: unavailableCores, gpuReadings: [0, 0], platform: .appleM1Family
            )
            suite.expect(unavailableTemperatures.isEmpty
                    && FanControlPolicy.curveCoolingLevel(curves: [defaultCurve],
                                                          temperatures: unavailableTemperatures,
                                                          previousLevel: 70) == nil
                    && FanControlPolicy.curveCoolingLevel(curves: [cpuCurve],
                                                          temperatures: unavailableTemperatures,
                                                          previousLevel: 70) == nil,
                   "missing or invalid M1 cores cannot drive CPU or SoC curves through auxiliary variants")
            suite.expectClose(TemperatureSensorSelector.displayedCPUTemperature(
                readings: unavailableCores, platform: .appleM1Family
            ) ?? -1, 93.88, "the monitor keeps its compatibility reading when M1 cores are unavailable")
        }
        let m1PartialReadings: [(key: String, value: Double)] = [
            ("Te0a", 42), ("Te3a", .nan), ("Tp2a", 0), ("Tp3a", 125), ("Tp9z", 93.88),
        ]
        let m1PartialTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: m1PartialReadings, gpuReadings: [0, 0], platform: .appleM1Family
        )
        suite.expect(m1PartialTemperatures.count == 4
                && m1PartialTemperatures.allSatisfy { $0.celsius == 42 },
               "one valid alternate M1 core keeps CPU and SoC curves available without auxiliary readings")
        suite.expectClose(TemperatureSensorSelector.displayedCPUTemperature(
            readings: m1PartialReadings, platform: .appleM1Family
        ) ?? -1, 42, "the monitor follows a valid alternate M1 core while other cores are invalid")
        let m1OriginalFanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Tp09", 43), ("Tp01", 49), ("Tp2z", 70)],
            gpuReadings: [], platform: .appleM1Family
        )
        suite.expectClose(m1OriginalFanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    49, "the original M1 fan curve keeps its hottest mapped core")
        suite.expectClose(m1OriginalFanTemperatures.first { $0.source == .averageCPU }?.celsius ?? -1,
                    46, "the original M1 fan curve keeps auxiliary variants out of its average")
        // Apple M4 Pro (Mac16,8) under load: the base M4 set tops out at Tp0Y,
        // 10 °C below the core that Tpx5 repeats.
        let m4ProPlatform = TemperatureSensorSelector.platform(brandString: "Apple M4 Pro")
        let m4ProFanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Te05", 74.15), ("Tp01", 77.10), ("Tp0Y", 87.08),
                          ("Tp0U", 97.84), ("Tpx5", 97.84), ("Tp29", 95.81),
                          ("Tex1", 79.64)],
            gpuReadings: [71.2],
            platform: m4ProPlatform
        )
        suite.expectClose(m4ProFanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    97.84,
                    "M4 Pro fan curves follow its hottest CPU core")
        suite.expectClose(m4ProFanTemperatures.first { $0.source == .averageCPU }?.celsius ?? -1,
                    88.74,
                    "M4 Pro fan curves average its own CPU sensor set")
        suite.expectClose(m4ProFanTemperatures.first { $0.source == .hottestSoC }?.celsius ?? -1,
                    97.84,
                    "M4 Pro fan curves keep the CPU in the SoC reading")
        // The same Mac at light idle with its P cores parked, plus a key
        // outside the set running hot the way Tp0W does on the base M4: the
        // hottest SoC curve must not raise the fans for it.
        let m4ProIdleFanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Te05", 54.80), ("Te06", 58.05), ("Tex1", 58.05),
                          ("Tex3", 57.19), ("Tpx5", 0), ("Tp0W", 68.0)],
            gpuReadings: [50.0],
            platform: m4ProPlatform
        )
        suite.expectClose(m4ProIdleFanTemperatures.first { $0.source == .hottestSoC }?.celsius ?? -1,
                    58.05,
                    "an idle M4 Pro keeps an auxiliary hotspot out of the hottest SoC curve")
        suite.expectClose(m4ProIdleFanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    58.05,
                    "an idle M4 Pro fan curve reads its hottest E core")
        let m4FanTemperatures = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("Tp01", 46.12), ("Te05", 45.01), ("Tp0W", 62.56)],
            gpuReadings: [],
            platform: TemperatureSensorSelector.platform(brandString: "Apple M4")
        )
        suite.expectClose(m4FanTemperatures.first { $0.source == .hottestCPU }?.celsius ?? -1,
                    46.12,
                    "base M4 fan curves keep using its mapped cores")
        suite.expect(FanControlPolicy.telemetryReadings(expectedCount: 1, readings: [1_200]) == [1_200]
                && FanControlPolicy.telemetryReadings(expectedCount: 2,
                                                      readings: [1_200, 1_350]) == [1_200, 1_350],
               "fan telemetry preserves one or several ordered readings")
        suite.expect(FanControlPolicy.telemetryReadings(expectedCount: 0, readings: []) == nil
                && FanControlPolicy.telemetryReadings(expectedCount: 2, readings: [1_200]) == nil
                && FanControlPolicy.telemetryReadings(expectedCount: 2, readings: [1_200, nil]) == nil
                && FanControlPolicy.telemetryReadings(expectedCount: 1, readings: [.infinity]) == nil
                && FanControlPolicy.telemetryReadings(expectedCount: 1, readings: [-1]) == nil,
               "fan telemetry rejects no-fan, missing and malformed sensor sets")
        suite.expect(FanControlPolicy.menuBarValue(for: [1_249.6]) == "1250"
                && FanControlPolicy.menuBarValue(for: [1_200, 1_350]) == "1200/1350"
                && FanControlPolicy.menuBarValue(for: []) == nil
                && FanControlPolicy.menuBarValue(for: [.infinity]) == nil,
               "fan RPM menu bar text supports one or several validated fans")

        let floatRPM = SMCValueCodec.encode(4_850, type: "flt ", size: 4)
        suite.expect(floatRPM.flatMap { SMCValueCodec.decode($0, type: "flt ") } == 4_850,
               "native fan RPM floats round-trip exactly")
        let fixedRPM = SMCValueCodec.encode(4_850.25, type: "fpe2", size: 2)
        suite.expect(fixedRPM.flatMap { SMCValueCodec.decode($0, type: "fpe2") } == 4_850.25,
               "fixed-point fan RPM values round-trip at quarter-RPM precision")
        suite.expect(SMCValueCodec.decode([0x12, 0x34], type: "ui16") == 0x1234
                && SMCValueCodec.decode([0, 0, 1, 2], type: "ui32") == 258
                && SMCValueCodec.encode(1, type: "ui8 ", size: 1) == [1],
               "SMC integer types preserve their documented byte order")
        suite.expect(SMCValueCodec.encode(-1, type: "flt ", size: 4) == nil
                && SMCValueCodec.encode(30_000, type: "fpe2", size: 2) == nil
                && SMCValueCodec.encode(1, type: "myst", size: 1) == nil,
               "SMC writes reject negative, overflowing and unknown encodings")

        let watchdogEnd = Date(timeIntervalSince1970: 2_000)
        suite.expect(FanControlPolicy.restoreReason(now: watchdogEnd,
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              thermalState: .nominal) == .timeLimit,
               "the watchdog still honors a deadline from a legacy helper request")
        suite.expect(FanControlPolicy.restoreReason(now: watchdogEnd,
                                              endsAt: nil,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              thermalState: .nominal) == nil,
               "current manual and curve control have no arbitrary time limit")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: FanControlPolicy.heartbeatLimit + 0.1,
                                              verificationFailures: 0,
                                              thermalState: .nominal) == .heartbeatLost,
               "the watchdog restores when the app heartbeat stops")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: FanControlPolicy.verificationFailureLimit,
                                              thermalState: .nominal) == .hardwareChanged,
               "the watchdog restores after repeated hardware verification failures")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              temperatureFailures: FanControlPolicy.temperatureFailureLimit,
                                              thermalState: .nominal) == .temperatureUnavailable,
               "a curve returns control after repeated missing temperature readings")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              thermalState: .serious) == .thermalPressure,
               "the watchdog returns control to the system under thermal pressure")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              thermalState: .fair) == nil,
               "a fair thermal state does not cancel the user's selected control")
        suite.expect(FanControlPolicy.restoreReason(now: Date(timeIntervalSince1970: 1_900),
                                              endsAt: watchdogEnd,
                                              heartbeatAge: 0,
                                              verificationFailures: 0,
                                              thermalState: .nominal) == nil,
               "a healthy maximum-cooling session remains active")

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.fanControl(language)
            expectFormat(strings.fanNameFormat, ["d"],
                         "fan name format stays valid for \(language.rawValue)")
            expectFormat(strings.rpmFormat, ["d"],
                         "fan speed format stays valid for \(language.rawValue)")
            expectFormat(strings.currentRPMFormat, ["d"],
                         "current fan speed format stays valid for \(language.rawValue)")
            expectFormat(strings.targetRPMFormat, ["d"],
                         "target fan speed format stays valid for \(language.rawValue)")
        }

        let legacyFanSnapshot = Data(#"{"fans":[],"isCooling":false}"#.utf8)
        let decodedLegacyFanSnapshot = try? JSONDecoder().decode(FanControlSnapshot.self,
                                                                  from: legacyFanSnapshot)
        suite.expect(decodedLegacyFanSnapshot != nil
                && decodedLegacyFanSnapshot?.coolingLevel == nil
                && decodedLegacyFanSnapshot?.configuration == nil
                && decodedLegacyFanSnapshot?.temperatures == nil,
               "fan snapshots remain compatible with an older installed helper")

        func activeSet(_ permission: AppPermission,
                       available: Set<AppFeature> = Set(AppFeature.allCases),
                       on: Set<String> = [],
                       strings: [String: String] = [:]) -> Set<AppFeature> {
            Set(AppFeature.activeFeatures(using: permission,
                                          isAvailable: { available.contains($0) },
                                          boolFor: { on.contains($0) },
                                          stringFor: { strings[$0] }))
        }

        suite.expect(PermissionPollingSupport.interval(visibleSurfaceCount: 0,
                                                 accessibilityIsNeeded: false,
                                                 accessibilityIsGranted: false) == nil,
               "permissions keep no background timer without a live feature or visible surface")
        suite.expect(PermissionPollingSupport.interval(visibleSurfaceCount: 1,
                                                 accessibilityIsNeeded: false,
                                                 accessibilityIsGranted: true) == 2.5,
               "a visible permission surface refreshes grants promptly")
        suite.expect(PermissionPollingSupport.interval(visibleSurfaceCount: 0,
                                                 accessibilityIsNeeded: true,
                                                 accessibilityIsGranted: false) == 2.5,
               "a live feature waiting for its grant refreshes promptly")
        suite.expect(PermissionPollingSupport.interval(visibleSurfaceCount: 0,
                                                 accessibilityIsNeeded: true,
                                                 accessibilityIsGranted: true) == 60,
               "a granted live feature keeps only the slow revocation watch")

        suite.expect(activeSet(.accessibility, on: [DefaultsKey.keepAwakeMouseJiggleEnabled]).contains(.keepAwake),
               "keep awake uses accessibility only with the mouse jiggle on")
        suite.expect(!activeSet(.accessibility).contains(.keepAwake),
               "keep awake without jiggle does not use accessibility")


        suite.expect(activeSet(.notifications) == [],
               "no alerts and no schedule means notifications are unused")
        suite.expect(activeSet(.notifications, on: [DefaultsKey.monitorAlertCPUTemperature]) == [.monitorCPU],
               "a CPU temperature alert marks the CPU monitor as notifying")
        suite.expect(activeSet(.notifications, on: [DefaultsKey.monitorAlertBatteryTemperature]) == [.monitorPower],
               "a battery temperature alert marks the power monitor as notifying")
        suite.expect(activeSet(.notifications, on: [DefaultsKey.memoryNotify]) == [.monitorMemory]
                     && activeSet(.notifications, available: Set(AppFeature.allCases).subtracting([.monitorMemory]),
                                  on: [DefaultsKey.memoryNotify]) == [],
               "the Memory module's notification, the one memory notifier, marks the memory monitor as notifying")
        suite.expect(!AppFeature.monitorAlertPairs.contains { $0.feature == .monitorMemory }
                     && !AppFeature.anyMonitorAlertEnabled(isAvailable: { _ in true },
                                                           boolFor: { $0 == DefaultsKey.memoryNotify }),
               "Monitor alerts have no memory alert: the Memory notification never arms the alert sampler")
        suite.expect(activeSet(.notifications,
                         available: Set(AppFeature.allCases).subtracting([.monitorCPU]),
                         on: [DefaultsKey.monitorAlertCPU]) == [],
               "an alert whose metric is unavailable does not notify")
        suite.expect(activeSet(.notifications, on: [DefaultsKey.cleanerScheduleNotify],
                         strings: [DefaultsKey.cleanerScheduleFrequency: "weekly"]) == [.cleaner],
               "a scheduled cleaner with notice enabled uses notifications")
        suite.expect(activeSet(.notifications, on: [DefaultsKey.cleanerScheduleNotify],
                         strings: [DefaultsKey.cleanerScheduleFrequency: "off"]) == [],
               "an unscheduled cleaner does not use notifications")
        suite.expect(activeSet(.notifications,
                         on: [DefaultsKey.whatsAppDownloadsAutomaticEnabled,
                              DefaultsKey.whatsAppDownloadsNotify]) == [],
               "WhatsApp cleanup notifications stay unused until that cleaner is turned on")
        suite.expect(activeSet(.notifications,
                         on: [DefaultsKey.whatsAppDownloadsEnabled,
                              DefaultsKey.whatsAppDownloadsAutomaticEnabled,
                              DefaultsKey.whatsAppDownloadsNotify]) == [.cleaner],
               "WhatsApp cleanup only uses notifications for an opted-in automatic summary")
        suite.expect(activeSet(.notifications,
                         on: [DefaultsKey.whatsAppOrganizerEnabled,
                              DefaultsKey.whatsAppDownloadsNotify]) == [],
               "the experimental WhatsApp organizer stays silent until that cleaner is turned on")
        suite.expect(activeSet(.notifications,
                         on: [DefaultsKey.whatsAppDownloadsEnabled,
                              DefaultsKey.whatsAppOrganizerEnabled,
                              DefaultsKey.whatsAppDownloadsNotify]) == [.cleaner],
               "the experimental WhatsApp organizer can offer an undo notification")
        suite.expect(activeSet(.filesAndFolders) == [],
               "WhatsApp Downloads folder access stays unused until that cleaner is turned on")
        suite.expect(activeSet(.filesAndFolders, on: [DefaultsKey.whatsAppDownloadsEnabled]) == [.cleaner],
               "the cleaner owns WhatsApp Downloads folder access")

        suite.expect(activeSet(.fullDiskAccess) == [.cleaner, .uninstaller],
               "cleaner and uninstaller are on-demand full disk users")
        suite.expect(activeSet(.accessibility).isEmpty,
               "with nothing enabled no feature uses accessibility")
        suite.expect(activeSet(.automationFinder) == [.uninstaller],
               "Finder automation is used only by the uninstaller's Trash ask")
        suite.expect(activeSet(.appManagement) == [.homebrew, .appUpdates],
               "package and update installs declare App Management access")
        suite.expect(AppFeature.homebrew.permissions == [.appManagement],
               "the package manager needs no Automation: the person's own terminal runs its commands")

        suite.expect(!AppFeature.anyMonitorAlertEnabled(isAvailable: { _ in true }, boolFor: { _ in false }),
               "no alert keys means no monitor alerts")
        suite.expect(AppFeature.anyMonitorAlertEnabled(isAvailable: { _ in true },
                                                 boolFor: { $0 == DefaultsKey.monitorAlertDisk }),
               "one alert on an available metric arms the alert service")
        suite.expect(AppFeature.anyMonitorAlertEnabled(isAvailable: { _ in true },
                                                 boolFor: {
                                                     $0 == DefaultsKey.monitorAlertBatteryTemperature
                                                 }),
               "a battery temperature alert arms the alert service")
        suite.expect(!AppFeature.anyMonitorAlertEnabled(isAvailable: { $0 != .monitorPower },
                                                  boolFor: {
                                                      $0 == DefaultsKey.monitorAlertBatteryTemperature
                                                  }),
               "a battery temperature alert stays disarmed without the power metric")
        suite.expect(!AppFeature.anyMonitorAlertEnabled(isAvailable: { $0 != .monitorDisk },
                                                  boolFor: { $0 == DefaultsKey.monitorAlertDisk }),
               "an alert with its metric off in the hub stays disarmed")

        suite.expect(GlobalShortcutRole.activeRoles(isOn: { _ in true }).count
                == GlobalShortcutRole.allCases.count,
               "the availability-free overload keeps every enabled current role")


        // MARK: Features hub strings

        for language in AppLanguage.allCases {
            let hub = FeatureStrings.hub(language)
            suite.expect(hub.activeCountFormat.contains("%1$d") && hub.activeCountFormat.contains("%2$d"),
                   "count format keeps positional specifiers (\(language.rawValue))")
        }
        for language in AppLanguage.allCases {
            let clipboard = FeatureStrings.clipboard(language)
            expectFormat(clipboard.deleteSelectedFormat, ["d"],
                         "\(language.rawValue) clipboard bulk-delete format")
        }
        suite.expect(FeatureStrings.hub(.enUS).pageTitle == "Features", "hub page title reads naturally")
        for language in AppLanguage.allCases {
            suite.expect(FeatureStrings.appUpdates(language).updateSelectedFormat.contains("%d")
                    && FeatureStrings.appUpdates(language).lastCheckFormat.contains("%@")
                    && FeatureStrings.appUpdates(language).nextCheckFormat.contains("%@")
                    && FeatureStrings.appUpdates(language).notificationBodyFormat.contains("%@"),
                   "app update formats keep their placeholders (\(language.rawValue))")
            suite.expect(!FeatureStrings.appUpdates(language).notificationBodyOne.contains("%"),
                   "the single-app note carries no placeholder (\(language.rawValue))")
        }

        // MARK: Kill Process safety
        suite.expect(KillProcessSupport.isProtected(pid: 0, name: "kernel_task", path: "/System/Library/"),
               "PID 0 is protected")
        suite.expect(KillProcessSupport.isProtected(pid: 1, name: "launchd", path: "/sbin/launchd"),
               "PID 1 is protected")
        suite.expect(KillProcessSupport.isProtected(pid: 9999, name: "WindowServer", path: "/System/Library/Frameworks/WindowServer"),
               "WindowServer is protected")
        suite.expect(KillProcessSupport.isProtected(pid: 9999, name: "loginwindow", path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"),
               "loginwindow is protected")
        suite.expect(KillProcessSupport.isProtected(pid: ProcessInfo.processInfo.processIdentifier, name: "Brim"),
               "current app PID is protected")
        suite.expect(!KillProcessSupport.isProtected(pid: 12345, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
               "ordinary user app is not protected")
        suite.expect(KillProcessSupport.numberComesBefore(90, 10, lhsPID: 2, rhsPID: 1,
                                                    ascending: false)
               && KillProcessSupport.numberComesBefore(10, 90, lhsPID: 2, rhsPID: 1,
                                                       ascending: true)
               && !KillProcessSupport.numberComesBefore(10, 10, lhsPID: 2, rhsPID: 1,
                                                        ascending: true),
               "Kill Process numeric sorting is strict and follows the selected direction")
        suite.expect(KillProcessSupport.nameComesBefore("Alpha", "Zulu", lhsPID: 2, rhsPID: 1,
                                                  ascending: true)
               && KillProcessSupport.nameComesBefore("Zulu", "Alpha", lhsPID: 2, rhsPID: 1,
                                                     ascending: false)
               && !KillProcessSupport.nameComesBefore("Same", "same", lhsPID: 2, rhsPID: 1,
                                                      ascending: true),
               "Kill Process name sorting is A to Z by default and strict for ties")
        suite.expect(KillProcessSupport.normalizedStartDescription(" Thu  Aug 27  10:20:30 2026 \n")
                == "Thu Aug 27 10:20:30 2026"
               && KillProcessSupport.normalizedStartDescription("bad'; kill 1") == nil,
               "Kill Process accepts only safe normalized start identities for the admin command")
        // pid 1 -> 10 -> {20, 21} -> 30, with 40 on an unrelated branch, 50
        // its own parent and 21 <-> 22 pointing at each other.
        let processTable: [(pid: pid_t, ppid: pid_t)] = [
            (10, 1), (20, 10), (21, 10), (30, 20), (40, 1), (50, 50), (22, 21), (21, 22),
        ]
        let treeBelowTen = KillProcessSupport.descendants(of: 10, parents: processTable)
        suite.expect(treeBelowTen == [20, 21, 30, 22],
               "Kill Process collects a whole process tree breadth first so the caller kills deepest first")
        suite.expect(KillProcessSupport.descendants(of: 30, parents: processTable).isEmpty
               && KillProcessSupport.descendants(of: 50, parents: processTable).isEmpty,
               "Kill Process reports no descendants for a leaf and never follows a self-parenting row")

        for language in AppLanguage.allCases {
            let shortcutValues = Mirror(reflecting: FeatureStrings.shortcuts(language)).children
                .compactMap { $0.value as? String }
            suite.expect(shortcutValues.allSatisfy { !$0.contains("—") },
                   "shortcut editor strings avoid em-dashes (\(language.rawValue))")
            let strings = Strings.enUS
            suite.expect(!strings.obPurposeTitle.isEmpty && !strings.obPurposeBody.isEmpty
                    && !strings.obPurposeSkip.isEmpty,
                   "the purpose step speaks \(language.rawValue)")
        }

        // MARK: Hub presets and energy badges

        suite.expect(FeaturePreset.allCases.count == 2,
               "two starting points, not another wall of decisions")
        suite.expect(FeaturePreset.allCases.allSatisfy { !$0.features.isEmpty },
               "every preset installs something")
        suite.expect(FeaturePreset.battery.features.allSatisfy {
                   !$0.permissions.contains(.accessibility)
               },
               "battery and quiet needs no accessibility permission at all")
        let firstRunSuiteName = "brim.tests.first-run.\(UUID().uuidString)"
        if let firstRunDefaults = UserDefaults(suiteName: firstRunSuiteName) {
            firstRunDefaults.register(defaults: AppFeature.availabilityDefaults)
            FeaturePreset.prepareFirstRunAvailability(in: firstRunDefaults)
            suite.expect(Set(AppFeature.allCases.filter {
                firstRunDefaults.bool(forKey: $0.availabilityKey)
            }) == FeaturePreset.essential.features,
            "a clean install loads only the essential feature set before onboarding")

            for feature in AppFeature.allCases {
                firstRunDefaults.set(true, forKey: feature.availabilityKey)
            }
            firstRunDefaults.set(2, forKey: DefaultsKey.onboardingStep)
            FeaturePreset.prepareFirstRunAvailability(in: firstRunDefaults)
            suite.expect(AppFeature.allCases.allSatisfy {
                firstRunDefaults.bool(forKey: $0.availabilityKey)
            }, "an interrupted onboarding keeps the feature selection already applied")
            firstRunDefaults.removePersistentDomain(forName: firstRunSuiteName)
        } else {
            suite.expect(false, "first-run defaults suite can be created")
        }

        // MARK: Settings page visibility

        func pageVisible(_ page: SettingsPage, available: Set<AppFeature>) -> Bool {
            FeatureVisibilitySupport.isPageVisible(page) { available.contains($0) }
        }
        let allFeatures = Set(AppFeature.allCases)
        suite.expect(!pageVisible(.monitor, available: allFeatures.subtracting(Set(FeatureVisibilitySupport.monitorFeatures))),
               "monitor page hides with every metric off")
        suite.expect(pageVisible(.monitor, available: [.monitorNetwork]), "one metric keeps the monitor page")
        suite.expect(pageVisible(.general, available: []) && pageVisible(.about, available: [])
                && pageVisible(.shortcuts, available: []),
               "app pages never hide")
        suite.expect(!pageVisible(.cleaner,
                            available: allFeatures.subtracting([.cleaner])),
               "cleaner settings, including WhatsApp downloads, follow the cleaner module")
        suite.expect(AppFeature.allCases.allSatisfy { feature in
            let destination = feature.settingsDestination
            let gate = FeatureVisibilitySupport.features(for: destination.page)
            return gate.isEmpty || gate.contains(feature)
        }, "every feature destination is either always visible or gated by that feature")
        suite.expect(AppFeature.allCases.allSatisfy { $0.settingsDestination.hasValidSectionAnchor },
               "every feature anchor belongs to its destination page")
        suite.expect(Set(AppFeature.allCases.compactMap(\.settingsDestination.sectionAnchor))
                == Set(SettingsSectionAnchor.allCases).subtracting([.panelConfiguration, .monitorAlerts])
                && SettingsSectionAnchor.panelConfiguration.page == .general
                && SettingsSectionAnchor.monitorAlerts.page == .monitor,
               "feature anchors and standalone Settings anchors reach their pages")
        suite.expect(AppFeature.allCases.allSatisfy(\.hasNavigableSettingsDestination),
               "every feature links to a separate configuration surface")
        suite.expect(AppFeature.monitorCPU.settingsDestination == FeatureSettingsDestination(.monitor)
                && AppFeature.fanControl.settingsDestination
                == FeatureSettingsDestination(.monitor, sectionAnchor: .fanControl),
               "shared monitor destinations distinguish the dedicated fan controls")
        let settingsRouter = SettingsRouter.shared
        var settingsRequestCount = 0
        var settingsRequestsPublishedReady = true
        let settingsRequestObservation = settingsRouter.$requestID
            .dropFirst()
            .sink { requestID in
                settingsRequestCount += 1
                settingsRequestsPublishedReady =
                    settingsRequestsPublishedReady
                    && settingsRouter.pendingDestinationRequest?.id == requestID
            }
        let repeatedDestination = FeatureSettingsDestination(.clipboard, sectionAnchor: .pastePlain)
        settingsRouter.request(repeatedDestination)
        let firstSettingsRequestID = settingsRouter.requestID
        settingsRouter.request(repeatedDestination)
        suite.expect(settingsRouter.destination == repeatedDestination
                && settingsRouter.page == repeatedDestination.page,
               "a Settings destination request selects its page and preserves its anchor")
        suite.expect(settingsRequestCount == 2 && settingsRouter.requestID != firstSettingsRequestID,
               "repeated requests for the same Settings destination remain observable")
        suite.expect(settingsRequestsPublishedReady,
               "a Settings request is ready to consume when its request identity is published")
        let repeatedSettingsRequestID = settingsRouter.requestID
        settingsRouter.consumeDestinationRequest(id: firstSettingsRequestID)
        suite.expect(settingsRouter.pendingDestinationRequest?.id == repeatedSettingsRequestID,
               "consuming an older Settings request cannot clear a newer request")
        settingsRouter.consumeDestinationRequest(id: repeatedSettingsRequestID)
        suite.expect(settingsRouter.pendingDestinationRequest == nil,
               "a handled Settings destination request is cleared")

        let featuresDestination = FeatureSettingsDestination(.features)
        settingsRouter.request(featuresDestination, targetFeature: .homebrew)
        let firstFeatureTargetRequestID = settingsRouter.requestID
        suite.expect(settingsRouter.pendingFeatureTarget?.id == firstFeatureTargetRequestID
                && settingsRouter.pendingFeatureTarget?.feature == .homebrew,
               "requesting Features with a target feature publishes a matching feature-target request")
        settingsRouter.request(featuresDestination, targetFeature: .homebrew)
        let secondFeatureTargetRequestID = settingsRouter.requestID
        suite.expect(secondFeatureTargetRequestID != firstFeatureTargetRequestID
                && settingsRouter.pendingFeatureTarget?.id == secondFeatureTargetRequestID,
               "repeated requests for the same target feature remain observable")
        settingsRouter.consumeFeatureTarget(id: firstFeatureTargetRequestID)
        suite.expect(settingsRouter.pendingFeatureTarget?.id == secondFeatureTargetRequestID,
               "consuming an older feature-target request cannot clear a newer target")
        settingsRouter.consumeFeatureTarget(id: secondFeatureTargetRequestID)
        suite.expect(settingsRouter.pendingFeatureTarget == nil,
               "a handled feature-target request is cleared")
        settingsRouter.request(featuresDestination, targetFeature: .portManager)
        suite.expect(settingsRouter.pendingFeatureTarget?.feature == .portManager,
               "requesting a different target feature is observable")
        settingsRouter.request(repeatedDestination)
        suite.expect(settingsRouter.pendingFeatureTarget == nil,
               "a later generic request clears any unconsumed feature target so it cannot leak into unrelated navigation")

        settingsRouter.cleanerTool = "tool-id"
        settingsRouter.request(FeatureSettingsDestination(.cleaner))
        suite.expect(settingsRouter.page == .cleaner && settingsRouter.cleanerTool == "tool-id",
               "requesting Cleaner Settings preserves its one-shot tool hint")
        settingsRouter.consumeDestinationRequest(id: settingsRouter.requestID)
        settingsRouter.cleanerTool = nil
        settingsRouter.page = .general
        withExtendedLifetime(settingsRequestObservation) {}

        let historyRouter = SettingsRouter()
        let initialHistoryRequestID = historyRouter.requestID
        historyRouter.goBack()
        historyRouter.goForward()
        suite.expect(historyRouter.page == .general
                && historyRouter.requestID == initialHistoryRequestID,
               "an empty Settings history does not navigate or publish requests")
        historyRouter.page = .about
        historyRouter.request(repeatedDestination)
        historyRouter.goBack()
        suite.expect(historyRouter.page == .about
                && historyRouter.destination == FeatureSettingsDestination(.about),
               "Settings Back includes direct sidebar-style page assignments")
        historyRouter.goBack()
        suite.expect(historyRouter.page == .general,
               "Settings Back reaches the initial page")
        let oldestHistoryRequestID = historyRouter.requestID
        historyRouter.goBack()
        suite.expect(historyRouter.requestID == oldestHistoryRequestID,
               "Settings Back stops at the oldest visit")
        historyRouter.goForward()
        suite.expect(historyRouter.page == .about,
               "Settings Forward retraces the visited pages")
        historyRouter.goForward()
        suite.expect(historyRouter.destination == repeatedDestination
                && historyRouter.pendingDestinationRequest?.destination == repeatedDestination,
               "Settings history restores section anchors with a fresh focus request")
        let newestHistoryRequestID = historyRouter.requestID
        historyRouter.goForward()
        suite.expect(historyRouter.requestID == newestHistoryRequestID,
               "Settings Forward stops at the newest visit")

        historyRouter.page = .clipboard
        let refinedDestination = FeatureSettingsDestination(.clipboard, sectionAnchor: .clipboardHistory)
        historyRouter.request(refinedDestination)
        historyRouter.request(refinedDestination)
        historyRouter.goBack()
        suite.expect(historyRouter.page == .about,
               "repeated page selections and same-page section requests do not duplicate history")
        historyRouter.goForward()
        suite.expect(historyRouter.destination == refinedDestination,
               "same-page section requests refine the destination restored by history")
        historyRouter.goBack()
        historyRouter.page = .shortcuts
        let branchedHistoryRequestID = historyRouter.requestID
        historyRouter.goForward()
        suite.expect(historyRouter.page == .shortcuts
                && historyRouter.requestID == branchedHistoryRequestID,
               "a new sidebar visit after Back discards forward history")
        historyRouter.goBack()
        historyRouter.request(FeatureSettingsDestination(.features), targetFeature: .homebrew)
        historyRouter.goForward()
        suite.expect(historyRouter.page == .features,
               "a destination request after Back also discards forward history")
        historyRouter.page = .advanced
        suite.expect(historyRouter.destination == FeatureSettingsDestination(.advanced)
                && historyRouter.pendingDestinationRequest == nil
                && historyRouter.pendingFeatureTarget == nil,
               "direct page navigation synchronizes the destination and clears stale reveal requests")

        let energyToolRouter = SettingsRouter()
        let keepAwakeDestination = FeatureSettingsDestination(.energy, sectionAnchor: .keepAwake)
        energyToolRouter.page = .energy
        energyToolRouter.request(keepAwakeDestination)
        energyToolRouter.request(keepAwakeDestination)
        energyToolRouter.goBack()
        suite.expect(energyToolRouter.destination == FeatureSettingsDestination(.energy),
               "Settings Back returns from an Energy tool to the Energy overview")
        energyToolRouter.goForward()
        suite.expect(energyToolRouter.destination == keepAwakeDestination,
               "Settings Forward retraces Energy tools")
        energyToolRouter.request(FeatureSettingsDestination(.energy), replacingVisit: true)
        energyToolRouter.goBack()
        energyToolRouter.goBack()
        suite.expect(energyToolRouter.page == .general,
               "a fallback replaces the visit instead of adding one")

        let hiddenHistoryRouter = SettingsRouter()
        hiddenHistoryRouter.page = .portManager
        hiddenHistoryRouter.page = .about
        hiddenHistoryRouter.goBack(isPageVisible: { $0 != .portManager })
        suite.expect(hiddenHistoryRouter.page == .general,
               "Settings Back skips pages whose features are no longer available")
        hiddenHistoryRouter.goForward(isPageVisible: { $0 != .portManager })
        suite.expect(hiddenHistoryRouter.page == .about,
               "skipping a hidden page preserves forward history")
        let visibleHistoryRequestID = hiddenHistoryRouter.requestID
        hiddenHistoryRouter.goBack(isPageVisible: { _ in false })
        suite.expect(hiddenHistoryRouter.page == .about
                && hiddenHistoryRouter.requestID == visibleHistoryRequestID,
               "Settings history stays put when no earlier page is visible")
        hiddenHistoryRouter.cleanerTool = "stale-tool"
        hiddenHistoryRouter.goBack()
        suite.expect(hiddenHistoryRouter.page == .portManager
                && hiddenHistoryRouter.cleanerTool == nil,
               "history can revisit re-enabled pages without replaying a stale Cleaner tool hint")

        let toolHistoryRouter = SettingsRouter()
        let sharedMonitorDestination = AppFeature.monitorGPU.settingsDestination
        toolHistoryRouter.request(sharedMonitorDestination, sidebarFeature: .monitorGPU)
        suite.expect(toolHistoryRouter.sidebarFeature == .monitorGPU,
               "Settings navigation keeps the requested tool when tools share a section")
        toolHistoryRouter.request(sharedMonitorDestination, sidebarFeature: .monitorCPU)
        suite.expect(toolHistoryRouter.sidebarFeature == .monitorCPU,
               "switching between tools on one section updates the selected tool")
        let fanDestination = AppFeature.fanControl.settingsDestination
        toolHistoryRouter.request(fanDestination, sidebarFeature: .fanControl)
        toolHistoryRouter.page = .about
        toolHistoryRouter.goBack()
        suite.expect(toolHistoryRouter.destination == fanDestination
                && toolHistoryRouter.sidebarFeature == .fanControl,
               "Settings Back restores the selected tool alongside its destination")
        toolHistoryRouter.goForward()
        suite.expect(toolHistoryRouter.page == .about && toolHistoryRouter.sidebarFeature == nil,
               "visiting a generic page clears the previous tool selection")
    }
}


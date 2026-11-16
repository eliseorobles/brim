// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A tab leaves the panel and the Dynamic Island once none of its gate
/// features is installed, so a row whose feature the gate leaves out is
/// unreachable when that feature is the only one installed. The sections and
/// rows are the production enums, generated from source.
enum MenuPanelSectionGateContract {
    static func run(_ suite: TestSuite) {
        func expectGate(_ section: PanelSectionID, keeps features: [AppFeature], _ rows: String) {
            let missing = features.filter { !section.featureGate.contains($0) }.map(\.rawValue)
            suite.expect(missing.isEmpty,
                         "every \(rows) row keeps the \(section.rawValue) tab available, missing \(missing)")
        }
        expectGate(.controls, keeps: [.notch], "control")
        expectGate(.utilities, keeps: UtilityPanelItem.allCases.map(\.feature), "utility")
        expectGate(.system, keeps: [.connectedDevices], "connected devices")
        let savedOrder = UtilityPanelItem.allCases.filter { $0 != .portManager }.map(\.rawValue)
        let restoredOrder = Defaults.sanitizedPanelItemOrder(savedOrder.joined(separator: ","),
                                                           defaultOrder: UtilityPanelItem.allCases.map(\.rawValue))
        suite.expect(restoredOrder == savedOrder + [UtilityPanelItem.portManager.rawValue],
                     "existing custom utility orders gain a new row without losing their order")
    }
}

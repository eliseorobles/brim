// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The price list shipped inside the app.
enum AgentPriceSource {
    static func bundled() -> AgentPriceList? {
        guard let url = Bundle.main.url(forResource: "agent-prices", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return AgentPriceList.decode(data)
    }
}

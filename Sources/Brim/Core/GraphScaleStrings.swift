// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

struct GraphScaleStrings {
    let title: String

    static func localized(_ language: AppLanguage) -> GraphScaleStrings {
        switch language {
        case .enUS: return .init(title: "Show graph scale")
        }
    }
}

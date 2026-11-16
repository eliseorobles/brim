// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

/// Reading the keyboard input source now typing through the system's Text
/// Input Sources services, for the island's layout notice.
enum InputSourceSelection {
    /// The short code the island's layout notice shows: the source's first
    /// language without its script or region, so "zh-Hans" reads as ZH. Empty
    /// when a source claims no language, which leaves the notice its mark alone.
    static func shortCode(languages: [String]) -> String {
        guard let base = languages.first?.split(separator: "-").first else { return "" }
        return base.uppercased()
    }

    /// What the island's notice says about the source now typing: its id, so
    /// a caller can tell one change from the next, its short code and the
    /// name the system itself shows in the Input menu.
    struct Reading: Equatable {
        let id: String
        let code: String
        let name: String
    }

    static func currentReading() -> Reading? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = inputSourceString(source, property: kTISPropertyInputSourceID)
        else { return nil }
        return Reading(id: id,
                       code: shortCode(languages: languages(of: source)),
                       name: inputSourceString(source, property: kTISPropertyLocalizedName) ?? "")
    }

    /// The languages a source types, in the order TIS keeps them.
    static func languages(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let list = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        else { return [] }
        return list
    }

    static func inputSourceString(_ source: TISInputSource,
                                  property: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

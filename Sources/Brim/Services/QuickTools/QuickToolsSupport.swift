// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import UniformTypeIdentifiers

enum QuickToolsSupport {
    // MARK: - Grid navigation

    enum GridDirection {
        case up, down, left, right
    }

    /// Keyboard navigation over a row-major grid: arrows move by one cell,
    /// clamped to the existing items (no wrapping, so the selection never
    /// jumps surprisingly from one edge to the other).
    static func gridIndex(after index: Int,
                          count: Int,
                          columns: Int,
                          direction: GridDirection) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        let candidate: Int
        switch direction {
        case .left: candidate = current - 1
        case .right: candidate = current + 1
        case .up: candidate = current - columns
        case .down: candidate = current + columns
        }
        guard candidate >= 0, candidate < count else { return current }
        if direction == .left, current % columns == 0 { return current }
        if direction == .right, current % columns == columns - 1 { return current }
        return candidate
    }

    // MARK: - Paste as plain text

    /// Whether a menu item is an app's own matching-style paste, judged by its
    /// key equivalent instead of its localized title. The universal
    /// convention is ⌥⇧⌘V; in the AX menu attributes that is command
    /// character "V" with the shift (1) and option (2) bits set and nothing
    /// else (0 alone means a plain ⌘ equivalent). ⇧⌘V and ⌃ variants are
    /// deliberately out: in several apps those are different edit commands,
    /// and pressing one would touch the document (issue #349).
    static func isMatchStyleEquivalent(commandCharacter: String?,
                                       modifierMask: UInt32?,
                                       isEnabled: Bool) -> Bool {
        let shiftAndOption: UInt32 = 1 | 2
        return commandCharacter?.uppercased() == "V"
            && modifierMask == shiftAndOption
            && isEnabled
    }

    /// The text a picture or clip copied on its own carries beside it: nothing,
    /// or one link or media file name, as a browser or a chat copies an image.
    /// Anything else, a cell's "example.com" or "2.4GHz" included, is text
    /// that came with a picture of itself and still pastes plain.
    static func isMediaTextFallback(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("data:") || lowercased.hasPrefix("blob:")
            || (trimmed.contains("://") && URL(string: trimmed)?.scheme != nil) { return true }
        let name = trimmed as NSString
        guard !name.deletingPathExtension.isEmpty, !name.pathExtension.isEmpty,
              let type = UTType(filenameExtension: name.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
    }

}

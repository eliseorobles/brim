// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import Combine
import Foundation

/// The app's one memory-pressure feed: a push source the kernel fires when
/// pressure changes (DISPATCH_MEMORYPRESSURE_NORMAL/WARN/CRITICAL), with the
/// level read once per event through SystemMonitor.readMemoryPressure. The
/// Memory module (the app's one memory notifier) and the menu bar tint
/// listen here; nothing samples pressure on a timer to react to it.
final class MemoryPressureMonitor: ObservableObject {
    static let shared = MemoryPressureMonitor()

    /// The level the latest event read.
    @Published private(set) var level: MemoryPressure
    /// Every event, with the level read for it.
    let events = PassthroughSubject<MemoryPressure, Never>()

    private var source: DispatchSourceMemoryPressure?

    private init() {
        level = SystemMonitor.readMemoryPressure()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.pressureChanged() }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }

    private func pressureChanged() {
        let read = SystemMonitor.readMemoryPressure()
        // A failed read keeps the level the last good one gave.
        guard read != .unknown else { return }
        if read != level { level = read }
        events.send(read)
    }
}

extension MemoryPressure {
    /// The level as a memory-tight episode reads it; a failed read is normal.
    var episodeLevel: MemoryTightEpisode.Pressure {
        switch self {
        case .warning: return .warning
        case .critical: return .critical
        case .normal, .unknown: return .normal
        }
    }
}

/// The menu bar item's only reaction to memory: a subtle tint of the glyph at
/// warning and critical, no badge and no animation, and nothing at normal.
enum MemoryMenuBarTint {
    static func color(for level: MemoryPressure) -> NSColor? {
        guard AppFeature.monitorMemory.isAvailable else { return nil }
        switch level {
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .normal, .unknown: return nil
        }
    }

    /// For the menu bar's redraw check.
    static func key(for level: MemoryPressure) -> String {
        color(for: level) == nil ? "-" : String(describing: level)
    }
}

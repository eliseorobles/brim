// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation
import IOKit

/// Reads and writes the built-in display's brightness for closed-lid
/// dimming, over DisplayServices, which has no public API: its symbols
/// resolve once at runtime and dimming is skipped wherever one is missing.
/// Only the built-in panel: an attached external display is not under the
/// lid and is left exactly as it was.
enum LidDisplayDimmer {
    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32

    private static let displayServicesHandle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightnessFn? = symbol("DisplayServicesGetBrightness")
    private static let setBrightness: SetBrightnessFn? = symbol("DisplayServicesSetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let displayServicesHandle, let pointer = dlsym(displayServicesHandle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Nil on a Mac without a lid, or when the power domain cannot be read.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    /// `CGGetOnlineDisplayList` still reports the built-in panel once the lid
    /// closes and it drops out of the active list, which is what lets it be
    /// found and written at all while the lid is shut.
    static func builtInDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Nil when the panel cannot be identified or its reading failed — never
    /// a stand-in zero, which `LidDimmingSupport` would take as a literal
    /// (and wrong) brightness to save.
    static func currentBrightness() -> Double? {
        guard let id = builtInDisplayID(), let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    /// True only when the panel was found in the online list and the write
    /// itself reported success — never assumed from having merely asked.
    @discardableResult
    static func setBrightness(_ value: Double) -> Bool {
        guard let id = builtInDisplayID(), let setBrightness else { return false }
        return setBrightness(id, Float(value)) == 0
    }
}

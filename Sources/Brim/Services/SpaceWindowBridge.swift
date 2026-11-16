// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// Window-server queries around Spaces, resolved at runtime so a macOS that
/// drops a symbol degrades to "unknown" instead of failing to launch. The
/// island reads the display topology to hide in fullscreen Spaces, and the
/// menu panel reads a window's Spaces before handing activation back.
///
/// Accessibility cannot describe a window parked on a Space that is not
/// visible (measured on macOS 26 and 27). The window server is the only
/// witness that such a window exists, and the only reliable tell between a
/// real parked window and a stale leftover surface: real windows normally
/// belong to at least one Space, leftovers belong to none.
enum SpaceWindowBridge {
    private typealias ConnectionID = UInt32

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, name)
    }

    private static let connection: ConnectionID = {
        typealias Function = @convention(c) () -> ConnectionID
        guard let symbol = symbol("CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(symbol, to: Function.self)()
    }()

    private typealias WindowIsOrderedInFunction =
        @convention(c) (ConnectionID, CGWindowID, UnsafeMutablePointer<UInt8>) -> CGError
    private static let windowIsOrderedIn: WindowIsOrderedInFunction? = {
        guard let symbol = symbol("CGSWindowIsOrderedIn") else { return nil }
        return unsafeBitCast(symbol, to: WindowIsOrderedInFunction.self)
    }()

    /// Unlike on-screen visibility, ordering survives a move to another desktop.
    /// A dismissed surface can retain its desktop assignment without being ordered.
    /// Keep an unavailable query distinct from an explicit ordered-out answer.
    static func isWindowOrderedIn(_ windowID: CGWindowID) -> Bool? {
        guard connection != 0, let windowIsOrderedIn else { return nil }
        var ordered: UInt8 = 0
        guard windowIsOrderedIn(connection, windowID, &ordered) == .success else { return nil }
        return ordered != 0
    }

    // MARK: - Space membership

    private typealias CopySpacesFunction =
        @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let copySpacesForWindows: CopySpacesFunction? = {
        guard let symbol = symbol("CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(symbol, to: CopySpacesFunction.self)
    }()

    /// Whether `spaces(of:)` can actually answer in this session. Callers use
    /// it to tell "this surface belongs to no Space" (the leftover signature)
    /// apart from "the Space queries are unavailable here", so a macOS that
    /// drops the private symbol keeps the pre-existing behavior instead of
    /// misreading every window as a leftover (issue #807).
    static var canResolveSpaces: Bool {
        connection != 0 && copySpacesForWindows != nil
    }

    /// Every Space (user desktops and fullscreen Spaces alike) containing the
    /// window. Empty for leftover surfaces, and when the query is unavailable.
    static func spaces(of windowID: CGWindowID) -> [UInt64] {
        resolvedSpaces(of: windowID) ?? []
    }

    /// An empty answer confirms a surface belongs to no Space. Nil means the
    /// query is unavailable or failed for this window; callers deciding whether
    /// to quit an app must not mistake that uncertainty for a closed window.
    static func resolvedSpaces(of windowID: CGWindowID) -> [UInt64]? {
        guard connection != 0, let copySpacesForWindows else { return nil }
        let mask: Int32 = 0x7
        guard let array = copySpacesForWindows(connection, mask,
                                               [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber]
        else { return nil }
        return array.map(\.uint64Value)
    }

    // MARK: - Display topology

    private typealias CopyDisplaySpacesFunction = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private static let copyManagedDisplaySpaces: CopyDisplaySpacesFunction? = {
        guard let symbol = symbol("CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(symbol, to: CopyDisplaySpacesFunction.self)
    }()

    struct Topology {
        struct DisplayInfo {
            let displayID: CGDirectDisplayID?
            let spaces: [UInt64]
            let fullscreenSpaces: Set<UInt64>
            let currentSpace: UInt64?
        }

        /// With separate Spaces, only the island's display controls visibility.
        /// A shared Space applies to every display even if its UUID is absent.
        func isFullscreen(on displayID: CGDirectDisplayID, separateSpaces: Bool) -> Bool {
            let candidates = separateSpaces ? displays.filter { $0.displayID == displayID } : displays
            return candidates.contains { display in
                display.currentSpace.map { display.fullscreenSpaces.contains($0) } == true
            }
        }

        /// Displays in order.
        let displays: [DisplayInfo]
        /// The Space currently showing on each display.
        var visibleSpaces: Set<UInt64> { Set(displays.compactMap(\.currentSpace)) }
        /// Native fullscreen Spaces. Managed-display dictionaries use type 4
        /// for these and type 0 for ordinary desktops on current macOS.
        var fullscreenSpaces: Set<UInt64> {
            displays.reduce(into: []) { $0.formUnion($1.fullscreenSpaces) }
        }
    }

    /// Captures AppKit's display identity while the caller is on main. The
    /// resulting values are safe to carry to window-enumeration workers.
    static func displayIDsByUUID() -> [String: CGDirectDisplayID] {
        var map: [String: CGDirectDisplayID] = [:]
        for screen in NSScreen.screens {
            guard let screenNum = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(screenNum)?.takeRetainedValue(),
                  let uuidStr = CFUUIDCreateString(nil, uuid) as String?
            else { continue }
            map[uuidStr] = screenNum
        }
        return map
    }

    /// Main-thread callers can keep using the AppKit-backed display mapping.
    static func topology() -> Topology? {
        topology(displayIDsByUUID: displayIDsByUUID())
    }

    /// Resolves Space topology using display values captured by the caller.
    /// This overload does not access AppKit and is safe for worker queues.
    static func topology(displayIDsByUUID: [String: CGDirectDisplayID]) -> Topology? {
        guard connection != 0, let copyManagedDisplaySpaces,
              let displayDicts = copyManagedDisplaySpaces(connection)?
                .takeRetainedValue() as? [[String: Any]],
              !displayDicts.isEmpty
        else { return nil }

        var displays: [Topology.DisplayInfo] = []
        for display in displayDicts {
            let spaceDictionaries = display["Spaces"] as? [[String: Any]] ?? []
            let row = spaceDictionaries
                .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard !row.isEmpty else { continue }
            let fullscreenSpaces = Set(spaceDictionaries.compactMap { space -> UInt64? in
                guard (space["type"] as? NSNumber)?.intValue == 4 else { return nil }
                return (space["id64"] as? NSNumber)?.uint64Value
            })
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber
            let uuidStr = display["Display Identifier"] as? String
            let displayID = uuidStr.flatMap { displayIDsByUUID[$0] }
            displays.append(Topology.DisplayInfo(displayID: displayID,
                                                 spaces: row,
                                                 fullscreenSpaces: fullscreenSpaces,
                                                 currentSpace: current?.uint64Value))
        }
        guard !displays.isEmpty else { return nil }
        return Topology(displays: displays)
    }
}

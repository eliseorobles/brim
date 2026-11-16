// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CoreAudio
import Darwin
import Foundation
import IOKit.pwr_mgt

/// The Mac's memory as the Memory section's header shows it.
struct MemorySummary: Equatable {
    var pressure: MemoryPressure = .unknown
    var used: UInt64 = 0
    var total: UInt64 = 0
    /// RAM the compressor holds (compressor pages × page size).
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var roomForHeavyWork: Bool { MemoryRules.roomForHeavyWork(compressed: compressed) }
}

/// One-shot reads a scan makes besides the process table. Each runs when a
/// scan runs (on an event), never on a timer.
enum MemorySystemReads {
    /// One whole-Mac reading: one VM statistics read (swap-ins, swap-outs,
    /// what the compressor holds), one SystemInfo.memoryUsage() (used and
    /// compressor RAM, as the header shows them) and one vm.swapusage read.
    static func measurement() -> MemoryMeasurement? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let swapRead = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let memory = SystemInfo.memoryUsage()
        // An unread swap stays unknown (MemoryMeasurement.reading): never 0.
        return MemoryMeasurement.reading(stats: VMStatisticsDecoder.read(), used: memory?.used, total: memory?.total,
                                         compressorRAM: memory?.compressed,
                                         swap: swapRead ? (used: swap.xsu_used, total: swap.xsu_total) : nil,
                                         page: UInt64(vm_kernel_page_size), at: Date(),
                                         awake: ProcessInfo.processInfo.systemUptime)
    }

    /// The header's numbers, from a measurement.
    static func summary(_ measurement: MemoryMeasurement, pressure: MemoryPressure) -> MemorySummary {
        MemorySummary(pressure: pressure, used: measurement.used, total: ProcessInfo.processInfo.physicalMemory,
                      compressed: measurement.compressorRAM, swapUsed: measurement.swapUsed,
                      swapTotal: measurement.swapTotal)
    }

    /// The pids of the person's running launchd jobs. Read with `launchctl
    /// list`, which only reads; `launchctl print pid/<pid>` is never used, as
    /// it registers a domain for the pid it is asked about.
    static func launchdJobs() -> Set<pid_t>? {
        let result = Shell.run("/bin/launchctl", ["list"], timeout: 5)
        guard result.status == 0 else { return nil }
        return MemoryRules.launchdJobPIDs(fromList: result.output)
    }

    /// Processes holding a power assertion (caffeinate, a download, a call).
    static func powerAssertionHolders() -> Set<pid_t> {
        var snapshot: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&snapshot) == kIOReturnSuccess,
              let assertions = snapshot?.takeRetainedValue() as? [NSNumber: Any] else { return [] }
        return Set(assertions.keys.map { pid_t($0.int32Value) })
    }

    /// Processes with audio running in or out right now (CoreAudio's
    /// process objects).
    static func audioActive() -> Set<pid_t> {
        var result = Set<pid_t>()
        for object in audioProcessObjects() {
            var pid: pid_t = -1
            guard read(object, kAudioProcessPropertyPID, &pid), pid > 0 else { continue }
            var input: UInt32 = 0
            var output: UInt32 = 0
            _ = read(object, kAudioProcessPropertyIsRunningInput, &input)
            _ = read(object, kAudioProcessPropertyIsRunningOutput, &output)
            if input != 0 || output != 0 { result.insert(pid) }
        }
        return result
    }

    /// CoreAudio's process objects: one for every process with an audio
    /// client, whether or not it is playing or recording right now.
    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { $0 != 0 }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)) == noErr
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// The words of Brim's Memory module: the menu panel section, its Settings
/// page and its notification.
struct MemoryStrings {
    let title: String
    let panelDescription: String
    let pressureNormal: String
    let pressureWarning: String
    let pressureCritical: String
    let usedOfFormat: String
    let compressedFormat: String
    let roomForHeavyWork: String
    let wait: String
    let swapFormat: String
    let testRunInProgress: String

    let leftovers: String
    let heavyIdle: String
    let helpers: String
    let runningNow: String
    let activity: String
    let nothingToClean: String
    let showMoreFormat: String
    let showFewer: String

    let parentGoneFormat: String
    let idle: String
    let busy: String
    let measuring: String
    let noNetwork: String
    let portsFormat: String
    let localSocket: String
    let leftByFormat: String
    let endsAutomatically: String
    let autoInFormat: String
    let unusedForFormat: String
    let runningForFormat: String
    let simulatorsFormat: String

    let testRun: String
    let devServer: String
    let agentSession: String
    let service: String
    let keepingAwake: String
    let playingAudio: String
    let networkInUse: String
    let inTerminal: String
    let kept: String
    let protectedTool: String
    let backgroundServer: String
    let languageServerInUse: String
    let languageServerIdle: String
    let staleMCP: String
    let simulatorClone: String

    let end: String
    let force: String
    let quit: String
    let reopen: String
    let shutDown: String
    let keep: String
    let copyCommand: String
    let waitingToQuit: String

    let logAutoEnded: String
    let logEnded: String
    let logForced: String
    let logQuit: String
    let logShutDown: String
    let stillRunning: String
    let failed: String
    let ending: String

    let autoCleanTitle: String
    let autoCleanHelp: String
    let idleAfterTitle: String
    let idleAfterHelp: String
    let hoursFormat: String
    let keepTitle: String
    let keepHelp: String
    let keepPlaceholder: String
    let add: String
    let remove: String
    let notifyTitle: String
    let notifyHelp: String
    let tiersTitle: String
    let tierInform: String
    let tierNotify: String
    let tierOneClick: String
    let tierAutomatic: String
    let settingsLink: String

    /// Under the System section's memory list, and on Kill Process's rows
    /// for other users' processes: what Brim cannot measure, said plainly.
    let otherUsersNotMeasuredFormat: String
    let notMeasuredHelp: String

    let notificationTitle: String
    let notificationBodyFormat: String
    let notificationNothing: String
    let quitThem: String
    let review: String

    // What holds the memory ("Biggest now"), measured deltas, scan cost.
    let biggestNow: String
    let systemProcess: String
    let inSessionFormat: String
    let groupOfFormat: String
    let growingFormat: String
    let aboveNormal: String
    let healthyFseventsd: String
    let unknownSize: String
    let atLeastFormat: String
    let systemNeverEnded: String
    let fseventsdLeakNote: String
    let copyRestartCommand: String
    let tableTooLargeFormat: String
    let slowClientsFormat: String
    let notMeasuredSystemFormat: String
    let autoWhenTight: String
    let unreadable: String
    let logEndedOutside: String
    let logRestartedOutside: String
    let estimatedFormat: String
    let measuredChangeFormat: String
    let measuredHelp: String
    let lastScanFormat: String
    let notificationCriticalTitle: String
    let leakTitle: String
    let leakTail: String
    let holderSystemFormat: String
    let holderOwnFormat: String
    let holderGrowingFormat: String
    let knownLeakTail: String
    let andMoreFormat: String

    // The runaway brake and alerts the system did not show (T-52).
    let logRunawayEnded: String
    let logRunawayFailed: String
    let runawayAtFormat: String
    let runawayForced: String
    let runawayNotificationTitle: String
    let runawayNotificationTail: String
    let tierRunaway: String
    let logAlertNotShown: String
    let alertNotShownFormat: String
    let notificationsOff: String
    let openNotificationSettings: String
    let dismiss: String

    func usedOf(_ used: String, _ total: String) -> String { String(format: usedOfFormat, used, total) }
    func compressed(_ amount: String) -> String { String(format: compressedFormat, amount) }
    func swap(_ used: String, _ total: String) -> String { String(format: swapFormat, used, total) }
    func parentGone(_ duration: String) -> String { String(format: parentGoneFormat, duration) }
    func ports(_ list: String) -> String { String(format: portsFormat, list) }
    func leftBy(_ app: String) -> String { String(format: leftByFormat, app) }
    func autoIn(_ duration: String) -> String { String(format: autoInFormat, duration) }
    func unusedFor(_ duration: String) -> String { String(format: unusedForFormat, duration) }
    func runningFor(_ duration: String) -> String { String(format: runningForFormat, duration) }
    func simulators(_ count: Int) -> String { String(format: simulatorsFormat, count) }
    func showMore(_ count: Int) -> String { String(format: showMoreFormat, count) }
    func hours(_ count: Int) -> String { String(format: hoursFormat, count) }
    func otherUsersNotMeasured(_ count: Int) -> String { String(format: otherUsersNotMeasuredFormat, count) }
    func inSession(_ agent: MemoryRules.Agent) -> String { String(format: inSessionFormat, Self.agentName(agent)) }
    func groupOf(_ count: Int) -> String { String(format: groupOfFormat, count) }
    func growing(_ rate: String) -> String { String(format: growingFormat, rate) }
    func atLeast(_ amount: String) -> String { String(format: atLeastFormat, amount) }
    func tableTooLarge(_ time: String) -> String { String(format: tableTooLargeFormat, time) }
    func slowClients(_ list: String) -> String { String(format: slowClientsFormat, list) }
    func notMeasuredSystem(_ count: Int) -> String { String(format: notMeasuredSystemFormat, count) }
    func estimated(_ amount: String) -> String { String(format: estimatedFormat, amount) }
    func lastScan(_ seconds: String, _ processes: String) -> String { String(format: lastScanFormat, seconds, processes) }

    /// "Mac: used −0.9 GB · swap −0.3 GB · compressed −0.4 GB".
    func measuredChange(_ change: MemoryMeasuredChange) -> String {
        String(format: measuredChangeFormat, MemoryFormat.signedBytes(change.used),
               MemoryFormat.signedBytes(change.swapUsed), MemoryFormat.signedBytes(change.compressorRAM))
    }

    static func agentName(_ agent: MemoryRules.Agent) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The sentence that names a holder:
    /// "fseventsd (system) 54 GB, growing ~1.5 GB/h. Known macOS leak; Brim can't end it.",
    /// "WindowServer and 1 more (system) 1.7 GB.",
    /// "node · GreenUp (in a Claude session) 35 GB, growing ~6 GB/h."
    func holderLine(_ holder: MemoryHolder) -> String {
        var name = holder.name
        if case .coalitionTotal(_, let members) = holder.memory, members > 1 {
            name = String(format: andMoreFormat, holder.name, members - 1)
        }
        let size = MemoryFormat.size(holder.memory, unknown: unknownSize)
        var line: String
        switch holder.kind {
        case .system:
            line = String(format: holderSystemFormat, name, size)
        case .own(let project, let agent):
            var title = MemoryFormat.title(name: name, count: 1, project: project)
            if let agent { title += " (" + inSession(agent) + ")" }
            line = String(format: holderOwnFormat, title, size)
        }
        if holder.growing, let perHour = holder.perHour {
            line += String(format: holderGrowingFormat, MemoryFormat.rate(perHour))
        }
        line += "."
        if holder.isFSEventsLeak { line += knownLeakTail }
        return line
    }
    /// An Activity row's label: "Ended automatically", "Ended runaway",
    /// "Alert not shown (notifications off)".
    func logKind(_ entry: MemoryActivityEntry) -> String {
        switch entry.kind {
        case .autoEnded: return logAutoEnded
        case .ended: return logEnded
        case .forced: return logForced
        case .quitApp: return logQuit
        case .shutDownSimulator: return logShutDown
        case .holderExited: return entry.restartedByLaunchd == true ? logRestartedOutside : logEndedOutside
        case .runawayEnded: return entry.outcome == .failed ? logRunawayFailed : logRunawayEnded
        case .alertNotShown: return logAlertNotShown
        }
    }

    /// An Activity row's title: what it acted on, and for a runaway the
    /// footprint it had right before the signal ("GreenUp at 561 GB").
    func logTitle(_ entry: MemoryActivityEntry) -> String {
        guard entry.kind == .runawayEnded else { return entry.title }
        return String(format: runawayAtFormat, entry.title, MemoryFormat.bytes(entry.runawayBytes ?? entry.estimatedBytes))
    }

    /// The row as one sentence: "Ended runaway GreenUp at 561 GB",
    /// "Alert not shown (notifications off): Memory is tight — …".
    func logSentence(_ entry: MemoryActivityEntry) -> String {
        logKind(entry) + (entry.kind == .alertNotShown ? ": " : " ") + logTitle(entry)
    }

    /// "Apps unused for 8 h+: 3 (4.1 GB). Leftovers: 1 (389 MB)."
    func notificationBody(apps: Int, hours: Int, appsSize: String, leftovers: Int, leftoversSize: String) -> String {
        guard apps + leftovers > 0 else { return notificationNothing }
        return String(format: notificationBodyFormat, apps, hours, appsSize, leftovers, leftoversSize)
    }
}

extension MemoryStrings {
    static let enUS = MemoryStrings(
        title: "Memory",
        panelDescription: "Memory pressure, leftovers from dev work, and apps unused for hours.",
        pressureNormal: "Normal",
        pressureWarning: "Warning",
        pressureCritical: "Critical",
        usedOfFormat: "%@ of %@ used",
        compressedFormat: "%@ compressed",
        roomForHeavyWork: "Room for heavy work",
        wait: "Wait",
        swapFormat: "Swap %@ of %@",
        testRunInProgress: "Test run in progress",
        leftovers: "Leftovers",
        heavyIdle: "Heavy & idle apps",
        helpers: "Long-running helpers",
        runningNow: "Running now",
        activity: "Activity",
        nothingToClean: "Nothing left over.",
        showMoreFormat: "Show %d more",
        showFewer: "Show fewer",
        parentGoneFormat: "parent gone %@",
        idle: "idle",
        busy: "busy",
        measuring: "measuring",
        noNetwork: "no network",
        portsFormat: "ports %@",
        localSocket: "local socket",
        leftByFormat: "left by %@",
        endsAutomatically: "ends automatically",
        autoInFormat: "auto in %@",
        unusedForFormat: "unused %@",
        runningForFormat: "running %@",
        simulatorsFormat: "%d Simulators",
        testRun: "Test run",
        devServer: "Dev server",
        agentSession: "Agent session",
        service: "Service",
        keepingAwake: "Keeping the Mac awake",
        playingAudio: "Playing audio",
        networkInUse: "Network in use",
        inTerminal: "In a terminal",
        kept: "Kept",
        protectedTool: "Protected",
        backgroundServer: "Its own background server",
        languageServerInUse: "In use. Restart it from its editor to free memory.",
        languageServerIdle: "Its editor is gone. It exits or restarts on demand.",
        staleMCP: "MCP server idle for hours",
        simulatorClone: "Simulator clone left booted",
        end: "End",
        force: "Force",
        quit: "Quit",
        reopen: "Reopen",
        shutDown: "Shut down",
        keep: "Keep",
        copyCommand: "Copy command",
        waitingToQuit: "Asked to quit",
        logAutoEnded: "Ended automatically",
        logEnded: "Ended",
        logForced: "Forced",
        logQuit: "Quit",
        logShutDown: "Shut down",
        stillRunning: "Still running after 5 s",
        failed: "Could not end it",
        ending: "Ending…",
        autoCleanTitle: "End leftovers automatically",
        autoCleanHelp: "Only while memory is tight: pressure above normal, or swap growing. Otherwise leftovers are listed for you to end. Only orphaned dev process groups that pass every check: parent and group leader gone 30 min+, idle for 30 awake min, no network or local socket, no terminal, 50 MB+, every reading known. Checked again right before each signal, ended gently, at most 3 per event, each one logged.",
        idleAfterTitle: "Apps count as idle after",
        idleAfterHelp: "Time asleep or behind the lock screen does not count.",
        hoursFormat: "%d h",
        keepTitle: "Keep list",
        keepHelp: "Names, paths or app bundle IDs the module never touches.",
        keepPlaceholder: "Name, /path or bundle ID",
        add: "Add",
        remove: "Remove",
        notifyTitle: "Notify when memory is tight",
        notifyHelp: "One notification per memory-tight episode, naming what holds the memory; and one when fseventsd leaks. None while memory is fine.",
        tiersTitle: "What each tier does",
        tierInform: "Inform: the panel shows memory use, leftovers and idle apps. Always on.",
        tierNotify: "Notify: one notification per memory-tight episode, naming what holds the memory, with Quit them and Review.",
        tierOneClick: "One click: you end a leftover or quit an app from its row.",
        tierAutomatic: "Automatic: only while memory is tight, only orphaned dev process groups, when every check passes again right before the signal.",
        settingsLink: "Memory settings…",
        otherUsersNotMeasuredFormat: "Not measured: %d processes of other users. macOS shows their memory only to admin tools.",
        notMeasuredHelp: "Another user's process: macOS shows its CPU and memory only to admin tools.",
        notificationTitle: "Memory is tight",
        notificationBodyFormat: "Apps unused for %2$d h+: %1$d (%3$@). Leftovers: %4$d (%5$@).",
        notificationNothing: "Nothing idle to quit right now.",
        quitThem: "Quit them",
        review: "Review",
        biggestNow: "Biggest now",
        systemProcess: "system",
        inSessionFormat: "in a %@ session",
        groupOfFormat: "group of %d processes",
        growingFormat: "growing %@",
        aboveNormal: "above normal",
        healthyFseventsd: "healthy is about 4 MB",
        unknownSize: "unknown",
        atLeastFormat: "≥ %@",
        systemNeverEnded: "System process: Brim never ends it.",
        fseventsdLeakNote: "Known macOS leak. Restarting it frees the memory (launchd starts it again); file-event history resets and Spotlight re-indexes for a while.",
        copyRestartCommand: "Copy restart command",
        tableTooLargeFormat: "reported 'event table has grown too large' at %@",
        slowClientsFormat: "slow clients: %@",
        notMeasuredSystemFormat: "%d system processes not measured",
        autoWhenTight: "auto when memory is tight",
        unreadable: "can't read",
        logEndedOutside: "Ended outside Brim",
        logRestartedOutside: "Restarted outside Brim",
        estimatedFormat: "est. %@",
        measuredChangeFormat: "Mac: used %@ · swap %@ · compressed %@",
        measuredHelp: "Measured change of the whole Mac between the action and the last exit; other apps' work counts too.",
        lastScanFormat: "Last scan: %@ s for %@ processes",
        notificationCriticalTitle: "Memory is critical",
        leakTitle: "fseventsd is leaking memory",
        leakTail: " Copy the restart command and run it in Terminal.",
        holderSystemFormat: "%@ (system) %@",
        holderOwnFormat: "%@ %@",
        holderGrowingFormat: ", growing %@",
        knownLeakTail: " Known macOS leak; Brim can't end it.",
        andMoreFormat: "%@ and %d more",
        logRunawayEnded: "Ended runaway",
        logRunawayFailed: "Could not end runaway",
        runawayAtFormat: "%@ at %@",
        runawayForced: "forced after 5 s",
        runawayNotificationTitle: "Brim ended a runaway process",
        runawayNotificationTail: " It held more than half of the Mac's memory while memory was tight.",
        tierRunaway: "Runaway brake: while memory is tight, a process of yours holding more than half of the Mac's memory is ended (gently, then forced after 5 s if it is still the same process and still that big), logged and notified. System processes, apps, agents, editors, terminals and kept ones are never ended.",
        logAlertNotShown: "Alert not shown (notifications off)",
        alertNotShownFormat: "%@ — %@",
        notificationsOff: "Brim can't alert you: notifications are off",
        openNotificationSettings: "Open Notification Settings…",
        dismiss: "Dismiss")
}

extension FeatureStrings {
    static func memory(_ language: AppLanguage) -> MemoryStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

/// How the Memory module writes sizes and durations: footprint in the
/// memory style (1024-based, like Activity Monitor) and short durations.
enum MemoryFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// A size that may be unknown or a lower bound: "1.2 GB", "unknown",
    /// "≥ 1.2 GB". Unknown is never written as 0.
    static func size(_ bytes: UInt64?, incomplete: Bool = false, unknown: String) -> String {
        guard let bytes else { return unknown }
        return incomplete ? "≥ " + self.bytes(bytes) : self.bytes(bytes)
    }

    static func size(_ memory: ProcessMemory, unknown: String) -> String {
        size(memory.bytes, unknown: unknown)
    }

    /// "+1.2 GB", "−0.9 GB": a measured change.
    static func signedBytes(_ value: Int64) -> String {
        let magnitude = bytes(value.magnitude)
        return value < 0 ? "−" + magnitude : "+" + magnitude
    }

    /// "~1.5 GB/h": one decimal under 10, whole above, in 1024-based units.
    static func rate(_ perHour: UInt64) -> String {
        let units: [(String, Double)] = [("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1024)]
        let value = Double(perHour)
        let (unit, scale) = units.first { value >= $0.1 } ?? ("KB", 1024)
        let amount = value / scale
        let text = String(format: amount < 10 ? "%.1f" : "%.0f", locale: MetricFormat.locale, amount)
        return "~\(text) \(unit)/h"
    }

    /// "45 min", "23 h", "6 d"; under a minute, "1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// "python3 ×7 · greenup-test".
    static func title(name: String, count: Int, project: String?) -> String {
        var title = count > 1 ? "\(name) ×\(count)" : name
        if let project, !project.isEmpty, project != name { title += " · " + project }
        return title
    }
}

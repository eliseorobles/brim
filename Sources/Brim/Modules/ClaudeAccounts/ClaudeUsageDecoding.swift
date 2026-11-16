// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// Who a config folder is signed in as, from .claude.json's oauthAccount.
struct ClaudeIdentity: Equatable {
    var accountUuid: String
    var email: String?
    var organizationUuid: String?
    var organizationType: String?
    var rateLimitTier: String?
    var planDisplayName: String?

    var plan: String? {
        ClaudeUsageDecoding.planLabel(organizationType: organizationType, rateLimitTier: rateLimitTier,
                                      planDisplayName: planDisplayName)
    }
}

/// .claude.json's cachedUsageUtilization.extra_usage.
struct ClaudeExtraUsage: Equatable {
    var isEnabled: Bool?
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?
    var disabledReason: String?
}

/// cachedUsageUtilization, accepted only when it belongs to the signed-in
/// account.
struct ClaudeCachedUsage: Equatable {
    var fetchedAtMs: Int64
    var reading: ClaudeAccountReading?
    var extraUsage: ClaudeExtraUsage?

    var fetchedAt: Date { Date(timeIntervalSince1970: TimeInterval(fetchedAtMs) / 1_000) }
}

enum ClaudeCachedUsageStatus: Equatable {
    case accepted
    /// No cachedUsageUtilization, or one without fetchedAtMs.
    case missing
    /// Its accountUuid is not oauthAccount.accountUuid (or one is absent):
    /// the numbers may be another account's.
    case accountMismatch
}

/// What Brim takes from one .claude.json.
struct ClaudeConfigSnapshot: Equatable {
    var identity: ClaudeIdentity?
    /// Set only when usageStatus is .accepted.
    var usage: ClaudeCachedUsage?
    var usageStatus: ClaudeCachedUsageStatus
    /// cachedUsageUtilization.fetchedAtMs whatever account it names: when
    /// Claude Code last fetched usage in this folder. A get_usage check uses it
    /// to tell an answer fetched for it from one served from an old copy.
    var cacheFetchedAtMs: Int64? = nil

    var signedIn: Bool { identity != nil }
}

/// One status-line render's input (Claude Code's statusLine stdin JSON).
/// Every field is optional: rate_limits appears only for subscribers after
/// the first API response, and each window only while it has not reset.
struct ClaudeStatusLineInput: Equatable {
    struct Window: Equatable {
        var usedPercentage: Double
        var resetsAt: Date?
    }

    var sessionId: String?
    var cwd: String?
    var projectDirectory: String?
    var modelId: String?
    var modelDisplayName: String?
    var fiveHour: Window?
    var sevenDay: Window?

    var hasRateLimits: Bool { fiveHour != nil || sevenDay != nil }
}

enum ClaudeUsageDecoding {
    /// .claude.json is rewritten constantly and grows with every project;
    /// today's are about 0.5 MB.
    static let configSizeLimit = 64 << 20

    /// ~/.claude.json for the default account (outside ~/.claude),
    /// <folder>/.claude.json for any other.
    static func configFile(forFolder folder: String, home: String) -> String {
        folder.isEmpty ? home + "/.claude.json" : folder + "/.claude.json"
    }

    // MARK: .claude.json

    static func snapshot(configFile path: String) -> ClaudeConfigSnapshot? {
        guard let data = ClaudeFileIO.read(path, limit: configSizeLimit) else { return nil }
        return snapshot(configData: data)
    }

    /// nil unless the data is a JSON object. JSONSerialization parses the
    /// file; only oauthAccount and cachedUsageUtilization are looked at.
    static func snapshot(configData: Data) -> ClaudeConfigSnapshot? {
        guard let json = ClaudeJSON.parse(configData) as? [String: Any] else { return nil }
        return snapshot(config: json)
    }

    static func snapshot(config json: [String: Any]) -> ClaudeConfigSnapshot {
        let identity = ClaudeJSON.object(json["oauthAccount"]).flatMap(self.identity)
        guard let cache = ClaudeJSON.object(json["cachedUsageUtilization"]),
              let fetched = ClaudeJSON.number(cache["fetchedAtMs"]), fetched > 0 else {
            return ClaudeConfigSnapshot(identity: identity, usage: nil, usageStatus: .missing)
        }
        // Claude Code itself drops a cache whose accountUuid is not the
        // signed-in account's; so does Brim, and an absent one cannot be checked.
        let fetchedAtMs = Int64(fetched)
        guard let identity, let owner = ClaudeJSON.string(cache["accountUuid"]), owner == identity.accountUuid else {
            return ClaudeConfigSnapshot(identity: identity, usage: nil, usageStatus: .accountMismatch,
                                        cacheFetchedAtMs: fetchedAtMs)
        }
        let observed = Date(timeIntervalSince1970: TimeInterval(fetchedAtMs) / 1_000)
        let utilization = ClaudeJSON.object(cache["utilization"]) ?? [:]
        let usage = ClaudeCachedUsage(fetchedAtMs: fetchedAtMs,
                                      reading: reading(utilization: utilization, observedAt: observed, source: .cache),
                                      extraUsage: extraUsage(utilization["extra_usage"]))
        return ClaudeConfigSnapshot(identity: identity, usage: usage, usageStatus: .accepted, cacheFetchedAtMs: fetchedAtMs)
    }

    /// Whether a snapshot carries usage Brim has not taken yet. The file is
    /// rewritten for unrelated keys all the time; only a larger fetchedAtMs
    /// is news.
    static func isNewer(_ snapshot: ClaudeConfigSnapshot, than previousFetchedAtMs: Int64?) -> Bool {
        guard snapshot.usageStatus == .accepted, let usage = snapshot.usage else { return false }
        guard let previousFetchedAtMs else { return true }
        return usage.fetchedAtMs > previousFetchedAtMs
    }

    static func identity(_ account: [String: Any]) -> ClaudeIdentity? {
        guard let uuid = ClaudeJSON.string(account["accountUuid"]) else { return nil }
        return ClaudeIdentity(accountUuid: uuid,
                              email: ClaudeJSON.string(account["emailAddress"]),
                              organizationUuid: ClaudeJSON.string(account["organizationUuid"]),
                              organizationType: ClaudeJSON.string(account["organizationType"]),
                              rateLimitTier: ClaudeJSON.string(account["organizationRateLimitTier"])
                                ?? ClaudeJSON.string(account["userRateLimitTier"]),
                              planDisplayName: ClaudeJSON.string(account["planDisplayName"]))
    }

    static func extraUsage(_ value: Any?) -> ClaudeExtraUsage? {
        guard let extra = ClaudeJSON.object(value) else { return nil }
        return ClaudeExtraUsage(isEnabled: ClaudeJSON.bool(extra["is_enabled"]),
                                monthlyLimit: ClaudeJSON.number(extra["monthly_limit"]),
                                usedCredits: ClaudeJSON.number(extra["used_credits"]),
                                utilization: ClaudeJSON.number(extra["utilization"]),
                                currency: ClaudeJSON.string(extra["currency"]),
                                disabledReason: ClaudeJSON.string(extra["disabled_reason"]))
    }

    /// "Max 20x" from organizationRateLimitTier "default_claude_max_20x";
    /// otherwise the organization type ("claude_pro" is "Pro"), otherwise
    /// planDisplayName.
    static func planLabel(organizationType: String?, rateLimitTier: String?, planDisplayName: String?) -> String? {
        if let tier = rateLimitTier?.lowercased(), let range = tier.range(of: "claude_max_") {
            let multiplier = tier[range.upperBound...].prefix { $0.isASCII && ($0.isNumber || $0 == "x") }
            if !multiplier.isEmpty { return "Max " + String(multiplier) }
        }
        switch organizationType?.lowercased() {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return planDisplayName
        }
    }

    // MARK: Usage windows

    /// The windows of a /api/oauth/usage body, as Claude Code saves it in
    /// cachedUsageUtilization.utilization and answers get_usage's rate_limits:
    /// five_hour and seven_day ({utilization, resets_at}), limits[] (kind
    /// session | weekly_all | weekly_scoped with scope.model.display_name,
    /// percent, resets_at, is_active), seven_day_opus / seven_day_sonnet and
    /// get_usage's model_scoped ([{display_name, utilization, resets_at}]).
    /// nil when the body has no window at all.
    static func reading(utilization body: [String: Any], observedAt: Date,
                        source: ClaudeUsageSource) -> ClaudeAccountReading? {
        func window(_ value: Any?) -> ClaudeUsageWindow? {
            guard let object = ClaudeJSON.object(value), let used = ClaudeJSON.percent(object["utilization"]) else { return nil }
            return ClaudeUsageWindow(utilization: used, resetsAt: ClaudeJSON.date(object["resets_at"]),
                                     observedAt: observedAt, source: source)
        }
        var reading = ClaudeAccountReading(fiveHour: window(body["five_hour"]), sevenDay: window(body["seven_day"]))
        var scoped: [ClaudeScopedWindow] = []
        func addScoped(_ model: String, _ used: Double, _ resets: Date?, _ active: Bool?) {
            guard !scoped.contains(where: { $0.model.lowercased() == model.lowercased() }) else { return }
            scoped.append(ClaudeScopedWindow(model: model, utilization: used, resetsAt: resets, active: active,
                                             observedAt: observedAt, source: source))
        }
        for case let limit as [String: Any] in ClaudeJSON.array(body["limits"]) ?? [] {
            guard let kind = ClaudeJSON.string(limit["kind"]), let percent = ClaudeJSON.percent(limit["percent"]) else { continue }
            let resets = ClaudeJSON.date(limit["resets_at"])
            let limitWindow = ClaudeUsageWindow(utilization: percent, resetsAt: resets, observedAt: observedAt, source: source)
            switch kind {
            case "session":
                if reading.fiveHour == nil { reading.fiveHour = limitWindow }
            case "weekly_all":
                if reading.sevenDay == nil { reading.sevenDay = limitWindow }
            case "weekly_scoped":
                let scope = ClaudeJSON.object(limit["scope"])
                if let model = ClaudeJSON.string(ClaudeJSON.object(scope?["model"])?["display_name"]) {
                    addScoped(model, percent, resets, ClaudeJSON.bool(limit["is_active"]))
                }
            default:
                continue
            }
        }
        for case let row as [String: Any] in ClaudeJSON.array(body["model_scoped"]) ?? [] {
            guard let model = ClaudeJSON.string(row["display_name"]), let used = ClaudeJSON.percent(row["utilization"]) else { continue }
            addScoped(model, used, ClaudeJSON.date(row["resets_at"]), nil)
        }
        for (key, model) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if let named = window(body[key]) { addScoped(model, named.utilization, named.resetsAt, nil) }
        }
        reading.scoped = scoped
        // limits[] is the server's whole list (get_usage's model_scoped is a
        // filtered projection of it): a scoped window it lacks is gone.
        if ClaudeJSON.array(body["limits"]) != nil { reading.scopedReportedAt = observedAt }
        return reading.isEmpty ? nil : reading
    }

    /// The get_usage control response (stream-json control protocol):
    /// `{rate_limits_available, rate_limits: {five_hour, seven_day,
    /// seven_day_opus, seven_day_sonnet, model_scoped?, limits?, extra_usage, …}}`.
    /// nil when plan limits do not apply or none came back.
    static func reading(getUsage response: [String: Any], observedAt: Date) -> ClaudeAccountReading? {
        guard ClaudeJSON.bool(response["rate_limits_available"]) == true,
              let limits = ClaudeJSON.object(response["rate_limits"]) else { return nil }
        return reading(utilization: limits, observedAt: observedAt, source: .check)
    }

    // MARK: Status line

    /// nil unless the data is a JSON object; any field may be missing.
    static func statusLineInput(_ data: Data) -> ClaudeStatusLineInput? {
        guard let json = ClaudeJSON.parse(data) as? [String: Any] else { return nil }
        let workspace = ClaudeJSON.object(json["workspace"])
        let model = ClaudeJSON.object(json["model"])
        let limits = ClaudeJSON.object(json["rate_limits"])
        func window(_ value: Any?) -> ClaudeStatusLineInput.Window? {
            guard let object = ClaudeJSON.object(value),
                  let used = ClaudeJSON.percent(object["used_percentage"]) else { return nil }
            return ClaudeStatusLineInput.Window(usedPercentage: used, resetsAt: ClaudeJSON.date(object["resets_at"]))
        }
        return ClaudeStatusLineInput(sessionId: ClaudeJSON.string(json["session_id"]),
                                     cwd: ClaudeJSON.string(json["cwd"]) ?? ClaudeJSON.string(workspace?["current_dir"]),
                                     projectDirectory: ClaudeJSON.string(workspace?["project_dir"]),
                                     modelId: ClaudeJSON.string(model?["id"]),
                                     modelDisplayName: ClaudeJSON.string(model?["display_name"]),
                                     fiveHour: window(limits?["five_hour"]),
                                     sevenDay: window(limits?["seven_day"]))
    }
}

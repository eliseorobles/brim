// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// A repo's own Stripe server: Stripe's hosted MCP server under a name of its
/// own (OAuth only, decided 2026-11-13). Each account signs in with
/// Stripe's own OAuth the first time a session uses the server (Claude Code's
/// MCP sign-in, in the normal browser), and picks the Stripe account or
/// sandbox on Stripe's consent screen. Claude Code keeps one sign-in per
/// server name and configuration, so stripe-acme and stripe-beta sign in
/// apart; a repo server at Stripe's address also hides plugin:stripe:stripe
/// in that repo. Brim holds no Stripe credential.
enum ClaudeMCPStripe {
    static let url = "https://mcp.stripe.com"
    static let host = "mcp.stripe.com"
    static let prefix = "stripe-"
    /// The kind Brim's record gives the servers it adds this way.
    static let kind = "stripe"

    enum NameProblem: Equatable {
        case empty
        case characters
        case taken
    }

    /// "acme" names the server "stripe-acme".
    static func serverName(nickname: String) -> String { prefix + nickname }

    /// Why the nickname cannot name a server, or nil: lowercase letters,
    /// digits and "-", and a server name nothing else uses.
    static func nicknameProblem(_ nickname: String, taken: Set<String>) -> NameProblem? {
        if nickname.isEmpty { return .empty }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard nickname.count <= 40, nickname.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !nickname.hasPrefix("-"), !nickname.hasSuffix("-") else { return .characters }
        return taken.contains(serverName(nickname: nickname)) ? .taken : nil
    }

    /// The server's configuration at local scope: Stripe's hosted server and
    /// nothing else, so Claude Code signs in to it with OAuth.
    static var config: String { ClaudeMCPMirror.canonicalJSON(["type": "http", "url": url]) ?? "{}" }
}

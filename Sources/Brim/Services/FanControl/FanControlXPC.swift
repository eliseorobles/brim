// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security
#if BRIM_DEVELOPMENT
import CryptoKit
#endif

enum FanControlIdentifiers {
    // Robles Consulting LLC. Release builds pin both ends of the helper link to this team.
    static let teamID = "53X2V2R96G"

    /// The app's bundle ID as build.sh stamped it, so the helper link
    /// follows the build instead of naming an ID. The app reads its Info.plist.
    /// The helper is a bare executable with no Info.plist (its bundle ID reads
    /// nil), so it reads the identifier build.sh signs it with,
    /// `<app id>.fan-control`, and drops the suffix. Empty when neither can be
    /// read, and the helper then refuses to start.
    static let appBundleID: String = {
        let own = Bundle.main.bundleIdentifier
            ?? (ownSigningInformation()?[kSecCodeInfoIdentifier as String] as? String) ?? ""
        return own.hasSuffix(helperSuffix) ? String(own.dropLast(helperSuffix.count)) : own
    }()

    private static let helperSuffix = ".fan-control"
    static let helperID = "\(appBundleID)\(helperSuffix)"
    static let plistName = "\(helperID).plist"

    static var appCodeRequirement: String {
        #if BRIM_DEVELOPMENT
        guard let hash = self.currentLeafCertificateSHA1() else {
            return "identifier \"\(appBundleID)\" and certificate leaf = H\"0000000000000000000000000000000000000000\""
        }
        return "identifier \"\(appBundleID)\" and certificate leaf = H\"\(hash)\""
        #else
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(appBundleID)\""
        #endif
    }

    static var helperCodeRequirement: String {
        #if BRIM_DEVELOPMENT
        guard let hash = self.currentLeafCertificateSHA1() else {
            return "identifier \"\(helperID)\" and certificate leaf = H\"0000000000000000000000000000000000000000\""
        }
        return "identifier \"\(helperID)\" and certificate leaf = H\"\(hash)\""
        #else
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(helperID)\""
        #endif
    }

    /// This process's own signature, read by the helper for its identity
    /// and by the Developer build for its certificate pin.
    private static func ownSigningInformation() -> [String: Any]? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let selfCode = dynamicCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess,
              let staticSelfCode = staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticSelfCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return nil
        }
        return info
    }

    #if BRIM_DEVELOPMENT
    private static func currentLeafCertificateSHA1() -> String? {
        guard let info = ownSigningInformation(),
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return nil
        }

        let data = SecCertificateCopyData(leaf) as Data
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

@objc protocol FanControlXPCProtocol {
    func status(withReply reply: @escaping (Data) -> Void)
    func startMaximumCooling(withReply reply: @escaping (Data) -> Void)
    func applyConfiguration(_ configuration: Data, withReply reply: @escaping (Data) -> Void)
    func heartbeat(withReply reply: @escaping (Data) -> Void)
    func restoreAutomatic(withReply reply: @escaping (Data) -> Void)
}

enum FanControlIPC {
    static func encode(_ response: FanControlResponse) -> Data {
        // Every value in this closed response model is JSON encodable. Keeping
        // one deterministic fallback avoids ever violating the XPC reply shape.
        (try? JSONEncoder().encode(response))
            ?? Data(#"{"succeeded":false,"snapshot":{"fans":[],"isCooling":false},"error":"controlFailed"}"#.utf8)
    }

    static func decode(_ data: Data) -> FanControlResponse? {
        try? JSONDecoder().decode(FanControlResponse.self, from: data)
    }

    static func encode(_ configuration: FanControlConfiguration) -> Data? {
        try? JSONEncoder().encode(configuration)
    }

    static func decodeConfiguration(_ data: Data) -> FanControlConfiguration? {
        guard let configuration = try? JSONDecoder().decode(FanControlConfiguration.self,
                                                              from: data),
              FanControlPolicy.validConfiguration(configuration) else { return nil }
        return configuration
    }
}

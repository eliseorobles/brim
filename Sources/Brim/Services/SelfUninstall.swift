// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ServiceManagement

/// Clears the app's own footprint on the system, for a clean uninstall.
///
/// Security note: every operation here is scoped to THIS app and nothing else.
/// The bundle id is a constant identifier (never user input), so the `tccutil`
/// call cannot be steered elsewhere; the login item and sudoers rule are the
/// app's own; the preference and saved-state paths are built from the app's own
/// bundle id; the Claude state folder is the one Brim's Claude accounts keep
/// (checked by `ClaudeInstallsRemoval.removeState`); and the app's own bundle
/// is moved to the Trash (reversible). Nothing leaves the machine.
enum SelfUninstall {
    // Empty outside an app bundle, and then nothing is reset or removed. Never another app's ID.
    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// Resets every TCC permission the app holds, drops the login item and the
    /// optional closed-lid sudoers rule, and leaves the app in place. Calls back
    /// on the main queue with whether the rule and permissions were removed.
    /// Used by "Clear all permissions".
    static func clearPermissions(completion: @escaping (Bool) -> Void) {
        func stop(sleepRestored: Bool = false) {
            DispatchQueue.main.async {
                if sleepRestored { KeepAwakeManager.shared.resumeAfterSystemTeardown() }
                Permissions.shared.refresh()
                FeatureRuntime.shared.sync(AppFeature.allCases)
                completion(false)
            }
        }
        // Stop every input interceptor FIRST (on the main thread), then revoke.
        // Revoking Accessibility while a tap is live makes the tap callback hang
        // on an AX call and freezes the whole machine's input — see the note on
        // `suspendInputInterceptors`.
        DispatchQueue.main.async {
            suspendInputInterceptors()
            DispatchQueue.global(qos: .userInitiated).async {
                guard restoreSleepBeforeRemoval() else { stop(); return }
                guard detachFromSystem() else {
                    stop(sleepRestored: true)
                    return
                }
                removeSudoersRuleIfPresent { ruleRemoved in    // may show one admin prompt
                    let reset = resetTCC()
                    DispatchQueue.main.async {
                        // The published permissions still say granted. Read the
                        // reset state now, or a grant made before the next poll
                        // looks unchanged and the suspended taps never resume.
                        Permissions.shared.refresh()
                        // Sleep was restored directly, so the closed-lid session
                        // state is stale whether or not the reset finished.
                        KeepAwakeManager.shared.resumeAfterSystemTeardown()
                        if !ruleRemoved || !reset {
                            FeatureRuntime.shared.sync(AppFeature.allCases)
                        }
                        completion(ruleRemoved && reset)
                    }
                }
            }
        }
    }

    /// Clears permissions, removes preferences and saved state, takes back what
    /// Claude accounts installed and deletes their state folder, sends the app
    /// bundle to the Trash and quits. Used by "Uninstall Brim completely".
    /// A failure passes the message explaining what stopped it.
    static func uninstallCompletely(onFailure: @escaping (String) -> Void) {
        // A failed reset may have changed some grants. Recheck them before
        // rearming services in the app that remains installed.
        func stop(_ body: String, sleepRestored: Bool = false) {
            DispatchQueue.main.async {
                if sleepRestored { KeepAwakeManager.shared.resumeAfterSystemTeardown() }
                Permissions.shared.refresh()
                FeatureRuntime.shared.sync(AppFeature.allCases)
                onFailure(body)
            }
        }
        DispatchQueue.main.async {
            suspendInputInterceptors()
            DispatchQueue.global(qos: .userInitiated).async {
                // Sleep may still be restored through the rule, and a refused
                // rule removal must stop before anything else is removed.
                guard restoreSleepBeforeRemoval() else {
                    stop(L10n.shared.s.advancedUninstallFailedBody)
                    return
                }
                removeSudoersRuleIfPresent { ruleRemoved in
                    guard ruleRemoved else {
                        stop(L10n.shared.s.advancedClearFailed, sleepRestored: true)
                        return
                    }
                    // The helper must be safely removed before permissions go;
                    // a failure here keeps the app's existing grants intact.
                    let fanHelperWasRegistered = FanControlService.hasRegisteredHelperForRemoval
                    guard detachFanControl() else {
                        stop(L10n.shared.s.advancedUninstallFailedBody, sleepRestored: true)
                        return
                    }
                    guard resetTCC() else {
                        // The app stays installed, so restore a helper that was
                        // registered before the attempted uninstall.
                        let fanReady = !fanHelperWasRegistered
                            || FanControlService.restoreRegistrationAfterFailedRemoval()
                        if fanReady {
                            stop(L10n.shared.s.advancedClearFailed, sleepRestored: true)
                        } else {
                            let warning = FeatureStrings.fanControl(L10n.shared.language).helperUnavailable
                            stop("\(L10n.shared.s.advancedClearFailed)\n\(warning)", sleepRestored: true)
                        }
                        return
                    }
                    // Do not clear the launch choice while a failed reset
                    // could still leave this app installed.
                    detachLoginItem()
                    removePreferences()
                    DispatchQueue.main.async {
                        // On the main thread right before quitting, so nothing
                        // the Claude accounts service still has queued there
                        // can write the state folder again.
                        removeClaudeAccounts()
                        trashOwnBundleAndQuit()
                    }
                }
            }
        }
    }

    // MARK: - Steps (each scoped to this app only)

    /// Tears down every Accessibility-backed input interceptor. MUST run on the
    /// main thread and BEFORE permissions are reset: otherwise revoking
    /// Accessibility while an event tap is still live makes the tap's callback
    /// block on an AX call, which stalls the OS input queue and freezes the
    /// keyboard and clicks (only the mouse cursor keeps moving). `suspend` is
    /// idempotent, so calling it when the service is already off is a no-op.
    private static func suspendInputInterceptors() {
        PastePlainService.shared.suspend()
    }

    @discardableResult
    private static func detachFromSystem() -> Bool {
        guard detachFanControl() else { return false }
        detachLoginItem()
        return true
    }

    private static func detachFanControl() -> Bool {
        FanControlService.restoreAndUnregisterForRemoval()
    }

    private static func detachLoginItem() {
        // Unregister the login item (scoped to our bundle id). The stored
        // intent goes with it, or the startup repair would quietly register
        // the item again after the user asked for a clean detach.
        UserDefaults.standard.set(false, forKey: DefaultsKey.launchAtLoginWanted)
        try? SMAppService.mainApp.unregister()
    }

    /// Puts normal sleep back before the app goes.
    ///
    /// `KeepAwakeManager` is allowed to give up on a failed revert when the app
    /// is merely quitting, because "the next start repairs a revert that was
    /// missed". Removal is the one exit with no next start, and the flag that
    /// would trigger that repair is deleted with the rest of the preferences a
    /// moment later — so a reinstall does not fix it either, since recovery
    /// reads the flag before it reads the setting. This is the last chance
    /// anything has, which is why it may ask for the password the launch-time
    /// recovery would have asked for.
    private static func restoreSleepBeforeRemoval() -> Bool {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.sleepDisabledFlag) else { return true }
        // The flag can outlive the setting, so a stale one must not put a
        // password dialog in front of someone uninstalling. Only a reading that
        // answered, and answered "off", is allowed to skip the rest: a probe
        // that failed says nothing. Going on then costs a no-op call, and a
        // dialog only if that call fails too — the case where sleep really may
        // still be off with nothing else left to put it back.
        let probe = Shell.run("/usr/bin/pmset", ["-g"])
        if probe.status == 0, !SudoersSupport.sleepDisabled(inPmsetOutput: probe.output) {
            return true
        }
        if Sudoers.pmsetDisableSleep(false) { return true }
        guard AdminShell.runSync("pmset disablesleep 0",
                                 prompt: L10n.shared.s.adminPromptRecover) else { return false }
        let verification = Shell.run("/usr/bin/pmset", ["-g"])
        return verification.status == 0
            && !SudoersSupport.sleepDisabled(inPmsetOutput: verification.output)
    }

    private static func removeSudoersRuleIfPresent(then: @escaping (Bool) -> Void) {
        guard Sudoers.ruleFilesPresent || Sudoers.isConfigured() else { then(true); return }
        Sudoers.remove(completion: then)            // shows the admin password prompt
    }

    /// `tccutil reset All <bundle id>` clears Accessibility, Full Disk Access,
    /// Automation and the rest, for this app only. The bundle id is a
    /// constant, so there is nothing to inject.
    @discardableResult
    private static func resetTCC() -> Bool {
        !bundleID.isEmpty && Shell.run("/usr/bin/tccutil", ["reset", "All", bundleID]).status == 0
    }

    private static func removePreferences() {
        let id = bundleID
        guard !id.isEmpty else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
        let home = NSHomeDirectory()
        try? FileManager.default.removeItem(atPath: "\(home)/Library/Preferences/\(id).plist")
        try? FileManager.default.removeItem(atPath: "\(home)/Library/Saved Application State/\(id).savedState")
        // Clipboard images and any other app-owned data live here.
        try? FileManager.default.removeItem(atPath: "\(home)/Library/Application Support/\(id)")
        try? FileManager.default.removeItem(atPath: "\(home)/Library/Caches/\(id)")
        // URLSession writes these on our behalf whenever the app talks to the
        // network, so they exist without the app ever choosing the path.
        try? FileManager.default.removeItem(atPath: "\(home)/Library/HTTPStorages/\(id)")
        try? FileManager.default.removeItem(
            atPath: "\(home)/Library/HTTPStorages/\(id).binarycookies")
    }

    /// Takes back the Claude Code status line and shell integration, then
    /// deletes Brim's Claude state folder (~/.config/brim/claude, brim-dev for
    /// the Developer app), last because the undo reads installs.json from it.
    /// Only that folder goes, and the variant folder above it when nothing
    /// else is in it (`ClaudeInstallsRemoval.removeState`). The undo's lines
    /// are not shown before the app quits (T-27).
    private static func removeClaudeAccounts() {
        ClaudeInstallsRemoval.uninstall(environment: ProcessInfo.processInfo.environment)
    }

    /// Moves the app's own bundle to the Trash after it quits, then quits. The
    /// path is the running app's own location, checked to be an `.app`, so this
    /// can only ever remove this app. A detached helper does the move so the
    /// bundle is not mutated while it is running.
    private static func trashOwnBundleAndQuit() {
        let app = Bundle.main.bundlePath
        guard app.hasSuffix(".app"), app != "/" else { NSApp.terminate(nil); return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        APP="$1"; PID="$2"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        TRASH="$HOME/.Trash"
        /bin/mkdir -p "$TRASH" 2>/dev/null || true
        BASE="$(basename "$APP")"
        DEST="$TRASH/$BASE"
        n=2
        while [ -e "$DEST" ]; do DEST="$TRASH/${BASE%.app} $n.app"; n=$((n+1)); done
        # Reversible move to the Trash. If a direct move fails, ask Finder to do
        # the same Trash operation so it can present the standard admin prompt.
        if ! /bin/mv "$APP" "$DEST" 2>/dev/null; then
            /usr/bin/osascript - "$APP" <<'APPLESCRIPT'
        on run argv
            tell application "Finder" to delete POSIX file (item 1 of argv)
        end run
        APPLESCRIPT
        fi
        if [ -d "$APP" ]; then /usr/bin/open "$APP" 2>/dev/null; fi
        /bin/rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-uninstall-\(pid)-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            // Its own session: the script's first act is to wait for this app
            // to exit, so a child left in our session would be torn down with
            // us before it ever gets to move the bundle.
            try DetachedProcess.spawn("/bin/sh", [scriptURL.path, app, "\(pid)"])
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// The words of Brim's Claude accounts: the menu panel section, its Settings
/// and setup window, and its notices.
struct ClaudeAccountsStrings {
    let title: String
    let panelDescription: String
    let newSessionsUse: String
    let automatic: String
    let fiveHour: String
    let weekly: String
    let resets: String
    let renewedEstimate: String
    let live: String
    let ago: String
    let checked: String
    let unknown: String
    let noReading: String
    let signedOut: String
    let overLimit: String
    let usableAgain: String
    let unknownRenewal: String
    let leftFormat: String
    let runningFormat: String
    let sameSignInFormat: String
    let defaultAccount: String
    let next: String
    let checking: String

    let openTerminal: String
    let signIn: String
    let refresh: String
    let refreshAll: String
    let copyMove: String
    let copyMoveHelp: String
    let copied: String
    let addAccount: String
    let setUp: String
    let rename: String
    let accountName: String
    let renameHelp: String
    let save: String
    let cancel: String
    let run: String
    let undo: String
    let done: String
    let close: String

    let accountsTitle: String
    let accountsHelp: String
    let defaultFolder: String
    let setupTitle: String
    let shellTitle: String
    let shellHelp: String
    let statusLineTitle: String
    let statusLineHelp: String
    let shareTitle: String
    let shareHelp: String
    /// A folder still links its conversations to ~/.claude.
    let shareNeedsUpdate: String
    let mcpTitle: String
    let mcpHelp: String
    let mcpNeedsLogin: String

    // MCP by repo
    let mcpOpen: String
    let commandsTitle: String
    let commandStartsOnFormat: String
    let commandStartsNone: String
    let commandAccountHelp: String
    let commandMoveFormat: String
    let commandsNeedShell: String
    let copyCommand: String
    let mcpReposTitle: String
    let mcpSearch: String
    let mcpAddRepo: String
    let mcpNoRepos: String
    let mcpPickRepo: String
    let mcpRepoOnly: String
    let mcpYourServers: String
    let mcpPlugins: String
    let mcpConnectors: String
    let mcpAllConnectors: String
    let mcpAddServer: String
    let mcpNone: String
    let mcpCopyToAll: String
    let mcpAppliesToNew: String
    let mcpOpenHereOne: String
    let mcpOpenHereFormat: String
    let mcpOffOutside: String
    let mcpOffOutsideHelp: String
    let mcpTurnOn: String
    let mcpTurnOnTitle: String
    let mcpTurnOnBody: String
    let mcpOffInAccountFormat: String
    let mcpTurnOffAll: String
    let mcpHiddenRepo: String
    let mcpHiddenUser: String
    let mcpPluginOff: String
    let mcpOffWithConnectors: String
    let mcpShadowed: String
    let mcpMissingFormat: String
    let mcpConflict: String
    let mcpUntrustedFormat: String
    let mcpStripeSignIn: String
    let mcpStripeSignInReviewFormat: String
    let mcpRemove: String
    let mcpRemoveSignIn: String
    let mcpRemoveDiffersFormat: String
    let mcpRemoveUncheckedFormat: String
    let mcpStillInFormat: String
    let mcpOffEverywhere: String
    let mcpHiddenInFormat: String
    let mcpShadowedInFormat: String
    let mcpNotApproved: String
    let mcpDeclined: String
    let mcpNotApprovedInFormat: String
    let mcpDeclinedInFormat: String
    let mcpSharesName: String
    let mcpNeedsLoginEverywhere: String
    let mcpCommandLineNote: String
    let mcpLeftOutFormat: String
    let mcpNoReadableAccount: String
    let mcpBusy: String
    let mcpTracked: String
    let mcpExcludedFormat: String
    let mcpGitFailedFormat: String
    let mcpExcludeFailedFormat: String
    let mcpAddTitleFormat: String
    let mcpStripe: String
    let mcpCopy: String
    let mcpPaste: String
    let mcpNickname: String
    let mcpNicknameHelp: String
    let mcpServerNameFormat: String
    let mcpStripeHelp: String
    let mcpNicknameCharacters: String
    let mcpNameTaken: String
    let mcpServerName: String
    let mcpServerJSON: String
    let mcpCopyNone: String
    let mcpCopyServer: String
    let mcpNameInRepoFormat: String
    let review: String
    let installed: String
    let notInstalled: String
    let partlyInstalled: String
    let otherStatusLine: String
    let reviewTitle: String
    let reviewHelp: String
    let blocked: String
    let resultTitle: String
    let nothingToChange: String
    let vscodeNote: String
    let claudeMissing: String
    let notifyTitleFormat: String
    let notifyBodyFormat: String
    /// A conversation continued on two accounts between syncs.
    let divergedTitle: String
    let divergedBodyFormat: String
    let notifyNoTarget: String
    /// A conversation held open on one account, out of the others' /resume.
    let heldOpenFormat: String
    let heldPausedFormat: String

    // The account list
    let email: String
    let add: String
    let addTitle: String
    let addHelp: String
    let folder: String
    let reusedFolderFormat: String
    let newFolderFormat: String
    let chooseFolder: String
    let useSuggestedFolder: String
    let othersTitle: String
    let firstAccountTitle: String
    let othersHelp: String
    let thatsAll: String
    let statusSignedIn: String
    let statusNotSignedIn: String
    let holdsFormat: String
    let wrongAccountHelp: String
    let duplicateOne: String
    let duplicatesFormat: String
    let tidyUp: String
    let tidyTitle: String
    let invalidEmail: String
    let alreadyListedFormat: String
    let alreadySignedInFormat: String
    let folderTakenFormat: String

    // Sign-in
    let signInTitleFormat: String
    let stepOpening: String
    let stepOpenedFormat: String
    let stepCopyLink: String
    let stepSignInThereFormat: String
    let stepCheck: String
    let defaultFolderWarning: String
    let liveSessionsFormat: String
    let copyLink: String
    let tryAgain: String
    let wrongAccountFormat: String
    let notSignedInAfter: String
    let signInTimedOut: String
    let signInStoppedFormat: String
    let refusedLink: String
    let helperMissing: String

    /// "2 open here keep their current servers until restarted."
    func mcpOpenHere(_ count: Int) -> String { count == 1 ? mcpOpenHereOne : String(format: mcpOpenHereFormat, count) }
    /// nil labels: every account.
    func mcpOffInAccount(_ labels: [String]?) -> String {
        labels.map { String(format: mcpOffInAccountFormat, $0.joined(separator: ", ")) } ?? mcpOffEverywhere
    }
    func mcpNeedsLoginIn(_ labels: [String]?) -> String {
        labels.map { mcpNeedsLogin + ": " + $0.joined(separator: ", ") } ?? mcpNeedsLoginEverywhere
    }
    func mcpHiddenIn(_ labels: [String]) -> String { String(format: mcpHiddenInFormat, labels.joined(separator: ", ")) }
    func mcpShadowedIn(_ labels: [String]) -> String { String(format: mcpShadowedInFormat, labels.joined(separator: ", ")) }
    func mcpNotApprovedIn(_ labels: [String]) -> String { String(format: mcpNotApprovedInFormat, labels.joined(separator: ", ")) }
    func mcpDeclinedIn(_ labels: [String]) -> String { String(format: mcpDeclinedInFormat, labels.joined(separator: ", ")) }
    func mcpLeftOut(_ labels: [String]) -> String { String(format: mcpLeftOutFormat, labels.joined(separator: ", ")) }
    func mcpStripeSignInReview(_ name: String) -> String { String(format: mcpStripeSignInReviewFormat, name) }
    func mcpRemoveDiffers(_ name: String) -> String { String(format: mcpRemoveDiffersFormat, name) }
    func mcpRemoveUnchecked(_ labels: [String]) -> String { String(format: mcpRemoveUncheckedFormat, labels.joined(separator: ", ")) }
    func mcpStillIn(_ name: String, _ labels: [String]) -> String {
        String(format: mcpStillInFormat, name, labels.count, labels.joined(separator: ", "))
    }
    func mcpMissing(_ labels: [String]) -> String { String(format: mcpMissingFormat, labels.joined(separator: ", ")) }
    func mcpUntrusted(_ labels: [String]) -> String { String(format: mcpUntrustedFormat, labels.joined(separator: ", ")) }
    func mcpExcluded(_ file: String) -> String { String(format: mcpExcludedFormat, file) }
    func mcpGitFailed(_ status: Int32) -> String { String(format: mcpGitFailedFormat, Int(status)) }
    func mcpExcludeFailed(_ detail: String) -> String { String(format: mcpExcludeFailedFormat, detail) }
    func mcpAddTitle(_ repo: String) -> String { String(format: mcpAddTitleFormat, repo) }
    func mcpServerNamed(_ name: String) -> String { String(format: mcpServerNameFormat, name) }
    func mcpNameInRepo(_ name: String) -> String { String(format: mcpNameInRepoFormat, name) }

    /// "38% left" with the percentage formatted by the caller.
    func left(_ percent: String) -> String { String(format: leftFormat, percent) }
    /// "2 running".
    func running(_ count: Int) -> String { String(format: runningFormat, count) }
    /// "Same sign-in in 2 folders".
    func sameSignIn(_ count: Int) -> String { String(format: sameSignInFormat, count) }
    /// "~/.claude-work (reused)" or "~/.claude-work (new)".
    func folderPlan(_ folder: String, reused: Bool) -> String {
        String(format: reused ? reusedFolderFormat : newFolderFormat, folder)
    }
    /// "Holds elliotgrayco.me".
    func holds(_ account: String) -> String { String(format: holdsFormat, account) }
    /// "+ 1 duplicate folder", "+ 2 duplicate folders".
    func duplicates(_ count: Int) -> String { count == 1 ? duplicateOne : String(format: duplicatesFormat, count) }
    func alreadyListed(_ label: String) -> String { String(format: alreadyListedFormat, label) }
    func alreadySignedIn(_ folder: String) -> String { String(format: alreadySignedInFormat, folder) }
    func folderTaken(_ owner: String) -> String { String(format: folderTakenFormat, owner) }
    /// "Sign in as elliot@rhodesconsultingllc.com".
    func signInTitle(_ email: String) -> String { String(format: signInTitleFormat, email) }
    /// "Sign in there as elliot@rhodesconsultingllc.com".
    func stepSignInThere(_ email: String) -> String { String(format: stepSignInThereFormat, email) }
    /// "Sessions running in this folder switch to this account: pid 4242 in /x."
    func liveSessionsWarning(_ sessions: String) -> String { String(format: liveSessionsFormat, sessions) }
    /// "Opened a private Chrome window".
    func stepOpened(_ browser: String) -> String { String(format: stepOpenedFormat, browser) }
    /// "That signed in as a@x.me, not b@y.com."
    func wrongAccount(signedInAs: String, expected: String) -> String {
        String(format: wrongAccountFormat, signedInAs, expected)
    }
    func signInStopped(_ status: Int) -> String { String(format: signInStoppedFormat, status) }
    /// "elliotgrayco.me is near a limit".
    func notifyTitle(_ label: String) -> String { String(format: notifyTitleFormat, label) }

    /// "1a2b3c4d was continued on two accounts; each keeps its own version."
    func divergedBody(_ shortId: String) -> String { String(format: divergedBodyFormat, shortId) }
    /// "8d866fb8 is paused at its usage limit on sparkfx.ai; /exit it there to
    /// continue it on another account."
    func held(_ conversation: ClaudeHeldConversation) -> String {
        String(format: conversation.paused ? heldPausedFormat : heldOpenFormat, conversation.shortId, conversation.account)
    }
    /// "Starts on sparkfx.ai now."
    func commandStartsOn(_ label: String) -> String { String(format: commandStartsOnFormat, label) }
    /// "After /exit, continues your last conversation on sparkfx.ai."
    func commandMove(_ label: String) -> String { String(format: commandMoveFormat, label) }
    /// "5h at 92%. Best next: rhodesconsulting. After /exit, run cx --to rhodesconsulting."
    func notifyBody(window: String, percent: String, target: String?) -> String {
        guard let target else { return String(format: notifyNoTarget, window, percent) }
        return String(format: notifyBodyFormat, window, percent, target, target)
    }
}

extension ClaudeAccountsStrings {
    static let enUS = ClaudeAccountsStrings(
        title: "Claude accounts",
        panelDescription: "Each Claude Code account's 5-hour and weekly limits, and which one new sessions use.",
        newSessionsUse: "New sessions use",
        automatic: "Auto (soonest reset)",
        fiveHour: "5h",
        weekly: "Weekly",
        resets: "resets in",
        renewedEstimate: "renewed (estimate)",
        live: "live",
        ago: "ago",
        checked: "checked",
        unknown: "unknown",
        noReading: "No reading yet",
        signedOut: "Signed out",
        overLimit: "Over a limit",
        usableAgain: "usable again in",
        unknownRenewal: "renewal unknown",
        leftFormat: "%@ left",
        runningFormat: "%d running",
        sameSignInFormat: "Same sign-in in %d folders",
        defaultAccount: "default account",
        next: "Next",
        checking: "Checking…",
        openTerminal: "Open Terminal",
        signIn: "Sign in",
        refresh: "Refresh",
        refreshAll: "Refresh all",
        copyMove: "Copy cx command",
        copyMoveHelp: "After /exit, cx continues the conversation on this account.",
        copied: "Copied",
        addAccount: "Add account…",
        setUp: "Set up…",
        rename: "Rename",
        accountName: "Account name",
        renameHelp: "The name you type after cc. Use letters, digits, “.”, “-” or “_”.",
        save: "Save",
        cancel: "Cancel",
        run: "Make these changes",
        undo: "Undo",
        done: "Done",
        close: "Close",
        accountsTitle: "Accounts",
        accountsHelp: "Each account is an email and the Claude Code folder that holds it. Sign in from here: Claude Code signs in and keeps its tokens itself, and Brim never reads them.",
        defaultFolder: "~/.claude (default)",
        setupTitle: "Setup",
        shellTitle: "Shell integration",
        shellHelp: "claude starts on the account Brim picks, cc <account> on that one, and cx moves the last conversation to another account after /exit. /resume, claude --resume and -c list every account's conversations.",
        statusLineTitle: "Status line",
        statusLineHelp: "Every running session reports its 5-hour and weekly use to Brim as it works, with no extra requests.",
        shareTitle: "Shared setup",
        shareHelp: "Every account uses ~/.claude's settings, CLAUDE.md, skills, agents and plugins. Each keeps its own conversation folders, sign-in and prompt history; Brim copies every conversation, plan and memory into each, so /resume lists them all.",
        shareNeedsUpdate: "Needs an update",
        mcpTitle: "MCP servers",
        mcpHelp: "Turn servers on or off per repo, and give every account the same servers, using Claude Code's own commands.",
        mcpNeedsLogin: "Needs its own MCP sign-in",
        mcpOpen: "Open…",
        commandsTitle: "Terminal commands",
        commandStartsOnFormat: "Starts on %@ now.",
        commandStartsNone: "No account has room right now.",
        commandAccountHelp: "Starts on this account.",
        commandMoveFormat: "After /exit, continues your last conversation on %@.",
        commandsNeedShell: "These work once Shell integration below is installed. Open a new terminal tab after installing it.",
        copyCommand: "Copy",
        mcpReposTitle: "Repos",
        mcpSearch: "Search repos",
        mcpAddRepo: "Add repo…",
        mcpNoRepos: "No repos yet. Start Claude Code in one, or add it here.",
        mcpPickRepo: "Choose a repo to see its servers.",
        mcpRepoOnly: "This repo only",
        mcpYourServers: "Your servers",
        mcpPlugins: "Plugins",
        mcpConnectors: "claude.ai connectors",
        mcpAllConnectors: "All claude.ai connectors",
        mcpAddServer: "Add server…",
        mcpNone: "None",
        mcpCopyToAll: "Copy to every account…",
        mcpAppliesToNew: "Changes apply to new sessions.",
        mcpOpenHereOne: "1 open here keeps its current servers until restarted.",
        mcpOpenHereFormat: "%d open here keep their current servers until restarted.",
        mcpOffOutside: "Off (set outside Brim)",
        mcpOffOutsideHelp: "Set in .claude/settings.json or ~/.claude/settings.json, which Brim does not edit.",
        mcpTurnOn: "Turn on…",
        mcpTurnOnTitle: "Turn it back on?",
        mcpTurnOnBody: "Brim did not turn this off. Turning it on removes that entry from this repo's .claude/settings.local.json.",
        mcpOffInAccountFormat: "Off in %@ only (set in /mcp)",
        mcpTurnOffAll: "Turn off for all accounts",
        mcpHiddenRepo: "Hidden: this repo has its own",
        mcpHiddenUser: "Hidden: one of your servers is the same",
        mcpPluginOff: "Plugin off in this repo",
        mcpOffWithConnectors: "Off with all claude.ai connectors",
        mcpShadowed: "This repo's own server of the same name runs here",
        mcpMissingFormat: "Not in %@ yet",
        mcpConflict: "Differs between accounts, so Brim copies nothing",
        mcpUntrustedFormat: "Its headersHelper runs once each account trusts this repo. Not yet: %@",
        mcpStripeSignIn: "Each account signs in to Stripe the first time a session uses it",
        mcpStripeSignInReviewFormat: "Each account signs in to Stripe the first time a session uses %@: Claude Code opens Stripe in your browser, where you choose the Stripe account or sandbox. Brim keeps no Stripe key.",
        mcpRemove: "Remove from this repo…",
        mcpRemoveSignIn: "This also clears its MCP sign-in in each of those accounts.",
        mcpRemoveDiffersFormat: "The accounts hold different versions of %@. Every version is removed.",
        mcpRemoveUncheckedFormat: "Not checked: %@ (Brim could not read their .claude.json), so Brim keeps its record of this server.",
        mcpStillInFormat: "%@ is still in %d account(s): %@. Brim keeps its record and its switch for it.",
        mcpOffEverywhere: "Off in every account (set in /mcp)",
        mcpHiddenInFormat: "Hidden in %@: a server there has the same address",
        mcpShadowedInFormat: "This repo's own server of the same name runs instead in %@",
        mcpNotApproved: "Not approved",
        mcpDeclined: "Declined here",
        mcpNotApprovedInFormat: "Not approved in %@",
        mcpDeclinedInFormat: "Declined in %@",
        mcpSharesName: "Switches match by name, so this one also turns off the other server of this name here",
        mcpNeedsLoginEverywhere: "Needs its own MCP sign-in in every account",
        mcpCommandLineNote: "Each server's settings, keys included, pass briefly through a command line (claude mcp add-json), where other programs you run can see them for about a second.",
        mcpLeftOutFormat: "Left out: %@ (Brim could not read their .claude.json).",
        mcpNoReadableAccount: "Brim could not read any account's .claude.json.",
        mcpBusy: "Brim is still making the last change.",
        mcpTracked: "This repo commits .claude/settings.local.json, so switches would be shared with everyone. Untrack it first.",
        mcpExcludedFormat: "Added .claude/settings.local.json to %@ so git ignores it.",
        mcpGitFailedFormat: "git could not check this repo (exit %d), so nothing changed.",
        mcpExcludeFailedFormat: "Could not keep .claude/settings.local.json out of git: %@",
        mcpAddTitleFormat: "Add a server to %@",
        mcpStripe: "Stripe",
        mcpCopy: "Copy from another repo",
        mcpPaste: "Paste JSON",
        mcpNickname: "Account nickname",
        mcpNicknameHelp: "Lowercase letters, digits and -, like acme.",
        mcpServerNameFormat: "Server name: %@",
        mcpStripeHelp: "Adds Stripe's hosted server to this repo in every account. Each account signs in to Stripe the first time a session uses it, and picks the Stripe account or sandbox on Stripe's own screen. Name it after that Stripe account.",
        mcpNicknameCharacters: "Use lowercase letters, digits and -.",
        mcpNameTaken: "That name is already used. Pick another.",
        mcpServerName: "Server name",
        mcpServerJSON: "Server JSON",
        mcpCopyNone: "No other repo has a server of its own.",
        mcpCopyServer: "Server",
        mcpNameInRepoFormat: "This repo already has a server named %@.",
        review: "Review…",
        installed: "Installed",
        notInstalled: "Not installed",
        partlyInstalled: "Partly installed",
        otherStatusLine: "Another status line is set",
        reviewTitle: "What will change",
        reviewHelp: "Nothing changes until you confirm.",
        blocked: "Blocked",
        resultTitle: "Result",
        nothingToChange: "Nothing to change.",
        vscodeNote: "The VS Code Claude panel always uses the default account; terminal sessions follow these accounts.",
        claudeMissing: "Claude Code was not found.",
        notifyTitleFormat: "%@ is near a limit",
        notifyBodyFormat: "%@ at %@. Best next: %@. After /exit, run cx --to %@.",
        divergedTitle: "Conversation on two accounts",
        divergedBodyFormat: "%@ was continued on two accounts; each keeps its own version.",
        notifyNoTarget: "%@ at %@. No other account has room right now.",
        heldOpenFormat: "%@ is held open on %@; /exit it there to continue it on another account.",
        heldPausedFormat: "%@ is paused at its usage limit on %@; /exit it there to continue it on another account.",
        email: "Email",
        add: "Add",
        addTitle: "Add a Claude account",
        addHelp: "Brim adds it to the list. You sign in from the list when you are ready.",
        folder: "Folder",
        reusedFolderFormat: "%@ (already there)",
        newFolderFormat: "%@ (new)",
        chooseFolder: "Choose folder…",
        useSuggestedFolder: "Use suggested",
        othersTitle: "Any other Claude accounts?",
        firstAccountTitle: "Which Claude account do you use?",
        othersHelp: "Type an email to add it to the list. Nothing signs in until you choose Sign in.",
        thatsAll: "That's all",
        statusSignedIn: "Signed in",
        statusNotSignedIn: "Not signed in",
        holdsFormat: "Holds %@",
        wrongAccountHelp: "This folder is signed in to another account. Sign in to put the right one there.",
        duplicateOne: "+ 1 duplicate folder",
        duplicatesFormat: "+ %d duplicate folders",
        tidyUp: "Tidy up…",
        tidyTitle: "Tidy up duplicate folders",
        invalidEmail: "Type one email address, like name@example.com.",
        alreadyListedFormat: "That email is already in the list, as %@.",
        alreadySignedInFormat: "That account is already signed in, in %@.",
        folderTakenFormat: "That folder belongs to %@.",
        signInTitleFormat: "Sign in as %@",
        stepOpening: "Opening a private window…",
        stepOpenedFormat: "Opened a private %@ window",
        stepCopyLink: "Copy the link into a private window (⇧⌘N)",
        stepSignInThereFormat: "Sign in there as %@",
        stepCheck: "Brim checks it's the right account",
        defaultFolderWarning: "Every session using the default folder switches to this account.",
        liveSessionsFormat: "Sessions running in this folder switch to this account: %@.",
        copyLink: "Copy link",
        tryAgain: "Try again",
        wrongAccountFormat: "That signed in as %@, not %@.",
        notSignedInAfter: "Claude Code finished, but the folder is not signed in.",
        signInTimedOut: "The sign-in stopped after 15 minutes without finishing.",
        signInStoppedFormat: "Claude Code stopped before the sign-in finished (exit %d).",
        refusedLink: "Claude Code gave a sign-in link Brim does not open, so nothing was opened.",
        helperMissing: "Brim's helper is missing from the app; reinstall Brim.")
}

extension FeatureStrings {
    static func claudeAccounts(_ language: AppLanguage) -> ClaudeAccountsStrings {
        switch language {
        case .enUS: return .enUS
        }
    }
}

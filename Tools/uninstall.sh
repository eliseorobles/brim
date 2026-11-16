#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Cleanly removes Brim and every piece of system state it created: the fan
# helper daemon, the login item, TCC permissions, preferences, saved state, the
# app's own data folder, the Claude accounts state folder and (if present) the
# password-free closed-lid sudoers rule. Leaves no dead entries behind. It touches only Brim's own app, bundle
# ID and files, never any other app's (upstream Vorssaint's included).
#
# Usage: Tools/uninstall.sh          removes Brim
#        Tools/uninstall.sh --dev    removes Brim (Developer)
set -uo pipefail

DEV=0
for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        *) print -u2 "usage: $0 [--dev]"; exit 2 ;;
    esac
done
source "${0:A:h}/identity.sh"
BUNDLE="$APP_BUNDLE_ID"
APP="/Applications/$APP_NAME.app"
# An app that only shares the name is never quit or removed.
brim_refuse_foreign_bundle "$APP" || exit 1

echo "▸ Quitting $APP_NAME…"
# Only the process running this app's own executable, matched by full path.
own_pids=($(brim_app_pids))
(( ${#own_pids} )) && kill "${own_pids[@]}" 2>/dev/null
sleep 0.5

# Detach from the system from inside whichever bundle still exists: unregisters
# the login item (no BTM tombstone), restores normal sleep and takes back what
# Claude accounts installed.
# The fan helper's registration lives in the system, not in the bundle, so
# deleting the app below cannot reach it. Only the binary can drop it, and the
# check after it settles what its absence or failure left behind.
detached=1
candidate="$APP/Contents/MacOS/$EXECUTABLE"
if [[ -x "$candidate" ]]; then
    echo "▸ Detaching the fan helper and login item, restoring sleep…"
    if "$candidate" --uninstall; then detached=0; fi
fi
# `detached` cannot tell a failed unregister from no binary having run, and the
# second is ordinary: an app trashed by hand, then this script for the rest. It
# also cannot see a daemon that went despite a reported failure. launchctl
# settles both without sudo, and still finds a registration held back for a
# pending fan recovery, which is the one case that must keep warning.
if (( detached )); then
    launchctl print "system/$FAN_HELPER_ID" >/dev/null 2>&1
    # 113 is "no such service", the only answer that proves absence. Any other
    # failure means launchctl could not tell us, and warning then is the honest
    # side of a check that exists to stop this script claiming what it cannot see.
    (( $? == 113 )) && detached=0
fi

# Whether the closed-lid feature is the reason sleep is off. Read here because
# the preferences that hold it are deleted a few lines below, and without it a
# check on the setting alone would blame Brim for a `pmset disablesleep 1`
# that somebody else, or the user, had set.
sleep_was_ours=0
[[ "$(defaults read "$BUNDLE" vorssDisabledSleep 2>/dev/null)" == "1" ]] && sleep_was_ours=1

echo "▸ Resetting privacy permissions…"
tccutil reset All "$BUNDLE" >/dev/null 2>&1 || true

echo "▸ Removing app, preferences, saved state and stored data (clipboard history, the Memory log)…"
rm -rf "$APP"
defaults delete "$BUNDLE" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$BUNDLE.plist"
rm -rf "$HOME/Library/Saved Application State/$BUNDLE.savedState"
# Clipboard history and the Memory log live here; the in-app uninstall takes
# them, so this path must not keep them.
rm -rf "$HOME/Library/Application Support/$BUNDLE"
rm -rf "$HOME/Library/Caches/$BUNDLE"
# Written by URLSession on the app's behalf, so they exist without the app ever
# naming the path; `defaults delete` does not reach them either.
rm -rf "$HOME/Library/HTTPStorages/$BUNDLE" "$HOME/Library/HTTPStorages/$BUNDLE.binarycookies"
# `defaults delete` does not reach ByHost. The (N) qualifier is load-bearing:
# without it zsh aborts the command on an unmatched pattern, which is the
# ordinary case, and prints an error over a successful uninstall.
rm -f "$HOME/Library/Preferences/ByHost/$BUNDLE".*.plist(N)

# The closed-lid rule, the same file the app writes (Sudoers.rulePath). Brim's
# release and Developer builds share it. Rules under any other name belong to
# another app and are left alone. zsh passes an unquoted string to a command as
# a single word, so the names live in an array.
RULES=(/etc/sudoers.d/brim-clamshell)
found_rules=()
for rule in "${RULES[@]}"; do
    [[ -e "$rule" ]] && found_rules+=("$rule")
done
# Brim's two variants share the rule; the other one, still installed, keeps it.
other_app="/Applications/$BRIM_DEVELOPER_APP_NAME.app"
(( DEV )) && other_app="/Applications/$BRIM_RELEASE_APP_NAME.app"
if (( ${#found_rules} )) && [[ -d "$other_app" ]]; then
    echo "▸ Keeping the closed-lid sudoers rule: $other_app still uses it."
    found_rules=()
fi
if (( ${#found_rules} )); then
    echo "▸ Removing closed-lid sudoers rule (asks for your admin password)…"
    osascript -e "do shell script \"rm -f $found_rules\" with administrator privileges with prompt \"$APP_NAME uninstaller\"" || true
fi

# Claude accounts. `--uninstall` above took back the Claude Code status
# line and shell integration the app installed; installs.json still names
# whatever it could not (the app was already gone, or the file changed since).
# Nothing can take that back once the app is gone, so it is named below.
# Then the state folder goes, last because installs.json is in it: the
# accounts list, live readings, requests, session owners, sign-in links, MCP
# backups and the install record. The app finds the folder the same way
# (ClaudeAccountsPaths) and removes it with the same checks
# (ClaudeInstallsRemoval.removeState). Tests/UninstallClaudeStateTests.sh runs
# this block, up to the sleep check, on scratch folders.
claude_standard="$HOME/.config/brim/claude"
(( DEV )) && claude_standard="$HOME/.config/brim-dev/claude"
claude_state="$claude_standard"
[[ "${BRIM_CLAUDE_STATE_DIR:-}" == /* ]] && claude_state="$BRIM_CLAUDE_STATE_DIR"
claude_left=()
if [[ -f "$claude_state/installs.json" ]]; then
    claude_value() { /usr/bin/plutil -extract "$1" raw -o - "$claude_state/installs.json" 2>/dev/null; }
    if claude_settings="$(claude_value statusLine.settings)"; then
        claude_left+=("the \"statusLine\" entry Brim added to $claude_settings")
    fi
    if claude_rc="$(claude_value shell.rcFile)"; then
        claude_line="$(claude_value shell.rcLine)" && claude_left+=("this line in $claude_rc: $claude_line")
        claude_left+=("the file $(claude_value shell.script)")
        [[ "$(claude_value shell.linkCreated)" == true ]] && claude_left+=("the link $(claude_value shell.link)")
    fi
fi
# Copies of conversations Brim held out of view while the conversation was
# open on another account (ClaudeSync's check-out, T-40), in
# projects/<slug>/.brim-checked-out/. `--uninstall` put every one back
# (ClaudeSync.checkInEverything); any still there (the app was already gone,
# or a move failed) is named, since Claude Code never lists it and nothing
# will put it back once Brim is gone. The folders: ~/.claude, ~/.claude-*
# and every account folder accounts.json names, each once by real path.
claude_folders=("$HOME/.claude" "$HOME"/.claude-*(N/))
if [[ -f "$claude_state/accounts.json" ]]; then
    claude_index=0
    while claude_folder="$(/usr/bin/plutil -extract "accounts.$claude_index.folder" raw -o - "$claude_state/accounts.json" 2>/dev/null)"; do
        [[ "$claude_folder" == /* ]] && claude_folders+=("$claude_folder")
        claude_index=$((claude_index + 1))
    done
fi
claude_held=()
for claude_folder in "${claude_folders[@]}"; do
    claude_held+=("$claude_folder"/projects/*/.brim-checked-out/*.jsonl(N:A))
done
claude_held=("${(u)claude_held[@]}")
# Whether the path has the shape of Brim's Claude state folder: absolute, with
# no empty, "." or ".." parts, below at least one folder and named "claude";
# never inside Claude Code's own folders (~/.claude*), never the home folder or
# a folder above it. The rule ClaudeInstallsRemoval.isStateFolder applies.
claude_state_shape() {
    [[ "$1" == /?*/claude && "$1/" != *//* && "$1/" != */./* && "$1/" != */../* ]] || return 1
    [[ "$1" != */.claude* && "$2" != "$1" && "$2" != "$1"/* ]]
}
# Only a real folder goes, never a link, and only when the folder it resolves
# to has that shape too.
claude_state_removable() {
    [[ -d "$1" && ! -L "$1" ]] && claude_state_shape "$1" "$HOME" && claude_state_shape "${1:A}" "${HOME:A}"
}
claude_kept=""
if [[ -e "$claude_state" || -L "$claude_state" ]]; then
    if claude_state_removable "$claude_state" && rm -rf -- "$claude_state"; then
        echo "▸ Removed $claude_state (the Claude accounts list)."
        # The standard folder's parent (~/.config/brim or brim-dev) goes too
        # when that left it empty: rmdir removes nothing else, and never a
        # link. ~/.config itself, and the folder above a BRIM_CLAUDE_STATE_DIR,
        # always stay.
        if [[ "$claude_state" == "$claude_standard" ]]; then
            rmdir -- "${claude_state:h}" 2>/dev/null || true
        fi
    else
        claude_kept="$claude_state"
    fi
fi

# `--uninstall` restores sleep, but it runs before the app has an
# NSApplication and so cannot raise the password dialog the in-app uninstall
# falls back to. A restore that needed one therefore reaches here as a setting
# still switched on. `pmset -g` reads it without sudo, and this is the only
# warning anyone will get: the app that knew the setting was its doing has
# just been removed.
sleep_stuck=0
sleep_unknown=0
if (( sleep_was_ours )); then
    sleep_state="$(pmset -g 2>/dev/null | awk '/SleepDisabled/ { print $2 }')"
    # "0" is the only answer that proves sleep came back, and "1" the only one
    # that proves it did not. Anything else is pmset not answering: it must not
    # pass as success, and it must not be reported as a failed restore either.
    if [[ "$sleep_state" == "1" ]]; then
        sleep_stuck=1
    elif [[ "$sleep_state" != "0" ]]; then
        sleep_unknown=1
    fi
fi

if (( detached == 0 && sleep_stuck == 0 && sleep_unknown == 0 && ${#claude_left} == 0 && ${#claude_held} == 0 )) && [[ -z "$claude_kept" ]]; then
    echo "✓ $APP_NAME fully removed."
    exit 0
fi
if (( detached )); then
    echo "⚠ $APP_NAME removed, but its fan helper is still registered with the system." >&2
    echo "  Reinstall $APP_NAME, then use Settings › Advanced to uninstall from inside the app." >&2
fi
if (( sleep_stuck )); then
    echo "⚠ $APP_NAME removed, but this Mac still has sleep switched off." >&2
    echo "  Closed-lid mode disabled it, and restoring it needed a password this script could not ask for." >&2
    echo "  Put it back with: sudo pmset disablesleep 0" >&2
fi
if (( sleep_unknown )); then
    echo "⚠ $APP_NAME removed, but whether sleep came back could not be read." >&2
    echo "  Closed-lid mode had switched it off. Check with: pmset -g | grep SleepDisabled" >&2
    echo "  If that reads 1, put it back with: sudo pmset disablesleep 0" >&2
fi
if (( ${#claude_left} )); then
    echo "⚠ $APP_NAME removed, but Claude Code still has what it installed. Remove by hand:" >&2
    for claude_item in "${claude_left[@]}"; do echo "  - $claude_item" >&2; done
    echo "  (Brim left a timestamped .brim-backup copy beside each file it edited.)" >&2
fi
if (( ${#claude_held} )); then
    echo "⚠ $APP_NAME removed, but it still holds copies of conversations out of Claude Code's view." >&2
    echo "  Move each back one folder up (or delete it if a longer copy of the same file is there):" >&2
    for claude_item in "${claude_held[@]}"; do echo "  - $claude_item" >&2; done
fi
if [[ -n "$claude_kept" ]]; then
    echo "⚠ $APP_NAME removed, but $claude_kept was left: it is a link, is not where Brim keeps its Claude state, or could not be deleted." >&2
    echo "  Delete it by hand if it is Brim's." >&2
fi
exit 1

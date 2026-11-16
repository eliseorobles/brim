# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robles Consulting LLC
#
# Brim's identity: the one file that names it. Brim is a hard fork of
# Vorssaint, whose trademark terms require a fork to use its own name, icon,
# bundle identifier and signing identity, and never to present itself as
# Vorssaint.
#
# Sourced (zsh or bash) by build.sh, Tools/uninstall.sh and
# Tests/DeveloperInstallIsolationTests.sh. DEV=1 selects the Developer variant,
# which installs and runs beside the release one with its own bundle ID,
# permissions, preferences and login item.

BRIM_TEAM_ID="53X2V2R96G"                      # Robles Consulting LLC
BRIM_TEAM_NAME="Robles Consulting LLC"

BRIM_RELEASE_APP_NAME="Brim"
BRIM_RELEASE_EXECUTABLE="Brim"
BRIM_RELEASE_BUNDLE_ID="com.roblesconsulting.brim"

BRIM_DEVELOPER_APP_NAME="Brim (Developer)"
BRIM_DEVELOPER_EXECUTABLE="BrimDeveloper"
BRIM_DEVELOPER_BUNDLE_ID="com.roblesconsulting.brim.dev"

# NSHumanReadableCopyright, the same text as AppInfo.copyright. Brim is a
# modified Vorssaint: the About panel and Settings › About show that credit
# (BrimIdentity.upstreamCredit) beneath it, as the GPL asks.
BRIM_COPYRIGHT="© 2026 Robles Consulting LLC"

if [[ "${DEV:-0}" == "1" ]]; then
    APP_NAME="$BRIM_DEVELOPER_APP_NAME"
    EXECUTABLE="$BRIM_DEVELOPER_EXECUTABLE"
    APP_BUNDLE_ID="$BRIM_DEVELOPER_BUNDLE_ID"
else
    APP_NAME="$BRIM_RELEASE_APP_NAME"
    EXECUTABLE="$BRIM_RELEASE_EXECUTABLE"
    APP_BUNDLE_ID="$BRIM_RELEASE_BUNDLE_ID"
fi
# The privileged fan helper is named after the app, so each variant owns its
# own launchd service and signing identifier.
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"

# The PIDs of this variant's installed app, matched by the full path of its
# executable in /Applications, so nothing else that happens to share the name is
# ever stopped. The optional argument names the executable (default: ours).
brim_app_pids() {
    local executable="/Applications/$APP_NAME.app/Contents/MacOS/${1:-$EXECUTABLE}"
    ps -axww -o pid=,comm= | awk -v executable="$executable" '{
        pid = $1
        sub(/^[ \t]*[0-9]+[ \t]+/, "")
        if ($0 == executable) print pid
    }'
}

# Whether the bundle at the path is this variant's app, or nothing is there:
# its CFBundleIdentifier must be $APP_BUNDLE_ID. Another app that only shares
# the name (or the path) is never stopped, replaced or removed.
brim_bundle_is_ours() {
    [[ -e "$1" ]] || return 0
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "$APP_BUNDLE_ID" ]]
}

brim_refuse_foreign_bundle() {
    brim_bundle_is_ours "$1" && return 0
    echo "✗ $1 is not $APP_NAME ($APP_BUNDLE_ID), so it is left alone; move it out of the way and retry." >&2
    return 1
}
